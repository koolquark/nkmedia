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

%% @doc Tests for media functionality
%% Things to test:
%% 
%% - Register a Verto or a Janus (videocall) (not using direct Verto connections here)
%%
%%   - Verto / Janus originator:
%%     Verto or Janus call je, fe, ke, p1, p2, m1, m2 all work the same way
%%     Verto (or Janus) register with the session on start as 
%%     {nkmedia_verto, CallId, Pid}. This way, we can use nkmedia_session_reg_event
%%     in their callback modules to detect the available answer and session stop.
%%     Also, if the Verto/Janus process stops, the session detects it and stops.
%%     The session 'link' {nkmedia_session, SessId, SessPid} is returned to Verto/Janus
%%     This way, if Verto/Janus needs to stop the session or send an info, it uses it 
%%     in their callback modules as an 'specially recognized' link type.
%%     Also, if the session is killed, stops, it is detected by Verto/Janus
%% 
%%   - Trickle ICE
%%     When the client is Verto, it sends the SDP without trickle. It uses
%%     no_answer_trickle_ice=true, so if the backend sends an SDP with trickle ICE
%%     (like Kurento) the candidates will be buffered and the answer
%%     will be sent when ready
%%     If the client is Janus, it sends the offer SDP with trickle. 
%%     When it sends a candidate the nkmedia_janus_candidate callback sends it
%%     to the session. If the backend has not set no_offer_trickle_ice, they will
%%     be sent directly to the backend. Otherwise (FS), they will be buffered and sent 
%%     to the backend when ready.
%%     Verto does not support receiving candidates either, so uses no_answer_trickle_ice
%%     If we had a client that supports them, should listen to the {candidate, _}
%%     event from nkmedia_session (neither Janus or Verto support receiving candidates)
%%
%%   - Verto / Janus receiver
%%     If we call invite/3 to a registered client, we locate it and we start the 
%%     session without offer. We then get the offer from the session, and send
%%     the invite to Verto/Janus with the session 'link'
%%     This way Verto/Janus monitor the session and send the answer or bye
%%     We also register the Verto/Janus process with the session, so that it can 
%%     detect session stops and kills.
%%
%%   - Direct call
%%     If we dial "dXXX", we start a 'master' session (p2p type, offeree), 
%%     and a 'slave' session (offerer), with the same offer. 
%%     The session sets set_master_answer, so the answer from slave is set on the master
%%     in the slave session, so that it takes the 'offerer' role
%%     If the master sends an offer ICE candidate, since no backend uses it,
%%     it is sent to the slave, where it is announced (unless no_offer_trickle_ice)
%%     If the caller sends a candidate (and no no_offer...), it is sent to the
%%     peer. If again no_offer..., and event is sent for the client
%%     If the peer sends a candidate (and no no_answer_...) it is sent to the master.
%%     If again no no_answer_..., an event is sent
%%
%%   - Call through Janus proxy
%%     A session with type proxy is created (offeree), and a slave session as offerer,
%%     that, upon start, gets the 'secondary offer' from the first.
%%     When the client replys (since it sets set_master_answer) the answer 
%%     is sent to master, where a final answer is generated.
%%     If the master sends a candidate, it is captured by the janus backend
%%     If the peer sends a candidate, it is captured by the janus session
%%     (in nkmedia_jaus_session:candidate/2) and sent to the master to be sent to Janus
%%
%%   - Call through FS/KMS




%%  - Register a SIP Phone
%%    The registrations is allowed and the domain is forced to 'nkmedia'

%%    - Incoming SIP (Janus version)
%%      When a call arrives, we create a proxy session with janus  
%%      and register the nkmedia-generated 'sip link' with it.
%%      We then start a second 'slave' proxy sesssion, and proceed with the invite
%%
%%    - Outcoming SIP (Janus version)
%%      As a Verto/Janus originator, we start a call with j that happens to
%%      resolve to a registered SIP endpoint.
%%      We start a second (slave, offerer, without offer) session, but with sdp_type=rtp.
%%      We get the offer and invite as usual


%% NOTES
%%
%% - Janus doest not currently work if we buffer candidates. 
%%   (not usually neccesary, since it accets trickle ice)







-module(nkmedia_test).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-compile([export_all]).

-define(LOG_SAMPLE(Type, Txt, Args, State),
    lager:Type("API Test (~s) "++Txt, [maps:get(user, State) | Args])).

-include_lib("nkservice/include/nkservice.hrl").
-include_lib("nksip/include/nksip.hrl").

s(Pos, Size) ->
    Bytes1 = base64:encode(crypto:rand_bytes(Size)),
    {Bytes2, _} = split_binary(Bytes1, Size-113),
    nkservice_api_gelf:send(test, src, short, Bytes2, 2, #{data1=>Pos}).

             

%% ===================================================================
%% Public
%% ===================================================================


start() ->
    Spec1 = #{
        callback => ?MODULE,
        web_server => "https:all:8081",
        web_server_path => "./www",
        api_server => "wss:all:9010",
        api_server_timeout => 180,
        verto_listen => "verto:all:8082",
        verto_proxy => "verto_proxy:all:8083",
        janus_listen => "janus:all:8989", 
        janus_proxy=> "janus_proxy:all:8990",
        kurento_proxy => "kmss:all:8433, kms:all:8888",
        nksip_trace => {console, all},
        sip_listen => "sip:all:8060",
        api_gelf_server => "c2.netc.io",
        log_level => debug
    },
    % export NKMEDIA_CERTS="/etc/letsencrypt/live/casa.carlosj.net"
    Spec2 = case os:getenv("NKMEDIA_CERTS") of
        false ->
            Spec1;
        Dir ->
            Spec1#{
                tls_certfile => filename:join(Dir, "cert.pem"),
                tls_keyfile => filename:join(Dir, "privkey.pem"),
                tls_cacertfile => filename:join(Dir, "fullchain.pem")
            }
    end,
    nkservice:start(test, Spec2).


stop() ->
    nkservice:stop(test).

restart() ->
    stop(),
    timer:sleep(100),
    start().




%% ===================================================================
%% Config callbacks
%% ===================================================================


plugin_deps() ->
    [
        nkmedia_sip,  nksip_registrar, nksip_trace,
        nkmedia_verto, nkmedia_fs, nkmedia_fs_verto_proxy,
        nkmedia_janus_proto, nkmedia_janus_proxy, nkmedia_janus,
        nkmedia_kms, nkmedia_kms_proxy,
        nkservice_api_gelf
    ].




%% ===================================================================
%% Cmds
%% ===================================================================


a() ->
    ConfigA = #{backend=>nkmedia_kms, no_offer_trickle_ice=>true, sdp_type=>rtp},
    {ok, SessId, SessLink} = start_session(play, ConfigA),    
    {ok, Offer} = nkmedia_session:get_offer(SessLink),
    
    ConfigB = #{backend=>nkmedia_fs, master_id=>SessId,
                set_master_answer=>true, offer=>Offer},
    {ok, _, _} = start_session(mcu, ConfigB#{room_id=>m1}).



    % {nkmedia_verto, Pid} = find_user(1008),
    % SessLink = {nkmedia_session, SessId, SessPid},
    % nkmedia_verto:invite(Pid, SessId, Offer, SessLink).


invite(Dest, Type, Opts) ->
    Opts2 = maps:merge(#{backend => nkmedia_kms}, Opts),
    start_invite(Dest, Type, Opts2).


invite_listen(Room, Pos, Dest) ->
    {ok, #{backend:=Backend, members:=Members}} = nkmedia_room:get_room(Room),
    Pubs = [P || {P, I} <- maps:to_list(Members), publisher==maps:get(role, I, none)],
    Pub = lists:nth(Pos, Pubs),
    Config = #{
        backend => Backend,
        publisher_id => Pub,
        use_video => true
    },
    start_invite(Dest, listen, Config).


update_media(SessId, Media) ->
    nkmedia_session:cmd(SessId, media, Media).


update_type(SessId, Type, Opts) ->
    nkmedia_session:cmd(SessId, session_type, Opts#{session_type=>Type}).


update_layout(SessId, Layout) ->
    Layout2 = nklib_util:to_binary(Layout),
    nkmedia_session:cmd(SessId, mcu_layout, #{mcu_layout=>Layout2}).


update_listen(SessId, Pos) ->
    {ok, listen, #{room_id:=Room}, _} = nkmedia_session:get_type(SessId),
    {ok, #{publishers:=Pubs}} = nkmedia_room:get_room(Room),
    Pub = lists:nth(Pos, maps:keys(Pubs)),
    nkmedia_session:cmd(SessId, listen_switch, #{publisher_id=>Pub}).




%% ===================================================================
%% nkmedia_verto callbacks
%% ===================================================================

nkmedia_verto_login(Login, Pass, Verto) ->
    case binary:split(Login, <<"@">>) of
        [User, _] ->
            Verto2 = Verto#{user=>User},
            lager:info("Verto login: ~s (pass ~s)", [User, Pass]),
            {true, User, Verto2};
        _ ->
            {false, Verto}
    end.


% @private Called when we receive INVITE from Verto
nkmedia_verto_invite(_SrvId, CallId, Offer, Verto) ->
    #{dest:=Dest} = Offer,
    Offer2 = nkmedia_util:filter_codec(video, vp8, Offer),
    Offer3 = nkmedia_util:filter_codec(audio, opus, Offer2),
    Reg = {nkmedia_verto, CallId, self()},
    case incoming(Dest, Offer3, Reg, #{no_answer_trickle_ice => true}) of
        {ok, _SessId, SessLink} ->
            {ok, SessLink, Verto};
        {error, Reason} ->
            lager:notice("Verto invite rejected ~p", [Reason]),
            {rejected, Reason, Verto}
    end.



%% ===================================================================
%% nkmedia_janus_proto callbacks
%% ===================================================================


% @private Called when we receive INVITE from Janus
nkmedia_janus_invite(_SrvId, CallId, Offer, Janus) ->
    #{dest:=Dest} = Offer, 
    Reg = {nkmedia_janus, CallId, self()},
    case incoming(Dest, Offer, Reg, #{no_answer_trickle_ice => true}) of
        {ok, _SessId, SessLink} ->
            {ok, SessLink, Janus};
        {error, Reason} ->
            lager:notice("Janus invite rejected: ~p", [Reason]),
            {rejected, Reason, Janus}
    end.



%% ===================================================================
%% Sip callbacks
%% ===================================================================

sip_route(_Scheme, _User, _Domain, _Req, _Call) ->
    process.


nks_sip_connection_sent(SipMsg, _Packet) ->
    case SipMsg#sipmsg.cseq of
        {_, 'REGISTER'} -> ok;
        _ -> continue
    end.

nks_sip_connection_recv(SipMsg, _Packet) ->
    case SipMsg#sipmsg.cseq of
        {_, 'REGISTER'} -> ok;
        _ -> continue
    end.


sip_register(Req, Call) ->
    Req2 = nksip_registrar_util:force_domain(Req, <<"nkmedia">>),
    {continue, [Req2, Call]}.



% Version that calls an echo... does not work!
nkmedia_sip_invite(_SrvId, <<"je">>, Offer, SipLink, _Req, _Call) ->
    ConfigA = incoming_config(nkmedia_janus, Offer, SipLink, #{}),
    {ok, SessId, SessLink} = start_session(proxy, ConfigA),
    ConfigB = slave_config(nkmedia_janus, SessId, #{}),
    {ok, SessId2, _SessLink2} = start_session(proxy, ConfigB),
    {ok, Offer2} = nkmedia_session:get_offer(SessId2),
    ConfigC = slave_config(nkmedia_janus, SessId2, #{}),
    start_session(echo, ConfigC#{offer=>Offer2}),
    {ok, SessLink};

% Version that calls another user using Janus proxy
nkmedia_sip_invite(_SrvId, <<"j", Dest/binary>>, Offer, SipLink, _Req, _Call) ->
    ConfigA = incoming_config(nkmedia_janus, Offer, SipLink, #{}),
    {ok, SessId, SessLink} = start_session(proxy, ConfigA),
    ConfigB = slave_config(nkmedia_janus, SessId, #{}),
    ok = start_invite(Dest, proxy, ConfigB),
    {ok, SessLink};

nkmedia_sip_invite(_SrvId, _Dest, _Offer, _SipLink, _Req, _Call) ->
    {rejected, decline}.





% % Version that generates a Janus proxy before going on
% nkmedia_sip_invite(_SrvId, _Dest, Offer, SipLink, _Req, _Call) ->
%     ConfigA = incoming_config(nkmedia_janus, Offer, SipLink, #{}),
%     {ok, SessId, SessPid} = start_session(proxy, ConfigA),
%     {ok, Offer2} = nkmedia_session:cmd(SessId, get_proxy_offer, #{}),
%     SessLink = {nkmedia_session, SessId, SessPid},
%     case find_user(a) of
%         {nkmedia_verto, Pid} ->
%             {ok, Link} = nkmedia_verto:invite(Pid, SessId, Offer2, SessLink),
%             {ok, _} = nkmedia_session:register(SessId, Link);
%         {nkmedia_janus, Pid} ->
%             {ok, Link} = nkmedia_janus_proto:invite(Pid, SessId, Offer2, SessLink),
%             {ok, _} = nkmedia_session:register(SessId, Link);
%         not_found ->
%             {rejected, user_not_found}
%     end.




%% ===================================================================
%% Internal
%% ===================================================================

incoming(<<"je">>, Offer, Reg, Opts) ->
    % Can update mute_audio, mute_video, record, bitrate
    Config = incoming_config(nkmedia_janus, Offer, Reg, Opts),
    start_session(echo, Config#{bitrate=>100000});

incoming(<<"fe">>, Offer, Reg, Opts) ->
    Config = incoming_config(nkmedia_fs, Offer, Reg, Opts),
    start_session(echo, Config);

incoming(<<"ke">>, Offer, Reg, Opts) ->
    Config = incoming_config(nkmedia_kms, Offer, Reg, Opts),
    start_session(echo, Config#{use_data=>false});

incoming(<<"kp">>, Offer, Reg, Opts) ->
    Config = incoming_config(nkmedia_kms, Offer, Reg, Opts),
    start_session(park, Config);

incoming(<<"m1">>, Offer, Reg, Opts) ->
    Config = incoming_config(nkmedia_fs, Offer, Reg, Opts),
    start_session(mcu, Config#{room_id=>"m1"});

incoming(<<"m2">>, Offer, Reg, Opts) ->
    Config = incoming_config(nkmedia_fs, Offer, Reg, Opts),
    start_session(mcu, Config#{room_id=>"m2"});

incoming(<<"jp1">>, Offer, Reg, Opts) ->
    nkmedia_room:start(test, #{room_id=>sfu, backend=>nkmedia_janus}),
    Config = incoming_config(nkmedia_janus, Offer, Reg, Opts),
    start_session(publish, Config#{room_id=>sfu});

incoming(<<"jp2">>, Offer, Reg, Opts) ->
    Config1 = incoming_config(nkmedia_janus, Offer, Reg, Opts),
    Config2 = Config1#{
        room_audio_codec => pcma,
        room_video_codec => vp9,
        room_bitrate => 100000
    },
    start_session(publish, Config2);

incoming(<<"pk1">>, Offer, Reg, Opts) ->
    nkmedia_room:start(test, #{room_id=>sfu, backend=>nkmedia_kms}),
    Config = incoming_config(nkmedia_kms, Offer, Reg, Opts),
    start_session(publish, Config#{room_id=>sfu});

incoming(<<"play">>, Offer, Reg, Opts) ->
    Config = incoming_config(nkmedia_kms, Offer, Reg, Opts),
    start_session(play, Config);

incoming(<<"d", Num/binary>>, Offer, Reg, Opts) ->
    ConfigA = incoming_config(p2p, Offer, Reg, Opts),
    {ok, SessId, SessLink} = start_session(p2p, ConfigA),
    ConfigB = slave_config(p2p, SessId, Opts#{offer=>Offer}),
    ok = start_invite(Num, p2p, ConfigB),
    {ok, SessId, SessLink};

incoming(<<"j", Num/binary>>, Offer, Reg, Opts) ->
    ConfigA1 = incoming_config(nkmedia_janus, Offer, Reg, Opts),
    ConfigA2 = case find_user(Num) of
        {nkmedia_sip, _, _} -> ConfigA1#{sdp_type=>rtp};
        _ -> ConfigA1
    end,
    {ok, SessId, SessLink} = start_session(proxy, ConfigA2#{bitrate=>100000}),
    ConfigB = slave_config(nkmedia_janus, SessId, Opts),
    ok = start_invite(Num, proxy, ConfigB#{bitrate=>150000}),
    {ok, SessId, SessLink};

incoming(<<"f", Num/binary>>, Offer, Reg, Opts) ->
    ConfigA = incoming_config(nkmedia_fs, Offer, Reg, Opts),
    {ok, SessId, SessLink} = start_session(park, ConfigA),
    ConfigB = slave_config(nkmedia_fs, SessId, Opts),
    ok = start_invite(Num, bridge, ConfigB),
    {ok, SessId, SessLink};

incoming(<<"k", Num/binary>>, Offer, Reg, Opts) ->
    ConfigA = incoming_config(nkmedia_kms, Offer, Reg, Opts),
    {ok, SessId, SessLink} = start_session(park, ConfigA),
    ConfigB = slave_config(nkmedia_kms, SessId, Opts),
    ok = start_invite(Num, bridge, ConfigB),
    {ok, SessId, SessLink};

incoming(<<"proxy-test">>, Offer, Reg, Opts) ->
    ConfigA1 = incoming_config(nkmedia_janus, Offer, Reg, Opts),
    {ok, SessId, SessLink} = start_session(proxy, ConfigA1),
    {ok, #{offer:=Offer2}} = nkmedia_session:cmd(SessId, get_proxy_offer, #{}),

    % % This should work, but Juanus fails with a ICE failed message
    % ConfigB = slave_config(nkmedia_janus, SessId, Opts#{offer=>Offer2}),
    % {ok, _, _} = start_session(echo, ConfigB),

    % % This, however works:
    % {nkmedia_janus, Pid} = find_user(a),
    % SessLink = {nkmedia_session, SessId, SessPid},
    % {ok, _} = nkmedia_janus_proto:invite(Pid, SessId, Offer2, SessLink),

    % % Doint the answering by hand fails with the same error
    % {ok, SessB, _} = start_session(publish, #{backend=>nkmedia_janus, offer=>Offer2}),
    % {ok, Answer2} = nkmedia_session:get_answer(SessB),
    % nkmedia_session:set_answer(SessId, Answer2),

    ConfigB = slave_config(nkmedia_fs, SessId, Opts#{offer=>Offer2}),
    {ok, _, _} = start_session(mcu, ConfigB),

    {ok, SessId, SessLink};


incoming(_Dest, _Offer, _Reg, _Opts) ->
    {error, no_destination}.



%% @private
incoming_config(Backend, Offer, Reg, Opts) ->
    Opts#{backend=>Backend, offer=>Offer, register=>Reg}.


%% @private
slave_config(Backend, MasterId, Opts) ->
    Opts#{backend=>Backend, master_id=>MasterId}.


%% @private
start_session(Type, Config) ->
    case nkmedia_session:start(test, Type, Config) of
        {ok, SessId, SessPid} ->
            {ok, SessId, {nkmedia_session, SessId, SessPid}};
        {error, Error} ->
            {error, Error}
    end.


%% Creates a new 'B' session, gets an offer and invites a Verto, Janus or SIP endoint
start_invite(Dest, Type, Config) ->
    case find_user(Dest) of
        {nkmedia_verto, VertoPid} ->
            Config2 = Config#{no_offer_trickle_ice=>true},
            {ok, SessId, SessLink} = start_session(Type, Config2),
            {ok, Offer} = nkmedia_session:get_offer(SessId),
            {ok, InvLink} = nkmedia_verto:invite(VertoPid, SessId, Offer, SessLink),
            {ok, _} = nkmedia_session:register(SessId, InvLink),
            ok;
        {nkmedia_janus, JanusPid} ->
            Config2 = Config#{no_offer_trickle_ice=>true},
            {ok, SessId, SessLink} = start_session(Type, Config2),
            {ok, Offer} = nkmedia_session:get_offer(SessId),
            {ok, InvLink} = nkmedia_janus_proto:invite(JanusPid, SessId, Offer, SessLink),
            {ok, _} = nkmedia_session:register(SessId, InvLink),
            ok;
        {nkmedia_sip, Uri, Opts} ->
            Config2 = Config#{sdp_type=>rtp},
            {ok, SessId, SessLink} = start_session(Type, Config2),
            {ok, SipOffer} = nkmedia_session:get_offer(SessId),
            {ok, InvLink} = nkmedia_sip:send_invite(test, Uri, SipOffer, SessLink, Opts),
            {ok, _} = nkmedia_session:register(SessId, InvLink),
            ok;
        not_found ->
            {error, unknown_user}
    end.





%% @private
find_user(User) ->
    User2 = nklib_util:to_binary(User),
    case nkmedia_verto:find_user(User2) of
        [Pid|_] ->
            {nkmedia_verto, Pid};
        [] ->
            case nkmedia_janus_proto:find_user(User2) of
                [Pid|_] ->
                    {nkmedia_janus, Pid};
                [] ->
                    case 
                        nksip_registrar:find(test, sip, User2, <<"nkmedia">>) 
                    of
                        [Uri|_] -> 
                            {nkmedia_sip, Uri, []};
                        []  -> 
                            not_found
                    end
            end
    end.








speed(N) ->
    Start = nklib_util:l_timestamp(),
    speed(#{c=>3, d=>4}, N),
    Stop = nklib_util:l_timestamp(),
    Time = (Stop - Start) / 1000000,
    N / Time.




speed(_Acc, 0) ->
    ok;
speed(Acc, Pos) ->
    #{a:=1, b:=2, c:=3, d:=4} = maps:merge(Acc, #{a=>1, b=>2}),
    speed(Acc, Pos-1).






% % Version that generates a Janus proxy before going on
% nkmedia_sip_invite(_SrvId, Dest, Offer, SipLink, _Req, _Call) ->
%     % {Codecs, SDP2} = nksip_sdp_util:extract_codecs(SDP),
%     % Codecs2 = nksip_sdp_util:remove_codec(video, h264, Codecs),
%     % SDP3 = nksip_sdp:unparse(nksip_sdp_util:insert_codecs(Codecs2, SDP2)),

%      Base = #{
%         offer => Offer,
%         register => SipLink,
%         backend => nkmedia_kms
%     },
%     % We create a session registered with SipLink, so will detect the
%     % answer and stops in nkmedia_sip_callbacks:nkmedia_session_reg_event().
%     % We return the session link, so that if we receive a BYE, 
%     % nkmedia_sip_callbacks:sip_bye() will call nkmedia_session:stop()
%     case incoming(Dest, Base) of
%         {ok, SessId, SessPid} ->
%             {ok, {nkmedia_session, SessId, SessPid}};
%         {error, Error} ->
%             {rejected, Error}
%     end.
    
% %     nkmedia_sip:register_incoming(Req, {nkmedia_session, SessId}),


% % Version that generates a Janus proxy before going on
% nkmedia_sip_invite(_SrvId, Dest, Offer, SipLink, _Req, _Call) ->
%     Base = #{
%         offer => Offer, 
%         register => SipLink, 
%         backend => nkmedia_janus
%     },
%     {Base2, SessLink} = insert_janus_proxy(Base),
%     case incoming(Dest, Base2) of
%         {ok, _, _} ->
%             {ok, SessLink};
%         {error, Error} ->
%             {rejected, Error}
%     end.



% insert_janus_proxy(Base) ->
%     Base2 = Base#{backend => nkmedia_janus},
%     {ok, SessId, SessPid} = start_session(proxy, Base#{}),
%     {ok, Offer2} = nkmedia_session:cmd(SessId, get_proxy_offer, #{}),
%     Base3 = maps:remove(register, Base2),
%     Base4 = Base3#{offer=>Offer2, master_id=>SessId, set_master_answer=>true},
%     {Base4, {nkmedia_session, SessId, SessPid}}.





    % {nkmedia_session, SessId, _} = Link2,
    % nkmedia_sip:register_incoming(Req, {nkmedia_session, SessId}),
    % % Since we are registering as {nkmedia_session, ..}, the second session
    % % will be linked with the first, and will send answer back
    % % We return {ok, Link} or {rejected, Reason}
    % % nkmedia_sip will store that Link
    % case incoming(Dest, #{offer=>Offer2, peer_id=>SessId}) of
    %     {ok, {nkmedia_session, SessId2, _SessPid2}} ->
    %         {ok, {nkmedia_session, SessId2}};
    %     {rejected, Rejected} ->
    %         {rejected, Rejected}
    % end.







% % Version that go directly to FS
% nkmedia_sip_invite(_SrvId, {sip, Dest, _}, Offer, Req, _Call) ->
%     {ok, Handle} = nksip_request:get_handle(Req),
%     {ok, Dialog} = nksip_dialog:get_handle(Req),
%     Link = {nkmedia_sip, {Handle, Dialog}, self()},
%     incoming(Offer#{dest=>Dest}, Link).


% % Version that calls Verto Directly
% nkmedia_sip_invite(SrvId, {sip, Dest, _}, Offer, Req, _Call) ->
%     case find_user(Dest) of
%         {webrtc, WebRTC} ->
%             {ok, Handle} = nksip_request:get_handle(Req),
%             {ok, Dialog} = nksip_dialog:get_handle(Req),
%             Config = #{
%                 offer => Offer,
%                 register => {nkmedia_sip, {Handle, Dialog}, self()}
%             },
%             {offer, Offer2, Link2} = start_session(proxy, Config),
%             {nkmedia_session, SessId2, _} = Link2,
%             case WebRTC of
%                 {nkmedia_verto, VertoPid} ->
%                     % Verto will send the answer or hangup to the session
%                     ok = nkmedia_verto:invite(VertoPid, SessId, Offer2, 
%                                               {nkmedia_session, SessId, SessPid}),
%                     {ok, _} = 
%                         nkmedia_session:register(SessId, {nkmedia_verto, Pid}),
%                     {ok, Link2};
%                 {error, Error} ->
%                     {rejected, Error}
%             end;
%         not_found ->
%             {rejected, user_not_found}
%     end.



