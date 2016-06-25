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
-export([cmd/4, handle_down/3]).
-export([syntax/1, defaults/1, mandatory/1]).


%% ===================================================================
%% Types
%% ===================================================================


%% ===================================================================
%% Commands
%% ===================================================================

%% @doc
-spec cmd(nkservice:id(), atom(), Data::map(), map()) ->
	{ok, map(), State::map()} | {error, nkservice:error(), State::map()}.


cmd(SrvId, start_session, Data, State) ->
	#{class:=Class, events:=Events} = Data,
	Config = Data#{
		{link, nkmedia_api} => self(),
		events := {Events, self()}
	},
	case nkmedia_session:start(SrvId, Class, Config) of
		{ok, SessId, Pid, Reply} ->
			Mon = monitor(process, Pid),
			Sessions = get_sessions(State),
			Sessions2 = [{SessId, Mon}|Sessions],
			{ok, Reply#{session_id=>SessId}, set_sessions(Sessions2, State)};
		{error, Error} ->
			lager:warning("Error calling session_start: ~p", [Error]),
			{error, Error, State}
	end;

cmd(_SrvId, _Other, _Data, State) ->
	{error, unknown_command, State}.


%% @doc
handle_down(Mon, Reason, State) ->
	Sessions = get_sessions(State),
	case lists:keytake(Mon, 2, Sessions) of
		{value, {SessId, Mon}, Sessions2} ->
			lager:warning("Session ~s is down: ~p", [SessId, Reason]),
			nkservice_api_server:event(self(), media, session, down, SessId, #{}),
			{ok, set_sessions(Sessions2, State)};
		false ->
			continue
	end.



%% ===================================================================
%% Syntax
%% ===================================================================

%% @private
syntax(start_session) ->
	#{
		class => {enum, [p2p, echo, park, mcu, proxy, publish, listen]},
		events => {enum, ['*', hangup]},
		wait_timeout => {integer, 1, none},
		ready_timeout => {integer, 1, none},
		backend => {enum, [p2p, janus, freeswitch, kurento]}
	}.


%% @private
defaults(start_session) ->
	#{class=>p2p, events=>'*'};

defaults(_) ->
	#{}.


%% @private
mandatory(_) ->
	[].



%% ===================================================================
%% Internal
%% ===================================================================

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


