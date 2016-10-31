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
-export([get/1, get/2, put/2, del/1]).
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
        admin_url => binary,
        admin_pass => binary,
        sip_port => integer,        
        no_docker => boolean,
        log_dir => fullpath,
        record_dir => fullpath,
        docker_log => any,
        default_bitrate => {integer, 0, none}
    },
    Defaults = #{
        admin_url => "wss://all:9010",
        admin_pass => "nkmedia",
        sip_port => 0,
        no_docker => false,
        log_dir => "./log",
        record_dir => "./record",
        default_bitrate => 100000
    },
    case nklib_config:load_env(?APP, Syntax, Defaults) of
        {ok, _} ->
            ensure_dirs(),
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
                            lager:notice("NkMEDIA: remote docker mode enabled"),
                            lager:notice("Erlang: ~s, Docker: ~s", 
                                         [nklib_util:to_host(MainIp), 
                                          nklib_util:to_host(DockerIp)]),
                            nkmedia_app:put(erlang_ip, MainIp),
                            nkmedia_app:put(docker_ip, DockerIp)
                    end;
                true ->
                    lager:warning("No docker support in config")
            end,
            {ok, Pid} = nkmedia_sup:start_link(),
            nkmedia_core:start(),
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

del(Key) ->
    nklib_config:del(?APP, Key).



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
ensure_dirs() ->
    Log = nkmedia_app:get(log_dir),
    filelib:ensure_dir(filename:join(Log, <<"foo">>)),
    Record = nkmedia_app:get(record_dir),
    filelib:ensure_dir(filename:join([Record, <<"tmp">>, <<"foo">>])).

% %% @private
% save_log_dir() ->
%     DirPath1 = nklib_parse:fullpath(filename:absname(DirPath)),



%     Dir = filename:absname(filename:join(code:priv_dir(?APP), "../log")),
%     Path = nklib_parse:fullpath(Dir),
%     nkmedia_app:put(log_dir, Path).








