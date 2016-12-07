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

-export([start/3, offer/4, answer/4, candidate/2, cmd/3, stop/2]).
-export([handle_call/3, handle_cast/2]).


-export_type([session/0, type/0, opts/0, cmd/0]).

-define(DEBUG(Txt, Args, State),
    case erlang:get(nkmedia_session_debug) of
        true -> ?LLOG(debug, Txt, Args, State);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args, Session),
    lager:Type(
        [
            {media_session_id, maps:get(session_id, Session)},
            {user_id, maps:get(user_id, Session)},
            {session_id, maps:get(user_session, Session)}
        ],
        "NkMEDIA KMS Session ~s (~s) "++Txt, 
        [maps:get(session_id, Session), maps:get(type, Session) | Args])).

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
        nkmedia_kms_source => endpoint(),
        nkmedia_kms_recorder => endpoint(),
        nkmedia_kms_player => endpoint()
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
-spec start(nkmedia_session:type(), nkmedia:role(), session()) ->
    {ok, session()} |
    {error, nkservice:error(), session()} | continue().

start(Type, Role, Session) -> 
    case is_supported(Type) of
        true ->
            Session2 = ?SESSION(#{backend=>nkmedia_kms}, Session),
            case get_pipeline(Type, Session2) of
                {ok, Session3} ->
                    case nkmedia_kms_session_lib:create_proxy(Session3) of
                        {ok, Session4} when Role==offeree ->
                            % Wait for the offer (it could has been updated by a callback)
                            {ok, Session4};
                        {ok, Session4} when Role==offerer ->
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


%% @private Someone set the offer
-spec offer(type(), nkmedia:role(), nkmedia:offer(), session()) ->
    {ok, session()} | {error, nkservice:error(), session()} | continue.

offer(_Type, offerer, _Offer, _Session) ->
    % We generated the offer
    continue;

offer(Type, offeree, Offer, Session) ->
    case start_offeree(Type, Offer, Session) of
        {ok, Session2} ->
            {ok, Offer, Session2};
        {error, Error, Session2} ->
            {error, Error, Session2}
    end.


%% @private We generated the offer, let's process the answer
-spec answer(type(), nkmedia:role(), nkmedia:answer(), session()) ->
    {ok, session()} | {error, nkservice:error(), session()}.

answer(_Type, offeree, _Answer, _Session) ->
    % We generated the answer
    continue;

answer(Type, offerer, Answer, Session) ->
    case nkmedia_kms_session_lib:set_answer(Answer, Session) of
        ok ->
            case do_start_type(Type, Session) of
                {ok, Session2} ->
                    {ok, Answer, Session2};
                {error, Error, Session2} ->
                    {error, Error, Session2}
            end;
        {error, Error} ->
            {error, Error, Session}
    end.


%% @private We received a candidate for the backend
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

cmd(set_type, #{type:=Type}=Opts, Session) ->
    case do_type(Type, Opts, Session) of
        {ok, TypeExt, Session2} -> 
            update_type(Type, TypeExt),
            {ok, TypeExt, Session2};
        {error, Error, Session3} ->
            {error, Error, Session3}
    end;

cmd(set_type, _Opts, Session) ->
    {error, {missing_field, type}, Session};

cmd(recorder_action, Opts, Session) ->
    Action = maps:get(action, Opts, get_actions),
    nkmedia_kms_session_lib:recorder_op(Action, Opts, Session);

cmd(player_action, Opts, Session) ->
    case maps:get(action, Opts, get_actions) of
        start ->
            cmd(set_type, Opts#{type=>play}, Session);
        Action ->
            nkmedia_kms_session_lib:player_op(Action, Opts, Session)
    end;

cmd(connect, Opts, Session) ->
    do_type(connect, Opts, Session);
   
%% Updates media in EP -> Proxy path only (to "mute")
cmd(update_media, Opts, Session) ->
    ok = nkmedia_kms_session_lib:update_media(Opts, Session),
    {ok, #{}, Session};

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

cmd(_Update, _Opts, Session) ->
    lager:error("A: ~p", [_Update]),
    {error, not_implemented, Session}.


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
    ok = connect_to_proxy(Opts, Session),
    case connect_from_peer(PeerProxy, Session) of
        {ok, Session2} ->
            ?DEBUG("remote connect ~s to us", [PeerProxy], Session),
            update_type(bridge, #{peer_id=>PeerSessId}),
            {reply, {ok, Proxy}, Session2};
        {error, Error} ->
            {reply, {error, Error}, Session}
    end;

handle_call(get_room_id, _From, #{type_ext:=#{room_id:=RoomId}}=Session) ->
    {reply, {ok, RoomId}, Session};

handle_call(get_room, _From, Session) ->
    {reply, {error, not_publishing}, Session}.

 
%% @private
handle_cast({bridge_stop, PeerId}, 
            #{type:=bridge, type_ext:=#{peer_id:=PeerId}}=Session) ->
    ?DEBUG("received bridge stop from ~s", [PeerId], Session),
    case Session of
        #{stop_after_peer:=false} ->
            Session2 = reset_type(Session),
            % In case we were linked
            nkmedia_session:unlink_session(self(), PeerId),
            update_type(park, #{}),
            {ok, Session3} = nkmedia_kms_session_lib:park(Session2),
            {noreply, Session3};
        _ ->
            nkmedia_session:stop(self(), bridge_stop),
            {noreply, Session}
    end;

handle_cast({bridge_stop, PeerId}, Session) ->
    ?LLOG(info, "ignoring bridge stop from ~s", [PeerId], Session),
    {noreply, Session};

handle_cast({end_of_stream, Player}, 
            #{nkmedia_kms_player:=Player, type_ext:=Ext}=Session) ->
    case Ext of
        #{loops:=0} ->
            case nkmedia_kms_session_lib:player_op(resume, #{}, Session) of
                {ok, _, Session2} -> ok;
                {error, Session2} -> ok
            end,
            {noreply, Session2};
        #{loops:=Loops} when is_integer(Loops), Loops > 1 ->
            case nkmedia_kms_session_lib:player_op(resume, #{}, Session) of
                {ok, _, Session2} -> ok;
                {error, Session2} -> ok
            end,
            update_type(play, Ext#{loops=>Loops-1}),
            {noreply, Session2};
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
    case do_type(Type, Session, Session) of
        {ok, TypeExt, Session2} ->                    
            update_type(Type, TypeExt),
            {ok, Session2};
        {error, Error, Session3} ->
            {error, Error, Session3}
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
    case connect_from_peer(Proxy, Session2) of
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
            ok = connect_to_proxy(Opts, Session2),
            ?DEBUG("connecting from ~s", [PeerProxy], Session),
            case connect_from_peer(PeerProxy, Session2) of
                {ok, Session3} ->
                    {ok, #{peer_id=>PeerId}, Session3};
                {error, Error} ->
                    {error, Error, Session2}
            end;
        {error, Error} ->
            {error, Error, Session2}
    end;

do_type(bridge, _Opts, Session) ->
    {error, {missing_field, peer_id}, Session};

do_type(publish, #{room_id:=RoomId}=Opts, Session) ->
    Session2 = reset_type(Session),
    case nkmedia_room:get_room(RoomId) of
        {ok, _Room} ->
            ok = connect_to_proxy(Opts, Session),
            notify_publisher(RoomId, Session),
            {ok, #{room_id=>RoomId}, Session2};
        {error, _Error} ->
            {error, room_not_found, Session2}
    end;

do_type(listen, #{publisher_id:=PeerId}, Session) ->
    Session2 = reset_type(Session),
    case session_call(PeerId, get_room_id) of
        {ok, RoomId} -> 
            case connect_from_session(PeerId, Session2) of
                {ok, Session3} -> 
                    notify_listener(RoomId, PeerId, Session3),
                    TypeExt = #{room_id=>RoomId, publisher_id=>PeerId},
                    {ok, TypeExt, Session3};
                {error, Error} ->
                    {error, Error, Session2}
            end;
        {error, Error} ->
            {error, Error, Session2}
    end;

do_type(listen, _Opts, Session) ->
    {error, {missing_field, publisher_id}, Session};

do_type(connect, _Opts, #{peer_id:=PeerId}=Session) ->
    case connect_from_session(PeerId, Session) of
        ok ->
            {ok, #{}, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

do_type(play, Opts, Session) ->
    Session2 = reset_type(Session),
    case nkmedia_kms_session_lib:player_op(start, Opts, Session2) of
        {ok, Info, Session3} ->
            Loops = maps:get(loops, Opts, 0),
            TypeExt = Info#{loops=>Loops},
            {ok, TypeExt, Session3};
        {error, Error, Session3} ->
            {error, Error, Session3}
    end;

do_type(_Op, _Opts, Session) ->
    {error, not_implemented, Session}.


%% @private 
%% If we are starting a publisher or listener with an already started room
%% we must connect to the same pipeline
-spec get_pipeline(type(), session()) ->
    {ok, session()} | {error, term()}.

get_pipeline(publish, #{room_id:=RoomId}=Session) ->
    get_pipeline_from_room(RoomId, Session);

get_pipeline(listen, #{publisher_id:=PeerId}=Session) ->
    case session_call(PeerId, get_room_id) of
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
            ?DEBUG("getting engine from ROOM: ~s", [KmsId], Session),
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


%% @private
%% Must set new type after calling this
-spec reset_type(session()) ->
    {ok, session()} | {error, term()}.

reset_type(#{session_id:=SessId}=Session) ->
    case nkmedia_kms_session_lib:player_op(stop, #{}, Session) of
        {ok, _, Session2} -> ok;
        {error, _, Session2} -> ok
    end,
    case Session2 of
        #{type:=bridge, type_ext:=#{peer_id:=PeerId}} ->
            ?DEBUG("sending bridge stop to ~s", [PeerId], Session),
            % In case we were linked
            nkmedia_session:unlink_session(self(), PeerId),
            session_cast(PeerId, {bridge_stop, SessId});
        _ ->
            ok
    end,
    case Session2 of
        #{type:=publish, type_ext:=#{room_id:=RoomId}} ->
            nkmedia_room:stopped_member(RoomId, SessId);
        #{type:=listen, type_ext:=#{room_id:=RoomId}} ->
            nkmedia_room:stopped_member(RoomId, SessId);
        _ ->
            ok
    end,
    Session2.


%% @private
%% Connect Remote Proxy -> Endpoint
%% See connect_from_peer
-spec connect_from_session(session_id(), session()) ->
    {ok, session()} | {error, nkservice:error()}.

connect_from_session(PeerId, Session) ->
    case get_peer_proxy(PeerId, Session) of
        {ok, PeerProxy} ->
            connect_from_peer(PeerProxy, Session);
        {error, Error} ->
            {error, Error}
    end.


%% @private
%% Connect Remote Proxy -> Endpoint
%% We connect audio, video and data always.
%% If we don't want to receive something, must 'mute' on oring
-spec connect_from_peer(endpoint(), session()) ->
    {ok, session()} | {error, nkservice:error()}.

connect_from_peer(Peer, Session) ->
    nkmedia_kms_session_lib:connect_from(Peer, all, Session).


%% @private Connect EP -> Proxy
%% All medias will be included, except if "mute_XXX=false" in Opts
-spec connect_to_proxy(map(), session()) ->
    ok.

connect_to_proxy(Opts, Session) ->
    ok = nkmedia_kms_session_lib:connect_to_proxy(Opts, Session).


%% @private
notify_publisher(RoomId, #{session_id:=SessId}=Session) ->
    UserId = maps:get(user_id, Session, <<>>),
    Info = #{role => publisher, user_id => UserId},
    case nkmedia_room:started_member(RoomId, SessId, Info, self()) of
        ok ->
            ok;
        {error, Error} ->
            ?LLOG(notice, "room publish error: ~p", [Error], Session)
    end.


%% @private
notify_listener(RoomId, PeerId, #{session_id:=SessId}=Session) ->
    UserId = maps:get(user_id, Session, <<>>),
    Info = #{role => listener, user_id => UserId, peer_id => PeerId},
    case nkmedia_room:started_member(RoomId, SessId, Info, self()) of
        ok ->
            ok;
        {error, Error} ->
            ?LLOG(notice, "room publish error: ~p", [Error], Session)
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


% %% @private
% -spec get_peer_room(session_id()) ->
%     {ok, nkmedia_room:id()} | {error, nkservice:error()}.

% get_peer_room(SessId) ->
%     session_call(SessId, get_room).


%% @private
update_type(Type, TypeExt) ->
    nkmedia_session:set_type(self(), Type, TypeExt).


%% @private
session_call(SessId, Msg) ->
    nkmedia_session:do_call(SessId, {nkmedia_kms, Msg}).


%% @private
session_cast(SessId, Msg) ->
    nkmedia_session:do_cast(SessId, {nkmedia_kms, Msg}).



