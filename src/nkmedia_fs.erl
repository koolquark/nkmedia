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

-export([start/1, stop/1]).
-export([start_inbound/3, start_outbound/2, channel_op/3, channel_op/4]).
-export([config/1]).
-export_type([config/0, q850/0]).


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


-type status() ::
	connecting | ready.


-type fs_update() ::
	#{
		status => status(),
		ip => inet:ip_address(),
		index => integer(),
		version => binary(),
		stats => stats()
	}.


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


-type ch_notify() ::
    wait | park | {room, binary()} | {join, binary()} | stop | ping.


-type q850() :: nkmedia_util:q850().


%% @doc Called by the FS engine
-callback nkmedia_fs_update(FsPid::pid(), fs_update()) ->
	ok.

%% @doc Called by the FS engine
-callback nkmedia_fs_ch_notify(CallId::binary(), ch_notify()) ->
	ok.



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
	


% %% @doc Starts a proxy connection
% %% We will start a new WS connection to fs, proxy_data/2 must be used to 
% %% send data to it. Responses will be sent as {nkmedia_fs_verto, pid(), proxy_event()} 
% %% messages to the caller
% -spec start_proxy(pid()) ->
% 	{ok, pid()} | {error, term()}.

% start_proxy(Pid) ->
% 	case nkmedia_fs_server:get_config(Pid) of
% 		{ok, Config } ->
% 			nkmedia_verto_proxy_client:start(Config);
% 		{error, Error} ->
% 			{error, Error}
% 	end.


%% @doc Generates a new inbound channel
-spec start_inbound(pid(), binary(), nkmedia_fs_server:in_ch_opts()) ->
	{ok, CallId::binary(), pid(), SDP::binary()} | {error, term()}.

start_inbound(Pid, SDP, Opts) ->
	nkmedia_fs_server:start_inbound(Pid, SDP, Opts).


%% @doc Generates a new outbound channel at this server and node
-spec start_outbound(pid(), nkmedia_fs_server:out_ch_opts()) ->
	{ok, CallId::binary()} | {error, term()}.

start_outbound(Pid, Opts) ->
	nkmedia_fs_server:start_outbound(Pid, Opts).


%% @doc Equivalent to channel_op(Pid, CallId, Op, #{})
-spec channel_op(pid(), binary(), nkmedia_fs_channel:op()) ->
	ok | {error, term()}.

channel_op(Pid, CallId, Op) ->
	channel_op(Pid, CallId, Op, #{}).


%% @doc Tries to perform an operation over a channel.
-spec channel_op(pid(), binary(), nkmedia_fs_channel:op(), 
			     nkmedia_fs_channel:op_opts()) ->
	ok | {error, term()}.

channel_op(Pid, CallId, Op, Opts) ->
	nkmedia_fs_server:channel_op(Pid, CallId, Op, Opts).



%% @private
-spec config(map()|list()) ->
	{ok, nkmedia:fs_start_opts()}.

config(Spec) ->
	Syntax = #{
		index => {integer, 0, 10},
		version => binary,
		release => binary,
		password => binary,
		docker_company => binary,
		callback => module,
		call_debug => boolean
	},
	Opts = #{
		return => map,
		defaults => nkmedia_app:get(fs_defaults),
		warning_unknown => true
	},
	case nklib_config:parse_config(Spec, Syntax, Opts) of
		{ok, Spec2, _} ->
			{ok, Spec2};
		{error, Error} ->
			{error, Error}
	end.


