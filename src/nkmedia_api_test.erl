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
-module(nkmedia_api_test).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-compile([export_all]).

-define(LOG_SAMPLE(Type, Txt, Args, State),
    lager:Type("API Sample (~s) "++Txt, [maps:get(user, State) | Args])).

-include_lib("nkservice/include/nkservice.hrl").


% -define(URL, "nkapic://media2.netcomposer.io:9010").
-define(URL, "nkapic://127.0.0.1:9010").


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
        % sip_listen => <<"sip:all:5060">>,
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


update_media(C, SessId, Data) ->
    sess_cmd(C, update, SessId, Data#{type=>media}).


stop_session(C, SessId) ->
    sess_cmd(C, stop, SessId, #{}).


set_answer(C, SessId, Answer) ->
    sess_cmd(C, set_answer, SessId, #{answer=>Answer}).


sess_cmd(C, Cmd, SessId, Data) ->
    Data2 = Data#{session_id=>SessId},
    nkservice_api_client:cmd(C, media, session, Cmd, Data2).


subscribe(SessId, WsPid, Body) ->
    Data = #{class=>media, subclass=>session, obj_id=>SessId, body=>Body},
    nkservice_api_client:cmd(WsPid, core, event, subscribe, Data).


call_cmd(C, Cmd, CallId, Data) ->
    Data2 = Data#{call_id=>CallId},
    nkservice_api_client:cmd(C, media, call, Cmd, Data2).



get_client() ->
    [{_, C}|_] = nkservice_api_client:get_all(),
    C.



listen(Publisher, Dest) ->
    Config = #{
        type => listen,
        subscribe => false,
        % events_body => Data, 
        publisher=>Publisher, 
        use_video=>true
    },
    case start_session(<<"listen">>, Config) of
        {ok, SessId, WsPid, #{<<"offer">>:=#{<<"sdp">>:=SDP}}} ->
            case Dest of 
                {invite, User} ->
                    case find_user(User) of
                        {webrtc, {nkmedia_verto, Pid}} ->
                            BinPid = list_to_binary(pid_to_list(Pid)),
                            Body = #{call_id=>SessId, verto_pid=>BinPid},
                            subscribe(SessId, WsPid, Body),
                            ProcId = {test_answer, SessId, WsPid},
                            ok = nkmedia_verto:invite(Pid, SessId, #{sdp=>SDP}, ProcId);
                        {webrtc, {nkmedia_janus_proto, Pid}} ->
                            BinPid = list_to_binary(pid_to_list(Pid)),
                            Body = #{call_id=>SessId, janus_pid=>BinPid},
                            subscribe(SessId, WsPid, Body),
                            ProcId = {test_answer, SessId, WsPid},
                            ok = nkmedia_janus_proto:invite(Pid, SessId, #{sdp=>SDP}, ProcId);
                        not_found ->
                          {error, invalid_user}
                    end 
            end;
        {error, Error} ->
            {error, Error}
    end.


listen_swich(C, SessId, Publisher) ->
    sess_cmd(C, update, SessId, #{type=>listen_switch, publisher=>Publisher}).




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
nkmedia_verto_invite(SrvId, CallId, Offer, Verto) ->
    #{user:=User} = Verto,
    Data = #{
        call_id => CallId,
        verto_pid => list_to_binary(pid_to_list(self()))
    },
    case send_call(SrvId, Offer, User, Data) of
        {ok, ProcId} ->
            {ok, ProcId, Verto};
        {answer, Answer, ProcId} ->
            {answer, Answer, ProcId, Verto};
        {rejected, Reason} ->
            lager:notice("Verto invite rejected ~p", [Reason]),
            {rejected, Reason, Verto}
    end.


%% @private Verto answers our invite
%% we register with the call as {nkmedia_verto, ...}
nkmedia_verto_answer(_CallId, {test_answer, SessId, WsPid}, Answer, Verto) ->
    case set_answer(WsPid, SessId, Answer) of
        {ok, _} -> 
            {ok, Verto};
        {error, Error} ->
            lager:notice("Verto: call rejected our answer: ~p", [Error]),
            {hangup, session_error, Verto}
    end;

nkmedia_verto_answer(_CallId, _ProcId, _Answer, _Verto) ->
    continue.
    

% @private Called when we receive BYE from Verto
nkmedia_verto_bye(_CallId, {test_answer, SessId, WsPid}, Verto) ->
    lager:info("Verto Answer BYE for ~s (~p)", [SessId, WsPid]),
    nkservice_api_client:stop(WsPid),
    {ok, Verto};

nkmedia_verto_bye(_CallId, {test_session, SessId, WsPid}, Verto) ->
    lager:info("Verto Session BYE for ~s (~p)", [SessId, WsPid]),
    nkservice_api_client:stop(WsPid),
    {ok, Verto};

nkmedia_verto_bye(_CallId, _ProcId, _Verto) ->
    continue.



%% ===================================================================
%% nkmedia_janus_proto callbacks
%% ===================================================================


% @private Called when we receive INVITE from Janus
% We register at the sessison as {nkmedia_janus_proto, CallId, Pid},
% and with the janus server as {nkmedia_session, SessId, Pid}
nkmedia_janus_invite(SrvId, CallId, Offer, Janus) ->
    #{user:=User} = Janus,
    Data = #{
        call_id => CallId,
        janus_pid => list_to_binary(pid_to_list(self()))
    },
    case send_call(SrvId, Offer, User, Data) of
        {ok, ProcId} ->
            {ok, ProcId, Janus};
        {answer, Answer, ProcId} ->
            {answer, Answer, ProcId, Janus};
        {rejected, Reason} ->
            lager:notice("Janus invite rejected: ~p", [Reason]),
            {rejected, Reason, Janus}
    end.


%% @private Janus answers our call invite
%% we register with the call as {nkmedia_janus_proto, ...}
%% the call will 
nkmedia_janus_answer(_CallId, {test_answer, SessId, Pid}, Answer, Janus) ->
    case set_answer(Pid, SessId, Answer) of
        {ok, _} ->
            {ok, Janus};
        {error, Error} ->
            lager:notice("Janus: call rejected our answer: ~p", [Error]),
            {hangup, Error, Janus}
    end;

nkmedia_janus_answer(_CallId, _ProcId, _Answer, _Janus) ->
    continue.


%% @private BYE from Janus
nkmedia_janus_bye(_CallId, {test_session, SessId, WsPid}, Janus) ->
    lager:info("Janus Session BYE for ~s (~p)", [SessId, WsPid]),
    nkservice_api_client:stop(WsPid),
    {ok, Janus};

nkmedia_janus_bye(_CallId, {test_answer, SessId, WsPid}, Janus) ->
    lager:info("Janus Answer BYE for ~s (~p)", [SessId, WsPid]),
    nkservice_api_client:stop(WsPid),
    {ok, Janus};

nkmedia_janus_bye(_CallId, _ProcId, _Janus) ->
    continue.



%% ===================================================================
%% Call callbacks
%% ===================================================================






%% ===================================================================
%% Internal
%% ===================================================================

send_call(SrvId, #{dest:=Dest}=Offer, User, Data) ->
    case Dest of 
        <<"e">> ->
            Config = #{
                type => echo,
                offer => Offer,
                events_body => Data, 
                backend => nkmedia_janus, 
                record => true
            },
            case start_session(User, Config) of
                {ok, SessId, WsPid, #{<<"answer">>:=#{<<"sdp">>:=SDP}}} ->
                    {answer, #{sdp=>SDP}, {test_session, SessId, WsPid}};
                {error, Error} ->
                    {rejected, Error}
            end;
        % <<"fe">> ->
        %     Config = #{offer=>Offer, backend=>nkmedia_fs},
        %     {ok, SessId, #{answer:=Answer}} = nkmedia_session:start(SrvId, echo, Config),
        %     {ok, Answer} = nkmedia_session:get_answer(SessId),
        %     {answer, Answer, SessId};
        % <<"m1">> ->
        %     Config = #{offer=>Offer, room=>"mcu1"},
        %     {ok, SessId, #{answer:=Answer}} = nkmedia_session:start(SrvId, mcu, Config),
        %     {ok, Answer} = nkmedia_session:get_answer(SessId),
        %     {answer, Answer, SessId};
        % <<"m2">> ->
        %     Config = #{offer=>Offer, room=>"mcu2"},
        %     {ok, SessId, #{answer:=Answer}} = nkmedia_session:start(SrvId, mcu, Config),
        %     {ok, Answer} = nkmedia_session:get_answer(SessId),
        %     {answer, Answer, SessId};
        <<"p">> ->
            Config = #{
                type => publish,
                offer => Offer,
                events_body => Data, 
                backend => nkmedia_janus,
                room_audio_codec => pcma,
                room_video_codec => vp9,
                room_bitrate => 100000
            },
            case start_session(User, Config) of
                {ok, SessId, WsPid, #{<<"answer">>:=#{<<"sdp">>:=SDP}}} ->
                    {answer, #{sdp=>SDP}, {test_session, SessId, WsPid}};
                {error, Error} ->
                    {rejected, Error}
            end;
        <<"p2">> ->
            nkmedia_janus_room:create(SrvId, #{id=><<"sfu">>, room_video_codec=>vp9}),
            Config = #{
                type => publish,
                room => <<"sfu">>,
                offer => Offer,
                events_body => Data, 
                backend => nkmedia_janus
            },
            case start_session(User, Config) of
                {ok, SessId, WsPid, #{<<"answer">>:=#{<<"sdp">>:=SDP}}} ->
                    {answer, #{sdp=>SDP}, {test_session, SessId, WsPid}};
                {error, Error} ->
                    {rejected, Error}
            end;
        <<"d", Num/binary>> ->
            % We first create the session, then the call
            % If it is a verto destination, it will be captured in verto_callbacks
            % If the call is rejected, nkmedia_verto_rejected calls to
            % nkmedia_call:rejected.
            % If it accepted, nkmedia_verto_answer calls to nkmedia_call:answered,
            % and (since we included the session with the call) the answer is sent
            % to the session. The session sends the 'answer' event that is
            % captured in api_client_fun (we could also capture the call's answer event
            % and call ourselves to set_answer in the session)
            SessConfig = #{
                type => p2p,
                offer => Offer,
                events_body => Data
            },
            case start_session(User, SessConfig) of
                {ok, SessId, WsPid, #{}} ->
                    CallConfig = #{
                        callee => Num,
                        session_id => SessId,
                        offer => Offer,
                        events_body => Data
                    },
                    case start_call(WsPid, CallConfig) of
                        {ok, CallId} ->
                            {ok, {test_session, CallId, WsPid}};
                        {error, Error} ->
                            {rejected, Error}
                    end;
                {error, Error} ->
                    {rejected, Error}
            end;
        <<"j", Num/binary>> ->
            SessConfig = #{
                type => proxy,
                offer => Offer,
                events_body => Data
            },
            case  start_session(User, SessConfig) of
                {ok, SessId, WsPid, #{<<"offer">>:=Offer2}} ->
                    CallConfig = #{
                        callee => Num,
                        session_id => SessId,
                        offer => Offer2,
                        events_body => Data
                    },
                    case start_call(WsPid, CallConfig) of
                        {ok, CallId} ->
                            {ok, {test_session, CallId, WsPid}};
                        {error, Error} ->
                            {rejected, Error}
                    end;
                {error, Error} ->
                    {rejected, Error}
            end;


        % <<"f", Num/binary>> ->
        %     case find_user(Num) of
        %         {webrtc, Dest2} ->
        %             {ok, SessIdA, #{answer:=Answer}} = 
        %                 nkmedia_session:start(SrvId, park, #{offer=>Offer}),
        %             {ok, SessIdB, #{offer:=_}} = 
        %                 nkmedia_session:start(SrvId, park, #{bridge_to=>SessIdA}),
        %             {ok, _CallId} = nkmedia_call:start(SessIdB, Dest2, #{}),
        %             {answer, Answer, SessIdA};
        %         {rtp, Dest2} ->
        %             {ok, SessIdA, #{answer:=Answer}} = 
        %                 nkmedia_session:start(SrvId, park, #{offer=>Offer}),
        %             {ok, SessIdB, #{offer:=_}} = 
        %                 nkmedia_session:start(SrvId, park, 
        %                                       #{sdp_type=>rtp, bridge_to=>SessIdA}),
        %             {ok, _CallId} = nkmedia_call:start(SessIdB, Dest2, #{}),
        %             {answer, Answer, SessIdA};
        %         not_found ->
        %             {rejected, user_not_found}
        %     end;
        _ ->
            {rejected, no_destination}
    end.


connect(User) ->
    Fun = fun ?MODULE:api_client_fun/2,
    {ok, _, C} = nkservice_api_client:start(test, ?URL, User, "p1", Fun, #{}),
    C.

start_session(User, Data) ->
    Pid = connect(User),
    case nkservice_api_client:cmd(Pid, media, session, start, Data) of
        {ok, #{<<"session_id">>:=SessId}=Res} -> {ok, SessId, Pid, Res};
        {error, {_Code, Txt}} -> {error, Txt}
    end.

start_call(Pid, Data) ->
    case nkservice_api_client:cmd(Pid, media, call, start, Data) of
        {ok, #{<<"call_id">>:=CallId}} -> 
            {ok, CallId};
        {error, {_Code, Txt}} -> 
            {error, Txt}
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
            {verto, SCallId, list_to_pid(binary_to_list(BinPid))};
        #{
            <<"call_id">> := SCallId,
            <<"janus_pid">> := BinPid
        } ->
            {janus, SCallId, list_to_pid(binary_to_list(BinPid))};
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
                    nkmedia_janus_proto:answer(Pid, CallId, #{sdp=>SDP})
            end;
        {<<"media">>, <<"session">>, <<"stop">>} ->
            case Sender of
                {verto, CallId, Pid} ->
                    nkmedia_verto:hangup(Pid, CallId);
                {janus, CallId, Pid} ->
                    nkmedia_janus_proto:hangup(Pid, CallId);
                unknown ->
                    lager:notice("TEST CLIENT SESSION STOP: ~p", [Data])
            end,
            nkservice_api_client:stop(self());
        {<<"media">>, <<"call">>, <<"answer">>} ->
            ok;
        {<<"media">>, <<"call">>, <<"hangup">>} ->
            case Sender of
                {verto, CallId, Pid} ->
                    nkmedia_verto:hangup(Pid, CallId);
                {janus, CallId, Pid} ->
                    nkmedia_janus_proto:hangup(Pid, CallId);
                unknown ->
                    lager:notice("TEST CLIENT CALL STOP: ~p", [Data])
            end,
            nkservice_api_client:stop(self());
        _ ->
            lager:notice("TEST CLIENT event ~s:~s:~s:~s: ~p", 
                         [Class, Sub, Type, ObjId, Body])
    end,
    {ok, #{}, UserData};

api_client_fun(_Req, UserData) ->
    lager:notice("TEST CLIENT req: ~p", [lager:pr(_Req, ?MODULE)]),
    {error, not_implemented, UserData}.






find_user(User) ->
    case nkmedia_verto:find_user(User) of
        [Pid|_] ->
            {webrtc, {nkmedia_verto, Pid}};
        [] ->
            case nkmedia_janus_proto:find_user(User) of
                [Pid|_] ->
                    {webrtc, {nkmedia_janus_proto, Pid}};
                [] ->
                    case 
                        nkmedia_sip:find_registered(sample, User, <<"nkmedia_sample">>) 
                    of
                        [Uri|_] -> 
                            {rtp, {nkmedia_sip, Uri, #{}}};
                            []  -> not_found
                    end
            end
    end.

