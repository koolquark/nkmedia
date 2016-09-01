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
%% - Register a Verto or a Janus (videocall) (not using direct Verto connections here)
%%   - Call e for Janus echo
%%     Verto/Janus register with the session on start as {nkmedia_verto, CallId, Pid}
%%     The session returns its Link, and it is registered with Janus/Verto
%%     When the sessions answers, Verto/Janus get the answer from their callback
%%     modules (nkmedia_session_reg_event). Same if it stops normally.
%%     If the session is killed it is detected by both
%%     If you hangup, nkmedia_verto_bye (or _janus_) stops the session
%%     If Verto/Janus is killed, it is detected by the session
%%     If the caller starts sending Trickle ICE requests (Janus client), they will be
%%     capture in nkmedia_janus_candidate and sent to the session
%%   - fe, p, p2, m1, m2 work the same way
%%   - start a listener with listen(Publisher, Num)
%%     This is the first operarion where we "call". We can reject the call, or accept it
%%     We create a session that generates an offer, and call Verto/Janus,
%%     then we register Verto/Janus with the session
%%     When Verto/Janus answers, their nkmedia_..._answer functions (or rejected) 
%%     sets the answer or stops the session (nkmedia_..._bye).
%%     If the caller starts sending candidates, is like above
%%     If the callee sends candidates, they again will be sent to the session, but
%%     with role 'callee', so that they will be processed correctly at nkmedia_janus_op
%%     and nkmedia_kms_op
%%   - d to call other party directly
%%   - j to call other party with Janus. Both parties are rgistered
%%   - f to call with FS
%%     We first starts a session in park state
%%     Then we start another with "call" and the id of the first. When it answers,
%%     sends a message to the first an both enter bridge.
%%     After that can use update_type con echo, park, or fs_call again
%%     Use park_after_bridge
%%   
%%  - Register a SIP Phone
%%    - Incoming. When a call arrives, we create a proxy session with janus  
%%      and register {nkmedia_sip, in, Pid} with it. 
%%      We call nkmedia_sip:register_incoming to store handle and dialog in SIP's 
%%      We can call any destination (d1009, j1009, etc. all should work), 
%%      and we start a second session (registered with {nkmedia_session, ...}) 
%%      so that when it answers, sends the answer back to the first. 
%%      SIP detects the answer in nkmedia_sip_calls (nkmedia_session_reg_event),
%%      finds the Handle and answers. If we can cancel, sip_cancel find the session
%%      When the answer arrives, it is detected in nkmedia_session_reg_event
%%      If we send BYE, the session is found in sip_bye
%%      If the session stops, it is detected in nkmedia_session_reg_event
%%    - Outcoming. When any invite example calls to a registered SIP endpoint,
%%      the option sdp_type=rtp is added (recognized by all backends)
%%      If we use "j...", we call send_invite with proxy 
%%      (Janus will generate the SIP offer) or we use "f..." we first start a 
%%      session A and then launch the send_invite with type call, and FS will 
%%      make the SIP offer.
%%      Then we call nkmedia_sip:send_invite thant launchs the invite and registers
%%      data for callbacks and dialogs.
%%      When receiving events, calls nkmedia_sip_invite_... in callbacks module,
%%      rejecting the session or setting the answer. When the sessions 
%%      (or the second session in the FS case, and sends it to the first) has the
%%      answer, the caller (Verto, etc.) is notified as above.
%%      If the sessions stops, sip detects it in nkmedia_sip_callbacks
%%      (nkmedia_session_reg_event), if the BYE we locate and stop the session.


-module(nkmedia_test).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-compile([export_all]).

-define(LOG_SAMPLE(Type, Txt, Args, State),
    lager:Type("API Test (~s) "++Txt, [maps:get(user, State) | Args])).

-include_lib("nkservice/include/nkservice.hrl").
-include_lib("nksip/include/nksip.hrl").




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
        sip_listen => "sip:all:9012",
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


update_media(SessId, Media) ->
    nkmedia_session:update(SessId, media, Media).


listen(Room, Pos, Dest) ->
    {ok, #{backend:=Backend, publishers:=Pubs}} = nkmedia_room:get_room(Room),
    Pub = lists:nth(Pos, maps:keys(Pubs)),
    Config = #{
        publisher_id => Pub,
        backend => Backend,
        use_video => true
    },
    start_invite(listen, Config, Dest).


listen_swich(SessId, Pos) ->
    {ok, listen, #{room_id:=Room}, _} = nkmedia_session:get_type(SessId),
    {ok, #{publishers:=Pubs}} = nkmedia_room:get_room(Room),
    Pub = lists:nth(Pos, maps:keys(Pubs)),
    nkmedia_session:update(SessId, listen_switch, #{publisher_id=>Pub}).


invite(Dest, Type, Opts) ->
    Opts2 = maps:merge(#{backend => nkmedia_kms}, Opts),
    start_invite(Type, Opts2, Dest).



update_type(SessId, Type, Opts) ->
    nkmedia_session:update(SessId, session_type, Opts#{session_type=>Type}).


mcu_layout(SessId, Layout) ->
    Layout2 = nklib_util:to_binary(Layout),
    nkmedia_session:update(SessId, mcu_layout, #{mcu_layout=>Layout2}).


% fs_call(SessId, Dest) ->
%     Config = #{master_id=>SessId, park_after_bridge=>true},
%     case start_invite(call, Config, Dest) of
%         {ok, _SessLinkB} ->
%             ok;
%         {rejected, Error} ->
%             lager:notice("Error in start_invite: ~p", [Error]),
%             nkmedia_session:stop(SessId)
%    end.


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


% nkmedia_verto_invite(_SrvId, _CallId, Offer, Verto) ->
%     {ok, Op} = nkmedia_kms_op:start(<<"nk_kms_aa38ayw_8888">>, <<>>),
%     Now = nklib_util:l_timestamp(),
%     {ok, Answer} = nkmedia_kms_op:echo(Op, Offer, #{}),
%     lager:error("TIME: ~p msec", [(nklib_util:l_timestamp() - Now) div 1000]),
%     {answer, Answer, {nkmedia_kms_op, Op}, Verto}.

% @private Called when we receive INVITE from Verto
% We register with the session as {nkmedia_verto, CallId, Pid}, and with the 
% verto server as {nkmedia_session, SessId, Pid}.
% Answer and Hangup of the session are detected in nkmedia_verto_callbacks
% If verto hangups, it is detected in nkmedia_verto_bye in nkmedia_verto_callbacks
% If verto dies, it is detected in the session because of the registration
% If the sessions dies, it is detected in verto because of the registration
nkmedia_verto_invite(_SrvId, CallId, Offer, Verto) ->
    #{dest:=Dest} = Offer, 
    Base = #{
        offer => Offer, 
        register => {nkmedia_verto, CallId, self()}, 
        no_answer_trickle_ice => true
    },
    case incoming(Dest, Base) of
        {ok, SessId, SessPid} ->
            {ok, {nkmedia_session, SessId, SessPid}, Verto};
        {error, Reason} ->
            lager:notice("Verto invite rejected ~p", [Reason]),
            {rejected, Reason, Verto}
    end.



%% ===================================================================
%% nkmedia_janus_proto callbacks
%% ===================================================================


% % @private Called when we receive INVITE from Janus
% nkmedia_janus_invite(_SrvId, _CallId, Offer, Janus) ->
%     {ok, OpPid} = nkmedia_kms_op:start(<<"nk_kms_aa38ayw_8888">>, <<>>),
%     JanusCallback = {nkmedia_janus_proto, candidate, [self()]},
%     {ok, Answer} = nkmedia_kms_op:echo(OpPid, Offer, #{callback=>JanusCallback}),
%     timer:sleep(2000),
%     {answer, Answer, {nkmedia_kms_op, OpPid}, Janus}.


% @private Called when we receive INVITE from Janus
nkmedia_janus_invite(_SrvId, CallId, Offer, Janus) ->
    #{dest:=Dest} = Offer, 
    Base = #{
        offer=>Offer, 
        register=>{nkmedia_janus, CallId, self()},
        no_answer_trickle_ice => true
    },
    case incoming(Dest, Base) of
        {ok, SessId, SessPid} ->
            {ok, {nkmedia_session, SessId, SessPid}, Janus};
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
%     {ok, Offer2} = nkmedia_session:update(SessId, get_proxy_offer, #{}),
%     Base3 = maps:remove(register, Base2),
%     Base4 = Base3#{offer=>Offer2, master_id=>SessId, set_master_answer=>true},
%     {Base4, {nkmedia_session, SessId, SessPid}}.




% Version that generates a Janus proxy before going on
nkmedia_sip_invite(_SrvId, Dest, Offer, SipLink, _Req, _Call) ->
    Base = #{
        offer => Offer, 
        register => SipLink, 
        backend => nkmedia_janus
    },
    {ok, SessId, SessPid} = start_session(proxy, Base#{}),
    {ok, Offer2} = nkmedia_session:update(SessId, get_proxy_offer, #{}),
    {nkmedia_verto, VertoPid} = find_user(1008),
    SessLink = {nkmedia_session, SessId, SessPid},
    lager:error("VERTO INVITE"),
    {ok, VertoLink} = nkmedia_verto:invite(VertoPid, SessId, Offer2, SessLink),
    {ok, _} = nkmedia_session:register(SessId, VertoLink),
    {ok, SessLink}.







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





%% ===================================================================
%% Internal
%% ===================================================================

incoming(<<"je">>, Base) ->
    Config = Base#{
        backend => nkmedia_janus, 
        use_audio => false,
        bitrate => 100000,
        record => true
    },
    start_session(echo, Config);

incoming(<<"fe">>, Base) ->
    Config = Base#{backend => nkmedia_fs},
    start_session(echo, Config);

incoming(<<"ke">>, Base) ->
    Config = Base#{backend => nkmedia_kms, use_data=>false},
    start_session(echo, Config);

incoming(<<"kp">>, Base) ->
    Config = Base#{backend => nkmedia_kms},
    start_session(park, Config);

incoming(<<"m1">>, Base) ->
    Config = Base#{room_id=>"mcu1"},
    start_session(mcu, Config);

incoming(<<"m2">>, Base) ->
    Config = Base#{room_id=>"mcu2"},
    start_session(mcu, Config);

incoming(<<"pj1">>, Base) ->
    nkmedia_room:start(test, #{room_id=>sfu, backend=>nkmedia_janus}),
    Config = Base#{room_id=>sfu, backend=>nkmedia_janus},
    start_session(publish, Config);

incoming(<<"pj2">>, Base) ->
    Config = Base#{
        room_audio_codec => pcma,
        room_video_codec => vp9,
        room_bitrate => 100000,
        backend => nkmedia_janus
    },
    start_session(publish, Config);


incoming(<<"p3">>, Base) ->
    nkmedia_room:start(test, #{room_id=>sfu, backend=>nkmedia_kms}),
    Config = Base#{room_id=>sfu1, backend=>nkmedia_kms},
    start_session(publish, Config);

incoming(<<"l3">>, Base) ->
    Config = Base#{backend=>nkmedia_kms, publisher_id=><<"6337fbc8-3ae8-6185-138e-38c9862f00d9_">>},
    start_session(listen, Config);

incoming(<<"play">>, Base) ->
    Config = Base#{backend=>nkmedia_kms},
    start_session(play, Config);

incoming(<<"d", Num/binary>>, Base) ->
    {ok, SessId, SessPid} = start_session(p2p, Base),
    start_invite_slave(p2p, {nkmedia_session, SessId, SessPid}, Base, Num);

incoming(<<"j", Num/binary>>, Base) ->
    Config = Base#{
        backend => nkmedia_janus
    },
    {ok, SessId, SessPid} = start_session(proxy, Config),
    lager:error("J1"),
    {ok, Offer2} = nkmedia_session:update(SessId, get_proxy_offer, #{}),
    lager:error("J2"),
    {ok, _, _} = start_invite_slave(callee, SessId, Config#{offer=>Offer2}, Num),
    lager:error("J3"),
    {ok, SessId, SessPid};

incoming(<<"f", Num/binary>>, Base) ->
    Config = Base#{
        park_after_bridge => true,
        backend => nkmedia_fs
    },
    {ok, SessId, SessPid} = start_session(park, Config),
    {ok, _, _} = start_invite_slave(bridge, SessId, Config#{peer_id=>SessId}, Num),
    {ok, SessId, SessPid};

incoming(<<"k", Num/binary>>, Base) ->
    Config = Base#{
        backend => nkmedia_kms
    },
    {ok, SessId, SessPid} = start_session(park, Config),
    {ok, _, _} = start_invite_slave(bridge, SessId, Config#{peer_id=>SessId}, Num),
    {ok, SessId, SessPid};

incoming(_, _Base) ->
    {rejected, no_destination}.


%% @private
start_session(Type, Config) ->
    nkmedia_session:start(test, Type, Config).


start_invite_slave(Type, SessId, Config, Dest) ->
    Config2 = maps:remove(register, Config),
    Config3 = Config2#{master_id=>SessId, set_master_answer=>true},
    start_invite(Type, Config3, Dest).


%% Creates a new 'B' session, gets an offer and invites a Verto, Janus or SIP endoint
start_invite(Type, Config, Dest) ->
    case find_user(Dest) of
        {nkmedia_verto, VertoPid} ->
            Config2 = Config#{no_offer_trickle_ice=>true},
            {ok, SessId, SessPid} = start_session(Type, Config2),
            % With this SessLink, when Verto answers it will send
            % the answer to the session (and detect session kill)
            {ok, Offer} = nkmedia_session:get_offer(SessId),
            SessLink = {nkmedia_session, SessId, SessPid},
            ok = nkmedia_verto:invite(VertoPid, SessId, Offer, SessLink),
            VertoLink = {nkmedia_verto, SessId, VertoPid},
            % With this VertoLink, verto can use nkmedia_session_reg_event()= to detect hangup (and Verto killed)
            {ok, _} = nkmedia_session:register(SessId, VertoLink),
            {ok, SessId, SessPid};
        {nkmedia_janus, JanusPid} ->
            Config2 = Config#{no_offer_trickle_ice=>true},
            {ok, SessId, SessPid} = start_session(Type, Config2),
            {ok, Offer} = nkmedia_session:get_offer(SessId),
            SessLink = {nkmedia_session, SessId, SessPid},
            ok = nkmedia_janus_proto:invite(JanusPid, SessId, Offer, SessLink),
            JanusLink = {nkmedia_janus, SessId, JanusPid},
            {ok, _} = nkmedia_session:register(SessId, JanusLink),
            {ok, SessId, SessPid};
        {nkmedia_sip, Uri, Opts} ->  
            Config2 = Config#{sdp_type=>rtp},
            {ok, SessId, SessPid} = start_session(Type, Config2),
            {ok, Offer} = nkmedia_session:get_offer(SessId),
            % With this SessLink, sip callbacks (sip_invite_ringing, etc.) will 
            % send the answer to the session
            SessLink = {nkmedia_session, SessId, SessPid},
            {ok, SipLink} = nkmedia_sip:send_invite(test, Uri, Offer, SessLink, Opts),
            % With this SipLink, sip can detect in nkmedia_session_reg_event()
            % when the session stops.
            {ok, _} = nkmedia_session:register(SessId, SipLink),
            {ok, SessId, SessPid};
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







