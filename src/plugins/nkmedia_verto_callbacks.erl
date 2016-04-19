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

-export([plugin_deps/0, plugin_start/2, plugin_stop/2]).
-export([nkmedia_verto_init/2, nkmedia_verto_login/4, 
         nkmedia_verto_invite/5, nkmedia_verto_answer/4, nkmedia_verto_bye/2,
         nkmedia_verto_dtmf/3, nkmedia_verto_terminate/2,
         nkmedia_verto_handle_call/3, nkmedia_verto_handle_cast/2,
         nkmedia_verto_handle_info/2]).



%% ===================================================================
%% Types
%% ===================================================================

-type continue() :: continue | {continue, list()}.
-type call_id() :: binary().
-type sdp() :: binary().



%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia].


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA Verto (~s) starting", [Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA Verto (~p) stopping", [Name]),
    {ok, Config}.



%% ===================================================================
%% Verto Callbacks
%% ===================================================================

-type state() :: map().
-type dialog() :: map().


%% @doc Called when a new verto connection arrives
-spec nkmedia_verto_init(nkpacket:nkport(), state()) ->
    {ok, state()}.

nkmedia_verto_init(_NkPort, State) ->
    {ok, State}.


%% @doc Called when a login request is received
-spec nkmedia_verto_login(VertoSessId::binary(), Login::binary(), Pass::binary(),
                          state()) ->
    {boolean(), state()} | continue().

nkmedia_verto_login(_VertoId, _Login, _Pass, State) ->
    {false, State}.


%% @doc Called when the client sends an INVITE
%% If {ok, state()} is returned, we must call nkmedia_verto:answer/3 ourselves
-spec nkmedia_verto_invite(call_id(), Dest::binary(), sdp(), dialog(), state()) ->
    {ok, state()} | {answer, sdp(), state()} | 
    {bye, Code::integer(), state()} | continue().

nkmedia_verto_invite(_CallId, _Dest, _SDP, _Dialog, State) ->
    {bye, 501, State}.


%% @doc Called when the client sends an ANSWER
-spec nkmedia_verto_answer(call_id(), sdp(), dialog(), state()) ->
    {ok, state()} |{bye, Code::integer(), state()} | continue().

nkmedia_verto_answer(_CallId, _SDP, _Dialog, State) ->
    {bye, 501, State}.


%% @doc Sends when the client sends a BYE
-spec nkmedia_verto_bye(call_id(), state()) ->
    {ok, state()} | continue().

nkmedia_verto_bye(_CallId, State) ->
    {ok, State}.


%% @doc
-spec nkmedia_verto_dtmf(call_id(), DTMF::binary(), state()) ->
    {ok, state()} | continue().

nkmedia_verto_dtmf(_CallId, _DTMF, State) ->
    {ok, State}.


%% @doc Called when the connection is stopped
-spec nkmedia_verto_terminate(Reason::term(), state()) ->
    {ok, state()}.

nkmedia_verto_terminate(_Reason, State) ->
    {ok, State}.


%% @doc 
-spec nkmedia_verto_handle_call(Msg::term(), {pid(), term()}, state()) ->
    {ok, state()} | continue().

nkmedia_verto_handle_call(Msg, From, State) ->
    {continue, [Msg, From, State]}.


%% @doc 
-spec nkmedia_verto_handle_cast(Msg::term(), state()) ->
    {ok, state()}.

nkmedia_verto_handle_cast(Msg, State) ->
    {continue, [Msg, State]}.


%% @doc 
-spec nkmedia_verto_handle_info(Msg::term(), state()) ->
    {ok, State::map()}.

nkmedia_verto_handle_info(Msg, State) ->
    {continue, [Msg, State]}.