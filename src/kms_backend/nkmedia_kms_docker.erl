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
-module(nkmedia_kms_docker).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/1, stop/1, stop_all/0]).
-export([notify/4]).

-include("nkmedia.hrl").

%% ===================================================================
%% Types    
%% ===================================================================

%% ===================================================================
%% Kurento Instance
%% ===================================================================
        

%% @doc Starts a KMS instance
-spec start(nkservice:name()) ->
    {ok, Name::binary()} | {error, term()}.

start(Service) ->
    try
        SrvId = case nkservice_srv:get_srv_id(Service) of
            {ok, SrvId0} -> SrvId0;
            not_found -> throw(unknown_service)
        end,
        Config = nkservice_srv:get_item(SrvId, config_nkmedia_kms),
        BasePort = crypto:rand_uniform(32768, 65535),
        Pass = nklib_util:luid(),
        Image = nkmedia_kms_build:run_image_name(Config),
        KmsIp = nklib_util:to_host(nkmedia_app:get(docker_ip)),
        Name = list_to_binary([
            "nk_kms_", 
            nklib_util:to_binary(SrvId), "_",
            nklib_util:to_binary(BasePort)
        ]),
        _LogDir = <<(nkmedia_app:get(log_dir))/binary, $/, Name/binary>>,
        Env = [
            {"NK_KMS_IP", KmsIp},                
            {"NK_BASE", nklib_util:to_binary(BasePort)},
            {"NK_SRV_ID", nklib_util:to_binary(SrvId)},
            {"ENV GST_DEBUG", "Kurento*:5"}

        ],
        Labels = [
            {"nkmedia", "kurento"}
        ],
        DockerOpts = #{
            name => Name,
            env => Env,
            net => host,
            interactive => true,
            labels => Labels
            % volumes => [{LogDir, "/usr/local/kurento/log"}]
        },
        DockerPid = case get_docker_pid() of
            {ok, DockerPid0} -> DockerPid0;
            {error, Error1} -> throw(Error1)
        end,
        nkdocker:rm(DockerPid, Name),
        case nkdocker:create(DockerPid, Image, DockerOpts) of
            {ok, _} -> ok;
            {error, Error2} -> throw(Error2)
        end,
        lager:info("NkMEDIA KMS Docker: starting instance ~s", [Name]),
        case nkdocker:start(DockerPid, Name) of
            ok ->
                {ok, Name};
            {error, Error3} ->
                {error, Error3}
        end
    catch
        throw:Throw -> {error, Throw}
    end.



%% @doc Stops a KMS instance
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
                        <<"nk_kms_", _/binary>> ->
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
            labels := #{<<"nkmedia">> := <<"kurento">>},
            env := #{
                <<"NK_KMS_IP">> := Host, 
                <<"NK_BASE">> := Base, 
                <<"NK_SRV_ID">> := SrvId
            },
            image := Image
        } ->
            case binary:split(Image, <<"/">>) of
                [_Comp, <<"nk_kurento_run:", Rel/binary>>] -> 
                    Config = #{
                        name => Name, 
                        srv_id => nklib_util:to_atom(SrvId),
                        rel => Rel, 
                        host => Host, 
                        base => nklib_util:to_integer(Base)
                    },
                    connect_kms(MonId, Config);
                _ ->
                    lager:warning("Started unrecognized kurento")
            end;
        _ ->
            lager:warning("Started unrecognized kurento: ~p")
    end;

notify(MonId, stop, Name, Data) ->
    case Data of
        #{
            name := Name,
            labels := #{<<"nkmedia">> := <<"kurento">>}
            % env := #{<<"NK_KMS_IP">> := Host}
        } ->
            remove_kms(MonId, Name);
        _ ->
            ok
    end;

notify(_MonId, stats, Name, Stats) ->
    nkmedia_kms_engine:stats(Name, Stats).



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
connect_kms(MonId, #{name:=Name}=Config) ->
    spawn(
        fun() -> 
            timer:sleep(2000),
            case nkmedia_kms_engine:connect(Config) of
                {ok, _Pid} -> 
                    ok = nkdocker_monitor:start_stats(MonId, Name);
                {error, {already_started, _Pid}} ->
                    ok;
                {error, Error} -> 
                    lager:warning("Could not connect to Kurento ~s: ~p", 
                                  [Name, Error])
            end
        end),
    ok.


%% @private
remove_kms(MonId, Name) ->
    spawn(
        fun() ->
            nkmedia_kms_engine:stop(Name),
            case nkdocker_monitor:get_docker(MonId) of
                {ok, Pid} -> 
                    nkdocker:rm(Pid, Name);
                _ -> 
                    ok
            end
        end),
    ok.

