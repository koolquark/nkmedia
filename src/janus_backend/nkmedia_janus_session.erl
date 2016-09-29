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
%% Bitrate referes to "received" bitrate


-module(nkmedia_janus_session).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/3, offer/4, answer/4, candidate/2, cmd/3, stop/2]).
-export([handle_call/3, handle_cast/2]).

-export_type([session/0, type/0, opts/0, cmd/0]).

-define(LLOG(Type, Txt, Args, Session),
    lager:Type("NkMEDIA JANUS Session ~s (~s)"++Txt, 
               [maps:get(session_id, Session), maps:get(type, Session) | Args])).

-define(DEFAULT_MEDIA, #{mute_audio=>false, mute_video=>false, bitrate=>500000}).


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
        nkmedia_janus_proxy_type => videocall | from_sip | to_sip,
        nkmedia_janus_proxy_offer => nkmedia:offer()
    }.


-type type() ::
    nkmedia_session:type() |
    echo     |
    proxy    |
    publish  |
    listen.


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
-spec start(nkmedia_session:type(), nkmedia:role(), session()) ->
    {ok, session()} |
    {error, nkservice:error(), session()} | continue().


%% Special case as 'B' leg of a proxy
start(proxy, offerer, #{master_peer:=MasterId}=Session) -> 
    case nkmedia_session:cmd(MasterId, get_proxy_offer, #{}) of
        {ok, #{janus_id:=Id, proxy_type:=Type, offer:=Offer}} ->
            Update = #{
                backend => nkmedia_janus, 
                nkmedia_janus_id => Id,
                nkmedia_janus_proxy_type => Type,
                % We want to send the answer back to master session
                no_answer_trickle_ice => false,
                set_master_answer => true
            },
            Session2 = ?SESSION(Update, Session),
            {ok, set_offer(Offer, Session2)};
        {error, Error} ->
            {error, Error, Session}
    end;

start(Type, Role, Session) -> 
    case is_supported(Type) of
        true ->
            Session2 = ?SESSION(#{backend=>nkmedia_janus}, Session),
            case get_mediaserver(Session2) of
                {ok, Session3} ->
                    case get_janus_op(Session3) of
                        {ok, Session4} when Role==offeree ->
                            % Wait for the offer (can be updated by a callback)
                            {ok, Session4};
                        {ok, Session4} when Role==offerer ->
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



%% @private Someone set the answer
-spec answer(type(), nkmedia:role(), nkmedia:answer(), session()) ->
    {ok, session()} | {error, nkservice:error(), session()} | continue.

answer(proxy, offerer, Answer, #{nkmedia_janus_proxy_type:=videocall}=Session) ->
    % We are the 'B' side of the proxy, do nothing because the answer will be sent
    % to the master automatically
    case set_default_media_proxy(Session) of
        {ok, Session2} ->
            lager:error("B SIDE1"),
            {ok, Answer, Session2};
        {error, Error, Session2} ->
            {error, Error, Session2}
    end;

answer(proxy, offerer, Answer, #{nkmedia_janus_proxy_type:=Type}=Session) ->
    % We are the 'B' side of a SIP  proxy
    lager:error("SIP B: ~p", [Type]),
    {ok, Answer, Session};

answer(proxy, offerer, Answer, Session) ->
    % We are the 'B' side of a SIP  proxy
    lager:error("SIP B NO TYPE"),
    {ok, Answer, Session};

answer(proxy, offeree, Answer, #{nkmedia_janus_pid:=Pid}=Session) ->
    % We are the 'A' side of the proxy. Answer it from B.
    case nkmedia_janus_op:answer(Pid, Answer) of
        {ok, Answer2} ->
            case Session of
                #{nkmedia_janus_proxy_type:=videocall} ->
                    case set_default_media(Session) of
                        {ok, Session2} ->
                            {ok, Answer2, Session2};
                        {error, Error, Session2} ->
                            {error, Error, Session2}
                    end;
                _ ->
                    {ok, Answer2, Session}
            end;
        {error, Error} ->
            {error, Error, Session}
    end;

answer(listen, offerer, Answer, #{nkmedia_janus_pid:=Pid}=Session) ->
    case nkmedia_janus_op:answer(Pid, Answer) of
        ok ->
            {ok, Answer, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

% For other types, do nothing special
answer(_Type, _Role, _Answer, _Session) ->
    continue.



%% @private We received a candidate from the client to the backend
-spec candidate(nkmedia:candidate(), session()) ->
    {ok, session()} | continue.

candidate(Candidate, #{type:=proxy, backend_role:=offerer}=Session) ->
    #{master_peer:=MasterId} = Session,
    session_cast(MasterId, {proxy_candidate, Candidate}),
    {ok, Session};

candidate(Candidate, #{nkmedia_janus_pid:=Pid}=Session) ->
    nkmedia_janus_op:candidate(Pid, Candidate),
    {ok, Session}.


% %% @private


%% @private
-spec cmd(cmd(), Opts::map(), session()) ->
    {ok, Reply::term(), session()} | {error, term(), session()} | continue().

cmd(update_media, Opts, #{type:=proxy, backend_role:=offerer}=Session) ->
    case set_media_proxy(Opts, Session) of
        {ok, Session2} ->
            {ok, #{}, Session2};
        {error, Error, Session2} ->
            {error, Error, Session2}
    end;

cmd(update_media, Opts, #{type:=Type}=Session) 
        when Type==echo; Type==proxy; Type==publish ->
    case set_media(Opts, Session) of
        {ok, Session2} ->
            {ok, #{}, Session2};
        {error, Error, Session2} ->
            {error, Error, Session2}
    end;

cmd(set_type, #{type:=listen, publisher_id:=Publisher}, #{type:=listen}=Session) ->
    #{nkmedia_janus_pid:=Pid, type_ext:=#{room_id:=RoomId}=Ext} = Session,
    case nkmedia_janus_op:listen_switch(Pid, Publisher) of
        ok ->
            notify_listener(RoomId, Publisher, Session),
            update_type(listen, Ext#{publisher_id=>Publisher}),
            {ok, #{}, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

cmd(recorder_action, Opts, Session) ->
    Action = maps:get(action, Opts, get_actions),
    recorder_action(Action, Opts, Session);

cmd(get_proxy_offer, _, Session) ->
    case Session of
        #{
            nkmedia_janus_id := Id, 
            nkmedia_janus_proxy_offer := Offer,
            nkmedia_janus_proxy_type := Type
        } ->
            {ok, #{janus_id=>Id, proxy_type=>Type, offer=>Offer}, Session};
        _ ->
            {error, invalid_session, Session}
    end;

cmd(_Update, _Opts, Session) ->
    {error, not_implemented, Session}.


%% @private
-spec stop(nkservice:error(), session()) ->
    {ok, session()}.

stop(_Reason, #{session_id:=SessId}=Session) ->
    case Session of
        #{type:=publish, type_ext:=#{room_id:=RoomId}} ->
            nkmedia_room:stopped_member(RoomId, SessId);
        #{type:=listen, type_ext:=#{room_id:=RoomId}} ->
            nkmedia_room:stopped_member(RoomId, SessId);
        _ ->
            ok
    end,
    {ok, Session}.


%% @private
handle_call(get_room_id, _From, #{type:=publish}=Session) ->
    #{type_ext:=#{room_id:=RoomId}} = Session,
    {reply, {ok, RoomId}, Session};

handle_call(get_room_id, _From, Session) ->
    {reply, {error, invalid_publisher}, Session};

handle_call({set_media_proxy, Data}, _From, #{nkmedia_janus_pid:=Pid}=Session) ->
    % lager:error("Media peer: ~p", [Data]),
    case nkmedia_janus_op:media_peer(Pid, Data) of
        ok ->
            {reply, ok, Session};
        {error, Error} ->
            {reply, {error, Error}, Session}
    end.


%% @private
handle_cast({proxy_candidate, Candidate}, #{nkmedia_janus_pid:=Pid}=Session) ->
    % lager:error("RECEIVED PROXY CANDIDATE"),
    case Session of
        #{nkmedia_janus_proxy_type:=videocall} ->
            nkmedia_janus_op:candidate_peer(Pid, Candidate);
        _ ->
            nkmedia_janus_op:candidate(Pid, Candidate)
    end,
    {noreply, Session}.



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

start_offerer(listen, #{publisher_id:=Publisher, nkmedia_janus_pid:=Pid}=Session) ->
    case get_room(listen, Session) of
        {ok, RoomId} ->
            case nkmedia_janus_op:listen(Pid, RoomId, Publisher) of
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
    case nkmedia_janus_op:echo(Pid, Offer) of
        {ok, Answer} ->
            % io:format("ANS:\n~s", [maps:get(sdp, Answer)]),
            Session2 = set_answer(Answer, Session),
            % {ok, Session2};
            set_default_media(Session2);
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
                    Update = #{
                        nkmedia_janus_proxy_type => Fun,
                        nkmedia_janus_proxy_offer => Offer2,
                        % when we receive answer from slave, we must process it
                        no_answer_trickle_ice => false
                    },
                    % Media will be set on answer
                    {ok, ?SESSION(Update, Session)};
                {error, Error} ->
                    {error, Error, Session}
            end
    end;

start_offeree(publish, Offer, #{nkmedia_janus_pid:=Pid}=Session) ->
    case get_room(publish, Session) of
        {ok, RoomId} ->
            case nkmedia_janus_op:publish(Pid, RoomId, Offer) of
                {ok, Answer} ->
                    notify_publisher(RoomId, Session),
                    update_type(publish, #{room_id=>RoomId}),
                    Session2 = set_answer(Answer, Session),
                    set_default_media(Session2);
                {error, Error} ->
                    {error, Error, Session}
            end;
        {error, Error} ->
            {error, Error, Session}
    end;

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
    {ok, nkmedia_janus_room:id()} | {error, term()}.

get_room(Type, #{nkmedia_janus_id:=JanusId}=Session) ->
    case get_room_id(Type, Session) of
        {ok, RoomId} ->
            case nkmedia_room:get_room(RoomId) of
                {ok, #{nkmedia_janus_id:=JanusId}} ->
                    % lager:error("Room exists in same Janus"),
                    {ok, RoomId};
                {ok, _O} ->
                    {error, different_mediaserver};
                {error, room_not_found} ->
                    create_room(RoomId, Session);
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
                    case session_call(Publisher, get_room_id) of
                        {ok, RoomId} -> {ok, RoomId};
                        {error, _Error} -> {error, invalid_publisher}
                    end;
                _ ->
                    {error, {missing_field, publisher_id}}
            end
    end.


%% @private
create_room(RoomId, #{srv_id:=SrvId, nkmedia_janus_id:=JanusId}=Session) ->
    Opts1 = [
        {room_id, RoomId},
        {backend, nkmedia_janus},
        {nkmedia_janus_id, JanusId},
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
    end.


%% @private
notify_publisher(RoomId, #{session_id:=SessId}=Session) ->
    UserId = maps:get(user_id, Session, <<>>),
    Info = #{role => publisher, user_id => UserId},
    case nkmedia_room:started_member(RoomId, SessId, Info, self()) of
        ok ->
            ok;
        {error, Error} ->
            ?LLOG(warning, "room publish error: ~p", [Error], Session)
    end.


%% @private
notify_listener(RoomId, PeerId, #{session_id:=SessId}=Session) ->
    UserId = maps:get(user_id, Session, <<>>),
    Info = #{role => listener, user_id => UserId, peer_id => PeerId},
    case nkmedia_room:started_member(RoomId, SessId, Info, self()) of
        ok ->
            ok;
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
recorder_action(start, Opts, Session) ->
    case start_record(Opts, Session) of
        {ok, Session2} ->
            {ok, #{}, Session2};
        {error, Error} ->
            {error, Error, Session}
    end;

recorder_action(stop, _Opts, Session) ->
    case stop_record(Session) of
        ok ->
            {ok, #{}, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

recorder_action(get_actions, _Opts, Session) ->
    {ok, #{actions=>[start, stop, get_actions]}, Session};

recorder_action(Action, _Opts, Session) ->
    {error, {invalid_action, Action}, Session}.


%% @private
start_record(#{record_uri:=<<"file://", File/binary>>}, Session) ->
    Data = #{record=>true, filename=>File},
    case Session of
        #{type:=proxy, backend_role:=offerer, master_peer:=MasterId} ->
            case session_call(MasterId, {set_media_proxy, Data}) of
                ok ->
                    {ok, Session};
                {error, Error} ->
                    {error, Error}
            end;
        #{nkmedia_janus_pid:=Pid} ->
            case nkmedia_janus_op:media(Pid, Data) of
                ok ->
                    {ok, Session};
                {error, Error} ->
                    {error, Error}
            end
    end;
    
start_record(#{uri:=Uri}=Opts, Session) ->
    start_record(Opts#{record_uri=>Uri}, Session);

start_record(Opts, Session) ->
    {Name1, Session2} = nkmedia_session:get_session_file(Session),
    Name2 = filename:join(<<"/tmp/record">>, Name1),
    start_record(Opts#{record_uri=><<"file://", Name2/binary>>}, Session2).


%% @private
stop_record(#{type:=proxy, backend_role:=offerer, master_peer:=MasterId}) ->
   session_call(MasterId, {set_media_proxy, #{record=>false}});

stop_record(#{nkmedia_janus_pid:=Pid}) ->
    nkmedia_janus_op:media(Pid, #{record=>false}).


%% @private
set_default_media(Session) ->
    Opts = maps:merge(?DEFAULT_MEDIA, Session),
    set_media(Opts, Session).

        
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


%% @private
set_default_media_proxy(Session) ->
    Opts = maps:merge(?DEFAULT_MEDIA, Session),
    set_media_proxy(Opts, Session).


% %% @private
set_media_proxy(Opts, #{master_peer:=MasterId}=Session) ->
    case Session of
        #{nkmedia_janus_proxy_type:=videocall} ->
            case get_media(Opts, Session) of
                none ->
                    {ok, Session};
                {Data, Session2} ->
                    case session_call(MasterId, {set_media_proxy, Data}) of
                        ok ->
                            {ok, Session2};
                        {error, Error} ->
                            {error, Error, Session2}
                    end
            end;
        _ ->
            {error, invalid_operation, Session}
    end.


%% @private
get_media(Opts, Session) ->
    Keys = [mute_audio, mute_video, mute_data, bitrate],
    case maps:with(Keys, Opts) of
        Data when map_size(Data) == 0 ->
            none;
        Data ->
            {Data, Session}
    end.


