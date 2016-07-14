
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
-module(nkmedia_test_api).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-compile([export_all]).

-define(LOG_SAMPLE(Type, Txt, Args, State),
    lager:Type("API Sample (~s) "++Txt, [maps:get(user, State) | Args])).

-include_lib("nkservice/include/nkservice.hrl").


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
    Req = #api_req{class=media, subclass=session, cmd=Cmd, data=Data2},
    nkservice_api_client:cmd(C, Req).


subscribe(SessId, WsPid, Body) ->
    Data = #{class=>media, subclass=>session, obj_id=>SessId, body=>Body},
    Cmd = #api_req{class=core, subclass=event, cmd=subscribe, data=Data},
    lager:warning("SU: ~p", [Data]),
    nkservice_api_client:cmd(WsPid, Cmd).


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
        {ok, SessId, WsPid} ->
            {ok, {test_session, SessId, WsPid}, Verto};
        {answer, Answer, SessId, WsPid} ->
            {answer, Answer, {test_session, SessId, WsPid}, Verto};
        {rejected, Reason} ->
            lager:notice("Verto invite rejected ~p", [Reason]),
            {rejected, Reason, Verto}
    end.


%% @private Janus answers our invite
%% we register with the call as {nkmedia_verto, ...}
nkmedia_verto_answer(_CallId, {test_answer, SessId, WsPid}, Answer, Verto) ->
    case set_answer(WsPid, SessId, Answer) of
        {ok, _} -> 
            {ok, Verto};
        {error, Error} ->
            lager:notice("Verto: call rejected our answer: ~p", [Error]),
            {hangup, session_error, Verto}
    end.


% @private Called when we receive BYE from Verto
nkmedia_verto_bye(_CallId, {test_answer, SessId, WsPid}, Verto) ->
    lager:info("Verto Answer BYE for ~s (~p)", [SessId, WsPid]),
    nkservice_api_client:stop(WsPid),
    {ok, Verto};

nkmedia_verto_bye(_CallId, {test_session, SessId, WsPid}, Verto) ->
    lager:info("Verto Session BYE for ~s (~p)", [SessId, WsPid]),
    nkservice_api_client:stop(WsPid),
    {ok, Verto}.





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
        {ok, SessId, WsPid} ->
            {ok, {test_session, SessId, WsPid}, Janus};
        {answer, Answer, SessId, WsPid} ->
            {answer, Answer, {test_session, SessId, WsPid}, Janus};
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
    end.


%% @private BYE from Janus
nkmedia_janus_bye(_CallId, {test_session, SessId, WsPid}, Janus) ->
    lager:info("Janus Session BYE for ~s (~p)", [SessId, WsPid]),
    nkservice_api_client:stop(WsPid),
    {ok, Janus};

nkmedia_janus_bye(_CallId, {test_answer, SessId, WsPid}, Janus) ->
    lager:info("Janus Answer BYE for ~s (~p)", [SessId, WsPid]),
    nkservice_api_client:stop(WsPid),
    {ok, Janus}.






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
                    {answer, #{sdp=>SDP}, SessId, WsPid};
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
                    {answer, #{sdp=>SDP}, SessId, WsPid};
                {error, Error} ->
                    {rejected, Error}
            end;
        <<"p2">> ->
            nkmedia_janus_room:create(SrvId, #{id=><<"sfu">>, room_video_codec=>vp9}),
            Config = #{
                type => publish,
                offer => Offer,
                events_body => Data, 
                backend => nkmedia_janus
            },
            case start_session(User, Config) of
                {ok, SessId, WsPid, #{<<"answer">>:=#{<<"sdp">>:=SDP}}} ->
                    {answer, #{sdp=>SDP}, SessId, WsPid};
                {error, Error} ->
                    {rejected, Error}
            end;
        % <<"d", Num/binary>> ->
        %     % 1) We start a session, and we register it with the caller process
        %     % 2) We start a call, and register it with the session
        %     % 3) The call invites and registers a called process
        %     case find_user(Num) of
        %         {webrtc, Dest2} ->
        %             SessConfig = #{offer=>Offer, register=>ProcId},
        %             {ok, SessId, SessPid, #{}} = 
        %                 nkmedia_session:start(SrvId, p2p, SessConfig),
        %             CallConfig = #{offer=>Offer, session_id=>SessId},
        %             {ok, _CallId, _CallPid} = 
        %                 nkmedia_call:start(SrvId, Dest2, CallConfig),
        %             {ok, SessId, SessPid};
        %         not_found ->
        %             {rejected, user_not_found}
        %     end;
        % <<"j", Num/binary>> ->
        %     case find_user(Num) of
        %         {webrtc, Dest2} ->
        %             SessConfig = #{offer=>Offer, register=>ProcId},
        %             {ok, SessId, SessPid, #{offer:=Offer2}} = 
        %                 nkmedia_session:start(SrvId, proxy, SessConfig),
        %             CallConfig = #{offer=>Offer2, session_id=>SessId},
        %             {ok, _CallId, _CallPid} = 
        %                 nkmedia_call:start(SrvId, Dest2, CallConfig),
        %             {ok, SessId, SessPid};
        %         {rtp, Dest2} ->
        %             Config = #{offer=>Offer, proxy_type=>rtp},
        %             {ok, SessId, #{}} = nkmedia_session:start(SrvId, proxy, Config),
        %             {ok, _CallId} = nkmedia_call:start(SrvId, Dest2, #{}),
        %             {ok, SessId};
        %         not_found ->
        %             {rejected, user_not_found}
        %     end;
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
    % Url = "nkapic://media2.netcomposer.io:9010",
    Url = "nkapic://localhost:9010",
    {ok, _, C} = nkservice_api_client:start(test, Url, User, "p1", Fun, #{}),
    C.

start_session(User, Data) ->
    Pid = connect(User),
    Req =  #api_req{
        class = media,
        subclass = session,
        cmd = start,
        data = Data
    },
    case nkservice_api_client:cmd(Pid, Req) of
        {ok, #{<<"session_id">>:=SessId}=Res} -> {ok, SessId, Pid, Res};
        {error, {_Code, Txt}} -> {error, Txt}
    end.


api_client_fun(#api_req{class = <<"core">>, cmd = <<"event">>, data = Data}, UserData) ->
    Class = maps:get(<<"class">>, Data),
    Sub = maps:get(<<"subclass">>, Data, <<"*">>),
    Type = maps:get(<<"type">>, Data, <<"*">>),
    ObjId = maps:get(<<"obj_id">>, Data, <<"*">>),
    Body = maps:get(<<"body">>, Data, #{}),
    lager:notice("TEST CLIENT event ~s:~s:~s:~s: ~p", [Class, Sub, Type, ObjId, Body]),
    case {Class, Sub, Type} of
        {<<"media">>, <<"session">>, <<"stop">>} ->
            case Body of
                #{
                    <<"call_id">> := CallId,
                    <<"verto_pid">> := BinPid
                } ->
                    Pid = list_to_pid(binary_to_list(BinPid)),
                    nkmedia_verto:hangup(Pid, CallId);
                #{
                    <<"call_id">> := CallId,
                    <<"janus_pid">> := BinPid
                } ->
                    Pid = list_to_pid(binary_to_list(BinPid)),
                    nkmedia_janus_proto:hangup(Pid, CallId);
                _ ->
                    lager:notice("TEST CLIENT SESSION STOP: ~p", [Data])
            end,
            nkservice_api_client:stop(self());
        _ ->
            ok
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

