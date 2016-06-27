
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
-module(nkmedia_sample_api).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/0, stop/0, restart/0]).

-export([api_start/0, api_client_fun/2, api_1/1]).

-export([plugin_deps/0]).

-export([api_server_login/3, api_allow/6]).
-export([nkmedia_verto_login/3, nkmedia_verto_invite/4, nkmedia_verto_bye/3,
         verto_client_fun/2]).

-include("nkmedia.hrl").

-define(LOG_SAMPLE(Type, Txt, Args, State),
    lager:Type("API Sample (~s) "++Txt, [maps:get(user, State) | Args])).



%% ===================================================================
%% Public
%% ===================================================================


start() ->
    _CertDir = code:priv_dir(nkpacket),
    Spec = #{
        callback => ?MODULE,
        web_server => "https:all:8081",
        web_server_path => "./priv/www",
        api_server => "wss:all:9010",
        api_server_timeout => 180,
        verto_listen => "verto:all:8082",
        verto_proxy => "verto_proxy:all:8083",
        janus_listen => "janus:all:8989", 
        janus_proxy=> "janus_proxy:all:8990",
        kurento_proxy => "kms:all:8433",
        nksip_trace => {console, all},
        sip_listen => <<"sip:all:5060">>,
        log_level => debug
    },
    nkservice:start(sample, Spec).


stop() ->
    nkservice:stop(sample).

restart() ->
    stop(),
    timer:sleep(100),
    start().


api_start() ->
    Fun = fun nkmedia_sample:api_client_fun/1,
    {ok, _SessId, C} = 
        nkservice_api_client:start(sample, "nkapic://localhost:9010", "u1", "p1", 
                                   Fun, #{}),
    timer:sleep(50),
    [{_, _, S}] = nkservice_api_server:get_all(),
    {C, S}.


api_client_fun({req, Class, <<"event">>, Data, _TId}, User) ->
    #{<<"type">>:=Type, <<"obj">>:=Obj, <<"obj_id">>:=ObjId} = Data,
    Body = maps:get(<<"body">>, Data, #{}),
    lager:notice("WsClient event ~s:~s:~s:~s: ~p", [Class, Type, Obj, ObjId, Body]),
    {ok, #{}, User};

api_client_fun(Msg, User) ->
    lager:notice("T1: ~p", [Msg]),
    {error, not_implemented, User}.


api_1(C) ->
    nkservice_api_client:cmd(C, media, start_session, #{class=>park}).


    





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
%% api server callbacks
%% ===================================================================


%% @doc Called on login
api_server_login(#{<<"user">>:=User, <<"pass">>:=_Pass}, _SessId, State) ->
    nkservice_api_server:start_ping(self(), 60),
    {true, User, State};

api_server_login(_Data, _SessId, _State) ->
    continue.


%% @doc
api_allow(_SessId, _User, media, _Cmd, _Data, State) ->
    {true, State};

api_allow(_SessId, _User, _Class, _Cmd, _Data, _State) ->
    continue.


%% ===================================================================
%% nkmedia_verto callbacks
%% ===================================================================


nkmedia_verto_login(Login, Pass, Verto) ->
    case binary:split(Login, <<"@">>) of
        [User, _] ->
            Verto2 = Verto#{user=>User},
            ?LOG_SAMPLE(info, "login: ~s (pass ~s)", [User, Pass], Verto2),
            {true, User, Verto2};
        _ ->
            {false, Verto}
    end.


nkmedia_verto_invite(SrvId, CallId, #{dest:=<<"0">>}=Offer, Verto) ->
    {ok, _, Pid} = nkservice_api_client:start(SrvId, "nkapic://localhost:9010", 
                                              "user", "pass", 
                                              fun ?MODULE:verto_client_fun/2,
                                              #{verto_pid=>self(), call_id=>CallId}),
    case 
        nkservice_api_client:cmd(Pid, media, start_session, #{class=>echo, offer=>Offer})
    of
        {ok, #{<<"answer">>:=#{<<"sdp">>:=SDP}}} ->
            {answer, #{sdp=>SDP}, {api_sample, Pid}, Verto};
        {error, {_Code, Txt}} ->
            lager:warning("API Sample: Error creating session: ~s", [Txt]),
            {rejected, normal, Verto}
    end.



nkmedia_verto_bye(CallId, {api_sample, Pid}, Verto) ->
    lager:info("Verto BYE for ~s", [CallId]),
    nkservice_api_client:stop(Pid),
    {ok, Verto}.



verto_client_fun({req, Class, <<"event">>, Data, _TId}, UserData) ->
    #{<<"type">>:=Type, <<"obj">>:=Obj, <<"obj_id">>:=ObjId} = Data,
    Body = maps:get(<<"body">>, Data, #{}),
    case {Class, Type, Obj} of
        {<<"media">>, <<"stop">>, <<"session">>} ->
            #{verto_pid:=Pid, call_id:=CallId} = UserData,
            nkmedia_verto:hangup(Pid, CallId, normal),
            nkservice_api_client:stop(self());
        _ ->
            lager:notice("API Sample event ~p:~p:~p:~p: ~p", 
                         [Class, Obj, Type, ObjId, Body])
    end,
    {ok, #{}, UserData};

verto_client_fun(Msg, UserData) ->
    lager:notice("API Sample: ~p", [Msg]),
    {error, not_implemented, UserData}.


