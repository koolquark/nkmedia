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
-export([find_call_id/1, to_mcu/2, to_park/1, to_join/2]).
-export([call/1]).

-export([plugin_deps/0, plugin_syntax/0, plugin_listen/2]).
-export([plugin_start/2, plugin_stop/2]).
-export([nkmedia_verto_init/2, nkmedia_verto_login/4]).
-export([ nkmedia_verto_invite/5, nkmedia_verto_bye/2]).
-export([nkmedia_verto_answer/4]). %, nkmedia_verto_terminate/2]).
-export([nkmedia_verto_handle_info/2]).
-export([nkmedia_session_send_call/2]).

-include("nkmedia.hrl").

-define(LOG_VERTO(Type, Txt, Args, State),
    lager:Type("Sample (~s) "++Txt, [maps:get(user, State) | Args])).



%% ===================================================================
%% Public
%% ===================================================================


start() ->
    _CertDir = code:priv_dir(nkpacket),
    Spec = #{
        plugins => [?MODULE],
        verto_listen => "verto:all:8082",
        % verto_listen => "verto_proxy:all:8082",
        verto_communicator => "https:all:8082/vc",
        % tls_keyfile => CertDir ++ "key.pem",
        % tls_certfile => CertDir ++ "cert.pem",
        % sip_trace => {console, all},
        log_level => debug
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
        [{CallId, _Pid}|_] -> CallId;
        [] -> <<>>
    end.


find_pid(User) ->
    case nklib_proc:values({?MODULE, user, nklib_util:to_binary(User)}) of
        [{undefined, Pid}|_] -> Pid;
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
        CallId_A -> 
            case find_call_id(User2) of 
                <<>> -> 
                    {error, user_not_found};
                CallId_B -> 
                    nkmedia_session:to_join(CallId_A, CallId_B)
            end
    end.


call(User) ->
    case find_pid(User) of
        Pid when is_pid(Pid) ->
            Config = #{monitor => self()},
            {ok, CallId, _SessPid} = nkmedia_session:start(sample, Config),
            ok = nkmedia_session:to_call(CallId, {verto, Pid}),
            ok = nkmedia_session:to_mcu(CallId, "kk");
        not_found ->
            {error, user_not_found}
    end.


%% ===================================================================
%% Config callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia].


plugin_syntax() ->
    nkpacket:register_protocol(verto, nkmedia_verto),
    nkpacket:register_protocol(verto_proxy, nkmedia_fs_verto_proxy_server),
    #{
        verto_listen => fun parse_listen/3,
        verto_communicator => fun parse_listen/3
    }.


plugin_listen(Config, #{id:=SrvId}) ->
    % verto_listen will be already parsed
    Listen1 = maps:get(verto_listen, Config, []),
    % With the 'user' parameter we tell nkmedia_verto protocol
    % to use the service callback module, so it will find
    % nkmedia_verto_* funs there.
    Opts1 = #{
        class => {nkmedia_sample, SrvId},      
        get_headers => [<<"user-agent">>],
        idle_timeout => ?VERTO_WS_TIMEOUT,
        user => #{callback=>SrvId}     
    },                                  
    Listen2 = [{Conns, maps:merge(ConnOpts, Opts1)} || {Conns, ConnOpts} <- Listen1],
    Web1 = maps:get(verto_communicator, Config, []),
    Path1 = list_to_binary(code:priv_dir(nkmedia)),
    Path2 = <<Path1/binary, "/www/verto_communicator">>,
    Opts2 = #{
        class => {ncp_media_verto, SrvId},
        http_proto => {static, #{path=>Path2, index_file=><<"index.html">>}}
    },
    Web2 = [{Conns, maps:merge(ConnOpts, Opts2)} || {Conns, ConnOpts} <- Web1],
    Listen2 ++ Web2.


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

nkmedia_verto_init(NkPort, State) ->
    {ok, {nkmedia_sample, SrvId}, _User} = nkpacket:get_user(NkPort),
    {ok, State#{srv_id=>SrvId, sessions=>#{}}}.


nkmedia_verto_login(VertoId, Login, Pass, State) ->
    [User, _Domain] = binary:split(Login, <<"@">>),
    State2 = State#{user=>User},
    nklib_proc:put({?MODULE, user, User}),
    ?LOG_VERTO(info, "login: ~s, ~s, ~s", [Login, Pass, VertoId], State2),
    {true, State2}.


nkmedia_verto_invite(CallId_A, Dest, SDP_A, Dialog, State) ->
    #{user:=User, srv_id:=SrvId, sessions:=Sessions} = State,
    ?LOG_VERTO(info, "INVITE ~s: ~s, ~s", [User, CallId_A, Dest], State),
    SessSpec_A = #{
        id => CallId_A, 
        monitor => self(), 
        sdp_a => SDP_A, 
        verto_dialog => Dialog
    },
    {ok, CallId_A, SessPid_A} = nkmedia_session:start(SrvId, SessSpec_A),
    case nkmedia_session:to_mediaserver(CallId_A) of
        {ok, SDP_B} ->
            Ref = monitor(process, SessPid_A),
            Sessions2 = maps:put(CallId_A, Ref, Sessions),
            ok = nkmedia_session:to_mcu(CallId_A, "kk"),
            {answer, SDP_B, State#{sessions:=Sessions2}};
            %     ok -> 
            %         SessSpec_B = #{
            %             srv_id => SrvId,
            %             id => CallId_B = nklib_util:uuid_4122(),
            %             monitor => self()
            %         },
            %         {ok, CallId_B, _SessPid_B} = nkmedia_session:start(SessSpec_B),
            %         case nkmedia_session:from_mediaserver(CallId_B) of
            %             {ok, _SDP2_A} ->
            %                 {answer, SDP_B, State2};
            %             {error, Error} ->
            %                 ?LOG_VERTO(warning, "error starting B: ~p", [Error], State),
            %                 {bye, 16, State}
            %         end;
            %     {error, Error} ->
            %         ?LOG_VERTO(warning, "error starting conf: ~p", [Error], State),
            %         {bye, 16, State}
            % end;
        {error, Error} ->
            ?LOG_VERTO(warning, "error starting session: ~p", [Error], State),
            {bye, 16, State}
    end.


nkmedia_verto_answer(CallId, _SDP, _Dialog, #{sessions:=Sessions}=State) ->
    case nkmedia_session:find(CallId) of
        {ok, SessPid} -> 
            Ref = monitor(process, SessPid),
            Sessions2 = maps:put(CallId, Ref, Sessions),
            {ok, State#{sessions:=Sessions2}};
        not_found ->
            ?LOG_VERTO(notice, "received answer without session", [], State),
            {ok, State}
    end.


nkmedia_verto_bye(CallId, #{sessions:=Sessions}=State) ->
    case maps:find(CallId, Sessions) of
        {ok, Ref} ->
            nkmedia_session:hangup(CallId, 16),
            nklib_util:demonitor(Ref),
            Sessions2 = maps:remove(CallId, Sessions),
            {ok, State#{sessions:=Sessions2}};
        error ->
            ?LOG_VERTO(notice, "BYE for unknown session ~s", [CallId], State),
            {ok, State}
    end.


% nkmedia_verto_dtmf(CallId, DTMF, #{user:=User}=State) ->
%     lager:notice("DTMF: ~s, ~s", [User, CallId, DTMF]),
%     {ok, State}.



nkmedia_verto_handle_info({'DOWN', Ref, process, _Pid, Reason}, State) ->
    #{sessions:=Sessions} = State,
    case lists:keyfind(Ref, 2, maps:to_list(Sessions)) of
        {CallId, Ref} ->
            case Reason of
                normal -> 
                    ?LOG_VERTO(info, "down of existing session", [], State);
                _ ->
                    ?LOG_VERTO(warning, "session failed!: ~p", [Reason], State)
            end,
            nkmedia_verto:bye(self(), CallId, 16),
            Sessions2 = maps:remove(CallId, Sessions),
            {ok, State#{sessions:=Sessions2}};
        error ->
            continue
    end;

nkmedia_verto_handle_info(_, _State) ->
    continue.


%% ==================================================================
%% Session
%% ===================================================================

nkmedia_session_send_call({verto, Pid}, #{id:=CallId, sdp_a:=SDP_A}=Session) ->
    case nkmedia_verto:invite(Pid, CallId, SDP_A, #{async=>false}) of
        {ok, SDP_B, Dialog} ->
            {ok, SDP_B, #{verto_dialog=>Dialog}, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

nkmedia_session_send_call(_Dest, _Session) ->
    continue.







%% ===================================================================
%% Internal
%% ===================================================================


parse_listen(_Key, [{[{_, _, _, _}|_], Opts}|_]=Multi, _Ctx) when is_map(Opts) ->
    {ok, Multi};

parse_listen(Key, Url, _Ctx) ->
    Schemes = case Key of
        verto_listen -> [verto, verto_proxy];
        verto_communicator -> [https]
    end,
    Opts = #{valid_schemes=>Schemes, resolve_type=>listen},
    case nkpacket:multi_resolve(Url, Opts) of
        {ok, List} -> {ok, List};
        _ -> error
    end.


