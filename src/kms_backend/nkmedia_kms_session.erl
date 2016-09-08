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

-export([start/2, answer/3, candidate/2, cmd/3, stop/2]).
-export([handle_call/3, handle_cast/2]).


-export_type([session/0, type/0, opts/0, cmd/0]).

-define(LLOG(Type, Txt, Args, Session),
    lager:Type("NkMEDIA KMS Session ~s "++Txt, 
               [maps:get(session_id, Session) | Args])).

-include_lib("nksip/include/nksip.hrl").
-include("../../include/nkmedia.hrl").



%% ===================================================================
%% Types
%% ===================================================================

-type session_id() :: nkmedia_session:id().
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
        nkmedia_kms_role => offerer | offeree,
        nkmedia_kms_source => endpoint(),
        nkmedia_kms_recorder => endpoint(),
        nkmedia_kms_player => endpoint(),
        nkmedia_kms_bridged_to => session_id(),
        nkmedia_kms_publish_to => nkmedia_room:id(),
        nkmedia_kms_listen_to => nkmedia_room:id()
    }.


-type type() ::
    nkmedia_session:type() |
    echo     |
    proxy    |
    publish  |
    listen   |
    play     |
    connect.

-type cmd() :: atom().

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
-spec start(nkmedia_session:type(), session()) ->
    {ok, session()} |
    {error, nkservice:error(), session()} | continue().

start(Type, Session) -> 
    case is_supported(Type) of
        true ->
            Session2 = ?SESSION(#{backend=>nkmedia_kms}, Session),
            case get_pipeline(Type, Session2) of
                {ok, Session3} ->
                    case nkmedia_kms_session_lib:create_proxy(Session3) of
                        {ok, #{offer:=Offer}=Session4} ->
                            start_offeree(Type, Offer, Session4);
                        {ok, Session4} ->
                            start_offerer(Type, Session4);
                        {error, Error} ->
                            {error, Error, Session3}
                    end;
                {error, Error} ->
                    {error, Error, Session2}
            end;
        false ->
            continue
    end.


%% @private
-spec answer(type(), nkmedia:answer(), session()) ->
    {ok, session()} | {error, nkservice:error(), session()}.

answer(Type, Answer, Session) ->
    case nkmedia_kms_session_lib:set_answer(Answer, Session) of
        ok ->
            do_start_type(Type, Session);
        {error, Error} ->
            {error, Error, Session}
    end.


%% @private We received a candidate from the client
-spec candidate(nkmedia:candidate(), session()) ->
    {ok, session()} | continue.

candidate(#candidate{last=true}, Session) ->
    {ok, Session};

candidate(Candidate, Session) ->
    nkmedia_kms_session_lib:add_ice_candidate(Candidate, Session),
    {ok, Session}.


%% @private
-spec cmd(cmd(), Opts::map(), session()) ->
    {ok, Reply::term(), session()} | {error, term(), session()} | continue().

cmd(session_type, #{session_type:=Type}=Opts, Session) ->
    case check_record(Opts, Session) of
        {ok, Session2} ->
            case do_type(Type, Opts, Session2) of
                {ok, TypeExt, Session3} -> 
                    update_type(Type, TypeExt),
                    {ok, TypeExt, Session3};
                {error, Error, Session3} ->
                    {error, Error, Session3}
            end;
        {error, Error} ->
            {error, Error, Session}
    end;

cmd(connect, Opts, Session) ->
    do_type(connect, Opts, Session);
   
%% Updates media in EP -> Proxy path only (to "mute")
cmd(media, Opts, Session) ->
    case check_record(Opts, Session) of
        {ok, Session2} ->
            ok = nkmedia_kms_session_lib:update_media(Opts, Session),
            {ok, #{}, Session2};
        {error, Error} ->
            {error, Error, Session}
    end;

cmd(recorder, #{operation:=Op}, Session) ->
    case nkmedia_kms_session_lib:recorder_op(Op, Session) of
        {ok, Session2} ->
            {ok, #{}, Session2};
        {error, Error} ->
            {error, Error, Session}
    end;

cmd(recorder, _Opts, Session) ->
    {error, {missing_parameter, operation}, Session};

cmd(player, #{operation:=Op}, Session) ->
    nkmedia_kms_session_lib:player_op(Op, Session);

cmd(get_stats, Opts, Session) ->
    Type1 = maps:get(media_type, Opts, <<"VIDEO">>),
    Type2 = nklib_util:to_upper(Type1),
    case nkmedia_kms_session_lib:get_stats(Type2, Session) of
        {ok, Stats} ->
            {ok, #{stats=>Stats}, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

cmd(print_info, _Opts, #{session_id:=SessId}=Session) ->
    nkmedia_kms_session_lib:print_info(SessId, Session),
    {ok, #{}, Session};

cmd(_Update, _Opts, _Session) ->
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
            update_type(bridge, #{peer_id=>PeerSessId}),
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
handle_cast(#candidate{}=Candidate, #{backend_role:=Role}=Session) ->
    Type = case Role of
        offerer -> offer;
        offeree -> answer
    end,
    nkmedia_session:candidate(self(), Candidate#candidate{type=Type}),
    {noreply, Session};

handle_cast({bridge_stop, PeerId}, #{nkmedia_kms_bridged_to:=PeerId}=Session) ->
    case nkmedia_session:bridge_stop(PeerId, Session) of
        {ok, Session2} ->
            Session3 = reset_type(Session2),
            % In case we were linked
            nkmedia_session:unlink_session(self(), PeerId),
            update_type(park, #{}),
            {noreply, Session3};
        {stop, Session2} ->
            nkmedia_session:stop(self(), bridge_stop),
            {noreply, Session2}
    end;

handle_cast({bridge_stop, PeerId}, Session) ->
    ?LLOG(notice, "ignoring bridge stop from ~s", [PeerId], Session),
    {noreply, Session};

handle_cast({end_of_stream, Player}, #{nkmedia_kms_player:=Player}=Session) ->
    case Session of
        #{player_loops:=true} ->
            nkmedia_kms_session_lib:player_op(resume, Session),
            {noreply, Session};
        #{player_loops:=Loops} when is_integer(Loops), Loops > 1 ->
            nkmedia_kms_session_lib:player_op(resume, Session),
            {noreply, ?SESSION(#{player_loops=>Loops-1}, Session)};
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
-spec start_offerer(type(), session()) ->
    {ok, session()} |
    {error, nkservice:error(), session()} | continue().

%% We must make the offer
start_offerer(_Type, Session) ->
    case create_endpoint_offerer(Session) of
        {ok, Session2} ->
            {ok, Session2};
        {error, Error} ->
            {error, Error, Session}
    end.


%% @private
-spec start_offeree(type(), nkmedia:offer(), session()) ->
    {ok, session()} |
    {error, nkservice:error(), session()} | continue().

start_offeree(Type, Offer, Session) ->
    case create_endpoint_offeree(Offer, Session) of
        {ok, Session2} ->
            do_start_type(Type, Session2);
        {error, Error} ->
            {error, Error, Session}
    end.


%% @private
-spec do_start_type(type(), session()) ->
    {ok, session()} | {error, nkservice:error(), session()}.

do_start_type(Type, Session) ->
    case check_record(Session, Session) of
        {ok, Session2} ->
            case do_type(Type, Session2, Session2) of
                {ok, TypeExt, Session3} ->                    
                    update_type(Type, TypeExt),
                    {ok, Session3};
                {error, Error, Session3} ->
                    {error, Error, Session3}
            end;
        {error, Error} ->
            {error, Error, Session}
    end.


%% @private
-spec do_type(atom(), map(), session()) ->
    {ok, nkmedia_session:type_ext(), session()} |
    {error, nkservice:error(), session()}.

do_type(park, _Opts, Session) ->
    Session2 = reset_type(Session),
    {ok, Session3} = nkmedia_kms_session_lib:park(Session2),
    {ok, #{}, Session3};

do_type(echo, Opts, #{nkmedia_kms_proxy:=Proxy}=Session) ->
    Session2 = reset_type(Session),
    ok = connect_to_proxy(Opts, Session2),
    case connect_from_peer(Proxy, Opts, Session2) of
        {ok, Session3} ->
            {ok, #{}, Session3};
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
                    {ok, #{peer_id=>PeerId}, Session4};
                {error, Error} ->
                    {error, Error, Session2}
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
            Session3 = ?SESSION(#{nkmedia_kms_publish_to=>RoomId}, Session2),
            {ok, #{room_id=>RoomId}, Session3};
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
                    TypeExt = #{room_id=>RoomId, publisher_id=>PeerId},
                    Session4 = ?SESSION(#{nkmedia_kms_listen_to=>RoomId}, Session3),
                    {ok, TypeExt, Session4};
                {error, Error} ->
                    {error, Error, Session2}
            end;
        {error, Error} ->
            {error, Error, Session2}
    end;

do_type(listen, _Opts, Session) ->
    {error, {missing_field, publisher_id}, Session};

do_type(connect, Opts, #{peer_id:=PeerId}=Session) ->
    case connect_from_session(PeerId, Opts, Session) of
        ok ->
            {ok, #{}, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

do_type(play, #{player_uri:=Uri}=Opts, Session) ->
    Session2 = reset_type(Session),
    case nkmedia_kms_session_lib:create_player(Uri, Opts, Session2) of
        {ok, Session3} ->
            Loops = maps:get(player_loops, Opts, false),
            TypeExt = #{player_uri=>Uri, player_loops=>Loops},
            Session4 = ?SESSION(#{player_loops=>Loops}, Session3),
            {ok, TypeExt, Session4};
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
            ?LLOG(info, "getting engine from ROOM: ~s", [KmsId], Session),
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
    {ok, session()} | {error, nkservice:error()}.

create_endpoint_offeree(#{sdp_type:=rtp}=Offer, Session) ->
    nkmedia_kms_session_lib:create_rtp(Offer, Session);

create_endpoint_offeree(Offer, Session) ->
    nkmedia_kms_session_lib:create_webrtc(Offer, Session).


%% @private
-spec create_endpoint_offerer(session()) ->
    {ok, session()} | {error, nkservice:error()}.

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
            % In case we were linked
            nkmedia_session:unlink_session(self(), PeerId),
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
update_type(Type, TypeExt) ->
    nkmedia_session:set_type(self(), Type, TypeExt).


%% @private
session_call(SessId, Msg) ->
    nkmedia_session:do_call(SessId, {nkmedia_kms, Msg}).


%% @private
session_cast(SessId, Msg) ->
    nkmedia_session:do_cast(SessId, {nkmedia_kms, Msg}).



