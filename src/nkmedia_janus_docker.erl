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

-export([start/1, stop/1, stop_all/0]).
-export([defaults/1, notify/4]).

-include("nkmedia.hrl").


%% ===================================================================
%% Types    
%% ===================================================================

%% ===================================================================
%% Freeswitch Instance
%% ===================================================================
        

%% @doc Starts a JANUS instance
%% BASE+0: WS port
%% BASE+1: WS admin port
-spec start(nkmedia_janus:config()) ->
    {ok, Name::binary()} | {error, term()}.

start(Config) ->
    Config2 = defaults(Config),
    Image = nkmedia_janus_build:run_image_name(Config2),
    JanusIp  = nklib_util:to_host(nkmedia_app:get(docker_ip)),
    #{base:=Base, pass:=Pass} = Config2,
    Name = list_to_binary(["nk_janus_", nklib_util:to_binary(Base)]),
    LogDir = <<(nkmedia_app:get(log_dir))/binary, $/, Name/binary>>,
    ok = filelib:ensure_dir(<<LogDir/binary, "dummy">>),
    _ExtIp = nklib_util:to_host(nkpacket_app:get(ext_ip)),
    #{pass:=Pass} = Config2,
    Env = [
        {"NK_JANUS_IP", JanusIp},             
        {"NK_EXT_IP", "192.168.0.102"}, %_ExtIp},  
        {"NK_PASS", nklib_util:to_binary(Pass)},
        {"NK_BASE", nklib_util:to_binary(Base)}
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
        labels => Labels,
        volumes => [{LogDir, "/var/log/janus"}]
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


%% @doc
stop_all() ->
    case get_docker_pid() of
        {ok, DockerPid} ->
            {ok, List} = nkdocker:ps(DockerPid),
            lists:foreach(
                fun(#{<<"Names">>:=[<<"/", Name/binary>>]}) ->
                    case Name of
                        <<"nk_janus_", _/binary>> ->
                            lager:info("Stopping ~s", [Name]),
                            stop(Name);
                        _ -> 
                            ok
                    end
                end,
                List);
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
    nkmedia_janus:config().

defaults(Config) ->
    Defs = #{
        comp => nkmedia_app:get(docker_company), 
        vsn => nkmedia_app:get(janus_version), 
        rel => nkmedia_app:get(janus_release),
        base => ?JANUS_DEF_BASE,
        pass => nklib_util:luid()
    },
    maps:merge(Defs, Config).


notify(MonId, ping, Name, Data) ->
    notify(MonId, start, Name, Data);

notify(MonId, start, Name, Data) ->
    case Data of
        #{
            name := Name,
            labels := #{<<"nkmedia">> := <<"janus">>},
            env := #{
                <<"NK_JANUS_IP">> := Host, 
                <<"NK_BASE">> := Base, 
                <<"NK_PASS">> := Pass
            },
            image := Image
        } ->
            case binary:split(Image, <<"/">>) of
                [_Comp, <<"nk_janus_run:", Rel/binary>>] -> 
                    Config = #{
                        name => Name, 
                        rel => Rel, 
                        host => Host, 
                        base => nklib_util:to_integer(Base),
                        pass => Pass
                    },
                    connect_janus(MonId, Config);
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
