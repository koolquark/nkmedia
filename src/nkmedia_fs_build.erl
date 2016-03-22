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

%% @doc NkMEDIA Utilities to build FS images
-module(nkmedia_fs_build).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([build_base_image/0, build_base_image/3]).
-export([build_nk_image/0, build_nk_image/3]).

% -include("nkmedia.hrl").

-define(REPO, "netcomposer").
-define(VERSION, "v1.6.5").
-define(RELEASE, "r01").


%% ===================================================================
%% Public
%% ===================================================================
        

%% @private
build_base_image() ->
    build_base_image(?REPO, ?VERSION, ?RELEASE).


%% @private
build_base_image(Repo, Vsn, Rel) ->
    Name = base_image_name(Repo, Vsn, Rel),
    Tar = nkdocker_util:make_tar([{"Dockerfile", base_image_dockerfile(Vsn)}]),
    case nkdocker:start_link() of
        {ok, Pid} ->
            Res = nkdocker_util:build(Pid, Name, Tar),
            nkdocker:stop(Pid),
            Res;
                {error, Error} ->
            {error, {docker_start_error, Error}}
    end.



%% @private
build_nk_image() ->
    build_nk_image(?REPO, ?VERSION, ?RELEASE).


%% @private Build NK Image
%% Environment variables:
%% - NK_LOCAL_IP: Default 127.0.0.1
%% - NK_EXT_IP: Default "stun:stun.freeswitch.org"
%% - NK_HOST_IP: Host for FS to connect to
%% - NK_PASS: Default "6666"

build_nk_image(Repo, Vsn, Rel) ->
    Name = nk_image_name(Repo, Vsn, Rel),
    Tar = nkdocker_util:make_tar([
        {"Dockerfile", nk_image_dockerfile(Repo, Vsn, Rel)},
        {"modules.conf.xml", nk_image_modules()},
        {"0000_nkmedia.xml", nk_image_dialplan()},
        {"event_socket.conf.xml", nk_image_event_socket()},
        {"verto.conf.xml", nk_image_verto()},
        {"start.sh", nk_image_start()}
    ]),
    case nkdocker:start_link() of
        {ok, Pid} ->
            Res = nkdocker_util:build(Pid, Name, Tar),
            nkdocker:stop(Pid),
            Res;
        {error, Error} ->
            {error, {docker_start_error, Error}}
    end.



%% ===================================================================
%% Base image (Repo/freeswitch:vXXX-rXXX)
%% ===================================================================


%% @private
base_image_name(Repo, Vsn, Rel) ->
    list_to_binary([Repo, "/freeswitch:", Vsn, "-", Rel]).


% -define(DEBIAN, "ftp.us.debian.org").
-define(DEBIAN, "ftp.debian.org").

 
%% @private
base_image_dockerfile(Vsn) -> 
<<"
FROM debian:jessie
ENV DEBIAN_FRONTEND noninteractive
ENV APT_LISTCHANGES_FRONTEND noninteractive
WORKDIR /root
RUN echo \"deb http://" ?DEBIAN "/debian jessie main\\n \\
           deb http://" ?DEBIAN "/debian jessie-updates main\\n \\
           deb http://security.debian.org jessie/updates main \\
        \" > /etc/apt/sources.list
RUN apt-get update && \\
    apt-get install -y git wget vim nano telnet build-essential && \\
    echo \"deb http://files.freeswitch.org/repo/deb/freeswitch-1.6/ jessie main\" > /etc/apt/sources.list.d/99FreeSWITCH.list && \\
    wget http://files.freeswitch.org/repo/deb/freeswitch-1.6/key.gpg && \\
    apt-key add key.gpg && \\
    echo \"deb http://packages.erlang-solutions.com/debian jessie contrib\" > /etc/apt/sources.list.d/99ErlangSolutions.list && \\
    wget http://packages.erlang-solutions.com/debian/erlang_solutions.asc && \\
    apt-key add erlang_solutions.asc && \\
    apt-get update && \\
    apt-get install -y -o Retry=5 freeswitch-video-deps-most esl-erlang=1:17.5.3 && \\
    apt-get clean
WORKDIR /usr/src
RUN git clone --branch ", (nklib_util:to_binary(Vsn))/binary, 
    " --depth 1 https://freeswitch.org/stash/scm/fs/freeswitch.git
WORKDIR /usr/src/freeswitch
#RUN ./bootstrap.sh -j && ./configure -C && \\
#    perl -i -pe 's/#applications\\/mod_av/applications\\/mod_av/g' modules.conf && \\
#    perl -i -pe 's/#applications\\/mod_curl/applications\\/mod_curl/g' modules.conf && \\
#    perl -i -pe 's/#applications\\/mod_http_cache/applications\\/mod_http_cache/g' modules.conf && \\
#    perl -i -pe 's/#applications\\/mod_mp4/applications\\/mod_mp4/g' modules.conf && \\
#    perl -i -pe 's/#applications\\/mod_mp4v2/applications\\/mod_mp4v2/g' modules.conf && \\
#    perl -i -pe 's/#codecs\\/mod_mp4v/codecs\\/mod_mp4v/g' modules.conf && \\
#    perl -i -pe 's/#formats\\/mod_vlc/formats\\/mod_vlc/g' modules.conf && \\
#    perl -i -pe 's/#say\\/mod_say_es/say\\/mod_say_es/g' modules.conf
# RUN make && make install && make megaclean
# RUN make cd-sounds-install && make cd-moh-install && make samples
# RUN ln -s /usr/local/freeswitch/bin/fs_cli /usr/local/bin/fs_cli

# Demo videos
# WORKDIR /var/www/html/vid/
# RUN wget -o /dev/null -O - http://demo.freeswitch.org/vid.tgz | tar zxfv -
">>.


%% ===================================================================
%% Instance build files (Repo/nk_freeswitch:vXXX-rXXX)
%% ===================================================================


%% @private
nk_image_name(Repo, Vsn, Rel) -> 
    list_to_binary([Repo, "/nk_freeswitch:", Vsn, "-", Rel]).


-define(VAR(Name), "\\\\$\\\\$\\\\{" ++ nklib_util:to_list(Name) ++ "}").

%% @private
%% Uses 



nk_image_dockerfile(Repo, Vsn, Rel) ->
    list_to_binary([
"FROM ", base_image_name(Repo, Vsn, Rel), "\n"
"WORKDIR /usr/local/freeswitch/\n"
"RUN mkdir -p certs\n"
"WORKDIR /usr/local/freeswitch/conf/\n"

"RUN ",
    %% Include nkvars.xml in freeswitch.xml
    replace(
        "(<X-PRE-PROCESS cmd=\"include\" data=\"vars.xml\"/>)",
        "\\1\\n  <X-PRE-PROCESS cmd=\"include\" data=\"nkvars.xml\"/>",
        "freeswitch.xml"), " && \\",

        %% Uncomment jsonrpc-allowed-event-channels in directory/default.xml
    replace(
        "<!-- (<param name=\"jsonrpc-allowed-event-channels\" value=\"demo,conference,presence\"/>) -->", 
        "\\1", 
        "directory/default.xml"), " && \\",

    %% Uncomment conference-flags in conference.conf.xml
    replace(
        "<!-- (<param name=\"conference-flags\" value=\"livearray-sync\"/>) -->", 
        "\\1", 
        "autoload_configs/conference.conf.xml"), " && \\",

    "mv autoload_configs/event_socket.conf.xml autoload_configs/event_socket.conf.xml.backup && \\"
    "mv autoload_configs/verto.conf.xml autoload_configs/verto.conf.xml.backup && \\",

    % Sip profile is too complex, we change some values
    replace(
        "<param name=\"ext-rtp-ip\" value=.+/>",
        "<param name=\"ext-rtp-ip\" value=\""++?VAR(nk_ext_ip)++"\"/>",
        "sip_profiles/internal.xml"), " && \\",
    "mv sip_profiles/external.xml sip_profiles/external.xml.backup && \\"
    "mv sip_profiles/external-ipv6.xml sip_profiles/external-ipv6.xml.backup && \\"
    "mv sip_profiles/internal-ipv6.xml sip_profiles/internal-ipv6.xml.backup && \\"
    "mv autoload_configs/modules.conf.xml autoload_configs/modules.conf.xml.backup\n"

"ADD event_socket.conf.xml /usr/local/freeswitch/conf/autoload_configs/\n"
"ADD verto.conf.xml /usr/local/freeswitch/conf/autoload_configs/\n"
"ADD modules.conf.xml /usr/local/freeswitch/conf/autoload_configs/\n"
"ADD 0000_nkmedia.xml /usr/local/freeswitch/conf/dialplan/default/\n"
"ADD start.sh /usr/local/freeswitch/\n"
"WORKDIR /usr/local/freeswitch/\n"
]).


nk_image_event_socket() -> <<"
<configuration name=\"event_socket.conf\" description=\"Socket Client\">
  <settings>
    <param name=\"nat-map\" value=\"false\"/>
    <param name=\"listen-ip\" value=\"$${local_ip_v4}\"/>
    <param name=\"listen-port\" value=\"8021\"/>
    <param name=\"password\" value=\"$${default_password}\"/>
    <param name=\"apply-inbound-acl\" value=\"0.0.0.0/0\"/>
    <param name=\"stop-on-bind-error\" value=\"true\"/>
  </settings>
</configuration>
">>.

nk_image_verto() -> <<"
<configuration name=\"verto.conf\" description=\"HTML5 Verto Endpoint\">
  <settings>
    <param name=\"debug\" value=\"$${verto_debug}\"/>
  </settings>
  <profiles>
    <profile name=\"default\">
      <param name=\"bind-local\" value=\"$${local_ip_v4}:8081\"/>
      <param name=\"force-register-domain\" value=\"$${local_ip_v4}\"/>
      <param name=\"userauth\" value=\"true\"/>
      <param name=\"blind-reg\" value=\"true\"/>
      <param name=\"mcast-ip\" value=\"224.1.1.1\"/>
      <param name=\"mcast-port\" value=\"1337\"/>
      <param name=\"rtp-ip\" value=\"$${local_ip_v4}\"/>
      <param name=\"ext-rtp-ip\" value=\"$${nk_ext_ip}\"/>
      <param name=\"local-network\" value=\"localnet.auto\"/>
      <param name=\"outbound-codec-string\" value=\"opus,vp8\"/>
      <param name=\"inbound-codec-string\" value=\"opus,vp8\"/>
      <param name=\"apply-candidate-acl\" value=\"localnet.auto\"/>
      <param name=\"apply-candidate-acl\" value=\"wan_v4.auto\"/>
      <param name=\"apply-candidate-acl\" value=\"rfc1918.auto\"/>
      <param name=\"apply-candidate-acl\" value=\"any_v4.auto\"/>
      <param name=\"timer-name\" value=\"soft\"/>
    </profile>
 </profiles>
</configuration>
">>.


nk_image_modules() -> <<"
<configuration name=\"modules.conf\" description=\"Modules\">
  <modules>
    <load module=\"mod_event_socket\"/>
    <load module=\"mod_vlc\"/>
    <load module=\"mod_logfile\"/>
    <load module=\"mod_sofia\"/>
    <load module=\"mod_loopback\"/>
    <load module=\"mod_rtc\"/>
    <load module=\"mod_verto\"/>
    <load module=\"mod_commands\"/>
    <load module=\"mod_conference\"/>
    <load module=\"mod_curl\"/>
    <load module=\"mod_db\"/>
    <load module=\"mod_dptools\"/>
    <load module=\"mod_expr\"/>
    <load module=\"mod_fifo\"/>
    <load module=\"mod_hash\"/>
    <load module=\"mod_fsv\"/>
    <load module=\"mod_valet_parking\"/>
    <load module=\"mod_httapi\"/>
    <load module=\"mod_dialplan_xml\"/>
    <load module=\"mod_spandsp\"/>
    <load module=\"mod_g723_1\"/>
    <load module=\"mod_g729\"/>
    <load module=\"mod_amr\"/>
    <load module=\"mod_ilbc\"/>
    <load module=\"mod_h26x\"/>
    <load module=\"mod_vpx\"/>
    <load module=\"mod_b64\"/>
    <load module=\"mod_opus\"/>
    <load module=\"mod_sndfile\"/>
    <load module=\"mod_native_file\"/>
    <load module=\"mod_png\"/>
    <load module=\"mod_local_stream\"/>
    <load module=\"mod_tone_stream\"/>
    <load module=\"mod_lua\"/>
  </modules>
</configuration>
">>.


nk_image_dialplan() -> 
<<"
<include>

    <extension name=\"nkmedia_inbound\">
        <condition field=\"destination_number\" expression=\"^nkmedia_in$\">
            <action application=\"set\" data=\"transfer_after_bridge=nkmedia_route:XML:default\"/>
            <action application=\"answer\"/>
            <action application=\"info\"/>
            <action application=\"transfer\" data=\"nkmedia_route\"/>
        </condition>
    </extension>

    <extension name=\"nkmedia_outgoing\">
        <condition field=\"destination_number\" expression=\"^nkmedia_out$\">
            <action application=\"set\" data=\"transfer_after_bridge=nkmedia_route:XML:default\"/>
            <action application=\"transfer\" data=\"nkmedia_route\"/>
        </condition>  
    </extension>

    <extension name=\"nkmedia_room\">
        <condition field=\"destination_number\" expression=\"^nkmedia_room_(.*)$\">
            <action application=\"event\" data=\"$${nkevent},op=room_$1\"/>
            <action application=\"set\" data=\"nkstatus=room_$1\"/>
            <action application=\"conference\" data=\"$1\"/>
            <action application=\"transfer\" data=\"nkmedia_route\"/>
        </condition>
    </extension>

    <extension name=\"nkmedia_route\">
        <condition field=\"destination_number\" expression=\"^nkmedia_route$\">
            <action application=\"set\" data=\"nkstatus=route\"/>
            <action application=\"event\" data=\"$${nkevent},op=route\"/>
            <action application=\"park\"/>      
        </condition>
    </extension>

    <extension name=\"nkmedia_join\">
        <condition field=\"destination_number\" expression=\"^nkmedia_join_(.*)$\">
            <action application=\"set\" data=\"nkstatus=join_$1\"/>
            <action application=\"event\" data=\"$${nkevent},op=join_$1\"/>
            <action application=\"set\" data=\"api_result=${uuid_bridge ${uuid} $1}\"/>
            <action application=\"transfer\" data=\"nkmedia_route\"/>
        </condition>
    </extension>     
  
    <extension name=\"nkmedia_hangup\">
       <condition field=\"destination_number\" expression=\"^nkmedia_hangup_(.*)$\">
            <action application=\"hangup\" data=\"$1\"/>
       </condition>
     </extension>
    
</include>
">>.


nk_image_start() ->
<<"
#!/bin/bash\n
set -e\n
export LOCAL_IP_V4=\"\\$\\${local_ip_v4}\"
export EXT_IP=\"stun:stun.freeswitch.org\"
cat > /usr/local/freeswitch/conf/nkvars.xml <<EOF
<include>
    <X-PRE-PROCESS cmd=\"set\" data=\"nk_ext_ip=${NK_EXT_IP-EXT_IP}\"/>
    <X-PRE-PROCESS cmd=\"set\" data=\"local_ip_v4=${NK_LOCAL_IP-$LOCAL_IP_V4}\"/>
    <X-PRE-PROCESS cmd=\"set\" data=\"nk_host_ip=${NK_HOST_IP-127.0.0.1}\"/>
    <X-PRE-PROCESS cmd=\"set\" data=\"default_password=${NK_PASS-6666}\"/>
    <!-- <X-PRE-PROCESS cmd=\"set\" data=\"domain=${LOCAL_IP_V4}\"/> -->
    <X-PRE-PROCESS cmd=\"set\" data=\"local_ip_v6=[::1]\"/>
    <X-PRE-PROCESS cmd=\"set\" data=\"nkevent=Event-Name=CUSTOM,Event-Subclass=NkMEDIA\"/>
</include>
EOF
#rm /usr/local/bin/fs_cli
cat > /usr/local/bin/fs_cli2 <<EOF
!/bin/bash
/usr/local/freeswitch/bin/fs_cli -H $NK_LOCAL_IP -p $NK_PASS
EOF
chmod a+x /usr/local/bin/fs_cli2
exec /usr/local/freeswitch/bin/freeswitch -nf -nonat
">>.



%% ===================================================================
%% Utilities
%% ===================================================================




replace(Text, Rep, File) ->
    list_to_binary([
        "perl -i -pe \"s/",
        replace_escape(Text),
        "/",
        replace_escape(Rep),
        "/g\""
        " ",
        File
    ]).


replace_escape(List) ->
    replace_escape(List, []).

replace_escape([$/|Rest], Acc) ->
    replace_escape(Rest, [$/, $\\|Acc]);

replace_escape([$"|Rest], Acc) ->
    replace_escape(Rest, [$", $\\|Acc]);

replace_escape([Ch|Rest], Acc) ->
    replace_escape(Rest, [Ch|Acc]);

replace_escape([], Acc) ->
    lists:reverse(Acc).

