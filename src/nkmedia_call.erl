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

-export([start/2, get_status/1]).
-export([hangup/1, hangup/2, hangup_all/0]).
-export([session_event/3, find/1, get_all/0]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, event/0]).


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Call ~s (~p) "++Txt, 
               [State#state.id, State#state.status | Args])).

-include("nkmedia.hrl").


%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().


-type config() :: 
    #{
        id => id(),       
        srv_id => nkservice:id(),              
        session_id => nkmedia_session:id(),
        session_pid => pid(),
        offer => nkmedia:offer(),                      % From this option on
        type => nkmedia_session:type(),                % are meant for the outbound call
        mediaserver => nkmedia_session:mediaserver(),  
        wait_timeout => integer(),                     
        ring_timeout => integer(),          
        call_timeout => integer(),
        term() => term()                               % User defined
    }.


-type status() ::
    calling | ringing | ready | hangup.


-type ext_status() :: nkmedia_session:ext_status().


-type call() ::
    config() |
    #{
        dest => nkmedia:call_dest(),
        status => status(),
        ext_status => ext_status(),
        answer => nkmedia:answer()
    }.


-type event() ::
    {status, status(), ext_status()} | {info, term()}.


-type call_out_spec() ::
    [call_out()] | nkmedia_session:call_dest().


-type call_out() ::
    #{
        dest => nkmedia_session:call_dest(),
        wait => integer(),              %% secs
        ring => integer()
    }.



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Starts a new call
%% MUST have the fields: srv_id, offer (with sdp if p2p), 
%% session_id, session_pid.
-spec start(nkmedia:call_dest(), config()) ->
    {ok, id(), pid()}.

start(Dest, Config) ->
    {CallId, Config2} = nkmedia_util:add_uuid(Config),
    Config3 = Config2#{dest=>Dest},
    {ok, Pid} = gen_server:start(?MODULE, [Config3], []),
    {ok, CallId, Pid}.


%% @private
hangup_all() ->
    lists:foreach(fun({CallId, _Pid}) -> hangup(CallId) end, get_all()).


%% @doc
-spec hangup(id()) ->
    ok | {error, term()}.

hangup(CallId) ->
    hangup(CallId, 16).


%% @doc
-spec hangup(id(), nkmedia:hangup_reason()) ->
    ok | {error, term()}.

hangup(CallId, Reason) ->
    do_cast(CallId, {hangup, Reason}).


%% @doc
-spec get_status(id()) ->
    {ok, status(), ext_status(), integer()}.

get_status(SessId) ->
    do_call(SessId, get_status).


%% @private
-spec get_all() ->
    [{id(), nkmedia_session:id(), pid()}].

get_all() ->
    [{Id, SessId, Pid} || {{Id, SessId}, Pid} <- nklib_proc:values(?MODULE)].


%% ===================================================================
%% Private
%% ===================================================================

session_event(CallId, SessId, Event) ->
    do_cast(CallId, {session_event, SessId, Event}).


% ===================================================================
%% gen_server behaviour
%% ===================================================================

-record(session_out, {
    dest :: nkmedia_session:call_out(),
    ring :: integer(),
    pos :: integer(),
    launched :: boolean(),
    pid :: pid()
}).

-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    call :: call(),
    status :: status(),
    session_in :: {nkmedia_session:id(), pid(), reference()},
    session_out :: {nkmedia_session:id(), pid(), reference()},
    outs = #{} :: #{nkmedia_session:id() => #session_out{}},
    out_pos = 0 :: integer(),
    timer :: reference()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()}.

init([Call]) ->
    #{id:=Id, srv_id:=SrvId, session_id:=SessId, session_pid:=SessPid} = Call,
    true = nklib_proc:reg({?MODULE, Id}),
    nklib_proc:put(?MODULE, {Id, SessId}),
    State = #state{
        id = Id, 
        srv_id = SrvId, 
        status = init,
        call = Call,
        session_in = {SessId, SessPid, monitor(process, SessPid)}
    },
    lager:info("NkMEDIA Call ~s starting (~p, ~s)", [Id, self(), SessId]),
    {ok, State2} = handle(nkmedia_call_init, [Id], State),
    gen_server:cast(self(), start),
    {ok, status(calling, State2)}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(get_status, _From, State) ->
    #state{status=Status, timer=Timer, call=Call} = State,
    #{ext_status:=Info} = Call,
    {reply, {ok, Status, Info, erlang:read_timer(Timer) div 1000}, State};

handle_call(Msg, From, State) -> 
    handle(nkmedia_call_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast(start, #state{call=Call}=State) ->
    #{dest:=Dest, offer:=Offer} = Call,
    IsP2P = maps:is_key(sdp, Offer),
    case handle(nkmedia_call_resolve, [Dest], State) of
        {ok, OutSpec, State3} ->
            #state{outs=Outs} = State4 = launch_outs(OutSpec, State3),
            ?LLOG(info, "resolved outs: ~p", [Outs], State4),
            case map_size(Outs) of
                0 ->
                    stop_hangup(<<"No Destination">>, State);
                Size when IsP2P, Size>1 ->
                    stop_hangup(<<"Multiple Calls Not Allowed">>, State);
                _ ->
                    {noreply, State4}
            end;
        {hangup, Reason, State3} ->
            ?LLOG(info, "nkmedia_call_resolve: hangup (~p)", [Reason], State3),
            stop_hangup(Reason, State3)
    end;

handle_cast({session_event, SessId, Event}, State) ->
    #state{session_out=Out, outs=Outs} = State,
    case Out of
        {SessId, _, _} ->
            process_out_event(Event, State);
        _ ->
            case maps:find(SessId, Outs) of
                {ok, CallOut}  ->
                    process_call_out_event(Event, SessId, CallOut, State);
                false ->
                    ?LLOG(warning, "event from unknown session", [Event], State),
                    {noreply, State}
            end
    end;

handle_cast({hangup, Reason}, State) ->
    ?LLOG(info, "external hangup: ~p", [Reason], State),
    stop_hangup(Reason, State);

handle_cast(stop, State) ->
    ?LLOG(info, "external stop", [], State),
    {stop, normal, State};

handle_cast(Msg, State) -> 
    handle(nkmedia_call_handle_cast, [Msg], State).


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({launch_out, SessId}, #state{status=Status}=State)
        when Status==calling; Status==ringing ->
    case find_out(SessId, State) of
        {ok, #session_out{launched=false, ring=Ring}=Out} ->
            erlang:send_after(1000*Ring, self(), {ring_timeout, SessId}),
            launch_out(SessId, Out, State);
        {ok, Out} ->
            launch_out(SessId, Out, State);
        not_found ->
            % The call can have been removed because of timeout
            {noreply, State}
    end;

handle_info({launch_out, SessId}, State) ->
    remove_out(SessId, State);

handle_info({ring_timeout, SessId}, State) ->
    case find_out(SessId, State) of
        {ok, #session_out{dest=Dest, pos=Pos, launched=Launched}} ->
            ?LLOG(info, "call ring timeout for ~p (~p, ~s)", 
                  [Dest, Pos, SessId], State),
            case Launched of
                true -> 
                    nkmedia_session:hangup(SessId, <<"Ring Timeout">>);
                false ->
                    ok
            end,
            remove_out(SessId, State);
        not_found ->
            {noreply, State}
    end;

handle_info({'DOWN', Ref, process, _Pid, Reason}, #state{session_in={_, _, Ref}}=State) ->
    ?LLOG(warning, "inbound session stopped: ~p", [Reason], State),
    %% Should enter into 'recovery' mode
    {stop, normal, State};

handle_info({'DOWN', Ref, process, _Pid, Reason}, #state{session_out={_, _, Ref}}=State) ->
    ?LLOG(warning, "outbound session out stopped: ~p", [Reason], State),
    %% Should enter into 'recovery' mode
    {stop, normal, State};

handle_info({timeout, _, status_timeout}, State) ->
    ?LLOG(info, "status timeout", [], State),
    stop_hangup(607, State);

handle_info(Msg, #state{}=State) -> 
    handle(nkmedia_call_handle_info, [Msg], State).


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(OldVsn, State, Extra) ->
    nklib_gen_server:code_change(nkmedia_call_code_change, 
                                 OldVsn, State, Extra, 
                                 #state.srv_id, #state.call).

%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(Reason, State) ->
    ?LLOG(info, "stopped: ~p", [Reason], State),
    catch handle(nkmedia_call_terminate, [Reason], State),
    % Probably it is already
    _ = stop_hangup(<<"Session Stop">>, State). 


% ===================================================================
%% Internal
%% ===================================================================

%% @private Generate data and launch messages
-spec launch_outs(call_out_spec(), State) ->
    State.

launch_outs([], State) ->
    State;

launch_outs([CallOut|Rest], #state{outs=Outs, call=Call, out_pos=Pos}=State) ->
    #{dest:=Dest} = CallOut,
    Wait = case maps:find(wait, CallOut) of
        {ok, Wait0} -> Wait0;
        error -> 0
    end,
    Ring = case maps:find(ring, CallOut) of
        {ok, Ring0} -> Ring0;
        error -> maps:get(ring_timeout, Call, ?DEF_RING_TIMEOUT)
    end,
    SessId = nklib_util:uuid_4122(),
    Out = #session_out{dest=Dest, ring=Ring, pos=Pos, launched=false},
    Outs2 = maps:put(SessId, Out, Outs),
    case Wait of
        0 -> self() ! {launch_out, SessId};
        _ -> erlang:send_after(1000*Wait, self(), {launch_out, SessId})
    end,
    launch_outs(Rest, State#state{outs=Outs2, out_pos=Pos+1});

launch_outs(Dest, State) ->
    launch_outs([#{dest=>Dest}], State).


%% @private
launch_out(SessId, #session_out{dest=Dest, pos=Pos}=Out, State) ->
    #state{
        id = Id, 
        call = Call, 
        srv_id = SrvId, 
        outs = Outs
    } = State,
    case handle(nkmedia_call_out, [SessId, Dest], State) of
        {call, Dest2, State2} ->
            ?LLOG(info, "launching out ~p (~p)", [Dest2, Pos], State),
            NotShared = [dest, status, ext_status],
            Config1 = maps:without(NotShared, Call),
            Config2 = Config1#{
                id => SessId, 
                monitor => self(),
                b_dest => Dest2,
                nkmedia_call_id => Id
            },
            {ok, SessId, Pid} = nkmedia_session:start(SrvId, Config2),
            Out2 = Out#session_out{launched=true, pid=Pid},
            Outs2 = maps:put(SessId, Out2, Outs),
            {noreply, State2#state{outs=Outs2}};
        {retry, Secs, State2} ->
            ?LLOG(info, "retrying out ~p (~p, ~p secs)", [Dest, Pos, Secs], State),
            erlang:send_after(1000*Secs, self(), {launch_out, SessId}),
            {noreply, State2};
        {remove, State2} ->
            ?LLOG(info, "removing out ~p (~p)", [Dest, Pos], State),
            remove_out(SessId, State2)
    end.


%% @private
find_out(SessId, #state{outs=Outs}) ->
    case maps:find(SessId, Outs) of
        {ok, Out} -> {ok, Out};
        error -> not_found
    end.


%% @private
remove_out(SessId, #state{outs=Outs, status=Status}=State) ->
    case maps:find(SessId, Outs) of
        {ok, #session_out{pos=Pos}} ->
            Outs2 = maps:remove(SessId, Outs),
            case map_size(Outs2) of
                0 when Status==calling; Status==ringing ->
                    ?LLOG(info, "all outs removed", [], State),
                    stop_hangup(<<"No Answer">>, State#state{outs=#{}});
                _ -> 
                    ?LLOG(info, "removed out ~s (~p)", [SessId, Pos], State),
                    %% We shouuld hibernate
                    {noreply, State#state{outs=Outs2}}
            end;
        error ->
            {noreply, State}
    end.


%% @private
process_out_event({status, hangup, _Data}, State) ->
    stop_hangup(<<"Callee Hangup">>, State);

process_out_event({status, call, _}, State) ->
    {noreply, State};

process_out_event(Event, State) ->
    ?LLOG(warning, "outbound session event: ~p", [Event], State),
    {noreply, State}.


%% @private
process_call_out_event({status, wait, _Data}, _SessId, _Out, State) ->
    {noreply, State};

process_call_out_event({status, calling, _Data}, _SessId, _Out, State) ->
    {noreply, State};

process_call_out_event({status, ringing, Data}, _SessId, _Out, State) ->
    % If we sent several call, we won't accept sdp in ringing
    Data2 = case State of
        #state{out_pos=1} -> Data;
        _ -> #{}
    end,
    {noreply, status(ringing, Data2, State)};

process_call_out_event({status, ready, Data}, SessId, Out, State) ->
    case State of
        #state{status=Status} when Status==calling; Status==ringing ->
            #session_out{pid=SessPid} = Out,
            SessOut = {SessId, SessPid, monitor(process, SessPid)},
            State2 = State#state{session_out=SessOut},
            State3 = hangup_all_outs(State2),
            Data2 = Data#{session_peer_id=>SessId},
            {noreply, status(ready, Data2, State3)};
        _ ->
            nkmedia_session:hangup(SessId, <<"Already Answered">>),
            {noreply, State}
    end;

process_call_out_event({status, hangup, _Data}, SessId, _OutCall, State) ->
    remove_out(SessId, State);
    
process_call_out_event(Event, _SessId, _OutCall, State) ->
    ?LLOG(warning, "out session event: ~p", [Event], State),
    {noreply, State}.


%% @private Use this to generate hangup code, otherwise terminate will call it
stop_hangup(_Reason, #state{status=hangup}=State) ->
    {stop, normal, State};

stop_hangup(Reason, State) ->
    #state{session_out=SessOut} = State,
    State2 = hangup_all_outs(State),
    case SessOut of 
        {Out, _, _} ->  
            nkmedia_session:hangup(Out, Reason);
        undefined -> 
            ok
    end,
    {stop, normal, status(hangup, #{hangup_reason=>Reason}, State2)}.


%% @private
hangup_all_outs(#state{session_out=SessOut, outs=Outs}=State) ->
    case SessOut of
        {SessOutId, _, _} -> ok;
        undefined -> SessOutId = undefined
    end,
    lists:foreach(
        fun
            ({SessId, #session_out{launched=true}}) when SessId /= SessOutId ->
                nkmedia_session:hangup(SessId, <<"User Canceled">>);
            ({_, _}) ->
                ok
        end,
        maps:to_list(Outs)),
    State#state{outs=#{}}.


%% @private
status(Status, State) ->
    status(Status, #{}, State).


%% @private
status(Status, _Info, #state{status=Status}=State) ->
    State;

status(NewStatus, Info, #state{call=Call}=State) ->
    ?LLOG(info, "status changed to ~p", [NewStatus], State),
    State2 = State#state{
        status = NewStatus,
        call= Call#{status=>NewStatus, ext_status=>Info}
    },
    event({status, NewStatus, Info}, State2).


%% @private
event(Event, #state{id=Id}=State) ->
    {ok, State2} = handle(nkmedia_call_event, [Id, Event], State),
    State2.


%% @private
handle(Fun, Args, State) ->
    nklib_gen_server:handle_any(Fun, Args, State, #state.srv_id, #state.call).


%% @private
find(Pid) when is_pid(Pid) ->
    {ok, Pid};

find(CallId) ->
    case nklib_proc:values({?MODULE, CallId}) of
        [{undefined, Pid}] -> {ok, Pid};
        [] -> not_found
    end.


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


