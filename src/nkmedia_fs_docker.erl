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

-export([launch/0]).



%% ===================================================================
%% Freeswitch Instance
%% ===================================================================
        

launch() ->
    launch("netcomposer/nk_freeswitch:v1.6.5-r01", "7777").



launch(Image, Pass) ->
    LocalHost = nkmedia_app:get(local_host),
    case nkmedia_app:get(docker_host) of
        <<"127.0.0.1">> ->
            Byte1 = crypto:rand_uniform(1, 255),
            Byte2 = crypto:rand_uniform(1, 255),
            Byte3 = crypto:rand_uniform(1, 255),
            FsHost = nklib_util:to_host({127, Byte1, Byte2, Byte3}),
            Name = list_to_binary(["nk_freeswitch", nklib_util:hash(FsHost)]);
        FsHost ->
            Name = "nk_freeswitch"

    end,
    ExtIp = nklib_util:to_host(nkpacket_app:get(ext_ip)),
    Env = [
        {"NK_HOST_IP", LocalHost},    % 127.0.0.1 usually
        {"NK_LOCAL_IP", FsHost},      % 127.0.0.1 usually
        {"NK_EXT_IP", ExtIp},  
        {"NK_PASS", nklib_util:to_list(Pass)}
    ],
    Cmds = ["bash", "/usr/local/freeswitch/start.sh"],
    DockerOpts = #{
        name => Name,
        env => Env,
        cmds => Cmds,
        net => host,
        interactive => true
    },
    lager:info("NkMEDIA FS Docker: creating instance ~s", [Name]),
    case nkdocker:start_link(#{}) of
        {ok, Pid} ->
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







% %% @doc Starts a docker instance
% -spec start(nkmedia_fs:start_opts(), pid()) ->
%     ok | {error, term()}.

% start(Spec, Docker) ->
%     case build_fs_instance(Docker, Spec) of
%         ok ->
%             RunName = fs_run_name(Spec),
%             case nkdocker:inspect(Docker, RunName) of
%                 {ok, #{<<"State">> := #{<<"Running">>:=true}}} -> 
%                     {error, already_running};
%                 {ok, _} ->
%                     lager:info("NkMEDIA FS Docker: removing ~s", [RunName]),
%                     case nkdocker:rm(Docker, RunName) of
%                         ok -> 
%                             launch(Docker, Spec);
%                         {error, Error} ->
%                             {error, Error}
%                     end;
%                 {error, {not_found, _}} -> 
%                     launch(Docker, Spec);
%                 {error, Error} ->
%                     {error, Error}
%             end;
%         {error, Error} ->
%             {error, Error}
%     end.


% %% @doc Stops the instance
% -spec stop(nkmedia_fs:start_opts(), pid()) ->
%     ok.

% stop(Spec, Docker) ->
%     Name = fs_run_name(Spec),
%     case nkdocker:kill(Docker, Name) of
%         ok -> ok;
%         {error, {not_found, _}} -> ok;
%         E1 -> lager:warning("NkMEDIA could not kill ~s: ~p", [Name, E1])
%     end,
%     case nkdocker:rm(Docker, Name) of
%         ok -> ok;
%         {error, {not_found, _}} -> ok;
%         E2 -> lager:warning("NkMEDIA could not remove ~s: ~p", [Name, E2])
%     end,
%     ok.

    

% %% @private
% -spec build_base(nkmedia_fs:start_opts(), pid()) ->
%     ok | {error, term()}.

% build_base(Spec, Docker) ->
%     build_fs_base(Docker, Spec).



% %% @doc Stops and removes a freeswitch instance and removes images
% remove(Spec, Docker) ->
%     stop(Spec, Docker),
%     InstName = fs_instance_name(Spec),
% 	case nkdocker:rmi(Docker, InstName, #{force=>true}) of
% 		{ok, _} -> ok;
% 		{error, {not_found, _}} -> ok;
% 		E3 -> lager:warning("NkMEDIA could not remove ~s: ~p", [InstName, E3])
% 	end.

