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

%% @doc NkMEDIA Utilities to build KMS images
-module(nkmedia_kms_build).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([build_base/0, build_base/1, remove_base/0, remove_base/1]).
-export([build_run/0, build_run/1, remove_run/0, remove_run/1]).
-export([run_name/1, defaults/1]).

-include("nkmedia.hrl").

-define(KMS_COMP, <<"netcomposer">>).
-define(KMS_VSN, <<"6.5.0.20160530172436.trusty">>).
-define(KMS_REL, <<"r01">>).



%% ===================================================================
%% Public
%% ===================================================================
        

%% @doc Builds base image (netcomposer/nk_kurento_base:v1.6.5-r01)
build_base() ->
    build_base(#{}).


%% @doc 
build_base(Config) ->
    Name = base_name(Config),
    #{vsn:=Vsn} = defaults(Config),
    Tar = nkdocker_util:make_tar([{"Dockerfile", base_dockerfile(Vsn)}]),
    nkdocker_util:build(Name, Tar).


%% @doc
remove_base() ->
    remove_base(#{}).


%% @doc 
remove_base(Config) ->
    Name = base_name(Config),
    case nkdocker:start_link() of
        {ok, Pid} ->
            Res = case nkdocker:rmi(Pid, Name, #{force=>true}) of
                {ok, _} -> ok;
                {error, {not_found, _}} -> ok;
                E3 -> lager:warning("NkMEDIA could not remove ~s: ~p", [Name, E3])
            end,
            nkdocker:stop(Pid),
            Res;
        {error, Error} ->
            {error, Error}
    end.


%% @doc
build_run() ->
    build_run(#{}).


%% @doc Builds run image (netcomposer/nk_kurento:...)
build_run(Config) ->
    Name = run_name(Config),
    Tar = nkdocker_util:make_tar([
        {"Dockerfile", run_dockerfile(Config)},
        {"start.sh", run_start()}
    ]),
    nkdocker_util:build(Name, Tar).


%% @doc
remove_run() ->
    remove_run(#{}).


%% @doc 
remove_run(Config) ->
    Config2 = defaults(Config),
    Name = run_name(Config2),
    case nkdocker:start_link() of
        {ok, Pid} ->
            Res = case nkdocker:rmi(Pid, Name, #{force=>true}) of
                {ok, _} -> ok;
                {error, {not_found, _}} -> ok;
                E3 -> lager:warning("NkMEDIA could not remove ~s: ~p", [Name, E3])
            end,
            nkdocker:stop(Pid),
            Res;
        {error, Error} ->
            {error, Error}
    end.


%% @private
defaults(Config) ->
    Defs = #{
        comp => ?KMS_COMP,
        vsn => ?KMS_VSN,        
        rel => ?KMS_REL
    },
    maps:merge(Defs, Config).



%% ===================================================================
%% Base image (Comp/nk_kurento_base:vXXX-rXXX)
%% ===================================================================


%% @private
base_name(Config) ->
    Config2 = defaults(Config),
    #{comp:=Comp, vsn:=Vsn, rel:=Rel} = Config2,
    list_to_binary([Comp, "/nk_kurento_base:", Vsn, "-", Rel]).


%% @private
base_dockerfile(Vsn) -> 
<<"
FROM ubuntu:14.04
RUN apt-get update && apt-get install -y wget vim nano telnet && \\
    echo \"deb http://ubuntu.kurento.org trusty kms6\" | tee /etc/apt/sources.list.d/kurento.list && \\
    wget -O - http://ubuntu.kurento.org/kurento.gpg.key | apt-key add - && \\
    apt-get update && \\
    apt-get -y install kurento-media-server-6.0=", (nklib_util:to_binary(Vsn))/binary, " && \\
    apt-get clean && rm -rf /var/lib/apt/lists/*
">>.



%% ===================================================================
%% Instance build files (Comp/nk_kurento:vXXX-rXXX)
%% ===================================================================


%% @private
run_name(Config) -> 
    Config2 = defaults(Config),
    #{comp:=Comp, vsn:=Vsn, rel:=Rel} = Config2,
    list_to_binary([Comp, "/nk_kurento:", Vsn, "-", Rel]).


run_dockerfile(Config) ->
    list_to_binary([
"FROM ", base_name(Config), "\n"
"WORKDIR /root\n"
"ADD start.sh /usr/local/bin\n"
"ENTRYPOINT [\"sh\", \"/usr/local/bin/start.sh\"]\n"
]).


run_start() ->
<<"
#!/bin/bash
set -e
BASE=${NK_BASE-50020}
perl -i -pe s/8888/$BASE/g /etc/kurento/kurento.conf.json

# Remove ipv6 local loop until ipv6 is supported
cat /etc/hosts | sed '/::1/d' | tee /etc/hosts > /dev/null

exec /usr/bin/kurento-media-server \"$@\"
">>.





%% ===================================================================
%% Utilities
%% ===================================================================


