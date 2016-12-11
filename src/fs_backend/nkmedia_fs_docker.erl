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

-export([start/1, stop/1, stop_all/0]).
-export([notify/4, check_started/1]).

-include("../../include/nkmedia.hrl").

%% ===================================================================
%% Types    
%% ===================================================================

%% ===================================================================
%% Freeswitch Instance
%% ===================================================================
        

%% @doc Starts a FS instance
%% BASE+0: Event port
%% BASE+1: WS verto port
%% BASE+2: SIP Port
-spec start(nkservice:name()) ->
    {ok, Name::binary()} | {error, term()}.

start(Service) ->
    try
        SrvId = case nkservice_srv:get_srv_id(Service) of
            {ok, SrvId0} -> SrvId0;
            not_found -> throw(unknown_service)
        end,
        Config = nkservice_srv:get_item(SrvId, config_nkmedia_fs),
        BasePort = crypto:rand_uniform(32768, 65535),
        Pass = nklib_util:luid(),
        Image = nkmedia_fs_build:run_name(Config),
        ErlangIp = nklib_util:to_host(nkmedia_app:get(erlang_ip)),
        FsIp = nklib_util:to_host(nkmedia_app:get(docker_ip)),
        Name = list_to_binary([
            "nk_fs_", 
            nklib_util:to_binary(SrvId), "_",
            nklib_util:to_binary(BasePort)
        ]),
        LogDir = <<(nkmedia_app:get(log_dir))/binary, $/, Name/binary>>,
        ExtIp = nklib_util:to_host(nkpacket_app:get(ext_ip)),
        Env = [
            {"NK_FS_IP", FsIp},                
            {"NK_ERLANG_IP", ErlangIp},         
            {"NK_RTP_IP", "$${local_ip_v4}"},       
            {"NK_EXT_IP", ExtIp},  
            {"NK_BASE", nklib_util:to_binary(BasePort)},
            {"NK_PASS", nklib_util:to_binary(Pass)},
            {"NK_SRV_ID", nklib_util:to_binary(SrvId)}
        ],
        Labels = [
            {"nkmedia", "freeswitch"}
        ],
        % Cmds = ["bash"],
        Cmds = ["bash", "/usr/local/freeswitch/start.sh"],
        DockerOpts1 = #{
            name => Name,
            env => Env,
            cmds => Cmds,
            net => host,
            interactive => true,
            labels => Labels,
            volumes => [{LogDir, "/usr/local/freeswitch/log"}],
            restart => {on_failure, 3}
        },
        DockerOpts2 = case nkmedia_app:get(docker_log) of
            undefined -> DockerOpts1;
            DockerLog -> DockerOpts1#{docker_log=>DockerLog}
        end,
        DockerPid = case get_docker_pid() of
            {ok, DockerPid0} -> DockerPid0;
            {error, Error1} -> throw(Error1)
        end,
        nkdocker:rm(DockerPid, Name),
        case nkdocker:create(DockerPid, Image, DockerOpts2) of
            {ok, _} -> ok;
            {error, Error2} -> throw(Error2)
        end,
        lager:info("NkMEDIA FS Docker: starting instance ~s", [Name]),
        case nkdocker:start(DockerPid, Name) of
            ok ->
                {ok, Name};
            {error, Error3} ->
                {error, Error3}
        end
    catch
        throw:Throw -> {error, Throw}
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


%% @doc
stop_all() ->
    case get_docker_pid() of
        {ok, DockerPid} ->
            {ok, List} = nkdocker:ps(DockerPid),
            lists:foreach(
                fun(#{<<"Names">>:=[<<"/", Name/binary>>]}) ->
                    case Name of
                        <<"nk_fs_", _/binary>> ->
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
    DockerMonId = nkmedia_app:get(docker_fs_mon_id),
    nkdocker_monitor:get_docker(DockerMonId).



%% @private
notify(MonId, ping, Name, Data) ->
    notify(MonId, start, Name, Data);

notify(MonId, start, Name, Data) ->
    case Data of
        #{
            name := Name,
            labels := #{<<"nkmedia">> := <<"freeswitch">>},
            env := #{
                <<"NK_FS_IP">> := Host, 
                <<"NK_BASE">> := Base, 
                <<"NK_PASS">> := Pass,
                <<"NK_SRV_ID">> := SrvId
            },
            image := Image
        } ->
            case binary:split(Image, <<"/">>) of
                [Comp, <<"nk_freeswitch:", Tag/binary>>] -> 
                    [Vsn, Rel] = binary:split(Tag, <<"-">>),
                    Config = #{
                        srv_id => nklib_util:to_atom(SrvId),
                        name => Name, 
                        comp => Comp,
                        vsn => Vsn,
                        rel => Rel, 
                        host => Host, 
                        base => nklib_util:to_integer(Base),
                        pass => Pass
                    },
                    connect_fs(MonId, Config);
                _ ->
                    lager:warning("Started unrecognized freeswitch")
            end;
        _ ->
            lager:warning("Started unrecognized freeswitch")
    end;

notify(MonId, stop, Name, Data) ->
    case Data of
        #{
            name := Name,
            labels := #{<<"nkmedia">> := <<"freeswitch">>}
        } ->
            remove_fs(MonId, Name);
        _ ->
            ok
    end;

notify(_MonId, stats, Name, Stats) ->
    nkmedia_fs_engine:stats(Name, Stats).


%% @private
check_started(SrvId) ->
    case nkmedia_fs_engine:get_all(SrvId) of
        [] ->
            lager:info("No FS engine detected"),
            start(SrvId);
        _ ->
            ok
    end.



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
                {error, {already_started, _Pid}} ->
                    ok;
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

