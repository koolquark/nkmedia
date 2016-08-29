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
%% We create an endpoint (webrtc or rtp) and a proxy (a PassThrough)
%% All media from the endpoint (camera/micro) goes to the proxy, and remote
%% endpoints connect from the proxy.
%% We select what we want to receive and connect directly them to the endpoint

-module(nkmedia_kms_session).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/3, answer/4, candidate/2, server_trickle_ready/2, update/4, stop/2]).
-export([handle_call/3, handle_cast/2]).


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
        nkmedia_kms_proxy => endpoint(),
        nkmedia_kms_endpoint => endpoint(),
        nkmedia_kms_endpoint_type => webtrc | rtp,
        nkmedia_kms_source => endpoint(),
        nkmedia_kms_recorder => endpoint(),
        nkmedia_kms_player => endpoint(),
        nkmedia_kms_bridged_to => session_id(),
        nkmedia_kms_publish_to => nkmedia_room:id(),
        nkmedia_kms_listen_to => nkmedia_room:id(),
        nkmedia_kms_record_pos => integer(),
        nkmedia_kms_player_loops => boolean() | integer(),
        nkmedia_kms_trickle_ice => map()  
    }.


-type type() ::
    nkmedia_session:type() |
    echo     |
    proxy    |
    publish  |
    listen   |
    play     |
    connect.

-type update() :: atom().

-type ext_ops() :: nkmedia_session:ext_ops().

-type opts() ::
    nkmedia_session:session() |
    #{
        record => boolean(),            %
        play_url => binary(),
        room_id => binary(),            % publish, listen
        publisher_id => binary()       % listen
    }.


% AUDIO, VIDEO, DATA
% -type media_type() :: nkmedia_kms_session_lib:media_type().




%% ===================================================================
%% Callbacks
%% ===================================================================


%% @private
-spec start(type(), from(), session()) ->
    {ok, Reply::term(), ext_ops(), session()} |
    {ok, ext_ops(), session()} |
    {error, nkservice:error(), session()} | continue().

start(Type, From, Session) -> 
    case is_supported(Type) of
        true ->
            Session2 = ?SESSION(#{backend=>nkmedia_kms}, Session),
            case get_pipeline(Type, Session2) of
                {ok, Session3} ->
                    case nkmedia_kms_session_lib:create_proxy(Session3) of
                        {ok, Session4} ->
                            case Session4 of
                                #{offer:=#{sdp:=_}=Offer} ->
                                    do_start_offeree(Type, Offer, From, Session4);
                                _ ->
                                    do_start_offerer(Type, From, Session4)
                            end;
                        {error, Error} ->
                            {error, Error}
                    end;
                {error, Error} ->
                    {error, Error, Session2}
            end;
        false ->
            continue
    end.


%% @private
-spec answer(type(), nkmedia:answer(), from(), session()) ->
    {ok, Reply::term(), ext_ops(), session()} |
    {ok, ext_ops(), session()} |
    {error, term(), session()} | continue().

answer(Type, Answer, _From, Session) ->
    case nkmedia_kms_session_lib:set_answer(Answer, Session) of
        {ok, _} ->
            case do_start_type(Type, Session) of
                {ok, Reply, ExtOps, Session2} ->
                    Reply2 = Reply#{answer=>Answer},
                    ExtOps2 = ExtOps#{answer=>Answer},
                    {ok, {ok, Reply2}, ExtOps2, Session2};
                {error, Error, Session2} ->
                    {error, Error, Session2}
            end;
        {error, Error} ->
            {error, Error, Session}
    end.

%% @private
-spec candidate(nkmedia:candidate(), session()) ->
    {ok, session()}.

candidate(#candidate{last=true}, Session) ->
    ?LLOG(info, "sending last client candidate to Kurento", [], Session),
    {ok, Session};

candidate(Candidate, Session) ->
    ?LLOG(info, "sending client candidate to Kurento", [], Session),
    nkmedia_kms_session_lib:add_ice_candidate(Candidate, Session),
    {ok, Session}.


%% @private
-spec server_trickle_ready([nkmedia:candidate()], session()) ->
    {ok, ext_ops(), session()} | {error, nkservice:error()}.

server_trickle_ready(Candidates, #{nkmedia_kms_trickle_ice:=Info}=Session) ->
    case Info of
        #{
            from := From,
            reply := Reply,
            extops := ExtOps,
            answer := #{sdp:=SDP}=Answer
        } ->
            SDP2 = nksip_sdp_util:add_candidates(SDP, Candidates),
            Answer2 = Answer#{sdp=>nksip_sdp:unparse(SDP2), trickle_ice=>false},
            Reply2 = {ok, Reply#{answer=>Answer2}}, 
            ExtOps2 = ExtOps#{answer=>Answer2};
        #{
            from := From,
            offer := #{sdp:=SDP}=Offer
        } ->
            SDP2 = nksip_sdp_util:add_candidates(SDP, Candidates),
            Offer2 = Offer#{sdp=>nksip_sdp:unparse(SDP2), trickle_ice=>false},
            Reply2 = {ok, #{offer=>Offer2}}, 
            ExtOps2 = #{offer=>Offer2}
    end,
    gen_server:reply(From, Reply2),
    Session2 = ?SESSION_RM(nkmedia_kms_trickle_ice, Session),
    {ok, ExtOps2, Session2}.


%% @private
-spec update(update(), Opts::map(), from(), session()) ->
    {ok, Reply::term(), ext_ops(), session()} |
    {ok, ext_ops(), session()} |
    {error, term(), session()} | continue().


update(session_type, #{session_type:=Type}=Opts, _From, Session) ->
    case check_record(Opts, Session) of
        {ok, Session2} ->
            do_type(Type, Opts, Session2);
        {error, Error} ->
            {error, Error, Session}
    end;

update(connect, Opts, _From, Session) ->
    do_type(connect, Opts, Session);
   
%% Updates media in EP -> Proxy path only (to "mute")
update(media, Opts, _From, Session) ->
    case check_record(Opts, Session) of
        {ok, Session2} ->
            ok = nkmedia_kms_session_lib:update_media(Opts, Session),
            {ok, #{}, #{}, Session2};
        {error, Error} ->
            {error, Error, Session}
    end;

update(recorder, #{operation:=Op}, From, Session) ->
    case nkmedia_kms_session_lib:recorder_op(Op, Session) of
        {ok, Session2} ->
            {ok, {ok, #{}}, #{}, Session2};
        {error, Error} ->
            {error, Error, Session}
    end;

update(recorder, _Opts, _From, Session) ->
    {error, {missing_parameter, operation}, Session};

update(player, #{operation:=Op}=Opts, _From, Session) ->
    case nkmedia_kms_session_lib:player_op(Op, Session) of
        {ok, Reply, Session2} ->
            {ok, {ok, Reply}, #{}, Session2};
        {ok, Session2} ->
            {ok, {ok, #{}}, #{}, Session2};
        {error, Error} ->
            {error, Error, Session}
    end;

update(get_stats, Opts, From, Session) ->
    Type1 = maps:get(media_type, Opts, <<"VIDEO">>),
    Type2 = nklib_util:to_upper(Type1),
    case nkmedia_kms_session_lib:get_stats(Type2, Session) of
        {ok, Stats} ->
            {ok, {ok, #{stats=>Stats}}, #{}, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

update(print_info, _Opts, From, #{session_id:=SessId}=Session) ->
    nkmedia_kms_session_lib:print_info(SessId, Session),
    {ok, {ok, #{}}, #{}, Session};

update(_Update, _Opts, _From, _Session) ->
    continue.


%% @private
-spec stop(nkservice:error(), session()) ->
    {ok, session()}.

stop(_Reason, Session) ->
    Session2 = reset_type(Session),
    nkmedia_kms_session_lib:release_all(Session2),
    {ok, Session2}.


%% @private
handle_call(get_proxy, _From, #{nkmedia_kms_proxy:=Proxy}=Session) ->
    {reply, {ok, Proxy}, Session};

handle_call({bridge, PeerSessId, PeerProxy, Opts}, 
             _From, #{nkmedia_kms_proxy:=Proxy}=Session) ->
    case connect_from_peer(PeerProxy, Opts, Session) of
        {ok, Session2} ->
            ExtOp = #{type=>bridge, type_ext=>#{peer_id=>PeerSessId}},
            nkmedia_session:ext_ops(self(), ExtOp),
            Session3 = ?SESSION(#{nkmedia_kms_bridged_to=>PeerSessId}, Session2),
            {reply, {ok, Proxy}, Session3};
        {error, Error} ->
            {reply, {error, Error}, Session}
    end;

handle_call(get_publisher, _From, #{nkmedia_kms_publish_to:=RoomId}=Session) ->
    {reply, {ok, RoomId}, Session};

handle_call(get_publisher, _From, Session) ->
    {reply, {error, not_publishing}, Session}.

 
%% @private
handle_cast({bridge_stop, PeerId}, Session) ->
    case Session of
        #{nkmedia_kms_bridged_to:=PeerId} ->
            Session2 = ?SESSION_RM(nkmedia_kms_bridged_to, Session),
            Session3 = reset_type(Session2),
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
            {noreply, ?SESSION(#{nkmedia_kms_player_loops=>Loops-1}, Session)};
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
-spec do_start_offeree(type(), nkmedia:offer(), from(), session()) ->
    {ok, Reply::term(), ext_ops(), session()} |
    {error, nkservice:error(), session()}.

do_start_offeree(Type, Offer, From, Session) ->
    case create_endpoint_offeree(Offer, Session) of
        {ok, #{trickle_ice:=AnsTrickleIce}=Answer, Session2} ->
            case do_start_type(Type, Session2) of
                {ok, Reply, ExtOps, Session3} ->
                    SessTrickleIce = maps:get(trickle_ice, Session3, false),
                    case AnsTrickleIce andalso not SessTrickleIce of
                        true -> 
                            Info = #{
                                from => From,
                                reply => Reply,
                                extops => ExtOps,
                                answer => Answer
                            },
                            Update = #{nkmedia_kms_trickle_ice => Info},
                            Session4 = ?SESSION(Update, Session3),
                            {wait_trickle_ice, Session4};
                        false ->
                            gen_server:reply(From, {ok, Reply#{answer=>Answer}}),
                            {ok, ExtOps#{answer=>Answer}, Session3}
                    end;
                {error, Error, Session3} ->
                    {error, Error, Session3}
            end;
        {error, Error} ->
            {error, Error, Session}
    end.


%% @private
-spec do_start_offerer(type(), from(), session()) ->
    {ok, Reply::map(), ext_ops(), session()} |
    {error, nkservice:error(), session()}.

do_start_offerer(_Type, From, Session) ->
    case create_endpoint_offerer(Session) of
        {ok, #{trickle_ice:=OffTrickleIce}=Offer, Session2} ->
            SessTrickleIce = maps:get(trickle_ice, Session2, false),
            case OffTrickleIce andalso not SessTrickleIce of
                true ->
                    Info = #{
                        from => From,
                        offer => Offer
                    },
                    Update = #{nkmedia_kms_trickle_ice => Info},
                    Session3 = ?SESSION(Update, Session2),
                    {wait_trickle_ice, Session3};
                false ->
                    gen_server:reply(From, {ok, #{offer=>Offer}}),
                    {ok, #{offer=>Offer}, Session2}
            end;
        {error, Error} ->
            {error, Error, Session}
    end.


%% @private
-spec do_start_type(type(), session()) ->
    {ok, Reply::term(), ext_ops(), session()} |
    {error, nkservice:error(), session()}.

do_start_type(Type, Session) ->
    case check_record(Session, Session) of
        {ok, Session2} ->
            case do_type(Type, Session2, Session2) of
                {ok, Reply, ExtOps, Session3} ->
                    {ok, Reply, ExtOps, Session3};
                {error, Error} ->
                    {error, Error, Session2}
            end;
        {error, Error} ->
            {error, Error, Session}
    end.


%% @private
-spec do_type(atom(), map(), session()) ->
    {ok, Reply::map(), ext_ops(), session()} |
    {error, nkservice:error(), session()} | continue().

do_type(park, _Opts, Session) ->
    Session2 = reset_type(Session),
    {ok, Session3} = nkmedia_kms_session_lib:park(Session2),
    {ok, #{}, #{type=>park}, Session3};

do_type(echo, Opts, #{session_id:=SessId, nkmedia_kms_proxy:=Proxy}=Session) ->
    Session2 = reset_type(Session),
    % {ok, #{}, #{type=>echo}, Session2};
    ok = connect_to_proxy(Opts, Session2),
    case connect_from_peer(Proxy, Opts, Session2) of
        {ok, Session3} ->
            {ok, #{}, #{type=>echo}, Session3};
        {error, Error} ->
            {error, Error, Session2}
    end;

do_type(bridge, #{peer_id:=PeerId}=Opts, Session) ->
    #{session_id:=SessId, nkmedia_kms_proxy:=Proxy} = Session,
    Session2 = reset_type(Session),
    case session_call(PeerId, {bridge, SessId, Proxy, Opts}) of
        {ok, PeerProxy} ->
            case connect_from_peer(PeerProxy, Opts, Session2) of
                {ok, Session3} ->
                    Session4 = ?SESSION(#{nkmedia_kms_bridged_to=>PeerId}, Session3),
                    ExtOps = #{type=>bridge, type_ext=>#{peer_id=>PeerId}},
                    {ok, #{}, ExtOps, Session4};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error, Session2}
    end;

do_type(publish, Opts, #{session_id:=SessId}=Session) ->
    Session2 = reset_type(Session),
    case get_room(publish, Opts, Session) of
        {ok, RoomId} ->
            ok = connect_to_proxy(Opts, Session),
            Update = {started_publisher, SessId, #{pid=>self()}},
            %% TODO: Link with room
            {ok, _RoomPid} = nkmedia_room:update(RoomId, Update),
            Reply = #{room_id=>RoomId},
            ExtOps = #{type=>publish, type_ext=>#{room_id=>RoomId}},
            Session3 = ?SESSION(#{nkmedia_kms_publish_to=>RoomId}, Session2),
            {ok, Reply, ExtOps, Session3};
        {error, Error} ->
            {error, Error, Session2}
    end;

do_type(listen, #{publisher_id:=PeerId}=Opts, #{session_id:=SessId}=Session) ->
    Session2 = reset_type(Session),
    case get_room(listen, Opts, Session2) of
        {ok, RoomId} ->
            case connect_from_session(PeerId, Opts, Session2) of
                {ok, Session3} -> 
                    Update = {started_listener, SessId, #{peer_id=>PeerId, pid=>self()}},
                    %% TODO: Link with room
                    {ok, _RoomPid} = nkmedia_room:update(RoomId, Update),
                    Reply = #{room_id=>RoomId},
                    ExtOps = #{
                        type => listen, 
                        type_ext => #{room_id=>RoomId, publisher_id=>PeerId}
                    },
                    Session4 = ?SESSION(#{nkmedia_kms_listen_to=>RoomId}, Session3),
                    {ok, Reply, ExtOps, Session4};
                {error, Error} ->
                    {error, Error, Session2}
            end;
        {error, Error} ->
            {error, Error, Session2}
    end;

do_type(listen, _Opts, Session) ->
    lager:error("O: ~p", [_Opts]),
    {error, {missing_field, publisher_id}, Session};

do_type(connect, Opts, #{peer_id:=PeerId}=Session) ->
    case connect_from_session(PeerId, Opts, Session) of
        ok ->
            {ok, #{}, #{}, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

do_type(play, #{player_uri:=Uri}=Opts, Session) ->
    Session2 = reset_type(Session),
    case nkmedia_kms_session_lib:create_player(Uri, Opts, Session2) of
        {ok, Session3} ->
            Loops = maps:get(player_loops, Session, false),
            ExtOps = #{
                type=>play, 
                type_ext => #{player_uri=>Uri, player_loops=>Loops}
            },
            Session4 = ?SESSION(#{nkmedia_kms_player_loops=>Loops}, Session3),
            {ok, #{}, ExtOps, Session4};
        {error, Error} ->
            {error, Error, Session2}
    end;

% do_type(play, Session, Session) ->
%     {error, {missing_field, player_uri}, Session};

do_type(play, _Opts, Session) ->
    % Uri = <<"file:///tmp/1.webm">>,
    Uri = <<"http://files.kurento.org/video/format/sintel.webm">>,
    do_type(play, #{player_uri=>Uri, player_loops=>2}, Session);

do_type(_Op, _Opts, Session) ->
    {error, invalid_operation, Session}.


%% @private 
%% If we are starting a publisher or listener with an already started room
%% we must connect to the same pipeline
-spec get_pipeline(type(), session()) ->
    {ok, session()} | {error, term()}.

get_pipeline(publish, #{room_id:=RoomId}=Session) ->
    get_pipeline_from_room(RoomId, Session);

get_pipeline(listen, #{publisher_id:=PeerId}=Session) ->
    case get_peer_publisher(PeerId) of
        {ok, RoomId} ->
            Session2 = ?SESSION(#{room_id=>RoomId}, Session),
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
            Session2 = ?SESSION(#{nkmedia_kms_id=>KmsId}, Session),
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
-spec create_endpoint_offeree(nkmedia:offer(), session()) ->
    {ok, nkmedia:answer(), session()} | {error, nkservice:error()}.

create_endpoint_offeree(#{sdp_type:=rtp}=Offer, Session) ->
    nkmedia_kms_session_lib:create_rtp(Offer, Session);

create_endpoint_offeree(Offer, Session) ->
    nkmedia_kms_session_lib:create_webrtc(Offer, Session).


%% @private
-spec create_endpoint_offerer(session()) ->
    {ok, nkmedia:answer(), session()} | {error, nkservice:error()}.

create_endpoint_offerer(#{sdp_type:=rtp}=Session) ->
    nkmedia_kms_session_lib:create_rtp(#{}, Session);

create_endpoint_offerer(Session) ->
    nkmedia_kms_session_lib:create_webrtc(#{}, Session).


%% @private Adds or removed medias in the EP -> Proxy path
-spec check_record(map(), session()) ->
    {ok, session()} | {error, term()}.

check_record(Opts, Session) ->
    case Opts of
        #{record:=true} ->
            nkmedia_kms_session_lib:create_recorder(Opts, Session);
        #{record:=false} ->
            case nkmedia_kms_session_lib:recorder_op(stop, Session) of
                {ok, Session2} -> {ok, Session2};
                _ -> {ok, Session}
            end;
        _ ->
            {ok, Session}
    end.


%% @private
-spec reset_type(session()) ->
    {ok, session()} | {error, term()}.

reset_type(#{session_id:=SessId}=Session) ->
    case nkmedia_kms_session_lib:player_op(stop, Session) of
        {ok, Session2} -> ok;
        _ -> Session2 = Session
    end,
    case Session2 of
        #{nkmedia_kms_bridged_to:=PeerId} ->
            session_cast(PeerId, {bridge_stop, SessId}),
            Session3 = ?SESSION_RM(nkmedia_kms_bridged_to, Session2);
        _ ->
            Session3 = Session2
    end,
    case Session3 of
        #{nkmedia_kms_publish_to:=RoomId} ->
            Update = {stopped_publisher, SessId, #{}},
            nkmedia_room:update_async(RoomId, Update),
            Session4 = ?SESSION_RM(nkmedia_kms_publish_to, Session3);
        #{nkmedia_kms_listen_to:=RoomId} ->
            Update = {stopped_listener, SessId, #{}},
            nkmedia_room:update_async(RoomId, Update),
            Session4 = ?SESSION_RM(nkmedia_kms_listen_to, Session3);
        _ ->
            Session4 = Session3
    end,
    Session4.


%% @private
%% Connect Remote -> Endpoint
%% All medias will be included, except if "use_XXX=false" in Session
-spec connect_from_session(session_id(), map(), session()) ->
    {ok, session()} | {error, nkservice:error()}.

connect_from_session(PeerId, Opts, Session) ->
    case get_peer_proxy(PeerId, Session) of
        {ok, PeerProxy} ->
            connect_from_peer(PeerProxy, Opts, Session);
        {error, Error} ->
            {error, Error}
    end.


%% @private
%% Connect Remote -> Endpoint
%% All medias will be included, except if "use_XXX=false" in Session
-spec connect_from_peer(endpoint(), map(), session()) ->
    {ok, session()} | {error, nkservice:error()}.

connect_from_peer(PeerEP, Opts, Session) ->
    nkmedia_kms_session_lib:connect_from(PeerEP, Opts, Session).


%% @private EP -> Proxy
%% All medias will be included, except if "use_XXX=false" in Session
-spec connect_to_proxy(map(), session()) ->
    ok.

connect_to_proxy(Opts, Session) ->
    ok = nkmedia_kms_session_lib:connect_to_proxy(Opts, Session).


%% @private
-spec get_room(publish|listen, map(), session()) ->
    {ok, nkmedia_room:id()} | {error, term()}.

get_room(Type, Opts, #{srv_id:=SrvId, nkmedia_kms_id:=KmsId}=Session) ->
    case get_room_id(Type, Opts, Session) of
        {ok, RoomId} ->
            lager:error("get_room ROOM ID IS: ~p", [RoomId]),
            case nkmedia_room:get_room(RoomId) of
                {ok, #{nkmedia_kms:=#{kms_id:=KmsId}}} ->
                    lager:error("Room exists in same MS"),
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
-spec get_room_id(publish|listen, map(), session()) ->
    {ok, nkmedia_room:id()} | {error, term()}.

get_room_id(Type, Opts, _Session) ->
    case maps:find(room_id, Opts) of
        {ok, RoomId} -> 
            lager:error("Found room_id in Opts"),
            {ok, nklib_util:to_binary(RoomId)};
        error when Type==publish -> 
            {ok, nklib_util:uuid_4122()};
        error when Type==listen ->
            case Opts of
                #{publisher_id:=Publisher} ->
                    case get_peer_publisher(Publisher) of
                        {ok, RoomId} -> {ok, RoomId};
                        {error, _Error} -> {error, invalid_publisher}
                    end;
                _ ->
                    {error, {missing_field, publisher_id}}
            end
    end.


%% @private
-spec get_peer_proxy(session_id(), session()) ->
    {ok, endpoint()} | {error, nkservice:error()}.

get_peer_proxy(SessId, #{session_id:=SessId, nkmedia_kms_proxy:=Proxy}) ->
    {ok, Proxy};
get_peer_proxy(SessId, _Session) ->
    case session_call(SessId, get_proxy) of
        {ok, EP} -> {ok, EP};
        {error, Error} -> {error, Error}
    end.


%% @private
-spec get_peer_publisher(session_id()) ->
    {ok, nkmedia_room:id()} | {error, nkservice:error()}.

get_peer_publisher(SessId) ->
    session_call(SessId, get_publisher).


%% @private
session_call(SessId, Msg) ->
    nkmedia_session:do_call(SessId, {nkmedia_kms, Msg}).


%% @private
session_cast(SessId, Msg) ->
    nkmedia_session:do_cast(SessId, {nkmedia_kms, Msg}).



