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
-module(nkmedia_fs_engine).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([connect/1, stop/1, find/1]).
-export([stats/2, register/2, get_config/1, api/2, bgapi/2]).
-export([start_inbound/3, start_outbound/2, channel_op/4]).
-export([get_all/0, stop_all/0]).
-export([start_link/1, init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).

-define(CONNECT_RETRY, 5000).

-define(LLOG(Type, Txt, Args, State),
	lager:Type("NkMEDIA FS Engine '~s' "++Txt, [State#state.name|Args])).

-define(CALL_TIME, 30000).

-define(EVENT_PROCESS, [
	<<"NkMEDIA">>, <<"HEARTBEAT">>,
	<<"CHANNEL_CREATE">>, <<"CHANNEL_PARK">>, <<"CHANNEL_DESTROY">>, 
	<<"CHANNEL_BRIDGE">>, <<"CHANNEL_HANGUP">>, <<"SHUTDOWN">>,
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

-type config() ::
	#{
		name => binary(),
		rel => binary(),
		host => binary(),
		pass => binary()
	}.


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

%% @private
-spec connect(config()) ->
	{ok, pid()} | {error, term()}.

connect(#{name:=Name, rel:=Rel, host:=Host, pass:=Pass}=Config) ->
	case find(Name) of
		not_found ->
			case connect_fs(Host, Pass, 10) of
				ok ->
					nkmedia_sup:start_fs_engine(Config);
				error ->
					{error, no_connection}
			end;
		{ok, _Status, FsPid, _ConnPid} ->
			case get_config(FsPid) of
				{ok, #{rel:=Rel, pass:=Pass}} ->
					{ok, FsPid};
				_ ->
					{error, incompatible_version}
			end
	end.


%% @private
stop(Pid) when is_pid(Pid) ->
	gen_server:cast(Pid, stop);

stop(Name) ->
	case find(Name) of
		{ok, _Status, FsPid, _ConnPid} -> stop(FsPid);
		not_found -> ok
	end.


%% @private
stats(Name, Stats) ->
	case find(Name) of
		{ok, _Status, FsPid, _ConnPid} -> gen_server:cast(FsPid, {stats, Stats});
		not_found -> ok
	end.


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
	{ok, config()} | {error, term()}.

get_config(Pid) ->
	nklib_util:call(Pid, get_config, ?CALL_TIME).


%% @priavte
-spec api(binary()|pid(), iolist()) ->
	{ok, binary()} | {error, term()}.

api(NameOrPid, Api) ->
	case find(NameOrPid) of
		{ok, ready, _FsPid, ConnPid} when is_pid(ConnPid) ->
			nkmedia_fs_event_protocol:api(ConnPid, Api);
		{ok, _, _, _} ->
			{error, not_ready};
		not_found ->
			{error, no_connection}
	end.


%% @doc
-spec bgapi(binary()|pid(), iolist()) ->
	{ok, binary()} | {error, term()}.

bgapi(NameOrPid, Api) ->
	case find(NameOrPid) of
		{ok, ready, _FsPid, ConnPid} when is_pid(ConnPid) ->
			nkmedia_fs_event_protocol:bgapi(ConnPid, Api);
		{ok, _, _, _} ->
			{error, not_ready};
		not_found ->
			{error, no_connection}
	end.


%% @private
get_all() ->
	nklib_proc:values(?MODULE).


%% @private
find(NameOrPid) ->
	NameOrPid2 = case is_pid(NameOrPid) of
		true -> NameOrPid;
		false -> nklib_util:to_binary(NameOrPid)
	end,
	case nklib_proc:values({?MODULE, NameOrPid2}) of
		[{{Status, ConnPid}, FsPid}] -> {ok, Status, FsPid, ConnPid};
		[] -> not_found
	end.


%% @private
stop_all() ->
	lists:foreach(fun({_, Pid}) -> stop(Pid) end, get_all()).


%% @private 
-spec start_link(config()) ->
    {ok, pid()} | {error, term()}.

start_link(Config) ->
	gen_server:start_link(?MODULE, [Config], []).





% ===================================================================
%% gen_server behaviour
%% ===================================================================


-record(state, {
	config :: config(),
	name :: binary(),
	% ip :: binary(),
	% pass :: binary(),
	status :: nkmedia_fs:status(),
	fs_conn :: pid()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()} | {ok, tuple(), timeout()|hibernate} |
    {stop, term()} | ignore.

init([#{name:=Name}=Config]) ->
	State = #state{config=Config, name=Name},
	process_flag(trap_exit, true),			% Channels and sessions shouldn't stop us
	nklib_proc:put(?MODULE, Name),
	true = nklib_proc:reg({?MODULE, Name}, {connecting, undefined}),
	self() ! connect,
	?LLOG(info, "started (~p)", [self()], State),
	{ok, State}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(get_state, _From, State) ->
	{reply, State, State};

handle_call(_, _From, #state{status=Status}=State) when Status/=ready ->
	{reply, {error, {not_ready, Status}}, State};

handle_call(get_event_port, _From, #state{fs_conn=Conn}=State) ->
	{reply, {ok, Conn}, State};

% handle_call({start_inbound, SDP, Opts}, _From, #state{callbacks=CallBacks}=State) ->
% 	case Opts of
% 	    #{call_id:=CallId} -> ok;
% 	    _ -> CallId = nklib_util:uuid_4122()
% 	end,
% 	Dialog = maps:get(verto_dialog, Opts, #{}),
% 	In = {in, SDP, Dialog},
% 	{ok, ChPid} = nkmedia_fs_channel:start_link(self(), CallBacks, CallId, In, Opts),
% 	State2 = started_channel(CallId, ChPid, State),
% 	{reply, {ok, CallId, ChPid}, State2};

% handle_call({start_outbound, Opts}, _From, #state{callbacks=CallBacks}=State) ->
% 	case Opts of
% 	    #{call_id:=CallId} -> ok;
% 	    _ -> CallId = nklib_util:uuid_4122()
% 	end,
% 	{ok, ChPid} = nkmedia_fs_channel:start_link(self(), CallBacks, CallId, out, Opts),
% 	State2 = started_channel(CallId, ChPid, State),
% 	{reply, {ok, CallId, ChPid}, State2};

% handle_call({channel_op, CallId, Op, Opts}, From, #state{channels=Channels}=State) ->
% 	case maps:find(CallId, Channels) of
% 		{ok, Pid} ->
% 			spawn_link(
% 				fun() ->
% 					Reply = nkmedia_fs_channel:channel_op(Pid, Op, Opts),
% 					gen_server:reply(From, Reply)
% 				end),
% 			{noreply, State};
% 		error ->
% 			{reply, {error, unknown_channel}, State}
% 	end;

handle_call(get_config, _From, #state{config=Config}=State) ->
    {reply, {ok, Config}, State};

handle_call(Msg, _From, State) ->
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({stats, _Stats}, State) ->
	{noreply, State};

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

handle_info(connect, #state{config=#{host:=Host, pass:=Pass}}=State) ->
	State2 = update_status(connecting, State#state{fs_conn=undefined}),
	case nkmedia_fs_event_protocol:start(Host, Pass) of
		{ok, Pid} ->
			monitor(process, Pid),
			State3 = State2#state{fs_conn=Pid},
			{noreply, update_status(ready, State3)};
		{error, Error} ->
			?LLOG(warning, "could not connect: ~p", [Error], State2),
			{stop, normal, State2}
	end;

handle_info({nkmedia_fs_event, _Pid, <<"SHUTDOWN">>, _Event}, State) ->
	{stop, normal, State};

handle_info({nkmedia_fs_event, _Pid, <<"HEARTBEAT">>, _Event}, State) ->
	{noreply, State};

handle_info({nkmedia_fs_event, _Pid, Name, Event}, State) ->
	% lager:info("EV: ~p", [Event]),
	Name2 = case Name of
		<<"CUSTOM">> -> maps:get(<<"Event-Subclass">>, Event);
		_ -> Name
	end,
	case lists:member(Name2, ?EVENT_PROCESS) of
		true ->
			{noreply, parse_event(Name2, Event, State)};
		false ->
			case lists:member(Name2, ?EVENT_IGNORE) of
				true -> 
					{noreply, State};
				false ->
					?LLOG(info, "ignoring event ~s", [Name2], State),
					lager:info("\n~s\n", [nklib_json:encode_pretty(Event)]),
					{noreply, State}
			end
	end;

handle_info({'DOWN', _Ref, process, Pid, _Reason}, #state{fs_conn=Pid}=State) ->
	?LLOG(warning, "connection event down", [], State),
	erlang:send_after(?CONNECT_RETRY, self(), connect),
	{noreply, update_status(connecting, State#state{fs_conn=undefined})};

% handle_info({'DOWN', _Ref, process, Pid, _Reason}=Info, State) ->
% 	#state{pids=Pids, channels=Channels, callbacks=_CallBacks} = State,
% 	case maps:find(Pid, Pids) of
% 		{ok, CallId} ->
% 			% ch_notify(CallBacks, CallId, stop),
% 			Channels2 = maps:remove(CallId, Channels),
% 			Pids2 = maps:remove(Pid, Pids),
% 			{noreply, State#state{channels=Channels2, pids=Pids2}};
% 		error ->
% 		    lager:warning("Module ~p received unexpected info: ~p (~p)", 
% 		    			  [?MODULE, Info, State]),
%     		{noreply, State}
%     end;

% handle_info({'EXIT', _, normal}, State) ->
% 	{noreply, State};

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

terminate(Reason, State) ->
    ?LLOG(info, "stop: ~p", [Reason], State).



% ===================================================================
%% Internal
%% ===================================================================


% %% @private
% started_channel(CallId, ChPid, State) ->
% 	monitor(process, ChPid),
% 	#state{channels=Channels, pids=Pids} = State,
% 	State#state{
% 		channels = maps:put(CallId, ChPid, Channels),
% 		pids = maps:put(ChPid, CallId, Pids)
% 	}.


% %% @private
% send_update(Update, #state{callbacks=CallBacks}=State) ->
% 	do_send_update(CallBacks, Update, State).


% %% @private
% do_send_update([], _Update, State) ->
% 	State;

% do_send_update([CallBack|Rest], Update, #state{index=Index, status=Status}=State) ->
% 	Update2 = Update#{status=>Status, index=>Index},
% 	case nklib_util:apply(CallBack, nkmedia_fs_update, [self(), Update2]) of
% 		ok ->
% 			ok;
% 		Other ->
% 			?LLOG(warning, "Invalid response from callback: ~p", [Other], State)
% 	end,
% 	do_send_update(Rest, Update, State).
	

%% @private
update_status(Status, #state{status=Status}=State) ->
	State;

update_status(NewStatus, #state{name=Name, status=OldStatus, fs_conn=Pid}=State) ->
	nklib_proc:put({?MODULE, Name}, {NewStatus, Pid}),
	nklib_proc:put({?MODULE, self()}, {NewStatus, Pid}),
	?LLOG(info, "status ~p -> ~p", [OldStatus, NewStatus], State),
	State#state{status=NewStatus}.
	% send_update(#{}, State#state{status=NewStatus}).

parse_event(Name, _Data, State) ->
	lager:warning("Event: ~s", [Name]),
	State.


% %% @private
% parse_event(<<"HEARTBEAT">>, Data, State) ->
% 	#{
% 		<<"Event-Info">> := Info,
% 		<<"FreeSWITCH-Version">> := Vsn, 
% 		<<"Idle-CPU">> := Idle,
% 		<<"Max-Sessions">> := MaxSessions,
% 		<<"Session-Count">> := SessionCount,
% 		<<"Session-Peak-FiveMin">> := PeakFiveMins,
% 		<<"Session-Peak-Max">> := PeakMax,
% 		<<"Session-Per-Sec">> := PerSec,
% 		<<"Session-Per-Sec-FiveMin">> := PerSecFiveMins,
% 		<<"Session-Per-Sec-Max">> := PerSecMax,
% 		<<"Session-Since-Startup">> := AllSessions,
% 		<<"Uptime-msec">> := UpTime
% 	} = Data,
% 	Stats = #{
% 		idle => round(binary_to_float(Idle)),
% 		max_sessions => binary_to_integer(MaxSessions),
% 		session_count => binary_to_integer(SessionCount),
% 		session_peak_five_mins => binary_to_integer(PeakFiveMins),
% 		session_peak_max => binary_to_integer(PeakMax),
% 		sessions_sec => binary_to_integer(PerSec),
% 		sessions_sec_five_mins => binary_to_integer(PerSecFiveMins),
% 		sessions_sec_max => binary_to_integer(PerSecMax),
% 		all_sessions => binary_to_integer(AllSessions),
% 		uptime => binary_to_integer(UpTime) div 1000
% 	},
% 	case Info of
% 		<<"System Ready">> -> ok;
% 		_ -> ?LLOG(warning, "unknown HEARTBEAT info: ~s", [Info], State)
% 	end,
% 	Update = #{vsn => Vsn, stats => Stats},
% 	send_update(Update, State);

% parse_event(<<"NkMEDIA">>, _Data, State) ->
% 	% CallId = maps:get(<<"Unique-ID">>, Data),
% 	% ?LLOG(info, "Media EVENT: ~p", [Data], State),
% 	State;

% parse_event(<<"CHANNEL_CREATE">>, Data, State) ->
% 	#state{channels=Channels, callbacks=CallBacks} = State,
% 	CallId = maps:get(<<"Unique-ID">>, Data),
% 	case maps:find(CallId, Channels) of
% 		{ok, ChPid} ->
% 			nkmedia_fs_channel:ch_create(ChPid, Data),
% 			State;
% 		error ->
% 			case Data of
% 				#{<<"variable_nkstatus">> := <<"outbound">>} ->
% 					{ok, ChPid} = 
% 						nkmedia_fs_channel:start_link(self(), CallBacks, CallId, out),
% 					started_channel(CallId, ChPid, State);
% 				_ ->
% 					?LLOG(warning, "event CHANNEL_CREATE for unknown channel ~s", 
% 						  [CallId], State),
% 					State
% 			end
% 	end;

% parse_event(<<"CHANNEL_PARK">>, Data, #state{channels=Channels}=State) ->
% 	CallId = maps:get(<<"Unique-ID">>, Data),
% 	case maps:find(CallId, Channels) of
% 		{ok, ChPid} ->
% 			nkmedia_fs_channel:ch_park(ChPid);
% 		error ->
% 			?LLOG(warning, "event CHANNEL_PARK for unknown channel ~s", 
% 				  [CallId], State)
% 	end,
% 	State;

% parse_event(<<"CHANNEL_HANGUP">>, Data, #state{channels=Channels}=State) ->
% 	CallId = maps:get(<<"Unique-ID">>, Data),
% 	Reason = maps:get(<<"Hangup-Cause">>, Data, <<"Unknown">>),
% 	case maps:find(CallId, Channels) of
% 		{ok, ChPid} ->
% 			nkmedia_fs_channel:ch_hangup(ChPid, Reason);
% 		error ->
% 			?LLOG(warning, "event CHANNEL_HANGUP for unknown channel ~s", 
% 				  [CallId], State)
% 	end,
% 	State;

% parse_event(<<"CHANNEL_DESTROY">>, Data, #state{channels=Channels}=State) ->
% 	CallId = maps:get(<<"Unique-ID">>, Data),
% 	case maps:find(CallId, Channels) of
% 		{ok, ChPid} ->
% 			nkmedia_fs_channel:stop(ChPid);
% 		error ->
% 			?LLOG(info, "event CHANNEL_CREATE for unknown channel ~s", 
% 				  [CallId], State)
% 	end,
% 	State;

% parse_event(<<"CHANNEL_BRIDGE">>, Data, #state{channels=Channels}=State) ->
% 	CallIdA = maps:get(<<"Bridge-A-Unique-ID">>, Data),
% 	CallIdB = maps:get(<<"Bridge-B-Unique-ID">>, Data),
% 	case maps:find(CallIdA, Channels) of
% 		{ok, ChPidA} ->
% 			nkmedia_fs_channel:ch_join(ChPidA, CallIdB);
% 		error ->
% 			?LLOG(notice, "event CHANNEL_BRIDGE for unknown channel ~s", 
% 				  [CallIdA], State)
% 	end,
% 	case maps:find(CallIdB, Channels) of
% 		{ok, ChPidB} ->
% 			nkmedia_fs_channel:ch_join(ChPidB, CallIdA);
% 		error ->
% 			?LLOG(notice, "event CHANNEL_BRIDGE for unknown channel ~s", 
% 				  [CallIdB], State)
% 	end,
% 	State;

% parse_event(<<"CONFERENCE_DATA">>, Data, State) ->
% 	lager:info("CONF1: ~s", [nklib_json:encode_pretty(Data)]),
% 	State;

% parse_event(<<"conference::maintenance">>, Data, #state{channels=Channels}=State) ->
% 	case Data of
% 		#{<<"Action">> := <<"add-member">>} ->
% 			CallId = maps:get(<<"Unique-ID">>, Data),
% 			case maps:find(CallId, Channels) of
% 				{ok, ChPid} ->
% 					Room = maps:get(<<"Conference-Name">>, Data),
% 					nkmedia_fs_channel:ch_room(ChPid, Room);
% 				error ->
% 					?LLOG(warning, "event conf_add_member for unknown channel ~s", 
% 						  [CallId], State)
% 			end;
% 		_ ->
% 			ok
% 	end,
% 	nkmedia_fs_conference:fs_event(Data),
% 	State.




%% @private
connect_fs(_Host, _Pass, 0) ->
	error;
connect_fs(Host, Pass, Tries) ->
	Host2 = nklib_util:to_list(Host),
	case gen_tcp:connect(Host2, 8021, [{active, false}, binary], 5000) of
		{ok, Socket} ->
			Res = connect_fs(Socket, Pass),
			gen_tcp:close(Socket),
			Res;
		{error, _} ->
			lager:info("Waiting for FS at ~s to start (~p) ...", [Host, Tries]),
			timer:sleep(1000),
			connect_fs(Host2, Pass, Tries-1)
	end.


-define(CT_AUTH, <<"Content-Type: auth/request\n\n">>).
-define(CT_AUTH_ACCEPTED, <<"Content-Type: command/reply\nReply-Text: +OK accepted\n\n">>).

%% @private
connect_fs(Socket, Pass) ->
	case gen_tcp:recv(Socket, 0, 5000) of
		{ok, ?CT_AUTH} ->
			case gen_tcp:send(Socket, ["auth ", Pass, "\n\n"]) of
				ok ->
					case gen_tcp:recv(Socket, 0, 5000) of
						{ok, ?CT_AUTH_ACCEPTED} -> ok;
						_ -> error
					end;
				_ -> 
					error
			end;
		_ ->
			error
	end.






