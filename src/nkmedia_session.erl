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

-export([start/3, get_status/1, get_session/1, get_offer/1, get_answer/1]).
-export([stop/1, stop/2, stop_all/0]).
-export([answer/2, answer_async/2, update/2, update_async/2]).
-export([register/2, unregister/2, link_session/3, get_all/0,  peer_event/3]).
-export([find/1, do_cast/2, do_call/2, do_call/3]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, config/0, session/0, event/0]).

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Session ~s (~p) "++Txt, 
               [State#state.id, State#state.class | Args])).

-include("nkmedia.hrl").

%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().


-type config() :: 
    #{
        id => id(),                             % Generated if not included
        wait_timeout => integer(),              % Secs
        ready_timeout => integer(),
        backend => nkemdia:backend(),
        hangup_after_error => boolean(),        % Default true
        {link, term()} => pid(),
        events => {hangup, pid()},              % Start an event registration
        term() => term()                        % Plugin data
    }.




-type session() ::
    config () | 
    #{
        srv_id => nkservice:id(),
        class => nkmedia:class()
    }.



-type event() ::
    {answer, nkmedia:answer()}          |   % Answer SDP is available
    {info, term()}                      |   % User info
    {update_class, term()}              |
    {hangup, nkmedia:hangup_reason()}   |   % Session is about to hangup
    {peer_down, term(), term()}.            % Linked session is down



%% ===================================================================
%% Public
%% ===================================================================

%% @private
-spec start(nkservice:id(), nkmedia:class(), config()) ->
    {ok, id(), pid(), Reply::map()} | {error, nkservice:error()}.

start(Srv, Class, Config) ->
    case nkservice_srv:get_srv_id(Srv) of
        {ok, SrvId} ->
            Config2 = Config#{class=>Class, srv_id=>SrvId},
            {SessId, Config3} = nkmedia_util:add_uuid(Config2),
            {ok, SessPid} = gen_server:start(?MODULE, [Config3], []),
            case gen_server:call(SessPid, do_start) of
                {ok, Reply} ->
                    {ok, SessId, SessPid, Reply};
                {error, Error} ->
                    {error, Error}
            end;
        not_found ->
            {error, service_not_found}
    end.


%% @doc Get current session data
-spec get_session(id()) ->
    {ok, session()} | {error, nkservice:error()}.

get_session(SessId) ->
    do_call(SessId, get_session).


%% @doc Get current session offer
-spec get_offer(id()) ->
    {ok, nkmedia:offer()} | {error, nkservice:error()}.

get_offer(SessId) ->
    do_call(SessId, get_offer).


%% @doc Get current session answer
-spec get_answer(id()) ->
    {ok, nkmedia:answer()} | {error, nkservice:error()}.

get_answer(SessId) ->
    do_call(SessId, get_answer).


%% @doc Get current status and remaining time to timeout
-spec get_status(id()) ->
    {ok, map(), integer()}.

get_status(SessId) ->
    do_call(SessId, get_status).


%% @doc Hangups the session
-spec stop(id()) ->
    ok | {error, nkservice:error()}.

stop(SessId) ->
    stop(SessId, 16).


%% @doc Hangups the session
-spec stop(id(), nkmedia:stop_reason()) ->
    ok | {error, nkservice:error()}.

stop(SessId, Reason) ->
    do_cast(SessId, {stop, Reason}).


%% @private Hangups all sessions
stop_all() ->
    lists:foreach(fun({SessId, _Pid}) -> stop(SessId) end, get_all()).


%% @doc Sets the session's current answer operation.
%% See each operation's doc for returned info
%% Some backends my support updating answer (like Freeswitch)
-spec answer(id(), nkmedia:answer()) ->
    ok | {error, nkservice:error()}.

answer(SessId, Answer) ->
    do_call(SessId, {answer, Answer}).


%% @doc Equivalent to answer/3, but does not wait for operation's result
-spec answer_async(id(), nkmedia:answer()) ->
    ok | {error, nkservice:error()}.

answer_async(SessId, Answer) ->
    do_call(SessId, {answer, Answer}).


%% @doc Sets the session's current answer operation.
%% See each operation's doc for returned info
%% Some backends my support updating answer (like Freeswitch)
-spec update(id(), nkmedia:update()) ->
    ok | {error, nkservice:error()}.

update(SessId, Update) ->
    do_call(SessId, {update, Update}).


%% @doc Equivalent to update/3, but does not wait for operation's result
-spec update_async(id(), nkmedia:update()) ->
    ok | {error, nkservice:error()}.

update_async(SessId, Update) ->
    do_call(SessId, {update, Update}).


%% @doc Links this session to another
%% If the other session fails, an event will be generated
-spec link_session(id(), id(), #{send_events=>boolean()}) ->
    ok | {error, nkservice:error()}.

link_session(SessId, SessIdB, Opts) ->
    do_call(SessId, {link_session, SessIdB, Opts}).


%% @doc Registers a process with the session
-spec register(id(), term()) ->
    {ok, pid()} | {error, nkservice:error()}.

register(SessId, Term) ->
    do_call(SessId, {register, Term, self()}).


%% @doc Registers a process with the session
-spec unregister(id(), term()) ->
    {ok, pid()} | {error, nkservice:error()}.

unregister(SessId, Term) ->
    do_call(SessId, {unregister, Term}).


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
    ok | {error, nkservice:error()}.

peer_event(Id, IdB, Event) ->
    do_cast(Id, {peer_event, IdB, Event}).


% ===================================================================
%% gen_server behaviour
%% ===================================================================

-type link_id() ::
    {user, term()} | {peer, id()} | {reg, term()}.

-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    class :: nkmedia:class(),
    has_answer = false :: boolean(),
    links :: nkmedia_links:links(link_id()),
    timer :: reference(),
    stop_sent = false :: boolean(),
    hibernate = false :: boolean(),
    session :: session()
}).


%% @private
-spec init(term()) ->
    {ok, #state{}} | {error, term()}.

init([#{id:=Id, class:=Class, srv_id:=SrvId}=Session]) ->
    true = nklib_proc:reg({?MODULE, Id}),
    nklib_proc:put(?MODULE, Id),
    State1 = #state{
        id = Id, 
        srv_id = SrvId, 
        class = Class,
        links = nkmedia_links:new(),
        session = Session
    },
    case Session of
        #{events := {Sub, EventPid}} ->
            {ok, _} = nkservice_events:reg(media, session, Sub, Id, #{}, EventPid);
        _ -> 
            ok
    end,
    State2 = lists:foldl(
        fun
            ({{link, LId}, Pid}, Acc) -> add_link({user, LId}, none, Pid, Acc);
            (_, Acc) -> Acc
        end,
        State1,
        maps:to_list(Session)),
    lager:info("NkMEDIA Session ~s starting (~p)", [Id, self()]),
    handle(nkmedia_session_init, [Id], restart_timer(State2)).
        

%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(do_start, From, State) ->
    do_set_class(From, State);

handle_call(get_session, _From, #state{session=Session}=State) ->
    {reply, {ok, Session}, State};

handle_call(get_status, _From, #state{class=Class, timer=Timer}=State) ->
    {reply, {ok, Class, erlang:read_timer(Timer) div 1000}, State};

handle_call({answer, Answer}, From, State) ->
    do_set_answer(Answer, From, State);

handle_call({update, Update}, From, State) ->
    do_update(Update, From, State);

handle_call(get_state, _From, State) -> 
    {reply, State, State};

handle_call(get_offer, _From, #{session:=#{offer:=Offer}}=State) -> 
    {reply, {ok, Offer}, State};

handle_call(get_answer, _From, #{session:=Session}=State) -> 
    Reply = case maps:find(answer, Session) of
        {ok, Answer} -> {ok, Answer};
        error -> {error, answer_not_set}
    end,
    {reply, Reply, State};

handle_call({link_session, IdA, Opts}, From, #state{id=IdB}=State) ->
    case find(IdA) of
        {ok, Pid} ->
            Events = maps:get(send_events, Opts, false),
            ?LLOG(info, "linked to ~s (events:~p)", [IdA, Events], State),
            gen_server:cast(Pid, {link_session_back, IdB, self(), Events}),
            State2 = add_link({peer, IdA}, {caller, Events}, Pid, State),
            gen_server:reply(From, ok),
            noreply(State2);
        not_found ->
            ?LLOG(warning, "trying to link unknown session ~s", [IdB], State),
            {stop, normal, State}
    end;

handle_call({register, Term, Pid}, From, State) ->
    ?LLOG(info, "linked to ~p (~p)", [Term, Pid], State),
    State2 = add_link({reg, Term}, none, Pid, State),
    gen_server:reply(From, ok),
    noreply(State2);

handle_call({unregister, Term}, From, State) ->
    ?LLOG(info, "unlinked from ~p", [Term], State),
    State2 = remove_link({reg, Term}, State),
    gen_server:reply(From, ok),
    noreply(State2);

handle_call(Msg, From, State) -> 
    handle(nkmedia_session_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({answer, Answer}, State) ->
    do_set_answer(Answer, undefined, State);

handle_cast({update, Update}, State) ->
    do_update(Update, undefined, State);

handle_cast({info, Info}, State) ->
    noreply(event({info, Info}, State));

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
    do_stop(Reason, State);

handle_cast(stop, State) ->
    ?LLOG(notice, "user stop", [], State),
    {stop, normal, State};

handle_cast(Msg, State) -> 
    handle(nkmedia_session_handle_cast, [Msg], State).


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({timeout, _, session_timeout}, State) ->
    ?LLOG(info, "operation timeout", [], State),
    do_stop(session_timeout, State);

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
                {user, _User} ->
                    do_stop(user_monitor_stop, State2);
                {peer, IdB} ->
                    {Type, _} = Data,
                    event({peer_down, IdB, Type, Reason}, State),
                    noreply(State2);
                {reg, _Term} ->
                    do_stop(reg_monitor_stop, State2)
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

terminate(Reason, #state{id=Id, session=Session}=State) ->
    case Session of
        #{events := {Sub, EventPid}} ->
            nkservice_events:unreg(media, session, Sub, Id, EventPid);
        _ -> 
            ok
    end,
    ?LLOG(info, "terminate: ~p", [Reason], State),
    _ = do_stop(<<"Process Terminate">>, State),
    _ = handle(nkmedia_session_terminate, [Reason], State).




%% ===================================================================
%% Internal
%% ===================================================================


%% @private
do_set_class(From, #state{class=Class}=State) ->
    case handle(nkmedia_session_class, [Class], State) of
        {ok, Class2, Reply, #state{session=Session2}=State2} ->
            case Session2 of
                #{offer:=#{sdp:=_}} ->
                    State3 = case Session2 of
                        #{answer:=#{sdp:=_}} ->
                            restart_timer(State2#state{has_answer=true});
                        _ ->
                            restart_timer(State2)
                    end,
                    reply_ok({ok, Reply}, From, update_class(Class2, State3));
                _ ->
                    reply_error(missing_offer, From, State2)
            end;
        {error, Error, State2} ->
            reply_error(Error, From, State2)
    end.


%% @private
do_set_answer(_Answer, From, #state{has_answer=true}=State) ->
    reply_error(answer_already_set, From, State);

do_set_answer(Answer, From, #state{class=Class}=State) ->
    case handle(nkmedia_session_answer, [Class, Answer], State) of
        {ok, Reply, #{sdp:=_}=Answer2, State2} ->
            State3 = update_session(answer, Answer2, State2),
            State4 = restart_timer(State3#state{has_answer=true}),
            State5 = event({answer, Answer2}, State4),
            reply_ok({ok, Reply}, From, State5);
        {ok, _, State2} ->
            reply_error(invalid_answer, From, State2);
        {error, Error, State2} ->
            reply_error(Error, From, State2)
    end.


%% @private
do_update(Update, From, #state{class=Class, has_answer=true}=State) ->
    case handle(nkmedia_session_update, [Class, Update], State) of
        {ok, Class2, Reply, State2} ->
           reply_ok({ok, Reply}, From, update_class(Class2, State2));
        {error, Error, State2} ->
            reply_error(Error, From, State2)
    end;

do_update(_Update, From, State) ->
    reply_error(answer_not_set, From, State).




%% ===================================================================
%% Util
%% ===================================================================




%% @private
update_class(Class, #state{class=Class}=State) ->
    State;

update_class(Class, State) ->
    State2 = update_session(class, Class, State),
    event({updated_class, Class}, State2#state{class=Class}).


%% @private
restart_timer(State) ->
    #state{
        timer = Timer, 
        session = Session, 
        has_answer = HasAnswer
    } = State,
    nklib_util:cancel_timer(Timer),
    Time = case HasAnswer of
        true -> maps:get(ready_timeout, Session, ?DEF_READY_TIMEOUT);
        false -> maps:get(wait_timeout, Session, ?DEF_WAIT_TIMEOUT)
    end,
    NewTimer = erlang:start_timer(1000*Time, self(), session_timeout),
    State#state{timer=NewTimer}.


%% @private
reply_ok(Reply, From, State) ->
    nklib_util:reply(From, Reply),
    noreply(State).


%% @private
reply_error(Error, From, #state{session=Session}=State) ->
    nklib_util:reply(From, {error, Error}),
    case maps:get(hangup_after_error, Session, true) of
        true ->
            do_stop(operation_error, State);
        false ->
            noreply(State)
    end.


%% @private
do_stop(_Reason, #state{stop_sent=true}=State) ->
    {stop, normal, State};

do_stop(Reason, State) ->
    {ok, State2} = handle(nkmedia_session_stop, [Reason], State),
    {stop, normal, event({stop, Reason}, State2#state{stop_sent=true})}.


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
    State2 = fold_links(
        fun
            ({peer, PeerId}, {_Type, true}, AccState) -> 
                peer_event(PeerId, Id, Event),
                AccState;
            ({reg, Reg}, none, AccState) ->
                {ok, AccState2} = 
                    handle(nkmedia_session_reg_event, [Id, Reg, Event], AccState),
                    AccState2;
            (_, _, AccState) -> 
                AccState
        end,
        State),
    {ok, State3} = handle(nkmedia_session_event, [Id, Event], State2),
    State3.


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
    do_call(SessId, Msg, ?DEF_SYNC_TIMEOUT).


%% @private
do_call(SessId, Msg, Timeout) ->
    case find(SessId) of
        {ok, Pid} -> nkservice_util:call(Pid, Msg, Timeout);
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


% %% @private
% update_link(Id, Data, State) ->
%     nkmedia_links:update(Id, Data, #state.links, State).


%% @private
remove_link(Id, State) ->
    nkmedia_links:remove(Id, #state.links, State).


%% @private
extract_link_mon(Mon, State) ->
    nkmedia_links:extract_mon(Mon, #state.links, State).


%% @private
fold_links(Fun, State) ->
    nkmedia_links:fold(Fun, State, #state.links, State).






