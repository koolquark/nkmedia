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

%% @doc NkMEDIA Docker management application
-module(nkmedia_janus_docker).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/0, start/1, stop/1]).
-export([defaults/1]).



%% ===================================================================
%% Types    
%% ===================================================================

%% ===================================================================
%% Freeswitch Instance
%% ===================================================================
        

%% @doc Starts a FS instance
-spec start() ->
    {ok, Name::binary()} | {error, term()}.

start() ->
    start(#{}).


%% @doc Starts a FS instance
-spec start(nkmedia_fs:config()) ->
    {ok, Name::binary()} | {error, term()}.

start(Config) ->
    Config2 = defaults(Config),
    Image = nkmedia_fs_build:run_image_name(Config2),
    ErlangIp = nklib_util:to_host(nkmedia_app:get(erlang_ip)),
    _MainIp = nklib_util:to_host(nkmedia_app:get(main_ip)),
    FsIp = case nkmedia_app:get(docker_ip) of
        {127,0,0,1} ->
            Byte1 = crypto:rand_uniform(1, 255),
            Byte2 = crypto:rand_uniform(1, 255),
            Byte3 = crypto:rand_uniform(1, 255),
            nklib_util:to_host({127, Byte1, Byte2, Byte3});
        DockerIp ->
            nklib_util:to_host(DockerIp)
    end,
    Name = list_to_binary(["nk_fs_", nklib_util:hash({Image, FsIp})]),
    ExtIp = nklib_util:to_host(nkpacket_app:get(ext_ip)),
    #{pass:=Pass} = Config2,
    Env = [
        {"NK_FS_IP", FsIp},                 %% 127.X.Y.Z except in dev mode
        {"NK_ERLANG_IP", ErlangIp},         %% 127.0.0.1 except in dev mode
        {"NK_RTP_IP", "$${local_ip_v4}"},       
        {"NK_EXT_IP", ExtIp},  
        {"NK_PASS", nklib_util:to_list(Pass)}
    ],
    Labels = [
        {"nkmedia", "freeswitch"}
    ],
    % Cmds = ["bash"],
    Cmds = ["bash", "/usr/local/freeswitch/start.sh"],
    DockerOpts = #{
        name => Name,
        env => Env,
        cmds => Cmds,
        net => host,
        interactive => true,
        labels => Labels
    },
    case get_docker_pid() of
        {ok, DockerPid} ->
            nkdocker:rm(DockerPid, Name),
            case nkdocker:create(DockerPid, Image, DockerOpts) of
                {ok, _} -> 
                    lager:info("NkMEDIA FS Docker: starting instance ~s", [Name]),
                    case nkdocker:start(DockerPid, Name) of
                        ok ->
                            {ok, Name};
                        {error, Error} ->
                            {error, Error}
                    end;
                {error, Error} -> 
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @doc Stops a FS instance
-spec stop(binary()) ->
    ok | {error, term()}.

stop(Name) ->    
    case get_docker_pid() of
        {ok, DockerPid} ->
            case nkdocker:kill(DockerPid, Name) of
                ok -> ok;
                {error, {not_found, _}} -> ok;
                E1 -> lager:warning("NkMEDIA could not kill ~s: ~p", [Name, E1])
            end,
            case nkdocker:rm(DockerPid, Name) of
                ok -> ok;
                {error, {not_found, _}} -> ok;
                E2 -> lager:warning("NkMEDIA could not remove ~s: ~p", [Name, E2])
            end,
            ok;
        {error, Error} ->
            {error, Error}
    end.



%% @private
-spec get_docker_pid() ->
    {ok, pid()} | {error, term()}.

get_docker_pid() ->
    DockerMonId = nkmedia_app:get(docker_mon_id),
    nkdocker_monitor:get_docker(DockerMonId).



%% @private
-spec defaults(map()) ->
    nkmedia_fs:config().

defaults(Config) ->
    Defs = #{
        comp => nkmedia_app:get(docker_company), 
        vsn => nkmedia_app:get(janus_version), 
        rel => nkmedia_app:get(janus_release)
    },
    maps:merge(Defs, Config).




