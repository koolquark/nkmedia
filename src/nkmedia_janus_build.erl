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

-include("nkmedia.hrl").

%% ===================================================================
%% Public
%% ===================================================================
        

%% @doc Builds base image (netcomposer/nk_janus_base:v1.6.5-r01)
build_base_image() ->
    build_base_image(#{}).


%% @doc 
build_base_image(Config) ->
    Name = base_image_name(Config),
    #{vsn:=Vsn} = nkmedia_janus_docker:defaults(Config),
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
    Config2 = nkmedia_janus_docker:defaults(Config),
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
    Config2 = nkmedia_janus_docker:defaults(Config),
    #{comp:=Comp, vsn:=Vsn, rel:=Rel} = Config2,
    list_to_binary([Comp, "/nk_janus_base:", Vsn, "-", Rel]).


% -define(DEBIAN, "ftp.us.debian.org").
-define(DEBIAN, "ftp.debian.org").

 
%% @private
base_image_dockerfile(Vsn) -> 
<<"
FROM debian:jessie
ENV DEBIAN_FRONTEND noninteractive
ENV APT_LISTCHANGES_FRONTEND noninteractive

RUN echo \"deb http://" ?DEBIAN "/debian jessie main\\n \\
           deb http://" ?DEBIAN "/debian jessie-updates main\\n \\
           deb http://security.debian.org jessie/updates main \\
        \" > /etc/apt/sources.list
RUN apt-get update
RUN apt-get install -y \\
        wget vim nano telnet git build-essential libmicrohttpd-dev libjansson-dev \\
        libnice-dev libssl-dev libsrtp-dev libsofia-sip-ua-dev libglib2.0-dev \\
        libopus-dev libogg-dev libini-config-dev libcollection-dev pkg-config \\
        gengetopt libtool automake librabbitmq-dev subversion make cmake
        libavutil-dev libavcodec-dev libavformat-dev && \\
        apt-get clean

WORKDIR /root
RUN git clone git://git.libwebsockets.org/libwebsockets && \\
    cd libwebsockets && \\
    git checkout v1.5-chrome47-firefox41 && \\
    mkdir build && cd build && \\
    cmake -DCMAKE_INSTALL_PREFIX:PATH=/usr .. && \\
    make && make install && make clean

WORKDIR /root
RUN svn co http://sctp-refimpl.googlecode.com/svn/trunk/KERN/usrsctp usrsctp && \\
    cd usrsctp && \\
    ./bootstrap && ./configure && make && make install && make clean

WORKDIR /root
RUN git clone --branch ", (nklib_util:to_binary(Vsn))/binary, 
      " --depth 1 https://github.com/meetecho/janus-gateway && \\
    cd janus-gateway && \\
    ./autogen.sh && ./configure --enable-post-processing --disable-docs && \\
    make && make install && \\
    make configs && make clean

RUN ldconfig

#EXPOSE 7088 8088 8188
#USER janus
WORKDIR /usr/local/
">>.



%% ===================================================================
%% Instance build files (Comp/nk_janus_run:vXXX-rXXX)
%% ===================================================================


%% @private
run_image_name(Config) -> 
    Config2 = nkmedia_janus_docker:defaults(Config),
    #{comp:=Comp, vsn:=Vsn, rel:=Rel} = Config2,
    list_to_binary([Comp, "/nk_janus_run:", Vsn, "-", Rel]).



run_image_dockerfile(Config) ->
    list_to_binary([
"FROM ", base_image_name(Config), "\n"
"ADD start.sh /usr/local/bin/\n"
"WORKDIR /usr/local/\n"
"RUN mkdir /var/log/janus\n"
"ENTRYPOINT [\"sh\", \"/usr/local/bin/start.sh\"]"
]).



%% @private
run_image_start() ->
    Base = config_base(),
    Http = config_http(),
    WS = config_ws(),
    Audiobridge = config_audiobridge(),
    RecordPlay = config_recordplay(),
    Sip = config_sip(),
    Streaming = config_streaming(),
    VideoRoom = config_videoroom(),
    Voicemail = config_voicemail(),
<<"#!/bin/bash
set -e
JANUS_IP=${NK_JANUS_IP-127.0.0.1}
EXT_IP=${NK_EXT_IP-127.0.0.1}
PASS=${NK_PASS-nkmedia_janus}
BASE=${NK_BASE-50000}
WS_PORT=$BASE
ADMIN_PORT=$(($BASE + 1))
export CONF=\"/usr/local/etc/janus\"

cat > $CONF/janus.cfg <<EOF\n", Base/binary, "\nEOF
cat > $CONF/janus.transport.http.cfg <<EOF\n", Http/binary, "\nEOF
cat > $CONF/janus.transport.websockets.cfg <<EOF\n", WS/binary, "\nEOF
cat > $CONF/janus.plugin.audiobridge.cfg <<EOF\n", Audiobridge/binary, "\nEOF
cat > $CONF/janus.plugin.echotest.cfg <<EOF\n", ";", "\nEOF
cat > $CONF/janus.plugin.recordplay.cfg <<EOF\n", RecordPlay/binary, "\nEOF
cat > $CONF/janus.plugin.sip.cfg <<EOF\n", Sip/binary, "\nEOF
cat > $CONF/janus.plugin.streaming.cfg <<EOF\n", Streaming/binary, "\nEOF
cat > $CONF/janus.plugin.videocall.cfg <<EOF\n", ";", "\nEOF
cat > $CONF/janus.plugin.videoroom.cfg <<EOF\n", VideoRoom/binary, "\nEOF
cat > $CONF/janus.plugin.voicemail.cfg <<EOF\n", Voicemail/binary, "\nEOF

mkdir /usr/local/log
mkdir /usr/local/log/janus
exec /usr/local/bin/janus
# exec /bin/bash
">>.


%% @private
config_base() ->
<<"
[general]
configs_folder = /usr/local/etc/janus
plugins_folder = /usr/local/lib/janus/plugins
transports_folder = /usr/local/lib/janus/transports     
;log_to_stdout = false              ; default=true
log_to_file = /var/log/janus/janus.log
;daemonize = true               
;pid_file = /tmp/janus.pid
interface = $JANUS_IP               ; Interface to use (will be used in SDP)
debug_level = 4                     ; Debug/logging level, valid values are 0-7
;debug_timestamps = yes
;debug_colors = no
api_secret = $PASS
;token_auth = yes                   ; Admin API MUST be enabled
admin_secret = $PASS   

[certificates]
cert_pem = /usr/local/share/janus/certs/mycert.pem
cert_key = /usr/local/share/janus/certs/mycert.key

[media]
;ipv6 = true
;max_nack_queue = 300
;rtp_port_range = 20000-40000
;dtls_mtu = 1200
;force-bundle = true                ; Default false
;force-rtcp-mux = true              ; Default false

[nat]
;stun_server = stun.voip.eutelia.it
;stun_port = 3478
nice_debug = false
;ice_lite = true
;ice_tcp = true
nat_1_1_mapping = $EXT_IP          ; All host candidates will have (only) this
;turn_server = myturnserver.com
;turn_port = 3478
;turn_type = udp
;turn_user = myuser
;turn_pwd = mypassword
;turn_rest_api = http://yourbackend.com/path/to/api
;turn_rest_api_key = anyapikeyyoumayhaveset
;ice_enforce_list = eth0            ; Also IPs
ice_ignore_list = vmnet

[plugins]
; disable = libjanus_voicemail.so,libjanus_recordplay.so

[transports]
; disable = libjanus_rabbitmq.so
">>.

config_http() -> <<"
[general]
base_path = /janus          
threads = unlimited         ; unlimited=thread per connection, number=thread pool
http = yes                  
port = 8088                
https = no                  
;secure_port = 8889         
acl = 127.,192.168.0.      

[admin]
admin_base_path = /admin        
admin_threads = unlimited       
admin_http = yes                 
admin_port = $ADMIN_PORT               
admin_https = no                
;admin_secure_port = 7889       
admin_acl = 127.,192.168.0.    

[certificates]
cert_pem = /usr/local/share/janus/certs/mycert.pem
cert_key = /usr/local/share/janus/certs/mycert.key
">>.


config_ws() -> <<"
[general]
ws = yes
ws_port = $WS_PORT
;wss = yes
;wss_port = 8989
ws_logging = 7             ; libwebsockets debugging level (0 by default)
ws_acl = 127.,192.168.0.   

[admin]
admin_ws = no                   
;admin_ws_port = 7988
admin_wss = no                  
;admin_wss_port = 7989          
admin_ws_acl = 127.,192.168.0. 

[certificates]
cert_pem = /usr/local/share/janus/certs/mycert.pem
cert_key = /usr/local/share/janus/certs/mycert.key
">>.


%% @private
config_audiobridge() -> <<"
[1234]
description = Demo Room
secret = adminpwd
sampling_rate = 16000
record = false
;record_file = /tmp/janus-audioroom-1234.wav
">>.


%% @private
config_recordplay() -> <<"
[general]
path = /usr/local/share/janus/recordings
">>.


%% @private
config_sip() -> <<"
[general]
; local_ip = 1.2.3.4        ; Guessed if omitted
keepalive_interval = 120    ; OPTIONS, 0 to disable
behind_nat = no         ; Use STUN
; user_agent = Cool WebRTC Gateway
register_ttl = 3600
">>.


%% @private
config_streaming() -> <<"
; [stream-name]
; type = rtp|live|ondemand|rtsp
;        rtp = stream originated by an external tool (e.g., gstreamer or
;              ffmpeg) and sent to the plugin via RTP
;        live = local file streamed live to multiple listeners
;               (multiple listeners = same streaming context)
;        ondemand = local file streamed on-demand to a single listener
;                   (multiple listeners = different streaming contexts)
;        rtsp = stream originated by an external RTSP feed (only
;               available if libcurl support was compiled)
; id = <unique numeric ID> (if missing, a random one will be generated)
; description = This is my awesome stream
; is_private = yes|no (private streams don't appear when you do a 'list'
;           request)
; secret = <optional password needed for manipulating (e.g., destroying
;           or enabling/disabling) the stream>
; pin = <optional password needed for watching the stream>
; filename = path to the local file to stream (only for live/ondemand)
; audio = yes|no (do/don't stream audio)
; video = yes|no (do/don't stream video)
;    The following options are only valid for the 'rtp' type:
; audioport = local port for receiving audio frames
; audiomcast = multicast group port for receiving audio frames, if any
; audiocodec = <audio RTP payload type> (e.g., 111)
; audiortpmap = RTP map of the audio codec (e.g., opus/48000/2)
; videoport = local port for receiving video frames
; videomcast = multicast group port for receiving video frames, if any
; videocodec = <video RTP payload type> (e.g., 100)
; videortpmap = RTP map of the video codec (e.g., VP8/90000)
; url = RTSP stream URL (only for restreaming RTSP)
;
; To test the [gstreamer-sample] example, check the test_gstreamer.sh
; script in the plugins/streams folder. To test the live and on-demand
; audio file streams, instead, the install.sh installation script
; automatically downloads a couple of files (radio.alaw, music.mulaw)
; to the plugins/streams folder. 

[gstreamer-sample]
type = rtp
id = 1
description = Opus/VP8 live stream coming from gstreamer
audio = yes
video = yes
audioport = 5002
audiopt = 111
audiortpmap = opus/48000/2
videoport = 5004
videopt = 100
videortpmap = VP8/90000
secret = adminpwd

[file-live-sample]
type = live
id = 2
description = a-law file source (radio broadcast)
filename = /usr/local/share/janus/streams/radio.alaw        ; See install.sh
audio = yes
video = no
secret = adminpwd

[file-ondemand-sample]
type = ondemand
id = 3
description = mu-law file source (music)
filename = /usr/local/share/janus/streams/music.mulaw   ; See install.sh
audio = yes
video = no
secret = adminpwd

;
; Firefox Nightly supports H.264 through Cisco's OpenH264 plugin. The only
; supported profile is the baseline one. This is an example of how to create
; a H.264 mountpoint: you can feed it an x264enc+rtph264pay pipeline in
; gstreamer.
;
;[h264-sample]
;type = rtp
;id = 10
;description = H.264 live stream coming from gstreamer
;audio = no
;video = yes
;videoport = 8004
;videopt = 126
;videortpmap = H264/90000
;videofmtp = profile-level-id=42e01f\;packetization-mode=1

;
; This is a sample configuration for Opus/VP8 multicast streams
;
;[gstreamer-multicast]
;type = rtp
;id = 20
;description = Opus/VP8 live multicast stream coming from gstreamer 
;audio = yes
;video = yes
;audioport = 5002
;audiomcast = 232.3.4.5
;audiopt = 111
;audiortpmap = opus/48000/2
;videoport = 5004
;videomcast = 232.3.4.5
;videopt = 100
;videortpmap = VP8/90000

;
; This is a sample configuration for an RTSP stream
; NOTE WELL: the plugin does NOT transcode, so the RTSP stream MUST be
; in a format the browser can digest (e.g., VP8 or H.264 for video)
;
;[rtsp-test]
;type = rtsp
;id = 99
;description = RTSP Test
;audio = no
;video = yes
;url=rtsp://127.0.0.1:8554/unicast
">>.


%% @private
config_videoroom() -> <<"
[1234]
description = Demo Room
secret = adminpwd
publishers = 6
bitrate = 128000
fir_freq = 10
;audiocodec = opus
;videocodec = vp8
record = false
;rec_dir = /tmp/janus-videoroom">>.


%% @private
config_voicemail() -> <<"
[general]
path = /tmp/voicemail/      ; In the webserver
base = /voicemail/          ; Path to the webserver
">>.


%% ===================================================================
%% Utilities
%% ===================================================================

