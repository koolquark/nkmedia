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

-type config() ::
    #{
        offer => nkmedia:offer(),
        register => nklib:proc_id()
    }.


-type call() ::
    config() |
    #{
        id => id(),
        srv_id => nkservice:id(),
        dest => dest()
    }.


-type event() :: 
    {ringing, nklib:proc_id()} | 
    {answered, nklib:proc_id(), nkmedia:answer()} | 
    {stop, nkservice:error()}.


-type invite_id() :: integer().


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
-spec start(nkservice:id(), dest(), config()) ->
    {ok, id(), pid()}.

start(Srv, Dest, Config) ->
    case nkservice_srv:get_srv_id(Srv) of
        {ok, SrvId} ->
            Config2 = Config#{dest=>Dest, srv_id=>SrvId},
            {CallId, Config3} = nkmedia_util:add_uuid(Config2),
            {ok, Pid} = gen_server:start(?MODULE, [Config3], []),
            {ok, CallId, Pid};
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
    callee :: nklib:proc_id()
}).

-type link_id() ::
    {reg, nklib:proc_id()} | {callee, nklib:proc_id()}.

-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    links :: nklib_links:links(link_id()),
    invites = [] :: [#invite{}],
    pos = 0 :: integer(),
    stop_sent = false :: boolean(),
    call :: call()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()}.

init([#{srv_id:=SrvId, id:=CallId, dest:=Dest}=Call]) ->
    nklib_proc:put(?MODULE, CallId),
    State1 = #state{
        id = CallId, 
        srv_id = SrvId, 
        links = nklib_links:new(),
        call = Call
    },
    State2 = case Call of
        #{register:=ProcId} -> 
            links_add(reg, ProcId, State1);
        _ ->
            State1
    end,
    gen_server:cast(self(), do_start),
    lager:info("NkMEDIA Call ~s starting to ~p (~p)", [CallId, Dest, self()]),
    handle(nkmedia_call_init, [CallId], State2).


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call({ringing, Pos}, _From, State) ->
    case find_invite(Pos, State) of
        #invite{callee=Callee} ->
            % Launch event
            {reply, ok, event({ringing, Callee}, State)};
        not_found ->
            {reply, {error, invite_not_found}, State} 
    end;

handle_call({answered, Pos, Answer}, From, #state{call=Call}=State) ->
    case find_invite(Pos, State) of
        #invite{callee=Callee} ->
            ?LLOG(info, "received ANSWER", [], State),
            gen_server:reply(From, ok),
            State2 = cancel_all(Pos, State),
            Call2 = maps:remove(offer, Call#{callee=>Callee}),
            State3 = State2#state{call=Call2},
            State4 = links_add(callee, Callee, State3),
            {noreply, event({answered, Callee, Answer}, State4)};
        not_found ->
            {reply, {error, invite_not_found}, State}
    end;

handle_call({rejected, Pos}, From, State) ->
    case find_invite(Pos, State) of
        #invite{} ->
            gen_server:reply(From, ok),
            remove_invite(Pos, State);
        not_found ->
            {reply, {error, invite_not_found}, State}
    end;

handle_call(Msg, From, State) -> 
    handle(nkmedia_call_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast(do_start, #state{call=#{dest:=Dest}}=State) ->
    {ok, CallDest, State2} = handle(nkmedia_call_resolve, Dest, State),
    {noreply, launch_invites(CallDest, State2)};

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
            % The call should have been removed because of timeout
            {noreply, State}
    end;

handle_info({ring_timeout, Pos}, #state{id=CallId}=State) ->
    case find_invite(Pos, State) of
        {ok, #invite{dest=Dest, callee=Callee, launched=Launched}} ->
            ?LLOG(info, "call ring timeout for ~p (~p)", [Dest, Pos], State),
            {ok, State2} = case Launched of
                true -> 
                    handle(nkmedia_call_cancel, [CallId, Callee], State);
                false ->
                    {ok, State}
            end,
            remove_invite(Pos, State2);
        not_found ->
            {noreply, State}
    end;

handle_info({'DOWN', _Ref, process, Pid, Reason}=Msg, State) ->
    case links_down(Pid, State) of
        {ok, Class, _ProcId, State2} ->
            case Reason of
                normal ->
                    ?LLOG(info, "linked ~p down (normal)", [Class], State);
                _ ->
                    ?LLOG(notice, "linked ~p down (~p)", [Class, Reason], State)
            end,
            case Class of
                reg ->
                    do_hangup(reg_monitor_stop, State2);
                callee ->
                    do_hangup(callee_stop, State2)
            end;
        not_found ->
            handle(nkmedia_session_handle_info, [Msg], State)
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
    {stop, normal, State3} = do_hangup(process_stop, State2),
    catch handle(nkmedia_call_terminate, [Reason], State3).


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

launch_invites(Dest, State) ->
    launch_invites([#{dest=>Dest}], State).


%% @private
launch_out(Pos, Inv, #state{id=CallId, invites=Invs, call=Call}=State) ->
    #invite{pos=Pos, dest=Dest} = Inv,
    Offer = maps:get(offer, Call, #{}),
    case handle(nkmedia_call_invite, [CallId, Dest, Offer], State) of
        {ok, Callee, State2} ->
            ?LLOG(info, "launching out ~p (~p)", [Dest, Pos], State),
            Inv2 = Inv#invite{launched=true, callee=Callee},
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
cancel_all(Except, #state{id=CallId, invites=Invs}=State) ->
    State2 = lists:foldl(
        fun
            (#invite{launched=true, callee=Callee, pos=Pos}, Acc) when Pos /= Except ->
                {ok, Acc2} = handle(nkmedia_call_cancel, [CallId, Callee], Acc),
                Acc2;
            (_, Acc) ->
                Acc
        end,
        State,
        Invs),
    State2#state{invites=[]}.


%% @private
do_hangup(Reason, #state{stop_sent=Sent}=State) ->
    State2 = case Sent of
        false -> event({hangup, Reason}, State);
        true -> State
    end,
    {stop, normal, State2}.


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



%% @private
links_add(Class, ProcId, #state{links=Links}=State) ->
    Pid = nklib_links:get_pid(ProcId),
    State#state{links=nklib_links:add({Class, ProcId}, none, Pid, Links)}.


% %% @private
% links_get(Id, #state{links=Links}) ->
%     nklib_links:get(Id, Links).


% %% @private
% links_remove(Id, #state{links=Links}=State) ->
%     State#state{links=nklib_links:remove(Id, Links)}.


%% @private
links_down(Pid, #state{links=Links}=State) ->
    case nklib_links:down(Pid, Links) of
        {ok, {Class, ProcId}, none, Links2} -> 
            {ok, Class, ProcId, State#state{links=Links2}};
        not_found -> 
            not_found
    end.


% %% @private
% links_iter(Fun, #state{links=Links}) ->
%     nklib_links:iter(Fun, Links).


% %% @private
% links_fold(Fun, Acc, #state{links=Links}) ->
%     nklib_links:fold(Fun, Acc, Links).






