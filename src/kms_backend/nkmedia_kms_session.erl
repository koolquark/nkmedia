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

-export([start/3, answer/4, candidate/2, update/4, stop/2]).
-export([handle_call/3, handle_cast/2]).
-import(nkmedia_kms_session_lib, [invoke/3]).


-export_type([session/0, type/0, opts/0, update/0]).

-define(LLOG(Type, Txt, Args, Session),
    lager:Type("NkMEDIA KMS Session ~s "++Txt, 
               [maps:get(session_id, Session) | Args])).

-include_lib("nksip/include/nksip.hrl").
-include("../../include/nkmedia.hrl").



%% ===================================================================
%% Types
%% ===================================================================

-type session_id() :: nkmedia_session:id().
-type from() :: {pid(), term()}.
-type endpoint() :: binary().
-type continue() :: continue | {continue, list()}.


-type session() :: 
    nkmedia_session:session() |
    #{
        nkmedia_kms_id => nkmedia_kms_engine:id(),
        nkmedia_kms_pipeline => binary(),
        nkmedia_kms_endpoint => endpoint(),
        nkmedia_kms_endpoint_type => webtrc | rtp,
        nkmedia_kms_recorder => endpoint(),
        nkmedia_kms_player => endpoint(),
        nkmedia_kms_bridged_to => session_id(),
        nkmedia_kms_publish_to => nkmedia_room:id(),
        nkmedia_kms_listen_to => nkmedia_room:id(),
        nkmedia_kms_record_pos => integer(),
        nkmedia_kms_player_loops => boolean() | integer()
    }.


-type type() ::
    nkmedia_session:type() |
    echo     |
    proxy    |
    publish  |
    listen   |
    play     |
    connect.

-type ext_ops() :: nkmedia_session:ext_ops().

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






%% ===================================================================
%% Callbacks
%% ===================================================================


%% @private
-spec start(type(), from(), session()) ->
    {reply, Reply::term(), ext_ops(), session()} |
    {noreply, ext_ops(), session()} |
    {error, nkservice:error(), session()} | continue().

start(Type, _From, Session) -> 
    case is_supported(Type) of
        true ->
            Session2 = ?SESSION(Session, #{backend=>nkmedia_kms}),
            case get_pipeline(Type, Session2) of
                {ok, Session3} ->
                    case Session3 of
                        #{offer:=#{sdp:=_}=Offer} ->
                            do_start_offeree(Type, Offer, Session3);
                        _ ->
                            do_start_offerer(Type, Session3)
                    end;
                {error, Error} ->
                    {error, Error, Session2}
            end;
        false ->
            continue
    end.


%% @private
-spec answer(type(), nkmedia:answer(), from(), session()) ->
    {reply, Reply::term(), ext_ops(), session()} |
    {noreply, ext_ops(), session()} |
    {error, term(), session()} | continue().

answer(Type, Answer, _From, Session) ->
    case nkmedia_kms_session_lib:set_answer(Answer, Session) of
        ok ->
            case do_start_setup(Type, Session) of
                {ok, Reply, ExtOpts, Session2} ->
                    Reply2 = Reply#{answer=>Answer},
                    ExtOpts2 = ExtOpts#{answer=>Answer},
                    {reply, {ok, Reply2}, ExtOpts2, Session2};
                {error, Error, Session2} ->
                    {error, Error, Session2}
            end;
        {error, Error} ->
            {error, Error, Session}
    end.

%% @private
-spec candidate(nkmedia:candidate(), session()) ->
    ok | {error, nkservice:error()}.

candidate(#candidate{last=true}, Session) ->
    ?LLOG(info, "sending last client candidate to Kurento", [], Session),
    ok;

candidate(Candidate, Session) ->
    ?LLOG(info, "sending client candidate to Kurento", [], Session),
    nkmedia_kms_session_lib:add_ice_candidate(Candidate, Session).


%% @private
-spec update(update(), Opts::map(), from(), session()) ->
    {reply, Reply::map(), ext_ops(), session()} |
    {noreply, ext_ops(), session()} |
    {error, term(), session()} | continue().


update(session_type, #{session_type:=Type}=Opts, _From, Session) ->
    do_type(Type, maps:merge(Session, Opts));

update(connect, Opts, _From, Session) ->
    do_type(connect, maps:merge(Session, Opts));
   
update(media, Opts, _From, Session) ->
    case nkmedia_kms_session_lib:update_media(Opts, Session) of
        ok ->
            case start_record(Opts, Session) of
                {ok, Session2} ->
                    {reply, {ok, #{}}, #{}, Session2};
                {error, Error} ->
                    {error, Error, Session}
            end;
        {error, Error} ->
            {error, Error, Session}
    end;

update(recorder, #{operation:=Op}, From, Session) ->
    case nkmedia_kms_session_lib:recorder_op(Op, Session) of
        {ok, Session2} ->
            {reply, {ok, #{}}, #{}, Session2};
        {error, Error} ->
            {error, Error, Session}
    end;

update(recorder, _Opts, _From, Session) ->
    {error, {missing_parameter, operation}, Session};

update(player, #{operation:=Op}=Opts, _From, Session) ->
    case nkmedia_kms_session_lib:player_op(Op, Session) of
        {ok, Reply, Session2} ->
            {reply, {ok, Reply}, #{}, Session2};
        {ok, Session2} ->
            {reply, {ok, #{}}, #{}, Session2};
        {error, Error} ->
            {error, Error, Session}
    end;

update(get_stats, Opts, From, Session) ->
    Type1 = maps:get(media_type, Opts, <<"VIDEO">>),
    Type2 = nklib_util:to_upper(Type1),
    case nkmedia_kms_session_lib:get_stats(Type2, Session) of
        {ok, Stats} ->
            {reply, {ok, #{stats=>Stats}}, #{}, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

update(print_info, _Opts, From, #{session_id:=SessId}=Session) ->
    nkmedia_kms_session_lib:print_info(SessId, Session),
    {reply, {ok, #{}}, #{}, Session};

update(_Update, _Opts, _From, _Session) ->
    continue.


%% @private
-spec stop(nkservice:error(), session()) ->
    {ok, session()}.

stop(_Reason, Session) ->
    Session2 = reset_all(Session),
    nkmedia_kms_session_lib:stop_endpoint(Session2),
    {ok, Session2}.


%% @private
handle_call(get_endpoint, _From, #{nkmedia_kms_endpoint:=EP}=Session) ->
    {reply, {ok, EP}, Session};

handle_call({bridge, PeerSessId, PeerEP, Medias}, 
             _From, #{nkmedia_kms_endpoint:=EP}=Session) ->
    case nkmedia_kms_session_lib:connect(PeerEP, Medias, Session) of
        ok ->
            ExtOp = #{type=>bridge, type_ext=>#{peer_id=>PeerSessId}},
            nkmedia_session:ext_ops(self(), ExtOp),
            {reply, {ok, EP}, ?SESSION(Session, #{bridged_to=>PeerSessId})};
        {error, Error} ->
            {reply, {error, Error}, Session}
    end;

handle_call(get_room, _From, #{publish_to:=RoomId}=Session) ->
    {reply, {ok, RoomId}, Session};

handle_call(get_room, _From, Session) ->
    {reply, {error, not_publishing}, Session}.

 
%% @private
handle_cast({bridge_stop, PeerId}, Session) ->
    case Session of
        #{nkmedia_kms_bridged_to:=PeerId} ->
            Session2 = ?SESSION_RM(nkmedia_kms_bridged_to, Session),
            Session3 = reset_all(Session2),
            nkmedia_session:ext_ops(self(), #{type=>park}),
            {noreply, Session3};
        _ ->
            ?LLOG(notice, "ignoring bridge stop", [], Session),
            {noreply, Session}
    end;

handle_cast({end_of_stream, Player}, #{nkmedia_kms_player:=Player}=Session) ->
    case Session of
        #{nkmedia_kms_player_loops:=true} ->
            nkmedia_kms_session_lib:player_op(resume, Session),
            {noreply, Session};
        #{nkmedia_kms_player_loops:=Loops} when is_integer(Loops), Loops > 1 ->
            nkmedia_kms_session_lib:player_op(resume, Session),
            {noreply, ?SESSION(Session, #{nkmedia_kms_player_loops=>Loops-1})};
        _ ->
            % Launch player stop event
            {noreply, Session}
    end;

handle_cast({end_of_stream, _Player}, Session) ->
    {noreply, Session};

handle_cast({kms_error, <<"INVALID_URI">>, _, _}, #{nkmedia_kms_player:=_}=Session) ->
    nkmedia_session:stop(self(), invalid_uri),
    {noreply, Session};

handle_cast({kms_error, Error, Code, Type}, Session) ->
    ?LLOG(notice, "Unexpected KMS error: ~s (~p, ~s)", [Error, Code, Type], Session),
    {noreply, Session}.




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
-spec do_start_offeree(type(), nkmedia:offer(), session()) ->
    {ok, Reply::map(), ext_ops(), session()} |
    {error, nkservice:error(), session()}.

do_start_offeree(Type, Offer, Session) ->
    case get_endpoint_offeree(Offer, Session) of
        {ok, Answer, Session2} ->
            case do_start_setup(Type, Session2) of
                {ok, Reply, ExtOpts, Session3} ->
                    Reply2 = Reply#{answer=>Answer},
                    ExtOps2 = ExtOpts#{answer=>Answer},
                    {reply, Reply2, ExtOps2, Session3};
                {error, Error, Session3} ->
                    {error, Error, Session3}
            end;
        {error, Error} ->
            {error, Error, Session}
    end.


%% @private
-spec do_start_offerer(type(), session()) ->
    {ok, Reply::map(), ext_ops(), session()} |
    {error, nkservice:error(), session()}.

do_start_offerer(Type, Session) ->
    case get_endpoint_offerer(Session) of
        {ok, Offer, Session2} ->
            {ok, #{offer=>Offer}, #{offer=>Offer}, Session2};
        {error, Error} ->
            {error, Error, Session}
    end.


%% @private
-spec do_start_setup(type(), session()) ->
    {ok, Reply::map(), ext_ops(), session()} |
    {error, nkservice:error(), session()}.

do_start_setup(Type, Session) ->
    case do_type(Type, Session) of
        {ok, Reply, ExtOpts, Session2} ->
            case start_record(Session2, Session2) of
                {ok, Session3} ->
                    {ok, Reply, ExtOpts, Session3};
                {error, Error} ->
                    {error, Error, Session2}
            end;
        {error, Error, Session2} ->
            {error, Error, Session2}
    end.


%% @private
-spec do_type(update(), session()) ->
    {ok, Reply::map(), ext_ops(), session()} |
    {error, nkservice:error(), session()} | continue().

do_type(park, Session) ->
    Session2 = reset_all(Session),
    {ok, #{}, #{type=>park}, Session2};

do_type(echo, #{session_id:=SessId}=Session) ->
    Session2 = reset_all(Session),
    case connect_peer(SessId, Session2) of
        ok ->
            {ok, #{}, #{type=>echo}, Session2};
        {error, Error} ->
            {error, Error, Session2}
    end;

do_type(bridge, #{peer_id:=PeerId}=Session) ->
    #{session_id:=SessId, nkmedia_kms_endpoint:=EP} = Session,
    %% Select all medias except if "use_XXX=false"
    Medias = nkmedia_kms_session_lib:get_create_medias(Session),
    Session2 = reset_all(Session),
    case session_call(PeerId, {bridge, SessId, EP, Medias}) of
        {ok, PeerEP} ->
            ok = nkmedia_kms_session_lib:connect(PeerEP, Medias, Session2),
            Session3 = ?SESSION(Session2, #{nkmedia_kms_bridged_to=>PeerId}),
            {ok, #{}, #{type=>bridge, type_ext=>#{peer_id=>PeerId}}, Session3};
        {error, Error} ->
            {error, Error, Session2}
    end;

do_type(publish, #{session_id:=SessId}=Session) ->
    Session2 = reset_all(Session),
    case get_room(publish, Session) of
        {ok, RoomId} ->
            Update = {started_publisher, SessId, #{pid=>self()}},
            %% TODO: Link with room
            {ok, _RoomPid} = nkmedia_room:update(RoomId, Update),
            Reply = #{room_id=>RoomId},
            ExtOps = #{type=>publish, type_ext=>#{room_id=>RoomId}},
            Session3 = ?SESSION(Session2, #{nkmedia_kms_publish_to=>RoomId}),
            {ok, Reply, ExtOps, Session3};
        {error, Error} ->
            {error, Error, Session2}
    end;

do_type(listen, #{publisher_id:=PeerId, session_id:=SessId}=Session) ->
    Session2 = reset_all(Session),
    case get_room(listen, Session) of
        {ok, RoomId} ->
            case connect_peer(PeerId, Session) of
                ok -> 
                    Update = {started_listener, SessId, #{peer_id=>PeerId, pid=>self()}},
                    %% TODO: Link with room
                    {ok, _RoomPid} = nkmedia_room:update(RoomId, Update),
                    Reply = #{room_id=>RoomId},
                    ExtOps = #{
                        type => listen, 
                        type_ext => #{room_id=>RoomId, publisher_id=>PeerId}
                    },
                    Session3 = ?SESSION(Session2, #{nkmedia_kms_listen_to=>RoomId}),
                    {ok, Reply, ExtOps, Session3};
                {error, Error} ->
                    {error, Error, Session2}
            end;
        {error, Error} ->
            {error, Error, Session2}
    end;

do_type(listen, Session) ->
    {error, {missing_field, publisher_id}, Session};

do_type(connect, #{peer_id:=PeerId}=Session) ->
    case connect_peer(PeerId, Session) of
        ok ->
            {ok, #{}, #{}, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

do_type(play, #{player_uri:=Uri}=Session) ->
    Session2 = reset_all(Session),
    case nkmedia_kms_session_lib:create_player(Uri, Session2) of
        {ok, Session3} ->
            Loops = maps:get(player_loops, Session, false),
            ExtOpts = #{
                type=>play, 
                type_ext => #{player_uri=>Uri, player_loops=>Loops}
            },
            Session4 = ?SESSION(Session3, #{nkmedia_kms_player_loops=>Loops}),
            {ok, #{}, ExtOpts, Session4};
        {error, Error} ->
            {error, Error, Session2}
    end;

% do_type(play, Session, Session) ->
%     {error, {missing_field, player_uri}, Session};

do_type(play, Session) ->
    % Uri = <<"file:///tmp/1.webm">>,
    Uri = <<"http://files.kurento.org/video/format/sintel.webm">>,
    do_type(play, Session#{player_uri=>Uri, player_loops=>2});

do_type(_Op, Session) ->
    {error, invalid_operation, Session}.


%% @private 
%% If we are starting a publisher or listener with an already started room
%% we must connect to the same pipeline
-spec get_pipeline(type(), session()) ->
    {ok, session()} | {error, term()}.

get_pipeline(publish, #{room_id:=RoomId}=Session) ->
    get_pipeline_from_room(RoomId, Session);

get_pipeline(listen, #{publisher_id:=PeerId}=Session) ->
    case get_peer_room(PeerId) of
        {ok, RoomId} ->
            Session2 = ?SESSION(Session, #{room_id=>RoomId}),
            get_pipeline_from_room(RoomId, Session2);
        _ ->
            get_pipeline(normal, Session)
    end;

get_pipeline(_Type, Session) ->
    case nkmedia_kms_session_lib:get_mediaserver(Session) of
        {ok, Session2} -> 
            {ok, Session2};
        {error, Error} -> 
            {error, Error}
    end.


%% @private
get_pipeline_from_room(RoomId, Session) ->
    case nkmedia_room:get_room(RoomId) of
        {ok, #{nkmedia_kms:=#{kms_id:=KmsId}}} -> 
            ?LLOG(notice, "getting engine from ROOM: ~s", [KmsId], Session),
            Session2 = ?SESSION(Session, #{nkmedia_kms_id=>KmsId}),
            case nkmedia_kms_session_lib:get_pipeline(Session2) of
                {ok, Session3} -> 
                    {ok, Session3};
                {error, Error} ->
                    {error, Error}
            end;
        _ ->
            get_pipeline(normal, Session)
    end.


%% @private
-spec get_endpoint_offeree(nkmedia:offer(), session()) ->
    {ok, nkmedia:answer(), session()} | {error, nkservice:error()}.

get_endpoint_offeree(#{sdp_type:=rtp}=Offer, Session) ->
    nkmedia_kms_session_lib:create_rtp(Offer, Session);

get_endpoint_offeree(Offer, Session) ->
    nkmedia_kms_session_lib:create_webrtc(Offer, Session).


%% @private
-spec get_endpoint_offerer(session()) ->
    {ok, nkmedia:answer(), session()} | {error, nkservice:error()}.

get_endpoint_offerer(#{sdp_type:=rtp}=Session) ->
    nkmedia_kms_session_lib:create_rtp(#{}, Session);

get_endpoint_offerer(Session) ->
    nkmedia_kms_session_lib:create_webrtc(#{}, Session).


%% @private
-spec start_record(map(), session()) ->
    {ok, session()} | {error, term()}.

start_record(#{record:=true}=Opts, #{session_id:=SessId}=Session) ->
    nkmedia_kms_session_lib:create_recorder(SessId, Opts, Session);

start_record(#{record:=false},  Session) ->
    case nkmedia_kms_session_lib:recorder_op(stop, Session) of
        {ok, Session2} -> {ok, Session2};
        _ -> {ok, Session}
    end;

start_record(_Opts, Session) ->
    {ok, Session}.


%% @private
-spec reset_all(session()) ->
    {ok, session()} | {error, term()}.

reset_all(#{session_id:=SessId}=Session) ->
    case nkmedia_kms_session_lib:player_op(stop, Session) of
        {ok, Session2} -> ok;
        _ -> Session2 = Session
    end,
    case nkmedia_kms_session_lib:recorder_op(stop, Session2) of
        {ok, Session3} -> Session3;
        _ -> Session3 = Session2
    end,
    nkmedia_kms_session_lib:disconnect_all(Session3),
    case Session3 of
        #{nkmedia_kms_bridged_to:=PeerId} ->
            session_cast(PeerId, {bridge_stop, SessId}),
            Session4 = ?SESSION_RM(nkmedia_kms_bridged_to, Session3);
        _ ->
            Session4 = Session3
    end,
    case Session4 of
        #{nkmedia_kms_publish_to:=RoomId} ->
            Update = {stopped_publisher, SessId, #{}},
            nkmedia_room:update_async(RoomId, Update),
            Session5 = ?SESSION_RM(nkmedia_kms_publish_to, Session4);
        #{nkmedia_kms_listen_to:=RoomId} ->
            Update = {stopped_listener, SessId, #{}},
            nkmedia_room:update_async(RoomId, Update),
            Session5 = ?SESSION_RM(nkmedia_kms_listen_to, Session4);
        _ ->
            Session5 = Session4
    end,
    Session5.


%% @private
%% Connect a remote session to us as sink
%% All medias will be included, except if "use_XXX=false" in Session
-spec connect_peer(session_id(), session()) ->
    ok | {error, nkservice:error()}.

connect_peer(PeerId, Session) ->
    case get_peer_endpoint(PeerId, Session) of
        {ok, PeerEP} ->
            nkmedia_kms_session_lib:connect(PeerEP, Session);
        {error, Error} ->
            {error, Error}
    end.



%% @private
-spec get_room(publish|listen, session()) ->
    {ok, nkmedia_room:id()} | {error, term()}.

get_room(Type, #{srv_id:=SrvId, nkmedia_kms_id:=KmsId}=Session) ->
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
-spec get_peer_endpoint(session_id(), session()) ->
    {ok, endpoint()} | {error, nkservice:error()}.

get_peer_endpoint(SessId, #{session_id:=SessId, nkmedia_kms_endpoint:=EP}) ->
    {ok, EP};
get_peer_endpoint(SessId, _Session) ->
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



