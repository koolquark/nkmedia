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

-export([start/0, start/1, stop/0, stop/1]).
-export([build_base/1, remove/0, remove/1]).

-include("nkmedia.hrl").

-define(VAR(Name), "\\\\$\\\\$\\\\{" ++ nklib_util:to_list(Name) ++ "}").



%% ===================================================================
%% Freeswitch Instance
%% ===================================================================


%% @doc Starts a docker instance
%% Use global_getvar to see vars (like nk_ext_ip)
-spec start() ->
    ok | {error, term()}.

start() ->
	start(#{}).

-spec start(nkmedia_fs:start_opts()) ->
    ok | {error, term()}.

start(Opts) ->
    Opts2 = nkmedia_fs:config(Opts),
    {ok, Docker} = nkmedia_docker:get_docker(),
    case build_fs_instance(Docker, Opts2) of
        ok ->
            RunName = fs_run_name(Opts2),
            ImgName = fs_instance_name(Opts2),
            case nkdocker:inspect(Docker, RunName) of
                {ok, 
                    #{
                        <<"State">> := #{<<"Running">>:=true}, 
                        <<"Config">> := #{<<"Image">>:=ImgName}
                    }} -> 
                    lager:info("NkMEDIA FS Docker: it was already running"),
                    ok;
                {ok, _} ->
                    lager:info("NkMEDIA FS Docker: removing ~s", [RunName]),
                    case nkdocker:rm(Docker, RunName) of
                        ok -> 
                            launch(Docker, Opts2);
                        {error, Error} ->
                            {error, Error}
                    end;
                {error, {not_found, _}} -> 
                    launch(Docker, Opts2);
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @doc Equivalent to stop()
-spec stop() ->
    ok.

stop() ->
    stop(#{}).


%% @doc Stops the instance
-spec stop(nkmedia_fs:start_opts()) ->
    ok.

stop(Opts) ->
    Opts2 = nkmedia_fs:config(Opts),
    {ok, Docker} = nkmedia_docker:get_docker(),
    Name = fs_run_name(Opts2),
    case nkdocker:kill(Docker, Name) of
        ok -> ok;
        {error, {not_found, _}} -> ok;
        E1 -> lager:warning("NkMEDIA could not kill ~s: ~p", [Name, E1])
    end,
    case nkdocker:rm(Docker, Name) of
        ok -> ok;
        {error, {not_found, _}} -> ok;
        E2 -> lager:warning("NkMEDIA could not remove ~s: ~p", [Name, E2])
    end,
    ok.

    

%% @private
-spec build_base(nkmedia_fs:install_opts()) ->
    ok | {error, term()}.

build_base(Opts) ->
    Opts2 = nkmedia_fs:config(Opts),
    {ok, Docker} = nkmedia_docker:get_docker(),
    build_fs_base(Docker, Opts2).



%% @doc Stops and removes a freeswitch instance and removes images
remove() ->
	remove(#{}).

remove(Opts) ->
    stop(Opts),
    Opts2 = nkmedia_fs:config(Opts),
    {ok, Docker} = nkmedia_docker:get_docker(),
    InstName = fs_instance_name(Opts2),
	case nkdocker:rmi(Docker, InstName, #{force=>true}) of
		{ok, _} -> ok;
		{error, {not_found, _}} -> ok;
		E3 -> lager:warning("NkMEDIA could not remove ~s: ~p", [InstName, E3])
	end.


%% ===================================================================
%% 'run' files
%% ===================================================================


%% @private
-spec launch(pid(), nkmedia_fs:start_opts()) ->
    ok | {error, term()}.

launch(Docker, #{pos:=Pos, pass:=Pass}=Opts) ->
    % See external_sip_ip in vars.xml
    CallDebug = maps:get(call_debug, Opts, false),
    LocalHost = nkmedia_app:get(local_host),
    FsHost = nkmedia_app:get(docker_host),
    ExtIp = nklib_util:to_host(nkpacket_app:get(ext_ip)),
    Env = [
        {"NK_LOCAL_IP", FsHost},      % 127.0.0.1 usually
        {"NK_HOST_IP", LocalHost},    % 127.0.0.1 usually
        {"NK_EXT_IP", ExtIp},  
        {"NK_PASS", nklib_util:to_list(Pass)},
        {"NK_EVENT_PORT", nklib_util:to_list(8021+Pos)},
        {"NK_SIP_PORT", nklib_util:to_list(5160+Pos)},
        {"NK_VERTO_PORT", nklib_util:to_list(8181+2*Pos)},
        {"NK_VERTO_PORT_SEC", nklib_util:to_list(8182+2*Pos)},
        {"NK_CALL_DEBUG", nklib_util:to_list(CallDebug)}
    ],
    Cmds = ["bash", "/usr/local/freeswitch/start.sh"],
    Name = fs_run_name(Opts),
    DockerOpts = #{
        name => Name,
        env => Env,
        cmds => Cmds,
        net => host,
        interactive => true
    },
    lager:info("NkMEDIA FS Docker: creating instance ~s", [Name]),
    case nkdocker:create(Docker, fs_instance_name(Opts), DockerOpts) of
        {ok, _} -> 
            lager:info("NkMEDIA FS Docker: starting ~s", [Name]),
            nkdocker:start(Docker, Name);
        {error, Error} -> 
            {error, Error}
    end.
        

%% @private
fs_run_name(#{pos:=0}) -> <<"nk_fs">>;
fs_run_name(#{pos:=Pos}) -> <<"nk_fs_", (nklib_util:to_binary(Pos))/binary>>.



%% ===================================================================
%% 'base' build files
%% ===================================================================

%% @private
build_fs_base(Docker, Opts) ->
	{Name, Tar} = fs_base(Opts),
	nkdocker_util:build(Docker, Name, Tar).


%% @private
fs_base(Opts) ->
    {
        fs_base_name(Opts),
        nkdocker_util:make_tar([
            {"Dockerfile", fs_base_dockerfile(Opts)}
        ])
    }.


%% @private
fs_base_name(#{vsn:=Vsn, rel:=Rel}) ->
    Company = nkmedia_app:get(docker_company),
	<<Company/binary, "/nk_fs_base_", Vsn/binary, ":", Rel/binary>>.


% -define(DEBIAN, "ftp.us.debian.org").
-define(DEBIAN, "ftp.debian.org").

 
%% @private
fs_base_dockerfile(#{vsn:=Vsn, rel:=<<"r01">>}) -> 
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
RUN git clone --branch ", Vsn/binary, " --depth 1 https://freeswitch.org/stash/scm/fs/freeswitch.git
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
%% 'instance' build files
%% ===================================================================

%% @private
build_fs_instance(Docker, Opts) ->
    {Name, Tar} = fs_instance(Opts),
    nkdocker_util:build(Docker, Name, Tar).


%% @private
fs_instance(Opts) ->
    Path = filename:join(code:priv_dir(nkmedia), "certs"),
    {ok, Wss} = file:read_file(filename:join(Path, "wss.pem")),
    {
        fs_instance_name(Opts),
        nkdocker_util:make_tar([
            {"Dockerfile", fs_instance_dockerfile(Opts)},
            {"wss.pem", Wss},
            {"modules.conf.xml", fs_instance_modules()},
            {"0000_nkmedia.xml", fs_instance_dialplan()},
            {"start.sh", fs_instance_start()}
        ])
    }.


%% @private
fs_instance_name(#{vsn:=Vsn, rel:=Rel}) -> 
    Company = nkmedia_app:get(docker_company),
    <<Company/binary, "/nk_fs_", Vsn/binary, ":", Rel/binary>>.


%% @private
fs_instance_dockerfile(#{rel:=<<"r01">>}=Opts) -> 
    list_to_binary([
"FROM ", fs_base_name(Opts), "\n"
"WORKDIR /usr/local/freeswitch/\n"
"RUN mkdir -p certs\n"
"ADD wss.pem /usr/local/freeswitch/certs/\n"
"WORKDIR /usr/local/freeswitch/conf/\n"

"RUN ",
    %% Include nkvars.xml in freeswitch.xml
    replace(
        "(<X-PRE-PROCESS cmd=\"include\" data=\"vars.xml\"/>)",
        "\\1\\n  <X-PRE-PROCESS cmd=\"include\" data=\"nkvars.xml\"/>",
        "freeswitch.xml"), " && \\",

    % replace(
    %      "<X-PRE-PROCESS cmd=\"set\" data=\"default_password=1234\"",
    %      "<X-PRE-PROCESS cmd=\"set\" data=\"default_password="++?VAR(nk_pass)++"\"",
    %      "vars.xml"), " && \\",

    % replace(
    %      "<X-PRE-PROCESS cmd=\"set\" data=\"internal_ssl_enable=false\"",
    %      "<X-PRE-PROCESS cmd=\"set\" data=\"internal_ssl_enable=true\"",
    %      "vars.xml"), " && \\",
    % replace(
    %      "<X-PRE-PROCESS cmd=\"set\" data=\"external_ssl_enable=false\"",
    %      "<X-PRE-PROCESS cmd=\"set\" data=\"external_ssl_enable=true\"",
    %      "vars.xml"), " && \\",

    %% Uncomment jsonrpc-allowed-event-channels in directory/default.xml
    replace(
        "<!-- (<param name=\"jsonrpc-allowed-event-channels\" value=\"demo,conference,presence\"/>) -->", 
        "\\1", 
        "directory/default.xml"), " && \\",

    %% Uncomment conference-flgas in conference.conf.xml
    replace(
        "<!-- (<param name=\"conference-flags\" value=\"livearray-sync\"/>) -->", 
        "\\1", 
        "autoload_configs/conference.conf.xml"), " && \\",

    %% Set IP ad PORT for event_socket 
    replace(
        "<param name=\"listen-ip\" value=.+/>", 
        "<param name=\"listen-ip\" value=\""++?VAR(local_ip_v4)++"\"/>", 
        "autoload_configs/event_socket.conf.xml"), " && \\",
    replace(
        "(<param name=\"listen-port\" value)=.+(/>)", 
        "\\1=\""++?VAR(event_socket_port)++"\"\\2", 
        "autoload_configs/event_socket.conf.xml"), " && \\",
    replace(
        "(<param name=\"password\" value)=.+(/>)", 
        "\\1=\""++?VAR(default_password)++"\"\\2", 
        "autoload_configs/event_socket.conf.xml"), " && \\",
    replace(
        "<!--.*(<param name=\"stop-on-bind-error\" value=\"true\"/>).*-->", 
        "\\1", 
        "autoload_configs/event_socket.conf.xml"), " && \\",
    replace(
        "<!--.*(<param name=\"apply-inbound-acl\" value=\".*\"/>).*-->", 
        "<param name=\"apply-inbound-acl\" value=\"0.0.0.0/0\"/>",
        "autoload_configs/event_socket.conf.xml"), " && \\",

    %% Set IP and PORT for verto
    replace(
        "<param name=\"debug\" value=\"0\"/>", 
        "<param name=\"debug\" value=\"1\"/>", 
         "autoload_configs/verto.conf.xml"), " && \\",
    replace(
        "<param name=\"blind-reg\" value=\"false\"/>", 
        "<param name=\"blind-reg\" value=\"true\"/>", 
         "autoload_configs/verto.conf.xml"), " && \\",
    replace(
        ?VAR(local_ip_v4)++":8081", 
        ?VAR(local_ip_v4)++":"++?VAR(verto_port),
         "autoload_configs/verto.conf.xml"), " && \\",
    replace(
        ?VAR(local_ip_v4)++":8082", 
        ?VAR(local_ip_v4)++":"++?VAR(verto_port_sec), 
        "autoload_configs/verto.conf.xml"), " && \\",
    replace(
        "\\\\["++?VAR(local_ip_v6)++"]:8081", 
        "[::1]:"++?VAR(verto_port), 
        "autoload_configs/verto.conf.xml"), " && \\",
    replace(
        "\\\\["++?VAR(local_ip_v6)++"]:8082", 
        "[::1]:"++?VAR(verto_port_sec), 
        "autoload_configs/verto.conf.xml"), " && \\",
    replace(
        "<param name=\"force-register-domain\" value=.+/>",
        "<param name=\"force-register-domain\" value=\""++?VAR(local_ip_v4)++"\"/>",
        "autoload_configs/verto.conf.xml"), " && \\",
    % replace(
    %     "<param name=\"rtp-ip\" value=.+/>",
    %     "<param name=\"rtp-ip\" value=\""++?VAR(nk_ext_ip)++"\"/>",
    %     "autoload_configs/verto.conf.xml"), " && \\",
    replace(
        "<!--  <param name=\"ext-rtp-ip\" value=.+/> -->",
        "<param name=\"ext-rtp-ip\" value=\""++?VAR(nk_ext_ip)++"\"/>",
        "autoload_configs/verto.conf.xml"), " && \\",

    % Sip profile
    % replace(
    %     "<param name=\"rtp-ip\" value=.+/>",
    %     "<param name=\"rtp-ip\" value=\""++?VAR(nk_ext_ip)++"\"/>",
    %     "sip_profiles/internal.xml"), " && \\",
    replace(
        "<param name=\"ext-rtp-ip\" value=.+/>",
        "<param name=\"ext-rtp-ip\" value=\""++?VAR(nk_ext_ip)++"\"/>",
        "sip_profiles/internal.xml"), " && \\",

    % Remove SIP profiles
    "mv sip_profiles/external.xml sip_profiles/external.xml.backup && \\"
    "mv sip_profiles/external-ipv6.xml sip_profiles/external-ipv6.xml.backup && \\"
    "mv sip_profiles/internal-ipv6.xml sip_profiles/internal-ipv6.xml.backup && \\"
    "mv autoload_configs/modules.conf.xml autoload_configs/modules.conf.xml.backup\n"

"ADD modules.conf.xml /usr/local/freeswitch/conf/autoload_configs/\n"
"ADD 0000_nkmedia.xml /usr/local/freeswitch/conf/dialplan/default/\n"
"ADD start.sh /usr/local/freeswitch/\n"
"WORKDIR /usr/local/freeswitch/\n"
]).


fs_instance_modules() -> <<"
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


fs_instance_dialplan() -> 
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


fs_instance_start() ->
<<"
#!/bin/bash\n
set -e\n
export LOCAL_IP_V4=\"\\$\\${local_ip_v4}\"
cat > /usr/local/freeswitch/conf/nkvars.xml <<EOF
<include>
    <X-PRE-PROCESS cmd=\"set\" data=\"nk_ext_ip=$NK_EXT_IP\"/>
    <X-PRE-PROCESS cmd=\"set\" data=\"local_ip_v4=${NK_LOCAL_IP-$LOCAL_IP_V4}\"/>
    <X-PRE-PROCESS cmd=\"set\" data=\"nk_host_ip=${NK_HOST_IP-127.0.0.1}\"/>
    <X-PRE-PROCESS cmd=\"set\" data=\"default_password=${NK_PASS-6666}\"/>
    <X-PRE-PROCESS cmd=\"set\" data=\"domain=${LOCAL_IP_V4}\"/>
    <X-PRE-PROCESS cmd=\"set\" data=\"local_ip_v6=[::1]\"/>
    <X-PRE-PROCESS cmd=\"set\" data=\"event_socket_port=${NK_EVENT_PORT-8021}\"/>
    <X-PRE-PROCESS cmd=\"set\" data=\"call_debug=${NK_CALL_DEBUG-false}\"/>
    <X-PRE-PROCESS cmd=\"set\" data=\"internal_sip_port=${NK_SIP_PORT-5060}\"/>
    <X-PRE-PROCESS cmd=\"set\" data=\"verto_port=${NK_VERTO_PORT-8081}\"/>
    <X-PRE-PROCESS cmd=\"set\" data=\"verto_port_sec=${NK_VERTO_PORT_SEC-8082}\"/>
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

