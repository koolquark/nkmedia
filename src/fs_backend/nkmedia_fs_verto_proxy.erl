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

%% @doc Plugin implementing a Kurento proxy server for testing
-module(nkmedia_fs_verto_proxy).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_syntax/0, plugin_listen/2, 
         plugin_start/2, plugin_stop/2]).
-export([nkmedia_fs_verto_proxy_init/2, nkmedia_fs_verto_proxy_find_fs/2,
         nkmedia_fs_verto_proxy_in/2, nkmedia_fs_verto_proxy_out/2, 
         nkmedia_fs_verto_proxy_terminate/2, nkmedia_fs_verto_proxy_handle_call/3,
         nkmedia_fs_verto_proxy_handle_cast/2, nkmedia_fs_verto_proxy_handle_info/2]).


-define(WS_TIMEOUT, 60*60*1000).
-include_lib("nkservice/include/nkservice.hrl").



%% ===================================================================
%% Types
%% ===================================================================

-type state() :: term().
-type continue() :: continue | {continue, list()}.

%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia_fs].


plugin_syntax() ->
    nkpacket:register_protocol(verto_proxy, nkmedia_fs_verto_proxy_server),
    #{
        verto_proxy => fun parse_listen/3
    }.


plugin_listen(Config, #{id:=SrvId}) ->
    % verto_proxy will be already parsed
    Listen = maps:get(verto_proxy, Config, []),
    % With the 'user' parameter we tell nkmedia_kurento protocol
    % to use the service callback module, so it will find
    % nkmedia_kurento_* funs there.
    Opts = #{
        class => {nkmedia_fs_verto_proxy, SrvId},
        idle_timeout => ?WS_TIMEOUT
    },                                  
    [{Conns, maps:merge(ConnOpts, Opts)} || {Conns, ConnOpts} <- Listen].
    


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA FS VERTO Proxy (~s) starting", [Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA FS VERTO Proxy (~p) stopping", [Name]),
    {ok, Config}.



%% ===================================================================
%% Offering callbacks
%% ===================================================================



%% @doc Called when a new KMS proxy connection arrives
-spec nkmedia_fs_verto_proxy_init(nkpacket:nkport(), state()) ->
    {ok, state()}.

nkmedia_fs_verto_proxy_init(_NkPort, State) ->
    {ok, State}.


%% @doc Called to select a KMS server
-spec nkmedia_fs_verto_proxy_find_fs(nkmedia_service:id(), state()) ->
    {ok, [nkmedia_fs_verto_engine:id()], state()}.

nkmedia_fs_verto_proxy_find_fs(SrvId, State) ->
    List = [Name || {Name, _} <- nkmedia_fs_engine:get_all(SrvId)],
    {ok, List, State}.


%% @doc Called when a new msg arrives
-spec nkmedia_fs_verto_proxy_in(map(), state()) ->
    {ok, map(), state()} | {stop, term(), state()} | continue().

nkmedia_fs_verto_proxy_in(Msg, State) ->
    {ok, Msg, State}.


%% @doc Called when a new msg is to be answered
-spec nkmedia_fs_verto_proxy_out(map(), state()) ->
    {ok, map(), state()} | {stop, term(), state()} | continue().

nkmedia_fs_verto_proxy_out(Msg, State) ->
    {ok, Msg, State}.


%% @doc Called when the connection is stopped
-spec nkmedia_fs_verto_proxy_terminate(Reason::term(), state()) ->
    {ok, state()}.

nkmedia_fs_verto_proxy_terminate(_Reason, State) ->
    {ok, State}.


%% @doc 
-spec nkmedia_fs_verto_proxy_handle_call(Msg::term(), {pid(), term()}, state()) ->
    {ok, state()} | continue().

nkmedia_fs_verto_proxy_handle_call(Msg, _From, State) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {ok, State}.


%% @doc 
-spec nkmedia_fs_verto_proxy_handle_cast(Msg::term(), state()) ->
    {ok, state()}.

nkmedia_fs_verto_proxy_handle_cast(Msg, State) ->
    lager:error("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {ok, State}.


%% @doc 
-spec nkmedia_fs_verto_proxy_handle_info(Msg::term(), state()) ->
    {ok, State::map()}.

nkmedia_fs_verto_proxy_handle_info(Msg, State) ->
    lager:error("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
    {ok, State}.





%% ===================================================================
%% Internal
%% ===================================================================


parse_listen(_Key, [{[{_, _, _, _}|_], Opts}|_]=Multi, _Ctx) when is_map(Opts) ->
    {ok, Multi};

parse_listen(verto_proxy, Url, _Ctx) ->
    Opts = #{valid_schemes=>[verto_proxy], resolve_type=>listen},
    case nkpacket:multi_resolve(Url, Opts) of
        {ok, List} -> {ok, List};
        _ -> error
    end.





