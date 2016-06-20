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
-export([nkmedia_verto_init/2, nkmedia_verto_login/3, 
         nkmedia_verto_invite/4, nkmedia_verto_answer/3, nkmedia_verto_bye/2,
         nkmedia_verto_dtmf/3, nkmedia_verto_terminate/2,
         nkmedia_verto_handle_call/3, nkmedia_verto_handle_cast/2,
         nkmedia_verto_handle_info/2]).
-export([nkmedia_session_invite/4, nkmedia_session_reg_event/4]).
-export([nkmedia_call_resolve/2]).

-define(VERTO_WS_TIMEOUT, 60*60*1000).
-include_lib("nkservice/include/nkservice.hrl").



%% ===================================================================
%% Types
%% ===================================================================

-type continue() :: continue | {continue, list()}.

-type verto_id() :: nkmedia_verto:verto_id().
-type session_id() :: nkmedia_session:id().



%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia].


plugin_syntax() ->
    nkpacket:register_protocol(verto, nkmedia_verto),
    #{
        verto_listen => fun parse_listen/3
    }.


plugin_listen(Config, #{id:=SrvId}) ->
    % verto_listen will be already parsed
    Listen = maps:get(verto_listen, Config, []),
    Opts = #{
        class => {nkmedia_verto, SrvId},
        % get_headers => [<<"user-agent">>],
        idle_timeout => ?VERTO_WS_TIMEOUT
    },                                  
    [{Conns, maps:merge(ConnOpts, Opts)} || {Conns, ConnOpts} <- Listen].


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


%% @doc Called when a new verto connection arrives
-spec nkmedia_verto_init(nkpacket:nkport(), verto()) ->
    {ok, verto()}.

nkmedia_verto_init(_NkPort, Verto) ->
    {ok, Verto}.


%% @doc Called when a login request is received
-spec nkmedia_verto_login(Login::binary(), Pass::binary(), verto()) ->
    {boolean(), verto()} | {true, Login::binary(), verto()} | continue().

nkmedia_verto_login(_Login, _Pass, Verto) ->
    {false, Verto}.


%% @doc Called when the client sends an INVITE
%% If {ok, ...} is returned, we must call nkmedia_verto:answer/3.
-spec nkmedia_verto_invite(nkservice:id(), nkmedia:offer(), verto_id(), verto()) ->
    {ok, nkmedia_session:id(), verto()} | 
    {answer, nkmedia_verto:answer(), nkmedia_session:id(), verto()} | 
    {rejected, nkmedia:hangup_reason(), verto()} | continue().

nkmedia_verto_invite(_SrvId, _Offer, _VertoSessId, _Verto) ->
    {rejected, not_implemented}.


    % #{sdp_type:=webrtc} = Offer,
    % Offer2 = Offer#{pid=>self(), nkmedia_verto=>in},
    % case nkmedia_session:start(SrvId, #{}) of
    %     {ok, SessId, SessPid} ->
    %         case SrvId:nkmedia_verto_call(SessId, Offer2, Verto) of
    %             {ok, Verto2} ->
    %                 {ok, SessId, SessPid, Verto2};
    %             {rejected, Reason, Verto2} ->
    %                 nkmedia_session:hangup(SessId, Reason),
    %                 {rejected, Reason, Verto2}
    %         end;
    %     {error, Error} ->
    %         lager:warning("Verto start_inbound error: ~p", [Error]),
    %         {hangup, <<"MediaServer Error">>, Verto}
    % end.


%% @doc Called when the client sends an ANSWER
-spec nkmedia_verto_answer(session_id(), nkmedia:answer(), verto()) ->
    {ok, verto()} |{hangup, nkmedia:hangup_reason(), verto()} | continue().

nkmedia_verto_answer(_SessId, _Answer, Verto) ->
    {ok, Verto}.


%% @doc Sends when the client sends a BYE
%% This default implementation will hangup the session

-spec nkmedia_verto_bye(session_id(), verto()) ->
    {ok, verto()} | continue().

nkmedia_verto_bye(SessId, Verto) ->
    lager:info("Verto BYE for ~s", [SessId]),
    nkmedia_session:hangup(SessId, <<"User Hangup">>),
    {ok, Verto}.


%% @doc
-spec nkmedia_verto_dtmf(session_id(), DTMF::binary(), verto()) ->
    {ok, verto()} | continue().

nkmedia_verto_dtmf(_SessId, _DTMF, Verto) ->
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


%% @private
nkmedia_session_reg_event(SessId, {nkmedia_verto, _CallId, Pid}, 
                          {answer, Answer}, _Session) ->
    #{sdp:=_} = Answer,
    lager:info("Verto (~s) calling media available", [SessId]),
    ok = nkmedia_verto:answer(Pid, SessId, Answer),
    continue;

nkmedia_session_reg_event(SessId, {nkmedia_verto, _CallId, Pid}, 
                          {hangup, _}, _Session) ->
    lager:info("Verto (~s) captured hangup", [SessId]),
    nkmedia_verto:hangup(Pid, SessId),
    continue;

nkmedia_session_reg_event(_SessId, _Id, _Event, _Session) ->
    continue.


%% @private
nkmedia_session_invite(SessId, {nkmedia_verto, Pid}, Offer, Session) ->
    Self = self(),
    spawn_link(
        fun() ->
            Reply = case nkmedia_verto:invite(Pid, SessId, Offer, #{pid=>Self}) of
                {answer, #{sdp:=_}=Answer} ->
                    {answered, Answer};
                rejected ->
                    {rejected, <<"Verto User Rejected">>};
                {error, Error} ->
                    lager:warning("Error calling invite: ~p", [Error]),
                    {rejected, <<"Verto Invite Error">>}
            end,
            % Could be already hangup
            nkmedia_session:invite_reply(SessId, Reply)
        end),
    % If we copied the offer from a caller session to this session,
    % and includes a verto '¡n' must be removed so that is not detected in the
    % answer here, since we already sent it in the invite_reply
    Session2 = case Session of
        #{offer:=#{nkmedia_verto:=in}=Offer} ->
            Session#{offer:=maps:remove(nkmedia_verto, Offer)};
        _ ->
            Session
    end,
    {ringing, #{nkmedia_verto=>out, pid=>Pid}, Session2};

nkmedia_session_invite(_SessId, _Dest, _Offer, _Session) ->
    continue.


%% @private
nkmedia_call_resolve(Dest, Call) ->
    case nkmedia_verto:find_user(Dest) of
        [Pid|_] ->
            {ok, {nkmedia_verto, Pid}, Call};
        [] ->
            lager:info("Verto: user ~s not found", [Dest]),
            continue
    end.






%% ===================================================================
%% Internal
%% ===================================================================


parse_listen(_Key, [{[{_, _, _, _}|_], Opts}|_]=Multi, _Ctx) when is_map(Opts) ->
    {ok, Multi};

parse_listen(verto_listen, Url, _Ctx) ->
    Opts = #{valid_schemes=>[verto], resolve_type=>listen},
    case nkpacket:multi_resolve(Url, Opts) of
        {ok, List} -> {ok, List};
        _ -> error
    end.





