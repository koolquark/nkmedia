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

%% @doc NkMEDIA callbacks

-module(nkmedia_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([nkdocker_notify/2]).



%% ===================================================================
%% Types
%% ===================================================================



%% ===================================================================
%% Public functions
%% ===================================================================

nkdocker_notify(MonId, {start, {<<"nk_freeswitch", _/binary>>, Data}}) ->
	case Data of
		#{
			name := Name,
			labels := #{<<"nkmedia">> := <<"freeswitch">>},
			env := #{<<"NK_LOCAL_IP">> := Ip, <<"NK_PASS">> := Pass},
			image := Image
		} ->
			connect_fs(MonId, Name, Image, Ip, Pass);
		_ ->
			lager:warning("Started unrecognized nk_freeswitch")
	end;

nkdocker_notify(MonId, {stop, {<<"nk_freeswitch", _/binary>>, Data}}) ->
	case Data of
		#{
			name := Name,
			labels := #{<<"nkmedia">> := <<"freeswitch">>},
			env := #{<<"NK_LOCAL_IP">> := Ip}
		} ->
			remove_fs(MonId, Name, Ip);
		_ ->
			ok
	end;

nkdocker_notify(_MonId, {stats, {Name, Stats}}) ->
	nkmedia_fs_engine:stats(Name, Stats);

nkdocker_notify(_Id, _Event) ->
	% lager:notice("NK EVENT: ~p", [Event]).
	ok.



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
connect_fs(MonId, Name, Image, Host, Pass) ->
	spawn(
		fun() -> 
			timer:sleep(2000),
			case nkmedia_fs_engine:connect(Name, Image, Host, Pass) of
				{ok, _Pid} -> 
					ok = nkdocker_monitor:start_stats(MonId, Name);
				{error, Error} -> 
					lager:warning("Could not connect to Freeswitch at ~s: ~p", 
								  [Host, Error])
			end
		end),
	ok.


%% @private
remove_fs(MonId, Name, Ip) ->
	spawn(
		fun() ->
			nkmedia_fs_engine:stop(Ip),
			case nkdocker_monitor:get_docker(MonId) of
				{ok, Pid} -> 
					nkdocker:rm(Pid, Name);
				_ -> 
					lager:warning("Could not remove container ~s", [Name])
			end
		end),
	ok.

