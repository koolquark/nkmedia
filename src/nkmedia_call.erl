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
%% - The call registers itself with the session
%% - When the call has an answer, it is captured in nkmedia_call_reg_event
%%   (nkmedia_callbacks) and sent to the session. Same with hangups
%% - If the session stops, it is captured in nkmedia_session_reg_event
%% - When the call stops, the called process must detect it in nkmedia_call_reg_event

-module(nkmedia_call).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start/3, ringing/2, answered/3, rejected/2, hangup/2, hangup_all/0]).
-export([register/2, unregister/2]).
-export([find/1, get_all/0, get_call/1]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, event/0]).


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Call ~s "++Txt, [State#state.id | Args])).

-include("nkmedia.hrl").
-include_lib("nkservice/include/nkservice.hrl").



%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().

-type callee() :: term().

-type config() ::
    #{
        type => atom(),                     % Optional, used in resolvers
        offer => nkmedia:offer(),           % If included, will be sent to the callee
        session_id => nkmedia_session:id(), % If included, will link with session
        register => nklib:proc_id()
    }.


-type call() ::
    config() |
    #{
        id => id(),
        srv_id => nkservice:id(),
        callee => callee(),
        callee_id => nklib:proc_id()

    }.


-type event() :: 
    {ringing, nklib:proc_id()} | 
    {answer, nklib:proc_id(), nkmedia:answer()} | 
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

%% @doc Starts a new call
-spec start(nkservice:id(), callee(), config()) ->
    {ok, id(), pid()}.

start(Srv, Callee, Config) ->
    case nkservice_srv:get_srv_id(Srv) of
        {ok, SrvId} ->
            Config2 = Config#{callee=>Callee, srv_id=>SrvId},
            {CallId, Config3} = nkmedia_util:add_uuid(Config2),
            {ok, Pid} = gen_server:start(?MODULE, [Config3], []),
            {ok, CallId, Pid};
        not_found ->
            {error, service_not_found}
    end.


%% @doc Called by the invited process
-spec ringing(id(), nklib:proc_id()) ->
    ok | {error, term()}.

ringing(CallId, ProcId) ->
    do_call(CallId, {ringing, ProcId}).


%% @doc Called by the invited process
-spec answered(id(), nklib:proc_id(), nkmedia:answer()) ->
    ok | {error, term()}.

answered(CallId, ProcId, Answer) ->
    do_call(CallId, {answered, ProcId, Answer}).


%% @doc Called by the invited process
-spec rejected(id(), nklib:proc_id()) ->
    ok | {error, term()}.

rejected(CallId, ProcId) ->
    do_call(CallId, {rejected, ProcId}).


%% @doc
-spec hangup(id(), nkservice:error()) ->
    ok | {error, term()}.

hangup(CallId, Reason) ->
    do_cast(CallId, {hangup, Reason}).


%% @private
hangup_all() ->
    lists:foreach(fun({CallId, _Pid}) -> hangup(CallId, 16) end, get_all()).


%% @doc Registers a process with the call
-spec register(id(), nklib:proc_id()) ->
    {ok, pid()} | {error, nkservice:error()}.

register(CallId, ProcId) ->
    do_call(CallId, {register, ProcId}).


%% @doc Registers a process with the call
-spec unregister(id(), nklib:proc_id()) ->
    ok | {error, nkservice:error()}.

unregister(CallId, ProcId) ->
    do_call(CallId, {unregister, ProcId}).


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
    proc_id :: nklib:proc_id()
}).

-type link_id() ::
    session | {reg, nklib:proc_id()} | {callee, nklib:proc_id()}.

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

init([#{srv_id:=SrvId, id:=CallId, callee:=Callee}=Call]) ->
    nklib_proc:put(?MODULE, CallId),
    nklib_proc:put({?MODULE, CallId}),
    State1 = #state{
        id = CallId, 
        srv_id = SrvId, 
        links = nklib_links:new(),
        call = Call
    },
    State2 = case Call of
        #{session_id:=SessId} -> 
            {ok, SessPid} = 
                nkmedia_session:register(SessId, {nkmedia_call, CallId, self()}),
            links_add(session, SessId, SessPid, State1);
        _ ->
            State1
    end,
    State3 = case Call of
        #{register:=ProcId} -> 
            Pid = nklib_links:get_pid(ProcId),
            links_add({reg, ProcId}, none, Pid, State2);
        _ ->
            State2
    end,
    gen_server:cast(self(), do_start),
    lager:info("NkMEDIA Call ~s starting to ~p (~p)", [CallId, Callee, self()]),
    handle(nkmedia_call_init, [CallId], State3).


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call({ringing, ProcId}, _From, State) ->
    case find_invite_callee(ProcId, State) of
        {ok, _} ->
            % Launch event
            {reply, ok, event({ringing, ProcId}, State)};
        not_found ->
            {reply, {error, invite_not_found}, State} 
    end;

handle_call({answered, ProcId, Answer}, From, #state{call=Call}=State) ->
    case find_invite_callee(ProcId, State) of
        {ok, #invite{pos=Pos}} ->
            ?LLOG(info, "received ANSWER", [], State),
            gen_server:reply(From, ok),
            State2 = cancel_all(Pos, State),
            Call2 = maps:remove(offer, Call#{callee_id=>ProcId}),
            State3 = State2#state{call=Call2},
            Pid = nklib_links:get_pid(ProcId),
            State4 = links_add(callee, ProcId, Pid, State3),
            {noreply, event({answer, ProcId, Answer}, State4)};
        not_found ->
            {reply, {error, invite_not_found}, State}
    end;

handle_call({rejected, ProcId}, From, State) ->
    case find_invite_callee(ProcId, State) of
        {ok, #invite{pos=Pos}} ->
            gen_server:reply(From, ok),
            remove_invite(Pos, State);
        not_found ->
            {reply, {error, invite_not_found}, State}
    end;

handle_call(get_call, _From, #state{call=Call}=State) -> 
    {reply, {ok, Call}, State};

handle_call({register, ProcId}, _From, State) ->
    ?LLOG(info, "proc registered (~p)", [ProcId], State),
    Pid = nklib_links:get_pid(ProcId),
    State2 = links_add({reg, ProcId}, none, Pid, State),
    {reply, {ok, self()}, State2};

handle_call({unregister, ProcId}, _From, State) ->
    ?LLOG(info, "proc unregistered (~p)", [ProcId], State),
    State2 = links_remove({reg, ProcId}, State),
    {reply, ok, State2};

handle_call(get_state, _From, State) ->
    {reply, State, State};

handle_call(Msg, From, State) -> 
    handle(nkmedia_call_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast(do_start, #state{call=#{callee:=Callee}}=State) ->
    lager:error("Calling ~p", [State#state.srv_id]),
    {ok, ExtDests, State2} = handle(nkmedia_call_resolve, [Callee, []], State),
    State3 = launch_invites(ExtDests, State2),
    ?LLOG(info, "Resolved ~p", [State3#state.invites], State),
    {noreply, State3};

handle_cast({hangup, Reason}, State) ->
    ?LLOG(info, "external hangup: ~p", [Reason], State),
    do_hangup(Reason, State);

handle_cast(Msg, State) -> 
    handle(nkmedia_call_handle_cast, [Msg], State).


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({launch_out, Pos}, State) ->
    case find_invite_pos(Pos, State) of
        {ok, #invite{launched=false, ring=Ring}=Out} ->
            erlang:send_after(1000*Ring, self(), {ring_timeout, Pos}),
            launch_out(Out, State);
        {ok, Out} ->
            launch_out(Out, State);
        not_found ->
            % The call should have been removed because of timeout
            {noreply, State}
    end;

handle_info({ring_timeout, Pos}, #state{id=CallId}=State) ->
    case find_invite_pos(Pos, State) of
        {ok, #invite{dest=Dest, proc_id=ProcId, launched=Launched}} ->
            ?LLOG(info, "call ring timeout for ~p (~p)", [Dest, Pos], State),
            {ok, State2} = case Launched of
                true -> 
                    handle(nkmedia_call_cancel, [CallId, ProcId], State);
                false ->
                    {ok, State}
            end,
            remove_invite(Pos, State2);
        not_found ->
            {noreply, State}
    end;

handle_info({'DOWN', _Ref, process, Pid, Reason}=Msg, State) ->
    case links_down(Pid, State) of
        {ok, Id, _Data, State2} ->
            case Reason of
                normal ->
                    ?LLOG(info, "linked ~p down (normal)", [Id], State);
                _ ->
                    ?LLOG(notice, "linked ~p down (~p)", [Id, Reason], State)
            end,
            case Id of
                {reg, _} ->
                    do_hangup(registered_stop, State2);
                callee ->
                    do_hangup(callee_stop, State2);
                session ->
                    do_hangup(session_stop, State2)
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
launch_out(Inv, #state{id=CallId, invites=Invs, call=Call}=State) ->
    #invite{pos=Pos, dest=Dest} = Inv,
    Offer = maps:get(offer, Call, #{}),
    case handle(nkmedia_call_invite, [CallId, Dest, Offer], State) of
        {ok, ProcId, State2} ->
            ?LLOG(notice, "launching out ~p (~p)", [Dest, Pos], State),
            Inv2 = Inv#invite{launched=true, proc_id=ProcId},
            Invs2 = lists:keystore(Pos, #invite.pos, Invs, Inv2),
            {noreply, State2#state{invites=Invs2}};
        {retry, Secs, State2} ->
            ?LLOG(notice, "retrying out ~p (~p, ~p secs)", [Dest, Pos, Secs], State),
            erlang:send_after(1000*Secs, self(), {launch_out, Pos}),
            {noreply, State2};
        {remove, State2} ->
            ?LLOG(notice, "removing out ~p (~p)", [Dest, Pos], State),
            remove_invite(Pos, State2)
    end.


%% @private
find_invite_pos(Pos, #state{invites=Invs}) ->
   case lists:keyfind(Pos, #invite.pos, Invs) of
        #invite{} = Inv -> {ok, Inv};
        false -> not_found
    end.


%% @private
find_invite_callee(ProcId, #state{invites=Invs}) ->
   case lists:keyfind(ProcId, #invite.proc_id, Invs) of
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
            (#invite{launched=true, proc_id=ProcId, pos=Pos}, Acc) when Pos /= Except ->
                {ok, Acc2} = handle(nkmedia_call_cancel, [CallId, ProcId], Acc),
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
    timer:sleep(100),   % Allow events
    {stop, normal, State2#state{stop_sent=true}}.


%% @private
event(Event, #state{id=Id}=State) ->
    case Event of
        {answer, ProcId, _Ans} ->
            ?LLOG(info, "sending 'event': ~p", [{answer, <<"sdp">>, ProcId}], State);
        _ ->
            ?LLOG(info, "sending 'event': ~p", [Event], State)
    end,
    ProcIds = links_fold(
        fun
            (session, SessId, Acc) -> [{nkmedia_session, SessId}|Acc];
            ({reg, ProcId}, none, Acc) -> [ProcId|Acc];
            (callee, ProcId, Acc) -> [ProcId|Acc]
        end,
        [],
        State),
    State2 = lists:foldl(
        fun(ProcId, AccState) ->
            {ok, AccState2} = 
                handle(nkmedia_call_reg_event, [Id, ProcId, Event], AccState),
            AccState2
        end,
        State,
        ProcIds),
    {ok, State3} = handle(nkmedia_call_event, [Id, Event], State2),
    ext_event(Event, State3).


%% @private
ext_event(Event, #state{srv_id=SrvId}=State) ->
    Send = case Event of
        {ringing, _} -> 
            {ringing, #{}};
        {answer, _, Answer} ->
            {answer, #{answer=>Answer}};
        {hangup, Reason} ->
            {Code, Txt} = SrvId:error_code(Reason),
            {hangup, #{code=>Code, reason=>Txt}}
    end,
    case Send of
        {EvType, Body} ->
            do_send_ext_event(EvType, Body, State);
        ignore ->
            ok
    end,
    State.


%% @private
do_send_ext_event(Type, Body, #state{srv_id=SrvId, id=CallId}=State) ->
    RegId = #reg_id{
        srv_id = SrvId,     
        class = <<"media">>, 
        subclass = <<"call">>,
        type = nklib_util:to_binary(Type),
        obj_id = CallId
    },
    ?LLOG(info, "ext event: ~p", [RegId], State),
    nkservice_events:send(RegId, Body).





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
links_add(Id, Data, Pid, #state{links=Links}=State) ->
    State#state{links=nklib_links:add(Id, Data, Pid, Links)}.


% %% @private
% links_get(Id, #state{links=Links}) ->
%     nklib_links:get(Id, Links).


%% @private
links_remove(Id, #state{links=Links}=State) ->
    State#state{links=nklib_links:remove(Id, Links)}.


%% @private
links_down(Pid, #state{links=Links}=State) ->
    case nklib_links:down(Pid, Links) of
        {ok, Id, Data, Links2} -> 
            {ok, Id, Data, State#state{links=Links2}};
        not_found -> 
            not_found
    end.


% %% @private
% links_iter(Fun, #state{links=Links}) ->
%     nklib_links:iter(Fun, Links).


%% @private
links_fold(Fun, Acc, #state{links=Links}) ->
    nklib_links:fold(Fun, Acc, Links).






