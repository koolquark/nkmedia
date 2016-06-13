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
-module(nkmedia_janus_session).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([init/3, terminate/3, offer_op/5, answer_op/5]).
-export([updated_answer/3, hangup/3]).

-export_type([config/0, offer_op/0, answer_op/0, op_opts/0]).

-define(LLOG(Type, Txt, Args, Session),
    lager:Type("NkMEDIA JANUS Session ~s "++Txt, 
               [maps:get(id, Session) | Args])).

-include("nkmedia.hrl").

%% ===================================================================
%% Types
%% ===================================================================

-type id() :: nkmedia_session:id().
-type session() :: nkmedia_session:session().
-type continue() :: continue | {continue, list()}.


-type config() :: 
    nkmedia_session:config() |
    #{
    }.

-type offer_op() ::
    nkmedia_session:offer_op() |
    proxy    |
    listen   |
    play.


-type answer_op() ::
    nkmedia_session:answer_op() |
    publish.


-type op_opts() ::  
    nkmedia_session:op_opts() |
    #{
    }.


-type state() ::
    #{
        janus_id => nkmedia_janus_engine:id(),
        janus_pid => pid(),
        janus_mon => reference(),
        janus_op => answer
    }.




%% ===================================================================
%% Callbacks
%% ===================================================================


-spec init(id(), session(), state()) ->
    {ok, state()}.

init(_Id, _Session, State) ->
    {ok, State}.


%% @doc Called when the session stops
-spec terminate(Reason::term(), session(), state()) ->
    {ok, state()}.

terminate(_Reason, _Session, State) ->
    {ok, State}.


%% @private You must generte an offer() for this offer_op()
%% ReplyOpts will only we used for user notification
-spec offer_op(offer_op(), op_opts(), boolean(), session(), state()) ->
    {ok, nkmedia:offer(), offer_op(), map(), session()} |
    {error, term(), state()} | continue().

offer_op(proxy, #{offer:=Offer}=Opts, false, Session, State) ->
    case get_janus(Opts, Session, State) of
        {ok, Pid, State2} ->
            OfferType = maps:get(sdp_type, Offer, webrtc),
            OutType = maps:get(type, Opts, webrtc),
            Fun = case {OfferType, OutType} of
                {webrtc, webrtc} -> videocall;
                {webrtc, rtp} -> to_sip;
                {rtp, webrtc} -> from_sip;
                {rtp, rtp} -> error
            end,
            case Fun of
                error ->
                    {error, unsupported_proxy, State};
                _ ->
                    case nkmedia_janus_op:Fun(Pid, Offer, Opts) of
                        {ok, Offer2} ->
                            State3 = State2#{janus_op=>answer},
                            Offer3 = maps:merge(Offer, Offer2),
                            {ok, Offer3, proxy, #{}, State3};
                        {error, Error} ->
                            {error, {videocall_error, Error}, State2}
                    end
            end;
        {error, Error} ->
            {error, Error, State}
    end;

offer_op(listen, #{room:=Room, publisher:=Publisher}=Opts, false, Session, State) ->
    case get_janus(Opts, Session, State) of
        {ok, Pid, State2} ->
            case nkmedia_janus_op:listen(Pid, Room, Publisher, Opts) of
                {ok, #{sdp:=SDP}} ->
                    State3 = State2#{janus_op=>answer},
                    {ok, #{sdp=>SDP}, listen, Opts, State3};
                {error, Error} ->
                    {error, {listen_error, Error}, State2}
            end;
        {error, Error} ->
            {error, Error, State}
    end;

offer_op(listen_switch, #{publisher:=Publisher}=Opts, true, 
         #{offer_op:={listen, Opts0}}, #{janus_pid:=Pid}=State) ->
    case nkmedia_janus_op:listen_switch(Pid, Publisher, Opts) of
        ok ->
            {ok, #{}, listen, maps:merge(Opts0, Opts), State};
        {error, Error} ->
            {error, {listen_switch_error, Error}, State}
    end;

offer_op(_Op, _Opts, _HasOffer, _Session, _State) ->
    continue.


%% @private
-spec answer_op(answer_op(), op_opts(), boolean(), session(), state()) ->
    {ok, nkmedia:answer(), ReplyOpts::map(), session()} |
    {error, term(), state()} | continue().

answer_op(echo, Opts, false, #{offer:=Offer}=Session, State) ->
    case get_janus(Opts, Session, State) of
        {ok, Pid, State2} ->
            case nkmedia_janus_op:echo(Pid, Offer, Opts) of
                {ok, #{sdp:=_}=Answer} ->
                    {ok, Answer, echo, #{}, State2};
                {error, Error} ->
                    {error, {echo_error, Error}, State2}
            end;
        {error, Error} ->
            {error, Error, State}
    end;

answer_op(publish, Opts, false, #{offer:=Offer}=Session, State) ->
    try
        Room = case maps:find(room, Opts) of
            {ok, Room0} -> nklib_util:to_binary(Room0);
            error -> nklib_util:uuid_4122()
        end,
        case get_janus(Opts, Session, State) of
            {ok, Pid, State2} ->
                case nkmedia_janus_room:get_info(Room) of
                    {error, not_found} ->
                        #{janus_id:=JanusId} = State2,
                        case nkmedia_janus_room:create(JanusId, Room, #{}) of
                            {ok, _} -> ok;
                            {error, Error} -> throw({room_creation_error, Error})
                        end;
                    {ok, _} ->
                        ok
                end,
                case nkmedia_janus_op:publish(Pid, Room, Offer, Opts) of
                    {ok, #{sdp:=_}=Answer} ->
                        {ok, Answer, publish, #{room=>Room}, State2};
                    {error, Error2} ->
                        {error, {echo_error, Error2}, State2}
                end;
            {error, Error3} ->
                {error, Error3, State}
        end
    catch
        throw:Throw -> {error, Throw, State}
    end;

answer_op(_Op, _Opts, _HasAnswer, _Session, _State) ->
    continue.



%% @private
-spec updated_answer(nkmedia:answer(), session(), state()) ->
    {ok, nkmedia:answer(), state()} |
    {error, term(), state()} | continue().

updated_answer(Answer, _Session, #{janus_op:=answer}=State) ->
    #{janus_pid:=Pid} = State,
    case nkmedia_janus_op:answer(Pid, Answer) of
        ok ->
            {ok, Answer, maps:remove(janus_op, State)};
        {ok, Answer2} ->
            {ok, Answer2, maps:remove(janus_op, State)};
        {error, Error} ->
            {error, {janus_answer_error, Error}, State}
    end;

updated_answer(_Answer, _Session, _State) ->
    continue.


%% @private
-spec hangup(nkmedia:hangup_reason(), session(), state()) ->
    {ok, state()}.

hangup(_Reason, _Session, State) ->
    {ok, State}.




%% ===================================================================
%% Internal
%% ===================================================================


%% @private
get_janus(_Opts, #{id:=SessId}, #{janus_id:=JanusId}=State) ->
    case nkmedia_janus_op:start(JanusId, SessId) of
        {ok, Pid} ->
            State2 = State#{janus_pid=>Pid, janus_mon=>monitor(process, Pid)},
            {ok, Pid, State2};
        {error, Error} ->
            {error, Error, State}
    end;

get_janus(Opts, Session, State) ->
    case get_mediaserver(Session, State) of
        {ok, State2} ->
            get_janus(Opts, Session, State2);
        {error, Error} ->
            {error, {get_janus_error, Error}, State}
    end.



%% @private
-spec get_mediaserver(session(), state()) ->
    {ok, state()} | {error, term()}.

get_mediaserver(_Session, #{janus_id:=_}=State) ->
    {ok, State};

get_mediaserver(#{srv_id:=SrvId}=Session, State) ->
    case SrvId:nkmedia_janus_get_mediaserver(Session) of
        {ok, Id} ->
            {ok, State#{janus_id=>Id}};
        {error, Error} ->
            {error, Error}
    end.


% %% @private
% get_op(#{offer_op:={Op, Data}}, #{janus_role:=offer}) -> {offer_op, Op, Data};
% get_op(#{answer_op:={Op, Data}}, #{janus_role:=answer}) -> {answer_op, Op, Data};
% get_op(_, _) -> unknown_op.

