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

-export([start/0, start/4, stop/0, stop/3]).
-export([get_image_parts/0]).



%% ===================================================================
%% Freeswitch Instance
%% ===================================================================
        

%% @doc Starts a FS instance
start() ->
    {Comp, Vsn, Rel} = get_image_parts(),
    Pass = nklib_util:hash(make_ref()),
    start(Comp, Vsn, Rel, Pass).


%% @doc Starts a FS instance
start(Comp, Vsn, Rel, Pass) ->
    Image = nkmedia_fs_build:run_image_name(Comp, Vsn, Rel),
    ErlangIp = nklib_util:to_host(nkmedia_app:get(erlang_ip)),
    MainIp = nklib_util:to_host(nkmedia_app:get(main_ip)),
    case nkmedia_app:get(docker_ip) of
        {127,0,0,1} ->
            Byte1 = crypto:rand_uniform(1, 255),
            Byte2 = crypto:rand_uniform(1, 255),
            Byte3 = crypto:rand_uniform(1, 255),
            FsIp = nklib_util:to_host({127, Byte1, Byte2, Byte3}),
            Name = list_to_binary([
                "nk_fs_", 
                integer_to_list(Byte1), "_",
                integer_to_list(Byte2), "_",
                integer_to_list(Byte3)
            ]);
        DockerIp ->
            FsIp = nklib_util:to_host(DockerIp),
            Name = "nk_fs_dev"

    end,
    ExtIp = nklib_util:to_host(nkpacket_app:get(ext_ip)),
    Env = [
        {"NK_FS_IP", FsIp},                 %% 127.X.Y.Z except in dev mode
        {"NK_ERLANG_IP", ErlangIp},         %% 127.0.0.1 except in dev mode
        {"NK_RTP_IP", MainIp},       
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
                    nkdocker:start(DockerPid, Name);
                {error, Error} -> 
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @doc Stops a dev FS instance
stop() ->
    stop(<<"nk_fs_dev">>).


%% @doc Stops a X_Y_Z FS instance
stop(A, B, C) ->
    Name = list_to_binary([
        "nk_fs_", 
        integer_to_list(A), "_",
        integer_to_list(B), "_",
        integer_to_list(C)
    ]),
    stop(Name).


%% @doc Stops a FS instance
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
get_image_parts() ->
    {
        nkmedia_app:get(docker_company), 
        nkmedia_app:get(fs_version), 
        nkmedia_app:get(fs_release)
    }.




