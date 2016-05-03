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

-export([start/0, start/1, stop/1, stop/0]).
-export([defaults/1, notify/4]).

-include("nkmedia.hrl").

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



%% Stop running instance (development only)
stop() ->
    Image = nkmedia_fs_build:run_image_name(#{}),
    FsIp = case nkmedia_app:get(docker_ip) of
        {127,0,0,1} ->
            error(no_dev_mode);
        DockerIp ->
            nklib_util:to_host(DockerIp)
    end,
    Name = list_to_binary(["nk_fs_", nklib_util:hash({Image, FsIp})]),
    stop(Name).


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
        vsn => nkmedia_app:get(fs_version), 
        rel => nkmedia_app:get(fs_release),
        pass => nklib_util:uid()
    },
    maps:merge(Defs, Config).



%% @private
notify(MonId, ping, Name, Data) ->
    notify(MonId, start, Name, Data);

notify(MonId, start, Name, Data) ->
    case Data of
        #{
            name := Name,
            labels := #{<<"nkmedia">> := <<"freeswitch">>},
            env := #{<<"NK_FS_IP">> := Host, <<"NK_PASS">> := Pass},
            image := Image
        } ->
            case binary:split(Image, <<"/">>) of
                [_Comp, <<"nk_freeswitch_run:", Rel/binary>>] -> 
                    case lists:member(Rel, ?SUPPORTED_FS) of
                        true ->
                            Config = #{name=>Name, rel=>Rel, host=>Host, pass=>Pass},
                            connect_fs(MonId, Config);
                        false ->
                            lager:warning("Started unsupported nk_freeswitch")
                    end;
                _ ->
                    lager:warning("Started unrecognized nk_freeswitch")
            end;
        _ ->
            lager:warning("Started unrecognized nk_freeswitch")
    end;

notify(MonId, stop, Name, Data) ->
    case Data of
        #{
            name := Name,
            labels := #{<<"nkmedia">> := <<"freeswitch">>}
            % env := #{<<"NK_FS_IP">> := Host}
        } ->
            remove_fs(MonId, Name);
        _ ->
            ok
    end;

notify(_MonId, stats, Name, Stats) ->
    nkmedia_fs_engine:stats(Name, Stats).



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
connect_fs(MonId, #{name:=Name}=Config) ->
    spawn(
        fun() -> 
            timer:sleep(2000),
            case nkmedia_fs_engine:connect(Config) of
                {ok, _Pid} -> 
                    ok = nkdocker_monitor:start_stats(MonId, Name);
                {error, Error} -> 
                    lager:warning("Could not connect to Freeswitch ~s: ~p", 
                                  [Name, Error])
            end
        end),
    ok.


%% @private
remove_fs(MonId, Name) ->
    spawn(
        fun() ->
            nkmedia_fs_engine:stop(Name),
            case nkdocker_monitor:get_docker(MonId) of
                {ok, Pid} -> 
                    nkdocker:rm(Pid, Name);
                _ -> 
                    ok
            end
        end),
    ok.

