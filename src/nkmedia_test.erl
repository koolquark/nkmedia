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
%% - Register a Verto or a Janus (videocall)
%%   - Call e for Janus echo
%%     Verto/Janus register with the session on start as {nkmedia_verto, CallId, Pid}
%%     The session returns its ProcId, and it is registered with Janus/Verto
%%     When the sessions answers, Verto/Janus get the answer from their callback
%%     modules (nkmedia_session_reg_event). Same if it stops normally.
%%     If the session is killed it is detected by both
%%     If you hangup, the functions nkmedia_verto_bye (/janus) stops the session
%%     If Verto/Janus is killed, it is detected by the session
%%   - fe, p, p2, m1, m2 work the same way
%%   - start a listener with listen(Publisher, {reg, Num})
%%     This is the first operarion where we "call". We can reject the call, or accept it
%%     We create a session that generates an offer, and call Verto/Janus,
%%     then we register Verto/Janus with the session
%%     When Verto/Janus answers, their nkmedia_..._answer functions (or rejected) 
%%     sets the answer or stops the session (nkmedia_..._bye).
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
%%      the option proxy_type=rtp is added (recognized by Janus and FS)
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
    Spec = #{
        callback => ?MODULE,
        web_server => "https:all:8081",
        web_server_path => "./www",
        api_server => "wss:all:9010",
        api_server_timeout => 180,
        verto_listen => "verto:all:8082",
        verto_proxy => "verto_proxy:all:8083",
        janus_listen => "janus:all:8989", 
        janus_proxy=> "janus_proxy:all:8990",
        kurento_proxy => "kms:all:8433",
        nksip_trace => {console, all},
        sip_listen => "sip:all:9012",
        log_level => debug
    },
    nkservice:start(test, Spec).


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
        nkmedia_kms, nkmedia_kms_proxy
    ].




%% ===================================================================
%% Cmds
%% ===================================================================


update_media(SessId, Media) ->
    nkmedia_session:update(SessId, media, Media).


listen(Publisher, Dest) ->
    Config = #{
        publisher => Publisher, 
        use_video => true
    },
    start_invite(listen, Config, Dest).

listen_swich(SessId, Publisher) ->
    nkmedia_session:update(SessId, listen_switch, #{publisher=>Publisher}).


update_type(SessId, Type, Opts) ->
    nkmedia_session:update(SessId, type, Opts#{type=>Type}).


mcu_layout(SessId, Layout) ->
    Layout2 = nklib_util:to_binary(Layout),
    nkmedia_session:update(SessId, mcu_layout, #{mcu_layout=>Layout2}).


fs_call(SessId, Dest) ->
    Config = #{peer=>SessId, park_after_bridge=>true},
    case start_invite(call, Config, {reg, Dest}) of
        {ok, _SessProcIdB} ->
            ok;
        {rejected, Error} ->
            lager:notice("Error in start_invite: ~p", [Error]),
            nkmedia_session:stop(SessId)
   end.


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
% We register with the session as {nkmedia_verto, CallId, Pid}, and with the 
% verto server as {nkmedia_session, SessId, Pid}.
% Answer and Hangup of the session are detected in nkmedia_verto_callbacks
% If verto hangups, it is detected in nkmedia_verto_bye in nkmedia_verto_callbacks
% If verto dies, it is detected in the session because of the registration
% If the sessions dies, it is detected in verto because of the registration
nkmedia_verto_invite(_SrvId, CallId, Offer, Verto) ->
    case send_call(Offer, {nkmedia_verto, CallId, self()}) of
        {ok, ProcId} ->
            {ok, ProcId, Verto};
        {answer, Answer, ProcId} ->
            {answer, Answer, ProcId, Verto};
        {rejected, Reason} ->
            lager:notice("Verto invite rejected ~p", [Reason]),
            {rejected, Reason, Verto}
    end.



%% ===================================================================
%% nkmedia_janus_proto callbacks
%% ===================================================================


% @private Called when we receive INVITE from Janus
nkmedia_janus_invite(_SrvId, CallId, Offer, Janus) ->
    case send_call(Offer, {nkmedia_janus, CallId, self()}) of
        {ok, ProcId} ->
            {ok, ProcId, Janus};
        {answer, Answer, ProcId} ->
            {answer, Answer, ProcId, Janus};
        {rejected, Reason} ->
            lager:notice("Janus invite rejected: ~p", [Reason]),
            {rejected, Reason, Janus}
    end.




%% ===================================================================
%% Sip callbacks
%% ===================================================================

sip_route(_Scheme, _User, _Domain, _Req, _Call) ->
    process.


sip_register(Req, Call) ->
    Req2 = nksip_registrar_util:force_domain(Req, <<"nkmedia">>),
    {continue, [Req2, Call]}.


% Version that generates a Janus proxy before going on
nkmedia_sip_invite(_SrvId, {sip, Dest, _}, Offer, Req, _Call) ->
    Config1 = #{offer=>Offer, register=>{nkmedia_sip, in, self()}},
    % We register with the session as {nkmedia_sip, ...}, so:
    % - we will detect the answer in nkmedia_sip_callbacks:nkmedia_session_reg_event
    % - we stop the session if thip process stops
    {offer, Offer2, ProcId2} = start_session(proxy, Config1),
    {nkmedia_session, SessId, _} = ProcId2,
    nkmedia_sip:register_incoming(Req, {nkmedia_session, SessId}),
    % Since we are registering as {nkmedia_session, ..}, the second session
    % will be linked with the first, and will send answer back
    % We return {ok, ProcId} or {rejected, Reason}
    % nkmedia_sip will store that ProcId
    send_call(Offer2#{dest=>Dest}, ProcId2).


% % Version that go directly to FS
% nkmedia_sip_invite(_SrvId, {sip, Dest, _}, Offer, Req, _Call) ->
%     {ok, Handle} = nksip_request:get_handle(Req),
%     {ok, Dialog} = nksip_dialog:get_handle(Req),
%     ProcId = {nkmedia_sip, {Handle, Dialog}, self()},
%     send_call(Offer#{dest=>Dest}, ProcId).


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
%             {offer, Offer2, ProcId2} = start_session(proxy, Config),
%             {nkmedia_session, SessId2, _} = ProcId2,
%             case WebRTC of
%                 {nkmedia_verto, VertoPid} ->
%                     % Verto will send the answer or hangup to the session
%                     ok = nkmedia_verto:invite(VertoPid, SessId, Offer2, 
%                                               {nkmedia_session, SessId, SessPid}),
%                     {ok, _} = 
%                         nkmedia_session:register(SessId, {nkmedia_verto, Pid}),
%                     {ok, ProcId2};
%                 {error, Error} ->
%                     {rejected, Error}
%             end;
%         not_found ->
%             {rejected, user_not_found}
%     end.





%% ===================================================================
%% Internal
%% ===================================================================

send_call(#{dest:=Dest}=Offer, ProcId) ->
    case Dest of 
        <<"e">> ->
            Config = #{
                offer => Offer, 
                backend => nkmedia_janus, 
                register => ProcId,
                record => false
            },
            start_session(echo, Config);
        <<"fe">> ->
            Config = #{
                offer => Offer, 
                backend => nkmedia_fs, 
                register => ProcId
            },
            start_session(echo, Config);
        <<"m1">> ->
            Config = #{offer=>Offer, room=>"mcu1", register=>ProcId},
            start_session(mcu, Config);
        <<"m2">> ->
            Config = #{offer=>Offer, room=>"mcu2", register=>ProcId},
            start_session(mcu, Config);
        <<"p">> ->
            Config = #{
                offer => Offer,
                register => ProcId,
                room_audio_codec => pcma,
                room_video_codec => vp9,
                room_bitrate => 100000
            },
            start_session(publish, Config);
        <<"p2">> ->
            nkmedia_janus_room:create(test, #{id=><<"sfu">>}),
            Config = #{offer=>Offer, room=><<"sfu">>, register=>ProcId},
            start_session(publish, Config);
        <<"d", Num/binary>> ->
            % We share the same session, with both caller and callee registered to it
            Config = #{offer => Offer, register => ProcId},
            start_invite(p2p, Config, {reg, Num});
        <<"j", Num/binary>> ->
            Config = #{offer => Offer, register => ProcId},
            start_invite(proxy, Config, {reg, Num});
        <<"f", Num/binary>> ->
            ConfigA = #{
                offer => Offer, 
                register => ProcId,
                park_after_bridge => true
            },
            case start_session(park, ConfigA) of
                {ok, SessProcIdA} ->
                    {nkmedia_session, SessIdA, _} = SessProcIdA,
                    ConfigB = #{peer=>SessIdA, park_after_bridge=>false},
                    spawn(
                        fun() -> 
                            case start_invite(call, ConfigB, {reg, Num}) of
                                {ok, _} -> 
                                    ok;
                                {rejected, Error} ->
                                    lager:notice("Error in start_invite: ~p", [Error]),
                                    nkmedia_session:stop(SessIdA)
                            end
                        end),
                    {ok, SessProcIdA};
                {error, Error} ->
                    {rejected, Error}
            end;
        _ ->
            {rejected, no_destination}
    end.


%% @private
start_session(Type, Config) ->
    case nkmedia_session:start(test, Type, Config) of
        {ok, SessId, SessPid, #{answer:=_}} ->
            % We don't return the answer since, Verto and Janus are going to 
            % detect it in their callbacks modules (nkmedia_session_reg_event) and
            % we would be sending two answers
            {ok, {nkmedia_session, SessId, SessPid}};
        {ok, SessId, SessPid, #{offer:=Offer}} ->
            {offer, Offer, {nkmedia_session, SessId, SessPid}};
        {ok, SessId, SessPid, #{}} ->
            Offer = maps:get(offer, Config),
            {offer, Offer, {nkmedia_session, SessId, SessPid}};
        {error, Error} ->
            {rejected, Error}
    end.


%% Creates a new session that must generate an offer (a p2p, proxy, listen or call)
%% Then invites Verto, Janus or SIP with that offer
start_invite(Type, Config, Dest) ->
    User = case Dest of
        {reg, Inv} -> find_user(Inv)
    end,
    Config2 = case User of
        {rtp, _} -> Config#{proxy_type=>rtp};
        _ -> Config
    end,
    case start_session(Type, Config2) of
        {offer, Offer, SessProcId} ->
            {nkmedia_session, SessId, _} = SessProcId,
            case User of 
                {webrtc, {nkmedia_verto, VertoPid}} ->
                    % With this SessProcId, when Verto answers it will send
                    % the answer to the session
                    % Also will detect session kill
                    ok = nkmedia_verto:invite(VertoPid, SessId, 
                                              Offer, SessProcId),
                    VertoProcId = {nkmedia_verto, SessId, VertoPid},
                    % With this VertoProcId, verto can use nkmedia_session_reg_event to detect hangup
                    % Also the session will detect Verto kill
                    {ok, _} = nkmedia_session:register(SessId, VertoProcId),
                    {ok, SessProcId};
                {webrtc, {nkmedia_janus, JanusPid}} ->
                    ok = nkmedia_janus_proto:invite(JanusPid, SessId, 
                                                    Offer, SessProcId),
                    JanusProcId = {nkmedia_janus, SessId, JanusPid},
                    {ok, _} = nkmedia_session:register(SessId, JanusProcId),
                    {ok, SessProcId};
                {rtp, {nkmedia_sip, Uri, Opts}} ->
                    Id = {nkmedia_session, SessId},
                    {ok, SipPid} = 
                        nkmedia_sip:send_invite(test, Uri, Offer, Id, Opts),
                    SipProcId = {nkmedia_sip, out, SipPid},
                    {ok, _} = nkmedia_session:register(SessId, SipProcId),
                    {ok, SessProcId};
                not_found ->
                    nkmedia_session:stop(SessId),
                    {rejected, unknown_user}
            end;
        {error, Error} ->
            {rejected, Error}
    end.


%% @private
find_user(User) ->
    User2 = nklib_util:to_binary(User),
    case nkmedia_verto:find_user(User2) of
        [Pid|_] ->
            {webrtc, {nkmedia_verto, Pid}};
        [] ->
            case nkmedia_janus_proto:find_user(User2) of
                [Pid|_] ->
                    {webrtc, {nkmedia_janus, Pid}};
                [] ->
                    case 
                        nksip_registrar:find(test, sip, User2, <<"nkmedia">>) 
                    of
                        [Uri|_] -> 
                            {rtp, {nkmedia_sip, Uri, []}};
                        []  -> 
                            not_found
                    end
            end
    end.

