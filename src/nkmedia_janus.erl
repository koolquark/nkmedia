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

%% @doc NkMEDIA application

-module(nkmedia_janus).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/1, stop/1]).
-export_type([config/0]).


%% ===================================================================
%% Types
%% ===================================================================


-type config() ::
    #{
        comp => binary(),
        vsn => binary(),
        rel => binary(),
        pass => binary(),
        name => binary()
    }.




%% ===================================================================
%% Public functions
%% ===================================================================

%% @doc Installs and starts a local FS instance
-spec start(config()) ->
    ok | {error, term()}.

start(Spec) ->
	case nkmedia_fs_docker:config(Spec) of
		{ok, Spec2, Docker} ->
			nkmedia_fs_docker:start(Spec2, Docker);
		{error, Error} ->
			{error, Error}
	end.
	% case nkmedia_fs_docker:start(Opts) of
	% 	ok ->
	% 		case nkmedia_sup:start_fs(config(Opts)) of
	% 			{ok, Pid} ->
	% 				case Opts of
	% 					#{callback:=CallBack} ->
	% 						case nkmedia_fs_server:register(Pid, CallBack) of
	% 							ok ->
	% 								{ok, Pid};
	% 							{error, Error} ->
	% 								{error, Error}
	% 						end;
	% 					_ ->
	% 						{ok, Pid}
	% 				end;
	% 			{error, Error} ->
	% 				{error, Error}
	% 		end;
	% 	{error, Error} ->
	% 		{error, Error}
	% end.


%% @doc Equivalent to stop()
-spec stop(config()) ->
    {ok, pid()} | {error, term()}.

stop(Spec) ->
	case nkmedia_fs_docker:config(Spec) of
		{ok, Spec2, Docker} ->
			nkmedia_fs_docker:stop(Spec2, Docker);
		{error, Error} ->
			{error, Error}
	end.
	% nkmedia_sup:stop_fs(config(Opts)),
	% nkmedia_fs_docker:remove(Opts).
	
