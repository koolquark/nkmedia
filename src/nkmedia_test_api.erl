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

%% @doc Testing the media API
%% After testing the media system form the Erlang interface (nkmedia_test)
%% here we test sending everything through the API interface.
%% When Verto or Janus call to the machine (e, fe, p, m1, etc.) they start a new
%% API connection, and create the session over it. They program the event system
%% do that answers and stops are detected in api_client_fun.
%% If they send BYE, verto_bye and janus_by are overloaded here also.
%% 
%% For a listener, start_invite is used, that generates a session over the API,
%% gets the offer over the wire a do a standard (as in nkmedia_test) invite, directly
%% to the session and without API. However, when Verto or Janus replies, the 
%% answer is capured here and sent over the wire.
%% 
%% For FS calls, the client starts two sessions over the API, the seconds one
%% is connected to the invite

-module(nkmedia_test_api).
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

%% Connect

connect(User) ->
    Fun = fun ?MODULE:api_client_fun/2,
    {ok, _, C} = nkservice_api_client:start(test, ?URL1, User, "p1", Fun, #{}),
    C.

connect2(User) ->
    Fun = fun ?MODULE:api_client_fun/2,
    {ok, _, C} = nkservice_api_client:start(test, ?URL2, User, "p1", Fun, #{}),
    C.

get_client() ->
    [{_, C}|_] = nkservice_api_client:get_all(),
    C.



%% Session

stop_session(C, SessId) ->
    sess_cmd(C, stop, SessId, #{}).

set_answer(C, SessId, Answer) ->
    sess_cmd(C, set_answer, SessId, #{answer=>Answer}).

sess_cmd(C, Cmd, SessId, Data) ->
    Data2 = Data#{session_id=>SessId},
    nkservice_api_client:cmd(C, media, session, Cmd, Data2).


%% Update

update_media(C, SessId, Data) ->
    update(C, SessId, media, Data).

update_layout(C, SessId, Layout) ->
    Layout2 = nklib_util:to_binary(Layout),
    update(C, SessId, mcu_layout, #{mcu_layout=>Layout2}).

update_type(C, SessId, Type, Data) ->
    update(C, SessId, session_type, Data#{session_type=>Type}).

update_listen(C, SessId, Publisher) ->
    update(C, SessId, listen_switch, #{publisher=>Publisher}).

update(C, SessId, Type, Data) ->
    sess_cmd(C, update, SessId, Data#{type=>Type}).


%% Room

room_list(C) ->
    room_cmd(C, list, #{}).

room_create(C, Data) ->
    room_cmd(C, create, Data).

room_destroy(C, Id) ->
    room_cmd(C, destroy, #{id=>Id}).

room_info(C, Id) ->
    room_cmd(C, info, #{id=>Id}).

room_cmd(C, Cmd, Data) ->
    nkservice_api_client:cmd(C, media, room, Cmd, Data).


%% Events

subscribe(SessId, WsPid, Body) ->
    Data = #{class=>media, subclass=>session, obj_id=>SessId, body=>Body},
    nkservice_api_client:cmd(WsPid, core, event, subscribe, Data).



%% Invite

listen(Publisher, Dest) ->
    Config = #{
        type => listen,
        subscribe => false,
        % events_body => Data, 
        publisher=>Publisher, 
        use_video=>true
    },
    start_invite(listen, Dest, Config).


 

%% ===================================================================
%% api server callbacks
%% ===================================================================


%% @doc Called on login
api_server_login(#{<<"user">>:=User, <<"pass">>:=_Pass}, _SessId, State) ->
    nkservice_api_server:start_ping(self(), 60),
    {true, User, State};

api_server_login(_Data, _SessId, _State) ->
    continue.


%% @doc
api_allow(_Req, State) ->
    {true, State}.


%% @oc
api_subscribe_allow(_SrvId, _Class, _SubClass, _Type, State) ->
    {true, State}.




%% ===================================================================
%% nkmedia_verto callbacks
%% ===================================================================

nkmedia_verto_login(Login, Pass, Verto) ->
    nkmedia_test:nkmedia_verto_login(Login, Pass, Verto).


% @private Called when we receive INVITE from Verto
nkmedia_verto_invite(_SrvId, CallId, Offer, Verto) ->
    #{dest:=Dest} = Offer,
    #{user:=User} = Verto,
    Base = #{
        offer => Offer,
        events_body => #{
            call_id => CallId,
            verto_pid => pid2bin(self())
        }
    },
    case send_call(Dest, User, Base) of
        {ok, ProcId} ->
            {ok, ProcId, Verto};
        {answer, Answer, ProcId} ->
            {answer, Answer, ProcId, Verto};
        {rejected, Reason} ->
            lager:notice("Verto invite rejected ~p", [Reason]),
            {rejected, Reason, Verto}
    end.

nkmedia_verto_answer(_CallId, {nkmedia_session, SessId, _Pid}, Answer, Verto) ->
    AnyClient = get_client(),
    {ok, _} = set_answer(AnyClient, SessId, Answer),
    {ok, Verto};

nkmedia_verto_answer(_CallId, _ProcId, _Answer, Verto) ->
    {ok, Verto}.


% @private Called when we receive BYE from Verto
nkmedia_verto_bye(_CallId, {test_api_session, SessId, WsPid}, Verto) ->
    lager:info("Verto Session BYE for ~s (~p)", [SessId, WsPid]),
    {ok, _} = stop_session(WsPid, SessId),
    timer:sleep(2000),
    nkservice_api_client:stop(WsPid),
    {ok, Verto};

nkmedia_verto_bye(_CallId, _ProcId, _Verto) ->
    continue.



%% ===================================================================
%% nkmedia_janus_proto callbacks
%% ===================================================================


% @private Called when we receive INVITE from Janus
nkmedia_janus_invite(_SrvId, CallId, Offer, Janus) ->
    #{dest:=Dest} = Offer,
    #{user:=User} = Janus,
    Base = #{
        offer => Offer,
        events_body => #{
            call_id => CallId,
            janus_pid => pid2bin(self())
        }
    },
    case send_call(Dest, User, Base) of
        {ok, ProcId} ->
            {ok, ProcId, Janus};
        {answer, Answer, ProcId} ->
            {answer, Answer, ProcId, Janus};
        {rejected, Reason} ->
            lager:notice("Janus invite rejected: ~p", [Reason]),
            {rejected, Reason, Janus}
    end.


nkmedia_janus_answer(_CallId, {nkmedia_session, SessId, _Pid}, Answer, Janus) ->
    AnyClient = get_client(),
    {ok, _} = set_answer(AnyClient, SessId, Answer),
    {ok, Janus};

nkmedia_janus_answer(_CallId, _ProcId, _Answer, Janus) ->
    {ok, Janus}.


%% @private BYE from Janus
nkmedia_janus_bye(_CallId, {test_api_session, SessId, WsPid}, Janus) ->
    lager:notice("Janus Session BYE for ~s (~p)", [SessId, WsPid]),
    {ok, _} = stop_session(WsPid, SessId),
    timer:sleep(2000),
    nkservice_api_client:stop(WsPid),
    {ok, Janus};

nkmedia_janus_bye(_CallId, _ProcId, _Janus) ->
    continue.






%% ===================================================================
%% Internal
%% ===================================================================

send_call(<<"e">>, User, Base) ->
    Config = Base#{
        type => echo,
        backend => nkmedia_janus, 
        record => false
    },
    start_session(User, Config);

send_call(<<"fe">>, User, Base) ->
    Config = Base#{
        type => echo,
        backend => nkmedia_fs
    },
    start_session(User, Config);

send_call(<<"m1">>, User, Base) ->
    Config = Base#{type=>mcu, room=>"mcu1"},
    start_session(User, Config);

send_call(<<"m2">>, User, Base) ->
    Config = Base#{type=>mcu, room=>"mcu2"},
    start_session(User, Config);

send_call(<<"p">>, User, Base) ->
    Config = Base#{
        type => publish,
        room_audio_codec => pcma,
        room_video_codec => vp9,
        room_bitrate => 100000
    },
    start_session(User, Config);

send_call(<<"p2">>, User, Base) ->
    nkmedia_janus_room:create(test, #{id=><<"sfu">>}),
    Config = Base#{type=>publish, room=><<"sfu">>},
    start_session(User, Config);

send_call(<<"d", Num/binary>>, _User, Base) ->
    % We share the same session, with both caller and callee registered to it
    start_invite(send_call, Num, Base#{type=>p2p});

send_call(<<"j", Num/binary>>, _User, Base) ->
    start_invite(send_call, Num, Base#{type=>proxy});

send_call(<<"f", Num/binary>>, User, Base) ->
    ConfigA = Base#{
        type => park,
        park_after_bridge => true
    },
    {answer, AnswerA, SessProcIdA} = start_session(User, ConfigA),
    {test_api_session, SessIdA, WsPid} = SessProcIdA,
    ConfigB = #{type=>call, peer=>SessIdA, park_after_bridge=>false},
    spawn(
        fun() -> 
            case start_invite(WsPid, Num, ConfigB) of
                {ok, _SessProcIdB} ->
                    ok;
                {rejected, Error} ->
                    lager:notice("Error in start_invite: ~p", [Error]),
                    nkmedia_session:stop(SessIdA)
            end
        end),
    {answer, AnswerA, SessProcIdA};

send_call(_, _User, _Base) ->
    {rejected, no_destination}.


start_session(WsPid, Data) when is_pid(WsPid) ->
    case nkservice_api_client:cmd(WsPid, media, session, start, Data) of
        {ok, #{<<"session_id">>:=SessId}=Res} -> 
            case Res of
                #{<<"answer">>:=#{<<"sdp">>:=SDP}} ->
                    {answer, #{sdp=>SDP}, {test_api_session, SessId, WsPid}};
                #{<<"offer">>:=#{<<"sdp">>:=SDP}} ->
                    {offer, #{sdp=>SDP}, {test_api_session, SessId, WsPid}};
                _ ->
                    {offer, maps:get(offer, Data), {test_api_session, SessId, WsPid}}
            end;
        {error, {_Code, Txt}} -> 
            {error, Txt}
    end;

start_session(User, Data) ->
    WsPid = connect(User),
    true = is_pid(WsPid),
    start_session(WsPid, Data).


start_invite(User, Num, Config) ->
    Dest = nkmedia_test:find_user(Num),
    Config2 = case Dest of
        {rtp, _} -> Config#{proxy_type=>rtp};
        _ -> Config
    end,
    {offer, Offer, SessProcId} = start_session(User, Config2),
    {test_api_session, SessId, _WsPid} = SessProcId,
    {ok, SessPid} = nkmedia_session:find(SessId), 
    case Dest of 
        {webrtc, {nkmedia_verto, VertoPid}} ->
            ok = nkmedia_verto:invite(VertoPid, SessId, 
                                      Offer, {nkmedia_session, SessId, SessPid}),
            VertoProcId = {nkmedia_verto, SessId, VertoPid},
            {ok, _} = nkmedia_session:register(SessId, VertoProcId),
            {ok, SessProcId};
        {webrtc, {nkmedia_janus, JanusPid}} ->
            ok = nkmedia_janus_proto:invite(JanusPid, SessId, 
                                      Offer, {nkmedia_session, SessId, SessPid}),
            JanusProcId = {nkmedia_janus, SessId, JanusPid},
            {ok, _} = nkmedia_session:register(SessId, JanusProcId),
            {ok, SessProcId};
        not_found ->
            nkmedia_session:stop(SessId),
            {rejected, unknown_user}
    end.



api_client_fun(#api_req{class = <<"core">>, cmd = <<"event">>, data = Data}, UserData) ->
    Class = maps:get(<<"class">>, Data),
    Sub = maps:get(<<"subclass">>, Data, <<"*">>),
    Type = maps:get(<<"type">>, Data, <<"*">>),
    ObjId = maps:get(<<"obj_id">>, Data, <<"*">>),
    Body = maps:get(<<"body">>, Data, #{}),
    Sender = case Body of
        #{
            <<"call_id">> := SCallId,
            <<"verto_pid">> := BinPid
        } ->
            {verto, SCallId, bin2pid(BinPid)};
        #{
            <<"call_id">> := SCallId,
            <<"janus_pid">> := BinPid
        } ->
            {janus, SCallId,  bin2pid(BinPid)};
        _ ->
            unknown
    end,
    case {Class, Sub, Type} of
        {<<"media">>, <<"session">>, <<"answer">>} ->
            #{<<"answer">>:=#{<<"sdp">>:=SDP}} = Body,
            case Sender of
                {verto, CallId, Pid} ->
                    nkmedia_verto:answer(Pid, CallId, #{sdp=>SDP});
                {janus, CallId, Pid} ->
                    nkmedia_janus_proto:answer(Pid, CallId, #{sdp=>SDP});
                unknown ->
                    lager:notice("TEST CLIENT ANSWER: ~p", [Data])
            end;
        {<<"media">>, <<"session">>, <<"stop">>} ->
            case Sender of
                {verto, CallId, Pid} ->
                    nkmedia_verto:hangup(Pid, CallId);
                {janus, CallId, Pid} ->
                    nkmedia_janus_proto:hangup(Pid, CallId);
                unknown ->
                    lager:notice("TEST CLIENT SESSION STOP: ~p", [Data])
            end;
        _ ->
            lager:notice("TEST CLIENT event ~s:~s:~s:~s: ~p", 
                         [Class, Sub, Type, ObjId, Body])
    end,
    {ok, #{}, UserData};

api_client_fun(_Req, UserData) ->
    lager:notice("TEST CLIENT req: ~p", [lager:pr(_Req, ?MODULE)]),
    {error, not_implemented, UserData}.


pid2bin(Pid) -> list_to_binary(pid_to_list(Pid)).
bin2pid(Bin) -> list_to_pid(binary_to_list(Bin)).
