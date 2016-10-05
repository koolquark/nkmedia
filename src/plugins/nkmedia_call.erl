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

%% @doc Call management
%%
%% Typical call process:
%% - A session is started
%% - A call is started, linking it with the session (using session_id)
%%   If the session goes down, the call is stopped with session_failed
%% - The call calls nkmedia_call_resolve and nkmedia_call_invite
%% 


%% - The call registers itself with the session
%% - When the call has an answer, it is captured in nkmedia_call_reg_event
%%   (nkmedia_callbacks) and sent to the session. Same with hangups
%% - If the session stops, it is captured in nkmedia_session_reg_event
%% - When the call stops, the called process must detect it in nkmedia_call_reg_event

-module(nkmedia_call).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start/3, ringing/2, ringing/3, answered/3, rejected/2]).
-export([hangup/2, hangup_all/0]).
-export([register/2, unregister/2, session_event/3]).
-export([find/1, get_all/0, get_call/1]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, event/0]).


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Call ~s "++Txt, [State#state.id | Args])).

-include("../../include/nkmedia.hrl").
-include("../../include/nkmedia_call.hrl").
-include_lib("nkservice/include/nkservice.hrl").



%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().

-type caller() :: term().

-type callee() :: term().

-type callee_id() :: nklib:link().

-type callee_session_id() :: session_id().

-type call_type() :: user | session | atom(). % Also nkmedia_verto, ...

-type session_id() :: nkmedia_session:id().

-type config() ::
    #{
        call_id => id(),                        % Optional
        type => call_type(),                    % Optional, used in resolvers
        caller => caller(),                     % Caller info
        backend => nkmedia:backend(),
        sdp_type => nkmedia:sdp_type(),
        caller_session_id => session_id(),      % Generated if not included
        register => nklib:link(),
        user_id => nkservice:user_id(),             % Informative only
        user_session => nkservice:user_session()    % Informative only
    }.


-type call() ::
    config() |
    #{
        srv_id => nkservice:id(),
        callee => callee(),
        callee_session_id => callee_session_id()
    }.


-type event() :: 
    {ringing, nklib:link(), nkmedia:answer()} | 
    {answer, nklib:link(), nkmedia:answer()} | 
    {hangup, nkservice:error()}.


-type dest() :: term().

-type dest_ext() ::
    #{
        dest => dest(),
        wait => integer(),                      %% secs
        ring => integer(),
        sdp_type => webrtc | rtp
    }.



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Starts a new call to a callee
%% - nkmedia_call_resolve is called to get destinations from callee
%% - once we have all destinations, nkmedia_call_invite is called for each
%% - callees must call ringing, answered, rejected
-spec start(nkservice:id(), callee(), config()) ->
    {ok, id(), pid()}.

start(Srv, Callee, Config) ->
    case nkservice_srv:get_srv_id(Srv) of
        {ok, SrvId} ->
            Config2 = Config#{srv_id=>SrvId, callee=>Callee},
            {CallId, Config3} = nkmedia_util:add_id(call_id, Config2),
            {ok, Pid} = gen_server:start(?MODULE, [Config3], []),
            {ok, CallId, Pid};
        not_found ->
            {error, service_not_found}
    end.



%% @doc Called by the invited process
-spec ringing(id(), callee_id() | callee_session_id()) ->
    ok | {error, term()}.

ringing(CallId, CalleeId) ->
    ringing(CallId, CalleeId, #{}).


%% @doc Called by the invited process
-spec ringing(id(), callee_id() | callee_session_id(), callee()) ->
    ok | {error, term()}.

ringing(CallId, CalleeId, Callee) ->
    do_call(CallId, {ringing, CalleeId, Callee}).


%% @doc Called by the invited process
-spec answered(id(), callee_id() | callee_session_id(), callee()) ->
    ok | {error, term()}.

answered(CallId, CalleeId, Callee) ->
    do_call(CallId, {answered, CalleeId, Callee}).


%% @doc Called by the invited process
-spec rejected(id(), callee_id() | callee_session_id()) ->
    ok | {error, term()}.

rejected(CallId, CalleeId) ->
    do_cast(CallId, {rejected, CalleeId}).


%% @doc
-spec hangup(id(), nkservice:error()) ->
    ok | {error, term()}.

hangup(CallId, Reason) ->
    do_cast(CallId, {hangup, Reason}).


%% @private
hangup_all() ->
    lists:foreach(fun({CallId, _Pid}) -> hangup(CallId, 16) end, get_all()).


%% @doc Registers a process with the call
-spec register(id(), nklib:link()) ->
    {ok, pid()} | {error, nkservice:error()}.

register(CallId, Link) ->
    do_call(CallId, {register, Link}).


%% @doc Registers a process with the call
-spec unregister(id(), nklib:link()) ->
    ok | {error, nkservice:error()}.

unregister(CallId, Link) ->
    do_call(CallId, {unregister, Link}).


%% @private
-spec session_event(id(), session_id(), nkmedia_session:event()) ->
    ok | {error, term()}.
session_event(CallId, SessId, Event) ->
    do_cast(CallId, {session_event, SessId, Event}).


%% @private
-spec get_all() ->
    [{id(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).


%% @doc
-spec get_call(id()) ->
    {ok, call()} | {error, term()}.

get_call(CallId) ->
    do_call(CallId, get_call).


% ===================================================================
%% gen_server behaviour
%% ===================================================================

-record(invite, {
    pos :: integer(),
    dest :: dest(),
    ring :: integer(),
    sdp_type :: webrtc | rtp,
    launched :: boolean(),
    timer :: reference(),
    link :: nklib:link(),
    session_id :: session_id()
}).

-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    links :: nklib_links:links(),
    invites = [] :: [#invite{}],
    pos = 0 :: integer(),
    stop_sent = false :: boolean(),
    call :: call()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()}.

init([#{srv_id:=SrvId, call_id:=CallId, callee:=Callee}=Call]) ->
    nklib_proc:put(?MODULE, CallId),
    nklib_proc:put({?MODULE, CallId}),  
    State1 = #state{
        id = CallId, 
        srv_id = SrvId,
        links = nklib_links:new(),
        call = Call
    },
    ?LLOG(info, "starting to ~p (~p)", [Callee, self()], State1),
    State2 = case Call of
        #{register:=Link} -> 
            links_add(Link, reg, State1);
        _ ->
            State1
    end,
    case handle(nkmedia_call_init, [CallId], State2) of
        {ok, #state{call=Call3}=State3} ->
            case Call3 of
                #{caller_session_id:=_} ->
                    gen_server:cast(self(), started_caller_session);
                _ ->
                    gen_server:cast(self(), start_caller_session),
                    {ok, State3}
            end;
        {error, Error} ->
            {stop, Error}
    end.




%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call({ringing, Id, Callee}, _From, State) ->
    case find_invite_by_id(Id, State) of
        {ok, #invite{link=Link}} ->
            {reply, ok, event({ringing, Link, Callee}, State)};
        not_found ->
            {reply, {error, invite_not_found}, State} 
    end;

handle_call({answered, Id, Callee}, _From, State) ->
    #state{id=CallId, call=Call} = State,
    case find_invite_by_id(Id, State) of
        {ok, #invite{pos=Pos, link=Link, session_id=CalleeSessId}} ->
            #{caller_session_id:=CallerSessId} = Call,
            Args = [CallId, CallerSessId, CalleeSessId, Callee],
            case handle(nkmedia_call_set_answer, Args, State) of
                {ok, State2} ->
                    State3 = cancel_all_but(Pos, State2),
                    Call2 = ?CALL(#{callee_session_id=>CalleeSessId}, Call),
                    State4 = State3#state{call=Call2},
                    State5 = links_add(Link, callee_link, State4),
                    Callee2 = maps:remove(answer, Callee),
                    {reply, ok, event({answer, Link, Callee2}, State5)};
                {error, Error, State2} ->
                    {reply, {error, Error}, State2}
            end;
        not_found ->
            {reply, {error, invite_not_found}, State}
    end;

handle_call(get_call, _From, #state{call=Call}=State) -> 
    {reply, {ok, Call}, State};

handle_call({register, Link}, _From, State) ->
    ?LLOG(info, "proc registered (~p)", [Link], State),
    State2 = links_add(Link, reg, State),
    {reply, {ok, self()}, State2};

handle_call({unregister, Link}, _From, State) ->
    ?LLOG(info, "proc unregistered (~p)", [Link], State),
    State2 = links_remove(Link, State),
    {reply, ok, State2};

handle_call(get_state, _From, State) ->
    {reply, State, State};

handle_call(Msg, From, State) -> 
    handle(nkmedia_call_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast(start_caller_session, #state{id=CallId}=State) ->
    case handle(nkmedia_call_start_caller_session, [CallId], State) of
        {ok, SessId, #state{call=Call}=State2} ->
            Call2 = ?CALL(#{caller_session_id=>SessId}, Call),
            handle_cast(started_caller_session, State2#state{call=Call2});
        {error, Error, State2} ->
            do_hangup(Error, State2)
    end;

handle_cast(started_caller_session, #state{id=CallId, call=Call}=State) ->
    #{caller_session_id:=SessId} = Call,
    case nkmedia_session:register(SessId, {nkmedia_call, CallId, self()}) of
        {ok, Pid} ->
            State2 = links_add(SessId, caller_session_id, Pid, State),
            do_start(State2);
        {error, Error, State2} ->
            do_hangup(Error, State2)
    end;

handle_cast({rejected, Id}, State) ->
    case find_invite_by_id(Id, State) of
        {ok, #invite{pos=Pos}} ->
            remove_invite(Pos, call_rejected, State);
        not_found ->
            {noreply, State}
    end;

handle_cast({session_event, SessId, {answer, Answer}}, #state{call=Call}=State) ->
    case Call of
        #{caller_session_id:=SessId, register:=Link} ->
            {noreply, event({session_answer, SessId, Answer}, Link, State)};
        #{caller_session_id:=_} ->
            ?LLOG(notice, "received session answer with no caller registration", 
                  [], State),
            {noreply, State};
        _ ->
            case find_invite_by_id(SessId, State) of
                {ok, #invite{link=Link}} ->
                    {noreply, event({session_answer, SessId, Answer}, Link, State)};
                not_found ->
                    ?LLOG(notice, "received unexpected session answer: ~p", 
                          [SessId], State),
                    {noreply, State}
            end
    end;

handle_cast({session_event, SessId, {candidate, Candidate}}, #state{call=Call}=State) ->
    case Call of
        #{caller_session_id:=SessId, register:=Link} ->
            {noreply, event({session_candidate, SessId, Candidate}, Link, State)};
        #{caller_session_id:=_} ->
            ?LLOG(notice, "received session candidate with no caller registration", 
                  [], State),
            {noreply, State};
        _ ->
            case find_invite_by_id(SessId, State) of
                {ok, #invite{link=Link}} ->
                    {noreply, event({session_candidate, SessId, Candidate}, Link, State)};
                not_found ->
                    ?LLOG(notice, "received unexpected session candidate: ~p", 
                          [SessId], State),
                    {noreply, State}
            end
    end;

handle_cast({session_event, SessId, {stop, _Reason}}, #state{call=Call}=State) ->
    case Call of
        #{caller_session_id:=SessId} ->
            do_hangup(caller_stopped, State);
        #{callee_session_id:=SessId} ->
            do_hangup(callee_stopped, State);
        _ ->
            rejected(self(), SessId),
            {noreply, State}
    end;

handle_cast({session_event, _SessId, _Event}, State) ->
    {noreply, State};

handle_cast({hangup, Reason}, State) ->
    ?LLOG(info, "external hangup: ~p", [Reason], State),
    do_hangup(Reason, State);

handle_cast(Msg, State) -> 
    handle(nkmedia_call_handle_cast, [Msg], State).


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({launch_out, Pos}, State) ->
    case find_invite_by_pos(Pos, State) of
        {ok, #invite{launched=false, ring=Ring}=Out} ->
            Timer = erlang:send_after(1000*Ring, self(), {ring_timeout, Pos}),
            launch_out(Out#invite{timer=Timer}, State);
        {ok, Out} ->
            launch_out(Out, State);
        not_found ->
            % The call should have been removed because of timeout
            {noreply, State}
    end;

handle_info({ring_timeout, Pos}, State) ->
    case find_invite_by_pos(Pos, State) of
        {ok, #invite{dest=Dest}} ->
            ?LLOG(info, "call ring timeout for ~p (~p)", [Dest, Pos], State),
            remove_invite(Pos, ring_timeout, State);
        not_found ->
            {noreply, State}
    end;

handle_info({'DOWN', Ref, process, _Pid, Reason}=Msg, #state{call=Call}=State) ->
    case links_down(Ref, State) of
        {ok, Link, Data, State2} ->
            case Reason of
                normal ->
                    ?LLOG(info, "linked ~p down (normal)", [Link], State);
                _ ->
                    ?LLOG(notice, "linked ~p down (~p)", [Link, Reason], State)
            end,
            case Data of
                caller_session_id ->
                    do_hangup(caller_stopped, State2);
                callee_session_id ->
                    case maps:find(callee_session_id, Call) of
                        {ok, Link} ->
                            do_hangup(callee_stopped, State2);
                        error ->
                            rejected(self(), Link)
                    end;
                reg ->
                    do_hangup(registered_down, State2)
            end;
        not_found ->
            handle(nkmedia_call_handle_info, [Msg], State)
    end;

handle_info(Msg, #state{}=State) -> 
    handle(nkmedia_call_handle_info, [Msg], State).


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(Reason, State) ->
    State2 = cancel_all(State),
    {stop, normal, State3} = do_hangup(process_down, State2),
    catch handle(nkmedia_call_terminate, [Reason], State3),
    ?LLOG(info, "stopped: ~p", [Reason], State2).


% ===================================================================
%% Internal
%% ===================================================================

%% @private
do_start(#state{call=#{callee:=Callee}=Call}=State) ->
    Type = maps:get(type, Call, all),
    {ok, ExtDests, State2} = handle(nkmedia_call_resolve, [Callee, Type, []], State),
    State3 = launch_invites(ExtDests, State2),
    {noreply, State3}.

%% @private Generate data and launch messages
-spec launch_invites(callee() | [dest_ext()], State) ->
    State.

launch_invites([], #state{invites=Invs}=State) ->
    ?LLOG(info, "resolved invites: ~p", [Invs], State),
    case length(Invs) of
        0 -> 
            hangup(self(), no_destination);
        _ -> 
            ok
    end,        
    State;

launch_invites([#{dest:=Dest}=DestEx|Rest], #state{invites=Invs, pos=Pos}=State) ->
    Wait = case maps:find(wait, DestEx) of
        {ok, Wait0} -> Wait0;
        error -> 0
    end,
    Ring = case maps:find(ring, DestEx) of
        {ok, Ring0} -> min(Ring0, ?MAX_RING_TIMEOUT);
        error -> ?DEF_RING_TIMEOUT
    end,
    Inv = #invite{
        pos = Pos,
        dest = Dest, 
        ring = Ring, 
        launched = false,
        sdp_type = maps:get(sdp_type, DestEx, webrtc)
    },
    case Wait of
        0 -> self() ! {launch_out, Pos};
        _ -> erlang:send_after(1000*Wait, self(), {launch_out, Pos})
    end,
    launch_invites(Rest, State#state{invites=[Inv|Invs], pos=Pos+1});

launch_invites(Callee, State) ->
    launch_invites([#{dest=>Callee}], State).


%% @private
launch_out(Inv, #state{id=CallId, call=Call}=State) ->
    Caller = maps:get(caller, Call, #{}),
    case start_callee_session(Inv, State) of
        {ok, #invite{dest=Dest, session_id=SessId}=Inv2, State2} ->
            Args = [CallId, Dest, SessId, Caller],
            case handle(nkmedia_call_invite, Args, State2) of
                {ok, Link, State3} ->
                    launched_out(Inv2, Link, SessId, State3);
                {ok, Link, SessId2, State3} ->
                    nkmedia_session:stop(SessId, session_not_used),
                    launched_out(Inv2, Link, SessId2, State3);
                {retry, Secs, State3} ->
                    launched_retry(Inv2, Secs, State3);
                {remove, State3} ->
                    #invite{pos=Pos, dest=Dest} = Inv,
                    ?LLOG(notice, "removing out ~p (~p)", [Dest, Pos], State),
                    remove_invite(Pos, call_rejected, State3)
            end;
        {error, Error, State2} ->
            ?LLOG(notice, "error generating session: ~p", [Error], State2),
            #invite{pos=Pos} = Inv,
            remove_invite(Pos, call_error, State2)
    end.


%% @private
launched_out(Inv, Link, SessId, #state{invites=Invs}=State) ->
    #invite{pos=Pos, dest=Dest} = Inv, 
    ?LLOG(info, "launched out ~p (~p)", [Dest, Pos], State),
    Inv2 = Inv#invite{launched=true, link=Link, session_id=SessId},
    Invs2 = lists:keystore(Pos, #invite.pos, Invs, Inv2),
    case nkmedia_session:register(SessId, Link) of
        {ok, _} ->
            {noreply, State#state{invites=Invs2}};
        {error, Error} ->
            ?LLOG(notice, "error registering callee session: ~p", [Error], State),
            remove_invite(Pos, session_error, State)
    end.


%% @private
launched_retry(Inv, Secs, #state{invites=Invs}=State) ->
    #invite{pos=Pos, dest=Dest} = Inv, 
    ?LLOG(notice, "retrying out ~p (~p, ~p secs)", [Dest, Pos, Secs], State),
    erlang:send_after(1000*Secs, self(), {launch_out, Pos}),
    Invs2 = lists:keystore(Pos, #invite.pos, Invs, Inv),
    {noreply, State#state{invites=Invs2}}.


%% @private
start_callee_session(#invite{session_id=undefined}=Inv, State) ->
    #state{id=CallId, call=Call} = State,
    #{caller_session_id:=CallerSessId} = Call,
    case handle(nkmedia_call_start_callee_session, [CallId, CallerSessId], State) of
        {ok, CalleeSessId, State2} ->
            Reg = {nkmedia_call, CallId, self()},
            case nkmedia_session:register(CalleeSessId, Reg) of
                {ok, Pid} ->
                    State3 = links_add(CalleeSessId, callee_session_id, Pid, State2),
                    Inv2 = Inv#invite{session_id=CalleeSessId},
                    {ok, Inv2, State3};
                {error, Error} ->
                    {error, Error, State2}
            end;
        {error, Error, State2} ->
            {error, Error, State2}
    end;

start_callee_session(Inv, State) ->
    {ok, Inv, State}.



%% @private
find_invite_by_pos(Pos, #state{invites=Invs}) ->
   case lists:keyfind(Pos, #invite.pos, Invs) of
        #invite{} = Inv -> {ok, Inv};
        false -> not_found
    end.


%% @private
find_invite_by_id(Id, #state{invites=Invs}) ->
   case lists:keyfind(Id, #invite.session_id, Invs) of
        #invite{} = Inv -> 
            {ok, Inv};
        false ->
            case lists:keyfind(Id, #invite.link, Invs) of
                #invite{} = Inv -> 
                    {ok, Inv};
                false ->
                    not_found
            end
    end.


%% @private
remove_invite(Pos, Reason, #state{invites=Invs}=State) ->
    case lists:keytake(Pos, #invite.pos, Invs) of
        {value, #invite{pos=Pos}=Inv, Invs2} ->
            stop_session(Inv, Reason),
            case Invs2 of
                [] ->
                    ?LLOG(info, "all invites removed", [], State),
                    do_hangup(no_answer, State#state{invites=[]});
                _ ->
                    ?LLOG(info, "removed invite (~p)", [Pos], State),
                    {noreply, State#state{invites=Invs2}}
            end;
        false ->
            {noreply, State}
    end.


%% @private
cancel_all(State) ->
    cancel_all_but(-1, State).


%% @private
cancel_all_but(Except, #state{invites=Invs}=State) ->
    State2 = lists:foreach(
        fun(#invite{pos=Pos, dest=Dest, timer=Timer}=Inv) ->
            nklib_util:cancel_timer(Timer),
            case Pos of
                Except ->
                    ok;
                _ ->
                    ?LLOG(info, "sending CANCEL to ~p (~p)", [Pos, Dest], State),
                    stop_session(Inv, originator_cancel)
            end
        end,
        Invs),
    State2#state{invites=[]}.


%% @private
do_hangup(_Reason, #state{stop_sent=true}=State) ->
    timer:sleep(100),                                       % Allow events
    {stop, normal, State#state{stop_sent=true}};

do_hangup(Reason, #state{stop_sent=false, call=Call}=State) ->
    State2 = event({hangup, Reason}, State),
    case Call of
        #{caller_session_id:=CallerSessId} ->
            nkmedia_session:stop(CallerSessId, Reason);
        _ ->
            ok
    end,
    do_hangup(Reason, State2#state{stop_sent=true}).


%% @private
event(Event, #state{id=Id}=State) ->
    case Event of
        {answer, Link, _Ans} ->
            ?LLOG(info, "sending 'event': ~p", [{answer, <<"sdp">>, Link}], State);
        _ ->
            ?LLOG(info, "sending 'event': ~p", [Event], State)
    end,
    State2 = links_fold(
        fun
            (Link, reg, AccState) -> 
                event(Event, Link, AccState);
            (_Link, _Data, AccState) -> 
                AccState
        end,
        State,
        State),
    {ok, State3} = handle(nkmedia_call_event, [Id, Event], State2),
    State3.


%% @private
event(Event, Link, #state{id=Id}=State) ->
    {ok, State2} = handle(nkmedia_call_reg_event, [Id, Link, Event], State),
    State2.



%% @private
stop_session(#invite{session_id=SessId}, Reason) when is_binary(SessId) ->
    nkmedia_session:stop(SessId, Reason);

stop_session(_Inv, _Reason) ->
    ok.


%% @private
handle(Fun, Args, State) ->
    nklib_gen_server:handle_any(Fun, Args, State, #state.srv_id, #state.call).


%% @private
do_call(CallId, Msg) ->
    do_call(CallId, Msg, 5000).


%% @private
do_call(CallId, Msg, Timeout) ->
    case find(CallId) of
        {ok, Pid} -> nkservice_util:call(Pid, Msg, Timeout);
        not_found -> {error, call_not_found}
    end.


%% @private
do_cast(CallId, Msg) ->
    case find(CallId) of
        {ok, Pid} -> gen_server:cast(Pid, Msg);
        not_found -> {error, call_not_found}
    end.

%% @private
find(Pid) when is_pid(Pid) ->
    {ok, Pid};

find(CallId) ->
    case nklib_proc:values({?MODULE, CallId}) of
        [{undefined, Pid}] -> {ok, Pid};
        [] -> not_found
    end.


%% @private
links_add(Link, Data, State) ->
    Pid = nklib_links:get_pid(Link),
    links_add(Link, Data, Pid, State).


%% @private
links_add(Link, Data, Pid, #state{links=Links}=State) ->
    State#state{links=nklib_links:add(Link, Data, Pid, Links)}.


%% @private
links_remove(Link, #state{links=Links}=State) ->
    State#state{links=nklib_links:remove(Link, Links)}.


%% @private
links_down(Ref, #state{links=Links}=State) ->
    case nklib_links:down(Ref, Links) of
        {ok, Link, Data, Links2} -> 
            {ok, Link, Data, State#state{links=Links2}};
        not_found -> 
            not_found
    end.


%% @private
links_fold(Fun, Acc, #state{links=Links}) ->
    nklib_links:fold_values(Fun, Acc, Links).






