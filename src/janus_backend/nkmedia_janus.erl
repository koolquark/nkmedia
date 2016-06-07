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

-export([start/0, start/1, stop/1, stop_all/0]).
-export_type([config/0]).


%% ===================================================================
%% Types
%% ===================================================================

-type id() :: nkmedia_janus_engine:id().


-type config() ::
    #{
        comp => binary(),
        vsn => binary(),
        rel => binary(),
        base => inet:port_number(),
        pass => binary(),
        name => binary()
    }.




%% ===================================================================
%% Public functions
%% ===================================================================

%% @doc Starts a JANUS instance
-spec start() ->
    {ok, id()} | {error, term()}.

start() ->
    start(#{}).


%% @doc Starts a JANUS instance
-spec start(config()) ->
    {ok, id()} | {error, term()}.

start(Config) ->
	nkmedia_janus_docker:start(Config).


%% @doc Stops a JANUS instance
-spec stop(id()) ->
    ok | {error, term()}.

stop(Id) ->    
	nkmedia_janus_docker:stop(Id).


%% @doc
stop_all() ->
	nkmedia_janus_docker:stop_all().







%% ===================================================================
%% Internal
%% ===================================================================

