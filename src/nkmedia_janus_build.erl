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

%% @doc NkMEDIA Utilities to build JANUS images
-module(nkmedia_janus_build).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([build_base_image/0, build_base_image/1]).
-export([remove_base_image/0, remove_base_image/1]).
-export([build_run_image/0, build_run_image/1]).
-export([remove_run_image/0, remove_run_image/1]).
-export([run_image_name/1]).

% -include("nkmedia.hrl").

%% ===================================================================
%% Public
%% ===================================================================
        

%% @doc Builds base image (netcomposer/nk_janus_base:v1.6.5-r01)
build_base_image() ->
    build_base_image(#{}).


%% @doc 
build_base_image(Config) ->
    Name = base_image_name(Config),
    #{vsn:=Vsn} = nkmedia_fs_docker:defaults(Config),
    Tar = nkdocker_util:make_tar([{"Dockerfile", base_image_dockerfile(Vsn)}]),
    nkdocker_util:build(Name, Tar).


%% @doc
remove_base_image() ->
    remove_base_image(#{}).


%% @doc 
remove_base_image(Config) ->
    Name = base_image_name(Config),
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
build_run_image() ->
    build_run_image(#{}).


%% @doc Builds run image (netcomposer/nk_janus_run:v1.6.5-r01)
%% Environment variables:
%% - NK_FS_IP: Default "$${local_ip_v4}". Maps to local_ip_v4 inside janus
%% - NK_RTP_IP: Default "$${local_ip_v4}".
%% - NK_ERLANG_IP: Host for FS to connect to. Used in rtp-ip
%% - NK_EXT_IP: Default "stun:stun.janus.org". Used in ext-rtp-ip
%% - NK_PASS: Default "6666"
build_run_image(Config) ->
    Name = run_image_name(Config),
    Tar = nkdocker_util:make_tar([
        {"Dockerfile", run_image_dockerfile(Config)},
        {"start.sh", run_image_start()}
    ]),
    nkdocker_util:build(Name, Tar).


%% @doc
remove_run_image() ->
    remove_run_image(#{}).


%% @doc 
remove_run_image(Config) ->
    Config2 = nkmedia_fs_docker:defaults(Config),
    Name = run_image_name(Config2),
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



%% ===================================================================
%% Base image (Comp/nk_janus_base:vXXX-rXXX)
%% ===================================================================


%% @private
base_image_name(Config) ->
    Config2 = nkmedia_fs_docker:defaults(Config),
    #{comp:=Comp, vsn:=Vsn, rel:=Rel} = Config2,
    list_to_binary([Comp, "/nk_janus_base:", Vsn, "-", Rel]).


% -define(DEBIAN, "ftp.us.debian.org").
-define(DEBIAN, "ftp.debian.org").

 
%% @private
base_image_dockerfile(Vsn) -> 
<<"
FROM debian:jessie
RUN apt-get update && \
  apt-get upgrade -y && \
  apt-get install -y libmicrohttpd-dev libjansson-dev libnice-dev libssl-dev libsrtp-dev libsofia-sip-ua-dev libglib2.0-dev libopus-dev libogg-dev libini-config-dev libcollection-dev  pkg-config gengetopt libtool automake librabbitmq-dev git subversion make cmake && \
  apt-get clean && \
  cd /usr/src && \
  git clone git://git.libwebsockets.org/libwebsockets && \
  cd libwebsockets && \
  mkdir build && \
  cd build && \
  cmake -DCMAKE_INSTALL_PREFIX:PATH=/usr .. && \
  make && \
  make install && \
  make clean && \
  cd /usr/src && \
  svn co http://sctp-refimpl.googlecode.com/svn/trunk/KERN/usrsctp usrsctp && \
  cd usrsctp && \
  ./bootstrap && \
  ./configure && \
  make && \
  make install && \
  make clean && \
  cd /usr/src && \
  git clone --branch ", (nklib_util:to_binary(Vsn))/binary, 
  " --depth 1 https://github.com/meetecho/janus-gateway && \
  cd janus-gateway && \
  ./autogen.sh && \
  ./configure --disable-docs && \
  make && \
  make install && \
  make configs && \
  make clean && \
  adduser --system janus && \
  ldconfig
#EXPOSE 7088 8088 8188
USER janus
WORKDIR /home/janus
ENTRYPOINT [\"janus\"]
">>.



%% ===================================================================
%% Instance build files (Comp/nk_janus_run:vXXX-rXXX)
%% ===================================================================


%% @private
run_image_name(Config) -> 
    Config2 = nkmedia_fs_docker:defaults(Config),
    #{comp:=Comp, vsn:=Vsn, rel:=Rel} = Config2,
    list_to_binary([Comp, "/nk_janus_run:", Vsn, "-", Rel]).


-define(VAR(Name), "\\\\$\\\\$\\\\{" ++ nklib_util:to_list(Name) ++ "}").

%% @private
%% Uses 



run_image_dockerfile(Config) ->
    list_to_binary([
"FROM ", base_image_name(Config), "\n"
"WORKDIR /usr/local/janus/\n"
]).






%% ===================================================================
%% Utilities
%% ===================================================================


% replace(Text, Rep, File) ->
%     list_to_binary([
%         "perl -i -pe \"s/",
%         replace_escape(Text),
%         "/",
%         replace_escape(Rep),
%         "/g\""
%         " ",
%         File
%     ]).


% replace_escape(List) ->
%     replace_escape(List, []).

% replace_escape([$/|Rest], Acc) ->
%     replace_escape(Rest, [$/, $\\|Acc]);

% replace_escape([$"|Rest], Acc) ->
%     replace_escape(Rest, [$", $\\|Acc]);

% replace_escape([Ch|Rest], Acc) ->
%     replace_escape(Rest, [Ch|Acc]);

% replace_escape([], Acc) ->
%     lists:reverse(Acc).



%% Expects:
%% - NK_FS_IP
%% - NK_RTP_IP
%% - NK_ERLANG_IP
%% - NK_EXT_IP
%% - NK_PASS

run_image_start() ->
<<"
#!/bin/bash\n
set -e\n
export LOCAL_IP_V4=\"\\$\\${local_ip_v4}\"
export FS_IP=\"${NK_FS_IP-$LOCAL_IP_V4}\"
export RTP_IP=\"${NK_RTP_IP-$LOCAL_IP_V4}\"
export ERLANG_IP=\"${NK_ERLANG_IP-127.0.0.1}\"
export EXT_IP=\"${NK_EXT_IP-stun:stun.freeswitch.org}\"
export PASS=\"${NK_PASS-6666}\"
exec /usr/local/freeswitch/bin/freeswitch -nf -nonat
">>.