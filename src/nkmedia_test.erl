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

%% @doc 
-module(nkmedia_test).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-compile([export_all]).

-define(LOG_SAMPLE(Type, Txt, Args, State),
    lager:Type("API Test (~s) "++Txt, [maps:get(user, State) | Args])).

-include_lib("nkservice/include/nkservice.hrl").
-include_lib("nksip/include/nksip.hrl").


% -define(URL, "nkapic://media2.netcomposer.io:9010").
-define(URL, "nkapic://127.0.0.1:9010").


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
    Config = #{peer_id=>SessId},
    case start_invite(call, Config, {invite, Dest}) of
        {ok, _SessProcIdB} ->
            ok;
        {error, Error} ->
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

% sip_route(_Scheme, _User, <<"192.168.0.100">>, _Req, _Call) ->
%     proxy;

sip_route(_Scheme, _User, _Domain, _Req, _Call) ->
    % lager:warning("User: ~p, Domain: ~p", [_User, _Domain]),
    process.


sip_register(Req, Call) ->
    Req2 = nksip_registrar_util:force_domain(Req, <<"nkmedia">>),
    {continue, [Req2, Call]}.


% nkmedia_sip_invite(SrvId, {sip, _Dest, _}, Offer, Req, _Call) ->
%     {ok, Handle} = nksip_request:get_handle(Req),
%     {ok, Dialog} = nksip_dialog:get_handle(Req),
%     Reg = {nkmedia_sip, {Handle, Dialog}, self()},
%     case nkmedia_session:start(SrvId, echo, #{offer=>Offer, register=>Reg}) of
%         {ok, _SessId, _SessPid, #{answer:=Answer}} ->
%             {reply, nksip_sdp:parse(Answer)};
%         {error, Error} ->
%             {rejected, Error}
%     end;


nkmedia_sip_invite(SrvId, {sip, Dest, _}, Offer, Req, _Call) ->
    % {ok, [{from_user, User}, {from_domain, _Domain}]} = 
    %     nksip_request:metas([from_user, from_domain], Req),
    case find_user(Dest) of
        {webrtc, WebRTC} ->
            {ok, Handle} = nksip_request:get_handle(Req),
            {ok, Dialog} = nksip_dialog:get_handle(Req),
            Reg = {nkmedia_sip, {Handle, Dialog}, self()},
            OfferA = Offer#{sdp_type=>webrtc},
            case nkmedia_session:start(SrvId, proxy, #{offer=>OfferA, register=>Reg}) of
                {ok, SessId, SessPid, #{offer:=Offer2}} ->
                    case WebRTC of
                        {nkmedia_verto, Pid} ->
                            % Verto will send the answer or hangup the session
                            ok = nkmedia_verto:invite(Pid, SessId, Offer2, 
                                                      {nkmedia_session, SessId, SessPid}),
                            {ok, _} = 
                                nkmedia_session:register(SessId, {nkmedia_verto, Pid}),
                            ok
                    end;
                {error, Error} ->
                    {rejected, Error}
            end;
        not_found ->
            {rejected, user_not_found}
    end;

nkmedia_sip_invite(_SrvId, _AOR, _Offer, _Req, _Call) ->
    continue.





%% ===================================================================
%% Session callbacks
%% ===================================================================

nkmedia_session_reg_event(_SessId, {nkmedia_sip, {Handle, Dialog}, _Pid}, 
                          Event, Session) ->
    case Event of
        {stop, _Reason} ->
            case Session of
                #{answer:=#{sdp:=_}} ->
                    nksip_uac:bye(Dialog, []);
                _ ->
                    lager:error("STOP2: ~p", [Handle]),
                    nksip_request:reply(decline, Handle)
            end;
        {answer, #{sdp:=SDP}} ->
            Body = nksip_sdp:parse(SDP),
            case nksip_request:reply({answer, Body}, Handle) of
                ok ->
                    ok;
                {error, Error} ->
                    lager:error("Error in SIP reply: ~p", [Error]),
                    nkmedia_session:hangup(self(), process_down)
            end;
        _ ->
            ok
    end,
    {ok, Session};

nkmedia_session_reg_event(_SessId, _ProcId, _Event, _Session) ->
    continue.


%% ===================================================================
%% Call callbacks
%% ===================================================================






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
            nkmedia_janus_room:create(test, #{id=><<"sfu">>, room_video_codec=>vp9}),
            Config = #{offer=>Offer, room=><<"sfu">>, register=>ProcId},
            start_session(publish, Config);
        <<"d", Num/binary>> ->
            % We share the same session, with both caller and callee registered to it
            Config = #{offer => Offer, register => ProcId},
            start_invite(p2p, Config, {invite, Num});
        <<"j", Num/binary>> ->
            Config = #{offer => Offer, register => ProcId},
            start_invite(proxy, Config, {invite, Num});
        <<"f", Num/binary>> ->
            ConfigA = #{
                offer => Offer, 
                register => ProcId,
                park_after_bridge => true
            },
            case start_session(park, ConfigA) of
                {ok, SessAProcId} ->
                    {nkmedia_session, SessIdA, _} = SessAProcId,
                    spawn(fun() -> fs_call(SessIdA, Num) end),
                    {ok, SessAProcId};
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


start_invite(Type, Config, Dest) ->
    case start_session(Type, Config) of
        {offer, Offer, SessProcId} ->
            {nkmedia_session, SessId, _} = SessProcId,
            case Dest of 
                {invite, User} ->
                    case find_user(User) of
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
                        not_found ->
                            nkmedia_session:stop(SessId),
                            {error, invalid_user}
                    end 
            end;
        {error, user_not_found} ->
            {error, user_not_found}
    end.


%% @private
find_user(User) ->
    case nkmedia_verto:find_user(User) of
        [Pid|_] ->
            {webrtc, {nkmedia_verto, Pid}};
        [] ->
            case nkmedia_janus_proto:find_user(User) of
                [Pid|_] ->
                    {webrtc, {nkmedia_janus, Pid}};
                [] ->
                    case 
                        nksip_registrar:find(test, sip, User, <<"nkmedia">>) 
                    of
                        [Uri|_] -> 
                            {rtp, {nkmedia_sip, Uri, #{}}};
                        []  -> 
                            not_found
                    end
            end
    end.

