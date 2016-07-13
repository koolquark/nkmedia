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
-export([cmd/4, forward_event/3, handle_down/4]).
-export([syntax/5]).

-include_lib("nkservice/include/nkservice.hrl").

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
	#{type:=Type} = Data,
	Config = Data#{register => {nkmedia_api, self()}},
	case nkmedia_session:start(SrvId, Type, Config) of
		{ok, SessId, Pid, Reply} ->
			case maps:get(subscribe, Data, true) of
				true ->
					RegId = nkmedia_util:session_reg_id(SrvId, <<"*">>, SessId),
					nkservice_api_server:register(self(), RegId, #{});
				false ->
					ok
			end,
			Mon = monitor(process, Pid),
			Sessions = get_sessions(State),
			Sessions2 = [{SessId, Mon}|Sessions],
			{ok, Reply#{session_id=>SessId}, set_sessions(Sessions2, State)};
		{error, Error} ->
			{error, Error, State}
	end;

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
	#{session_id:=SessId, update:=Update} = Data,
	case nkmedia_session:update(SessId, Update, Data) of
		{ok, _} ->
			{ok, #{}, State};
		{error, Error} ->
			{error, Error, State}
	end;

cmd(_SrvId, _Other, _Data, State) ->
	{error, unknown_command, State}.


%% @doc Called when api server must forward an event to the client
%% Captures session stop event
forward_event(RegId, _Body, State) ->
	case RegId of
		#reg_id{
			class = <<"media">>, 
			subclass = <<"session">>, 
		    type = <<"stop">>, 
		    obj_id = SessId
		} ->
			Sessions = get_sessions(State),
			case lists:keytake(SessId, 1, Sessions) of
				{value, {SessId, Mon}, Sessions2} -> demonitor(Mon, [flush]);
				false -> Sessions2 = Sessions
			end,
			{ok, set_sessions(Sessions2, State)};
		_ ->
			{ok, State}
	end.


%% @doc Called when api servers receives a DOWN
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
			continue
	end.



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
			update => atom
		},
		Defaults,
		[session_id, update|Mandatory]
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



%% @private
get_sessions(State) ->
    Data = maps:get(?MODULE, State, #{}),
    maps:get(sessions, Data, []).


%% @private
set_sessions(Regs, State) ->
    Data1 = maps:get(?MODULE, State, #{}),
    Data2 = Data1#{sessions=>Regs},
    State#{?MODULE=>Data2}.


