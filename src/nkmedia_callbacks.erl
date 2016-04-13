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

-export([plugin_deps/0, plugin_start/2, plugin_stop/2]).
-export([nkmedia_session_init/2, nkmedia_session_terminate/2, 
		 nkmedia_session_status/2,
		 nkmedia_session_handle_call/3, nkmedia_session_handle_cast/2,
		 nkmedia_session_handle_info/2, nkmedia_session_code_change/3]).
-export([nkdocker_notify/2]).

-include("nkmedia.hrl").


%% ===================================================================
%% Types
%% ===================================================================


%% ===================================================================
%% Plugin callbacks
%%
%% These are used when NkMEDIA is started as a NkSERVICE plugin
%% ===================================================================


plugin_deps() ->
    [nksip].


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA (~s) starting", [Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA (~p) stopping", [Name]),
    {ok, Config}.



%% ===================================================================
%% Session Callbacks
%% ===================================================================

nkmedia_session_init(_Id, Config) ->
	{ok, Config}.

nkmedia_session_terminate(_Reason, Config) ->
	{ok, Config}.

nkmedia_session_status(_Status, Config) ->
	{ok, Config}.

nkmedia_session_handle_call(Msg, _From, Config) ->
    lager:error("Module nkmedia_session received unexpected call ~p", [Msg]),
    {noreply, Config}.

nkmedia_session_handle_cast(Msg, Config) ->
    lager:error("Module nkmedia_session received unexpected cast ~p", [Msg]),
    {noreply, Config}.

nkmedia_session_handle_info(Msg, Config) ->
    lager:error("Module nkmedia_session received unexpected info ~p", [Msg]),
    {noreply, Config}.

nkmedia_session_code_change(_OldVsn, Config, _Extra) ->
	{ok, Config}.



%% ===================================================================
%% Docker Monitor Callbacks
%% ===================================================================

nkdocker_notify(MonId, {start, {<<"nk_fs_", _/binary>>, Data}}) ->
	case Data of
		#{
			name := Name,
			labels := #{<<"nkmedia">> := <<"freeswitch">>},
			env := #{<<"NK_FS_IP">> := Host, <<"NK_PASS">> := Pass},
			image := Image
		} ->
			case binary:split(Image, <<"/">>) of
				[_Comp, <<"nk_freeswitch_run:", Rel/binary>>] -> 
					case lists:member(Rel, ?SUPPORTED_FS) of
						true ->
							Config = #{name=>Name, rel=>Rel, host=>Host, pass=>Pass},
							connect_fs(MonId, Config);
						false ->
							lager:warning("Started unsupported nk_freeswitch")
					end;
				_ ->
					lager:warning("Started unrecognized nk_freeswitch")
			end;
		_ ->
			lager:warning("Started unrecognized nk_freeswitch")
	end;

nkdocker_notify(MonId, {stop, {<<"nk_fs_", _/binary>>, Data}}) ->
	case Data of
		#{
			name := Name,
			labels := #{<<"nkmedia">> := <<"freeswitch">>}
			% env := #{<<"NK_FS_IP">> := Host}
		} ->
			remove_fs(MonId, Name);
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
connect_fs(MonId, #{name:=Name}=Config) ->
	spawn(
		fun() -> 
			timer:sleep(2000),
			case nkmedia_fs_engine:connect(Config) of
				{ok, _Pid} -> 
					ok = nkdocker_monitor:start_stats(MonId, Name);
				{error, Error} -> 
					lager:warning("Could not connect to Freeswitch ~s: ~p", 
								  [Name, Error])
			end
		end),
	ok.


%% @private
remove_fs(MonId, Name) ->
	spawn(
		fun() ->
			nkmedia_fs_engine:stop(Name),
			case nkdocker_monitor:get_docker(MonId) of
				{ok, Pid} -> 
					nkdocker:rm(Pid, Name);
				_ -> 
					ok
			end
		end),
	ok.

