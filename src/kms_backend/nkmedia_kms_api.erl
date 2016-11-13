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

-module(nkmedia_kms_api).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([cmd/4]).

-include_lib("nkservice/include/nkservice.hrl").
% -include_lib("nksip/include/nksip.hrl").


%% ===================================================================
%% Types
%% ===================================================================


%% ===================================================================
%% Commands
%% ===================================================================

%% @doc
-spec cmd(nkservice:id(), atom(), Data::map(), map()) ->
	{ok, map(), State::map()} | {error, nkservice:error(), State::map()}.

cmd(session, Cmd, #api_req{data=Data}, State)
		when Cmd == pause_record; Cmd == resume_record ->
 	#{session_id:=SessId} = Data,
 	Cmd2 = binary_to_atom(Cmd, latin1),
	case nkmedia_session:cmd(SessId, Cmd2, Data) of
		{ok, Reply} ->
			{ok, Reply, State};
		{error, Error} ->
			{error, Error, State}
	end;


cmd(_SrvId, _Other, _Data, _State) ->
	continue.



