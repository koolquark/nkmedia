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

-export([start/3, ringing/2, answered/3, rejected/2, stop/2, stop_all/0]).
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
-spec start(nkmedia_session:id(), dest() | [dest_ext()], config()) ->
    {ok, id()}.

start(SessId, Dest, Config) ->
    {CallId, Config2} = nkmedia_util:add_uuid(Config),
    Config3 = Config2#{session_id=>SessId, dest=>Dest},
    {ok, _Pid} = gen_server:start(?MODULE, [Config3], []),
    {ok, CallId}.


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
-spec stop(id(), nkmedia:stop_reason()) ->
    ok | {error, term()}.

stop(CallId, Reason) ->
    do_cast(CallId, {stop, Reason}).


%% @private
stop_all() ->
    lists:foreach(fun({CallId, _Pid}) -> stop(CallId, 16) end, get_all()).



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
    id :: term() | pid(),
    mon :: reference()
}).

-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
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

init([#{id:=CallId, session_id:=SessId, dest:=Dest}=Config]) ->
    {ok, SrvId, Pid} = nkmedia_session:register(SessId, {nkmedia_call, CallId, self()}),
    {ok, Offer} = nkemdia_session:get_offer(SessId),
    nklib_proc:put(?MODULE, {CallId, SessId}),
    State = #state{
        id = CallId, 
        srv_id = SrvId, 
        session_id = SessId,
        session_mon = monitor(process, Pid),
        offer = Offer,
        call = Config#{srv_id=>SrvId}
    },
    lager:info("NkMEDIA Call ~s starting (~p, ~s)", [CallId, self(), SessId]),
    {ok, State2} = handle(nkmedia_call_init, [CallId], State),
    State3 = launch_invites(Dest, State2),
    case length(State3#state.invites) of
        0 ->
            {stop, normal};
        _ -> 
            {ok, State3}
    end.


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

handle_call({answered, InvId, Answer}, _From, #state{id=Id}=State) ->
    case find_invite(InvId, State) of
        {ok, #invite{pos=Pos}} ->
            ?LLOG(info, "received ANSWER", [], State),
            State2 = cancel_all(Pos, State),
            % Launch event
            #state{session_id=SessId} = State,
            {ok, _} = nkmedia_session:answer(SessId, Answer),
            ok = nkmedia_session:unregister(SessId, {nkmedia_call, Id, self()}),
            {stop, normal, event(answered, State2)};
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

handle_cast({stop, Reason}, State) ->
    ?LLOG(info, "external stop: ~p", [Reason], State),
    do_stop(Reason, State);

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
        {ok, #invite{dest=Dest, id=Id, launched=Launched}} ->
            ?LLOG(info, "call ring timeout for ~p (~p)", [Dest, Pos], State),
            case Launched of
                true -> 
                    {ok, State2} = handle(nkmedia_call_cancel, [Id, Dest, 607], State);
                false ->
                    State2 = State
            end,
            remove_invite(Pos, State2);
        not_found ->
            {noreply, State}
    end;

handle_info({'DOWN', Ref, process, _Pid, Reason}, #state{session_mon=Ref}=State) ->
    case Reason of
        normal ->
            ?LLOG(info, "inbound session stopped (normal)", [], State);
        _ ->
            ?LLOG(notice, "inbound session stopped: ~p", [Reason], State)
    end,
    do_stop(session_stop, State);

handle_info({'DOWN', Ref, process, _Pid, Reason}=Msg, #state{invites=Invs}=State) ->
    case maps:keyfind(Ref, #invite.mon, Invs) of
        #invite{pos=Pos} ->
            ?LLOG(info, "invite stopped (~p)", [Reason], State),
            remove_invite(Pos, State);
        _ ->
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
        {ok, InvId, State2} ->
            ?LLOG(info, "launching out ~p (~p)", [Dest, Pos], State),
            Mon = case is_pid(InvId) of
                true -> monitor:process(InvId);
                false -> undefined
            end,
            Inv2 = Inv#invite{launched=true, id=InvId, mon=Mon},
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
            do_stop(no_answer, State#state{invites=[]});
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
            (#invite{launched=true, id=Id, pos=Pos}, Acc) when Pos /= Except ->
                {ok, Acc2} = handle(nkmedia_call_cancel, [Id, 607], Acc),
                Acc2;
            (_, Acc) ->
                Acc
        end,
        State,
        Invs),
    State2#state{invites=[]}.


%% @private
event(Event, #state{id=CallId, session_id=SessId}=State) ->
    {ok, State2} = handle(nkmedia_call_event, [CallId, SessId, Event], State),
    State2.


%% @private
do_stop(Reason, State) ->
    event({stop, Reason}, State),
    {stop, normal, State}.


%% @private
handle(Fun, Args, State) ->
    nklib_gen_server:handle_any(Fun, Args, State, #state.srv_id, #state.call).


%% @private
do_call(CallId, Msg) ->
    do_call(CallId, Msg, 5000).


%% @private
do_call(CallId, Msg, Timeout) ->
    case find(CallId) of
        {ok, Pid} -> nklib_util:call(Pid, Msg, Timeout);
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



