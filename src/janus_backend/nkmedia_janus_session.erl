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

-export([start/2, answer/3, candidate/2, update/3, stop/2]).
-export([handle_call/3, handle_cast/2]).

-export_type([session/0, type/0, opts/0, update/0]).

-define(LLOG(Type, Txt, Args, Session),
    lager:Type("NkMEDIA JANUS Session ~s (~s)"++Txt, 
               [maps:get(session_id, Session), maps:get(type, Session) | Args])).

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
        nkmedia_janus_offer => nkmedia:offer()
    }.


-type type() ::
    nkmedia_session:type() |
    echo     |
    proxy    |
    publish  |
    listen   |
    play.


-type opts() ::
    nkmedia_session:session() |
    #{
    }.


-type update() ::
    nkmedia_session:update() |
    {listener_switch, binary()}.




%% ===================================================================
%% Callbacks
%% ===================================================================



%% @private
-spec start(nkmedia_session:type(), session()) ->
    {ok, session()} |
    {error, nkservice:error(), session()} | continue().

start(callee, #{role:=offeree, master_peer:=Master}=Session) -> 
    case session_call(Master, get_caller_data) of
        {ok, Update} ->
            Session2 = ?SESSION(Update, Session),
            {ok, Session2};
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
                        {ok, #{offer:=Offer}=Session4} ->
                            start_offeree(Type, Offer, Session4);
                        {ok, Session4} ->
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


%% @private
-spec start_offerer(type(), session()) ->
    {ok, session()} |
    {error, nkservice:error(), session()} | continue().

%% We must make the offer
start_offerer(listen, #{publisher_id:=Publisher, nkmedia_janus_pid:=Pid}=Session) ->
    case get_room(listen, Session) of
        {ok, RoomId} ->
            case nkmedia_janus_op:listen(Pid, RoomId, Publisher, #{}) of
                {ok, Offer} ->
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
    io:format("OFF:\n~s", [maps:get(sdp, Offer)]),
    case nkmedia_janus_op:echo(Pid, Offer) of
        {ok, Answer} ->
            io:format("ANS:\n~s", [maps:get(sdp, Answer)]),
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
                    Session2 = ?SESSION(#{nkmedia_janus_offer=>Offer2}, Session),
                    set_media(Session2);
                {error, Error} ->
                    lager:error("FUN: ~p ~p", [Fun, Error]),
                    {error, Error, Session}
            end
    end;

start_offeree(publish, Offer, #{nkmedia_janus_pid:=Pid}=Session) ->
    case get_room(publish, Session) of
        {ok, RoomId} ->
            case nkmedia_janus_op:publish(Pid, RoomId, Offer, #{}) of
                {ok, Answer} ->
                    update_type(publish, #{room_id=>RoomId}),
                    {ok, set_media(set_answer(Answer, Session))};
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
-spec answer(type(), nkmedia:answer(), session()) ->
    {ok, session()} | {error, nkservice:error(), session()}.

%% We generated the offer, let's process the answer
answer(Type, Answer, Session) when Type==proxy; Type==listen ->
    #{nkmedia_janus_pid:=Pid} = Session,
    case nkmedia_janus_op:answer(Pid, Answer) of
        ok ->
            {ok, Session};
        {ok, Answer2} ->
            {ok, set_answer(Answer2, Session)};
        {error, Error} ->
            {error, Error, Session}
    end;

answer(_Type, _Answer, Session) ->
    {ok, Session}.



%% @private We received a candidate from the client
-spec candidate(nkmedia:candidate(), session()) ->
    {ok, session()} | continue.

candidate(Candidate, #{type:=callee, master_peer:=Master}=Session) ->
    session_cast(Master, {callee_candidate, Candidate}),
    {ok, Session};

candidate(Candidate, #{nkmedia_janus_pid:=Pid}=Session) ->
    nkmedia_janus_op:candidate(Pid, Candidate),
    {ok, Session}.


%% @private
-spec update(update(), Opts::map(), session()) ->
    {ok, Reply::term(), session()} | {error, term(), session()} | continue().

update(media, Opts, #{type:=callee}=Session) ->
    case set_media_callee(Opts, Session) of
        {ok, Session2} ->
            {ok, #{}, Session2};
        {error, Error, Session2} ->
            {error, Error, Session2}
    end;

update(media, Opts, #{type:=Type}=Session) when Type==echo; Type==proxy; Type==publish ->
    case set_media(Opts, Session) of
        {ok, Session2} ->
            {ok, #{}, Session2};
        {error, Error, Session2} ->
            {error, Error, Session2}
    end;

update(listen_switch, #{publisher_id:=Publisher}, #{type:=listen}=Session) ->
    #{nkmedia_janus_pid:=Pid, type_ext:=Ext} = Session,
    case nkmedia_janus_op:listen_switch(Pid, Publisher, #{}) of
        ok ->
            update_type(listen, Ext#{publisher_id=>Publisher}),
            {ok, #{}, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

update(get_proxy_offer, _, #{nkmedia_janus_offer:=Offer}=Session) ->
    {ok, Offer, Session};

update(_Update, _Opts, _Session) ->
    continue.


%% @private
-spec stop(nkservice:error(), session()) ->
    {ok, session()}.

stop(_Reason, Session) ->
    {ok, Session}.


%% @private
handle_call(get_publisher, _From, #{type:=publish}=Session) ->
    #{type_ext:=#{room_id:=RoomId}} = Session,
    {reply, {ok, RoomId}, Session};

handle_call(get_publisher, _From, Session) ->
    {reply, {error, invalid_publisher}, Session};

handle_call(get_caller_data, _From, #{type:=proxy}=Session) ->
    Update = maps:with([nkmedia_janus_id, nkmedia_janus_pid], Session),
    {reply, {ok, Update}, Session};

handle_call(caller_data, _From,Session) ->
    {reply, {error, invalid_operation}, Session}.


%% @private
handle_cast({callee_candidate, Candidate}, #{nkmedia_janus_pid:=Pid}=Session) ->
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
            lager:error("get_room ROOM ID IS: ~p", [RoomId]),
            case nkmedia_room:get_room(RoomId) of
                {ok, #{nkmedia_janus:=#{janus_id:=JanusId}}} ->
                    lager:error("Room exists in same MS"),
                    {ok, RoomId};
                {ok, O} ->
                    lager:error("O: ~p", [O]),
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
            lager:error("Found room_id in Opts"),
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


%% @private
set_media_callee(Opts, #{nkmedia_janus_pid:=Pid}=Session) ->
    case get_media(Opts, Session) of
        none ->
            {ok, Session};
        {Data, Session2} ->
            case nkmedia_janus_op:media_callee(Pid, Data) of
                ok ->
                    {ok, Session2};
                {error, Error} ->
                    {error, Error, Session2}
            end
    end.


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


