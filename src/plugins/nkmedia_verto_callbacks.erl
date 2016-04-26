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

%% @doc Plugin implementing a Verto server
-module(nkmedia_verto_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_syntax/0, plugin_listen/2, 
         plugin_start/2, plugin_stop/2]).
-export([nkmedia_verto_init/2, nkmedia_verto_login/4, 
         nkmedia_verto_invite/3, nkmedia_verto_answer/3, nkmedia_verto_bye/2,
         nkmedia_verto_dtmf/3, nkmedia_verto_terminate/2,
         nkmedia_verto_handle_call/3, nkmedia_verto_handle_cast/2,
         nkmedia_verto_handle_info/2]).
-export([nkmedia_session_out/4, nkmedia_session_notify/3]).


-define(VERTO_WS_TIMEOUT, 60*60*1000).
-include_lib("nkservice/include/nkservice.hrl").



%% ===================================================================
%% Types
%% ===================================================================

-type continue() :: continue | {continue, list()}.



%% ===================================================================
%% Plugin callbacks
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
        class => {nkmedia_verto, SrvId},
        % get_headers => [<<"user-agent">>],
        idle_timeout => ?VERTO_WS_TIMEOUT
    },                                  
    Listen2 = [{Conns, maps:merge(ConnOpts, Opts1)} || {Conns, ConnOpts} <- Listen1],
    Web1 = maps:get(verto_communicator, Config, []),
    Path1 = list_to_binary(code:priv_dir(nkmedia)),
    Path2 = <<Path1/binary, "/www/verto_communicator">>,
    Opts2 = #{
        class => {nkmedia_verto_vc, SrvId},
        http_proto => {static, #{path=>Path2, index_file=><<"index.html">>}}
    },
    Web2 = [{Conns, maps:merge(ConnOpts, Opts2)} || {Conns, ConnOpts} <- Web1],
    Listen2 ++ Web2.


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA Verto (~s) starting", [Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA Verto (~p) stopping", [Name]),
    {ok, Config}.



%% ===================================================================
%% Offering Callbacks
%% ===================================================================

-type verto() :: nkmedia_verto:verto().
-type call_id() :: nkmedia_verto:call_id().

% -record(call, {
%     type :: call | nkmedia_session,
%     mon :: reference()
% }).



%% @doc Called when a new verto connection arrives
-spec nkmedia_verto_init(nkpacket:nkport(), verto()) ->
    {ok, verto()}.

nkmedia_verto_init(_NkPort, Verto) ->
    {ok, Verto#{calls=>#{}}}.


%% @doc Called when a login request is received
-spec nkmedia_verto_login(VertoSessId::binary(), Login::binary(), Pass::binary(),
                          verto()) ->
    {boolean(), verto()} | {true, Login::binary(), verto()} | continue().

nkmedia_verto_login(_VertoId, _Login, _Pass, Verto) ->
    {false, Verto}.


%% @doc Called when the client sends an INVITE
%% If {ok, verto()} is returned, we must call nkmedia_verto:answer/3 ourselves
-spec nkmedia_verto_invite(call_id(), nkmedia_verto:offer(), verto()) ->
    {ok, verto()} | {answer, nkmedia_verto:answer(), verto()} | 
    {hangup, nkmedia:hangup_reason(), verto()} | continue().

nkmedia_verto_invite(SessId, Offer, #{srv_id:=SrvId}=Verto) ->
    Spec = #{
        id => SessId, 
        offer => Offer, 
        monitor => self(),
        nkmedia_verto => self()
    },
    {ok, SessId, SessPid} = nkmedia_session:start_inbound(SrvId, Spec),
    #{callee_id:=Dest} = Offer,
    nkmedia_session:to_call(SessPid, Dest),
    {ok, Verto}.

    % Sess = #call{type=call, mon=monitor(process, SessPid)},
    % {ok, Verto#{calls:=maps:put(calls, Call, Calls)}}.


%% @doc Called when the client sends an ANSWER
-spec nkmedia_verto_answer(call_id(), nkmedia_verto:answer(), verto()) ->
    {ok, verto()} |{hangup, nkmedia:hangup_reason(), verto()} | continue().

nkmedia_verto_answer(_CallId, _Answer, Verto) ->
    {ok, Verto}.


%% @doc Sends when the client sends a BYE
-spec nkmedia_verto_bye(call_id(), verto()) ->
    {ok, verto()} | continue().

nkmedia_verto_bye(CallId, Verto) ->
    nkmedia_session:hangup(CallId, <<"User Bye">>),
    {ok, Verto}.


%% @doc
-spec nkmedia_verto_dtmf(call_id(), DTMF::binary(), verto()) ->
    {ok, verto()} | continue().

nkmedia_verto_dtmf(_CallId, _DTMF, Verto) ->
    {ok, Verto}.


%% @doc Called when the connection is stopped
-spec nkmedia_verto_terminate(Reason::term(), verto()) ->
    {ok, verto()}.

nkmedia_verto_terminate(_Reason, Verto) ->
    {ok, Verto}.


%% @doc 
-spec nkmedia_verto_handle_call(Msg::term(), {pid(), term()}, verto()) ->
    {ok, verto()} | continue().

nkmedia_verto_handle_call(Msg, _From, Verto) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {ok, Verto}.


%% @doc 
-spec nkmedia_verto_handle_cast(Msg::term(), verto()) ->
    {ok, verto()}.

nkmedia_verto_handle_cast(Msg, Verto) ->
    lager:error("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {ok, Verto}.


%% @doc 
-spec nkmedia_verto_handle_info(Msg::term(), verto()) ->
    {ok, Verto::map()}.

nkmedia_verto_handle_info(Msg, Verto) ->
    lager:error("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
    {ok, Verto}.




%% ===================================================================
%% Implemented Callbacks - nkmedia_session
%% ===================================================================


nkmedia_session_notify(SessId, {status, hangup, _}, #{nkmedia_verto:=Pid}) ->
    nkmedia_verto:hangup(Pid, SessId),
    continue;

nkmedia_session_notify(SessId, {status, p2p, #{peer:=PeerId}}, #{nkmedia_verto:=Pid}) ->
    {ok, Answer} = nkmedia_session:get_answer(PeerId),
    nkmedia_verto:answer(Pid, SessId, Answer),
    continue;

nkmedia_session_notify(SessId, {status, Status, _}, #{nkmedia_verto:=_Pid}) ->
    lager:notice("Verto status (~s): ~p", [SessId, Status]),
    continue;

nkmedia_session_notify(_SessId, _Event, _Session) ->
    continue.


nkmedia_session_out(SessId, {nkmedia_verto, Pid}, Offer, Session) ->
    Self = self(),
    spawn_link(
        fun() ->
            case nkmedia_verto:invite(Pid, SessId, Offer#{monitor=>Self}) of
                {answered, Answer} ->
                    nkmedia_session:answered(SessId, Answer);
                hangup ->
                    lager:info("Verto user hangup"),
                    nkmedia_session:hangup(SessId);
                {error, Error} ->
                    lager:warning("Error calling invite: ~p", [Error]),
                    nkmedia_session:hangup(SessId)
            end
        end),
    {ringing, #{}, Session#{nkmedia_verto=>Pid}};

nkmedia_session_out(_SessId, _Dest, _Offer, _Session) ->
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





