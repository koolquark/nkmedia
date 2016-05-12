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
-export([stats/2, get_config/1, api/2]).
-export([get_all/0, stop_all/0]).
-export([start_link/1, init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, config/0]).

-define(CONNECT_RETRY, 5000).

-define(LLOG(Type, Txt, Args, State),
	lager:Type("NkMEDIA FS Engine '~s' "++Txt, [State#state.name|Args])).

-define(CALL_TIME, 30000).

-define(EVENT_PROCESS, [
	<<"NkMEDIA">>, <<"HEARTBEAT">>,
	<<"CHANNEL_PARK">>, <<"CHANNEL_DESTROY">>, 
	<<"CHANNEL_BRIDGE">>, <<"CHANNEL_HANGUP">>, <<"SHUTDOWN">>,
	<<"conference::maintenance">>
]).
	
-define(EVENT_IGNORE,	[
	<<"verto::client_connect">>, <<"verto::client_disconnect">>, <<"verto::login">>, 
	<<"CHANNEL_CREATE">>,
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

-type id() :: Name:: binary() | pid().

-type config() ::
	#{
		name => binary(),
		rel => binary(),
		host => binary(),
		pass => binary()
	}.



%% ===================================================================
%% Public functions
%% ===================================================================

%% @private
-spec connect(config()) ->
	{ok, pid()} | {error, term()}.

connect(#{name:=Name, rel:=Rel, host:=Host, base:=Base, pass:=Pass}=Config) ->
	case find(Name) of
		not_found ->
			case connect_fs(Host, Base, Pass, 10) of
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
stats(Id, Stats) ->
	case find(Id) of
		{ok, _Status, FsPid, _ConnPid} -> gen_server:cast(FsPid, {stats, Stats});
		not_found -> ok
	end.


%% @private
-spec get_config(id()) ->
	{ok, config()} | {error, term()}.

get_config(Id) ->
	case find(Id) of
		{ok, _Status, FsPid, _ConnPid} ->
			nklib_util:call(FsPid, get_config, ?CALL_TIME);
		not_found ->
			{error, no_connection}
	end.


%% @priavte
-spec api(id(), iolist()) ->
	{ok, binary()} | {error, term()}.

api(Id, Api) ->
	case find(Id) of
		{ok, ready, _FsPid, ConnPid} when is_pid(ConnPid) ->
			nkmedia_fs_event_protocol:api(ConnPid, Api);
		{ok, _, _, _} ->
			{error, not_ready};
		not_found ->
			{error, no_connection}
	end.



%% @doc
-spec get_all() ->
	[{Name::binary(), pid()}].

get_all() ->
	nklib_proc:values(?MODULE).


%% @private
find(Id) ->
	Id2 = case is_pid(Id) of
		true -> Id;
		false -> nklib_util:to_binary(Id)
	end,
	case nklib_proc:values({?MODULE, Id2}) of
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

handle_info(connect, #state{config=#{host:=Host, base:=Base, pass:=Pass}}=State) ->
	State2 = update_status(connecting, State#state{fs_conn=undefined}),
	case nkmedia_fs_event_protocol:start(Host, Base, Pass) of
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
			parse_event(Name2, Event, State),
			{noreply, State};
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


%% @private
update_status(Status, #state{status=Status}=State) ->
	State;

update_status(NewStatus, #state{name=Name, status=OldStatus, fs_conn=Pid}=State) ->
	nklib_proc:put({?MODULE, Name}, {NewStatus, Pid}),
	nklib_proc:put({?MODULE, self()}, {NewStatus, Pid}),
	?LLOG(info, "status ~p -> ~p", [OldStatus, NewStatus], State),
	State#state{status=NewStatus}.
	% send_update(#{}, State#state{status=NewStatus}).


%% @private
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
% 	Update = #{vsn => Vsn, stats => _Stats},
% 	State;

%% @private
parse_event(<<"NkMEDIA">>, #{<<"Unique-ID">>:=_CallId}, State) ->
    ?LLOG(info, "event 'NkMEDIA'", [], State);
    
parse_event(<<"CHANNEL_PARK">>, #{<<"Unique-ID">>:=CallId}, State) ->
	send_event(CallId, parked, State);

parse_event(<<"CHANNEL_HANGUP">>, #{<<"Unique-ID">>:=CallId}, State) ->
	send_event(CallId, stop, State);

parse_event(<<"CHANNEL_DESTROY">>, #{<<"Unique-ID">>:=CallId}, State) ->
	send_event(CallId, stop, State);

parse_event(<<"CHANNEL_BRIDGE">>, Data, State) ->
    CallIdA = maps:get(<<"Bridge-A-Unique-ID">>, Data),
    CallIdB = maps:get(<<"Bridge-B-Unique-ID">>, Data),
    send_event(CallIdA, {bridge, CallIdB}, State),
	send_event(CallIdB, {bridge, CallIdB}, State);

parse_event(<<"CONFERENCE_DATA">>, Data, State) ->
    ?LLOG(notice, "CONF DATA: ~s", [nklib_json:encode_pretty(Data)], State);

parse_event(<<"conference::maintenance">>, Data, State) ->
    case Data of
        #{
        	<<"Action">> := <<"add-member">>,
            <<"Unique-ID">> := CallId,
            <<"Member-ID">> := MemberId,
            <<"Conference-Name">> := ConfName
        } ->
        	Conf = #{
        		room_name => ConfName,
        		room_member_id => MemberId
        	},
        	send_event(CallId, {mcu, Conf}, State);
        _ ->
            ok
    end;

parse_event(Name, _Data, State) ->
    ?LLOG(warning, "unexpected event: ~s", [Name], State).


%% @private
send_event(ChId, Status, #state{name=FsId}) ->
    nkmedia_session:ms_event(ChId, {freeswitch, FsId}, Status).


%% @private
connect_fs(_Host, _Base, _Pass, 0) ->
	error;
connect_fs(Host, Base, Pass, Tries) ->
	Host2 = nklib_util:to_list(Host),
	case gen_tcp:connect(Host2, Base, [{active, false}, binary], 5000) of
		{ok, Socket} ->
			Res = connect_fs(Socket, Pass),
			gen_tcp:close(Socket),
			Res;
		{error, _} ->
			lager:info("Waiting for FS at ~s to start (~p) ...", [Host, Tries]),
			timer:sleep(1000),
			connect_fs(Host2, Base, Pass, Tries-1)
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






