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
-module(nkmedia_call).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start/3, ringing/2, answered/3, rejected/2, hangup/2, hangup_all/0]).
-export([find/1, get_all/0]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, event/0]).


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Call ~s "++Txt, [State#state.id | Args])).

-include("nkmedia.hrl").


%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().

-type invite_id() :: term() | pid().


-type config() ::
    #{
        offer => nkmedia:offer(),
        caller_id => term(),
        caller_pid => pid()
    }.


-type call() ::
    config() |
    #{
    }.


-type event() :: ringing | answered | {stop, nkmedia:hangup_reason()}.

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

%% @doc Starts a new call
-spec start(nkservice:id(), term(), config()) ->
    {ok, id(), pid()}.

start(Srv, Dest, Config) ->
    case nkservice_srv:get_srv_id(Srv) of
        {ok, SrvId} ->
            {CallId, Config2} = nkmedia_util:add_uuid(Config),
            Config3 = Config2#{dest=>Dest, srv_id=>SrvId},
            {ok, _Pid} = gen_server:start(?MODULE, [Config3], []),
            {ok, CallId};
        not_found ->
            {error, service_not_found}
    end.


%% @doc Called by the invited process
-spec ringing(id(), invite_id()) ->
    ok | {error, term()}.

ringing(CallId, Id) ->
    do_call(CallId, {ringing, Id}).


%% @doc Called by the invited process
-spec answered(id(), invite_id(), nkmedia:answer()) ->
    ok | {error, term()}.

answered(CallId, Id, Answer) ->
    do_call(CallId, {answered, Id, Answer}).


%% @doc Called by the invited process
-spec rejected(id(), invite_id()) ->
    ok | {error, term()}.

rejected(CallId, Id) ->
    do_call(CallId, {rejected, Id}).


%% @doc
-spec hangup(id(), nkservice:error()) ->
    ok | {error, term()}.

hangup(CallId, Reason) ->
    do_cast(CallId, {hangup, Reason}).


%% @private
hangup_all() ->
    lists:foreach(fun({CallId, _Pid}) -> hangup(CallId, 16) end, get_all()).



%% @private
-spec get_all() ->
    [{id(), nkmedia_session:id(), pid()}].

get_all() ->
    [{Id, SessId, Pid} || {{Id, SessId}, Pid} <- nklib_proc:values(?MODULE)].



% ===================================================================
%% gen_server behaviour
%% ===================================================================

-record(invite, {
    pos :: integer(),
    dest :: dest(),
    ring :: integer(),
    sdp_type :: webrtc | rtp,
    launched :: boolean(),
    callee_id :: term(),
    callee_pid :: pid() | undefined
}).

-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    caller_mon :: reference(),
    callee_mon :: reference(),
    session_id :: nkmedia:session_id(),
    session_mon :: reference(),
    offer :: nkmedia:offer(),
    invites = [] :: [#invite{}],
    pos = 0 :: integer(),
    call :: call()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()}.

init([#{id:=CallId, dest:=Dest, srv_id:=SrvId}=Call]) ->
    nklib_proc:put(?MODULE, CallId),
    State = #state{
        id = CallId, 
        srv_id = SrvId, 
        call = Call#{srv_id=>SrvId}
    },
    lager:info("NkMEDIA Call ~s starting to ~p (~p)", [CallId, Dest, self()]),
    State2 = case Call of
        #{caller_pid:=Pid} -> State#state{caller_mon=monitor(process, Pid)};
        _ -> State
    end,
    gen_server:cast(self(), do_start),
    handle(nkmedia_call_init, [CallId], State2).


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call({ringing, InvId}, _From, State) ->
    case find_invite(InvId, State) of
        {ok, _} ->
            % Launch event
            {reply, ok, event(ringing, State)};
        not_found ->
            {error, invite_not_found}
    end;

handle_call({answered, InvId, Answer}, From, State) ->
    case find_invite(InvId, State) of
        {ok, #invite{pos=Pos, callee_id=CalleeId, callee_pid=CalleePid}} ->
            ?LLOG(info, "received ANSWER", [], State),
            State2 = cancel_all(Pos, State),
            #state{session_id=SessId, call=Call} = State,
            Call2 = Call#{callee_id=>CalleeId},
            State3 = State2#state{call=Call2, offer=undefined},
            State4 = case is_pid(CalleePid) of
                true -> State3#state{callee_mon=monitor(process, CalleePid)};
                false -> State3
            end,
            {ok, _} = nkmedia_session:answer(SessId, Answer),
            gen_server:reply(From, ok),
            {noreply, status(ready, State4)};
        not_found ->
            {error, invite_not_found}
    end;

handle_call({rejected, InvId}, From, State) ->
    case find_invite(InvId, State) of
        {ok, #invite{pos=Pos}} ->
            gen_server:reply(From, ok),
            remove_invite(Pos, State);
        not_found ->
            {error, invite_not_found}
    end;

handle_call(Msg, From, State) -> 
    handle(nkmedia_call_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast(do_start, State) ->
    #state{call=#{dest:=Dest}, srv_id=SrvId} = State,
    case handle(nkmedia_call_session_class, Dest, State) of
        {ok, Class, Config, State2} ->
            case nkmedia_session:start(SrvId, Class, Config) of
                {ok, SessId, #{answer:=_Answer}} ->
                    State3 = link_session(SessId, State2),
                    {noreply, status(ready, State3)};
                {ok, SessId, #{offer:=Offer}} ->
                    State3 = link_session(SessId, State2#state{offer=Offer}),
                    case handle(nkmedia_call_resolve, Dest, State3) of
                        {ok, [], State4} ->
                            do_hangup(no_destination, State4);
                        {ok, CallDest, State4} ->
                            State5 = launch_invites(CallDest, State4),
                            {noreply, status(invite, State5)}
                    end;
                {error, Error} ->
                    ?LLOG(warning, "could not start session: ~p", [Error], State),
                    do_hangup(session_stop, State)
            end;
        {hangup, Reason, State2} ->
            do_hangup(Reason, State2)
    end;


handle_cast({hangup, Reason}, State) ->
    ?LLOG(info, "external hangup: ~p", [Reason], State),
    do_hangup(Reason, State);

handle_cast(Msg, State) -> 
    handle(nkmedia_call_handle_cast, [Msg], State).


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({launch_out, Pos}, State) ->
    case find_invite(Pos, State) of
        {ok, #invite{launched=false, ring=Ring}=Out} ->
            erlang:send_after(1000*Ring, self(), {ring_timeout, Pos}),
            launch_out(Pos, Out, State);
        {ok, Out} ->
            launch_out(Pos, Out, State);
        not_found ->
            % The call can have been removed because of timeout
            {noreply, State}
    end;

handle_info({ring_timeout, Pos}, State) ->
    case find_invite(Pos, State) of
        {ok, #invite{dest=Dest, callee_id=CalleeId, launched=Launched}} ->
            ?LLOG(info, "call ring timeout for ~p (~p)", [Dest, Pos], State),
            case Launched of
                true -> 
                    {ok, State2} = 
                        handle(nkmedia_call_cancel, [CalleeId, Dest, 607], State);
                false ->
                    State2 = State
            end,
            remove_invite(Pos, State2);
        not_found ->
            {noreply, State}
    end;

handle_info({'DOWN', Ref, process, _Pid, Reason}, #state{caller_mon=Ref}=State) ->
    case Reason of
        normal ->
            ?LLOG(info, "caller process stopped (normal)", [], State);
        _ ->
            ?LLOG(notice, "caller process stopped: ~p", [Reason], State)
    end,
    do_hangup(reg_monitor_stop, State);

handle_info({'DOWN', Ref, process, _Pid, Reason}, #state{callee_mon=Ref}=State) ->
    case Reason of
        normal ->
            ?LLOG(info, "callee process stopped (normal)", [], State);
        _ ->
            ?LLOG(notice, "callee process stopped: ~p", [Reason], State)
    end,
    do_hangup(reg_monitor_stop, State);

handle_info({'DOWN', Ref, process, _Pid, Reason}, #state{session_mon=Ref}=State) ->
    case Reason of
        normal ->
            ?LLOG(info, "session process stopped (normal)", [], State);
        _ ->
            ?LLOG(notice, "session process stopped: ~p", [Reason], State)
    end,
    do_hangup(reg_monitor_stop, State);

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
    ?LLOG(info, "stopped: ~p", [Reason], State),
    State2 = cancel_all(State),
    catch handle(nkmedia_call_terminate, [Reason], State2).


% ===================================================================
%% Internal
%% ===================================================================

%% @private Generate data and launch messages
-spec launch_invites(dest() | [dest_ext()], State) ->
    State.

launch_invites([], #state{invites=Invs}=State) ->
    ?LLOG(info, "resolved invites: ~p", [Invs], State),
    case length(Invs) of
        0 -> hangup(self(), no_destination);
        _ -> ok
    end,        
    State;

launch_invites([DestEx|Rest], #state{invites=Invs, pos=Pos}=State) ->
    #{dest:=Dest} = DestEx,
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

launch_invites(Dest, State) ->
    launch_invites([#{dest=>Dest}], State).


%% @private
launch_out(Pos, Inv, #state{id=Id, offer=Offer, invites=Invs}=State) ->
    #invite{pos=Pos, dest=Dest} = Inv,
    case handle(nkmedia_call_invite, [Id, Offer, Dest], State) of
        {ok, CalleeId, CalleePid, State2} ->
            ?LLOG(info, "launching out ~p (~p)", [Dest, Pos], State),
            Inv2 = Inv#invite{launched=true, callee_id=CalleeId, callee_pid=CalleePid},
            Invs2 = lists:keystore(Pos, #invite.pos, Invs, Inv2),
            {noreply, State2#state{invites=Invs2}};
        {retry, Secs, State2} ->
            ?LLOG(info, "retrying out ~p (~p, ~p secs)", [Dest, Pos, Secs], State),
            erlang:send_after(1000*Secs, self(), {launch_out, Pos}),
            {noreply, State2};
        {remove, State2} ->
            ?LLOG(info, "removing out ~p (~p)", [Dest, Pos], State),
            remove_invite(Pos, State2)
    end.


%% @private
find_invite(Pos, #state{invites=Invs}) ->
   case lists:keyfind(Pos, #invite.pos, Invs) of
        #invite{} = Inv -> {ok, Inv};
        false -> not_found
    end.


%% @private
remove_invite(Pos, #state{invites=Invs}=State) ->
    case lists:keytake(Pos, #invite.pos, Invs) of
        {value, #invite{}, []} ->
            ?LLOG(info, "all invites removed", [], State),
            do_hangup(no_answer, State#state{invites=[]});
        {value, #invite{pos=Pos}, Invs2} ->
            ?LLOG(info, "removed invite (~p)", [Pos], State),
            {noreply, State#state{invites=Invs2}};
        false ->
            {noreply, State}
    end.


%% @private
cancel_all(State) ->
    cancel_all(-1, State).


%% @private
cancel_all(Except, #state{invites=Invs}=State) ->
    State2 = lists:foldl(
        fun
            (#invite{launched=true, callee_id=Id, pos=Pos}, Acc) when Pos /= Except ->
                {ok, Acc2} = handle(nkmedia_call_cancel, [Id, 607], Acc),
                Acc2;
            (_, Acc) ->
                Acc
        end,
        State,
        Invs),
    State2#state{invites=[]}.



%% @private
do_hangup(Reason, State) ->
    event({hangup, Reason}, State),
    {stop, normal, State}.


%% @private
link_session(SessId, #state{id=Id}=State) ->
    {ok, Pid} = nkmedia_session:register(SessId, {nkmedia_call, Id}),
    Mon = monitor(process, Pid),
    State#state{session_id=SessId, session_mon=Mon}.


status(NewStatus, State) ->
    State2 = event({status, NewStatus}, State),
    State2.


%% @private
event(Event, #state{id=CallId}=State) ->
    {ok, State2} = handle(nkmedia_call_event, [CallId, Event], State),
    State2.







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



