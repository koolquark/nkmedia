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
-export([set_offer/3, set_offer_async/3, set_op/3, set_op_async/3, invite_reply/2]).
-export([link_session/3, get_all/0,  peer_event/3]).
-export([find/1, do_cast/2, do_call/2, do_call/3]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, config/0, session/0, event/0, invite_dest/0]).

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Session ~s (~p) "++Txt, 
               [State#state.id, State#state.op | Args])).

-include("nkmedia.hrl").

%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().


-type config() :: 
    #{
        id => id(),                             % Generated if not included
        hangup_after_error => boolean(),        % Default true
        wait_timeout => integer(),              % Secs
        ring_timeout => integer(),          
        ready_timeout => integer(),
        module() => term()                      % Plugin data
    }.


-type invite_dest() :: term().


-type session() ::
    config () | 
    #{
        srv_id => nkservice:id()
    }.


-type offer_op() ::
    sdp     |   % Must include 'offer' in opts
    atom().     % See backends and plugins for supprted operations


-type session_op() ::
    sdp      |   % Must include 'answer' in opts
    invite   |   % Must include 'dest' in opts
    atom().      % See backends and plugins for supprted operations


-type backend() :: 
    p2p | atom().       % Plugins can add backends like freeswitch, janus or kurento


-type op_opts() ::  
    #{
        %% common
        backend => backend(),

        %% sdp operations
        offer => nkmedia:offer(),
        answer => nkmedia:answer(),

        %% invite
        dest => invite_dest(),
        hangup_after_rejected => boolean(),

        %% See backends and plugins for supprted options
        term() => term()
    }.


-type invite_reply() :: 
    ringing                         |   % Informs invite is ringing
    {ringing, nkmedia:answer()}     |   % The same, with answer
    {answered, nkmedia:answer()}    |   % Invite is answered
    {rejected, nkmedia:hangup_reason()}.


-type event() ::
    {offer, nkmedia:offer()}            |   % Offer is available
    {answer, nkmedia:answer()}          |   % Answer is available
    {session_op, session_op(), map()}   |   % An operation is set
    {info, term()}                      |   % User info
    {hangup, nkmedia:hangup_reason()}   |   % Session is about to hangup
    {peer_down, term(), term()}.            % Linked session is down



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


%% @doc Get current session data
-spec get_session(id()) ->
    {ok, session()} | {error, term()}.

get_session(SessId) ->
    do_call(SessId, get_session).


%% @doc Get current status and remaining time to timeout
-spec get_status(id()) ->
    {ok, session_op(), integer()}.

get_status(SessId) ->
    do_call(SessId, get_status).


%% @doc Hangups the session
-spec hangup(id()) ->
    ok | {error, term()}.

hangup(SessId) ->
    hangup(SessId, 16).


%% @doc Hangups the session
-spec hangup(id(), nkmedia:hangup_reason()) ->
    ok | {error, term()}.

hangup(SessId, Reason) ->
    do_cast(SessId, {hangup, Reason}).


%% @private Hangups all sessions
hangup_all() ->
    lists:foreach(fun({SessId, _Pid}) -> hangup(SessId) end, get_all()).


%% @doc Sets the session's offer operation, if not already set
%% See each operaion's doc for returned info
-spec set_offer(id(), offer_op(), op_opts()) ->
    {ok, map()} | {error, term()}.

set_offer(SessId, OfferOp, Opts) ->
    do_call(SessId, {offer_op, OfferOp, Opts}).


%% @doc Equivalent to set_offer/3, but does not wait for operation's result
-spec set_offer_async(id(), offer_op(), op_opts()) ->
    ok | {error, term()}.

set_offer_async(SessId, OfferOp, Opts) ->
    do_cast(SessId, {offer_op, OfferOp, Opts}).


%% @doc Sets the session's current operation.
%% If an operation is already set, can be used to update it or start another,
%% depending on the operation and backend
%% See each operaion's doc for returned info
-spec set_op(id(), session_op(), op_opts()) ->
    {ok, map()} | {error, term()}.

set_op(SessId, AnswerOp, Opts) ->
    do_call(SessId, {session_op, AnswerOp, Opts}).


%% @doc Equivalent to set_op/3, but does not wait for operation's result
-spec set_op_async(id(), session_op(), op_opts()) ->
    ok | {error, term()}.

set_op_async(SessId, AnswerOp, Opts) ->
    do_cast(SessId, {session_op, AnswerOp, Opts}).


%% @doc Informs the session of a ringing or answered status for an invite
-spec invite_reply(id(), invite_reply()) ->
    ok | {error, term()}.

invite_reply(SessId, Reply) ->
    do_cast(SessId, {invite_reply, Reply}).


%% @doc Links this session to another
%% If the other session fails, an event will be generated
-spec link_session(id(), id(), #{send_events=>boolean()}) ->
    ok | {error, term()}.

link_session(SessId, SessIdB, Opts) ->
    do_cast(SessId, {link_session, SessIdB, Opts}).


%% @private
-spec get_all() ->
    [{id(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec peer_event(id(), id(), event()) ->
    ok | {error, term()}.

peer_event(Id, IdB, Event) ->
    do_cast(Id, {peer_event, IdB, Event}).


% ===================================================================
%% gen_server behaviour
%% ===================================================================

-type link_id() ::
    offer | answer | invite | {peer, id()}.

-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    has_offer = false :: boolean(),
    has_answer = false :: boolean(),
    op :: noop | session_op(),
    links :: nkmedia_links:links(link_id()),
    timer :: reference(),
    hangup_sent = false :: boolean(),
    hibernate = false :: boolean(),
    session :: session()
}).


%% @private
-spec init(term()) ->
    {ok, #state{}} | {error, term()}.

init([#{id:=Id, srv_id:=SrvId}=Session]) ->
    true = nklib_proc:reg({?MODULE, Id}),
    nklib_proc:put(?MODULE, Id),
    State1 = #state{
        id = Id, 
        srv_id = SrvId, 
        links = nkmedia_links:new(),
        session = Session
    },
    State2 = update_op(noop, #{}, State1),
    lager:info("NkMEDIA Session ~s starting (~p)", [Id, self()]),
    handle(nkmedia_session_init, [Id], State2).
        

%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(get_session, _From, #state{session=Session}=State) ->
    {reply, {ok, Session}, State};

handle_call(get_status, _From, #state{op=Op, timer=Timer}=State) ->
    {reply, {ok, Op, erlang:read_timer(Timer) div 1000}, State};

handle_call({offer_op, OfferOp, Opts}, From, #state{has_offer=false}=State) ->
    do_offer_op(OfferOp, Opts, From, State);

handle_call({offer_op, _OfferOp, _Opts}, _From, State) ->
    {reply, {error, invalid_status}, State};

handle_call({session_op, AnswerOp, Opts}, From,#state{has_offer=true}=State) ->
    do_session_op(AnswerOp, Opts, From, State);

handle_call({session_op, _AnswerOp, _Opts}, _From, State) ->
    {reply, {error, invalid_status}, State};

handle_call(get_state, _From, State) -> 
    {reply, State, State};

handle_call(Msg, From, State) -> 
    handle(nkmedia_session_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({offer_op, OfferOp, Opts}, #state{has_offer=false}=State) ->
    do_offer_op(OfferOp, Opts, undefined, State);

handle_cast({offer_op, _OfferOp, _Opts}, State) ->
    ?LLOG(warning, "invalid status for offer_op", [], State),
    noreply(State);

handle_cast({session_op, AnswerOp, Opts}, #state{has_offer=true}=State) ->
    do_session_op(AnswerOp, Opts, undefined, State);

handle_cast({session_op, _AnswerOp, _Opts}, State) ->
    ?LLOG(warning, "invalid status for session_op", [], State),
    noreply(State);

handle_cast({info, Info}, State) ->
    noreply(event({info, Info}, State));

handle_cast({invite_reply, Reply}, #state{op=invite}=State) ->
    do_invite_reply(Reply, State);

handle_cast({invite_reply, {rejected, _}}, State) ->
    noreply(State);

handle_cast({invite_reply, Reply}, State) ->
    ?LLOG(notice, "received unexpected invite_reply: ~p", [Reply], State),
    noreply(State);

handle_cast({link_session, IdA, Opts}, #state{id=IdB}=State) ->
    case find(IdA) of
        {ok, Pid} ->
            Events = maps:get(send_events, Opts, false),
            ?LLOG(info, "linked to ~s (events:~p)", [IdA, Events], State),
            gen_server:cast(Pid, {link_session_back, IdB, self(), Events}),
            State2 = add_link({peer, IdA}, {caller, Events}, Pid, State),
            noreply(State2);
        not_found ->
            ?LLOG(warning, "trying to link unknown session ~s", [IdB], State),
            {stop, normal, State}
    end;

handle_cast({link_session_back, IdB, Pid, Events}, State) ->
    ?LLOG(info, "linked back from ~s (events:~p)", [IdB, Events], State),
    State2 = add_link({peer, IdB}, {callee, Events}, Pid, State),
    noreply(State2);

handle_cast({peer_event, PeerId, Event}, State) ->
    case get_link({peer, PeerId}, State) of
        {ok, {Type, true}} ->
            {ok, State2} = 
                handle(nkmedia_session_peer_event, [PeerId, Type, Event], State),
            noreply(State2);
        _ ->            
            noreply(State)
    end;

handle_cast({hangup, Reason}, State) ->
    ?LLOG(info, "external hangup: ~p", [Reason], State),
    do_hangup(Reason, State);

handle_cast(stop, State) ->
    ?LLOG(notice, "user stop", [], State),
    {stop, normal, State};

handle_cast(Msg, State) -> 
    handle(nkmedia_session_handle_cast, [Msg], State).


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({timeout, _, op_timeout}, State) ->
    ?LLOG(info, "operation timeout", [], State),
    do_hangup(607, State);

handle_info({'DOWN', Ref, process, _Pid, Reason}=Msg, State) ->
    case extract_link_mon(Ref, State) of
        not_found ->
            handle(nkmedia_session_handle_info, [Msg], State);
        {ok, Id, Data, State2} ->
            case Reason of
                normal ->
                    ?LLOG(info, "linked ~p down (normal)", [Id], State);
                _ ->
                    ?LLOG(notice, "linked ~p down (~p)", [Id, Reason], State)
            end,
            case Id of
                offer ->
                    do_hangup(<<"Offer Monitor Stop">>, State2);
                answer ->
                    do_hangup(<<"Answer Monitor Stop">>, State2);
                invite ->
                    do_hangup(<<"Invite Monitor Stop">>, State2);
                {peer, IdB} ->
                    {Type, _} = Data,
                    event({peer_down, IdB, Type, Reason}, State),
                    noreply(State2)
            end
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
    ?LLOG(info, "terminate: ~p", [Reason], State),
    {ok, State2} = handle(nkmedia_session_terminate, [Reason], State),
    _ = do_hangup(<<"Process Terminate">>, State2).




%% ===================================================================
%% Internal
%% ===================================================================

%% @private
do_offer_op(OfferOp, Opts, From, State) ->
    case handle(nkmedia_session_offer_op, [OfferOp, Opts], State) of
        {ok, Offer, OfferOp2, Opts2, State2} ->
            case update_offer(Offer, State2) of
                {ok, State3} ->
                   State4 = update_offer_op(OfferOp2, Opts2, State3),
                   reply_ok({ok, Opts2}, From, State4);
                {error, Error, State3} ->
                    reply_error(Error, From, State3)
            end;
        {error, Error, State2} ->
            reply_error(Error, From, State2)
    end.


%% @private
do_session_op(AnswerOp, Opts, From, #state{has_answer=HasAnswer}=State) ->
    case handle(nkmedia_session_session_op, [AnswerOp, Opts], State) of
        {ok, Answer, AnswerOp2, Opts2, State2} ->
            case update_answer(Answer, State2) of
                {ok, State3} ->
                    State4 = update_op(invite, Opts2, State3),
                    case AnswerOp2 of
                        invite ->
                            Dest = maps:get(dest, Opts2),
                            case maps:get(fake, Opts2, false) of
                                false when not HasAnswer ->
                                    do_invite(Dest, Opts2, From, State4);
                                false ->
                                    reply_error(answer_already_set, From, State3);
                                true ->
                                    do_fake_invite(Dest, Opts2, From, State4)
                            end;
                        _ ->
                            reply_ok({ok, Opts2}, From, State4)
                    end;
                {error, Error, State3} ->
                    reply_error(Error, From, State3)
            end;
        {error, Error, State2} ->
            reply_error(Error, From, State2)
    end.


%% @private
do_invite(Dest, Opts, From, #state{id=Id, session=Session, op=invite}=State) ->
    #{offer:=Offer} = Session,
    case handle(nkmedia_session_invite, [Id, Dest, Offer], State) of
        {ringing, Answer, State2} ->
            State3 = invite_link(Answer, Dest, Opts, From, State2),
            do_invite_reply({ringing, Answer}, State3);
        {answer, Answer, State2} ->
            State3 = invite_link(Answer, Dest, Opts, From, State2),
            do_invite_reply({answer, Answer}, State3);
        {rejected, Reason, State2} ->
            do_invite_reply({rejected, Reason}, State2);
        {async, Answer, State2} ->
            ?LLOG(info, "invite delayed", [], State2),
            State3 = invite_link(Answer, Dest, Opts, From, State2),
            noreply(State3)
    end.


%% @private
do_fake_invite(Dest, Opts, From, #state{op=invite}=State) ->
    ?LLOG(warning, "fake invite started", [], State),
    State2 = invite_link(#{}, Dest, Opts, From, State),
    noreply(State2).


%% @private
do_invite_reply(ringing, State) ->
    do_invite_reply({ringing, #{}}, State);

do_invite_reply({ringing, Answer}, State) ->
    case update_answer(Answer, State) of
        {ok, State2} ->
            {ok, #{opts:=Opts}} = get_link(invite, State2),
            Answer2 = maps:remove(sdp, Answer),
            State3 = update_op(invite, Opts#{status=>ringing, answer=>Answer2}, State2),
            noreply(State3);
        {error, Error, State2} ->
            ?LLOG(warning, "could not set answer in invite_ringing", [Error], State),
            do_hangup(<<"Answer Error">>, State2)
    end;

do_invite_reply({answered, Answer}, State) ->
    case update_answer(Answer, State) of
        {ok, #state{has_answer=true}=State2} ->
            {ok, #{from:=From, opts:=Opts}} = get_link(invite, State2),
            {ok, State3} = update_link(invite, undefined, State2),
            Answer2 = maps:remove(sdp, Answer),
            State4 = update_op(invite, Opts#{status=>answered, answer=>Answer2}, State3),
            reply_ok({ok, Opts}, From, State4);
        {ok, State2} ->
            ?LLOG(warning, "invite without SDP!", [], State),
            do_hangup(<<"No SDP">>, State2);
        {error, Error, State2} ->
            ?LLOG(warning, "could not set answer in invite: ~p", [Error], State),
            do_hangup(<<"Answer Error">>, State2)
    end;

do_invite_reply({rejected, Reason}, State) ->
    {ok, #{from:=From, opts:=Opts}} = get_link(invite, State),
    State2 = remove_link(invite, State),
    State3 = update_op(invite, Opts#{status=>rejected, reason=>Reason}, State2),
    case maps:get(hangup_after_rejected, Opts, true) of
        true ->
            do_hangup(<<"Call Rejected">>, State3);
        false ->
            State4 = update_op(noop, #{}, State3),
            reply_ok({rejected, Reason}, From, State4)
    end.



%% @private
invite_link(Answer, Dest, Opts, From, State) ->
    Pid = maps:get(pid, Answer, undefined),
    add_link(invite, #{dest=>Dest, opts=>Opts, from=>From}, Pid, State).



%% ===================================================================
%% Util
%% ===================================================================


%% @private
-spec update_offer(nkmedia:offer(), #state{}) ->
    {ok, #state{}} | {error, term(), #state{}}.

update_offer(Offer, State) when is_map(Offer) ->
    #state{has_offer=HasOffer, session=Session} = State,
    State2 = case Offer of
        #{pid:=Pid} ->
            add_link(offer, none, Pid, State);
        _ ->
            State
    end,
    OldOffer = maps:get(offer, Session, #{}),
    Offer2 = maps:merge(OldOffer, Offer),
    case HasOffer of
        false ->
            set_updated_offer(Offer, State2);
        true ->
            SDP = maps:get(sdp, OldOffer),
            case Offer2 of
                #{sdp:=SDP2} when SDP2 /= SDP ->
                    {error, duplicated_offer, State2};
                _ ->
                    set_updated_offer(Offer2, State2)
            end
    end;

update_offer(_Offer, State) ->
    {error, invalid_offer, State}.


%% @private
set_updated_offer(Offer, #state{has_offer=HasOffer}=State) ->
    case handle(nkmedia_session_updated_offer, [Offer], State) of
        {ok, Offer2, State2} ->
            State3 = update_session(offer, Offer2, State2),
            case Offer2 of
                #{sdp:=_} when not HasOffer ->
                    State4 = State3#state{has_offer=true},
                    {ok, event({offer, Offer2}, State4)};
                _ ->
                    {ok, State3}
            end;
        {error, Error} ->
            {error, Error, State}
    end.


%% @private
update_offer_op(OfferOp, Data, State) ->
    Data2 = maps:remove(offer, Data),
    update_session(offer_op, {OfferOp, Data2}, State).



%% @private
-spec update_answer(nkmedia:answer(), #state{}) ->
    {ok, #state{}} | {error, term(), #state{}}.

update_answer(_Answer, #state{has_offer=false}=State) ->
    {error, offer_not_set, State};

update_answer(Answer, State) when is_map(Answer) ->
    #state{has_answer=HasAnswer, session=Session} = State,
    State2 = case Answer of
        #{pid:=Pid} ->
            add_link(answer, none, Pid, State);
        _ ->
            State
    end,
    OldAnswer = maps:get(answer, Session, #{}),
    Answer2 = maps:merge(OldAnswer, Answer),
    case HasAnswer of
        false ->
            set_updated_answer(Answer2, State2);
        true ->
            SDP = maps:get(sdp, OldAnswer),
            case Answer2 of
                #{sdp:=SDP2} when SDP2 /= SDP ->
                    {error, duplicated_answer, State};
                _ ->
                    set_updated_answer(Answer, State2)
            end
    end;

update_answer(_Answer, State) ->
    {error, invalid_answer, State}.


%% @private
set_updated_answer(Answer, #state{has_answer=HasAnswer}=State) ->
    case handle(nkmedia_session_updated_answer, [Answer], State) of
        {ok, Answer2, State2} ->
            State3 = update_session(answer, Answer2, State2),
            case Answer2 of
                #{sdp:=_} when not HasAnswer ->
                    State4 = State3#state{has_answer=true},
                    {ok, event({answer, Answer2}, State4)};
                _ ->
                    {ok, State3}
            end;
        {error, Error} ->
            {error, Error, State}
    end.


%% @private
update_op(Op, Data, State) ->
    #state{timer=Timer, session=Session, has_offer=HasOffer} = State,
    nklib_util:cancel_timer(Timer),
    Time = case Op of
        noop ->
            maps:get(wait_timeout, Session, ?DEF_WAIT_TIMEOUT);
        invite ->
            case Data of
                #{status:=answered} ->
                    maps:get(ready_timeout, Session, ?DEF_READY_TIMEOUT);
                _ ->
                    maps:get(ring_timeout, Session, ?DEF_RING_TIMEOUT)
            end;
        _ ->
            maps:get(ready_timeout, Session, ?DEF_READY_TIMEOUT)
    end,
    NewTimer = erlang:start_timer(1000*Time, self(), op_timeout),
    Hibernate = Op /= noop,
    State2 = update_session(session_op, {Op, Data}, State#state{op=Op}),
    State3 = case HasOffer of
        true -> event({session_op, Op, Data}, State2);
        false -> State2
    end,
    State3#state{timer=NewTimer, op=Op, hibernate=Hibernate}.


%% @private
reply_ok(Reply, From, State) ->
    nklib_util:reply(From, Reply),
    noreply(State).


reply_error(Error, From, #state{session=Session}=State) ->
    nklib_util:reply(From, {error, Error}),
    case maps:get(hangup_after_error, Session, true) of
        true ->
            ?LLOG(warning, "operation error: ~p", [Error], State),
            do_hangup(<<"Operation Error">>, State);
        false ->
            noreply(State)
    end.


%% @private
do_hangup(_Reason, #state{hangup_sent=true}=State) ->
    {stop, normal, State};

do_hangup(Reason, State) ->
    {ok, State2} = handle(nkmedia_session_hangup, [Reason], State),
    iter_links(
        fun
            (invite, #{from:=From}) ->
                nklib_util:reply(From, {hangup, Reason});
            (_, _) ->
                ok
        end,
        State2),
    {stop, normal, event({hangup, Reason}, State2#state{hangup_sent=true})}.


%% @private
event(Event, #state{id=Id}=State) ->
    case Event of
        {offer, _} ->
            ?LLOG(info, "sending 'offer'", [], State);
        {answer, _} ->
            ?LLOG(info, "sending 'answer'", [], State);
        _ -> 
            ?LLOG(info, "sending 'event': ~p", [Event], State)
    end,
    iter_links(
        fun
            ({peer, PeerId}, {_Type, true}) -> peer_event(PeerId, Id, Event);
            (_, _) -> ok
        end,
        State),
    {ok, State2} = handle(nkmedia_session_event, [Id, Event], State),
    State2.


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
    do_call(SessId, Msg, 1000*?DEF_RING_TIMEOUT).


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
update_session(Key, Val, #state{session=Session}=State) ->
    Session2 = maps:put(Key, Val, Session),
    State#state{session=Session2}.


%% @private
noreply(#state{hibernate=true}=State) ->
    {noreply, State#state{hibernate=false}, hibernate};
noreply(State) ->
    {noreply, State}.


%% @private
add_link(Id, Data, Pid, State) ->
    nkmedia_links:add(Id, Data, Pid, #state.links, State).


%% @private
get_link(Id, State) ->
    nkmedia_links:get(Id, #state.links, State).


%% @private
update_link(Id, Data, State) ->
    nkmedia_links:update(Id, Data, #state.links, State).


%% @private
remove_link(Id, State) ->
    nkmedia_links:remove(Id, #state.links, State).


%% @private
extract_link_mon(Mon, State) ->
    nkmedia_links:extract_mon(Mon, #state.links, State).


%% @private
iter_links(Fun, State) ->
    nkmedia_links:iter(Fun, #state.links, State).
