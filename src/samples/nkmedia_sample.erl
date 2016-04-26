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

%% @doc Plugins implementing a Verto-compatible server
-module(nkmedia_sample).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/0, stop/0, restart/0]).
-export([find_user/1, find_call_id/1, to_mcu/2, to_park/1, to_join/2]).
-export([call/1, call_sip_user/1]).

-export([plugin_deps/0, plugin_start/2, plugin_stop/2]).
-export([nkmedia_verto_login/4]).
-export([nkmedia_call_backend/2, nkmedia_call_resolve/2]).
-export([nkmedia_call_notify/3, nkmedia_session_notify/3]).
-export([sip_register/2]).

-include("nkmedia.hrl").

-define(LOG_SAMPLE(Type, Txt, Args, State),
    lager:Type("Sample (~s) "++Txt, [maps:get(user, State) | Args])).



%% ===================================================================
%% Public
%% ===================================================================


start() ->
    _CertDir = code:priv_dir(nkpacket),
    Spec = #{
        plugins => [?MODULE, nksip_registrar, nksip_trace],
        verto_listen => "verto:all:8082",
        % verto_listen => "verto_proxy:all:8082",
        verto_communicator => "https:all:8082/vc",
        janus_demos => "http:all:8083/janus",
        log_level => debug,
        nksip_trace => {console, all},
        sip_listen => <<"sip:all:5060">>
    },
    nkservice:start(sample, Spec).


stop() ->
    nkservice:stop(sample).

restart() ->
    stop(),
    timer:sleep(100),
    start().


find_call_id(User) ->
    case nklib_proc:values({?MODULE, call, nklib_util:to_binary(User)}) of
        [{CallId, _Pid}|_] -> {ok, CallId};
        [] -> not_found
    end.


find_user(User) ->
    case nklib_proc:values({?MODULE, user, nklib_util:to_binary(User)}) of
        [{undefined, Pid}|_] -> {ok, Pid};
        [] -> not_found
    end.


to_mcu(User, Room) ->
    case find_call_id(User) of 
        <<>> -> {error, user_not_found};
        CallId -> nkmedia_session:to_mcu(CallId, Room)
    end.


to_park(User) ->
    case find_call_id(User) of 
        <<>> -> {error, user_not_found};
        CallId -> nkmedia_session:to_park(CallId)
    end.


to_join(User1, User2) ->
    case find_call_id(User1) of 
        <<>> -> 
            {error, user_not_found};
        SessIdA -> 
            case find_call_id(User2) of 
                <<>> -> 
                    {error, user_not_found};
                CallId_B -> 
                    nkmedia_session:to_join(SessIdA, CallId_B)
            end
    end.


call(User) ->
    case find_user(User) of
        Pid when is_pid(Pid) ->
            Config = #{monitor => self()},
            {ok, CallId, _SessPid} = nkmedia_session:start(sample, Config),
            ok = nkmedia_session:to_call(CallId, {verto, Pid}),
            ok = nkmedia_session:to_mcu(CallId, "kk");
        not_found ->
            {error, user_not_found}
    end.


call_sip_user(User) ->
    User2 = nklib_util:to_binary(User),
    case nksip_registrar:find(sample, sip, User2, <<"nkmedia_sample">>) of
        [Uri|_] ->
            Config = #{monitor => self(), sdp_type=>sip},
            {ok, CallId, _SessPid} = nkmedia_session:start(sample, Config),
            spawn(
                fun() ->
                    _ = nkmedia_session:to_call(CallId, {sip, Uri, #{}}),
                    ok = nkmedia_session:to_mcu(CallId, "kk")
                end);
        [] ->
            {error, user_not_found}
    end.



%% ===================================================================
%% Config callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia, nkmedia_sip, nkmedia_verto].


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin ~p (~s) starting", [?MODULE, Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin ~p (~p) stopping", [?MODULE, Name]),
    {ok, Config}.




%% ===================================================================
%% nkmedia_verto callbacks
%% ===================================================================

%% The functions in this group are called from the nkmedia_verto
%% protocol

nkmedia_verto_login(VertoId, Login, Pass, Verto) ->
    case binary:split(Login, <<"@">>) of
        [User, _] ->
            Verto2 = Verto#{user=>User},
            ?LOG_SAMPLE(info, "login: ~s (pass ~s, ~s)", [User, Pass, VertoId], Verto2),
            {true, User, Verto2};
        _ ->
            {false, Verto}
    end.



nkmedia_call_backend(_CalleeId, Call) ->
    {ok, p2p, Call}.


nkmedia_call_resolve(CalleeId, #{backend:=p2p}=Call) ->
    case nkmedia_verto:find_user(CalleeId) of
        [Pid|_] ->
            {ok, {nkmedia_verto, Pid}, Call};
        [] ->
            {hangup, <<"No User">>, Call}
    end.

nkmedia_call_notify(CallId, Event, _Call) ->
    lager:notice("Sample call notify (~s): ~p", [CallId, Event]),
    continue.



nkmedia_session_notify(SessId, Event, _Session) ->
    lager:notice("Sample session notify (~s): ~pState#state{out_notify_mon = nkmedia_util:notify_mon(Notify)}", [SessId, Event]),
    continue.



% nkmedia_verto_dtmf(CallId, DTMF, #{user:=User}=State) ->
%     lager:notice("DTMF: ~s, ~s", [User, CallId, DTMF]),
%     {ok, State}.





%% ===================================================================
%% sip_callbacks
%% ===================================================================

sip_register(Req, Call) ->
    Req2 = nksip_registrar_util:force_domain(Req, <<"nkmedia_sample">>),
    {continue, [Req2, Call]}.




%% ==================================================================
%% Session
%% ===================================================================








%% ===================================================================
%% Internal
%% ===================================================================
