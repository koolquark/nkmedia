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
-export([error_code/1]).
-export([nkmedia_verto_init/2, nkmedia_verto_login/3, 
         nkmedia_verto_invite/4, nkmedia_verto_bye/3,
         nkmedia_verto_answer/4, nkmedia_verto_rejected/3,
         nkmedia_verto_dtmf/4, nkmedia_verto_terminate/2,
         nkmedia_verto_handle_call/3, nkmedia_verto_handle_cast/2,
         nkmedia_verto_handle_info/2]).
-export([nkmedia_call_resolve/4, nkmedia_call_invite/4, nkmedia_call_cancel/3,
         nkmedia_call_reg_event/4]).
-export([nkmedia_session_reg_event/4]).

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
    [nkmedia, nkmedia_call].


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




-type call_id() :: nkmedia_verto:call_id().
-type verto() :: nkmedia_verto:verto().


%% @doc Called when a new verto connection arrives
-spec nkmedia_verto_init(nkpacket:nkport(), verto()) ->
    {ok, verto()}.

nkmedia_verto_init(_NkPort, Verto) ->
    {ok, Verto#{?MODULE=>#{}}}.


%% @doc Called when a login request is received
-spec nkmedia_verto_login(Login::binary(), Pass::binary(), verto()) ->
    {boolean(), verto()} | {true, Login::binary(), verto()} | continue().

nkmedia_verto_login(_Login, _Pass, Verto) ->
    {false, Verto}.


%% @doc Called when the client sends an INVITE
%% This default implementation will start a session (registered with us, we detect
%% answer and hangup) and a call to the called destination.
%% When the remote party answers, must create a slave session
%% If {ok, ...} is returned, we must call nkmedia_verto:answer/3.
-spec nkmedia_verto_invite(nkservice:id(), call_id(), nkmedia:offer(), verto()) ->
    {ok, nklib:link(), verto()} | 
    {answer, nkmedia:answer(), nklib_:link(), verto()} | 
    {rejected, nkservice:error(), verto()} | continue().

nkmedia_verto_invite(SrvId, CallId, Offer, Verto) ->
    case start_call(SrvId, CallId, Offer) of
        {ok, Link} ->
            {ok, Link, Verto};
        error ->
            {rejected, call_error, Verto}
    end.


%% @doc Called when the client sends an ANSWER after nkmedia_verto:invite/4
-spec nkmedia_verto_answer(call_id(), nklib:link(), nkmedia:answer(), verto()) ->
    {ok, verto()} |{hangup, nkservice:error(), verto()} | continue().

% If the registered process happens to be {nkmedia_session, ...} and we have
% an answer for an invite we received, we set the answer in the session
% (we are ignoring the possible proxy answer in the reponse)
nkmedia_verto_answer(CallId, {nkmedia_session, SessId, _Pid}, Answer, Verto) ->
    case nkmedia_call:find(CallId) of
        {ok, Pid} ->
            case nkmedia_call:answered(Pid, SessId, SessId, #{}) of
                ok -> 
                    set_answer(SessId, Answer);
                {error, Error} -> 
                    {hangup, Error}
            end;
        not_found ->
            set_answer(SessId, Answer),
            {ok, Verto}
    end;


% % If the registered process happens to be {nkmedia_call, ...} and we have
% % an answer for an invite we received, we set the answer in the call
% nkmedia_verto_answer(_CallId, {nkmedia_call, CallId, _Pid}, Answer, Verto) ->
%     case nkmedia_call:answered(CallId, {nkmedia_verto, self()}, Answer) of
%         ok ->
%             {ok, Verto};
%         {error, Error} ->
%             {hangup, Error, Verto}
%     end;

nkmedia_verto_answer(_CallId, _Link, _Answer, Verto) ->
    {ok, Verto}.


%% @doc Called when the client sends an BYE after nkmedia_verto:invite/4
-spec nkmedia_verto_rejected(call_id(), nklib:link(), verto()) ->
    {ok, verto()} | continue().

nkmedia_verto_rejected(CallId, {nkmedia_session, SessId, _Pid}, Verto) ->
    case nkmedia_call:find(CallId) of
        {ok, Pid} ->
            nkmedia_call:rejected(Pid, SessId);
        _ ->
            ok
    end,
    nkmedia_session:stop(SessId, verto_rejected),
    {ok, Verto};

% nkmedia_verto_rejected(_CallId, {nkmedia_call, CallId, _Pid}, Verto) ->
%     nkmedia_call:rejected(CallId, {nkmedia_verto, self()}),
%     {ok, Verto};

nkmedia_verto_rejected(_CallId, _Link, Verto) ->
    {ok, Verto}.


%% @doc Sends when the client sends a BYE during a call
-spec nkmedia_verto_bye(call_id(), nklib:link(), verto()) ->
    {ok, verto()} | continue().

% We recognize some special Links
nkmedia_verto_bye(CallId, {nkmedia_session, SessId, _Pid}, Verto) ->
    case nkmedia_call:find(CallId) of
        {ok, Pid} ->
            nkmedia_call:hangup(Pid, verto_bye);
        not_found ->
            ok
    end,
    nkmedia_session:stop(SessId, verto_bye),
    {ok, Verto};

% nkmedia_verto_bye(_CallId, {nkmedia_call, CallId, _Pid}, Verto) ->
%     nkmedia_call:hangup(CallId, verto_bye),
%     {ok, Verto};

nkmedia_verto_bye(_CallId, _Link, Verto) ->
    {ok, Verto}.


%% @doc
-spec nkmedia_verto_dtmf(call_id(), nklib:link(), DTMF::binary(), verto()) ->
    {ok, verto()} | continue().

nkmedia_verto_dtmf(_CallId, _Link, _DTMF, Verto) ->
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
%% Implemented Callbacks
%% ===================================================================


%% @private See nkservice_callbacks
error_code(verto_bye)       -> {306001, "Verto bye"};
error_code(verto_rejected)  -> {306002, "Verto rejected"};
error_code(_) -> continue.


%% @private
%% If call has type 'verto' we will capture it
nkmedia_call_resolve(Callee, Type, Acc, Call) when Type==verto; Type==all ->
    Dest = [
        #{dest=>{nkmedia_verto, Pid}}
        || Pid <- nkmedia_verto:find_user(Callee)
    ],
    {continue, [Callee, Type, Acc++Dest, Call]};

nkmedia_call_resolve(_Callee, _Type, _Acc, _Call) ->
    continue.


%% @private
%% When a call is sento to {nkmedia_verto, pid()}, we capture it here
%% We register with verto as {nkmedia_call, CallId, PId},
%% and with the call as {nkmedia_verto, Pid}
nkmedia_call_invite({nkmedia_verto, Pid}, _Caller, CallId, #{session_id:=SessId}=Call) ->
    SessConfig = #{register=>{nkmedia_verto, CallId, Pid}},
    case nkmedia_session:cmd(SessId, start_callee, SessConfig) of
        {ok, #{session_id:=SessIdB}} ->
            {ok, SessPidB} = nkmedia_session:find(SessIdB),
            case nkmedia_session:get_offer(SessIdB) of
                {ok, Offer} ->
                    Link = {nkmedia_session, SessIdB, SessPidB},
                    {ok, _} = nkmedia_verto:invite(Pid, CallId, Offer, Link),
                    {ok, SessIdB, Call};
                {error, Error} ->
                    lager:error("Verto INVITE in error: ~p", [Error]),
                    {remove, Call}
            end;
        {error, Error} ->
            lager:error("Verto INVITE in error: ~p", [Error]),
            {remove, Call}
    end;

nkmedia_call_invite(_CallId, _Dest, _Data, _Call) ->
    continue.


%% @private
nkmedia_call_cancel(_CallId, {nkmedia_session, SessId, _SessPid}, _Call) ->
    nkmedia_session:stop(SessId, originator_cancel),
    continue;

nkmedia_call_cancel(_CallId, _Link, _Call) ->
    continue.


%% @private
%% Convenient functions in case we are registered with the call as
%% {nkmedia_verto, Pid}
nkmedia_call_reg_event(_CallId, {nkmedia_verto, _}, {hangup, _Reason}, Call) ->
    #{session_id:=SessId} = Call,
    nkmedia_session:stop(SessId, call_stopped),
    continue;

nkmedia_call_reg_event(_CallId, _Link, _Event, _Call) ->
    % lager:error("CALL REG: ~p", [_Link]),
    continue.


%% @private
%% Convenient functions in case we are registered with the session as
%% {nkmedia_verto, CallId, Pid}
nkmedia_session_reg_event(_SessId, {nkmedia_verto, CallId, Pid}, Event, _Session) ->
    case Event of
        {answer, Answer} ->
            % we may be blocked waiting for the same session creation
            case nkmedia_verto:answer_async(Pid, CallId, Answer) of
                ok ->
                    ok;
                {error, Error} ->
                    lager:error("Error setting Verto answer: ~p", [Error])
            end;
        {stop, Reason} ->
            lager:info("Verto stopping after session stop: ~p", [Reason]),
            nkmedia_verto:hangup(Pid, CallId, Reason);
        _ ->
            ok
    end,
    continue;

nkmedia_session_reg_event(_SessId, _Link, _Event, _Call) ->
    continue.






%% ===================================================================
%% Internal
%% ===================================================================

set_answer(SessId, Answer) ->
    case nkmedia_session:set_answer(SessId, Answer) of
        ok ->
            ok;
        {error, Error} -> 
            nkmedia_verto:hangup(self(), Error)
    end.



%% @private
start_call(SrvId, CallId, #{dest:=Dest} = Offer) ->
    Config1 = #{offer=>Offer, register=>{nkmedia_verto, CallId, self()}},
    Config2 = case Dest of
        <<"p2p:", Callee/binary>> ->
            Config1;
        <<"sip:", Callee/binary>> ->
            Config1#{backend=>nkmedia_janus, sdp_type=>rtp};
        Callee ->
            Config1#{backend=>nkmedia_janus}
    end,
    case nkmedia_call:start(SrvId, Callee, Config2) of
        {ok, CallId, CallPid} ->
            {ok, {nkmedia_call, CallId, CallPid}};
        {error, Error} ->
            lager:warning("NkMEDIA Verto session error: ~p", [Error]),
            error
    end.






    % case Dest of
    %     <<"p2p:", Callee/binary>> ->
    %         case nkmedia_session:start(SrvId, p2p, Config2) of
    %             {ok, SessId, SessPid} ->
    %                 {ok, {user, Callee, SessId, SessPid}};
    %             {error, Error} ->
    %                 {error, Error}
    %         end;
    %     <<"verto:", Callee/binary>> ->
    %         Config3 = Config2#{backend => nkmedia_janus},
    %         case nkmedia_session:start(SrvId, proxy, Config3) of
    %             {ok, SessId, SessPid} ->
    %                 case nkmedia_session:get_offer(SessPid) of
    %                     {ok, Offer2} ->
    %                         {ok, {verto, Callee, Offer2, SessId, SessPid}};
    %                     {error, Error} ->
    %                         {error, Error}
    %                 end;
    %             {error, Error} ->
    %                 {error, Error}
    %         end;
    %     <<"sip:", Callee/binary>> ->
    %         Config3 = Config2#{backend => nkmedia_janus, sdp_type => rtp},
    %         case nkmedia_session:start(SrvId, proxy, Config3) of
    %             {ok, SessId, SessPid} ->
    %                 case nkmedia_session:get_offer(SessPid) of
    %                     {ok, Offer2} ->
    %                         {ok, {sip, Callee, Offer2, SessId, SessPid}};
    %                     {error, Error} ->
    %                         {error, Error}
    %                 end;
    %             {error, Error} ->
    %                 {error, Error}
    %         end;
    %     Callee ->
    %         Config3 = Config2#{backend => nkmedia_janus},
    %         case nkmedia_session:start(SrvId, proxy, Config3) of
    %             {ok, SessId, SessPid} ->
    %                 case nkmedia_session:get_offer(SessPid) of
    %                     {ok, Offer2} ->
    %                         {ok, {user, Callee, Offer2, SessId, SessPid}};
    %                     {error, Error} ->
    %                         {error, Error}
    %                 end;
    %             {error, Error} ->
    %                 {error, Error}
    %         end
    % end.


parse_listen(_Key, [{[{_, _, _, _}|_], Opts}|_]=Multi, _Ctx) when is_map(Opts) ->
    {ok, Multi};

parse_listen(verto_listen, Url, _Ctx) ->
    Opts = #{valid_schemes=>[verto], resolve_type=>listen},
    case nkpacket:multi_resolve(Url, Opts) of
        {ok, List} -> {ok, List};
        _ -> error
    end.





