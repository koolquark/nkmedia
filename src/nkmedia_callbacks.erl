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
-export([nkmedia_call_init/2, nkmedia_call_terminate/2, 
		 nkmedia_call_backend/2, nkmedia_call_resolve/2, nkmedia_call_out/4, 
		 nkmedia_call_notify/3, 
		 nkmedia_call_handle_call/3, nkmedia_call_handle_cast/2, 
		 nkmedia_call_handle_info/2]).
-export([nkmedia_session_init/2, nkmedia_session_terminate/2, 
		 nkmedia_session_notify/3, nkmedia_session_out/4, 
		 nkmedia_session_handle_call/3, nkmedia_session_handle_cast/2, 
		 nkmedia_session_handle_info/2]).
-export([nkmedia_session_get_mediaserver/1]).

-export([nkdocker_notify/2]).

-include("nkmedia.hrl").


%% ===================================================================
%% Types
%% ===================================================================

-type continue() :: continue | {continue, list()}.



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
%% Call Callbacks
%% ===================================================================

-type call_id() :: nkmedia_call:id().
-type call() :: nkmedia_call:call().


%% @doc Called when a new call starts
-spec nkmedia_call_init(call_id(), call()) ->
	{ok, call()}.

nkmedia_call_init(_Id, Call) ->
	{ok, Call}.

%% @doc Called when the call stops
-spec nkmedia_call_terminate(Reason::term(), call()) ->
	{ok, call()}.

nkmedia_call_terminate(_Reason, Call) ->
	{ok, Call}.


%% @doc Called when the status of the call changes
-spec nkmedia_call_notify(call_id(), nkmedia_call:event(), call()) ->
	{ok, call()} | continue().

nkmedia_call_notify(_CallId, _Event, Call) ->
	{ok, Call}.


%% @doc Called when a call specificatio must be resolved
-spec nkmedia_call_backend(nkmedia:offer(), call()) ->
	{ok, nkmedia:backend(), call()} | 
	{hangup, nkmedia:hangup_reason(), call()} |
	continue().

nkmedia_call_backend(_Offer, Call) ->
	{hangup, <<"No Backend">>, Call}.


%% @doc Called when a call specificatio must be resolved
-spec nkmedia_call_resolve(nkmedia:offer(), call()) ->
	{ok, nkmedia_call:call_out_spec(), call()} | 
	{hangup, nkmedia:hangup_reason(), call()} |
	{error, binary(), call()} | 
	continue().

nkmedia_call_resolve(_Offer, Call) ->
	{error, <<"Unknown Destination">>, Call}.


%% @doc Called when an outbound call is scheduled to be sent
-spec nkmedia_call_out(call_id(), session_id(), 
							nkmedia_session:call_dest(), call()) ->
	{call, nkmedia_session:call_dest(), call()} | 
	{retry, Secs::pos_integer(), call()} | 
	{remove, call()} | 
	continue().

nkmedia_call_out(_CallId, _SessId, Dest, Call) ->
	{call, Dest, Call}.


%% @doc
-spec nkmedia_call_handle_call(term(), {pid(), term()}, call()) ->
	{reply, term(), call()} | {noreply, call()} | continue().

nkmedia_call_handle_call(Msg, _From, Call) ->
	lager:error("Unexpected call at nkmedia_call: ~p", [Msg]),
	{noreply, Call}.


%% @doc
-spec nkmedia_call_handle_cast(term(), call()) ->
	{noreply, call()} | continue().

nkmedia_call_handle_cast(Msg, Call) ->
	lager:error("Unexpected cast at nkmedia_call: ~p", [Msg]),
	{noreply, Call}.


%% @doc
-spec nkmedia_call_handle_info(term(), call()) ->
	{noreply, call()} | continue().

nkmedia_call_handle_info(Msg, Call) ->
	lager:error("Unexpected info at nkmedia_call: ~p", [Msg]),
	{noreply, Call}.



%% ===================================================================
%% Session Callbacks
%% ===================================================================

-type session_id() :: nkmedia_session:id().
-type session() :: nkmedia_session:session().


%% @doc Called when a new session starts
-spec nkmedia_session_init(session_id(), session()) ->
	{ok, session()}.

nkmedia_session_init(_Id, Session) ->
	{ok, Session}.

%% @doc Called when the session stops
-spec nkmedia_session_terminate(Reason::term(), session()) ->
	{ok, session()}.

nkmedia_session_terminate(_Reason, Session) ->
	{ok, Session}.


%% @doc Called when the status of the session changes
-spec nkmedia_session_notify(nkmedia_session:id(), nkmedia_session:event(), session()) ->
	{ok, session()} | continue().

nkmedia_session_notify(SessId, Event, Session) ->
	case Session of
		#{notify:={nkmedia_call, _CallId, CallPid}} ->
			nkmedia_call:session_event(CallPid, SessId, Event);
		_ ->
			ok
	end,
	{ok, Session}.

				  

%% @doc Called when a new call must be sent from the session
%% The notify, is included, will be monitorized and stored and out_notify in the 
%% session
-spec nkmedia_session_out(session_id(), nkmedia_session:call_dest(), 
						  nkmedia:offer(), session()) ->
	{ringing, nkmedia:notify(), nkmedia:answer()|#{}, session()} |	% Answer optional
	{answer, nkmedia:notify(), nkmedia:answer()|#{}, session()} |   % Answer optional
	{ok, nkmedia:notify(), session()} | 			     		    % (if not in ringing)
	{hangup, nkmedia:hangup_reason(), session()}.

nkmedia_session_out(_SessId, _CallDest, _Offer, Session) ->
	{hangup, <<"Unrecognized Destination">>, Session}.


%% @doc
-spec nkmedia_session_handle_call(term(), {pid(), term()}, session()) ->
	{reply, term(), session()} | {noreply, session()} | continue().

nkmedia_session_handle_call(Msg, _From, Session) ->
	lager:error("Unexpected call at nkmedia_session: ~p", [Msg]),
	{noreply, Session}.


%% @doc
-spec nkmedia_session_handle_cast(term(), session()) ->
	{noreply, session()} | continue().

nkmedia_session_handle_cast(Msg, Session) ->
	lager:error("Unexpected cast at nkmedia_session: ~p", [Msg]),
	{noreply, Session}.


%% @doc
-spec nkmedia_session_handle_info(term(), session()) ->
	{noreply, session()} | continue().

nkmedia_session_handle_info(Msg, Session) ->
	lager:error("Unexpected info at nkmedia_session: ~p", [Msg]),
	{noreply, Session}.



%% @private
-spec nkmedia_session_get_mediaserver(nkmedia:backend()) ->
	{ok, nkmedia_session:mediaserver()} | {error, term()}.

nkmedia_session_get_mediaserver(p2p) ->
	{ok, none};

nkmedia_session_get_mediaserver(freeswitch) ->
	case nkmedia_fs_engine:get_all() of
        [{FsId, _}|_] ->
			{ok, {freeswitch, FsId}};
       	[] ->
       		{error, no_mediaserver_avialable}
    end;

nkmedia_session_get_mediaserver(Backend) ->
	{error, {unknown_backend, Backend}}.




%% ===================================================================
%% Docker Monitor Callbacks
%% ===================================================================

nkdocker_notify(MonId, {ping, {<<"nk_fs_", _/binary>>=Name, Data}}) ->
	nkdocker_notify(MonId, {start, {Name, Data}});

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

nkdocker_notify(_MonId, {stats, {<<"nk_fs_", _/binary>>=Name, Stats}}) ->
	nkmedia_fs_engine:stats(Name, Stats);

nkdocker_notify(_Id, _Event) ->
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

