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

%% @doc NkMEDIA external API

-module(nkmedia_api).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([cmd/4, handle_down/4]).
-export([session_stop/2, nkmedia_api_session_stop/2]).
-export([call_resolve/3, call_invite/4, call_cancel/3, 
		 call_hangup/3, nkmedia_api_call_hangup/2]).


-include_lib("nkservice/include/nkservice.hrl").
-include("nkmedia.hrl").


%% ===================================================================
%% Types
%% ===================================================================


%% ===================================================================
%% Commands
%% ===================================================================

%% @doc
-spec cmd(nkservice:id(), atom(), Data::map(), map()) ->
	{ok, map(), State::map()} | {error, nkservice:error(), State::map()}.


%% Starts a new session
%% Registers self() with the session (to be monitorized)
%% Subscribes the caller to session events
%% Monitorizes the session and stores info on State
cmd(<<"session">>, <<"start">>, #api_req{srv_id=SrvId, data=Data}, State) ->
	start_session(SrvId, Data, State);

cmd(<<"session">>, <<"stop">>, #api_req{data=Data}, State) ->
	#{session_id:=SessId} = Data,
	nkmedia_session:stop(SessId),
	{ok, #{}, State};

cmd(<<"session">>, <<"set_answer">>, #api_req{data=Data}, State) ->
	#{answer:=Answer, session_id:=SessId} = Data,
	case nkmedia_session:answer(SessId, Answer) of
		{ok, Reply} ->
			{ok, Reply, State};
		{error, Error} ->
			{error, Error, State}
	end;

cmd(<<"session">>, <<"update">>, #api_req{data=Data}, State) ->
	#{session_id:=SessId, type:=Type} = Data,
	case nkmedia_session:update(SessId, Type, Data) of
		{ok, _} ->
			{ok, #{}, State};
		{error, Error} ->
			{error, Error, State}
	end;

cmd(<<"call">>, <<"start">>, #api_req{srv_id=SrvId, data=Data}, State) ->
	#{callee:=Callee} = Data,
	start_call(SrvId, Callee, Data, State);

cmd(<<"call">>, <<"ringing">>, #api_req{data=Data}, State) ->
	#{call_id:=CallId} = Data,
	case nkmedia_call:ringing(CallId, {nkmedia_api, self()}) of
		ok ->
			{ok, #{}, State};
		{error, invite_not_found} ->
			{error, already_answered, State};
		{error, call_not_found} ->
			{error, call_not_found, State};
		{error, Error} ->
			lager:warning("Error in call ringing: ~p", [Error]),
			{error, call_error, State}
	end;

cmd(<<"call">>, <<"answered">>, #api_req{srv_id=SrvId, data=Data}, State) ->
	#{call_id:=CallId} = Data,
	Answer = maps:get(answer, Data, #{}),
	case nkmedia_call:answered(CallId, {nkmedia_api, self()}, Answer) of
		ok ->
			update_call(SrvId, CallId, Data, State);
		{error, invite_not_found} ->
			{error, already_answered, State};
		{error, call_not_found} ->
			{error, call_not_found, State};
		{error, Error} ->
			lager:warning("Error in call answered: ~p", [Error]),
			{error, call_error, State}
	end;

cmd(<<"call">>, <<"rejected">>, #api_req{data=Data}, State) ->
	#{call_id:=CallId} = Data,
	case nkmedia_call:rejected(CallId, {nkmedia_api, self()}) of
		ok ->
			{ok, #{}, State};
		{error, invite_not_found} ->
			{ok, #{}, State};
		{error, call_not_found} ->
			{error, call_not_found, State};
		{error, Error} ->
			lager:warning("Error in call answered: ~p", [Error]),
			{error, call_error, State}
	end;

cmd(<<"call">>, <<"hangup">>, #api_req{data=Data}, State) ->
	#{call_id:=CallId} = Data,
	Reason = maps:get(reason, Data, <<"user_hangup">>),
	case nkmedia_call:hangup(CallId, Reason) of
		ok ->
			{ok, #{}, State};
		{error, call_not_found} ->
			{error, call_not_found, State};
		{error, Error} ->
			lager:warning("Error in call answered: ~p", [Error]),
			{error, call_error, State}
	end;

cmd(_SrvId, _Other, _Data, State) ->
	{error, unknown_command, State}.


%% @doc Called when a registered session or call goes down
handle_down(SrvId, Mon, Reason, State) ->
	Sessions = get_sessions(State),
	case lists:keytake(Mon, 2, Sessions) of
		{value, {SessId, Mon}, Sessions2} ->
			lager:warning("Session ~s is down: ~p", [SessId, Reason]),
			RegId = session_reg_id(SrvId, stop, SessId),
			{Code, Txt} = SrvId:error_code(process_down),
			Body = #{code=>Code, reason=>Txt},
			nkservice_api_server:send_event(self(), RegId, Body),
			{ok, set_sessions(Sessions2, State)};
		false ->
			Calls = get_calls(State),
			case lists:keytake(Mon, 2, Calls) of
				{value, {CallId, Mon}, Calls2} ->
					lager:warning("Call ~s is down: ~p", [CallId, Reason]),
					RegId = call_reg_id(SrvId, stop, CallId),
					{Code, Txt} = SrvId:error_code(process_down),
					Body = #{code=>Code, reason=>Txt},
					nkservice_api_server:send_event(self(), RegId, Body),
					{ok, set_calls(Calls2, State)};
				_ ->
					continue
			end
	end.


%% @private Called from nkmedia_session_reg_event when a session 
%% registered with {nkmedia_api, Pid} stops. Calls next function.
session_stop(Pid, SessId) ->
	gen_server:cast(Pid, {nkmedia_api_session_stop, SessId}).


%% @private  
nkmedia_api_session_stop(SessId, State) ->
	Sessions = get_sessions(State),
	case lists:keytake(SessId, 1, Sessions) of
		{value, {SessId, Mon}, Sessions2} -> demonitor(Mon, [flush]);
		false -> Sessions2 = Sessions
	end,
	{ok, set_sessions(Sessions2, State)}.


%% @private Called when a new call is searching for destinations
call_resolve(Dest, Acc, Call) ->
	Acc2 = case maps:get(type, Call, user) of
		user ->
			Acc ++ [
				#{dest=>{nkmedia_api, {user, Pid}}} 
				|| {_, Pid} <- nkservice_api_server:find_user(Dest)
			];
		_ ->
			Acc
	end,
	Acc3 = case maps:get(type, Call, session) of
		session ->
			Acc2 ++ case nkservice_api_server:find_session(Dest) of
				{ok, _User, Pid} ->
					[#{dest=>{nkmedia_api, {session, Pid}}}];
				_ ->
					[]
			end;
		_ ->
			Acc2
	end,
	{ok, Acc3, Call}.


%% @private Called from nkmedia_callback when a call invites a destination
%% with the type {nkmedia_api, {user|session, Pid}}
%% Registers this callee as {nkmedia_api, Pid}
call_invite(CallId, Offer, {Type, Pid}, Call) ->
	Data = #{call_id=>CallId, offer=>Offer, type=>Type},
	case nkservice_api_server:cmd(Pid, media, call, invite, Data) of
		{ok, <<"ok">>, #{<<"retry">>:=Retry}} ->
			case is_integer(Retry) andalso Retry>0 of
				true -> {retry, Retry, Call};
				false -> {remove, Call}
			end;
		{ok, <<"ok">>, _} ->
			% The proc_id is {nkmedia_api, Pid}
			{ok, {nkmedia_api, Pid}, Call};
		{ok, <<"error">>, _} ->
			{remove, Call};
		{error, _Error} ->
			{remove, Call}
	end.


%% @private Called from nkmedia_callback when a call cancels the callee
%% {nkmedia_api, Pid}
call_cancel(CallId, Pid, Call) ->
	{Code, Txt} = nkmedia_util:error(originator_cancel),
	nkservice_api_server:cmd_async(Pid, media, call, hangup, 
								   #{call_id=>CallId, code=>Code, reason=>Txt}),
	{ok, Call}.



%% @private Called from nkmedia_call_reg_event when a call registered
%% with {nkmedia_api, Pid} stops. Calls next functions.
call_hangup(Pid, CallId, _Reason) ->
	gen_server:cast(Pid, {nkmedia_api_call_hangup, CallId}).


%% @private  
nkmedia_api_call_hangup(CallId, State) ->
	Sessions = get_calls(State),
	case lists:keytake(CallId, 1, Sessions) of
		{value, {CallId, Mon}, Sessions2} -> demonitor(Mon, [flush]);
		false -> Sessions2 = Sessions
	end,
	{ok, set_calls(Sessions2, State)}.



%% ===================================================================
%% Internal
%% ===================================================================

%% Monitorizes the session and stores info on State
start_session(SrvId, Data, State) ->
	#{type:=Type} = Data,
	Config = Data#{register => {nkmedia_api, self()}},
	case nkmedia_session:start(SrvId, Type, Config) of
		{ok, SessId, Pid, Reply} ->
			case maps:get(subscribe, Data, true) of
				true ->
					RegId = session_reg_id(SrvId, <<"*">>, SessId),
					Body = maps:get(events_body, Data, #{}),
					nkservice_api_server:register(self(), RegId, Body);
				false ->
					ok
			end,
			Mon = monitor(process, Pid),
			Sessions = get_sessions(State),
			Sessions2 = [{SessId, Mon}|Sessions],
			{ok, Reply#{session_id=>SessId}, set_sessions(Sessions2, State)};
		{error, Error} ->
			{error, Error, State}
	end.


%% @private
get_sessions(State) ->
    Data = maps:get(?MODULE, State, #{}),
    maps:get(sessions, Data, []).


%% @private
set_sessions(Regs, State) ->
    Data1 = maps:get(?MODULE, State, #{}),
    Data2 = Data1#{sessions=>Regs},
    State#{?MODULE=>Data2}.


%% @private
%% We start the call
%% The client must be susbcribed to events (ringing, answered, hangup)
%% We implement call_invite and call_cancel and called above
%% If it stops, we capture the DOWN event above
%% If it sends a hangup, we also capture it in nkmedia_call_reg_event and 
%% call_hangup/3 is called
start_call(SrvId, Callee, Data, State) ->
	Config = Data#{register => {nkmedia_api, self()}},
	{ok, CallId, CallPid} = nkmedia_call:start(SrvId, Callee, Config),
	case maps:get(subscribe, Data, true) of
		true ->
			% In case of no_destination, the call will wait 100msecs before stop
			RegId = call_reg_id(SrvId, <<"*">>, CallId),
			Body = maps:get(events_body, Data, #{}),
			nkservice_api_server:register(self(), RegId, Body);
		false ->
			ok
	end,
	Mon = monitor(process, CallPid),
	Calls1 = get_calls(State),
	Calls2 = [{CallId, Mon}|Calls1],
	{ok, #{call_id=>CallId}, set_calls(Calls2, State)}.


%% @private
%% We have a B leg to the call
%% We monitor the call, and also capture hangup
update_call(SrvId, CallId, Data, State) ->
	{ok, CallPid} = nkmedia_call:register(CallId, {nkmedia_api, self()}),
	Mon = monitor(process, CallPid),
	Calls1 = get_calls(State),
	Calls2 = [{CallId, Mon}|Calls1],
	case maps:get(subscribe, Data, true) of
		true ->
			RegId = call_reg_id(SrvId, <<"*">>, CallId),
			Body = maps:get(events_body, Data, #{}),
			nkservice_api_server:register(self(), RegId, Body);
		false -> 
			ok
	end,
	{ok, #{}, set_calls(Calls2, State)}.


%% @private
get_calls(State) ->
    Data = maps:get(?MODULE, State, #{}),
    maps:get(calls, Data, []).


%% @private
set_calls(Regs, State) ->
    Data1 = maps:get(?MODULE, State, #{}),
    Data2 = Data1#{calls=>Regs},
    State#{?MODULE=>Data2}.



%% @private
session_reg_id(SrvId, Type, SessId) ->
	#reg_id{
		srv_id = SrvId, 	
		class = <<"media">>, 
		subclass = <<"session">>,
		type = nklib_util:to_binary(Type),
		obj_id = SessId
	}.


%% @private
call_reg_id(SrvId, Type, SessId) ->
	#reg_id{
		srv_id = SrvId, 	
		class = <<"media">>, 
		subclass = <<"call">>,
		type = nklib_util:to_binary(Type),
		obj_id = SessId
	}.

