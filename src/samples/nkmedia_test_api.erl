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
%%
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
-define(URL2, "nkapic://c1.netc.io:9010").


%% ===================================================================
%% Public
%% ===================================================================


start() ->
    _CertDir = code:priv_dir(nkpacket),
    Spec = #{
        callback => ?MODULE,
        plugins => [nkmedia_janus, nkmedia_fs, nkmedia_kms],
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

        api_gelf_server => "c1.netc.io"
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
        nkmedia_verto, nkmedia_janus_proto,
        nkmedia_fs, nkmedia_kms, nkmedia_janus,
        nkmedia_fs_verto_proxy, nkmedia_janus_proxy, nkmedia_kms_proxy,
        nkservice_api_gelf
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



%% Session

session_stop(C, SessId) ->
    sess_cmd(C, stop, SessId, #{}).

session_info(C, SessId) ->
    sess_cmd(C, info, SessId, #{}).

session_answer(C, SessId, Answer) ->
    sess_cmd(C, set_answer, SessId, #{answer=>Answer}).

session_list(C) ->
    nkservice_api_client:cmd(C, media, session, list, #{}).

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
    update(C, SessId, listen_switch, #{publisher_id=>Publisher}).

update(C, SessId, Type, Data) ->
    sess_cmd(C, update, SessId, Data#{update_type=>Type}).


%% Room

room_list(C) ->
    room_cmd(C, list, #{}).

room_create(C, Data) ->
    room_cmd(C, create, Data).

room_destroy(C, Id) ->
    room_cmd(C, destroy, #{room_id=>Id}).

room_info(C, Id) ->
    room_cmd(C, info, #{room_id=>Id}).

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
        publisher_id=>Publisher, 
        use_video=>true
    },
    WsPid = get_client(),
    start_invite(WsPid, Dest, Config).


 

%% ===================================================================
%% api server callbacks
%% ===================================================================


%% @doc Called on login
api_server_login(#{<<"user">>:=User}, _SessId, State) ->
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
    case nkmedia_test:nkmedia_verto_login(Login, Pass, Verto) of
        {true, <<"verto-", _/binary>>=User, Verto2} ->
            {true, User, Verto2};
        {true, User, Verto2} ->
            Pid = connect(User, #{test_verto_server=>self()}),
            {true, User, Verto2#{test_api_server=>Pid}};
        Other ->
            Other
    end.


% @private Called when we receive INVITE from Verto
% We start a session (registered with the API server) and
% the verto session is registerd as {test_session, Id, Pid}
% When we are called, we are registered as {nkmedia_session...}
nkmedia_verto_invite(_SrvId, CallId, Offer, #{test_api_server:=Ws}=Verto) ->
    #{dest:=Dest} = Offer,
    Base = #{
        offer => Offer,
        events_body => #{
            verto_call_id => CallId,
            verto_pid => pid2bin(self())
        }
    },
    case send_call(Dest, Ws, Base) of
        {ok, Link} ->
            {ok, Link, Verto};
        {answer, Answer, Link} ->
            {answer, Answer, Link, Verto};
        {rejected, Reason} ->
            lager:notice("Verto invite rejected ~p", [Reason]),
            {rejected, Reason, Verto}
    end;

nkmedia_verto_invite(_SrvId, _CallId, _Offer, _Verto) ->
    continue.


%% @private
nkmedia_verto_answer(_CallId, {nkmedia_session, SessId, _Pid}, Answer, 
                     #{test_api_server:=Ws}=Verto) ->
    {ok, _} = session_answer(Ws, SessId, Answer),
    {ok, Verto};

nkmedia_verto_answer(_CallId, _Link, _Answer, Verto) ->
    {ok, Verto}.


% @private Called when we receive BYE from Verto
nkmedia_verto_bye(_CallId, {test_session, SessId, WsPid}, Verto) ->
    #{test_api_server:=WsPid} = Verto,
    lager:info("Verto Session BYE for ~s (~p)", [SessId, WsPid]),
    {ok, _} = session_stop(WsPid, SessId),
    {ok, Verto};

nkmedia_verto_bye(_CallId, _Link, _Verto) ->
    continue.

%% @private
nkmedia_verto_terminate(_Reason, #{test_api_server:=Pid}=Verto) ->
    nkservice_api_client:stop(Pid),
    {ok, Verto};

nkmedia_verto_terminate(_Reason, Verto) ->
    {ok, Verto}.



%% ===================================================================
%% nkmedia_janus_proto callbacks
%% ===================================================================

%% @private
nkmedia_janus_registered(User, Janus) ->
    Pid = connect(User, #{test_janus_server=>self()}),
    {ok, Janus#{test_api_server=>Pid}}.


% @private Called when we receive INVITE from Janus
nkmedia_janus_invite(_SrvId, CallId, Offer, #{test_api_server:=Ws}=Janus) ->
    #{dest:=Dest} = Offer,
    Base = #{
        offer => Offer,
        events_body => #{
            janus_call_id => CallId,
            janus_pid => pid2bin(self())
        }
    },
    case send_call(Dest, Ws, Base) of
        {ok, Link} ->
            {ok, Link, Janus};
        {answer, Answer, Link} ->
            {answer, Answer, Link, Janus};
        {rejected, Reason} ->
            lager:notice("Janus invite rejected: ~p", [Reason]),
            {rejected, Reason, Janus}
    end.


nkmedia_janus_answer(_CallId, {nkmedia_session, SessId, _Pid}, Answer, 
                     #{test_api_server:=Ws}=Janus) ->
    {ok, _} = session_answer(Ws, SessId, Answer),
    {ok, Janus};

nkmedia_janus_answer(_CallId, _Link, _Answer, Janus) ->
    {ok, Janus}.


%% @private BYE from Janus
nkmedia_janus_bye(_CallId, {test_session, SessId, WsPid}, Janus) ->
    lager:notice("Janus Session BYE for ~s (~p)", [SessId, WsPid]),
    {ok, _} = session_stop(WsPid, SessId),
    {ok, Janus};

nkmedia_janus_bye(_CallId, _Link, _Janus) ->
    continue.


%% @private
nkmedia_janus_terminate(_Reason, #{test_api_server:=Pid}=Janus) ->
    nkservice_api_client:stop(Pid),
    {ok, Janus};

nkmedia_janus_terminate(_Reason, Janus) ->
    {ok, Janus}.





%% ===================================================================
%% Internal
%% ===================================================================

send_call(<<"e">>, WsPid, Base) ->
    Config = Base#{
        type => echo,
        backend => nkmedia_janus, 
        record => false
    },
    start_session(WsPid, Config);

send_call(<<"fe">>, WsPid, Base) ->
    Config = Base#{
        type => echo,
        backend => nkmedia_fs
    },
    start_session(WsPid, Config);

send_call(<<"m1">>, WsPid, Base) ->
    Config = Base#{type=>mcu, room_id=>"mcu1"},
    start_session(WsPid, Config);

send_call(<<"m2">>, WsPid, Base) ->
    Config = Base#{type=>mcu, room_id=>"mcu2"},
    start_session(WsPid, Config);

send_call(<<"p">>, WsPid, Base) ->
    Config = Base#{
        type => publish,
        room_audio_codec => pcma,
        room_video_codec => vp9,
        room_bitrate => 100000
    },
    start_session(WsPid, Config);

send_call(<<"p2">>, WsPid, Base) ->
    nkmedia_room:start(test, #{room_id=><<"sfu">>}),
    Config = Base#{type=>publish, room_id=><<"sfu">>},
    start_session(WsPid, Config);

send_call(<<"d", Num/binary>>, WsPid, Base) ->
    % We share the same session, with both caller and callee registered to it
    start_invite(WsPid, Num, Base#{type=>p2p});

send_call(<<"j", Num/binary>>, WsPid, Base) ->
    start_invite(WsPid, Num, Base#{type=>proxy});

send_call(<<"f", Num/binary>>, WsPid, Base) ->
    ConfigA = Base#{
        type => park,
        park_after_bridge => true
    },
    {answer, AnswerA, SessLinkA} = start_session(WsPid, ConfigA),
    {test_session, SessIdA, WsPid} = SessLinkA,
    ConfigB = #{type=>call, peer=>SessIdA, park_after_bridge=>false},
    spawn(
        fun() -> 
            case start_invite(WsPid, Num, ConfigB) of
                {ok, _SessLinkB} ->
                    ok;
                {rejected, Error} ->
                    lager:notice("Error in start_invite: ~p", [Error]),
                    nkmedia_session:stop(SessIdA)
            end
        end),
    {answer, AnswerA, SessLinkA};

send_call(_, _WsPid, _Base) ->
    {rejected, no_destination}.


start_session(WsPid, Data) when is_pid(WsPid) ->
    case nkservice_api_client:cmd(WsPid, media, session, start, Data) of
        {ok, #{<<"session_id">>:=SessId}=Res} -> 
            case Res of
                #{<<"answer">>:=#{<<"sdp">>:=SDP}} ->
                    {answer, #{sdp=>SDP}, {test_session, SessId, WsPid}};
                #{<<"offer">>:=#{<<"sdp">>:=SDP}} ->
                    {offer, #{sdp=>SDP}, {test_session, SessId, WsPid}};
                _ ->
                    {offer, maps:get(offer, Data), {test_session, SessId, WsPid}}
            end;
        {error, {_Code, Txt}} -> 
            {error, Txt}
    end.

% start_session(User, Data) ->
%     WsPid = connect(User),
%     true = is_pid(WsPid),
%     start_session(WsPid, Data).


start_invite(WsPid, Num, Config) ->
    Dest = nkmedia_test:find_user(Num),
    {offer, Offer, SessLink} = start_session(WsPid, Config),
    {test_session, SessId, _WsPid} = SessLink,
    {ok, SessPid} = nkmedia_session:find(SessId), 
    case Dest of 
        {webrtc, {nkmedia_verto, VertoPid}} ->
            ok = nkmedia_verto:invite(VertoPid, SessId, 
                                      Offer, {nkmedia_session, SessId, SessPid}),
            VertoLink = {nkmedia_verto, SessId, VertoPid},
            {ok, _} = nkmedia_session:register(SessId, VertoLink),
            {ok, SessLink};
        {webrtc, {nkmedia_janus, JanusPid}} ->
            ok = nkmedia_janus_proto:invite(JanusPid, SessId, 
                                      Offer, {nkmedia_session, SessId, SessPid}),
            JanusLink = {nkmedia_janus, SessId, JanusPid},
            {ok, _} = nkmedia_session:register(SessId, JanusLink),
            {ok, SessLink};
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
