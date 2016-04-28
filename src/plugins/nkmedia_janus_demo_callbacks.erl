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

-module(nkmedia_janus_demo_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_syntax/0, plugin_listen/2, 
         plugin_start/2, plugin_stop/2]).


-define(JANUS_WS_TIMEOUT, 60*60*1000).


%% ===================================================================
%% Types
%% ===================================================================

% -type continue() :: continue | {continue, list()}.



%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia].


plugin_syntax() ->
    nkpacket:register_protocol(janus, nkmedia_janus_demo),
    nkpacket:register_protocol(janus_proxy, nkmedia_janus_proxy_server),
    #{
        janus_listen => fun parse_listen/3,
        janus_demos => fun parse_listen/3
    }.


plugin_listen(Config, #{id:=SrvId}) ->
    % janus_listen will be already parsed
    Listen1 = maps:get(janus_listen, Config, []),
    Opts1 = #{
        class => {nkmedia_janus, SrvId},
        % get_headers => [<<"user-agent">>],
        idle_timeout => ?JANUS_WS_TIMEOUT,
        ws_proto => <<"janus-protocol">>
    },                                  
    Listen2 = [{Conns, maps:merge(ConnOpts, Opts1)} || {Conns, ConnOpts} <- Listen1],     
    Web1 = maps:get(janus_demos, Config, []),
    Path1 = list_to_binary(code:priv_dir(nkmedia)),
    Path2 = <<Path1/binary, "/www/janus">>,
    Opts2 = #{
        class => {nkmedia_janus_demos, SrvId},
        http_proto => {static, #{path=>Path2, index_file=><<"index.html">>}}
    },
    Web2 = [{Conns, maps:merge(ConnOpts, Opts2)} || {Conns, ConnOpts} <- Web1],
    Listen2++Web2.


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA Janus Demo (~s) starting", [Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA Janus Demo (~p) stopping", [Name]),
    {ok, Config}.



%% ===================================================================
%% Offering Callbacks
%% ===================================================================


%% ===================================================================
%% Internal
%% ===================================================================


parse_listen(_Key, [{[{_, _, _, _}|_], Opts}|_]=Multi, _Ctx) when is_map(Opts) ->
    {ok, Multi};

parse_listen(Key, Url, _Ctx) ->
    Schemes = case Key of
        janus_listen -> [janus, janus_proxy];
        janus_demos -> [http, https]
    end,
    Opts = #{valid_schemes=>Schemes, resolve_type=>listen},
    case nkpacket:multi_resolve(Url, Opts) of
        {ok, List} -> {ok, List};
        _ -> error
    end.


