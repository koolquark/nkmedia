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
		 nkmedia_session_event/3, nkmedia_session_out/4, 
		 nkmedia_session_handle_call/3, nkmedia_session_handle_cast/2, 
		 nkmedia_session_handle_info/2]).
-export([nkmedia_session_get_backend/1, nkmedia_session_get_mediaserver/2]).
-export([nkmedia_call_init/2, nkmedia_call_terminate/2, 
		 nkmedia_call_resolve/2, nkmedia_call_out/3, 
		 nkmedia_call_event/3, 
		 nkmedia_call_handle_call/3, nkmedia_call_handle_cast/2, 
		 nkmedia_call_handle_info/2]).

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


%% @doc Called to select the backend for this session
-spec nkmedia_session_get_backend(session()) ->
	{ok, nkmedia:backend(), session()}.

nkmedia_session_get_backend(Config) ->
	{ok, p2p, Config}.


%% @doc Called when the status of the session changes
-spec nkmedia_session_event(nkmedia_session:id(), nkmedia_session:event(), session()) ->
	{ok, session()} | continue().

nkmedia_session_event(SessId, Event, Session) ->
	case Session of
		#{nkmedia_call_id:=CallId} ->
			nkmedia_call:session_event(CallId, SessId, Event);
		_ ->
			ok
	end,
	{ok, Session}.

				  

%% @doc Called when a new call must be sent from the session
%% The notify, is included, will be monitorized and stored and out_notify in the 
%% session
-spec nkmedia_session_out(session_id(), nkmedia_session:call_dest(), 
						  nkmedia:offer(), session()) ->
	{ringing, nkmedia:answer(), pid()|undefined,  session()} |	% Answer optional
	{answer, nkmedia:answer(), pid()|undefined, session()} |    % Answer optional
	{async, pid()|undefined, session()} | 			     	    %   (if not in ringing)
	{hangup, nkmedia:hangup_reason(), session()}.

nkmedia_session_out(_SessId, _CallDest, _Offer, Session) ->
	{hangup, <<"Unrecognized Destination">>, Session}.


%% @doc
-spec nkmedia_session_handle_call(term(), {pid(), term()}, session()) ->
	{reply, term(), session()} | {noreply, session()} | continue().

nkmedia_session_handle_call(Msg, _From, Session) ->
	lager:error("Module nkmedia_session received unexpected call: ~p", [Msg]),
	{noreply, Session}.


%% @doc
-spec nkmedia_session_handle_cast(term(), session()) ->
	{noreply, session()} | continue().

nkmedia_session_handle_cast(Msg, Session) ->
	lager:error("Module nkmedia_session received unexpected cast: ~p", [Msg]),
	{noreply, Session}.


%% @doc
-spec nkmedia_session_handle_info(term(), session()) ->
	{noreply, session()} | continue().

nkmedia_session_handle_info(Msg, Session) ->
	lager:warning("Module nkmedia_session received unexpected info: ~p", [Msg]),
	{noreply, Session}.


%% @private
-spec nkmedia_session_get_mediaserver(nkmedia:backend(), session()) ->
	{ok, nkmedia_session:mediaserver(), session()} | {error, term()}.

nkmedia_session_get_mediaserver(p2p, Session) ->
	{ok, none, Session};

nkmedia_session_get_mediaserver(freeswitch, Session) ->
	case nkmedia_fs_engine:get_all() of
        [{FsId, _}|_] ->
			{ok, {freeswitch, FsId}, Session};
       	[] ->
       		{error, no_mediaserver_available}
    end;

nkmedia_session_get_mediaserver(Backend, _Session) ->
	{error, {unknown_backend, Backend}}.



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
-spec nkmedia_call_event(call_id(), nkmedia_call:event(), call()) ->
	{ok, call()} | continue().

nkmedia_call_event(CallId, Event, Call) ->
	case Call of
		#{session_id:=SessionId} ->
			nkmedia_session:call_event(SessionId, CallId, Event);
		_ ->
			ok
	end,
	{ok, Call}.


%% @doc Called when a call specificatio must be resolved
-spec nkmedia_call_resolve(nkmedia:offer(), call()) ->
	{ok, nkmedia_call:call_out_spec(), call()} | 
	{hangup, nkmedia:hangup_reason(), call()} |
	continue().

nkmedia_call_resolve(_Offer, Call) ->
	{hangup,  <<"Unknown Destination">>, Call}.


%% @doc Called when an outbound call is scheduled to be sent
-spec nkmedia_call_out(session_id(), nkmedia_session:call_dest(), call()) ->
	{call, nkmedia_session:call_dest(), call()} | 
	{retry, Secs::pos_integer(), call()} | 
	{remove, call()} | 
	continue().

nkmedia_call_out(_SessId, Dest, Call) ->
	{call, Dest, Call}.


%% @doc
-spec nkmedia_call_handle_call(term(), {pid(), term()}, call()) ->
	{reply, term(), call()} | {noreply, call()} | continue().

nkmedia_call_handle_call(Msg, _From, Call) ->
	lager:error("Module nkmedia_call received unexpected call: ~p", [Msg]),
	{noreply, Call}.


%% @doc
-spec nkmedia_call_handle_cast(term(), call()) ->
	{noreply, call()} | continue().

nkmedia_call_handle_cast(Msg, Call) ->
	lager:error("Module nkmedia_call received unexpected call: ~p", [Msg]),
	{noreply, Call}.


%% @doc
-spec nkmedia_call_handle_info(term(), call()) ->
	{noreply, call()} | continue().

nkmedia_call_handle_info(Msg, Call) ->
	lager:warning("Module nkmedia_call received unexpected info: ~p", [Msg]),
	{noreply, Call}.


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

