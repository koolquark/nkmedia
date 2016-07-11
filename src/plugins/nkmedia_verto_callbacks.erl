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

%% @doc Plugin implementing a Verto server
-module(nkmedia_verto_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_syntax/0, plugin_listen/2, 
         plugin_start/2, plugin_stop/2]).
-export([error_code/1]).
-export([nkmedia_verto_init/2, nkmedia_verto_login/3, 
         nkmedia_verto_invite/4, nkmedia_verto_bye/3,
         nkmedia_verto_answer/4, nkmedia_verto_rejected/3,
         nkmedia_verto_dtmf/4, nkmedia_verto_terminate/2,
         nkmedia_verto_handle_call/3, nkmedia_verto_handle_cast/2,
         nkmedia_verto_handle_info/2]).
% -export([nkmedia_call_resolve/2]).

-define(VERTO_WS_TIMEOUT, 60*60*1000).
-include_lib("nkservice/include/nkservice.hrl").



%% ===================================================================
%% Types
%% ===================================================================

-type continue() :: continue | {continue, list()}.





%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia].


plugin_syntax() ->
    nkpacket:register_protocol(verto, nkmedia_verto),
    #{
        verto_listen => fun parse_listen/3
    }.


plugin_listen(Config, #{id:=SrvId}) ->
    % verto_listen will be already parsed
    Listen = maps:get(verto_listen, Config, []),
    Opts = #{
        class => {nkmedia_verto, SrvId},
        % get_headers => [<<"user-agent">>],
        idle_timeout => ?VERTO_WS_TIMEOUT
    },                                  
    [{Conns, maps:merge(ConnOpts, Opts)} || {Conns, ConnOpts} <- Listen].


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA Verto (~s) starting", [Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA Verto (~p) stopping", [Name]),
    {ok, Config}.



%% ===================================================================
%% Offering Callbacks
%% ===================================================================

-type call_id() :: nkmedia_verto:call_id().
-type verto() :: nkmedia_verto:verto().


%% @doc Called when a new verto connection arrives
-spec nkmedia_verto_init(nkpacket:nkport(), verto()) ->
    {ok, verto()}.

nkmedia_verto_init(_NkPort, Verto) ->
    {ok, Verto#{?MODULE=>#{}}}.


%% @doc Called when a login request is received
-spec nkmedia_verto_login(Login::binary(), Pass::binary(), verto()) ->
    {boolean(), verto()} | {true, Login::binary(), verto()} | continue().

nkmedia_verto_login(_Login, _Pass, Verto) ->
    {false, Verto}.


%% @doc Called when the client sends an INVITE
%% If {ok, ...} is returned, we must call nkmedia_verto:answer/3.
-spec nkmedia_verto_invite(nkservice:id(), call_id(), nkmedia:offer(), verto()) ->
    {ok, nklib:proc_id(), verto()} | 
    {answer, nkmedia:answer(), nklib_:proc_id(), verto()} | 
    {rejected, nkservice:error(), verto()} | continue().

nkmedia_verto_invite(SrvId, CallId, Offer, Verto) ->
    {rejected, not_implemented}.


%% @doc Called when the client sends an ANSWER after nkmedia_verto:invite/4
-spec nkmedia_verto_answer(call_id(), nklib:proc_id(), nkmedia:answer(), verto()) ->
    {ok, verto()} |{hangup, nkservice:error(), verto()} | continue().

nkmedia_verto_answer(_CallId, _ProcId, _Answer, Verto) ->
    {ok, Verto}.


%% @doc Called when the client sends an BYE after nkmedia_verto:invite/4
-spec nkmedia_verto_rejected(call_id(), nklib:proc_id(), verto()) ->
    {ok, verto()} | continue().

nkmedia_verto_rejected(_CallId, _ProcId, Verto) ->
    {ok, Verto}.


%% @doc Sends when the client sends a BYE during a call
-spec nkmedia_verto_bye(call_id(), nklib:proc_id(), verto()) ->
    {ok, verto()} | continue().

nkmedia_verto_bye(CallId, _ProcId, Verto) ->
    {ok, Verto}.


%% @doc
-spec nkmedia_verto_dtmf(call_id(), nklib:proc_id(), DTMF::binary(), verto()) ->
    {ok, verto()} | continue().

nkmedia_verto_dtmf(_CallId, _ProcId, _DTMF, Verto) ->
    {ok, Verto}.


%% @doc Called when the connection is stopped
-spec nkmedia_verto_terminate(Reason::term(), verto()) ->
    {ok, verto()}.

nkmedia_verto_terminate(_Reason, Verto) ->
    {ok, Verto}.


%% @doc 
-spec nkmedia_verto_handle_call(Msg::term(), {pid(), term()}, verto()) ->
    {ok, verto()} | continue().

nkmedia_verto_handle_call(Msg, _From, Verto) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {ok, Verto}.


%% @doc 
-spec nkmedia_verto_handle_cast(Msg::term(), verto()) ->
    {ok, verto()}.

nkmedia_verto_handle_cast(Msg, Verto) ->
    lager:error("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {ok, Verto}.


%% @doc 
-spec nkmedia_verto_handle_info(Msg::term(), verto()) ->
    {ok, Verto::map()}.

nkmedia_verto_handle_info(Msg, Verto) ->
    lager:error("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
    {ok, Verto}.




%% ===================================================================
%% Implemented Callbacks - error
%% ===================================================================

error_code(verto_bye) -> {0, <<"Verto BYE">>};
error_code(_) -> continue.



%% ===================================================================
%% Internal
%% ===================================================================


parse_listen(_Key, [{[{_, _, _, _}|_], Opts}|_]=Multi, _Ctx) when is_map(Opts) ->
    {ok, Multi};

parse_listen(verto_listen, Url, _Ctx) ->
    Opts = #{valid_schemes=>[verto], resolve_type=>listen},
    case nkpacket:multi_resolve(Url, Opts) of
        {ok, List} -> {ok, List};
        _ -> error
    end.





