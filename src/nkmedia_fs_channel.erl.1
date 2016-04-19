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

-module(nkmedia_fs_channel).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start_link/5, stop/1, channel_op/3, wait_sdp/2, wait_park/2]).
-export([sip_inbound_invite/4]).
-export([ch_create/2, ch_park/1, ch_join/2, ch_room/2, ch_hangup/2]).
-export([get_pid/1, get_all/0, stop_all/0]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Channel ~s (~p) "++Txt, 
               [State#state.call_id, State#state.status | Args])).

-define(CALL_OP_TIMEOUT, 30000).
-define(PING_TIMEOUT, 10000).
-define(PARK_TIMEOUT, 3*60*1000).
-define(ORIGINATE_TIME, 30000).


%% ===================================================================
%% Types
%% ===================================================================

-type status() ::
    wait_park | park | wait_op | {room, binary()} | {join, binary()} |
    {hangup, binary()}.

-type op() ::
    {join, CallId::binary()} | {room, binary()} | {room_layout, binary()} |
    {hangup, nkmedia_fs:q850()|binary()} | {dtmf, binary()} |
    {answer, SDP::binary()} | {sip, Url::binary()}.


-type op_opts() ::
    #{
        % generic opts
        call_timeout => pos_integer(),

        % answer opts
        verto_dialog => map(),

        % sip opts
        user => binary(),
        pass => binary(),
        proxy => binary()
    }.


-type class() ::
    {in, SDP::binary(), Dialog::map()} | out.
   


%% ===================================================================
%% Public
%% ===================================================================


%% @doc
-spec start_link(pid(), module(), binary(), class(), 
                 nkmedia_fs_server:in_ch_opts() | nkmedia_fs_server:out_ch_opts()) ->
    {ok, pid()}.

start_link(FsPid, CallBacks, CallId, Type, Opts) ->
    gen_server:start_link(?MODULE, [FsPid, CallBacks, CallId, Type, Opts], []).


%% @doc
-spec channel_op(binary()|pid(), op(), op_opts()) ->
    ok | {error, term()}.

channel_op(CallId, Op, Opts) ->
    case get_pid(CallId) of
        {ok, Pid} ->
            Timeout = maps:get(call_timeout, Opts, ?CALL_OP_TIMEOUT),
            nklib_util:call(Pid, {op, Op, Opts}, Timeout);
        not_found ->
            {error, {unknown_channel, CallId}}
    end.


%% @doc
-spec wait_sdp(binary()|pid(), op_opts()) ->
    {ok, binary()} | {error, term()}.

wait_sdp(CallId, Opts) ->
    case get_pid(CallId) of
        {ok, Pid} ->
            Timeout = maps:get(call_timeout, Opts, ?CALL_OP_TIMEOUT),
            nklib_util:call(Pid, wait_sdp, Timeout);
        not_found ->
            {error, {unknown_channel, CallId}}
    end.


%% @doc
-spec wait_park(binary()|pid(), op_opts()) ->
    {ok, binary()} | {error, term()}.

wait_park(CallId, Opts) ->
    case get_pid(CallId) of
        {ok, Pid} ->
            Timeout = maps:get(call_timeout, Opts, ?CALL_OP_TIMEOUT),
            nklib_util:call(Pid, wait_park, Timeout);
        not_found ->
            {error, {unknown_channel, CallId}}
    end.



sip_inbound_invite(CallId, Handle, Dialog, SDP) ->
    case get_pid(CallId) of
        {ok, Pid} ->
            nklib_util:call(Pid, {inbound_invite, Handle, Dialog, SDP});
        not_found ->
            {error, {unknown_channel, CallId}}
    end.




%% ===================================================================
%% Internal
%% ===================================================================


%% @private Called from freeswitch
ch_create(ChPid, #{<<"Caller-Direction">>:=<<"inbound">>}=Event) ->
    #{
        <<"Answer-State">> := AnsState,
        <<"Channel-Call-State">> := CallState,
        <<"Caller-Username">> := Username
    } = Event,
    Data = #{
        answer_state => AnsState,
        call_state => CallState,
        username => Username
    },
    gen_server:cast(ChPid, {event, {created_in, Data}});

ch_create(ChPid, #{<<"Caller-Direction">>:=<<"outbound">>}=Event) ->
    #{
        <<"Answer-State">> := AnsState,
        <<"Channel-Call-State">> := CallState,
        <<"variable_rtp_local_sdp_str">> := SDP
    } = Event,
    Data = #{
        answer_state => AnsState,
        call_state => CallState
    },
    gen_server:cast(ChPid, {event, {created_out, SDP, Data}}).


%% @private
ch_park(ChPid) ->
    gen_server:cast(ChPid, {event, park}).


%% @private
ch_join(ChPid, CallId) ->
    gen_server:cast(ChPid, {event, {join, CallId}}).


%% @private
ch_room(ChPid, Room) ->
    gen_server:cast(ChPid, {event, {room, Room}}).


%% @private
ch_hangup(ChPid, Reason) ->
    gen_server:cast(ChPid, {event, {hangup, Reason}}).


%% @private
stop(ChPid) ->
    gen_server:cast(ChPid, stop).


%% @doc
get_pid(Pid) when is_pid(Pid) ->
    {ok, Pid};

get_pid(CallId) ->
    case nklib_proc:values({?MODULE, CallId}) of
        [{undefined, Pid}|_] -> {ok, Pid};
        [] -> not_found
    end.


%% @doc
get_all() ->
    nklib_proc:values(?MODULE).

stop_all() ->
   lists:foreach(fun({_, Pid}) -> stop(Pid) end, get_all()).
        


% ===================================================================
%% gen_server behaviour
%% ===================================================================


-record(call_op, {
    op :: op(),
    opts :: op_opts(),
    from :: {pid(), term()}
}).


-record(state, {
    fs_pid :: pid(),
    call_id :: binary(),
    callbacks :: [module()],
    class :: verto | sip,
    client_id :: term(),
    client_pid :: pid(),
    status :: status(),
    sdp :: binary(),
    data = #{} :: map(),
    session_pid :: pid(),
    session_id :: binary(),
    pending = [] :: [#call_op{}],
    waiting :: #call_op{},
    timer :: reference(),
    wait_sdp :: {pid(), term()},
    wait_park :: {pid(), term()},
    sip_handle :: binary(),
    sip_dialog :: binary()
}).



%% @private
-spec init(term()) ->
    {ok, tuple()}.

init([FsPid, CallBacks, CallId, Type, Opts]) ->
    Id = maps:get(id, Opts, none),
    Pid = maps:get(monitor, Opts, undefined),
    State1 = #state{
        fs_pid = FsPid,
        call_id = CallId,
        callbacks = CallBacks,
        client_id = Id,
        client_pid = Pid
    },
    case is_pid(Pid) of
        true -> monitor(process, Pid);
        false -> ok
    end,
    nklib_proc:put({?MODULE, CallId}),
    self() ! send_ping,
    case Type of
        {in, SDP, Dialog} ->
            gen_server:cast(self(), connect_in),
            {ok, State1#state{class=verto, sdp=SDP, data=Dialog}};
        out ->
            gen_server:cast(self(), connect_out),
            Class = maps:get(class, Opts),
            {ok, State1#state{class=Class}}
    end.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call({op, Op, Opts}, From, #state{pending=Pending}=State) ->
    case quick_ops(Op, Opts, State) of
        {true, Reply, State2} ->
            {reply, Reply, State2};
        false ->
            Pending2 = Pending ++ [#call_op{op=Op, opts=Opts, from=From}],
            State2 = State#state{pending=Pending2},
            {noreply, perform_ops(State2)}
    end;

handle_call(get_call_id, _From, #state{call_id=CallId}=State) ->
    {reply, {ok, CallId}, State};

handle_call(wait_sdp, From, #state{wait_sdp=undefined, sdp=SDP}=State) ->
    case is_binary(SDP) of
        true ->
            {reply, {ok, SDP}, State};
        false ->
            {noreply, State#state{wait_sdp=From}}
    end;

handle_call(wait_park, From, #state{wait_park=undefined, status=Status}=State) ->
    case Status of
        park ->
            {reply, ok, State};
        _ ->
            {noreply, State#state{wait_park=From}}
    end;

handle_call({inbound_invite, Handle, Dialog, _SDP}, _From, State) ->
    State2 = State#state{sip_handle=Handle, sip_dialog=Dialog},
    {reply, ok, State2};

handle_call(Msg, _From, State) ->
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast(connect_in, State) ->
    #state{fs_pid=FsPid, call_id=CallId, sdp=SDP, data=Dialog} = State,
    State2 = update_status(wait_park, State),
    case nkmedia_verto_client:start(FsPid) of
        {ok, _SessId, SessPid} ->
            Dialog2 = Dialog#{<<"callID">> => CallId},
            case 
                nkmedia_verto_client:invite(SessPid, "nkmedia_in", SDP, Dialog2) 
            of
                {ok, SDP2} ->
                    State3 = State2#state{sdp=SDP2, session_pid=SessPid, data=#{}},
                    {noreply, State3};
                {error, Error} ->
                    nkmedia_verto_client:stop(SessPid),
                    ?LLOG(warning, "invite error: ~p", [Error], State2),
                    {stop, normal, State2}
            end;
        {error, Error} ->
            ?LLOG(warning, "sesion error: ~p", [Error], State),
            {stop, normal, State2}
    end;

handle_cast(connect_out, #state{class=verto, fs_pid=FsPid}=State) ->
    State2 = update_status(wait_park, State),
    case nkmedia_verto_client:start(FsPid) of
        {ok, SessId, SessPid} ->
            State3 = State2#state{session_pid=SessPid, session_id=SessId, data=#{}},
            originate_verto(State3),
            {noreply, State3};
        {error, Error} ->
            ?LLOG(warning, "sesion error: ~p", [Error], State),
            {stop, normal, State2}
    end;

handle_cast(connect_out, #state{class=sip}=State) ->
    State2 = update_status(wait_park, State),
    originate_sip(State2),
    {noreply, State2};

handle_cast({event, Event}, State) ->
    {noreply, process_event(Event, State)};

handle_cast({originate_error, Error}, #state{class=Class}=State) ->
    ?LLOG(info, "originate ~p error: ~p", [Class, Error], State),
    {noreply, State};

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info(send_ping, State) ->
    send_notify(ping, State),
    erlang:send_after(?PING_TIMEOUT, self(), send_ping),
    {noreply, State};

handle_info({timeout, _, park}, State) ->
    ?LLOG(notice, "park timeout", [], State),
    State2 = State#state{pending=[#call_op{op={hangup, <<"Park Timeout">>}}]},
    {noreply, perform_ops(State2)};

handle_info({'DOWN', _Ref, process, Pid, _Reason}, #state{client_pid=Pid}=State) ->
    ?LLOG(info, "user process ~p down", [State#state.client_id], State),
    do_transfer(<<"nkmedia_hangup_user_down">>, State),
    {stop, normal, State};

handle_info(Info, State) -> 
    lager:warning("Module ~p received unexpected info: ~p (~p)", [?MODULE, Info, State]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(_Reason, #state{pending=CallOps, waiting=Waiting}=State) ->
    ?LLOG(info, "stopped", [], State),
    send_notify({status, stop}, State),
    CallOps2 = case Waiting of
        #call_op{} = Call -> [Call|CallOps];
        undefined -> CallOps
    end,
    lists:foreach(
        fun(#call_op{op=Op}=CallOp) ->
            Reply = case Op of
                {hangup, _} -> ok;
                _ -> {error, channel_destroyed}
            end,
            user_reply(Reply, CallOp)
        end,
        CallOps2).

    


% ===================================================================
%% Internal
%% ===================================================================

%% @private
update_status(Status, #state{status=Status}=State) ->
    State;

update_status(NewStatus, #state{call_id=CallId, timer=Timer, pending=Pending}=State) ->
    ?LLOG(info, "status changed to ~p: ~p", [NewStatus, Pending], State),
    nklib_proc:put(?MODULE, {CallId, NewStatus}),
    nklib_util:cancel_timer(Timer),
    Timer2 = case NewStatus of
        park ->
            erlang:start_timer(?PARK_TIMEOUT, self(), park);
        _ ->
            undefined
    end,
    State2 = State#state{status=NewStatus, timer=Timer2},
    send_notify({status, NewStatus}, State2).


%% @private
send_notify(Msg, #state{callbacks=CallBacks, pending=Pending}=State) ->
    UserMsg = case Msg of
        {status, wait_park} -> {status, wait};
        {status, wait_op} -> {status, wait};
        {status, park} when Pending /= [] -> {status, wait};
        {status, Status} -> {status, Status};
        ping -> ping
    end,
    do_send_notify(CallBacks, UserMsg, State).


%% @private
do_send_notify([], _Msg, State) ->
    State;

do_send_notify([CallBack|Rest], Msg, #state{call_id=CallId, client_id=Id}=State) ->
    case nklib_util:apply(CallBack, nkmedia_fs_ch_notify, [CallId, Id, Msg]) of
        ok ->
            ok;
        Other ->
            ?LLOG(warning, "invalid callback response: ~p", [Other], State)
    end,
    do_send_notify(Rest, Msg, State).


%% @private
process_event({created_in, Data}, State) ->
    State#state{data=Data};

process_event({created_out, SDP, Data}, #state{wait_sdp=From}=State) ->
    case From of
        undefined -> ok;
        _ -> gen_server:reply(From, {ok, SDP})
    end,
    State#state{sdp=SDP, data=Data, wait_sdp=SDP};

process_event(park, #state{status=Status, wait_park=WaitPark}=State) ->
    case Status of
        wait_park -> ok;
        _ -> ?LLOG(warning, "received park event in state ~p", [Status], State)
    end,
    State2 = case WaitPark of
        undefined -> 
            State;
        _ -> 
            gen_server:reply(WaitPark, ok),
            State#state{wait_park=undefined}
    end,
    State3 = update_status(park, State2),
    perform_ops(State3);

process_event({room, Room}, #state{status=Status, waiting=Waiting}=State) ->
    case Waiting of
        #call_op{op={room, _}} when Status==wait_op ->
            user_reply(ok, Waiting);
        #call_op{op=Op} ->
            user_reply({error, {channel_updated, Status, Op}}, Waiting);
        undefined ->
            ok
    end,
    State2 = update_status({room, Room}, State#state{waiting=undefined}),
    perform_ops(State2);

process_event({join, Bridge}, #state{status=Status, waiting=Waiting}=State) ->
    case Waiting of
        #call_op{op={join, _}} when Status==wait_op ->
            user_reply(ok, Waiting);
        #call_op{op=Op} ->
            user_reply({error, {channel_updated, Status, Op}}, Waiting);
        undefined ->
            ok
    end,
    State2 = update_status({join, Bridge}, State#state{waiting=undefined}),
    perform_ops(State2);

process_event({hangup, Reason}, #state{waiting=Waiting}=State) ->
    case Waiting of
        #call_op{op={hangup, _}} ->
            user_reply(ok, Waiting);
        #call_op{} ->
            user_reply({error, channel_hangup}, Waiting);
        undefined ->
            ok
    end,
    State2 = update_status({hangup, Reason}, State#state{waiting=undefined}),
    perform_ops(State2).


%% @private
perform_ops(#state{pending=[]}=State) ->
    State;

perform_ops(#state{status=park, pending=[CallOp|Rest]}=State) ->
    case do_call_op(CallOp, State) of
        ok ->
            State2 = State#state{pending=Rest, waiting=CallOp},
            update_status(wait_op, State2);
        {error, Error} ->
            user_reply({error, Error}, CallOp),
            perform_ops(State#state{pending=Rest})
    end;

perform_ops(State) ->
    do_park(State).



%% @private
do_park(State) ->
    do_transfer(<<"nkmedia_route">>, State),
    update_status(wait_park, State).


%% @private
do_call_op(#call_op{op={hangup, Code}}, State) ->
    Reason = nkmedia_util:q850_to_msg(Code),
    Ext = <<"nkmedia_hangup_", Reason/binary>>,
    do_transfer(Ext, State);

do_call_op(#call_op{op={join, CallId2}}, #state{call_id=CallId1}=State) ->
    Api = list_to_binary([<<"uuid_bridge ">>, CallId1, <<" ">>, CallId2]),
    do_api(Api, State);

do_call_op(#call_op{op={room, Room}}, State) ->
    Ext = list_to_binary([<<"nkmedia_room_">>, Room]),
    do_transfer(Ext, State);

do_call_op(#call_op{op=Op}, _State) ->
    {error, {invalid_op, Op}}.


%% @private
do_transfer(Ext, #state{fs_pid=Pid, call_id=CallId}) ->
    {ok, _} = nkmedia_fs_cmd:transfer(Pid, CallId, Ext),
    ok.



%% @private
do_api(Api, #state{fs_pid=Pid}) ->
    {ok, _} = nkmedia_fs_server:bgapi(Pid, Api),
    ok.


%% @private
quick_ops({dtmf, DTMF}, _Opts, #state{fs_pid=Pid, call_id=CallId}=State) ->
    nkmedia_fs_cmd:dtmf(Pid, CallId, DTMF),
    {true, ok, State};

quick_ops({room_layout, Layout}, _Opts, #state{status=Status}=State) ->
    case Status of
        {room, Room} ->
            Api = <<
                "conference ", Room/binary, " vid-layout ",
                (nklib_util:to_binary(Layout))/binary
            >>,
            case do_api(Api, State) of
                {ok, <<"Change ", _/binary>>} -> {true, ok, State};
                {ok, Other} -> {true, {error, Other}, State};
                {error, Error} -> {true, {error, Error}, State}
            end;
        _ ->
            {true, {error, no_room}, State}
    end;

quick_ops({answer, SDP}, Opts, #state{class=verto, session_pid=SessPid}=State) ->
    Dialog = maps:get(verto_dialog, Opts, #{}),
    case nkmedia_verto_client:answer(SessPid, SDP, Dialog) of
        ok ->
            {true, ok, State};
        {error, Error} ->
            {true, {error, Error}, State}
    end;

quick_ops({answer, SDP}, _Opts, #state{class=sip}=State) ->
    #state{sip_handle=Handle} = State,
    case nksip_request:reply({ok, [{body, SDP}]}, Handle) of
        ok ->
            {true, ok, State};
        {error, Error} ->
            {true, {error, Error}, State}
    end;

quick_ops(_, _, _) ->
    false.


%% @private
originate_verto(#state{call_id=CallId, fs_pid=FsPid, session_id=SessId}) ->
    Dest = <<"verto.rtc/u:", SessId/binary>>,
    Vars = [{<<"nkstatus">>, <<"outbound">>}], 
    CallOpts = #{vars => Vars, timeout=>?ORIGINATE_TIME, call_id=>CallId},
    Self = self(),
    spawn_link(
        fun() ->
            case nkmedia_fs_cmd:call(FsPid, Dest, <<"nkmedia_out">>, CallOpts) of
                {ok, CallId} -> ok;
                {error, Error} -> gen_server:cast(Self, {originate_error, Error})
            end
        end).


%% @private
user_reply(_Msg, #call_op{from=undefined}) -> ok;
user_reply(Msg, #call_op{from=From}) -> gen_server:reply(From, Msg).



% ===================================================================
%% SIP
%% ===================================================================


originate_sip(#state{fs_pid=FsPid, call_id=CallId}) ->
    Host = nklib_util:to_host(nkmedia_app:get(erlang_ip)),
    Port = nkmedia_app:get(sip_port),
    Sip = <<Host/binary, ":", (nklib_util:to_binary(Port))/binary, ";transport=tcp">>,
    Vars = [{<<"nkstatus">>, <<"outbound">>}], 
    CallOpts = #{vars=>Vars, call_id=>CallId},
    Dest = <<"sofia/internal/", CallId/binary, "@", Sip/binary>>,
    Self = self(),
    spawn_link(
        fun() ->
            case nkmedia_fs_cmd:call(FsPid, Dest, <<"nkmedia_out">>, CallOpts) of
                {ok, CallId} -> ok;
                {error, Error} -> gen_server:cast(Self, {originate_error, Error})
            end
        end).




% Layouts
% 1up_top_left+5
% 1up_top_left+7
% 1up_top_left+9
% 1x1
% 1x1+2x1
% 1x2
% 2up_bottom+8
% 2up_middle+8
% 2up_top+8
% 2x1
% 2x1-presenter-zoom
% 2x1-zoom
% 2x2
% 3up+4
% 3up+9
% 3x1-zoom
% 3x2-zoom
% 3x3
% 4x2-zoom
% 4x4, 
% 5-grid-zoom
% 5x5
% 6x6
% 7-grid-zoom
% 8x8
% overlaps
% presenter-dual-horizontal
% presenter-dual-vertical
% presenter-overlap-large-bot-right
% presenter-overlap-large-top-right
% presenter-overlap-small-bot-right
% presenter-overlap-small-top-right






