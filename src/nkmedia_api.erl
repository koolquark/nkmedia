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
-export([cmd/3]).
-export([session_stopped/3, api_session_down/3]).

-include_lib("nkservice/include/nkservice.hrl").
-include_lib("nksip/include/nksip.hrl").


%% ===================================================================
%% Types
%% ===================================================================


%% ===================================================================
%% Commands
%% ===================================================================

%% @doc
-spec cmd(binary(), Data::map(), map()) ->
	{ok, map(), State::map()} | {error, nkservice:error(), State::map()}.

%% Create a session from the API
%% We create the session linked with the API server process
%% - we capture the destroy event 
%%   (nkmedia_session_reg_event() -> session_stopped() here)
%% - if the session is killed, it is detected in 
%%   api_server_reg_down() -> api_session_down() here
cmd(create, Req, State) ->
	#api_req{srv_id=SrvId, data=Data, user_id=User, session_id=UserSession} = Req,
	#{type:=Type} = Data,
	Config = Data#{
		register => {nkmedia_api, self()},
		user_id => User,
		user_session => UserSession
	},
	{ok, SessId, Pid} = nkmedia_session:start(SrvId, Type, Config),
	nkservice_api_server:register(self(), {nkmedia_session, SessId, Pid}),
	case get_create_reply(SessId, Config) of
		{ok, Reply} ->
			{ok, Reply, State};
		{error, Error} ->
			nkmedia_session:stop(SessId, Error),
			{error, Error, State}
	end;

cmd(destroy, #api_req{data=Data}, State) ->
	#{session_id:=SessId} = Data,
	nkmedia_session:stop(SessId),
	{ok, #{}, State};

cmd(set_answer, #api_req{data=Data}, State) ->
	#{answer:=Answer, session_id:=SessId} = Data,
	case nkmedia_session:cmd(SessId, set_answer, #{answer=>Answer}) of
		{ok, Reply} ->
			{ok, Reply, State};
		{error, Error} ->
			{error, Error, State}
	end;

cmd(get_offer, #api_req{data=#{session_id:=SessId}}, State) ->
	case nkmedia_session:get_offer(SessId) of
		{ok, Offer} ->
			{ok, Offer, State};
		{error, Error} ->
			{error, Error, State}
	end;

cmd(get_answer, #api_req{data=#{session_id:=SessId}}, State) ->
	case nkmedia_session:get_answer(SessId) of
		{ok, Answer} ->
			{ok, Answer, State};
		{error, Error} ->
			{error, Error, State}
	end;

cmd(Cmd, #api_req{data=Data}, State)
		when Cmd == update_media; 
			 Cmd == set_type;
		     Cmd == recorder_action; 
		     Cmd == player_action; 
		     Cmd == room_action;
		     Cmd == get_stats ->
 	#{session_id:=SessId} = Data,
	case nkmedia_session:cmd(SessId, Cmd, Data) of
		{ok, Reply} ->
			{ok, Reply, State};
		{error, Error} ->
			{error, Error, State}
	end;

cmd(set_candidate, #api_req{data=Data}, State) ->
	#{
		session_id := SessId, 
		sdpMid := Id, 
		sdpMLineIndex := Index, 
		candidate := ALine
	} = Data,
	Candidate = #candidate{m_id=Id, m_index=Index, a_line=ALine},
	case nkmedia_session:candidate(SessId, Candidate) of
		ok ->
			{ok, #{}, State};
		{error, Error} ->
			{error, Error, State}
	end;

cmd(set_candidate_end, #api_req{data=Data}, State) ->
	#{session_id := SessId} = Data,
	Candidate = #candidate{last=true},
	case nkmedia_session:candidate(SessId, Candidate) of
		ok ->
			{ok, #{}, State};
		{error, Error} ->
			{error, Error, State}
	end;

cmd(get_info, #api_req{data=Data}, State) ->
	#{session_id:=SessId} = Data,
	case nkmedia_session:get_session(SessId) of
		{ok, Session} ->
			Data2 = nkmedia_api_syntax:get_info(Session),
			{ok, Data2, State};
		{error, Error} ->
			{error, Error, State}
	end;

cmd(get_status, #api_req{data=Data}, State) ->
	#{session_id:=SessId} = Data,
	case nkmedia_session:get_status(SessId) of
		{ok, Status} ->
			{ok, Status, State};
		{error, Error} ->
			{error, Error, State}
	end;

cmd(get_stats, #api_req{data=Data}, State) ->
	#{session_id:=SessId} = Data,
	case nkmedia_session:get_status(SessId) of
		{ok, Status} ->
			{ok, Status, State};
		{error, Error} ->
			{error, Error, State}
	end;

cmd(get_list, _Req, State) ->
	Res = [#{session_id=>Id} || {Id, _Pid} <- nkmedia_session:get_all()],
	{ok, Res, State};


cmd(Other, _Data, State) ->
	{error, {unknown_command, Other}, State}.




%% ===================================================================
%% Session callbacks
%% ===================================================================

%% @private Sent by the media session when it has been stopped
%% We sent a message to the API session to remove the session before 
%% it receives the DOWN.
session_stopped(SessId, ApiPid, Session) ->
	#{srv_id:=SrvId} = Session,
	Event = get_session_event(SrvId, SessId),
	nkservice_api_server:unsubscribe(ApiPid, Event),
	nkservice_api_server:unregister(ApiPid, {nkmedia_session, SessId, self()}),
	{ok, Session}.



%% ===================================================================
%% API server callbacks
%% ===================================================================


%% @private Called when API server detects a registered media session is down
%% Normally it should have been unregistered first
%% (detected above and sent in the cast after)
api_session_down(SessId, Reason, State) ->
	#{srv_id:=SrvId} = State,
	lager:warning("API Server: Session ~s is down: ~p", [SessId, Reason]),
	Event = get_session_event(SrvId, SessId),
	nkservice_api_server:unsubscribe(self(), Event),
	nkmedia_api_events:session_down(SrvId, SessId).



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
get_create_reply(SessId, Config) ->
	case maps:get(wait_reply, Config, false) of
		false ->
			{ok, #{session_id=>SessId}};
		true ->
			case Config of
				#{offer:=_, answer:=_} -> 
					{ok, #{session_id=>SessId}};
				#{offer:=_} -> 
					case nkmedia_session:get_answer(SessId) of
						{ok, Answer} ->
							{ok, #{session_id=>SessId, answer=>Answer}};
						{error, Error} ->
							{error, Error}
					end;
				_ -> 
					case nkmedia_session:get_offer(SessId) of
						{ok, Offer} ->
							{ok, #{session_id=>SessId, offer=>Offer}};
						{error, Error} ->
							{error, Error}
					end
			end
	end.


%% @private
get_session_event(SrvId, SessId) ->
	#event{
		srv_id = SrvId, 
		class = <<"media">>, 
		subclass = <<"session">>,
		obj_id = SessId
	}.



