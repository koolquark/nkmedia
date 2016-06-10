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

-module(nkmedia_fs).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export_type([id/0, stats/0]).


%% ===================================================================
%% Types
%% ===================================================================

-type id() :: nkmedia_fs_engine:id().


-type stats() :: #{
		idle => integer(),
		max_sessions => integer(),
		session_count => integer(),
		session_peak_five_mins => integer(),
		session_peak_max => integer(),
		sessions_sec => integer(),
		sessions_sec_five_mins => integer(),
		sessions_sec_max => integer(),
		all_sessions => integer(),
		uptime => integer()
	}.



%% ===================================================================
%% Public functions
%% ===================================================================

