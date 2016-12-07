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

%% @doc 
-module(nkmedia_fs_event_protocol).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/4]).
-export([api/2, api_block/2, event/3, msg/3, shutdown/1]).
-export([execute/3, execute/4, execute/5, execute/6]).
-export([t/1]).


-export([transports/1, default_port/1]).
-export([conn_init/1, conn_parse/3, conn_handle_call/4, conn_handle_cast/3, conn_handle_info/3]).


-define(CT_AUTH, <<"Content-Type: auth/request\n\n">>).
-define(CT_AUTH_ACCEPTED, <<"Content-Type: command/reply\nReply-Text: +OK accepted\n\n">>).
-define(CT_AUTH_EVENTS, <<"Content-Type: command/reply\nReply-Text: +OK event listener enabled json\n\n">>).
-define(IGNORE_FIELDS, [
	<<"Command">>, <<"Core-UUID">>,
	<<"Event-Calling-File">>, <<"Event-Calling-Function">>, 
	<<"Event-Calling-Line-Number">>, <<"Event-Date-GMT">>,
	<<"Event-Date-Local">>, <<"Event-Date-Timestamp">>, <<"Event-Name">>, 
	<<"Event-Sequence">>, <<"FreeSWITCH-Hostname">>, <<"FreeSWITCH-IPv4">>,
	<<"FreeSWITCH-IPv6">>, <<"FreeSWITCH-Switchname">>]).


-define(DEBUG(Txt, Args, State),
    case erlang:get(nkmedia_fs_event_protocol_debug) of
        true -> ?LLOG(debug, Txt, Args, State);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args, State),
	lager:Type("NkMEDIA FS Event "++Txt, Args)).



-include("nkmedia.hrl").


%% ===================================================================
%% Public
%% ===================================================================


%% @doc
-spec start(nkservice:id(), binary(), inet:port_number(), binary()) ->
	{ok, pid()} | {error, term()}.

start(SrvId, Host, Base, Pass) ->
	{ok, Ip} = nklib_util:to_ip(Host),
	Conn = {?MODULE, tcp, Ip, Base},
	Debug = case nkservice_util:get_debug_info(SrvId, ?MODULE) of
		{true, #{nkpacket:=true}} -> true;
		_ -> false
	end,
	ConnOpts = #{
		class => nkmedia_fs, 
		idle_timeout => 60000,
		monitor => self(),
		user => #{srv_id=>SrvId, password=>nklib_util:to_binary(Pass), notify=>self()},
		debug => Debug
	},
	nkpacket:connect(Conn, ConnOpts).


%% @doc
-spec api(pid(), iolist()) ->
	{ok, binary()} | {error, term()}.

api(Pid, Api) ->
	do_call(Pid, {cmd, ["bgapi ", Api], true}).


%% @doc
-spec api_block(pid(), iolist()) ->
	{ok, binary()} | {error, term()}.

api_block(Pid, Api) ->
	do_call(Pid, {cmd, ["api ", Api], false}).


%% @doc
-spec event(pid(), iolist(), [{iolist(), iolist()}]) ->
	{ok, binary()} | {error, term()}.

event(Pid, Name, Vars) ->
	Vars1 = [
		[
			nklib_util:to_binary(K), <<": ">>, 
			nklib_util:to_binary(V), <<"\n">>
		] 
		|| {K, V} <- Vars
	],
	do_call(Pid, {cmd, [<<"sendevent ">>, Name, <<"\n">>, Vars1], false}).


%% @private
execute(Pid, UUID, AppName) ->
	execute(Pid, UUID, AppName, undefined, undefined, false).


execute(Pid, UUID, AppName, AppArg) ->
	execute(Pid, UUID, AppName, AppArg, undefined, false).


execute(Pid, UUID, AppName, AppArg, Loops) ->
	execute(Pid, UUID, AppName, AppArg, Loops, false).


execute(Pid, UUID, AppName, AppArg, Loops, Lock) ->
	Vars = [
		{"call-command", "execute"}, 
		{"execute-app-name", AppName}
	] 
	++
	case AppArg of
		undefined -> []; 
		_ -> [{"execute-app-arg", AppArg}]
	end
	++
	case Loops of
		undefined -> [];
		_ -> [{"loops", Loops}]
	end
	++
	case Lock of
		true -> [{"event-lock", "true"}];
		_ -> []
	end,
	msg(Pid, UUID, Vars).


msg(Pid, Name, Vars) ->
	Vars1 = [
		[
			nklib_util:to_binary(K), <<": ">>, 
			nklib_util:to_binary(V), <<"\n">>
		] 
		|| {K, V} <- Vars
	],
	do_call(Pid, {cmd, [<<"sendmsg ">>, Name, <<"\n">>, Vars1], false}).


%% @doc
-spec shutdown(pid()) ->
	ok | {error, term()}.

shutdown(Pid) ->
	gen_server:call(Pid, shutdown, infinity).



%% ===================================================================
%% Protocol callbacks
%% ===================================================================



-record(cmd, {
    async :: boolean(),
    from :: {pid(), reference()}
}).


-record(job, {
    id :: nkworker:trans_id(),
    from :: {pid(), reference()}
}).


-record(state, {
	srv_id :: nkservice:id(),
    password :: binary(),
    notify :: pid(),
    authenticated :: boolean(),
    cmds = [] :: [#cmd{}],
    jobs = [] :: [#job{}],
	buff = <<>> :: binary(),
	last_event :: nklib_util:timestamp()
}).



%% @private
-spec transports(nklib:scheme()) ->
    [nkpacket:transport()].

transports(_) -> [tcp].

-spec default_port(nkpacket:transport()) ->
    inet:port_number() | invalid.

default_port(tcp) -> 50000.


-spec conn_init(nkpacket:nkport()) ->
	{ok, #state{}}.

conn_init(NkPort) ->
    {ok, _Class, User} = nkpacket:get_user(NkPort),
	#{srv_id:=SrvId, password:=Pass, notify:=Pid} = User,
	monitor(process, Pid),
    State = #state{
    	srv_id = SrvId,
        password = Pass,
        authenticated = false,
        notify = Pid
    },
    set_log(State),
	nkservice_util:register_for_changes(SrvId),
    ?DEBUG("started", [], State),
    {ok, State}.


%% @private
-spec conn_parse(term()|close, nkpacket:nkport(), #state{}) ->
	{ok, #state{}} | {stop, term(), #state{}}.

conn_parse(close, _NkPort, State) ->
	{ok, State};

conn_parse(?CT_AUTH, NkPort, #state{authenticated=false}=State) ->
	#state{password=Password} = State,
	ret_send(["auth ", Password], NkPort, State);

conn_parse(?CT_AUTH_ACCEPTED, NkPort, #state{authenticated=false}=State) ->
	ret_send(<<"events json all\n\n">>, NkPort, State);

conn_parse(?CT_AUTH_EVENTS, _NkPort, #state{authenticated=false}=State) ->
	% lager:info("NkMEDIA FS Event Protocol connected to freeswitch"),
	{ok, State#state{authenticated=true}};

conn_parse(Data, _NkPort, #state{}=State) ->
	case do_parse(Data, State) of
		{ok, State1} -> {ok, State1};
		{error, Error} -> {stop, Error, State}
	end.


%% @private
-spec conn_handle_call(term(), {pid(), term()}, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_handle_call({cmd, Cmd, Async}, From, NkPort, #state{cmds=Cmds}=State) ->
	Cmds1 =  Cmds ++ [#cmd{async=Async, from=From}],
	ret_send(Cmd, NkPort, State#state{cmds=Cmds1});

conn_handle_call(shutdown, From, NkPort, State) ->
	case do_send("api fsctl shutdown asap\n\n", NkPort) of
		ok ->
			gen_server:reply(From, ok);
		{error, Error} ->
			gen_server:reply(From, {error, Error})
	end,
	{stop, normal, State};

conn_handle_call(get_state, From, _NkPort, State) ->
	gen_server:reply(From, State),
	{ok, State};

conn_handle_call(Msg, _From, _NkPort, State) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {stop, unexpected_call, State}.


-spec conn_handle_cast(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_handle_cast(Msg, _NkPort, State) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {ok, State}.


%% @private
-spec conn_handle_info(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_handle_info({'DOWN', _Ref, process, Pid, _Reason}, _NkPort, #state{notify=Pid}=State) ->
	{stop, normal, State};

conn_handle_info({nkservice_updated, _SrvId}, _NkPort, State) ->
    {ok, set_log(State)};

conn_handle_info(Msg, _NkPort, State) ->
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
    {ok, State}.



%% ===================================================================
%% Util
%% ===================================================================


%% @private
set_log(#state{srv_id=SrvId}=State) ->
    Debug = case nkservice_util:get_debug_info(SrvId, ?MODULE) of
        {true, _} -> true;
        _ -> false
    end,
    put(nkmedia_fs_event_protocol_debug, Debug),
    State.

%% @private
do_call(Pid, Msg) ->
	nkservice_util:call(Pid, Msg, 5*60*1000).


%% @private
-spec ret_send(binary(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

ret_send(Msg, NkPort, State) ->
    case do_send(Msg, NkPort) of
        ok ->
            {ok, State};
        {error, closed} ->
            {stop, normal, State};
        {error, Error} ->
            lager:notice("Error sending FS command ~p: ~p", [Msg, Error]),
            {stop, {send_error, Error}, State}
    end.


%% @private
-spec do_send(binary(), nkpacket:nkport()) ->
    ok | {error, term()}.

do_send(Msg, NkPort) ->
    nkpacket_connection_lib:raw_send(NkPort, [Msg, <<"\n\n">>]).


%% @private
-spec do_parse(binary(), #state{}) ->
	{ok, #state{}} | {error, term()}.

do_parse(Data, #state{buff=Buff}=State) ->
	Data1 = <<Buff/binary, Data/binary>>,
	case binary:split(Data1, <<"\n\n">>) of
		[_] -> 
			{ok, State#state{buff=Data1}};
		[Head, Rest] ->
			case get_content_length(Head) of
				CL when is_integer(CL) ->
					case byte_size(Rest) of
						CL ->
							do_parse_msg(Head, Rest, <<>>, State#state{buff = <<>>});
						Size when Size < CL ->
							{ok, State#state{buff=Data1}};
						_ ->
							{Body, Rest1} = split_binary(Rest, CL),
							do_parse_msg(Head, Body, Rest1, State#state{buff = <<>>})
					end;
				error ->
					do_parse_msg(Head, <<>>, Rest, State#state{buff = <<>>})
			end
	end.



%% @private
-spec do_parse_msg(binary(), binary(), binary(), #state{}) ->
	{ok, #state{}} | {error, term()}.

do_parse_msg(Head, Body, Rest, State) ->
	case get_content_type(Head) of
		<<"command/reply">> -> 
			ReplyText = get_reply_text(Head),
			do_parse_reply(ReplyText, Rest, State);
		<<"api/response">> -> 
			do_parse_reply(Body, Rest, State);
		<<"text/event-json">> -> 
			case nklib_json:decode(Body) of
				#{<<"Event-Name">>:=Name} = Event ->
					do_parse_event(Name, Event, Rest, State);
				_ ->
					lager:error("Error decoding JSON ~p", [Body]),
					{error, decode_error}
			end;
		<<"text/disconnect-notice">> ->
			{ok, State};
		error ->
			lager:error("Unknown response in FS: ~p, ~p", [Head, Body]),
			do_parse(Rest, State)
	end.


%% @private
-spec do_parse_reply(binary(), binary(), #state{}) ->
	{ok, #state{}} | {error, term()}.

do_parse_reply(<<"+OK Job-UUID: ", Job/binary>>, Rest,
			   #state{cmds=[#cmd{async=true, from=From}|RestCmds], jobs=Jobs}=State) ->
	Jobs1 = [#job{id=Job, from=From}|Jobs],
	do_parse(Rest, State#state{cmds=RestCmds, jobs=Jobs1});

do_parse_reply(Msg, Rest, #state{cmds=[#cmd{async=false, from=From}|RestCmds]}=State) ->
	gen_server:reply(From, {ok, Msg}),
	do_parse(Rest, State#state{cmds=RestCmds}).


%% @private
-spec do_parse_event(binary(), map(), binary(), #state{}) ->
	{ok, #state{}} | {error, term()}.

do_parse_event(Ignore, _, Rest, State)
		when Ignore == <<"RE_SCHEDULE">>; Ignore == <<"API">> ->
	do_parse(Rest, State);

do_parse_event(<<"BACKGROUND_JOB">>, Event, Rest, #state{jobs=Jobs}=State) ->
	#{<<"Job-UUID">>:=UUID, <<"_body">>:=Data} = Event,
	case lists:keytake(UUID, #job.id, Jobs) of
		{value, #job{from=From}, Jobs1} ->
			gen_server:reply(From, {ok, Data}),
			do_parse(Rest, State#state{jobs=Jobs1});
		false ->
			lager:warning("FS: Unknown background job"),
			do_parse(Rest, State)
	end;

do_parse_event(Name, Event, Rest, #state{notify=Notify}=State) ->
	case is_pid(Notify) of
		true ->
			Event1 = maps:without(?IGNORE_FIELDS, Event),
			Notify ! {nkmedia_fs_event, self(), Name, Event1};
		false ->
			lager:notice("EVENT: ~s", [Name])
	end,
	do_parse(Rest, State).


%% @private
get_content_length(Bin) ->
	case binary:split(Bin, <<"Content-Length: ">>) of
		[_] ->
			error;
		[_, CL1] ->
			case binary:split(CL1, <<"\n">>) of
				[CL2] -> binary_to_integer(CL2);
				[CL2, _] -> binary_to_integer(CL2)
			end
	end. 


%% @private
get_content_type(Bin) ->
	case binary:split(Bin, <<"Content-Type: ">>) of
		[_] ->
			error;
		[_, CT1] ->
			case binary:split(CT1, <<"\n">>) of
				[CT2] -> CT2;
				[CT2, _] -> CT2
			end
	end. 

get_reply_text(Bin) ->
	case binary:split(Bin, <<"Reply-Text: ">>) of
		[_] ->
			<<>>;
		[_, RT1] ->
			case binary:split(RT1, <<"\n">>) of
				[RT2] -> RT2;
				[RT2, _] -> RT2
			end
	end. 



%%% TEST

t(P) ->
	Start = os:timestamp(),
	{ok, R} = api(P, "show interfaces"),
	t(1000, P, R),
	timer:now_diff(os:timestamp(), Start) / 1000.

t(0, _, _) ->
	ok;
t(N, P, R) ->
	proc_lib:spawn_link(fun() -> {ok, R} = api(P, "show interfaces") end),
	t(N-1, P, R).





