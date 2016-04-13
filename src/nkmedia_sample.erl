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

%% @doc 
-module(nkmedia_sample).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/0, stop/0]).
-export([plugin_deps/0, plugin_syntax/0, plugin_listen/2]).
-export([plugin_start/2, plugin_stop/2]).
-export([nkmedia_verto_init/2, nkmedia_verto_login/4, nkmedia_verto_invite/5]).
-export([nkmedia_verto_answer/4, nkmedia_verto_bye/2]).
-export([nkmedia_verto_dtmf/3, nkmedia_verto_terminate/2]).
-export([nkmedia_verto_handle_call/3]).


-include("nkmedia.hrl").


%% ===================================================================
%% Public
%% ===================================================================


start() ->
    _CertDir = code:priv_dir(nkpacket),
    Spec = #{
        plugins => [?MODULE],
        verto_listen => "verto:all:8082",
        % verto_listen => "verto_proxy:all:8082",
        verto_communicator => "https:all:8082/vc",
        % tls_keyfile => CertDir ++ "key.pem",
        % tls_certfile => CertDir ++ "cert.pem",
        % sip_trace => {console, all},
        log_level => debug
    },
    nkservice:start(verto_sample, Spec).


stop() ->
    nkservice:stop(verto_sample).


%% ===================================================================
%% Config callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia].


plugin_syntax() ->
    nkpacket:register_protocol(verto, nkmedia_verto_server),
    nkpacket:register_protocol(verto_proxy, nkmedia_verto_proxy_server),
    #{
        verto_listen => fun parse_listen/3,
        verto_communicator => fun parse_listen/3
    }.


plugin_listen(Config, #{id:=SrvId}) ->
    % verto_listen will be already parsed
    Listen1 = maps:get(verto_listen, Config, []),
    % With the 'user' parameter we tell nkmedia_verto_server protocol
    % to use the service callback module, so it will find
    % nkmedia_verto_* funs there.
    Opts1 = #{
        class => {nkmedia_verto_sample, SrvId},      
        get_headers => [<<"user-agent">>],
        idle_timeout => ?VERTO_WS_TIMEOUT,
        user => #{callback=>SrvId}     
    },                                  
    Listen2 = [{Conns, maps:merge(ConnOpts, Opts1)} || {Conns, ConnOpts} <- Listen1],
    Web1 = maps:get(verto_communicator, Config, []),
    Path1 = list_to_binary(code:priv_dir(nkmedia)),
    Path2 = <<Path1/binary, "/www/verto_communicator">>,
    Opts2 = #{
        class => {ncp_media_verto, SrvId},
        http_proto => {static, #{path=>Path2, index_file=><<"index.html">>}}
    },
    Web2 = [{Conns, maps:merge(ConnOpts, Opts2)} || {Conns, ConnOpts} <- Web1],
    Listen2 ++ Web2.


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin ~p (~s) starting", [?MODULE, Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin ~p (~p) stopping", [?MODULE, Name]),
    {ok, Config}.




%% ===================================================================
%% nkmedia_verto_server callbacks
%% ===================================================================

% %% The functions in this group are called from the nkmedia_verto_server
% %% protocol

nkmedia_verto_init(_NkPort, State) ->
    {ok, State#{calls=>#{}}}.


nkmedia_verto_login(VertoId, Login, Pass, State) ->
    lager:notice("Sample login: ~s, ~s, ~s", [Login, Pass, VertoId]),
    {ok, State#{user=>Login}}.


nkmedia_verto_invite(CallId, Dest, SDP, Dialog, #{user:=User}=State) ->
    lager:notice("INVITE ~s: ~s, ~s, ~p", [User, CallId, Dest, Dialog]),
    % nkmedia_verto_server:bye(self(), CallId),
    [{_, Pid}] = nkmedia_verto_server:get_user(<<"1009@localhost">>),
    gen_server:call(Pid, {sample_invite, CallId, SDP, Dialog, self()}),
    {ok, State}.

nkmedia_verto_answer(CallId, SDP, Dialog, #{user:=User}=State) ->
    lager:notice("ANSWER ~s: ~s, ~p", [User, CallId, Dialog]),
    case State of
        #{call:=Pid} ->
            nkmedia_verto_server:answer(Pid, CallId, SDP, Dialog);
        _ ->
            lager:error("NO CALL")            
    end,
    {ok, State}.
    
nkmedia_verto_bye(CallId, #{user:=User}=State) ->
    lager:notice("BYE ~s: ~s", [User, CallId]),
    {ok, State}.


nkmedia_verto_dtmf(CallId, DTMF, #{user:=User}=State) ->
    lager:notice("DTMF: ~s, ~s", [User, CallId, DTMF]),
    {ok, State}.


nkmedia_verto_terminate(Reason, #{user:=User}=State) ->
    lager:notice("TERMINATE ~s: ~p", [User, Reason]),
    {ok, maps:remove(ncp_media_verto, State)}.


nkmedia_verto_handle_call({sample_invite, CallId, SDP, Dialog, Pid}, From, #{user:=User}=State) ->
    lager:notice("MAKE INVITE ~s", [User]),
    Self = self(),
    spawn(fun() -> nkmedia_verto_server:invite(Self, CallId, SDP, Dialog) end),
    gen_server:reply(From, ok),
    {ok, State#{call=>Pid}}.




%% ===================================================================
%% Internal
%% ===================================================================


parse_listen(_Key, [{[{_, _, _, _}|_], Opts}|_]=Multi, _Ctx) when is_map(Opts) ->
    {ok, Multi};

parse_listen(Key, Url, _Ctx) ->
    Schemes = case Key of
        verto_listen -> [verto, verto_proxy];
        verto_communicator -> [https]
    end,
    Opts = #{valid_schemes=>Schemes, resolve_type=>listen},
    case nkpacket:multi_resolve(Url, Opts) of
        {ok, List} -> {ok, List};
        _ -> error
    end.


