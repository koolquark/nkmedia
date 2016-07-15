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
-export([call_hangup/3, nkmedia_api_call_hangup/2, call_invite/4, call_cancel/3]).
-export([syntax/5]).


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
	#{type:=Type} = Data,
	Ring = maps:get(ring_time, Data, ?DEF_RING_TIMEOUT),
	case Type of
		user ->
			case maps:find(user, Data) of
				{ok, User} ->
					Dests = [
						#{dest=>{nkmedia_api, {user, User, Pid}}, ring=>Ring} 
						|| {_, Pid} <- nkservice_api_server:find_user(User)
					],
					start_call(SrvId, {user, User}, Dests, Data, State);
				error ->
					{error, {missing_field, <<"user">>}, State}
			end;
		_ ->
			{error, {syntax_error, <<"type">>}, State}
	end;

cmd(<<"call">>, <<"ringing">>, #api_req{data=Data}, State) ->
	#{call_id:=CallId} = Data,
	Calls = get_calls(State),
	case lists:keyfind(CallId, 1, Calls) of
		{CallId, Type, _Mon} ->
			Id = case Type of
				{user, User} -> {nkmedia_api, {user, User, self()}}
			end,
			case nkmedia_call:ringing(CallId, Id) of
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
		false ->
			{error, call_not_found, State}
	end;

cmd(<<"call">>, <<"answered">>, #api_req{data=Data}, State) ->
	#{call_id:=CallId} = Data,
	Calls = get_calls(State),
	case lists:keyfind(CallId, 1, Calls) of
		{CallId, Type, _Mon} ->
			Id = case Type of
				{user, User} -> {nkmedia_api, {user, User, self()}}
			end,
			Answer = maps:get(answer, Data, #{}),
			case nkmedia_call:answered(CallId, Id, Answer) of
				ok ->
					{ok, #{}, State};
				{error, invite_not_found} ->
					{error, already_answered, State};
				{error, call_not_found} ->
					{error, call_not_found, State};
				{error, Error} ->
					lager:warning("Error in call answered: ~p", [Error]),
					{error, call_error, State}
			end;
		false ->
			{error, call_not_found, State}
	end;

cmd(<<"call">>, <<"rejected">>, #api_req{data=Data}, State) ->
	#{call_id:=CallId} = Data,
	Calls = get_calls(State),
	case lists:keyfind(CallId, 1, Calls) of
		{CallId, Type, _Mon} ->
			Id = case Type of
				{user, User} -> {nkmedia_api, {user, User, self()}}
			end,
			case nkmedia_call:rejected(CallId, Id) of
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
		false ->
			{error, call_not_found, State}
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


% %% @doc Called when api server must forward an event to the client
% %% Captures session and call stop event
% forward_event(RegId, _Body, State) ->
% 	case RegId of
% 		#reg_id{
% 			class = <<"media">>, 
% 			subclass = <<"session">>, 
% 		    type = <<"stop">>, 
% 		    obj_id = SessId
% 		} ->
% 			Sessions = get_sessions(State),
% 			case lists:keytake(SessId, 1, Sessions) of
% 				{value, {SessId, Mon}, Sessions2} -> demonitor(Mon, [flush]);
% 				false -> Sessions2 = Sessions
% 			end,
% 			{ok, set_sessions(Sessions2, State)};
% 		_ ->
% 			{ok, State}
% 	end.


%% @doc Called when a registered session or call goes down
handle_down(SrvId, Mon, Reason, State) ->
	Sessions = get_sessions(State),
	case lists:keytake(Mon, 2, Sessions) of
		{value, {SessId, Mon}, Sessions2} ->
			lager:warning("Session ~s is down: ~p", [SessId, Reason]),
			RegId = nkmedia_util:session_reg_id(SrvId, stop, SessId),
			{Code, Txt} = SrvId:error_code(process_down),
			Body = #{code=>Code, reason=>Txt},
			nkservice_api_server:send_event(self(), RegId, Body),
			{ok, set_sessions(Sessions2, State)};
		false ->
			Calls = get_calls(State),
			case lists:keytake(Mon, 3, Calls) of
				{value, {CallId, _Type, Mon}, Calls2} ->
					lager:warning("Call ~s is down: ~p", [CallId, Reason]),
					RegId = nkmedia_util:call_reg_id(SrvId, stop, CallId),
					{Code, Txt} = SrvId:error_code(process_down),
					Body = #{code=>Code, reason=>Txt},
					nkservice_api_server:send_event(self(), RegId, Body),
					{ok, set_calls(Calls2, State)};
				_ ->
					continue
			end
	end.


%% @private Called from nkmedia_session_reg_event
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


%% @private Called from nkmedia_call_reg_event
call_hangup(Pid, CallId, _Reason) ->
	gen_server:cast(Pid, {nkmedia_api_call_hangup, CallId}).


%% @private  
nkmedia_api_call_hangup(CallId, State) ->
	Sessions = get_calls(State),
	case lists:keytake(CallId, 1, Sessions) of
		{value, {CallId, _Type, Mon}, Sessions2} -> demonitor(Mon, [flush]);
		false -> Sessions2 = Sessions
	end,
	{ok, set_calls(Sessions2, State)}.


%% @private
call_invite(CallId, Offer, {user, User, Pid}, Call) ->
	Data = #{call_id=>CallId, offer=>Offer, type=>user},
	case nkservice_api_server:cmd(Pid, media, call, invite, Data) of
		{ok, <<"ok">>, #{<<"retry">>:=Retry}} ->
			case is_integer(Retry) andalso Retry>0 of
				true -> {retry, Retry, Call};
				false -> {remove, Call}
			end;
		{ok, <<"ok">>, _} ->
			{ok, {nkmedia_api, {user, User, Pid}}, Call};
		{ok, <<"error">>, _} ->
			{remove, Call};
		{error, _Error} ->
			{remove, Call}
	end.

%% @private
call_cancel(CallId, {user, _User, Pid}, Call) ->
	{Code, Txt} = nkmedia_util:error(originator_cancel),
	nkservice_api_server:cmd_async(Pid, media, call, hangup, 
								   #{call_id=>CallId, code=>Code, reason=>Txt}),
	{ok, Call}.


%% ===================================================================
%% Syntax
%% ===================================================================

%% @private
syntax(<<"session">>, <<"start">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			type => atom,							%% p2p, proxy...
			offer => offer(),
			answer => answer(),
			subscribe => boolean,
			events_body => any,
			wait_timeout => {integer, 1, none},
			ready_timeout => {integer, 1, none},
			backend => atom							%% nkmedia_janus, etc.
		},
		Defaults,
		[type|Mandatory]
	};

syntax(<<"session">>, <<"stop">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			session_id => binary,
			code => integer,
			reason => binary
		},
		Defaults,
		[session_id|Mandatory]
	};

syntax(<<"session">>, <<"set_answer">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			session_id => binary,
			answer => answer()
		},
		Defaults,
		[session_id, answer|Mandatory]
	};

syntax(<<"session">>, <<"update">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			session_id => binary,
			type => atom
		},
		Defaults,
		[session_id, type|Mandatory]
	};

syntax(<<"call">>, <<"start">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			type => atom,
			offer => offer(),
			ring_time => {integer, 1, none},
			user => binary,
			session => binary,
			url => binary
		},
		Defaults,
		[type|Mandatory]
	};

syntax(<<"call">>, <<"ringing">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{call_id => binary},
		Defaults,
		[call_id|Mandatory]
	};


syntax(<<"call">>, <<"answered">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			call_id => binary,
			answer => answer()
		},
		Defaults,
		[call_id|Mandatory]
	};

syntax(<<"call">>, <<"rejected">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{call_id => binary},
		Defaults,
		[call_id|Mandatory]
	};

syntax(<<"call">>, <<"hangup">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			call_id => binary,
			reason => binary
		},
		Defaults,
		[call_id|Mandatory]
	};

syntax(_Sub, _Cmd, Syntax, Defaults, Mandatory) ->
	{Syntax, Defaults, Mandatory}.



%% @private
offer() ->
	#{
		sdp => binary,
		sdp_type => {enum, [rtp, webrtc]},
		dest => binary,
        caller_name => binary,
        caller_id => binary,
        callee_name => binary,
        callee_id => binary,
        use_audio => boolean,
        use_stereo => boolean,
        use_video => boolean,
        use_screen => boolean,
        use_data => boolean,
        in_bw => {integer, 0, none}, 
        out_bw => {integer, 0, none}
     }.


%% @private
answer() ->
	#{
		sdp => binary,
		sdp_type => {enum, [rtp, webrtc]},
        use_audio => boolean,
        use_stereo => boolean,
        use_video => boolean,
        use_screen => boolean,
        use_data => boolean
     }.




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
					RegId = nkmedia_util:session_reg_id(SrvId, <<"*">>, SessId),
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
%% The client must be susbcribed to events (ringing, answred, hangup)
%% We implement call_invite and call_cancel and called above
%% If it stops, we capture the DOWN event above
%% If it sends a hangup, we also capture it in nkmedia_call_reg_event and 
%% call_hangup/3 is called

start_call(SrvId, Type, Dests, Data, State) ->
	Config1 = #{register => {nkmedia_api, self()}},
	Config2 = case maps:find(offer, Data) of
		{ok, Offer} -> Config1#{offer=>Offer};
		error -> Config1
	end,
	{ok, CallId, CallPid} = nkmedia_call:start(SrvId, Dests, Config2),
	case maps:get(subscribe, Data, true) of
		true ->
			% In case of no_destination, the call will wait 100msecs before stop
			RegId = nkmedia_util:call_reg_id(SrvId, <<"*">>, CallId),
			Body = maps:get(events_body, Data, #{}),
			nkservice_api_server:register(self(), RegId, Body);
		false ->
			ok
	end,
	Mon = monitor(process, CallPid),
	Calls = get_calls(State),
	Calls2 = [{CallId, Type, Mon}|Calls],
	{ok, #{call_id=>CallId}, set_calls(Calls2, State)}.


%% @private
get_calls(State) ->
    Data = maps:get(?MODULE, State, #{}),
    maps:get(calls, Data, []).


%% @private
set_calls(Regs, State) ->
    Data1 = maps:get(?MODULE, State, #{}),
    Data2 = Data1#{calls=>Regs},
    State#{?MODULE=>Data2}.

