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

%% @doc NkMEDIA application
-module(nkmedia_fs_server).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start_link/1, stop/1, register/2, get_config/1, api/2, bgapi/2]).
-export([start_inbound/3, start_outbound/2, channel_op/4]).
-export([get_all/0, stop_all/0]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).

-define(CONNECT_RETRY, 5000).

-define(LLOG(Type, Txt, Args, State),
	lager:Type("NkMEDIA FS (~p ~p) "++Txt, [State#state.pos, self()|Args])).

-define(CALL_TIME, 30000).



-define(EVENT_PROCESS, [
	<<"NkMEDIA">>, <<"HEARTBEAT">>,
	<<"CHANNEL_CREATE">>, <<"CHANNEL_PARK">>, <<"CHANNEL_DESTROY">>, 
	<<"CHANNEL_BRIDGE">>, <<"CHANNEL_HANGUP">>,
	<<"conference::maintenance">>
]).
	

-define(EVENT_IGNORE,	[
	<<"verto::client_connect">>, <<"verto::client_disconnect">>, <<"verto::login">>, 
	<<"CHANNEL_OUTGOING">>, <<"CHANNEL_STATE">>, <<"CHANNEL_CALLSTATE">>, 
	<<"CHANNEL_EXECUTE">>, <<"CHANNEL_EXECUTE_COMPLETE">>, <<"CHANNEL_UNBRIDGE">>,
	<<"CALL_STATE">>, <<"CHANNEL_ANSWER">>, <<"CHANNEL_UNPARK">>,
	<<"CHANNEL_HANGUP">>, <<"CHANNEL_HANGUP_COMPLETE">>, 
	<<"CHANNEL_PROGRESS">>, <<"CHANNEL_ORIGINATE">>, <<"CALL_UPDATE">>,
	<<"CALL_SECURE">>, <<"CODEC">>, <<"RECV_RTCP_MESSAGE">>, 
	<<"PRESENCE_IN">>, 
	<<"RELOADXML">>, <<"MODULE_LOAD">>, <<"MODULE_UNLOAD">>, <<"SHUTDOWN">>,
	<<"DEL_SCHEDULE">>, <<"UNPUBLISH">>,
	<<"CONFERENCE_DATA">>, 
	<<"TRAP">>
]).



-include("nkmedia.hrl").

%% ===================================================================
%% Types
%% ===================================================================


-type in_ch_opts() :: #{
	class => verto | sip,
	call_id => binary(),
	verto_dialog => map(),
	monitor => pid(),
	id => term()
}.


-type out_ch_opts() :: #{
	class => verto | sip,
	call_id => binary()
}.




%% ===================================================================
%% Public functions
%% ===================================================================


%% @private See callbacks functions in nkmedia_fs
-spec start_link(nkmedia_fs:start_opts()) ->
    {ok, pid()} | {error, term()}.

start_link(Config) ->
	Ip = nkmedia_app:get(docker_ip),
	gen_server:start_link({local, ?MODULE}, ?MODULE, [Config#{ip=>Ip}], []).


%% @private
stop(Pid) ->
	gen_server:cast(Pid, stop).


%% @private Registers a callback module
-spec register(pid(), module()) ->
	ok | {error, term()}.

register(Pid, CallBack) ->
	nklib_util:call(Pid, {register_callback, CallBack}).


%% @doc Generates a new inbound channel
-spec start_inbound(pid(), binary(), in_ch_opts()) ->
	{ok, CallId::binary(), pid(), SDP::binary()} | {error, term()}.

start_inbound(Pid, SDP1, #{class:=verto}=Opts) ->
	case nklib_util:call(Pid, {start_inbound, SDP1, Opts}, ?CALL_TIME) of
		{ok, CallId, ChPid} ->
			case nkmedia_fs_channel:wait_sdp(ChPid, #{}) of
				{ok, SDP2} ->
					{ok, CallId, ChPid, SDP2};
				{error, Error} ->
					{error, Error}
			end;
		{error, Error} ->
			{error, Error}
	end.


%% @doc Generates a new outbound channel at this server and node
-spec start_outbound(pid(), out_ch_opts()) ->
	{ok, CallId::binary(), SDP::binary()} | {error, term()}.

start_outbound(Pid, #{class:=Class}=Opts) when Class==verto; Class==sip ->
	case nklib_util:call(Pid, {start_outbound, Opts}, ?CALL_TIME) of
		{ok, CallId, ChPid} ->
			case nkmedia_fs_channel:wait_sdp(ChPid, #{}) of
				{ok, SDP2} ->
					{ok, CallId, SDP2};
				{error, Error} ->
					{error, Error}
			end;
		{error, Error} ->
			{error, Error}
	end.



%% @doc Tries to perform an operation over a channel.
%% We need to send the request to the right node.
-spec channel_op(pid(), binary(), nkmedia_fs_channel:op(), 
			     nkmedia_fs_channel:op_opts()) ->
	ok | {error, term()}.

channel_op(Pid, CallId, Op, Opts) ->
	nklib_util:call(Pid, {channel_op, CallId, Op, Opts}, ?CALL_TIME).


%% @private
-spec get_config(pid()) ->
	{ok, nkmedia_fs:start_opts()} | {error, term()}.

get_config(Pid) ->
	nklib_util:call(Pid, get_config, ?CALL_TIME).


%% @priavte
-spec api(pid(), iolist()) ->
	{ok, binary()} | {error, term()}.

api(Pid, Api) ->
	case nklib_util:call(Pid, get_event_port, ?CALL_TIME) of
		{ok, EventPort} ->
			Api1 = nklib_util:to_binary(Api),
			nkmedia_fs_event_protocol:api(EventPort, Api1);
		{error, Error} ->
			{error, Error}
	end.


%% @doc
-spec bgapi(pid(), iolist()) ->
	{ok, binary()} | {error, term()}.

bgapi(Pid, Api) ->
	case nklib_util:call(Pid, get_event_port, ?CALL_TIME) of
		{ok, EventPort} ->
			Api1 = nklib_util:to_binary(Api),
			nkmedia_fs_event_protocol:bgapi(EventPort, Api1);
		{error, Error} ->
			{error, Error}
	end.


%% @private
get_all() ->
	nklib_proc:values(?MODULE).


%% @private
stop_all() ->
	lists:foreach(fun({_, Pid}) -> stop(Pid) end, get_all()).



% ===================================================================
%% gen_server behaviour
%% ===================================================================


-record(state, {
	config2 :: nkmedia_fs:start_opts(),
	pos :: integer(),
	status :: nkmedia_fs:status(),
	callbacks = [] :: [module()],
	fs_conn :: pid(),
	channels = #{} :: #{CallId::binary() => ChPid::pid()},
	pids = #{} :: #{pid() => CallId::binary()}
}).


%% @private
-spec init(term()) ->
    {ok, tuple()} | {ok, tuple(), timeout()|hibernate} |
    {stop, term()} | ignore.

init([#{pos:=Pos}=Config]) ->
	State = #state{config2=Config, pos=Pos},
	process_flag(trap_exit, true),			% Channels and sessions shouldn't stop us
	nklib_proc:put(?MODULE, Pos),			% 
	self() ! connect,
	?LLOG(info, "started", [], State),
	{ok, State}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call({register_callback, CallBack}, _From, #state{callbacks=CallBacks}=State) ->
	CallBacks2 = nklib_util:store_value(CallBack, CallBacks),
	{reply, ok, State#state{callbacks=CallBacks2}};

handle_call(get_state, _From, State) ->
	{reply, State, State};

handle_call(_, _From, #state{status=Status}=State) when Status/=ready ->
	{reply, {error, {not_ready, Status}}, State};

handle_call(get_event_port, _From, #state{fs_conn=Conn}=State) ->
	{reply, {ok, Conn}, State};

handle_call(get_config, _From, #state{config2=Config}=State) ->
	{reply, {ok, Config}, State};

handle_call({start_inbound, SDP, Opts}, _From, #state{callbacks=CallBacks}=State) ->
	case Opts of
	    #{call_id:=CallId} -> ok;
	    _ -> CallId = nklib_util:uuid_4122()
	end,
	Dialog = maps:get(verto_dialog, Opts, #{}),
	In = {in, SDP, Dialog},
	{ok, ChPid} = nkmedia_fs_channel:start_link(self(), CallBacks, CallId, In, Opts),
	State2 = started_channel(CallId, ChPid, State),
	{reply, {ok, CallId, ChPid}, State2};

handle_call({start_outbound, Opts}, _From, #state{callbacks=CallBacks}=State) ->
	case Opts of
	    #{call_id:=CallId} -> ok;
	    _ -> CallId = nklib_util:uuid_4122()
	end,
	{ok, ChPid} = nkmedia_fs_channel:start_link(self(), CallBacks, CallId, out, Opts),
	State2 = started_channel(CallId, ChPid, State),
	{reply, {ok, CallId, ChPid}, State2};

handle_call({channel_op, CallId, Op, Opts}, From, #state{channels=Channels}=State) ->
	case maps:find(CallId, Channels) of
		{ok, Pid} ->
			spawn_link(
				fun() ->
					Reply = nkmedia_fs_channel:channel_op(Pid, Op, Opts),
					gen_server:reply(From, Reply)
				end),
			{noreply, State};
		error ->
			{reply, {error, unknown_channel}, State}
	end;

handle_call(Msg, _From, State) ->
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.


handle_cast(stop, State) ->
	{stop, normal, State};

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info(connect, #state{fs_conn=Pid}=State) when is_pid(Pid) ->
	true = is_process_alive(Pid),
	{noreply, State};

handle_info(connect, #state{config2=Config, pos=Pos}=State) ->
	State1 = update_status(connecting, State),
	case nkmedia_fs_docker:start(Config) of
		ok ->
			#{pos:=Pos, pass:=Pass} = Config,
			case nkmedia_fs_event_protocol:start(8021+Pos, Pass) of
				{ok, Pid} ->
					monitor(process, Pid),
					State2 = State1#state{fs_conn=Pid},
					{noreply, update_status(ready, State2)};
				{error, Error} ->
					?LLOG(warning, "could not connect: ~p", [Error], State),
					erlang:send_after(?CONNECT_RETRY, self(), connect),
					{noreply, State1}
			end;
		{error, Error} ->
			?LLOG(warning, "could not start FS: ~p", [Error], State),
			erlang:send_after(?CONNECT_RETRY, self(), connect),
			{noreply, State1}
	end;

handle_info({nkmedia_fs_event, _Pid, Name, Event}, State) ->
	% lager:info("EV: ~p", [Event]),
	Name1 = case Name of
		<<"CUSTOM">> -> maps:get(<<"Event-Subclass">>, Event);
		_ -> Name
	end,
	case lists:member(Name1, ?EVENT_PROCESS) of
		true ->
			{noreply, parse_event(Name1, Event, State)};
		false ->
			case lists:member(Name1, ?EVENT_IGNORE) of
				true -> 
					{noreply, State};
				false ->
					?LLOG(info, "ignoring event ~s", [Name1], State),
					lager:info("\n~s\n", [nklib_json:encode_pretty(Event)]),
					{noreply, State}
			end
	end;

handle_info({'DOWN', _Ref, process, Pid, _Reason}, #state{fs_conn=Pid}=State) ->
	?LLOG(warning, "connection event down", [], State),
	self() ! connect,
	{noreply, State#state{fs_conn=undefined}};

handle_info({'DOWN', _Ref, process, Pid, _Reason}=Info, State) ->
	#state{pids=Pids, channels=Channels, callbacks=_CallBacks} = State,
	case maps:find(Pid, Pids) of
		{ok, CallId} ->
			% ch_notify(CallBacks, CallId, stop),
			Channels2 = maps:remove(CallId, Channels),
			Pids2 = maps:remove(Pid, Pids),
			{noreply, State#state{channels=Channels2, pids=Pids2}};
		error ->
		    lager:warning("Module ~p received unexpected info: ~p (~p)", 
		    			  [?MODULE, Info, State]),
    		{noreply, State}
    end;

handle_info({'EXIT', _, normal}, State) ->
	{noreply, State};

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

terminate(_Reason, _State) ->
    ok.
    


% ===================================================================
%% Internal
%% ===================================================================


%% @private
started_channel(CallId, ChPid, State) ->
	monitor(process, ChPid),
	#state{channels=Channels, pids=Pids} = State,
	State#state{
		channels = maps:put(CallId, ChPid, Channels),
		pids = maps:put(ChPid, CallId, Pids)
	}.


%% @private
send_update(Update, #state{callbacks=CallBacks}=State) ->
	do_send_update(CallBacks, Update, State).


%% @private
do_send_update([], _Update, State) ->
	State;

do_send_update([CallBack|Rest], Update, #state{pos=Pos, status=Status}=State) ->
	Update2 = Update#{status=>Status, pos=>Pos},
	case nklib_util:apply(CallBack, nkmedia_fs_update, [self(), Update2]) of
		ok ->
			ok;
		Other ->
			?LLOG(warning, "Invalid response calling ~p:~p(~p, ~p): ~p", 
				  [CallBack, nkmedia_fs_update, self(), Update2, Other], State)
	end,
	do_send_update(Rest, Update, State).
	

%% @private
update_status(Status, #state{status=Status}=State) ->
	State;

update_status(NewStatus, #state{pos=Pos, status=OldStatus}=State) ->
	nklib_proc:put({?MODULE, Pos}, NewStatus),
	?LLOG(info, "status update ~p->~p", [OldStatus, NewStatus], State),
	send_update(#{}, State#state{status=NewStatus}).


%% @private
parse_event(<<"HEARTBEAT">>, Data, State) ->
	#{
		<<"Event-Info">> := Info,
		<<"FreeSWITCH-Version">> := Vsn, 
		<<"Idle-CPU">> := Idle,
		<<"Max-Sessions">> := MaxSessions,
		<<"Session-Count">> := SessionCount,
		<<"Session-Peak-FiveMin">> := PeakFiveMins,
		<<"Session-Peak-Max">> := PeakMax,
		<<"Session-Per-Sec">> := PerSec,
		<<"Session-Per-Sec-FiveMin">> := PerSecFiveMins,
		<<"Session-Per-Sec-Max">> := PerSecMax,
		<<"Session-Since-Startup">> := AllSessions,
		<<"Uptime-msec">> := UpTime
	} = Data,
	Stats = #{
		idle => round(binary_to_float(Idle)),
		max_sessions => binary_to_integer(MaxSessions),
		session_count => binary_to_integer(SessionCount),
		session_peak_five_mins => binary_to_integer(PeakFiveMins),
		session_peak_max => binary_to_integer(PeakMax),
		sessions_sec => binary_to_integer(PerSec),
		sessions_sec_five_mins => binary_to_integer(PerSecFiveMins),
		sessions_sec_max => binary_to_integer(PerSecMax),
		all_sessions => binary_to_integer(AllSessions),
		uptime => binary_to_integer(UpTime) div 1000
	},
	case Info of
		<<"System Ready">> -> ok;
		_ -> ?LLOG(warning, "unknown HEARTBEAT info: ~s", [Info], State)
	end,
	Update = #{vsn => Vsn, stats => Stats},
	send_update(Update, State);

parse_event(<<"NkMEDIA">>, _Data, State) ->
	% CallId = maps:get(<<"Unique-ID">>, Data),
	% ?LLOG(info, "Media EVENT: ~p", [Data], State),
	State;

parse_event(<<"CHANNEL_CREATE">>, Data, State) ->
	#state{channels=Channels, callbacks=CallBacks} = State,
	CallId = maps:get(<<"Unique-ID">>, Data),
	case maps:find(CallId, Channels) of
		{ok, ChPid} ->
			nkmedia_fs_channel:ch_create(ChPid, Data),
			State;
		error ->
			case Data of
				#{<<"variable_nkstatus">> := <<"outbound">>} ->
					{ok, ChPid} = 
						nkmedia_fs_channel:start_link(self(), CallBacks, CallId, out),
					started_channel(CallId, ChPid, State);
				_ ->
					?LLOG(warning, "event CHANNEL_CREATE for unknown channel ~s", 
						  [CallId], State),
					State
			end
	end;

parse_event(<<"CHANNEL_PARK">>, Data, #state{channels=Channels}=State) ->
	CallId = maps:get(<<"Unique-ID">>, Data),
	case maps:find(CallId, Channels) of
		{ok, ChPid} ->
			nkmedia_fs_channel:ch_park(ChPid);
		error ->
			?LLOG(warning, "event CHANNEL_PARK for unknown channel ~s", 
				  [CallId], State)
	end,
	State;

parse_event(<<"CHANNEL_HANGUP">>, Data, #state{channels=Channels}=State) ->
	CallId = maps:get(<<"Unique-ID">>, Data),
	Reason = maps:get(<<"Hangup-Cause">>, Data, <<"Unknown">>),
	case maps:find(CallId, Channels) of
		{ok, ChPid} ->
			nkmedia_fs_channel:ch_hangup(ChPid, Reason);
		error ->
			?LLOG(info, "event CHANNEL_HANGUP for unknown channel ~s", 
				  [CallId], State)
	end,
	State;

parse_event(<<"CHANNEL_DESTROY">>, Data, #state{channels=Channels}=State) ->
	CallId = maps:get(<<"Unique-ID">>, Data),
	case maps:find(CallId, Channels) of
		{ok, ChPid} ->
			nkmedia_fs_channel:stop(ChPid);
		error ->
			?LLOG(info, "event CHANNEL_CREATE for unknown channel ~s", 
				  [CallId], State)
	end,
	State;

parse_event(<<"CHANNEL_BRIDGE">>, Data, #state{channels=Channels}=State) ->
	CallIdA = maps:get(<<"Bridge-A-Unique-ID">>, Data),
	CallIdB = maps:get(<<"Bridge-B-Unique-ID">>, Data),
	case maps:find(CallIdA, Channels) of
		{ok, ChPidA} ->
			nkmedia_fs_channel:ch_join(ChPidA, CallIdB);
		error ->
			?LLOG(notice, "event CHANNEL_BRIDGE for unknown channel ~s", 
				  [CallIdA], State)
	end,
	case maps:find(CallIdB, Channels) of
		{ok, ChPidB} ->
			nkmedia_fs_channel:ch_join(ChPidB, CallIdA);
		error ->
			?LLOG(notice, "event CHANNEL_BRIDGE for unknown channel ~s", 
				  [CallIdB], State)
	end,
	State;

parse_event(<<"CONFERENCE_DATA">>, Data, State) ->
	lager:info("CONF1: ~s", [nklib_json:encode_pretty(Data)]),
	State;

parse_event(<<"conference::maintenance">>, Data, #state{channels=Channels}=State) ->
	case Data of
		#{<<"Action">> := <<"add-member">>} ->
			CallId = maps:get(<<"Unique-ID">>, Data),
			case maps:find(CallId, Channels) of
				{ok, ChPid} ->
					Room = maps:get(<<"Conference-Name">>, Data),
					nkmedia_fs_channel:ch_room(ChPid, Room);
				error ->
					?LLOG(warning, "event conf_add_member for unknown channel ~s", 
						  [CallId], State)
			end;
		_ ->
			ok
	end,
	nkmedia_fs_conference:fs_event(Data),
	State.










