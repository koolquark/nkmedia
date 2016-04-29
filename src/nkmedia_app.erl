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

%% @doc NkMEDIA OTP Application Module
-module(nkmedia_app).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(application).

-export([start/0, start/2, stop/1]).
-export([get/1, get/2, put/2]).
-export([get_env/1, get_env/2, set_env/2]).

-include("nkmedia.hrl").
-include_lib("nklib/include/nklib.hrl").

-define(APP, nkmedia).

%% ===================================================================
%% Private
%% ===================================================================

%% @doc Starts stand alone.
-spec start() -> 
    ok | {error, Reason::term()}.

start() ->
    case nklib_util:ensure_all_started(?APP, permanent) of
        {ok, _Started} ->
            ok;
        Error ->
            Error
    end.


%% @private OTP standard start callback
start(_Type, _Args) ->
    Syntax = #{
        docker_company => binary,
        fs_version => binary,
        fs_release => binary,
        fs_password => binary,
        janus_version => binary,
        janus_release => binary,
        sip_port => integer,        
        no_docker => boolean

    },
    Defaults = #{
        docker_company => <<"netcomposer">>,
        fs_version => <<"v1.6.5">>,
        fs_release => <<"r01">>,
        fs_password => <<"764123">>,
        janus_version => <<"master">>,
        janus_release => <<"r01">>,
        sip_port => 0,
        no_docker => false
    },
    case nklib_config:load_env(?APP, Syntax, Defaults) of
        {ok, _} ->
            % nkpacket:register_protocol(fs_event, nkmedia_fs_event_protocol),
            % nkpacket:register_protocol(fs_verto_proxy, nkmedia_fs_verto_proxy_client),
            {ok, Vsn} = application:get_key(?APP, vsn),
            lager:info("NkMEDIA v~s is starting", [Vsn]),
            MainIp = nkpacket_config_cache:main_ip(),
            nkmedia_app:put(main_ip, MainIp),
            % Erlang IP is used for the media servers to contact to the
            % management server 
            case nkmedia_app:get(no_docker) of
                false ->
                    {ok, #{ip:=DockerIp}} =nkdocker_util:get_conn_info(),
                    case DockerIp of
                        {127,0,0,1} ->
                            nkmedia_app:put(erlang_ip, {127,0,0,1}),
                            nkmedia_app:put(docker_ip, {127,0,0,1});
                        _ ->
                            lager:warning("NkMEDIA: remote docker mode enabled"),
                            lager:warning("Erlang: ~s, Docker: ~s", 
                                         [nklib_util:to_host(MainIp), 
                                          nklib_util:to_host(DockerIp)]),
                            nkmedia_app:put(erlang_ip, MainIp),
                            nkmedia_app:put(docker_ip, DockerIp)
                    end,
                    case nkdocker_monitor:register(nkmedia_callbacks) of
                        {ok, DockerMonId} ->
                            nkmedia_app:put(docker_mon_id, DockerMonId),
                            lager:info("Installed images: ~s", 
                                [nklib_util:bjoin(find_images(DockerMonId))]);
                        {error, Error} ->
                            lager:error("Could not start Docker Monitor: ~p", [Error]),
                            error(docker_monitor)
                    end;

                    % Images = nkmedia_docker:find_images(),
                    % lager:info("Installed images: ~s", [Images]);
                true ->
                    lager:warning("No docker support in config")
            end,
            {ok, Pid} = nkmedia_sup:start_link(),
            nkmedia_core_sip:start(),
            {ok, Pid};
        {error, Error} ->
            lager:error("Error parsing config: ~p", [Error]),
            error(Error)
    end.


%% @private OTP standard stop callback
stop(_) ->
    ok.


%% Configuration access
get(Key) ->
    nklib_config:get(?APP, Key).

get(Key, Default) ->
    nklib_config:get(?APP, Key, Default).

put(Key, Val) ->
    nklib_config:put(?APP, Key, Val).



%% @private
get_env(Key) ->
    get_env(Key, undefined).


%% @private
get_env(Key, Default) ->
    case application:get_env(?APP, Key) of
        undefined -> Default;
        {ok, Value} -> Value
    end.


%% @private
set_env(Key, Value) ->
    application:set_env(?APP, Key, Value).

%% @private
find_images(MonId) ->
    {ok, Docker} = nkdocker_monitor:get_docker(MonId),
    {ok, Images} = nkdocker:images(Docker),
    Tags = lists:flatten([T || #{<<"RepoTags">>:=T} <- Images]),
    lists:filter(fun(Img) -> length(binary:split(Img, <<"/nk_">>))==2 end, Tags).




