%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc Session Management
%% Run inside nkmedia_session to extend its capabilities
%% For each operation, starts and monitors a new nkmedia_kms_op process

-module(nkmedia_kms_session).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([init/3, terminate/3, start/3, answer/4, candidate/3, update/5, stop/3]).
-export([nkmedia_session_handle_call/4, nkmedia_session_handle_cast/3]).
-import(nkmedia_kms_session_lib, [invoke/3]).


-export_type([config/0, type/0, opts/0, update/0]).

-define(LLOG(Type, Txt, Args, Session),
    lager:Type("NkMEDIA KMS Session ~s "++Txt, 
               [maps:get(session_id, Session) | Args])).

-include_lib("nksip/include/nksip.hrl").



%% ===================================================================
%% Types
%% ===================================================================

-type session_id() :: nkmedia_session:id().
-type session() :: nkmedia_session:session().
-type endpoint() :: binary().
-type continue() :: continue | {continue, list()}.


-type config() :: 
    nkmedia_session:config() |
    #{
    }.


-type type() ::
    nkmedia_session:type() |
    echo     |
    proxy    |
    publish  |
    listen   |
    play     |
    connect.

-type ext_opts() :: nkmedia_session:ext_opts().

-type opts() ::
    nkmedia_session:session() |
    #{
        record => boolean(),            %
        play_url => binary(),
        room_id => binary(),            % publish, listen
        publisher_id => binary(),       % listen
        proxy_type => webrtc | rtp      % proxy
    }.


-type update() ::
    nkmedia_session:update().


-type state() ::
    #{
        kms_id => nkmedia_kms_engine:id(),
        pipeline => binary(),
        endpoint => endpoint(),
        endpoint_type => webtrc | rtp,
        bridged_to => session_id(),
        publish_to => nkmedia_room:id(),
        listen_to => nkmedia_room:id(),
        record_pos => integer(),
        player_loops => boolean() | integer()
    }.





%% ===================================================================
%% Callbacks
%% ===================================================================


-spec init(session_id(), session(), state()) ->
    {ok, state()}.

init(_Id, _Session, State) ->
    {ok, State}.


%% @doc Called when the session stops
-spec terminate(Reason::term(), session(), state()) ->
    {ok, state()}.

terminate(_Reason, _Session, State) ->
    {ok, State}.


%% @private
-spec start(type(), session(), state()) ->
    {ok, Reply::map(), ext_opts(), state()} |
    {error, nkservice:error(), state()} | continue().

start(Type, Session, State) -> 
    case is_supported(Type) of
        true ->
            case get_pipeline(Type, Session, State) of
                {ok, Session2, State2} ->
                    case Session2 of
                        #{offer:=#{sdp:=_}=Offer} ->
                            do_start_offeree(Type, Offer, Session2, State2);
                        _ ->
                            do_start_offerer(Type, Session2, State2)
                    end;
                {error, Error} ->
                    {error, Error, State}
            end;
        false ->
            continue
    end.


%% @private
-spec answer(type(), nkmedia:answer(), session(), state()) ->
    {ok, Reply::map(), ext_opts(), state()} |
    {error, nkservice:error(), state()} | continue().

answer(Type, Answer, Session, State) ->
    case nkmedia_kms_session_lib:set_answer(Answer, State) of
        ok ->
            case do_start_setup(Type, Session, State) of
                {ok, Reply, ExtOpts, State2} ->
                    Reply2 = Reply#{answer=>Answer},
                    ExtOpts2 = ExtOpts#{answer=>Answer},
                    {ok, Reply2, ExtOpts2, State2};
                {error, Error, State2} ->
                    {error, Error, State2}
            end;
        {error, Error} ->
            {error, Error, State}
    end.

%% @private
-spec candidate(nkmedia:candidate(), session(), state()) ->
    ok | {error, nkservice:error()}.

candidate(#candidate{last=true}, Session, _State) ->
    ?LLOG(info, "sending last client candidate to Kurento", [], Session),
    ok;

candidate(Candidate, Session, State) ->
    ?LLOG(info, "sending client candidate to Kurento", [], Session),
    nkmedia_kms_session_lib:add_ice_candidate(Candidate, State).


%% @private
-spec update(update(), Opts::map(), type(), nkmedia:session(), state()) ->
    {ok, Reply::map(), ext_opts(), state()} |
    {error, nkservice:error(), state()} | continue().

update(session_type, #{session_type:=Type}=Opts, _OldType, Session, State) ->
    do_type(Type, maps:merge(Session, Opts), State);

update(connect, Opts, _Type, Session, State) ->
    do_type(connect, maps:merge(Session, Opts), State);
   
update(media, Opts, _Type, Session, State) ->
    case nkmedia_kms_session_lib:update_media(Opts, State) of
        ok ->
            case start_record(Opts, Session, State) of
                {ok, State2} ->
                    {ok, #{}, #{}, State2};
                {error, Error} ->
                    {error, Error, State}
            end;
        {error, Error} ->
            {error, Error, State}
    end;

update(recorder, #{operation:=Op}, _Type, Session, State) ->
    case nkmedia_kms_session_lib:recorder_op(Op, State) of
        {ok, State2} ->
            {ok, #{}, #{}, State2};
        {error, Error} ->
            {error, Error, State}
    end;

update(recorder, _Opts, _Type, _Session, State) ->
    {error, {missing_parameter, operation}, State};

update(player, #{operation:=Op}=Opts, _Type, Session, State) ->
    case nkmedia_kms_session_lib:player_op(Op, State) of
        {ok, Reply, State2} ->
            {ok, Reply, #{}, State2};
        {ok, State2} ->
            {ok, #{}, #{}, State2};
        {error, Error} ->
            {error, Error, State}
    end;

update(get_stats, Opts, _Type, Session, State) ->
    Type1 = maps:get(media_type, Opts, <<"VIDEO">>),
    Type2 = nklib_util:to_upper(Type1),
    case nkmedia_kms_session_lib:get_stats(Type2, State) of
        {ok, Stats} ->
            {ok, #{stats=>Stats}, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

update(print_info, _Opts, _Type, #{session_id:=SessId}, State) ->
    nkmedia_kms_session_lib:print_info(SessId, State),
    {ok, #{}, #{}, State};

update(_Update, _Opts, _Type, _Session, _State) ->
    continue.


%% @private
-spec stop(nkservice:error(), session(), state()) ->
    {ok, state()}.

stop(_Reason, Session, State) ->
    State2 = reset_all(Session, State),
    nkmedia_kms_session_lib:stop_endpoint(State2),
    {ok, State2}.


%% @private
nkmedia_session_handle_call(get_endpoint, _From, _Session, #{endpoint:=EP}=State) ->
    {reply, {ok, EP}, State};

nkmedia_session_handle_call({bridge, PeerSessId, PeerEP, Medias}, 
                             _From, _Session, #{endpoint:=EP}=State) ->
    case nkmedia_kms_session_lib:connect(PeerEP, Medias, State) of
        ok ->
            ExtOp = #{type=>bridge, type_ext=>#{peer_id=>PeerSessId}},
            nkmedia_session:ext_ops(self(), ExtOp),
            {reply, {ok, EP}, State#{bridged_to=>PeerSessId}};
        {error, Error} ->
            {reply, {error, Error}, State}
    end;

nkmedia_session_handle_call(get_room, _From, _Session, #{publish_to:=RoomId}=State) ->
    {reply, {ok, RoomId}, State};

nkmedia_session_handle_call(get_room, _From, _Session, State) ->
    {reply, {error, not_publishing}, State}.

 
%% @private
nkmedia_session_handle_cast({bridge_stop, PeerId}, Session, State) ->
    case State of
        #{bridged_to:=PeerId} ->
            State2 = reset_all(Session, maps:remove(bridged_to, State)),
            nkmedia_session:ext_ops(self(), #{type=>park}),
            {noreply, State2};
        _ ->
            ?LLOG(notice, "ignoring bridge stop: ~p", [State], Session),
            {noreply, State}
    end;

nkmedia_session_handle_cast({end_of_stream, Player}, _Session, #{player:=Player}=State) ->
    case State of
        #{player_loops:=true} ->
            nkmedia_kms_session_lib:player_op(resume, State),
            {noreply, State};
        #{player_loops:=Loops} when is_integer(Loops), Loops > 1 ->
            nkmedia_kms_session_lib:player_op(resume, State),
            {noreply, State#{player_loops:=Loops-1}};
        _ ->
            % Launch player stop event
            {noreply, State}
    end;

nkmedia_session_handle_cast({end_of_stream, _Player}, _Session, State) ->
    {noreply, State};

nkmedia_session_handle_cast({kms_error, <<"INVALID_URI">>, _, _}, _Session, 
                             #{player:=_}=State) ->
    nkmedia_session:stop(self(), invalid_uri),
    {noreply, State};

nkmedia_session_handle_cast({kms_error, Error, Code, Type}, Session, State) ->
    ?LLOG(notice, "Unexpected KMS error: ~s (~p, ~s)", [Error, Code, Type], Session),
    {noreply, State}.




%% ===================================================================
%% Internal
%% ===================================================================

%% @private
is_supported(park) -> true;
is_supported(echo) -> true;
is_supported(bridge) -> true;
is_supported(publish) -> true;
is_supported(listen) -> true;
is_supported(play) -> true;
is_supported(connect) -> true;
is_supported(_) -> false.


%% @private
-spec do_start_offeree(type(), nkmedia:offer(), session(), state()) ->
    {ok, Reply::map(), ext_opts(), state()} |
    {error, nkservice:error(), state()}.

do_start_offeree(Type, Offer, Session, State) ->
    case get_endpoint_offeree(Offer, Session, State) of
        {ok, Answer, State2} ->
            case do_start_setup(Type, Session, State2) of
                {ok, Reply, ExtOpts, State3} ->
                    Reply2 = Reply#{answer=>Answer},
                    ExtOps2 = ExtOpts#{answer=>Answer},
                    {ok, Reply2, ExtOps2, State3};
                {error, Error, State3} ->
                    {error, Error, State3}
            end;
        {error, Error} ->
            {error, Error, State}
    end.


%% @private
-spec do_start_offerer(type(), session(), state()) ->
    {ok, Reply::map(), ext_opts(), state()} |
    {error, nkservice:error(), state()}.

do_start_offerer(Type, Session, State) ->
    case get_endpoint_offerer(Session, State) of
        {ok, Offer, State2} ->
            {ok, #{offer=>Offer}, #{offer=>Offer}, State2};
        {error, Error} ->
            {error, Error, State}
    end.


%% @private
-spec do_start_setup(type(), session(), state()) ->
    {ok, Reply::map(), ext_opts(), state()} |
    {error, nkservice:error(), state()}.

do_start_setup(Type, Session, State) ->
    case do_type(Type, Session, State) of
        {ok, Reply, ExtOpts, State2} ->
            case start_record(Session, Session, State2) of
                {ok, State3} ->
                    {ok, Reply, ExtOpts, State3};
                {error, Error} ->
                    {error, Error, State}
            end;
        {error, Error, State2} ->
            {error, Error, State2}
    end.


%% @private
-spec do_type(update(), nkmedia:session(), state()) ->
    {ok, Reply::map(), ext_opts(), state()} |
    {error, nkservice:error(), state()} | continue().

do_type(park, Session, State) ->
    State2 = reset_all(Session, State),
    {ok, #{}, #{type=>park}, State2};

do_type(echo, #{session_id:=SessId}=Session, State) ->
    State2 = reset_all(Session, State),
    case connect_peer(SessId, Session, State2) of
        ok ->
            {ok, #{}, #{type=>echo}, State2};
        {error, Error} ->
            {error, Error, State2}
    end;

do_type(bridge, #{peer_id:=PeerId}=Session, State) ->
    #{session_id:=SessId} = Session,
    #{endpoint:=EP} = State,
    %% Select all medias except if "use_XXX=false"
    Medias = nkmedia_kms_session_lib:get_create_medias(Session),
    State2 = reset_all(Session, State),
    case session_call(PeerId, {bridge, SessId, EP, Medias}) of
        {ok, PeerEP} ->
            ok = nkmedia_kms_session_lib:connect(PeerEP, Medias, State2),
            State3 = State#{bridged_to=>PeerId},
            {ok, #{}, #{type=>bridge, type_ext=>#{peer_id=>PeerId}}, State3};
        {error, Error} ->
            {error, Error, State2}
    end;

do_type(publish, #{session_id:=SessId}=Session, State) ->
    State2 = reset_all(Session, State),
    case get_room(publish, Session, State) of
        {ok, RoomId} ->
            Update = {started_publisher, SessId, #{pid=>self()}},
            %% TODO: Link with room
            {ok, _RoomPid} = nkmedia_room:update(RoomId, Update),
            Reply = #{room_id=>RoomId},
            ExtOps = #{type=>publish, type_ext=>#{room_id=>RoomId}},
            State3 = State2#{publish_to=>RoomId},
            {ok, Reply, ExtOps, State3};
        {error, Error} ->
            {error, Error, State2}
    end;

do_type(listen, #{publisher_id:=PeerId, session_id:=SessId}=Session, State) ->
    State2 = reset_all(Session, State),
    case get_room(listen, Session, State) of
        {ok, RoomId} ->
            case connect_peer(PeerId, Session, State) of
                ok -> 
                    Update = {started_listener, SessId, #{peer_id=>PeerId, pid=>self()}},
                    %% TODO: Link with room
                    {ok, _RoomPid} = nkmedia_room:update(RoomId, Update),
                    Reply = #{room_id=>RoomId},
                    ExtOps = #{
                        type => listen, 
                        type_ext => #{room_id=>RoomId, publisher_id=>PeerId}
                    },
                    State3 = State2#{listen_to=>RoomId},
                    {ok, Reply, ExtOps, State3};
                {error, Error} ->
                    {error, Error, State2}
            end;
        {error, Error} ->
            {error, Error, State2}
    end;

do_type(listen, _Session, State) ->
    {error, {missing_field, publisher_id}, State};

do_type(connect, #{peer_id:=PeerId}=Session, State) ->
    case connect_peer(PeerId, Session, State) of
        ok ->
            {ok, #{}, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

do_type(play, #{player_uri:=Uri, session_id:=SessId}=Session, State) ->
    State2 = reset_all(Session, State),
    case nkmedia_kms_session_lib:create_player(SessId, Uri, Session, State2) of
        {ok, State3} ->
            Loops = maps:get(player_loops, Session, false),
            ExtOpts = #{
                type=>play, 
                type_ext => #{player_uri=>Uri, player_loops=>Loops}
            },
            State4 = State3#{player_loops=>Loops},
            {ok, #{}, ExtOpts, State4};
        {error, Error} ->
            {error, Error, State2}
    end;

% do_type(play, Session, State) ->
%     {error, {missing_field, player_uri}, State};

do_type(play, Session, State) ->
    % Uri = <<"file:///tmp/1.webm">>,
    Uri = <<"http://files.kurento.org/video/format/sintel.webm">>,
    do_type(play, Session#{player_uri=>Uri, player_loops=>2}, State);

do_type(_Op, _Session, State) ->
    {error, invalid_operation, State}.


%% @private 
%% If we are starting a publisher or listener with an already started room
%% we must connect to the same pipeline
-spec get_pipeline(type(), session(), state()) ->
    {ok, session(), state()} | {error, term()}.

get_pipeline(publish, #{room_id:=RoomId}=Session, State) ->
    get_pipeline_from_room(RoomId, Session, State);

get_pipeline(listen, #{publisher_id:=PeerId}=Session, State) ->
    case get_peer_room(PeerId) of
        {ok, RoomId} ->
            Session2 = Session#{room_id=>RoomId},
            get_pipeline_from_room(RoomId, Session2, State);
        _ ->
            get_pipeline(normal, Session, State)
    end;

get_pipeline(_Type, #{srv_id:=SrvId}=Session, State) ->
    case nkmedia_kms_session_lib:get_mediaserver(SrvId, State) of
        {ok, State2} -> 
            {ok, Session, State2};
        {error, Error} -> 
            {error, Error}
    end.


%% @private
get_pipeline_from_room(RoomId, Session, State) ->
    case nkmedia_room:get_room(RoomId) of
        {ok, #{nkmedia_kms:=#{kms_id:=KmsId}}} -> 
            ?LLOG(notice, "getting engine from ROOM: ~s", [KmsId], Session),
            State2 = State#{kms_id=>KmsId},
            case nkmedia_kms_session_lib:get_pipeline(State2) of
                {ok, State3} -> 
                    {ok, Session, State3};
                {error, Error} ->
                    {error, Error}
            end;
        _ ->
            get_pipeline(normal, Session, State)
    end.


%% @private
-spec get_endpoint_offeree(nkmedia:offer(), session(), state()) ->
    {ok, nkmedia:answer(), state()} | {error, nkservice:error()}.

get_endpoint_offeree(#{sdp_type:=rtp}=Offer, #{session_id:=SessId}, State) ->
    nkmedia_kms_session_lib:create_rtp(SessId, Offer, State);

get_endpoint_offeree(Offer, #{session_id:=SessId}, State) ->
    nkmedia_kms_session_lib:create_webrtc(SessId, Offer, State).


%% @private
-spec get_endpoint_offerer(session(), state()) ->
    {ok, nkmedia:answer(), state()} | {error, nkservice:error()}.

get_endpoint_offerer(#{session_id:=SessId, sdp_type:=rtp}, State) ->
    nkmedia_kms_session_lib:create_rtp(SessId, #{}, State);

get_endpoint_offerer(#{session_id:=SessId}, State) ->
    nkmedia_kms_session_lib:create_webrtc(SessId, #{}, State).


%% @private
-spec start_record(map(), session(), state()) ->
    {ok, state()} | {error, term()}.

start_record(#{record:=true}=Opts, #{session_id:=SessId}, State) ->
    nkmedia_kms_session_lib:create_recorder(SessId, Opts, State);

start_record(#{record:=false}, _Session, State) ->
    case nkmedia_kms_session_lib:recorder_op(stop, State) of
        {ok, State2} -> {ok, State2};
        _ -> {ok, State}
    end;

start_record(_Opts, _Session, State) ->
    {ok, State}.


%% @private
-spec reset_all(session(), state()) ->
    {ok, state()} | {error, term()}.

reset_all(#{session_id:=SessId}, State) ->
    case nkmedia_kms_session_lib:player_op(stop, State) of
        {ok, State2} -> ok;
        _ -> State2 = State
    end,
    case nkmedia_kms_session_lib:recorder_op(stop, State2) of
        {ok, State3} -> State3;
        _ -> State3 = State2
    end,
    nkmedia_kms_session_lib:disconnect_all(State3),
    case State3 of
        #{bridged_to:=PeerId} ->
            session_cast(PeerId, {bridge_stop, SessId}),
            State4 = maps:remove(bridged_to, State3);
        _ ->
            State4 = State3
    end,
    case State4 of
        #{publish_to:=RoomId} ->
            Update = {stopped_publisher, SessId, #{}},
            nkmedia_room:update_async(RoomId, Update),
            State5 = maps:remove(publish_to, State4);
        #{listen_to:=RoomId} ->
            Update = {stopped_listener, SessId, #{}},
            nkmedia_room:update_async(RoomId, Update),
            State5 = maps:remove(listen_to, State4);
        _ ->
            State5 = State4
    end,
    State5.


%% @private
%% Connect a remote session to us as sink
%% All medias will be included, except if "use_XXX=false" in Session
-spec connect_peer(session_id(), session(), state()) ->
    ok | {error, nkservice:error()}.

connect_peer(PeerId, Session, State) ->
    case get_peer_endpoint(PeerId, Session, State) of
        {ok, PeerEP} ->
            nkmedia_kms_session_lib:connect(PeerEP, Session, State);
        {error, Error} ->
            {error, Error}
    end.



%% @private
-spec get_room(publish|listen, session(), state()) ->
    {ok, nkmedia_room:id()} | {error, term()}.

get_room(Type, #{srv_id:=SrvId}=Session, #{kms_id:=KmsId}) ->
    case get_room_id(Type, Session) of
        {ok, RoomId} ->
            lager:error("ROOM ID IS: ~p", [RoomId]),
            case nkmedia_room:get_room(RoomId) of
                {ok, #{nkmedia_kms:=#{kms_id:=KmsId}}} ->
                    lager:error("SAME MS"),
                    {ok, RoomId};
                {ok, _} ->
                    {error, different_mediaserver};
                {error, room_not_found} ->
                    Opts = #{
                        room_id => RoomId,
                        backend => nkmedia_kms, 
                        nkmedia_kms => KmsId
                    },
                    case nkmedia_room:start(SrvId, Opts) of
                        {ok, RoomId, _} ->
                            {ok, RoomId};
                        {error, Error} ->
                            {error, Error}
                    end;
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @private
-spec get_room_id(publish|listen, session()) ->
    {ok, nkmedia_room:id()} | {error, term()}.

get_room_id(Type, Session) ->
    case maps:find(room_id, Session) of
        {ok, RoomId} -> 
            lager:error("HAS ROOM"),
            {ok, nklib_util:to_binary(RoomId)};
        error when Type==publish -> 
            {ok, nklib_util:uuid_4122()};
        error when Type==listen ->
            case Session of
                #{publisher_id:=Publisher} ->
                    case get_peer_room(Publisher) of
                        {ok, RoomId} -> {ok, RoomId};
                        {error, _Error} -> {error, invalid_publisher}
                    end;
                _ ->
                    {error, {missing_field, publisher_id}}
            end
    end.


%% @private
-spec get_peer_endpoint(session_id(), session(), state()) ->
    {ok, endpoint()} | {error, nkservice:error()}.

get_peer_endpoint(SessId, #{session_id:=SessId}, #{endpoint:=EP}) ->
    {ok, EP};
get_peer_endpoint(SessId, _Session, _State) ->
    case session_call(SessId, get_endpoint) of
        {ok, EP} -> {ok, EP};
        {error, Error} -> {error, Error}
    end.


%% @private
-spec get_peer_room(session_id()) ->
    {ok, nkmedia_room:id()} | {error, nkservice:error()}.

get_peer_room(SessId) ->
    session_call(SessId, get_room).


%% @private
session_call(SessId, Msg) ->
    nkmedia_session:do_call(SessId, {nkmedia_kms, Msg}).


%% @private
session_cast(SessId, Msg) ->
    nkmedia_session:do_cast(SessId, {nkmedia_kms, Msg}).



