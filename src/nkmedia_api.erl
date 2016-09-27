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
-export([api_server_reg_down/3, api_server_handle_cast/2]).
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

%% Registers the media session with the API session (to monitor DOWNs)
%% as (nkmedia_session, SessId, SessPid)
%% Registers the API session with the media session (as nkmedia_api, pid())
%% Subscribes to events
cmd(<<"session">>, <<"start">>, Req, State) ->
	#api_req{srv_id=SrvId, data=Data, user=User, session=UserSession} = Req,
	#{type:=Type} = Data,
	Config = Data#{
		register => {nkmedia_api, self()},
		user_id => User,
		user_session => UserSession
	},
	case start_session(SrvId, Type, Config) of
		{ok, SessId, Pid, Reply} ->
   		    nkservice_api_server:register(self(), {nkmedia_session, SessId, Pid}),
			case maps:get(subscribe, Data, true) of
				true ->
					RegId = session_reg_id(SrvId, <<"*">>, SessId),
					Body = maps:get(events_body, Data, #{}),
					nkservice_api_server:register_events(self(), RegId, Body);
				false ->
					ok
			end,
			{ok, Reply#{session_id=>SessId}, State};
		{error, Error} ->
			{error, Error, State}
	end;

cmd(<<"session">>, <<"stop">>, #api_req{data=Data}, State) ->
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

cmd(<<"session">>, <<"cmd">>, #api_req{data=Data}, State) ->
	#{session_id:=SessId, cmd:=Cmd} = Data,
	case nkmedia_session:cmd(SessId, Cmd, Data) of
		{ok, _} ->
			{ok, #{}, State};
		{error, Error} ->
			{error, Error, State}
	end;

cmd(<<"session">>, <<"info">>, #api_req{data=Data}, State) ->
	#{session_id:=SessId} = Data,
	case nkmedia_session:get_session(SessId) of
		{ok, Session} ->
			Keys = nkmedia_api_syntax:session_fields(),
			Data2 = maps:with(Keys, Session),
			{ok, Data2, State};
		{error, Error} ->
			{error, Error, State}
	end;

cmd(<<"session">>, <<"list">>, _Req, State) ->
	Res = [#{session_id=>Id} || {Id, _Pid} <- nkmedia_session:get_all()],
	{ok, Res, State};


cmd(_SrvId, _Other, _Data, State) ->
	{error, unknown_command, State}.




%% ===================================================================
%% Session callbacks
%% ===================================================================

%% @private Sent by the session when it is stopping
%% We sent a message to the API session to remove the session before 
%% it receives the DOWN.
nkmedia_session_reg_event(SessId, {nkmedia_api, Pid}, {stop, _Reason}, _Session) ->
	gen_server:cast(Pid, {nkmedia_api_session_stop, SessId, self()});

nkmedia_session_reg_event(_SessId, _RegId, _Event, _Session) ->
	ok.



%% ===================================================================
%% API server callbacks
%% ===================================================================


%% @private Called from nkmedia_callbacks, if a registered link is down
api_server_reg_down({nkmedia_session, SessId, _SessPid}, Reason, State) ->
	lager:warning("API Server: Session ~s is down: ~p", [SessId, Reason]),
	{ok, State};

api_server_reg_down(_Link, _Reason, _State) ->
	continue.


%% @private
api_server_handle_cast({nkmedia_api_session_stop, SessId, Pid}, State) ->
	nkservice_api_server:unregister(self(), {nkmedia_session, SessId, Pid}),
	{ok, State};

api_server_handle_cast(_Msg, _State) ->
	continue.



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
start_session(SrvId, Type, Config) ->
	case nkmedia_session:start(SrvId, Type, Config) of
		{ok, SessId, Pid} ->
			case Config of
				#{offer:=_, answer:=_} -> 
					{ok, #{}};
				#{offer:=_} -> 
					case nkmedia_session:get_answer(Pid) of
						{ok, Answer} ->
							{ok, SessId, Pid, #{answer=>Answer}};
						{error, Error} ->
							{error, Error}
					end;
				_ -> 
					case nkmedia_session:get_offer(Pid) of
						{ok, Offer} ->
							{ok, SessId, Pid, #{offer=>Offer}};
						{error, Error} ->
							{error, Error}
					end
			end;
		{error, Error} ->
			{error, Error}
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



