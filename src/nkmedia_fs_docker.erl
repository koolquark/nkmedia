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
-module(nkmedia_fs_docker).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/0, start/2, stop/0, stop/1]).



%% ===================================================================
%% Freeswitch Instance
%% ===================================================================
        

%% @doc Starts a FS instance
start() ->
    Pass = nklib_util:hash(make_ref()),
    start("netcomposer/nk_freeswitch:v1.6.5-r01", Pass).


%% @doc Starts a FS instance
start(Image, Pass) ->
    LocalHost = nklib_util:to_host(nkmedia_app:get(local_ip)),
    case nkmedia_app:get(docker_ip) of
        {127,0,0,1} ->
            Byte1 = crypto:rand_uniform(1, 255),
            Byte2 = crypto:rand_uniform(1, 255),
            Byte3 = crypto:rand_uniform(1, 255),
            FsHost = nklib_util:to_host({127, Byte1, Byte2, Byte3}),
            Name = list_to_binary(["nk_freeswitch_", nklib_util:hash(FsHost)]);
        FsHost ->
            Name = "nk_freeswitch"

    end,
    ExtIp = nklib_util:to_host(nkpacket_app:get(ext_ip)),
    Env = [
        {"NK_HOST_IP", LocalHost},   
        {"NK_LOCAL_IP", FsHost},     
        {"NK_EXT_IP", ExtIp},  
        {"NK_PASS", nklib_util:to_list(Pass)}
    ],
    Labels = [
        {"nkmedia", "freeswitch"}
    ],
    Cmds = ["bash", "/usr/local/freeswitch/start.sh"],
    DockerOpts = #{
        name => Name,
        env => Env,
        cmds => Cmds,
        net => host,
        interactive => true,
        labels => Labels
    },
    lager:info("NkMEDIA FS Docker: creating instance ~s", [Name]),
    case nkdocker:start_link(#{}) of
        {ok, Pid} ->
            nkdocker:rm(Pid, Name),
            Res = case nkdocker:create(Pid, Image, DockerOpts) of
                {ok, _} -> 
                    lager:info("NkMEDIA FS Docker: starting ~s", [Name]),
                    nkdocker:start(Pid, Name);
                {error, Error} -> 
                    {error, Error}
            end,
            nkdocker:stop(Pid),
            Res;
        {error, Error} ->
            {error, Error}
    end.


%% @doc Stops a FS instance
stop() ->
    stop("nk_freeswitch").


%% @doc Stops a FS instance
stop(Name) ->
    case nkdocker:start_link(#{}) of
        {ok, Pid} ->
            case nkdocker:kill(Pid, Name) of
                ok -> ok;
                {error, {not_found, _}} -> ok;
                E1 -> lager:warning("NkMEDIA could not kill ~s: ~p", [Name, E1])
            end,
            case nkdocker:rm(Pid, Name) of
                ok -> ok;
                {error, {not_found, _}} -> ok;
                E2 -> lager:warning("NkMEDIA could not remove ~s: ~p", [Name, E2])
            end,
            nkdocker:stop(Pid);
        {error, Error} ->
            {error, Error}
    end.




