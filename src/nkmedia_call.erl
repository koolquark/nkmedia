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

-export([start/2, hangup/2, hangup_all/0]).
-export([session_event/3, find/1, get_all/0]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, event/0]).


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Call ~s "++Txt, 
               [State#state.id | Args])).

-include("nkmedia.hrl").


%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().


-type event() :: 
    {ringing, nkmedia_session:id(), nkmedia:answer()} |
    {answer, nkmedia_session:id(), nkmedia:answer()} |
    {hangup, nkmedia:hangup_reason()}.


-type call_out_spec() ::
    [call_out()] | nkmedia_session:call_dest().


-type call_out() ::
    #{
        dest => nkmedia_session:call_dest(),
        wait => integer(),                      %% secs
        ring => integer(),
        sdp_type => webrtc | rtp
    }.



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Starts a new call
-spec start(nkmedia:call_dest(), nkmedia:session()) ->
    {ok, id(), pid()}.

start(Dest, Config) ->
    CallId = nklib_util:uuid_4122(),
    {ok, Pid} = gen_server:start(?MODULE, [CallId, Dest, self(), Config], []),
    {ok, CallId, Pid}.


%% @private
hangup_all() ->
    lists:foreach(fun({CallId, _Pid}) -> hangup(CallId, 16) end, get_all()).


%% @doc
-spec hangup(id(), nkmedia:hangup_reason()) ->
    ok | {error, term()}.

hangup(CallId, Reason) ->
    do_cast(CallId, {hangup, Reason}).


%% @private
-spec get_all() ->
    [{id(), nkmedia_session:id(), pid()}].

get_all() ->
    [{Id, SessId, Pid} || {{Id, SessId}, Pid} <- nklib_proc:values(?MODULE)].


%% ===================================================================
%% Private
%% ===================================================================


%% @private
%% Called from nkmedia_session if we started in with 'call' key
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
    sdp_type :: webrtc | rtp,
    pid :: pid()
}).

-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    dest :: nkmedia_session:call_dest(),
    session :: nkmedia_session:id(),
    session_mon :: reference(),
    outs = #{} :: #{nkmedia_session:id() => #session_out{}},
    out_pos = 0 :: integer(),
    timer :: reference()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()}.

init([CallId, Dest, SessPid, Session]) ->
    #{id:=SessId, srv_id:=SrvId} = Session,
    true = nklib_proc:reg({?MODULE, CallId}),
    nklib_proc:put(?MODULE, {CallId, SessId}),
    State = #state{
        id = CallId, 
        srv_id = SrvId, 
        dest = Dest,
        session = Session, 
        session_mon = monitor(process, SessPid)
    },
    lager:info("NkMEDIA Call ~s starting (~p, ~s)", [CallId, self(), SessId]),
    {ok, State2} = handle(nkmedia_call_init, [CallId], State),
    gen_server:cast(self(), start),
    {ok, State2}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(Msg, From, State) -> 
    handle(nkmedia_call_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast(start, #state{dest=Dest, session=Session}=State) ->
    #{offer:=Offer} = Session,
    IsP2P = maps:is_key(sdp, Offer),
    case handle(nkmedia_call_resolve, [Dest], State) of
        {ok, OutSpec, State3} ->
            #state{outs=Outs} = State4 = launch_outs(OutSpec, State3),
            ?LLOG(info, "resolved outs: ~p", [Outs], State4),
            case map_size(Outs) of
                0 ->
                    do_hangup(<<"No Destination">>, State);
                Size when IsP2P, Size>1 ->
                    do_hangup(<<"Multiple Destinations">>, State);
                _ ->
                    {noreply, State4}
            end;
        {hangup, Reason, State3} ->
            do_hangup(Reason, State3)
    end;

handle_cast({session_event, SessId, Event}, State) ->
    #state{outs=Outs} = State,
    case maps:find(SessId, Outs) of
        {ok, _CallOut}  ->
            process_out_event(Event, SessId, State);
        false ->
            ?LLOG(warning, "event from unknown session", [Event], State),
            {noreply, State}
    end;

handle_cast({hangup, Reason}, State) ->
    ?LLOG(info, "external hangup: ~p", [Reason], State),
    do_hangup(Reason, State);

handle_cast(stop, State) ->
    ?LLOG(info, "external stop", [], State),
    {stop, normal, State};

handle_cast(Msg, State) -> 
    handle(nkmedia_call_handle_cast, [Msg], State).


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({launch_out, SessId}, State) ->
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

handle_info({'DOWN', Ref, process, _Pid, Reason}, #state{session_mon=Ref}=State) ->
    case Reason of
        normal ->
            ?LLOG(info, "inbound session stopped (normal)", [], State);
        _ ->
            ?LLOG(notice, "inbound session stopped: ~p", [Reason], State)
    end,
    do_hangup(<<"Caller Monitor Down">>, State);

handle_info({timeout, _, status_timeout}, State) ->
    ?LLOG(info, "status timeout", [], State),
    do_hangup(607, State);

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
    catch handle(nkmedia_call_terminate, [Reason], State).


% ===================================================================
%% Internal
%% ===================================================================

%% @private Generate data and launch messages
-spec launch_outs(call_out_spec(), State) ->
    State.

launch_outs([], State) ->
    State;

launch_outs([CallOut|Rest], #state{outs=Outs, session=Session, out_pos=Pos}=State) ->
    #{dest:=Dest} = CallOut,
    Wait = case maps:find(wait, CallOut) of
        {ok, Wait0} -> Wait0;
        error -> 0
    end,
    Ring = case maps:find(ring, CallOut) of
        {ok, Ring0} -> Ring0;
        error -> maps:get(ring_timeout, Session, ?DEF_RING_TIMEOUT)
    end,
    SessId = nklib_util:uuid_4122(),
    Out = #session_out{
        dest = Dest, 
        ring = Ring, 
        pos = Pos, 
        launched = false,
        sdp_type = maps:get(sdp_type, CallOut, webrtc)
    },
    Outs2 = maps:put(SessId, Out, Outs),
    case Wait of
        0 -> self() ! {launch_out, SessId};
        _ -> erlang:send_after(1000*Wait, self(), {launch_out, SessId})
    end,
    launch_outs(Rest, State#state{outs=Outs2, out_pos=Pos+1});

launch_outs(Dest, State) ->
    launch_outs([#{dest=>Dest}], State).


%% @private
launch_out(SessId, #session_out{dest=Dest, pos=Pos, sdp_type=Type}=Out, State) ->
    #state{
        id = Id, 
        session = Session, 
        srv_id = SrvId, 
        outs = Outs
    } = State,
    case handle(nkmedia_call_invite, [SessId, Dest], State) of
        {call, Dest2, State2} ->
            ?LLOG(info, "launching out ~p (~p)", [Dest2, Pos], State),
            Config = Session#{
                id => SessId, 
                call => {Id, self()}
            },
            {ok, SessId, Pid} = nkmedia_session:start(SrvId, Config),
            Opts = #{async=>true, sdp_type=>Type},
            ok = nkmedia_session:set_op_async(Pid, {invite, Dest}, Opts),
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
remove_out(SessId, #state{outs=Outs}=State) ->
    case maps:find(SessId, Outs) of
        {ok, #session_out{pos=Pos}} ->
            Outs2 = maps:remove(SessId, Outs),
            case map_size(Outs2) of
                0 ->
                    ?LLOG(info, "all outs removed", [], State),
                    do_hangup(<<"No Answer">>, State#state{outs=#{}});
                _ -> 
                    ?LLOG(info, "removed out ~s (~p)", [SessId, Pos], State),
                    {noreply, State#state{outs=Outs2}}
            end;
        error ->
            {noreply, State}
    end.


%% @private
process_out_event({ringing, Answer}, SessId, State) ->
    {noreply, event({ringing, SessId, Answer}, State)};

process_out_event({answer, Answer}, SessId, State) ->
    ?LLOG(info, "received ANSWER", [], State),
    #state{outs=Outs} =State,
    Outs2 = maps:remove(SessId, Outs),
    State2 = hangup_all_outs(State#state{outs=Outs2}),
    State3 = event({answer, SessId, Answer}, State2),
    timer:sleep(2000),      % Give time for session to contact peer (and remove call_in)
    {stop, normal, State3};

process_out_event({hangup, _Reason}, SessId, State) ->
    remove_out(SessId, State);
    
process_out_event(_Event, _SessId, State) ->
    % ?LLOG(notice, "out session event: ~p", [Event], State),
    {noreply, State}.


%% @private
hangup_all_outs(#state{outs=Outs}=State) ->
    lists:foreach(
        fun
            ({SessId, #session_out{launched=true}}) when SessId ->
                nkmedia_session:hangup(SessId, <<"Cancel">>);
            ({_, _}) ->
                ok
        end,
        maps:to_list(Outs)),
    State#state{outs=#{}}.


%% @private
event(Event, #state{id=CallId, session=#{id:=SessId}}=State) ->
    nkmedia_session:call_event(SessId, CallId, Event),
    {ok, State2} = handle(nkmedia_call_event, [CallId, Event], State),
    State2.


%% @private
do_hangup(Reason, State) ->
    event({hangup, Reason}, State),
    {stop, normal, State}.




%% @private
handle(Fun, Args, State) ->
    nklib_gen_server:handle_any(Fun, Args, State, #state.srv_id, #state.session).


%% @private
find(Pid) when is_pid(Pid) ->
    {ok, Pid};

find(CallId) ->
    case nklib_proc:values({?MODULE, CallId}) of
        [{undefined, Pid}] -> {ok, Pid};
        [] -> not_found
    end.


% %% @private
% do_call(CallId, Msg) ->
%     do_call(CallId, Msg, 5000).


% %% @private
% do_call(CallId, Msg, Timeout) ->
%     case find(CallId) of
%         {ok, Pid} -> nklib_util:call(Pid, Msg, Timeout);
%         not_found -> {error, call_not_found}
%     end.


%% @private
do_cast(CallId, Msg) ->
    case find(CallId) of
        {ok, Pid} -> gen_server:cast(Pid, Msg);
        not_found -> {error, call_not_found}
    end.


