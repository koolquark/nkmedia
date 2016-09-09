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
%% For each operation, starts and monitors a new nkmedia_janus_op process

-module(nkmedia_janus_session).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/2, offer/3, answer/3, candidate/2, peer_candidate/2, cmd/3, stop/2]).
-export([handle_call/3, handle_cast/2]).

-export_type([session/0, type/0, opts/0, cmd/0]).

-define(LLOG(Type, Txt, Args, Session),
    lager:Type("NkMEDIA JANUS Session ~s (~s)"++Txt, 
               [maps:get(session_id, Session), maps:get(type, Session) | Args])).

-define(DEFAULT_MEDIA, #{use_audio=>true, use_video=>true, bitrate=>500000}).


-include_lib("nksip/include/nksip.hrl").
-include("../../include/nkmedia.hrl").



%% ===================================================================
%% Types
%% ===================================================================

-type continue() :: continue | {continue, list()}.


-type session() :: 
    nkmedia_session:session() |
    #{
        nkmedia_janus_id => nkmedia_janus_engine:id(),
        nkmedia_janus_pid => pid(),
        nkmedia_janus_mon => reference(),
        nkmedia_janus_proxy_offer => nkmedia:offer()
    }.


-type type() ::
    nkmedia_session:type() |
    echo     |
    proxy    |
    publish  |
    listen   |
    bridge   |
    play.


-type opts() ::
    nkmedia_session:session() |
    #{
    }.


-type cmd() ::
    nkmedia_session:cmd() |
    {listener_switch, binary()}.




%% ===================================================================
%% Callbacks
%% ===================================================================



%% @private
-spec start(nkmedia_session:type(), session()) ->
    {ok, session()} |
    {error, nkservice:error(), session()} | continue().


%% Special case as 'B' leg of a proxy
start(bridge, #{backend_role:=offerer, master_peer:=MasterId}=Session) -> 
    case nkmedia_session:cmd(MasterId, get_proxy_offer, #{}) of
        {ok, #{janus_id:=Id, offer:=Offer}} ->
            Update = #{backend=>nkmedia_janus, nkmedia_janus_id=>Id},
            Session2 = ?SESSION(Update, Session),
            lager:error("BRIDGE SESSION SET OFFER"),
            {ok, set_offer(Offer, Session2)};
        {error, Error} ->
            {error, Error, Session}
    end;

start(Type, Session) -> 
    case is_supported(Type) of
        true ->
            Session2 = ?SESSION(#{backend=>nkmedia_janus}, Session),
            case get_mediaserver(Session2) of
                {ok, Session3} ->
                    case get_janus_op(Session3) of
                        {ok, #{backend_role:=offeree}=Session4} ->
                            % Wait for the offer
                            {ok, Session4};
                        {ok, #{backend_role:=offerer}=Session4} ->
                            start_offerer(Type, Session4);
                        {error, Error} ->
                            {error, Error, Session2}
                    end;
                {error, Error} ->
                    {error, Error, Session2}
            end;
        false ->
            continue
    end.


%% @private Someone set the offer
-spec offer(type(), nkmedia:offer(), session()) ->
    {ok, session()} | {error, nkservice:error(), session()} | continue.

offer(_Type, _Offer, #{backend_role:=offerer}) ->
    % We generated the offer
    continue;

offer(Type, Offer, Session) ->
    case start_offeree(Type, Offer, Session) of
        {ok, Session2} ->
            {ok, Offer, Session2};
        {error, Error, Session2} ->
            {error, Error, Session2}
    end.



%% @private Someone set the answer
-spec answer(type(), nkmedia:answer(), session()) ->
    {ok, session()} | {error, nkservice:error(), session()} | continue.

answer(bridge, Answer, Session) ->
    lager:error("CALLER SET ANSWER B"),
    % We are the 'B' side of the proxy, do nothing because the answer will be sent
    % to the master automatically
    {ok, Answer, Session};

answer(proxy, Answer, #{backend_role:=offeree, nkmedia_janus_pid:=Pid}=Session) ->
    % We are the 'A' side of the proxy
    lager:error("CALLER SET ANSWER A"),
    case nkmedia_janus_op:answer(Pid, Answer) of
        {ok, Answer2} ->
            {ok, Answer2, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

answer(listen, Answer, #{nkmedia_janus_pid:=Pid}=Session) ->
    case nkmedia_janus_op:answer(Pid, Answer) of
        ok ->
            {ok, Answer, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

% For other types, do nothing special
answer(_Type, _Answer, _Session) ->
    lager:error("ANS: ~p", [_Type]),
    continue.



%% @private We received a candidate from the client to the backend
-spec candidate(nkmedia:candidate(), session()) ->
    {ok, session()} | continue.

candidate(Candidate, #{nkmedia_janus_pid:=Pid}=Session) ->
    nkmedia_janus_op:candidate(Pid, Candidate),
    {ok, Session}.


%% @private
-spec peer_candidate(nkmedia:candidate(), session()) ->
    {ok, session()} | continue.

peer_candidate(#candidate{type=Type}=Candidate, #{type:=bridge}=Session) ->
    case Session of
        #{backend_role:=offerer, slave_peer:=_, nkmedia_janus_pid:=Pid} ->
            case Type of
                offer ->
                    nkmedia_janus_op:candidate(Pid, Candidate);
                answer ->
                    ?LLOG(error, "received answer peer candidate in offerer", 
                          [], Session)
            end;
        #{backend_role:=offeree, master_peer:=MasterId} ->
            case Type of
                answer ->
                    session_cast(MasterId, {proxy_candidate, Candidate});
                offer ->
                    ?LLOG(error, "received offer peer candidate in offeree", 
                          [], Session)
            end
    end,
    {ok, Session};

peer_candidate(_Candidate, _Session) ->
    continue.


%% @private
-spec cmd(cmd(), Opts::map(), session()) ->
    {ok, Reply::term(), session()} | {error, term(), session()} | continue().

% cmd(media, Opts, #{type:=callee}=Session) ->
%     case set_media_callee(Opts, Session) of
%         {ok, Session2} ->
%             {ok, #{}, Session2};
%         {error, Error, Session2} ->
%             {error, Error, Session2}
%     end;

cmd(media, Opts, #{type:=Type}=Session) when Type==echo; Type==proxy; Type==publish ->
    case set_media(Opts, Session) of
        {ok, Session2} ->
            {ok, #{}, Session2};
        {error, Error, Session2} ->
            {error, Error, Session2}
    end;

cmd(listen_switch, #{publisher_id:=Publisher}, #{type:=listen}=Session) ->
    #{nkmedia_janus_pid:=Pid, type_ext:=#{room_id:=RoomId}=Ext} = Session,
    case nkmedia_janus_op:listen_switch(Pid, Publisher, #{}) of
        ok ->
            notify_listener(RoomId, Publisher, Session),
            update_type(listen, Ext#{publisher_id=>Publisher}),
            {ok, #{}, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

cmd(get_proxy_offer, _, Session) ->
    case Session of
        #{nkmedia_janus_id:=Id, nkmedia_janus_proxy_offer:=Offer} ->
            {ok, #{janus_id=>Id, offer=>Offer}, Session};
        _ ->
            {error, invalid_session, Session}
    end;

cmd(_Update, _Opts, _Session) ->
    continue.


%% @private
-spec stop(nkservice:error(), session()) ->
    {ok, session()}.

stop(_Reason, #{session_id:=SessId}=Session) ->
    case Session of
        #{type:=publish, type_ext:=#{room_id:=RoomId}} ->
            Event = {stopped_publisher, SessId, #{}},
            nkmedia_room:update(RoomId, Event);
        #{type:=listen, type_ext:=#{room_id:=RoomId}} ->
            Event = {stopped_listener, SessId, #{}},
            nkmedia_room:update(RoomId, Event);
        _ ->
            ok
    end,
    {ok, Session}.


%% @private
handle_call(get_publisher, _From, #{type:=publish}=Session) ->
    #{type_ext:=#{room_id:=RoomId}} = Session,
    {reply, {ok, RoomId}, Session};

handle_call(get_publisher, _From, Session) ->
    {reply, {error, invalid_publisher}, Session}.


%% @private
handle_cast({proxy_candidate, Candidate}, #{nkmedia_janus_pid:=Pid}=Session) ->
    nkmedia_janus_op:candidate_callee(Pid, Candidate),
    {ok, Session}.



%% ===================================================================
%% Internal
%% ===================================================================


%% @private
is_supported(echo) -> true;
is_supported(proxy) -> true;
is_supported(publish) -> true;
is_supported(listen) -> true;
is_supported(_) -> false.


%% @private We must make the offer
-spec start_offerer(type(), session()) ->
    {ok, session()} |
    {error, nkservice:error(), session()} | continue().

%% We are the 'B' leg of the proxy
start_offerer(listen, #{publisher_id:=Publisher, nkmedia_janus_pid:=Pid}=Session) ->
    case get_room(listen, Session) of
        {ok, RoomId} ->
            case nkmedia_janus_op:listen(Pid, RoomId, Publisher, #{}) of
                {ok, Offer} ->
                    notify_listener(RoomId, Publisher, Session),
                    update_type(listen, #{room_id=>RoomId, publisher_id=>Publisher}),
                    {ok, set_offer(Offer, Session)};
                {error, Error} ->
                    {error, Error, Session}
            end;
        {error, Error} ->
            {error, Error, Session}
    end;

start_offerer(listen, Session) ->
    {error, {missing_field, publisher_id}, Session};

start_offerer(_, Session) ->
    {error, invalid_operation, Session}.



%% @private
-spec start_offeree(type(), nkmedia:offer(), session()) ->
    {ok, session()} |
    {error, nkservice:error(), session()} | continue().

start_offeree(echo, Offer, #{nkmedia_janus_pid:=Pid}=Session) ->
    % io:format("OFF:\n~s", [maps:get(sdp, Offer)]),
    case nkmedia_janus_op:echo(Pid, Offer) of
        {ok, Answer} ->
            % io:format("ANS:\n~s", [maps:get(sdp, Answer)]),
            set_media(set_answer(Answer, Session));
        {error, Error} ->
            {error, Error, Session}
    end;

start_offeree(proxy, Offer, #{nkmedia_janus_pid:=Pid}=Session) ->
    OfferType = maps:get(sdp_type, Offer, webrtc),
    OutType = maps:get(sdp_type, Session, webrtc),
    Fun = case {OfferType, OutType} of
        {webrtc, webrtc} -> videocall;
        {webrtc, rtp} -> to_sip;
        {rtp, webrtc} -> from_sip;
        {rtp, rtp} -> error
    end,
    case Fun of
        error ->
            {error, invalid_parameters, Session};
        _ ->
            case nkmedia_janus_op:Fun(Pid, Offer) of
                {ok, Offer2} ->
                    Session2 = ?SESSION(#{nkmedia_janus_proxy_offer=>Offer2}, Session),
                    set_media(Session2);
                {error, Error} ->
                    {error, Error, Session}
            end
    end;

start_offeree(publish, Offer, #{nkmedia_janus_pid:=Pid}=Session) ->
    case get_room(publish, Session) of
        {ok, RoomId} ->
            case nkmedia_janus_op:publish(Pid, RoomId, Offer, #{}) of
                {ok, Answer} ->
                    notify_publisher(RoomId, Session),
                    update_type(publish, #{room_id=>RoomId}),
                    Media = maps:merge(?DEFAULT_MEDIA, Session),
                    set_media(Media, set_answer(Answer, Session));
                {error, Error} ->
                    {error, Error, Session}
            end;
        {error, Error} ->
            {error, Error, Session}
    end;

start_offeree(callee, _Offer, Session) ->
    {ok, Session};

start_offeree(_Type, _Offer, _Session) ->
    continue.


%% @private
get_janus_op(#{nkmedia_janus_id:=JanusId, session_id:=SessId}=Session) ->
    case nkmedia_janus_op:start(JanusId, SessId) of
        {ok, Pid} ->
            Session2 = Session#{
                nkmedia_janus_pid => Pid,
                nkmedia_janus_mon => monitor(process, Pid)
            },
            {ok, Session2};
        {error, Error} ->
            ?LLOG(warning, "janus connection start error: ~p", [Error], Session),
            {error, janus_connection_error}
    end.


%% @private
-spec get_mediaserver(session()) ->
    {ok, session()} | {error, term()}.

get_mediaserver(#{nkmedia_janus_id:=_}=Session) ->
    {ok, Session};

get_mediaserver(#{srv_id:=SrvId}=Session) ->
    case SrvId:nkmedia_janus_get_mediaserver(SrvId) of
        {ok, Id} ->
            {ok, Session#{nkmedia_janus_id=>Id}};
        {error, Error} ->
            {error, Error}
    end.


%% @private
-spec get_room(publish|listen, session()) ->
    {ok, nkmedia_room:id()} | {error, term()}.

get_room(Type, #{srv_id:=SrvId, nkmedia_janus_id:=JanusId}=Session) ->
    case get_room_id(Type, Session) of
        {ok, RoomId} ->
            case nkmedia_room:get_room(RoomId) of
                {ok, #{nkmedia_janus:=#{janus_id:=JanusId}}} ->
                    % lager:error("Room exists in same Janus"),
                    {ok, RoomId};
                {ok, _O} ->
                    {error, different_mediaserver};
                {error, room_not_found} ->
                    Opts1 = [
                        {room_id, RoomId},
                        {backend, nkmedia_janus},
                        {nkmedia_janus, JanusId},
                        case maps:find(room_audio_codec, Session) of
                            {ok, AC} -> {audio_codec, AC};
                            error -> []
                        end,
                        case maps:find(room_video_codec, Session) of
                            {ok, VC} -> {video_codec, VC};
                            error -> []
                        end,
                        case maps:find(room_bitrate, Session) of
                            {ok, BR} -> {bitrate, BR};
                            error -> []
                        end
                    ],
                    Opts2 = maps:from_list(lists:flatten(Opts1)),
                    case nkmedia_room:start(SrvId, Opts2) of
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
            {ok, nklib_util:to_binary(RoomId)};
        error when Type==publish -> 
            {ok, nklib_util:uuid_4122()};
        error when Type==listen ->
            case Session of
                #{publisher_id:=Publisher} ->
                    case session_call(Publisher, get_publisher) of
                        {ok, RoomId} -> {ok, RoomId};
                        {error, _Error} -> {error, invalid_publisher}
                    end;
                _ ->
                    {error, {missing_field, publisher_id}}
            end
    end.


%% @private
notify_publisher(RoomId, #{session_id:=SessId}=Session) ->
    User = maps:get(user_id, Session, <<>>),
    JanusEvent = {started_publisher, SessId, #{user=>User, pid=>self()}},
    case nkmedia_room:update(RoomId, JanusEvent) of
        {ok, Pid} ->
            nkmedia_session:register(self(), {nkmedia_room, RoomId, Pid});
        {error, Error} ->
            ?LLOG(warning, "room publish error: ~p", [Error], Session)
    end.


%% @private
notify_listener(RoomId, PeerId, #{session_id:=SessId}=Session) ->
    User = maps:get(user_id, Session, <<>>),
    JanusEvent = {started_listener, SessId, #{user=>User, pid=>self(), peer_id=>PeerId}},
    case nkmedia_room:update(RoomId, JanusEvent) of
        {ok, Pid} ->
            nkmedia_session:register(self(), {nkmedia_room, RoomId, Pid});
        {error, Error} ->
            ?LLOG(warning, "room publish error: ~p", [Error], Session)
    end.


%% @private
set_offer(Offer, Session) ->
    ?SESSION(#{offer=>Offer}, Session).


%% @private
set_answer(Answer, Session) ->
    ?SESSION(#{answer=>Answer}, Session).

%% @private
session_call(SessId, Msg) ->
    nkmedia_session:do_call(SessId, {nkmedia_janus, Msg}).

%% @private
session_cast(SessId, Msg) ->
    nkmedia_session:do_cast(SessId, {nkmedia_janus, Msg}).

%% @private
update_type(Type, TypeExt) ->
    nkmedia_session:set_type(self(), Type, TypeExt).


%% @private
set_media(Session) ->
    set_media(Session, Session).


%% @private
set_media(Opts, #{nkmedia_janus_pid:=Pid}=Session) ->
    case get_media(Opts, Session) of
        none ->
            {ok, Session};
        {Data, Session2} ->
            case nkmedia_janus_op:media(Pid, Data) of
                ok ->
                    {ok, Session2};
                {error, Error} ->
                    {error, Error, Session2}
            end
    end.


% %% @private
% set_media_callee(Opts, #{nkmedia_janus_pid:=Pid}=Session) ->
%     case get_media(Opts, Session) of
%         none ->
%             {ok, Session};
%         {Data, Session2} ->
%             case nkmedia_janus_op:media_callee(Pid, Data) of
%                 ok ->
%                     {ok, Session2};
%                 {error, Error} ->
%                     {error, Error, Session2}
%             end
%     end.


%% @private
get_media(Opts, Session) ->
    Keys = [use_audio, use_video, use_data, bitrate, record],
    case maps:with(Keys, Opts) of
        Data when map_size(Data) == 0 ->
            none;
        #{record:=true}=Data ->
            {Name, Session2} = nkmedia_session:get_session_file(Session),
            File = filename:join(<<"/tmp/record">>, Name),
            {Data#{filename => File}, Session2};
        Data ->
            {Data, Session}
    end.


