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

-export([build_base/0, build_base/1, remove_base/0, remove_base/1]).
-export([build_run/0, build_run/1, remove_run/0, remove_run/1]).
-export([run_name/1]).
-export([defaults/1]).

-include("../../include/nkmedia.hrl").

-define(FS_COMP, <<"netcomposer">>).
-define(FS_VSN, <<"v1.6.9">>).
-define(FS_REL, <<"r01">>).


%% ===================================================================
%% Public
%% ===================================================================
        

%% @doc Builds base image (netcomposer/nk_freeswitch_base:v1.6.5-r01)
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


%% @doc Builds run image (netcomposer/nk_freeswitch:v1.6.5-r01)
%% Environment variables:
%% - NK_FS_IP: Default "$${local_ip_v4}". Maps to local_ip_v4 inside freeswitch
%% - NK_RTP_IP: Default "$${local_ip_v4}".
%% - NK_ERLANG_IP: Host for FS to connect to. Used in rtp-ip
%% - NK_EXT_IP: Default "stun:stun.freeswitch.org". Used in ext-rtp-ip
%% - NK_PASS: Default "6666"
build_run(Config) ->
    Name = run_name(Config),
    Tar = nkdocker_util:make_tar([
        {"Dockerfile", run_dockerfile(Config)},
        {"modules.conf.xml", run_modules()},
        {"nkmedia_dp.xml", run_dialplan()},
        {"event_socket.conf.xml", run_event_socket()},
        {"sip.xml", run_sip()},
        {"verto.conf.xml", run_verto()},
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
        comp => ?FS_COMP,
        vsn => ?FS_VSN,        
        rel => ?FS_REL
    },
    maps:merge(Defs, Config).




%% ===================================================================
%% Base image (Comp/nk_freeswitch_base:vXXX-rXXX)
%% ===================================================================


%% @private
base_name(Config) ->
    Config2 = defaults(Config),
    #{comp:=Comp, vsn:=Vsn, rel:=Rel} = Config2,
    list_to_binary([Comp, "/nk_freeswitch_base:", Vsn, "-", Rel]).


%% @private
base_dockerfile(Vsn) -> 
<<"
FROM debian:jessie
ENV DEBIAN_FRONTEND noninteractive
ENV APT_LISTCHANGES_FRONTEND noninteractive
WORKDIR /root
RUN apt-get update && \\
    apt-get install -y wget vim nano telnet git build-essential && \\
    echo \"deb http://files.freeswitch.org/repo/deb/debian/ jessie main\" > /etc/apt/sources.list.d/99FreeSWITCH.list && \\
    wget http://files.freeswitch.org/repo/deb/debian/key.gpg && \\
    apt-key add key.gpg && \\
    apt-get update && \\
    apt-get install -y freeswitch-video-deps-most && \\
    apt-get clean
RUN git config --global pull.rebase true
WORKDIR /usr/src
RUN git clone --depth 1 --branch ", (nklib_util:to_binary(Vsn))/binary,
" https://freeswitch.org/stash/scm/fs/freeswitch.git
WORKDIR /usr/src/freeswitch
RUN ./bootstrap.sh -j && ./configure -C && \\
    perl -i -pe 's/#applications\\/mod_av/applications\\/mod_av/g' modules.conf && \\
    perl -i -pe 's/#applications\\/mod_curl/applications\\/mod_curl/g' modules.conf && \\
    perl -i -pe 's/#applications\\/mod_http_cache/applications\\/mod_http_cache/g' modules.conf && \\
    perl -i -pe 's/#applications\\/mod_mp4/applications\\/mod_mp4/g' modules.conf && \\
    perl -i -pe 's/#applications\\/mod_mp4v2/applications\\/mod_mp4v2/g' modules.conf && \\
    perl -i -pe 's/#codecs\\/mod_mp4v/codecs\\/mod_mp4v/g' modules.conf && \\
    perl -i -pe 's/#formats\\/mod_vlc/formats\\/mod_vlc/g' modules.conf && \\
    perl -i -pe 's/#say\\/mod_say_es/say\\/mod_say_es/g' modules.conf && \\
    make && make install && make megaclean
RUN make cd-sounds-install && make cd-moh-install && make samples
RUN ln -s /usr/local/freeswitch/bin/fs_cli /usr/local/bin/fs_cli
">>.




%% ===================================================================
%% Instance build files (Comp/nk_freeswitch:vXXX-rXXX)
%% ===================================================================


%% @private
run_name(Config) -> 
    Config2 = defaults(Config),
    #{comp:=Comp, vsn:=Vsn, rel:=Rel} = Config2,
    list_to_binary([Comp, "/nk_freeswitch:", Vsn, "-", Rel]).


-define(VAR(Name), "\\\\$\\\\$\\\\{" ++ nklib_util:to_list(Name) ++ "}").

%% @private
%% Uses 



run_dockerfile(Config) ->
    list_to_binary([
"FROM ", base_name(Config), "\n"
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
        "\\1\\n"
        "      <param name=\"jsonrpc-allowed-jsapi\" value=\"true\"/>", 
        "directory/default.xml"), " && \\",

    %% Uncomment conference-flags in conference.conf.xml
    replace(
        "<!-- (<param name=\"conference-flags\" value=\"livearray-sync\"/>) -->", 
        "\\1", 
        "autoload_configs/conference.conf.xml"), " && \\",

    replace(
        "(<context name=\"default\">)",
        "\\1\\n    <X-PRE-PROCESS cmd=\"include\" data=\"nkmedia/*.xml\"/>", 
        "dialplan/default.xml"), " && \\",

    "mv autoload_configs/event_socket.conf.xml autoload_configs/event_socket.conf.xml.backup && \\"
    "mv autoload_configs/verto.conf.xml autoload_configs/verto.conf.xml.backup && \\",
    "mv sip_profiles/internal.xml sip_profiles/internal.xml.backup && \\"
    "mv sip_profiles/external.xml sip_profiles/external.xml.backup && \\"
    "mv sip_profiles/external-ipv6.xml sip_profiles/external-ipv6.xml.backup && \\"
    "mv sip_profiles/internal-ipv6.xml sip_profiles/internal-ipv6.xml.backup && \\"
    "mv autoload_configs/modules.conf.xml autoload_configs/modules.conf.xml.backup\n"

"ADD sip.xml /usr/local/freeswitch/conf/sip_profiles/\n"
"ADD event_socket.conf.xml /usr/local/freeswitch/conf/autoload_configs/\n"
"ADD verto.conf.xml /usr/local/freeswitch/conf/autoload_configs/\n"
"ADD modules.conf.xml /usr/local/freeswitch/conf/autoload_configs/\n"
"ADD nkmedia_dp.xml /usr/local/freeswitch/conf/dialplan/nkmedia/\n"
"ADD start.sh /usr/local/freeswitch/\n"
"WORKDIR /usr/local/freeswitch/\n"
]).


run_event_socket() -> <<"
<configuration name=\"event_socket.conf\" description=\"Socket Client\">
  <settings>
    <param name=\"nat-map\" value=\"false\"/>
    <param name=\"listen-ip\" value=\"$${nk_fs_ip}\"/>
    <param name=\"listen-port\" value=\"$${nk_event_port}\"/>
    <param name=\"password\" value=\"$${default_password}\"/>
    <param name=\"apply-inbound-acl\" value=\"0.0.0.0/0\"/>
    <param name=\"stop-on-bind-error\" value=\"true\"/>
  </settings>
</configuration>
">>.

run_verto() -> <<"
<configuration name=\"verto.conf\" description=\"HTML5 Verto Endpoint\">
  <settings>
    <param name=\"debug\" value=\"0\"/>
  </settings>
  <profiles>
    <profile name=\"nkmedia\">
      <param name=\"bind-local\" value=\"$${nk_fs_ip}:$${nk_verto_port}\"/>
      <param name=\"force-register-domain\" value=\"$${local_ip_v4}\"/>
      <param name=\"userauth\" value=\"true\"/>
      <param name=\"blind-reg\" value=\"true\"/>
      <param name=\"mcast-ip\" value=\"224.1.1.1\"/>
      <param name=\"mcast-port\" value=\"1337\"/>
      <param name=\"rtp-ip\" value=\"$${nk_rtp_ip}\"/>
      <param name=\"ext-rtp-ip\" value=\"$${nk_ext_ip}\"/>
      <param name=\"local-network\" value=\"localnet.auto\"/>
      <param name=\"outbound-codec-string\" value=\"opus,vp8,speex,iLBC,GSM,PCMU,PCMA\"/>
      <param name=\"inbound-codec-string\" value=\"opus,vp8,speex,iLBC,GSM,PCMU,PCMA\"/>
      <param name=\"apply-candidate-acl\" value=\"localnet.auto\"/>
      <param name=\"apply-candidate-acl\" value=\"wan_v4.auto\"/>
      <param name=\"apply-candidate-acl\" value=\"rfc1918.auto\"/>
      <param name=\"apply-candidate-acl\" value=\"any_v4.auto\"/>
      <param name=\"timer-name\" value=\"soft\"/>
    </profile>
 </profiles>
</configuration>
">>.


run_sip() -> <<"
<profile name=\"internal\">
  <aliases>
  </aliases>
  <gateways>
  </gateways>
  <domains>
    <domain name=\"all\" alias=\"true\" parse=\"false\"/>
  </domains>
  <settings>
    <param name=\"debug\" value=\"0\"/>
    <param name=\"shutdown-on-fail\" value=\"true\"/>
    <param name=\"sip-trace\" value=\"no\"/>
    <param name=\"sip-capture\" value=\"no\"/>
    <!-- Don't be picky about negotiated DTMF just always offer 2833 and accept both 2833 and INFO -->
    <!--<param name=\"liberal-dtmf\" value=\"true\"/>-->
    <param name=\"watchdog-enabled\" value=\"no\"/>
    <param name=\"watchdog-step-timeout\" value=\"30000\"/>
    <param name=\"watchdog-event-timeout\" value=\"30000\"/>
    <param name=\"log-auth-failures\" value=\"false\"/>
    <param name=\"forward-unsolicited-mwi-notify\" value=\"false\"/>
    <param name=\"context\" value=\"public\"/>
    <param name=\"rfc2833-pt\" value=\"101\"/>
    <param name=\"sip-port\" value=\"$${internal_sip_port}\"/>
    <param name=\"dialplan\" value=\"XML\"/>
    <param name=\"dtmf-duration\" value=\"2000\"/>
    <param name=\"inbound-codec-prefs\" value=\"$${global_codec_prefs}\"/>
    <param name=\"outbound-codec-prefs\" value=\"$${global_codec_prefs}\"/>
    <param name=\"rtp-timer-name\" value=\"soft\"/>
    <param name=\"rtp-ip\" value=\"$${nk_rtp_ip}\"/>
    <param name=\"sip-ip\" value=\"$${nk_fs_ip}\"/>
    <param name=\"hold-music\" value=\"$${hold_music}\"/>
    <param name=\"apply-nat-acl\" value=\"nat.auto\"/>
    <param name=\"apply-inbound-acl\" value=\"domains\"/>
    <param name=\"local-network-acl\" value=\"localnet.auto\"/>
    <!--<param name=\"dtmf-type\" value=\"info\"/>-->
    <param name=\"record-path\" value=\"$${recordings_dir}\"/>
    <param name=\"record-template\" value=\"${caller_id_number}.${target_domain}.${strftime(%Y-%m-%d-%H-%M-%S)}.wav\"/>
    <param name=\"manage-presence\" value=\"true\"/>
    <param name=\"presence-hosts\" value=\"$${domain},$${local_ip_v4}\"/>
    <param name=\"presence-privacy\" value=\"$${presence_privacy}\"/>
    <!--set to 'greedy' if you want your codec list to take precedence -->
    <param name=\"inbound-codec-negotiation\" value=\"generous\"/>
    <param name=\"tls\" value=\"false\"/>
    <!--<param name=\"pass-rfc2833\" value=\"true\"/>-->
    <!--<param name=\"inbound-bypass-media\" value=\"true\"/>-->
    <!--<param name=\"inbound-proxy-media\" value=\"true\"/>-->
    <!-- Let calls hit the dialplan before selecting codec for the a-leg -->
    <param name=\"inbound-late-negotiation\" value=\"true\"/>
    <param name=\"nonce-ttl\" value=\"60\"/>
    <param name=\"auth-calls\" value=\"$${internal_auth_calls}\"/>
    <param name=\"inbound-reg-force-matching-username\" value=\"true\"/>
    <param name=\"auth-all-packets\" value=\"false\"/>
    <param name=\"ext-rtp-ip\" value=\"$${nk_ext_ip}\"/>
    <param name=\"ext-sip-ip\" value=\"auto-nat\"/>
    <param name=\"rtp-timeout-sec\" value=\"300\"/>
    <param name=\"rtp-hold-timeout-sec\" value=\"1800\"/>
    <param name=\"force-register-domain\" value=\"$${domain}\"/>
    <param name=\"force-subscription-domain\" value=\"$${domain}\"/>
    <param name=\"force-register-db-domain\" value=\"$${domain}\"/>
    <param name=\"ws-binding\"  value=\":5066\"/>
    <param name=\"wss-binding\" value=\":7443\"/>
    <param name=\"challenge-realm\" value=\"auto_from\"/>
  </settings>
</profile>
">>.




run_modules() -> <<"
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


run_dialplan() -> 
<<"
<include>

    <extension name=\"nkmedia_inbound\">
        <condition field=\"destination_number\" expression=\"^nkmedia_in$\">
            <action application=\"answer\"/>
            <action application=\"park\"/>
        </condition>
    </extension>
</include>
">>.


%% Expects:
%% - NK_FS_IP
%% - NK_RTP_IP
%% - NK_ERLANG_IP
%% - NK_EXT_IP
%% - NK_PASS

run_start() ->
<<"
#!/bin/bash\n
set -e\n
LOCAL_IP_V4=\"\\$\\${local_ip_v4}\"
FS_IP=${NK_FS_IP-$LOCAL_IP_V4}
RTP_IP=$LOCAL_IP_V4
ERLANG_IP=${NK_ERLANG_IP-127.0.0.1}
EXT_IP=\"${NK_EXT_IP-stun:stun.freeswitch.org}\"
PASS=\"${NK_PASS-6666}\"
BASE=${NK_BASE-50000}
EVENT_PORT=$BASE
VERTO_PORT=$(($BASE + 1))
SIP_PORT=$(($BASE + 2))
cat > /usr/local/freeswitch/conf/nkvars.xml <<EOF
<include>
    <X-PRE-PROCESS cmd=\"set\" data=\"nk_fs_ip=$FS_IP\"/>
    <X-PRE-PROCESS cmd=\"set\" data=\"nk_erlang_ip=$ERLANG_IP\"/>
    <X-PRE-PROCESS cmd=\"set\" data=\"nk_rtp_ip=$RTP_IP\"/>
    <X-PRE-PROCESS cmd=\"set\" data=\"nk_ext_ip=$EXT_IP\"/>
    <X-PRE-PROCESS cmd=\"set\" data=\"default_password=$PASS\"/>
    <X-PRE-PROCESS cmd=\"set\" data=\"local_ip_v6=[::1]\"/>
    <X-PRE-PROCESS cmd=\"set\" data=\"nkevent=Event-Name=CUSTOM,Event-Subclass=NkMEDIA\"/>
    <X-PRE-PROCESS cmd=\"set\" data=\"nk_event_port=$EVENT_PORT\"/>
    <X-PRE-PROCESS cmd=\"set\" data=\"nk_verto_port=$VERTO_PORT\"/>
    <X-PRE-PROCESS cmd=\"set\" data=\"internal_sip_port=$SIP_PORT\"/>
</include>
EOF
#rm /usr/local/bin/fs_cli
cat > /usr/local/bin/fs_cli2 <<EOF
!/bin/bash
/usr/local/freeswitch/bin/fs_cli -H $FS_IP -P $EVENT_PORT -p $PASS
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

