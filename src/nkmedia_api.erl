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
-export([cmd/4]).

%% ===================================================================
%% Types
%% ===================================================================

-type state() ::
	#{
		nkmedia_api_sessions => [{nkmedia_seesion:id(), reference()}]
	}


%% ===================================================================
%% Commands
%% ===================================================================

%% @doc
-spec cmd(nkservice:id(), atom(), Data::map(), map()) ->
	{ok, map(), State::map()} | {error, nkservice:error_code(), State::map()}.


cmd(SrvId, start_session, Map, State) ->
	case check(start_session, Map) of
		{ok, #{class:=Class}=Data} ->
			Config = Data#{{link, nkmedia_api}=>self()},
			case nkmedia_session:start(SrvId, Class, Config) of
				{ok, SessId, Pid, Reply} ->
					Ref = monitor(process, Pid),
					Sessions = maps:get(nkmedia_api_sessions, State, []),
					Sessions2 = [{SessId, Ref}|Sessions],
					State2 = State#{nkmedia_api_sessions=>Sessions2},
					{ok, Reply#{session_id=>SessId}, State2};
				{error, Error} ->
					lager:warning("Error calling session_start: ~p", [Error]),
					{error, internal_error, State}
			end;
		{syntax, Syntax} ->
			{error, {syntax_error, Syntax}, State}
	end;

cmd(_SrvId, _Other, _Data, State) ->
	{error, unknown_cmd, State}.




%% @doc
handle_down(Ref, Reason, State) ->
	case maps:find(nkmedia_api_sessions, State) of
		{ok, List} ->
			case lists:keytake(Ref, 2, List) of
				{value, {SessId, Ref}, List2} ->
					lager:notice("Session ~s is down, closing connection", [SessId]),
					{stop, State#{nkmedia_api_sessions:=List2}};
				false ->
					continue
			end;
		error ->
			continue
	end;



session_event(SessId, Event, ApiPid) ->
	


%% ===================================================================
%% Syntax
%% ===================================================================

%% @private
syntax(start_session) ->
	#{
		class => {enum, [p2p, park, mcu, proxy, publish, listen]},
		wait_timeout => {integer, 1, none},
		ready_timeout => {integer, 1, none},
		backend => {enum, [p2p, janus, freeswitch, kurento]}
	}.


%% @private
defaults(start_session) ->
	#{class=>p2p};

defaults(_) ->
	#{}.


%% @private
mandatory(_) ->
	[].



%% ===================================================================
%% Internal
%% ===================================================================


%% @private
check(Type, Map) ->
	Opts = #{
		return => map, 
		defaults => defaults(Type),
		mandatory => mandatory(Type)
	},
	case nklib_config:parse_config(Map, syntax(Type), Opts) of
		{ok, Parsed, _} ->
			{ok, Parsed};
		{error, {syntax_error, Error}} ->
			{syntax, Error};
		{error, Error} ->
			error(Error)
	end.




