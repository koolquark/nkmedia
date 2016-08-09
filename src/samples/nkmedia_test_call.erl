
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

%% @doc Testing the call system
%% We can test here:
%% 
%% 1) A Verto or Janus session connects (using call creation over API) to a 
%%    registered Verto session
%%    - Janus or Verto calls "v..."
%%    - They create a session and register with it (to get answer and down)
%%    - They start a call over the API, with type 'verto', linked with the session
%%    - At the server, Verto plugin captures the call resolve and call invite, and
%%      calls directly to Verto
%%    - If it answers, send the answer to the call, and the call to the session. 
%%      We caller receive only the call event (we didn't subscribe to session events)
%%      Since we registered as {nkmedia_verto, _, _}, the caller Janus or Verto will
%%      detect the answer automatically. Otherwise, we need to get the answer from the
%%      call, send it to the session, and get the new answer, or susbcribe to session
%%      events (and leave the call linked with the session)
%%    - If we reject, we call nkmedia_call:rejected
%%    - Tested with several Verto terminals with the same name. 
%% 
%% 2) A session (Janus or Verto) calls to another session
%%    - Janus/Verto calls without the "v". Type "user" is selected
%%    - nkmedia_api finds all users and send INVITEs
%%    - Invites are captured in api_client_fund, ringing is sent
%%    - We call Veto or Janus invite, and waits for answer, also managing bye
%%    - Tested calling from Janus to several Vertos. CANCEL is captured in verto_callbacks
%%    - For Verto incoming, need to implement nkmedia_verto_invite like here
%%
%% 3) Calling to SIP
%%    - When Janus/Verto calls to a number starting with "s" is is understood
%%      as a SIP destionation. Can be a registered user, with or without domain,
%%      or a full SIP address
%%
%% 4) Incoming SIOP
%%
%%

%% 



-module(nkmedia_test_call).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-compile([export_all]).

-define(LOG_SAMPLE(Type, Txt, Args, State),
    lager:Type("API Sample (~s) "++Txt, [maps:get(user, State) | Args])).

-include_lib("nkservice/include/nkservice.hrl").
-include_lib("nksip/include/nksip.hrl").

-define(URL1, "nkapic://127.0.0.1:9010").
-define(URL2, "nkapic://media2.netcomposer.io:9010").


%% ===================================================================
%% Public
%% ===================================================================


start() ->
    _CertDir = code:priv_dir(nkpacket),
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
        sip_listen => <<"sip:all:9012">>,
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

%% Connect

connect(User, Data) ->
    Fun = fun ?MODULE:api_client_fun/2,
    {ok, _, C} = nkservice_api_client:start(test, ?URL1, User, "p1", Fun, Data),
    C.

connect2(User, Data) ->
    Fun = fun ?MODULE:api_client_fun/2,
    {ok, _, C} = nkservice_api_client:start(test, ?URL2, User, "p1", Fun, Data),
    C.



call_cmd(C, Cmd, Data) ->
    nkservice_api_client:cmd(C, media, call, Cmd, Data).



%% ===================================================================
%% api server callbacks
%% ===================================================================


%% @doc Called on login
api_server_get_user_pass(_User, State) ->    
    {true, State}.
    

%% @doc
api_allow(_Req, State) ->
    {true, State}.


%% @oc
api_subscribe_allow(_SrvId, _Class, _SubClass, _Type, State) ->
    {true, State}.





%% ===================================================================
%% nkmedia_verto callbacks
%% ===================================================================

nkmedia_verto_login(<<"test", _/binary>>=User, Pass, Verto) ->
    nkmedia_test:nkmedia_verto_login(User, Pass, Verto);

nkmedia_verto_login(Login, Pass, Verto) ->
    lager:error("LOG: ~p", [Login]),
    case nkmedia_test:nkmedia_verto_login(Login, Pass, Verto) of
        {true, User, Verto2} ->
            Pid = connect(User, #{test_verto_server=>self()}),
            {true, User, Verto2#{test_api_server=>Pid}};
        Other ->
            Other
    end.


nkmedia_verto_invite(_SrvId, CallId, Offer, #{test_api_server:=Ws}=Verto) ->
    #{dest:=Dest} = Offer,
    Events = #{
        verto_call_id => CallId,
        verto_pid => pid2bin(self())
    },
    Link = {nkmedia_verto, CallId, self()},
    case start_call(CallId, Dest, Ws, Offer, Events, Link) of
        {ok, Link2} ->
            {ok, Link2, Verto};
        {rejected, Reason} ->
            lager:notice("Verto invite rejected ~p", [Reason]),
            {rejected, Reason, Verto}
    end;

nkmedia_verto_invite(_SrvId, _CallId, _Offer, _Verto) ->
    continue.


nkmedia_verto_answer(CallId, {test_call, CallId, WsPid}, Answer, Verto) ->
    #{test_api_server:=WsPid} = Verto,
    case call_cmd(WsPid, answered, #{call_id=>CallId, answer=>Answer}) of
        {ok, #{}} ->
            %% Call will get the answer and send it back to the session
            ok;
        {error, Error} ->
            lager:notice("VERTO CALL REJECTED: ~p", [Error]),
            nkmedia_verto:hangup(self(), CallId)
    end,
    {ok, Verto};

nkmedia_verto_answer(_CallId, _Link, _Answer, _Verto) ->
    continue.


nkmedia_verto_rejected(CallId, {test_call, CallId, WsPid}, Verto) ->
    #{test_api_server:=WsPid} = Verto,
    call_cmd(WsPid, rejected, #{call_id=>CallId}),
    {ok, Verto};

nkmedia_verto_rejected(_CallId, _Link, _Verto) ->
    continue.


nkmedia_verto_bye(CallId, {test_call, CallId, WsPid}, Verto) ->
    #{test_api_server:=WsPid} = Verto,
    call_cmd(WsPid, hangup, #{call_id=>CallId}),
    {ok, Verto};

nkmedia_verto_bye(_CallId, _Link, _Verto) ->
    continue.


nkmedia_verto_terminate(_Reason, #{test_api_server:=Pid}=Verto) ->
    nkservice_api_client:stop(Pid),
    {ok, Verto}.



%% ===================================================================
%% nkmedia_janus_proto callbacks
%% ===================================================================


nkmedia_janus_registered(User, Janus) ->
    Pid = connect(User, #{test_janus_server=>self()}),
    {ok, Janus#{test_api_server=>Pid}}.


% @private Called when we receive INVITE from Janus
nkmedia_janus_invite(_SrvId, CallId, Offer, #{test_api_server:=Ws}=Janus) ->
    #{dest:=Dest} = Offer,
    Events = #{
        janus_call_id => CallId,
        janus_pid => pid2bin(self())
    },
    Link = {nkmedia_janus, CallId, self()},
    case start_call(CallId, Dest, Ws, Offer, Events, Link) of
        {ok, Link2} ->
            {ok, Link2, Janus};
        {rejected, Reason} ->
            lager:notice("Janus invite rejected ~p", [Reason]),
            {rejected, Reason, Janus}
    end.


nkmedia_janus_answer(CallId, {test_call, CallId, WsPid}, Answer, Janus) ->
    #{test_api_server:=WsPid} = Janus,
    case call_cmd(WsPid, answered, #{call_id=>CallId, answer=>Answer}) of
        {ok, #{}} ->
            %% Call will get the answer and send it back to the session
            ok;
        {error, Error} ->
            lager:notice("JANUS CALL REJECTED: ~p", [Error]),
            nkmedia_janus_proto:hangup(self(), CallId)
    end,
    {ok, Janus};

nkmedia_janus_answer(_CallId, _Link, _Answer, _Janus) ->
    continue.


nkmedia_janus_bye(CallId, {test_call, VCallId, _Pid}, #{test_api_server:=Ws}=Verto) ->
    CallId = VCallId,
    {ok, #{}} = call_cmd(Ws, hangup, #{call_id=>CallId, reason=><<"Janus Stop">>}),
    {ok, Verto};

nkmedia_janus_bye(_CallId, _Link, _Verto) ->
    continue.


nkmedia_janus_terminate(_Reason, #{test_api_server:=Pid}=Janus) ->
    nkservice_api_client:stop(Pid),
    {ok, Janus}.



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
% nkmedia_sip_invite(_SrvId, {sip, Dest, _}, Offer, Req, _Call) ->
%     Config1 = #{offer=>Offer, register=>{nkmedia_sip, in, self()}},
%     % We register with the session as {nkmedia_sip, ...}, so:
%     % - we will detect the answer in nkmedia_sip_callbacks:nkmedia_session_reg_event
%     % - we stop the session if thip process stops
%     {offer, Offer2, Link2} = start_session(proxy, Config1),
%     {nkmedia_session, SessId, _} = Link2,
%     nkmedia_sip:register_incoming(Req, {nkmedia_session, SessId}),
%     % Since we are registering as {nkmedia_session, ..}, the second session
%     % will be linked with the first, and will send answer back
%     % We return {ok, Link} or {rejected, Reason}
%     % nkmedia_sip will store that Link
%     send_call(Dest, #{offer=>Offer2, peer=>SessId}).


% % Version that go directly to FS
% nkmedia_sip_invite(_SrvId, {sip, Dest, _}, Offer, Req, _Call) ->
%     {ok, Handle} = nksip_request:get_handle(Req),
%     {ok, Dialog} = nksip_dialog:get_handle(Req),
%     Link = {nkmedia_sip, {Handle, Dialog}, self()},
%     send_call(Offer#{dest=>Dest}, Link).


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

start_call(CallId, Dest, WsPid, Offer, Events, Link) ->
    {Type, Callee, ProxyType} = case Dest of
        <<"v", Rest/binary>> -> {verto, Rest, webrtc};
        <<"s", Rest/binary>> -> {sip, Rest, rtp};
        _ -> {user, Dest, webrtc}
    end,
    SessConfig = #{
        backend => nkmedia_janus, 
        proxy_type => ProxyType,
        offer => Offer,
        register => Link
    },
    {ok, SessId, SessPid, #{offer:=Offer2}} = 
        nkmedia_session:start(test, proxy, SessConfig),
    CallConfig = #{
        id => CallId,
        type => Type,         
        callee => Callee, 
        offer => Offer2, 
        session_id => SessId,
        events_body => Events, 
        meta => #{module=>?MODULE}
    },
    % We start a call, link the ws session with the call, and subscribe to events
    case call_cmd(WsPid, start, CallConfig) of
        {ok, #{<<"call_id">>:=CallId}} -> 
            {ok, {nkmedia_session, SessId, SessPid}};
        Other ->
            nkmedia_session:stop(SessId),
            nkservice_api_client:stop(WsPid),
            {rejected, {call_error, Other}}
    end.



api_client_fun(#api_req{class = <<"core">>, cmd = <<"event">>, data = Data}, UserData) ->
    Class = maps:get(<<"class">>, Data),
    Sub = maps:get(<<"subclass">>, Data, <<"*">>),
    Type = maps:get(<<"type">>, Data, <<"*">>),
    ObjId = maps:get(<<"obj_id">>, Data, <<"*">>),
    Body = maps:get(<<"body">>, Data, #{}),
    Sender = case Body of
        #{
            <<"verto_call_id">> := SCallId,
            <<"verto_pid">> := BinPid
        } ->
            {verto, SCallId, bin2pid(BinPid)};
        #{
            <<"janus_call_id">> := SCallId,
            <<"janus_pid">> := BinPid
        } ->
            {janus, SCallId,  bin2pid(BinPid)};
        _ ->
            unknown
    end,
    case {Class, Sub, Type} of
        {<<"media">>, <<"call">>, <<"answer">>} ->
            ok;
        {<<"media">>, <<"call">>, <<"hangup">>} ->
            case Sender of
                {verto, CallId, Pid} ->
                    nkmedia_verto:hangup(Pid, CallId);
                {janus, CallId, Pid} ->
                    nkmedia_janus_proto:hangup(Pid, CallId);
                unknown ->
                    case UserData of
                        #{test_janus_server:=Pid} ->
                            nkmedia_janus_proto:hangup(Pid, ObjId);
                        #{test_verto_server:=Pid} ->
                            nkmedia_verto:hangup(Pid, ObjId)
                    end
            end;
        _ ->
            lager:notice("TEST CLIENT event ~s:~s:~s:~s: ~p", 
                         [Class, Sub, Type, ObjId, Body])
    end,
    {ok, #{}, UserData};

api_client_fun(#api_req{cmd= <<"invite">>, data=Data}, UserData) ->
    #{<<"call_id">>:=CallId, <<"offer">>:=Offer} = Data,
    lager:info("INVITE: ~p", [UserData]),
    Self = self(),
    spawn(
        fun() ->
            call_cmd(Self, ringing, #{call_id=>CallId}),
            case UserData of
                #{test_janus_server:=JanusPid} ->
                    timer:sleep(1000),
                    Link = {test_call, CallId, Self},
                    #{<<"sdp">>:=SDP} = Offer,
                    ok = nkmedia_janus_proto:invite(JanusPid, CallId, #{sdp=>SDP}, Link);
                #{test_verto_server:=VertoPid} ->
                    Link = {test_call, CallId, Self},
                    #{<<"sdp">>:=SDP} = Offer,
                    ok = nkmedia_verto:invite(VertoPid, CallId, #{sdp=>SDP}, Link)
            end
        end),
    {ok, #{}, UserData};

api_client_fun(#api_req{subclass = <<"call">>, cmd= <<"hangup">>, data=Data}, UserData) ->
    #{<<"call_id">>:=_CallId} = Data,
    lager:error("HANGUP ~p", [UserData]),
    {ok, #{}, UserData};

api_client_fun(_Req, UserData) ->
    lager:notice("TEST CLIENT req: ~p", [lager:pr(_Req, ?MODULE)]),
    {error, not_implemented, UserData}.


pid2bin(Pid) -> list_to_binary(pid_to_list(Pid)).
bin2pid(Bin) -> list_to_pid(binary_to_list(Bin)).
