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


-module(nkmedia_session).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start/2, get_status/1, get_session/1]).
-export([hangup/1, hangup/2, hangup_all/0]).
-export([set_offer/3, set_answer/3]).
-export([reply/2]).
-export([pbx_event/3, call_event/3, get_all/0, find/1]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, config/0, status/0, session/0, event/0]).
-export_type([call_dest/0]).


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Session ~s (~p, ~p) "++Txt, 
               [State#state.id, State#state.type, State#state.status | Args])).

-include("nkmedia.hrl").

%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().

-type config() :: 
    #{
        id => id(),                             % Generated if not included
        type => type(),
        offer => nkmedia:offer(),               
        answer => nkmedia:offer(),              
        monitor => pid(),                       % Monitor this process
        mediaserver => mediaserver(),           % Forces mediaserver
        wait_timeout => integer(),              % Secs
        ring_timeout => integer(),          
        call_timeout => integer(),
        module() => term()                      % User data
}.

-type type() :: p2p | proxy | pbx.

-type call_dest() :: term().

-type status() ::
    wait    |   % Waiting for an operation, no media
    calling |   % Launching an invite
    ringing |   % Received 'ringing'
    ready   |   % Waiting for operation, has media
    call    |   % Session is connected to another
    mcu     | 
    sfu     |
    record  |
    play    | 
    hangup.


%% Extended status
-type ext_status() ::
    #{
        dest => binary(),                       % For calling status
        answer => nkmedia:answer(),             % For ringing, ready
        peer => id(),                           % Bridged, p2p
        room_name => binary(),                  % For mcu
        room_member => binary(),
        hangup_reason => nkmedia_util:hangup_reason()
    }.


-type session() ::
    config () | 
    #{
        srv_id => nkservice:id(),
        status => status(),
        ext_status => ext_status()
    }.

-type offer_op() ::
    nkmedia:offer() | {listener, Room::integer(), User::integer()}.


-type answer_op() ::
    nkmedia:answer() | echo | {mcu, Room::binary()} | 
    {publisher, Room::integer()} | {call, Dest::binary()} | 
    {invite, Dest::binary()}.

-type op_opts() ::  
    #{
        type => type(),
        sync => boolean(),
        get_sdp => boolean()
    }.

-type op_meta() ::  
    #{
        offer => nkmedia:offer(),
        answer => nkmedia:answer()
    }.


-type reply() :: 
    ringing | {ringing, nkmedia:answer()} | {answered, nkmedia:answer()}.


-type event() ::
    {status, status(), ext_status()} | {info, term()}.


-type pbx_event() ::
    parked | {hangup, term()} | {bridge, id()} | {mcu, map()}.


% -type proxy_event() ::
%     parked | {hangup, term()} | {bridge, id()} | {mcu, map()}.


-type mediaserver() ::
    {fs, nkmedia_fs:id()} | {janus, nkmedia_janus:id()}.



%% ===================================================================
%% Public
%% ===================================================================

%% @private
-spec start(nkservice:id(), config()) ->
    {ok, id(), pid()} | {error, term()}.

start(Service, Config) ->
    case nkservice_srv:get_srv_id(Service) of
        {ok, SrvId} ->
            Config2 = Config#{srv_id=>SrvId},
            {SessId, Config3} = nkmedia_util:add_uuid(Config2),
            {ok, SessPid} = gen_server:start(?MODULE, [Config3], []),
            {ok, SessId, SessPid};
        not_found ->
            {error, service_not_found}
    end.


%% @doc
-spec get_session(id()) ->
    {ok, session()} | {error, term()}.

get_session(SessId) ->
    do_call(SessId, get_session).


%% @doc
-spec get_status(id()) ->
    {ok, status(), ext_status(), integer()}.

get_status(SessId) ->
    do_call(SessId, get_status).


%% @doc
-spec hangup(id()) ->
    ok | {error, term()}.

hangup(SessId) ->
    hangup(SessId, 16).


%% @doc
-spec hangup(id(), nkmedia:hangup_reason()) ->
    ok | {error, term()}.

hangup(SessId, Reason) ->
    do_cast(SessId, {hangup, Reason}).


%% @private
hangup_all() ->
    lists:foreach(fun({SessId, _Pid}) -> hangup(SessId) end, get_all()).


%% @doc 
-spec set_offer(id(), offer_op(), op_opts()) ->
    ok | {ok, op_meta()} | {error, term()}.

set_offer(SessId, OfferOp, #{sync:=true}=Opts) ->
    do_call(SessId, {offer_op, OfferOp, Opts});

set_offer(SessId, OfferOp, Opts) ->
    do_cast(SessId, {offer_op, OfferOp, Opts}).


%% @doc 
-spec set_answer(id(), answer_op(), op_opts()) ->
    ok | {ok, op_meta()} | {error, term()}.

set_answer(SessId, AnswerOp, #{sync:=true}=Opts) ->
    do_call(SessId, {answer_op, AnswerOp, Opts});

set_answer(SessId, AnswerOp, Opts) ->
    do_cast(SessId, {answer_op, AnswerOp, Opts}).


%% @private Called when an outbound process delayed the response
-spec reply(id(), reply()) ->
    ok | {error, term()}.

reply(SessId, Reply) ->
    do_cast(SessId, {reply, Reply}).


%% @private
-spec get_all() ->
    [{id(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).



%% ===================================================================
%% Internal
%% ===================================================================

%% @private Called from nkmedia_fs_engine and nkmedia_fs_verto

-spec pbx_event(id(), nkmedia_fs:id(), pbx_event()) ->
    ok.

pbx_event(SessId, FsId, Event) ->
    case do_cast(SessId, {pbx_event, FsId, Event}) of
        ok -> 
            ok;
        {error, _} when Event==stop ->
            ok;
        {error, _} -> 
            lager:warning("NkMEDIA Session: pbx event ~p for unknown session ~s", 
                          [Event, SessId])
    end.


%% @private Called from nkmedia_callbacks:nkmedia_call_event when a 
%% call has an event for us.
call_event(SessPid, CallId, Event) ->
    do_cast(SessPid, {call_event, CallId, Event}).



% ===================================================================
%% gen_server behaviour
%% ===================================================================

-type link_id() ::
    user | {call, nkmedia_call:id()} | janus | out.

-type from_id() ::
    {call, nkmedia_call:id()} | out.

-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    type :: type(),
    status :: status() | init,
    ms :: mediaserver(),
    has_offer = false :: boolean(),
    has_answer = false :: boolean(),
    links = [] :: [{link_id(), pid(), reference()}],
    froms = [] :: [{from_id(), {pid(), term()}, op_opts()}],
    timer :: reference(),
    session :: session()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()}.

init([#{id:=Id, srv_id:=SrvId}=Session]) ->
    true = nklib_proc:reg({?MODULE, Id}),
    nklib_proc:put(?MODULE, Id),
    State1 = #state{
        id = Id, 
        srv_id = SrvId, 
        status = init,
        ms = maps:get(mediaserver, Session, undefined),
        session = #{}
    },
    State2 = case Session of
        #{monitor:=Pid} -> 
            add_link(user, Pid, State1);
        _ -> 
            State1
    end,
    {ok, State3} = update_config(Session, State2),
    {ok, State4} = handle(nkmedia_session_init, [Id], State3),
    lager:info("NkMEDIA Session ~s starting (~p)", [Id, self()]),
    #state{has_offer=Offer, has_answer=Answer} = State4,
    case Offer andalso Answer of
        true -> 
            {ok, status(ready, State4)};
        false ->
            {ok, status(wait, State4)}
    end.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(get_session, _From, #state{session=Session}=State) ->
    {reply, {ok, Session}, State};

handle_call(get_status, _From, State) ->
    #state{status=Status, timer=Timer, session=Session} = State,
    #{ext_status:=Info} = Session,
    {reply, {ok, Status, Info, erlang:read_timer(Timer) div 1000}, State};

handle_call({offer_op, OfferOp, Opts}, From, #state{has_offer=false}=State) ->
    send_offer_op(OfferOp, Opts, From, State);

handle_call({offer_op, _OfferOp, _Opts}, _From, State) ->
    {reply, {error, already_has_offer}, State};

handle_call({answer_op, AnswerOp, Opts}, From, State) ->
    send_answer_op(AnswerOp, Opts, From, State);

handle_call(Msg, From, State) -> 
    handle(nkmedia_session_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({offer_op, OfferOp, Opts}, #state{has_offer=false}=State) ->
    send_offer_op(OfferOp, Opts, undefined, State);

handle_cast({offer_op, _OfferOp, _Opts}, State) ->
    {reply, {error, already_has_offer}, State};

handle_cast({answer_op, AnswerOp, Opts}, State) ->
    send_answer_op(AnswerOp, Opts, undefned, State);

handle_cast({hangup, Reason}, State) ->
    ?LLOG(info, "external hangup: ~p", [Reason], State),
    stop_hangup(Reason, State);

handle_cast({info, Info}, State) ->
    {noreply, event({info, Info}, State)};

handle_cast({call_event, CallId, Event}, #state{links=Links}=State) ->
    case lists:keyfind({call, CallId}, 1, Links) of
        {_, _, _} ->
            do_call_event(CallId, Event, State);
        false ->
            ?LLOG(notice, "received unexpected call event from ~s (~p)", 
                  [CallId, Event], State),
            {noreply, State}
    end;

handle_cast({pbx_event, FsId, Event}, #state{ms={fs, FsId}}=State) ->
   ?LLOG(info, "received pbx event: ~p", [Event], State),
    do_pbx_event(Event, State),
    {noreply, State};

handle_cast({pbx_event, FsId2, Event}, #state{ms=MS}=State) ->
    ?LLOG(warning, "received event ~s from unknown pbx ~p (~p)",
                  [Event, FsId2, MS], State),
    {noreply, State};

handle_cast({reply, ringing}, State) ->
    invite_ringing(#{}, State);

handle_cast({reply, {ringing, Answer}}, State) ->
    invite_ringing(Answer, State);

handle_cast({reply, {answered, Answer}}, State) ->
    invite_answered(Answer, State);

handle_cast({reply, Reply}, State) ->
    ?LLOG(warning, "unrecognized reply: ~p", [Reply], State),
    stop_hangup(<<"Unrecognized Reply">>, State);

handle_cast(stop, State) ->
    ?LLOG(notice, "user stop", [], State),
    {stop, normal, State};

handle_cast(Msg, State) -> 
    handle(nkmedia_session_handle_cast, [Msg], State).


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({timeout, _, status_timeout}, State) ->
    ?LLOG(info, "status timeout", [], State),
    stop_hangup(607, State);

handle_info({'DOWN', _Ref, process, Pid, Reason}=Msg, State) ->
    case find_link_pid(Pid, State) of
        user when Reason==normal ->
            ?LLOG(info, "user monitor down (normal)", [], State),
            stop_hangup(<<"Monitor Stop">>, State);
        user ->
            ?LLOG(notice, "user monitor down (~p)", [Reason], State),
            stop_hangup(<<"Monitor Stop">>, State);
        {call, CallId} when Reason==normal ->
            ?LLOG(info, "call ~s down (normal)", [CallId], State),
            stop_hangup(<<"Call Down">>, State);
        {call, CallId} ->
            ?LLOG(warning, "call ~s down (~p)", [CallId, Reason], State),
            stop_hangup(<<"Call Down">>, State);
        out when Reason==normal ->
            ?LLOG(notice, "called session out down (normal)", [], State),
            stop_hangup(<<"Call Out Down">>, State);
        out ->
            ?LLOG(notice, "called session out down (~p)", [Reason], State),
            stop_hangup(<<"Call Out Down">>, State);
        janus when Reason==normal ->
            ?LLOG(notice, "Janus down (normal)", [], State),
            stop_hangup(<<"Janus Out Down">>, State);
        janus ->
            ?LLOG(notice, "Janus down (~p)", [Reason], State),
            stop_hangup(<<"Janus Out Down">>, State);
        _ ->
            handle(nkmedia_session_handle_info, [Msg], State)
    end;
    
handle_info(Msg, State) -> 
    handle(nkmedia_session_handle_info, [Msg], State).


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(OldVsn, State, Extra) ->
    nklib_gen_server:code_change(nkmedia_session_code_change, 
                                 OldVsn, State, Extra, 
                                 #state.srv_id, #state.session).

%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(Reason, State) ->
    ?LLOG(info, "stopped: ~p", [Reason], State),
    catch handle(nkmedia_session_terminate, [Reason], State),
    _ = stop_hangup(<<"Session Stop">>, State).



%% ===================================================================
%% Internal - offer_op
%% ===================================================================

offer_op(#{sdp:=_}=Offer, Opts, From, State) ->
    Meta = case Opts of
        #{get_offer:=true} -> #{offer=>Offer};
        _ -> #{}
    end,
    nklib_util:reply(From, {ok, Meta}),
    State2 = update_config(#{offer=>Offer}, State),
    {noreply, State2};

offer_op({listener, Room, UserId}, Opts, From, #state{type=undefined}=State) ->
    State2 = update_config(#{type=>proxy}, State),
    offer_op({listener, Room, UserId}, Opts, From, State2);

offer_op({listener, Room, UserId}, Opts, From, #state{type=proxy}=State) ->
    case get_proxy(State) of
        {ok, Pid, State2} ->
            case nkmedia_janus_session:listener(Pid, Room, UserId) of
                {ok, #{sdp:=_}=Offer} ->
                    offer_op(Offer, Opts, From, State);
                {error, Error} ->
                    reply_error(Error, From, State2)
            end;
        {error, Error} ->
            reply_error(Error, From, State)
    end;

offer_op({listener, _Room, _UserId}, _Opts, From, State) ->
    reply_error(incompatible_session_type, From, State);

offer_op(_OfferOp, _Opts, From, State) ->
    reply_error(unknown_offer_op, From, State).



%% ===================================================================
%% offer_op - util
%% ===================================================================


%% TODO: Check if we are ringing, calling or waiting to fs

%% @private
send_offer_op(OfferOp, Opts, From, #state{type=Type}=State) ->
    case offer_op_default(OfferOp) of
        unknown ->
            {reply, {error, unknown_offer_op}, State};
        DefType ->
            Opts2 = case Type of
                undefined -> Opts#{type=>DefType};
                _ -> Opts
            end,
            case update_config(Opts2, State) of
                {ok, State2} ->
                    offer_op(OfferOp, Opts2, From, State2);
                {error, Error} ->
                    {reply, {error, Error}, State}
            end
    end.


%% @private
offer_op_default(Op) ->
    case Op of
        Map when is_map(Map) -> undefined;
        {listener, _, _} -> proxy;
        _ -> unknown
    end.



%% ===================================================================
%% Internal - answer_op
%% ===================================================================



%% RAW SDP
answer_op(#{sdp:=_}=Answer, Opts, From, #state{has_answer=false}=State) ->
    State2 = answer_op_set_ready(Answer, State),
    answer_op_reply(From, Opts, State2),
    {noreply, State2};


%% ECHO
answer_op(echo, Opts, From, #state{type=proxy, has_answer=false}=State) ->
    #state{session=#{offer:=Offer}} = State,
    case get_proxy(State) of
        {ok, Pid, State2} ->
            case nkmedia_janus_session:echo(Pid, Offer) of
                {ok, #{sdp:=_}=Answer} ->
                    State3 = answer_op_set_ready(Answer, State2),
                    answer_op_reply(From, Opts, State3),
                    {noreply, status(echo, State2)};
                {error, Error} ->
                    reply_error(Error, From, State2)
            end;
        {error, Error} ->
            reply_error(Error, From, State)
    end;

answer_op(echo, Opts, From, #state{type=pbx, has_answer=false}=State) ->
    case get_pbx_answer(State) of
        {ok, Answer, State2} ->
            State2 = answer_op_set_ready(Answer, State),
            answer_op(echo, Opts, From, State2);
        {error, Error} ->
            reply_error(Error, From, State)
    end;

answer_op(echo, Opts, From, #state{type=pbx, has_answer=true}=State) ->
    case pbx_transfer("echo", State) of
        ok ->
            % FS will send event and status will be updated
            answer_op_reply(From, Opts, State);
        {error, Error} ->
            reply_error({echo_transfer_error, Error}, From, State)
    end;


%% MCU
answer_op({mcu, Room}, Opts, From, #state{type=pbx, has_answer=false}=State) ->
    case get_pbx_answer(State) of
        {ok, Answer, State2} ->
            State2 = answer_op_set_ready(Answer, State),
            answer_op({mcu, Room}, Opts, From, State2);
        {error, Error} ->
            reply_error(Error, From, State)
    end;

answer_op({mcu, Room}, Opts, From, #state{type=pbx, has_answer=true}=State) ->
    Type = maps:get(room_type, Opts, <<"video-mcu-stereo">>),
    Cmd = [<<"conference:">>, Room, <<"@">>, Type],
    case pbx_transfer(Cmd, State) of
        ok ->
            % FS will send event and status will be updated
            answer_op_reply(From, Opts, State);
        {error, Error} ->
            reply_error({mcu_transfer_error, Error}, From, State)
    end;


%% PUBLISHER
answer_op({publisher, Room}, Opts, From, 
              #state{type=proxy, has_answer=false}=State) ->
    #state{session=#{offer:=Offer}} = State,
    case get_proxy(State) of
        {ok, Pid, State2} ->
            case nkmedia_janus_session:publisher(Pid, Room, Offer) of
                {ok, _UserId, #{sdp:=_}=Answer} ->
                    answer_op(Answer, Opts, From, State2);
                {error, Error} ->
                    reply_error(Error, From, State2)
            end;
        {error, Error} ->
            reply_error(Error, From, State)
    end;


%% CALL
answer_op({call, Dest}, Opts, From, #state{type=p2p, has_answer=false}=State) ->
    #state{session=#{offer:=Offer}} = State,
    do_send_call(Dest, Opts, Offer, From, State);

answer_op({call, Dest}, Opts, From, #state{type=pbx, has_answer=false}=State) ->
    case get_pbx_answer(State) of
        {ok, Answer, State2} ->
            State2 = answer_op_set_ready(Answer, State),
            answer_op({call, Dest}, Opts, From, State2);
        {error, Error} ->
            reply_error(Error, From, State)
    end;

answer_op({call, Dest}, Opts, From, #state{type=pbx, has_answer=true}=State) ->
    #state{session=#{offer:=Offer}} = State,
    Offer2 = maps:remove(sdp, Offer),
    do_send_call(Dest, Opts, Offer2, From, State);

answer_op({call, Dest}, Opts, From, #state{type=proxy, has_answer=false}=State) ->
    #state{session=#{offer:=Offer}} = State,
    case get_proxy(State) of
        {ok, Pid, State2} ->
            case nkmedia_janus_session:videocall(Pid, Offer) of
                {ok, #{sdp:=SDP}} ->
                    do_send_call(Dest, Opts, Offer#{sdp=>SDP}, From, State2);
                {error, Error} ->
                    reply_error(Error, From, State)
            end;
        {error, Error} ->
            reply_error(Error, From, State)
    end;


%% INVITE
answer_op({invite, Dest}, Opts, From, #state{id=Id, session=Session}=State) ->
    #{offer:=Offer} = Session,
    State2 = status(calling, State),
    case handle(nkmedia_session_out, [Id, Dest, Offer], State2) of
        {ringing, Answer, Pid, State3} ->
            State4 = add_link(out, Pid, State3),
            State5 = add_from(out, From, Opts, State4),
            invite_ringing(Answer, State5);
        {answer, Answer, Pid, State3} ->
            ?LLOG(info, "session answer", [], State3),
            State4 = add_link(out, Pid, State3),
            State5 = add_from(out, From, Opts, State4),
            invite_answered(Answer, State5);
        {async, Pid, State3} ->
            ?LLOG(info, "session delayed", [], State3),
            State4 = add_link(out, Pid, State3),
            State5 = add_from(out, From, Opts, State4),
            {noreply, State5};
        {hangup, Reason, State3} ->
            ?LLOG(info, "session hangup: ~p", [Reason], State3),
            gen_server:reply(From, {hangup, Reason}),
            stop_hangup(Reason, State3)
    end;


%% ERROR
answer_op(_AnswerOp, _Opts, From, State) ->
    reply_error(incompatible_session_type, From, State).


%% ===================================================================
%% answer_op - util
%% ===================================================================


%% @private
send_answer_op(AnswerOp, Opts, From, #state{type=Type}=State) ->
    case answer_op_default(AnswerOp) of
        unknown ->
            {reply, {error, unknown_answer_op}, State};
        DefType ->
            Type2 = maps:get(type, Opts, Type),
            Opts2 = Opts#{type=>Type2};

            lager:error("T: ~p", [Type]),


            case update_config(Opts2, State) of
                {ok, #state{has_offer=true}=State2} ->
                    answer_op(AnswerOp, Opts2, From, State2);
                {ok, #state{type=pbx, has_offer=false}=State2} ->
                    case get_pbx_offer(State2) of
                        {ok, State3} ->
                            answer_op(AnswerOp, Opts2, From, State3);
                        {error, Error} ->
                            reply_error(Error, From, State)
                    end;
                {ok, State2} ->
                    reply_error(offer_is_missing, From, State2);
                {error, Error} ->
                    reply_error(Error, From, State)
            end
    end.


%% @private
answer_op_default(Op) ->
    case Op of
        Map when is_map(Map) -> undefined;
        echo -> proxy;
        {mcu, _} -> pbx;
        {publisher, _} -> proxy;
        {invite, _} -> proxy;
        _ -> unknown
    end.


%% @private
answer_op_set_ready(#{sdp:=_}=Answer, #state{has_answer=false}=State) ->
    {ok, State2} = update_config(#{answer=>Answer}, State),
    status(ready, #{answer=>Answer}, State2).


%% @private
answer_op_reply(From, Opts, #state{session=Session}) ->
    Meta = case Opts of
        #{get_answer:=true} -> 
            #{answer=>maps:get(answer, Session)};
        _ -> 
            #{}
    end,
    nklib_util:reply(From, {ok, Meta}).


%% @private
do_send_call(Dest, Opts, Offer, From, State) ->
    #state{id=Id, session=Session} = State,
    gen_server:reply(From, {ok, #{}}),
    Shared = [srv_id, type, mediaserver, wait_timeout, ring_timeout, call_timeout],
    Config1 = maps:with(Shared, Session),
    Config2 = Config1#{session_id=>Id, session_pid=>self(), offer=>Offer}, 
    {ok, CallId, CallPid} = nkmedia_call:start(Dest, Config2),
    State2 = add_link({call, CallId}, CallPid, State),
    State3 = add_from({call, CallId}, From, Opts, State2),
    % Now we will receive notifications from the call
    {noreply, status(calling, #{dest=>Dest}, State3)}.


%% @private Called at the B-leg
invite_ringing(Answer, #state{status=calling}=State) ->
    case Answer of
        #{sdp:=_} ->
            case invite_set_answer(Answer, State) of
                {ok, State2} -> 
                    {noreply, status(ringing, Answer, State2)};
                {error, Error} ->
                    stop_hangup(Error, State)
            end;
        _ ->
            {noreply, status(ringing, Answer, State)}
    end;

invite_ringing(_Answer, State) ->
    {noreply, State}.


%% @private Called at the B-leg
invite_answered(_Answer, #state{status=Status}=State) 
        when Status/=calling, Status/=ringing ->
    ?LLOG(warning, "received unexpected answer", [], State),
    {noreply, State};

invite_answered(#{sdp:=SDP}, #state{session=#{answer:=Old}}=State) ->
    case Old of
        #{sdp:=SDP} ->
            invite_do_ready(State);
        _ ->
            ?LLOG(warning, "ignoring updated SDP!: ~p", [Old], State),
            invite_do_ready(State)
    end;

invite_answered(#{sdp:=_}=Answer, State) ->
    case invite_set_answer(Answer, State) of
        {ok, State2} ->
            invite_do_ready(State2);
        {error, Error} ->
            stop_hangup(Error, State)
    end;

invite_answered(_Answer, State) ->
    stop_hangup(<<"Missing SDP">>, State).


%% @private Called at the B-leg
invite_set_answer(Answer, #state{type=p2p, session=Session}=State) ->
    Session2 = Session#{answer=>Answer},
    {ok, State#state{has_answer=true, session=Session2}};

invite_set_answer(Answer, #state{type=pbx, ms={fs, _}}=State) ->
    #state{id=SessId, session=Session} = State,
    Mod = get_fs_mod(State),
    case Mod:answer_out(SessId, Answer) of
        ok ->
            Session2 = Session#{answer=>Answer},
            {ok, State#state{has_answer=true, session=Session2}};
        {error, Error} ->
            ?LLOG(warning, "mediaserver error in invite_set_answer: ~p", [Error], State),
            {error, <<"Mediaserver Error">>}
    end;

invite_set_answer(Answer, #state{type=proxy, session=Session}=State) ->
    Session2 = Session#{answer=>Answer},
    {ok, State#state{has_answer=true, session=Session2}}.


%% @private
invite_do_ready(#state{type=Type, session=Session}=State) ->
    #{answer:=Answer} = Session,
    State2 = status(ready, #{answer=>Answer}, State),
    {From, Opts, State3} = get_from(out, State),
    answer_op_reply(From, Opts, State3),
    case Type of
        p2p ->
            #{session_id:=PeerId} = Session,
            {noreply, status(call, #{peer_id=>PeerId}, State3)};
        proxy ->
            #{session_id:=PeerId} = Session,
            {noreply, status(call, #{peer_id=>PeerId}, State3)};
        _ ->
            {noreply, State2}
    end.


%% ===================================================================
%% Events
%% ===================================================================



%% @private
do_call_event(_CallId, {status, calling, _}, #state{status=calling}=State) ->
    {noreply, State};

do_call_event(_CallId, {status, ringing, Data}, #state{status=calling}=State) ->
    #state{type=Type} = State,
    HasMedia = case Data of
        #{answer := #{sdp:=_}}  -> true;
        _ -> false
    end,
    case HasMedia of
        true when Type==pbx ->
            case get_pbx_answer(State) of
                {ok, State2} ->
                    {noreply, status(ringing, Data, State2)};
                error ->
                    stop_hangup(<<"Mediaserver Error">>, State)
            end;
        true when Type==proxy ->
            case proxy_get_answer(maps:get(answer, Data), State) of
                {ok, State2} ->
                    {noreply, status(ringing, Data, State2)};
                error ->
                    stop_hangup(<<"Mediaserver Error">>, State)
            end;
        _ ->
            {noreply, status(ringing, Data, State)}
    end;

do_call_event(_CallId, {status, ringing, _Data}, #state{status=ringing}=State) ->
    {noreply, State};

do_call_event(CallId, {status, ready, Data}, #state{status=Status}=State)
        when Status==calling; Status==ringing ->
    #state{session=Session, type=Type} = State,
    {From, Opts, State2} = get_from({call, CallId}, State),
    answer_op_reply(From, Opts, State2),
    % We get the answer and Id of the remote session
    #{answer:=AnswerB, session_peer_id:=PeerId} = Data,
    case Type of
        p2p -> 
            State3 = status(ready, #{answer=>AnswerB}, State2),
            State4 = State3#state{session=Session#{answer=>AnswerB}},
            {noreply, status(call, #{peer_id=>PeerId}, State4)};
        pbx -> 
            case get_pbx_answer(State2) of
                {ok, State4} ->
                    case pbx_bridge(PeerId, State4) of
                        ok ->
                            {noreply, State4};  % Wait for pbx event
                        error ->
                            stop_hangup(<<"Mediaserver Error">>, State4)
                    end;
                error ->
                    stop_hangup(<<"Mediaserver Error">>, State2)
            end;
        proxy ->
            case proxy_get_answer(AnswerB, State2) of
                {ok, State3} ->
                    {noreply, status(call, #{peer_id=>PeerId}, State3)};
                error ->
                    stop_hangup(<<"Mediaserver Error">>, State2)
            end
    end;

do_call_event(CallId, {status, hangup, Data}, #state{status=Status}=State) ->
    {From, _Opts, State2} = get_from({call, CallId}, State),
    #{hangup_reason:=Reason} = Data,
    gen_server:reply(From, {hangup, Reason}),
    if 
        Status==calling; Status==ringing; Status==call ->
            stop_hangup(Reason, State2);
        true ->
            {noreply, remove_link({call, CallId}, State2)}
    end;

do_call_event(_CallId, Event, State) ->
    ?LLOG(warning, "unexpected call event: ~p", [Event], State),
    {noreply, State}.


%% @private
do_pbx_event(parked, #state{status=Status}=State)
        when Status==ready; Status==ringing ->
    {noreply, State};

do_pbx_event(parked, #state{status=Status}=State) ->
    ?LLOG(notice, "received parked in '~p'", [Status], State),
    {noreply, State};

do_pbx_event({bridge, Remote}, State) ->
    {noreply, status(call, #{peer=>Remote}, State)};

do_pbx_event({mcu, McuInfo}, State) ->
    {noreply, status(mcu, McuInfo, State)};

do_pbx_event({hangup, Reason}, State) ->
    stop_hangup(Reason, State);

do_pbx_event(stop, State) ->
    stop_hangup(<<"MediaServer Stop">>, State);

do_pbx_event(Event, State) ->
    ?LLOG(warning, "unexpected ms event: ~p", [Event], State),
    {noreply, State}.




%% ===================================================================
%% Internal - Shared
%% ===================================================================


%% @private
-spec update_config(config(), #state{}) ->
    {ok, #state{}} | {error, term()}.

update_config(Config, #state{session=Session, type=OldType, ms=MS}=State) ->
    try
        Session2 = maps:merge(Session, Config),
        HasOffer = case Session2 of
            #{offer := #{sdp:= _}} -> true;
            _ -> false
        end,
        HasAnswer = case Session2 of
            #{answer := #{sdp:= _}} -> true;
            _ -> false
        end,
        Type = case maps:find(type, Session2) of
            {ok, OldType} ->
                OldType;
            {ok, NewType} when OldType==undefined ->
                NewType;
            {ok, _} -> 
                throw(incompatible_type);
            error ->
                OldType
        end,
        Type2 = case Type of
            undefined when MS==undefined -> undefined;
            undefined when element(1, MS)==fs -> pbx;
            undefined when element(1, MS)==janus -> proxy;
            p2p when MS==undefined -> p2p;
            pbx when MS==undefined -> pbx;
            pbx when element(1, MS)==fs -> pbx;
            proxy when MS==undefined -> proxy;
            proxy when element(1, MS)==janus -> proxy;
            _ -> throw(invalid_session_type)
        end,
        State2 = State#state{
            type = Type,
            session = Session2#{type=>Type},
            has_offer = HasOffer,
            has_answer = HasAnswer
        },
        {ok, State2}
    catch
        throw:Error -> {error, Error}
    end.


%% @private
get_proxy(#state{id=Id, type=proxy}=State) ->
    case get_mediaserver(State) of
        {ok, {janus, JanusId}, State2} ->
            case nkmedia_janus_session:start(Id, JanusId) of
                {ok, Pid} ->
                    {ok, Pid, add_link(janus, Pid, State2)};
                {error, Error} ->
                    {error, {proxy_connect_error, Error}}
            end;
        {error, Error} ->
            {error, {get_proxy_error, Error}}
    end.


%% @private
get_pbx_answer(#state{type=pbx, ms={fs, _}, has_answer=true}=State) ->
    {ok, State};

get_pbx_answer(#state{type=pbx, ms={fs, FsId}, has_answer=false}=State) ->
    #state{id=SessId, session=#{offer:=Offer}} = State,
    case nkmedia_fs_verto:start_in(SessId, FsId, Offer) of
        {ok, SDP} ->
            %% TODO Send and receive pings
            {ok, #{sdp=>SDP}, State};
        {error, Error} ->
            {error, {get_pbx_answer_error, Error}}
    end;

get_pbx_answer(#state{type=pbx, ms=undefined}=State) ->
    case get_mediaserver(State) of
        {ok, {fs, _}, State2} ->
            get_pbx_answer(State2);
        {error, Error} ->
            {error, {get_pbx_answer_error, Error}}
    end.


%% @private
get_pbx_offer(#state{type=pbx, ms={fs, _}, has_offer=true}=State) ->
    {ok, State};

get_pbx_offer(#state{type=pbx, ms={fs, FsId}, has_offer=false}=State) ->
    #state{id=SessId, session=Session} = State,
    Mod = get_fs_mod(State),
    case Mod:start_out(SessId, FsId, #{}) of
        {ok, SDP} ->
            %% TODO Send and receive pings
            Offer1 = maps:get(offer, Session, #{}),
            Offer2 = Offer1#{sdp=>SDP},
            {ok, update_config(#{offer=>Offer2}, State)};
        {error, Error} ->
            {error, {backend_out_error, Error}}
    end;

get_pbx_offer(#state{type=pbx, ms=undefined}=State) ->
        case get_mediaserver(State) of
        {ok, {fs, _}, State2} ->
            get_pbx_offer(State2);
        {error, Error} ->
            {error, {get_pbx_offer_error, Error}}
    end.


%% @private
get_mediaserver(#state{ms=undefined}=State) ->
    #state{srv_id=SrvId, type=Type, session=Session} = State,
    case SrvId:nkmedia_session_get_mediaserver(Type, Session) of
        {ok, MS, Session2} ->
            Session3 = Session2#{mediaserver=>MS},
            {ok, MS, State#state{ms=MS, session=Session3}};
        {error, Error} ->
            {error, Error}
    end;

get_mediaserver(#state{ms=MS}=State) ->
    {ok, MS, State}.


%% @private
pbx_transfer(Dest, #state{id=SessId, ms={fs, FsId}}) ->
    nkmedia_fs_cmd:transfer_inline(FsId, SessId, Dest).


%% @private
pbx_bridge(SessIdB, #state{id=SessIdA, ms={fs, FsId}}=State) ->
    case nkmedia_fs_cmd:set_var(FsId, SessIdA, "park_after_bridge", "true") of
        ok ->
            nkmedia_fs_cmd:bridge(FsId, SessIdA, SessIdB);
        {error, Error} ->
            ?LLOG(warning, "pbx bridge error: ~p", [Error], State),
            error
    end.

proxy_get_answer(AnswerB, #state{id=Id, ms={janus, _}, session=Session}=State) ->
    case nkmedia_janus_session:videocall_answer(Id, AnswerB) of
        {ok, AnswerA} ->
            Session2 = Session#{answer=>AnswerA},
            State2 = State#state{session=Session2},
            {ok, status(ready, #{answer=>AnswerA}, State2)};
        {error, Error} ->
            ?LLOG(warning, "could not get answer from proxy: ~p", [Error], State),
            error
    end.



%% @private
stop_hangup(_Reason, #state{status=hangup}=State) ->
    {stop, normal, State};

stop_hangup(Reason, #state{id=SessId, ms=MS, links=Links, froms=Froms}=State) ->
    lists:foreach(
        fun
            ({{call, CallId}, _, _Mon}) ->
                nkmedia_call:hangup(CallId, <<"Caller Stopped">>);
            ({janus, Pid, _Mon}) ->
                nkmedia_janus_client:stop(Pid);
            (_) ->
                ok
        end,
        Links),
     lists:foreach(
        fun({_Id, From, _Opts}) ->
            gen_server:reply(From, {hangup, Reason})
        end,
        Froms),
    case MS of
        {fs, FsId} ->
            nkmedia_fs_cmd:hangup(FsId, SessId);
        _ ->
            ok
    end,
    {stop, normal, status(hangup, #{hangup_reason=>Reason}, State)}.


%% @private
status(Status, State) ->
    status(Status, #{}, State).


%% @private
status(Status, _Info, #state{status=Status}=State) ->
    restart_timer(State);

%% @private
status(NewStatus, Info, #state{session=Session}=State) ->
    ?LLOG(info, "status changed to ~p", [NewStatus], State),
    State2 = restart_timer(State#state{status=NewStatus}),
    State3 = State2#state{session=Session#{status=>NewStatus, ext_status=>Info}},
    event({status, NewStatus, Info}, State3).


%% @private
event(Event, #state{id=Id}=State) ->
    {ok, State2} = handle(nkmedia_session_event, [Id, Event], State),
    State2.


%% @private
restart_timer(#state{status=hangup, timer=Timer}=State) ->
    nklib_util:cancel_timer(Timer),
    State;

restart_timer(#state{status=Status, timer=Timer, session=Session}=State) ->
    nklib_util:cancel_timer(Timer),
    Time = if
        Status==wait; Status==calling; Status==ready ->
            maps:get(wait_timeout, Session, ?DEF_WAIT_TIMEOUT);
        Status==ringing ->
            maps:get(ring_timeout, Session, ?DEF_RING_TIMEOUT);
        true ->
            maps:get(call_timeout, Session, ?DEF_CALL_TIMEOUT)
    end,
    NewTimer = erlang:start_timer(1000*Time, self(), status_timeout),
    State#state{timer=NewTimer}.


%% @private
handle(Fun, Args, State) ->
    nklib_gen_server:handle_any(Fun, Args, State, #state.srv_id, #state.session).


%% @private
find(Pid) when is_pid(Pid) ->
    {ok, Pid};

find(SessId) ->
    case nklib_proc:values({?MODULE, SessId}) of
        [{undefined, Pid}] -> {ok, Pid};
        [] -> not_found
    end.


%% @private
do_call(SessId, Msg) ->
    do_call(SessId, Msg, 5000).


%% @private
do_call(SessId, Msg, Timeout) ->
    case find(SessId) of
        {ok, Pid} -> nklib_util:call(Pid, Msg, Timeout);
        not_found -> {error, session_not_found}
    end.


%% @private
do_cast(SessId, Msg) ->
    case find(SessId) of
        {ok, Pid} -> gen_server:cast(Pid, Msg);
        not_found -> {error, session_not_found}
    end.


%% @private
get_fs_mod(#state{session=Session}) ->
    case maps:get(sdp_type, Session, webrtc) of
        webrtc -> nkmedia_fs_verto;
        sip -> nkmedia_fs_sip
    end.


%% @private
add_link(Id, Pid, #state{links=Links}=State) when is_pid(Pid) ->
    Link = {Id, Pid, monitor(process, Pid)},
    State#state{links=[Link|Links]};

add_link(_Id, _Pid, State) ->
    State.


%% @private
remove_link(Id, #state{links=Links}=State) ->
    case lists:keyfind(Id, 1, Links) of
        {Id, _Pid, Mon} ->
            nklib_util:demonitor(Mon),
            State#state{links=lists:keydelete(Id, 1, Links)};
        false ->
            State
    end.


%% @private
find_link_pid(Pid, #state{links=Links}) ->
    do_find_link_pid(Pid, Links).

do_find_link_pid(_Pid, []) -> not_found;
do_find_link_pid(Pid, [{Id, Pid, _}|_]) -> Id;
do_find_link_pid(Pid, [_|Rest]) -> do_find_link_pid(Pid, Rest).


%% @private
add_from(_Id, undefined, _Opts, State) ->
    State;

add_from(Id, From, Opts, #state{froms=Froms}=State) ->
    State#state{links=[{Id, From, Opts}|Froms]}.


%% @private
get_from(Id, #state{froms=Froms}=State) ->
    case lists:keytake(Id, 1, Froms) of
        {value, {Id, From, Opts}, Froms2} ->
            {From, Opts, State#state{froms=Froms2}};
        false ->
            {undefined, #{}, State}
    end.


reply_error(Error, undefined, State) ->
    ?LLOG(warning, "operation error: ~p", [Error], State),
    {noreply, State};

reply_error(Error, From, State) ->
    gen_server:reply(From, {error, Error}),
    {noreply, State}.

