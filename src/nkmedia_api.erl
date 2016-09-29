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
-export([api_server_reg_down/3]).
-export([nkmedia_session_reg_event/4]).

-include_lib("nkservice/include/nkservice.hrl").
-include_lib("nksip/include/nksip.hrl").


%% ===================================================================
%% Types
%% ===================================================================


%% ===================================================================
%% Commands
%% ===================================================================

%% @doc
-spec cmd(nkservice:id(), atom(), Data::map(), map()) ->
	{ok, map(), State::map()} | {error, nkservice:error(), State::map()}.

%% Create a session from the API
%% We create the session linked with the API server process
%% (we capture the stop event and remove it from the API session, and stop if it fails)
%% We then register the session at the API server
%% (if the session fails, we print an error)
%% It also subscribes the API session to events
cmd(<<"session">>, <<"create">>, Req, State) ->
	#api_req{srv_id=SrvId, data=Data, user=User, session=UserSession} = Req,
	#{type:=Type} = Data,
	Config = Data#{
		register => {nkmedia_api, self()},
		user_id => User,
		user_session => UserSession
	},
	{ok, SessId, Pid} = nkmedia_session:start(SrvId, Type, Config),
	nkservice_api_server:register(self(), {nkmedia_session, SessId, Pid}),
	case maps:get(subscribe, Data, true) of
		true ->
			RegId = session_reg_id(SrvId, <<"*">>, SessId),
			Body = maps:get(events_body, Data, #{}),
			nkservice_api_server:register_events(self(), RegId, Body);
		false ->
			ok
	end,
	case get_create_reply(SessId, Config) of
		{ok, Reply} ->
			{ok, Reply, State};
		{error, Error} ->
			nkmedia_session:stop(SessId, Error),
			{error, Error, State}
	end;

cmd(<<"session">>, <<"destroy">>, #api_req{data=Data}, State) ->
	#{session_id:=SessId} = Data,
	nkmedia_session:stop(SessId),
	{ok, #{}, State};

cmd(<<"session">>, <<"set_answer">>, #api_req{data=Data}, State) ->
	#{answer:=Answer, session_id:=SessId} = Data,
	case nkmedia_session:cmd(SessId, set_answer, #{answer=>Answer}) of
		{ok, Reply} ->
			{ok, Reply, State};
		{error, Error} ->
			{error, Error, State}
	end;

cmd(<<"session">>, <<"get_offer">>, #api_req{data=#{session_id:=SessId}}, State) ->
	case nkmedia_session:get_offer(SessId) of
		{ok, Offer} ->
			{ok, Offer, State};
		{error, Error} ->
			{error, Error, State}
	end;

cmd(<<"session">>, <<"get_answer">>, #api_req{data=#{session_id:=SessId}}, State) ->
	case nkmedia_session:get_answer(SessId) of
		{ok, Offer} ->
			{ok, Offer, State};
		{error, Error} ->
			{error, Error, State}
	end;

cmd(<<"session">>, Cmd, #api_req{data=Data}, State)
		when Cmd == <<"update_media">>; 
			 Cmd == <<"set_type">>;
		     Cmd == <<"recorder_action">>; 
		     Cmd == <<"player_action">>; 
		     Cmd == <<"room_action">> ->
 	#{session_id:=SessId} = Data,
 	Cmd2 = binary_to_atom(Cmd, latin1),
	case nkmedia_session:cmd(SessId, Cmd2, Data) of
		{ok, Reply} ->
			{ok, Reply, State};
		{error, Error} ->
			{error, Error, State}
	end;

cmd(<<"session">>, <<"set_candidate">>, #api_req{data=Data}, State) ->
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

cmd(<<"session">>, <<"set_candidate_end">>, #api_req{data=Data}, State) ->
	#{session_id := SessId} = Data,
	Candidate = #candidate{last=true},
	case nkmedia_session:candidate(SessId, Candidate) of
		ok ->
			{ok, #{}, State};
		{error, Error} ->
			{error, Error, State}
	end;

cmd(<<"session">>, <<"get_info">>, #api_req{data=Data}, State) ->
	#{session_id:=SessId} = Data,
	case nkmedia_session:get_session(SessId) of
		{ok, Session} ->
			Keys = nkmedia_api_syntax:session_fields(),
			Data2 = maps:with(Keys, Session),
			{ok, Data2, State};
		{error, Error} ->
			{error, Error, State}
	end;

cmd(<<"session">>, <<"get_list">>, _Req, State) ->
	Res = [#{session_id=>Id} || {Id, _Pid} <- nkmedia_session:get_all()],
	{ok, Res, State};


cmd(_SrvId, Other, _Data, State) ->
	{error, {unknown_command, Other}, State}.




%% ===================================================================
%% Session callbacks
%% ===================================================================

%% @private Sent by the session when it is stopping
%% We sent a message to the API session to remove the session before 
%% it receives the DOWN.
nkmedia_session_reg_event(SessId, {nkmedia_api, Pid}, {stop, _Reason}, Session) ->
	#{srv_id:=SrvId} = Session,
	RegId = session_reg_id(SrvId, <<"*">>, SessId),
	nkservice_api_server:unregister_events(Pid, RegId),
	nkservice_api_server:unregister(Pid, {nkmedia_session, SessId, self()});

nkmedia_session_reg_event(_SessId, _RegId, _Event, _Session) ->
	ok.



%% ===================================================================
%% API server callbacks
%% ===================================================================


%% @private Called when API server detects a registered session is down
%% Normally it should have been unregistered first
%% (detected above and sent in the cast after)
api_server_reg_down({nkmedia_session, SessId, _SessPid}, Reason, State) ->
	lager:warning("API Server: Session ~s is down: ~p", [SessId, Reason]),
	{ok, State};

api_server_reg_down(_Link, _Reason, _State) ->
	continue.



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
session_reg_id(SrvId, Type, SessId) ->
	#reg_id{
		srv_id = SrvId, 
		class = <<"media">>, 
		subclass = <<"session">>,
		type = nklib_util:to_binary(Type),
		obj_id = SessId
	}.



