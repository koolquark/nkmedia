
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

%% @doc Testing the call system (try after nkmedia_test and nkmedia_test_api)
%% We can test here:
%% 
%% 1) Normal call
%%    - A Verto or Janus session connects to a registered user
%%    - A session is started, registers with Janus or Verto process, and viceversa
%%    - A call is started over API
%%    - The other party receives the INVITE (api_client_fun) and send ringing back.
%%      Then create the Janus/Verto invite, registered as {test_ call, Id Pid}
%%      If they answer, we capture it in this file and send the answer.
%%      Same if rejected
%%    - If it answers, send the answer to the call, and the call to the session. 
%%      We caller receive only the call event (we didn't subscribe to session events)
%%      Since we registered as {nkmedia_verto, _, _}, the caller Janus or Verto will
%%      detect the answer automatically. Otherwise, we need to get the answer from the
%%      call, send it to the session, and get the new answer, or susbcribe to session
%%      events (and leave the call linked with the session)
%%
%% 2) Connect to a 'default' Verto session
%%    - Start a verto session as vXXXXX
%%    - Janus or Verto calls to a connected user vXXXXX
%%    - Similar to previous case, but the call type is "verto"
%%    - At the server, Verto plugin captures the call, resolve and call invite, and
%%      calls directly to Verto
%%    - Verto either rejects or acceptes the call, sending the answer to the call,
%%      and the call to the session.
%%    - If this Verto instance calls, the default implementation of nkmedia_verto_invite
%%      will start a session (linked with it) and a call. 
%%    - Destinations "p2p:", "verto:", "sip:" and standard are accepted
%% 
%% 3) Calling to SIP
%%    - All SIP processing is standard SIP plugin behaviour
%%    - When normal Janus/Verto calls to a number starting with "s" is is understood
%%      as a SIP destionation. Can be a registered user, with or without domain,
%%      or a full SIP address
%%    - From native verto instances (registered as vXXXX), use sip:...
%%    - If receive a call from SIP, it is accepted "sip-", "verto-" or normal user
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
    Spec1 = #{
        callback => ?MODULE,
        plugins => [nkmedia_janus, nkmedia_fs, nkmedia_kms],  %% Call janus->fs->kms
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
        log_level => debug,
        api_gelf_server => "c2.netc.io"
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
        nkmedia_sip, nksip_registrar, nksip_trace,
        nkmedia_verto, nkmedia_janus_proto,
        nkmedia_fs, nkmedia_kms, nkmedia_janus,
        nkmedia_fs_verto_proxy, 
        nkmedia_janus_proxy, 
        nkmedia_kms_proxy,
        nkservice_api_gelf,
        nkmedia_room_msglog
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

get_client() ->
    [{_, C}|_] = nkservice_api_client:get_all(),
    C.



call_cmd(C, Cmd, Data) ->
    nkservice_api_client:cmd(C, media, call, Cmd, Data).



%% ===================================================================
%% api server callbacks
%% ===================================================================


%% @doc Called on login
api_server_login(Data, SessId, State) ->
    nkmedia_test_api:api_server_login(Data, SessId, State).


%% @doc
api_allow(Req, State) ->
    nkmedia_test_api:api_allow(Req, State).


%% @oc
api_subscribe_allow(SrvId, Class, SubClass, Type, State) ->
    nkmedia_test_api:api_subscribe_allow(SrvId, Class, SubClass, Type, State).




%% ===================================================================
%% nkmedia_verto callbacks
%% ===================================================================

%% @private
% If the login is tXXXX, an API session is emulated (not Verto specific)
% Without t, it is a 'standard' verto Session
nkmedia_verto_login(Login, Pass, Verto) ->
    case nkmedia_test:nkmedia_verto_login(Login, Pass, Verto) of
        {true, <<"t", _/binary>>=User, Verto2} ->
            Pid = connect(User, #{test_verto_server=>self()}),
            {true, User, Verto2#{test_api_server=>Pid}};
        {true, User, Verto2} ->
            {true, User, Verto2};
        Other ->
            Other
    end.


%% @private Verto but using API Call emulation
nkmedia_verto_invite(_SrvId, CallId, Offer, #{test_api_server:=Ws}=Verto) ->
    true = is_process_alive(Ws),
    #{dest:=Dest} = Offer,
    Events = #{
        verto_call_id => CallId,
        verto_pid => pid2bin(self())
    },
    Link = {nkmedia_verto, CallId, self()},
    case start_call(Dest, Offer, CallId, Ws, Events, Link) of
        {ok, Link2} ->
            {ok, Link2, Verto};
        {rejected, Reason} ->
            lager:notice("Verto invite rejected ~p", [Reason]),
            {rejected, Reason, Verto}
    end;

%% @private Standard Verto calling (see default implementation)
nkmedia_verto_invite(_SrvId, _CallId, _Offer, _Verto) ->
    continue.


%% @private
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


%% @private
nkmedia_verto_rejected(CallId, {test_call, CallId, WsPid}, Verto) ->
    #{test_api_server:=WsPid} = Verto,
    call_cmd(WsPid, rejected, #{call_id=>CallId}),
    {ok, Verto};

nkmedia_verto_rejected(_CallId, _Link, _Verto) ->
    continue.


%% @private
nkmedia_verto_bye(CallId, {test_call, CallId, WsPid}, Verto) ->
    #{test_api_server:=WsPid} = Verto,
    call_cmd(WsPid, hangup, #{call_id=>CallId}),
    {ok, Verto};

nkmedia_verto_bye(_CallId, _Link, _Verto) ->
    continue.


%% @private
nkmedia_verto_terminate(Reason, Verto) ->
    nkmedia_test_api:nkmedia_verto_terminate(Reason, Verto).


%% ===================================================================
%% nkmedia_janus_proto callbacks
%% ===================================================================


%% @private
nkmedia_janus_registered(User, Janus) ->
    Pid = connect(User, #{test_janus_server=>self()}),
    {ok, Janus#{test_api_server=>Pid}}.


% @private Called when we receive INVITE from Janus
nkmedia_janus_invite(_SrvId, CallId, Offer, #{test_api_server:=Ws}=Janus) ->
    true = is_process_alive(Ws),
    #{dest:=Dest} = Offer,
    Events = #{
        janus_call_id => CallId,
        janus_pid => pid2bin(self())
    },
    Link = {nkmedia_janus, CallId, self()},
    case start_call(Dest, Offer, CallId, Ws, Events, Link) of
        {ok, Link2} ->
            {ok, Link2, Janus};
        {rejected, Reason} ->
            lager:notice("Janus invite rejected ~p", [Reason]),
            {rejected, Reason, Janus}
    end.


%% @private
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


%% @private
nkmedia_janus_bye(CallId, {test_call, VCallId, _Pid}, #{test_api_server:=Ws}=Verto) ->
    CallId = VCallId,
    {ok, #{}} = call_cmd(Ws, hangup, #{call_id=>CallId, reason=><<"Janus Stop">>}),
    {ok, Verto};

nkmedia_janus_bye(_CallId, _Link, _Verto) ->
    continue.


%% @private
nkmedia_janus_terminate(Reason, Janus) ->
    nkmedia_test_api:nkmedia_janus_terminate(Reason, Janus).



%% ===================================================================
%% Sip callbacks
%% ===================================================================


%% @private
nks_sip_connection_sent(SipMsg, _Packet) ->
    case SipMsg#sipmsg.cseq of
        {_, 'REGISTER'} -> ok;
        _ -> continue
    end.

%% @private
nks_sip_connection_recv(SipMsg, _Packet) ->
    case SipMsg#sipmsg.cseq of
        {_, 'REGISTER'} -> ok;
        _ -> continue
    end.



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
incoming(<<"j", Num/binary>>, Offer, CallId, WsPid, Events, Opts) ->
    MasterConfig = incoming_config(nkmedia_janus, proxy, Offer, Events, Opts),
    {ok, SessId, SessPid} = nkmedia_test_api:start_session(WsPid, MasterConfig),
    CallConfig = #{
        call_id => CallId,
        callee => Num, 
        invite => #{module=>?MODULE}, 
        session_id => SessId,
        events_body => Events
    },
    % We start a call, link the ws session with the call, and subscribe to events
    case call_cmd(WsPid, start, CallConfig) of
        {ok, #{<<"call_id">>:=CallId}} -> 
            {ok, {nkmedia_session, SessId, SessPid}};
        Other ->
            nkmedia_session:stop(SessId),
            {error, {call_error, Other}}
    end.


start_call(Dest, Offer, CallId, WsPid, Events, Link) ->
    {Type, Backend, Callee, ProxyType} = case Dest of
        <<"jv", _/binary>> -> {verto, nkmedia_janus, Dest, webrtc};
        <<"kv", _/binary>> -> {verto, nkmedia_kms, Dest, webrtc};
        <<"s", Rest/binary>> -> {sip, Rest, rtp};
        _ -> {user, Dest, webrtc}
    end,
    SessConfig = #{
        backend => Backend, 
        sdp_type => ProxyType,
        offer => Offer,
        register => Link
    },
    {ok, SessId, SessPid} = nkmedia_session:start(test, proxy, SessConfig),
    {ok, Offer2} = nkmedia_session:cmd(SessId, get_proxy_offer),
    CallConfig = #{
        call_id => CallId,
        type => Type,         
        callee => Callee, 
        invite => #{offer=>Offer2, module=>?MODULE}, 
        session_id => SessId,
        events_body => Events
    },
    % We start a call, link the ws session with the call, and subscribe to events
    case call_cmd(WsPid, start, CallConfig) of
        {ok, #{<<"call_id">>:=CallId}} -> 
            {ok, {nkmedia_session, SessId, SessPid}};
        Other ->
            nkmedia_session:stop(SessId),
            {error, {call_error, Other}}
    end.


%% @private
incoming_config(Backend, Type, Offer, Events, Opts) ->
    Opts#{
        backend => Backend, 
        type => Type, 
        offer => Offer, 
        events_body => Events
    }.


%% @private
start_call(WsPid, Callee, Config) ->
    case call_cmd(WsPid, start, Config#{callee=>Callee}) of
        {ok, #{<<"call_id">>:=_CallId}} -> 
            ok;
        {error, Error} ->
            {error, Error}
    end.


%% @private
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
    lager:notice("TEST CLIENT2 req: ~p", [lager:pr(_Req, ?MODULE)]),
    {error, not_implemented, UserData}.


pid2bin(Pid) -> list_to_binary(pid_to_list(Pid)).
bin2pid(Bin) -> list_to_pid(binary_to_list(Bin)).
