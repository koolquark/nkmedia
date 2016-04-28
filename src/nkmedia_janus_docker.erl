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

-export([start/0, start/1, stop/1, stop/0]).
-export([defaults/1, restart/0, notify/4]).

-include("nkmedia.hrl").


%% ===================================================================
%% Types    
%% ===================================================================

%% ===================================================================
%% Freeswitch Instance
%% ===================================================================
        

%% @doc Starts a JANUS instance
-spec start() ->
    {ok, Name::binary()} | {error, term()}.

start() ->
    start(#{}).


%% @doc Starts a JANUS instance
-spec start(nkmedia_janus:config()) ->
    {ok, Name::binary()} | {error, term()}.

start(Config) ->
    Config2 = defaults(Config),
    Image = nkmedia_janus_build:run_image_name(Config2),
    ErlangIp = nklib_util:to_host(nkmedia_app:get(erlang_ip)),
    MainIp = nklib_util:to_host(nkmedia_app:get(main_ip)),
    FsIp = case nkmedia_app:get(docker_ip) of
        {127,0,0,1} ->
            Byte1 = crypto:rand_uniform(1, 255),
            Byte2 = crypto:rand_uniform(1, 255),
            Byte3 = crypto:rand_uniform(1, 255),
            nklib_util:to_host({127, Byte1, Byte2, Byte3});
        DockerIp ->
            nklib_util:to_host(DockerIp)
    end,
    Name = list_to_binary(["nk_janus_", nklib_util:hash({Image, FsIp})]),
    ExtIp = nklib_util:to_host(nkpacket_app:get(ext_ip)),
    #{pass:=Pass} = Config2,
    Env = [
        {"NK_JANUS_IP", FsIp},                 %% 127.X.Y.Z except in dev mode
        {"NK_ERLANG_IP", ErlangIp},         %% 127.0.0.1 except in dev mode
        {"NK_RTP_IP", MainIp},       
        {"NK_EXT_IP", ExtIp},  
        {"NK_PASS", nklib_util:to_list(Pass)}
    ],
    Labels = [
        {"nkmedia", "janus"}
    ],
    % Cmds = ["bash"],
    DockerOpts = #{
        name => Name,
        env => Env,
        net => host,
        interactive => true,
        labels => Labels
    },
    case get_docker_pid() of
        {ok, DockerPid} ->
            nkdocker:rm(DockerPid, Name),
            case nkdocker:create(DockerPid, Image, DockerOpts) of
                {ok, _} -> 
                    lager:info("NkMEDIA Janus Docker: starting instance ~s", [Name]),
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


stop() ->
    Image = nkmedia_janus_build:run_image_name(#{}),
    FsIp = case nkmedia_app:get(docker_ip) of
        {127,0,0,1} ->
            error(no_dev_mode);
        DockerIp ->
            nklib_util:to_host(DockerIp)
    end,
    Name = list_to_binary(["nk_janus_", nklib_util:hash({Image, FsIp})]),
    stop(Name).



%% @doc Stops a JANUS instance
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


restart() ->
    stop(),
    nkmedia_janus_build:remove_run_image(),
    nkmedia_janus_build:build_run_image(),
    start().






%% @private
-spec get_docker_pid() ->
    {ok, pid()} | {error, term()}.

get_docker_pid() ->
    DockerMonId = nkmedia_app:get(docker_mon_id),
    nkdocker_monitor:get_docker(DockerMonId).



%% @private
-spec defaults(map()) ->
    nkmedia_janus:config().

defaults(Config) ->
    Defs = #{
        comp => nkmedia_app:get(docker_company), 
        vsn => nkmedia_app:get(janus_version), 
        rel => nkmedia_app:get(janus_release),
        pass => nklib_util:uid()
    },
    maps:merge(Defs, Config).


notify(MonId, ping, Name, Data) ->
    notify(MonId, start, Name, Data);

notify(MonId, start, Name, Data) ->
    case Data of
        #{
            name := Name,
            labels := #{<<"nkmedia">> := <<"janus">>},
            env := #{<<"NK_JANUS_IP">> := Host, <<"NK_PASS">> := Pass},
            image := Image
        } ->
            case binary:split(Image, <<"/">>) of
                [_Comp, <<"nk_janus_run:", Rel/binary>>] -> 
                    case lists:member(Rel, ?SUPPORTED_JANUS) of
                        true ->
                            Config = #{name=>Name, rel=>Rel, host=>Host, pass=>Pass},
                            connect_janus(MonId, Config);
                        false ->
                            lager:warning("Started unsupported nk_janus")
                    end;
                _ ->
                    lager:warning("Started unrecognized nk_janus")
            end;
        _ ->
            lager:warning("Started unrecognized nk_janus")
    end;

notify(MonId, stop, Name, Data) ->
    case Data of
        #{
            name := Name,
            labels := #{<<"nkmedia">> := <<"janus">>}
            % env := #{<<"NK_FS_IP">> := Host}
        } ->
            remove_janus(MonId, Name);
        _ ->
            ok
    end;

notify(_MonId, stats, _Name, _Stats) ->
    ok.




%% ===================================================================
%% Internal
%% ===================================================================

%% @private
connect_janus(MonId, #{name:=Name}=Config) ->
    spawn(
        fun() -> 
            % timer:sleep(2000),
            case nkmedia_janus_engine:connect(Config) of
                {ok, _Pid} -> 
                    ok = nkdocker_monitor:start_stats(MonId, Name);
                {error, {already_started, _Pid}} ->
                    ok;
                {error, Error} -> 
                    lager:warning("Could not connect to Janus ~s: ~p", 
                                  [Name, Error])
            end
        end),
    ok.


%% @private
remove_janus(MonId, Name) ->
    spawn(
        fun() ->
            nkmedia_janus_engine:stop(Name),
            case nkdocker_monitor:get_docker(MonId) of
                {ok, Pid} -> 
                    nkdocker:rm(Pid, Name);
                _ -> 
                    ok
            end
        end),
    ok.
