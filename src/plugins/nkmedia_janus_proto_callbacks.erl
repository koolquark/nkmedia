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

-module(nkmedia_janus_proto_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_syntax/0, plugin_listen/2, 
         plugin_start/2, plugin_stop/2]).
-export([nkmedia_janus_init/2, nkmedia_janus_registered/2,
         nkmedia_janus_invite/4, nkmedia_janus_answer/4, nkmedia_janus_bye/3,
         nkmedia_janus_candidate/4,
         nkmedia_janus_start/3, nkmedia_janus_terminate/2,
         nkmedia_janus_handle_call/3, nkmedia_janus_handle_cast/2,
         nkmedia_janus_handle_info/2]).
-export([error_code/1]).
-export([nkmedia_call_resolve/3, nkmedia_call_invite/5, nkmedia_call_cancel/3,
         nkmedia_call_reg_event/4]).
-export([nkmedia_session_reg_event/4]).



-define(JANUS_WS_TIMEOUT, 60*60*1000).


%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia].


plugin_syntax() ->
    nkpacket:register_protocol(janus, nkmedia_janus_proto),
    #{
        janus_listen => fun parse_listen/3
    }.


plugin_listen(Config, #{id:=SrvId}) ->
    % janus_listen will be already parsed
    Listen = maps:get(janus_listen, Config, []),
    Opts = #{
        class => {nkmedia_janus_proto, SrvId},
        % get_headers => [<<"user-agent">>],
        idle_timeout => ?JANUS_WS_TIMEOUT,
        ws_proto => <<"janus-protocol">>
    },                                  
    [{Conns, maps:merge(ConnOpts, Opts)} || {Conns, ConnOpts} <- Listen].


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA JANUS Proto (~s) starting", [Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA JANUS Proto (~p) stopping", [Name]),
    {ok, Config}.




%% ===================================================================
%% Offering Callbacks
%% ===================================================================

-type janus() :: nkmedia_janus_proto:janus().
-type call_id() :: nkmedia_janus_proto:call_id().
-type continue() :: continue | {continue, list()}.


%% @doc Called when a new janus connection arrives
-spec nkmedia_janus_init(nkpacket:nkport(), janus()) ->
    {ok, janus()}.

nkmedia_janus_init(_NkPort, Janus) ->
    {ok, Janus}.


%% @doc Called when the client sends an INVITE
-spec nkmedia_janus_registered(binary(), janus()) ->
    {ok, janus()}.

nkmedia_janus_registered(_User, Janus) ->
    {ok, Janus}.


%% @doc Called when the client sends an INVITE
-spec nkmedia_janus_invite(nkservice:id(), call_id(), nkmedia:offer(), janus()) ->
    {ok, nklib:link(), janus()} | 
    {answer, nkmedia_janus_proto:answer(), nklib:link(), janus()} | 
    {rejected, nkservice:error(), janus()} | continue().

nkmedia_janus_invite(_SrvId, _CallId, _Offer, Janus) ->
    {rejected, not_implemented, Janus}.


%% @doc Called when the client sends an ANSWER
-spec nkmedia_janus_answer(call_id(), nklib:link(), nkmedia:answer(), janus()) ->
    {ok, janus()} |{hangup, nkservice:error(), janus()} | continue().

% If the registered process happens to be {nkmedia_session, ...} and we have
% an answer for an invite we received, we set the answer in the session
% (we are ignoring the possible proxy answer in the reponse)
nkmedia_janus_answer(_CallId, {nkmedia_session, SessId, _Pid}, Answer, Janus) ->
    case nkmedia_session:answer_async(SessId, Answer) of
        ok ->
            {ok, Janus};
        {error, Error} ->
            {hangup, Error, Janus}
    end;

% If the registered process happens to be {nkmedia_call, ...} and we have
% an answer for an invite we received, we set the answer in the call
nkmedia_janus_answer(_CallId, {nkmedia_call, CallId, _Pid}, Answer, Janus) ->
    case nkmedia_call:answered(CallId, {nkmedia_janus, self()}, Answer) of
        ok ->
            {ok, Janus};
        {error, Error} ->
            {hangup, Error, Janus}
    end;

nkmedia_janus_answer(_CallId, _Link, _Answer, Janus) ->
    {ok, Janus}.


%% @doc Sends when the client sends a BYE
-spec nkmedia_janus_bye(call_id(), nklib:link(), janus()) ->
    {ok, janus()} | continue().

% We recognize some special Links
nkmedia_janus_bye(_CallId, {nkmedia_session, SessId, _Pid}, Janus) ->
    nkmedia_session:stop(SessId, janus_bye),
    {ok, Janus};

nkmedia_janus_bye(_CallId, {nkmedia_call, CallId, _Pid}, Janus) ->
    nkmedia_call:hangup(CallId, janus_bye),
    {ok, Janus};

nkmedia_janus_bye(_CallId, _Link, Janus) ->
    {ok, Janus}.


%% @doc Called when the client sends an START for a PLAY
-spec nkmedia_janus_start(call_id(), nkmedia:offer(), janus()) ->
    ok | {hangup, nkservice:error(), janus()} | continue().

nkmedia_janus_start(SessId, Answer, Janus) ->
    case nkmedia_session:answer_async(SessId, Answer, #{}) of
        ok ->
            {ok, Janus};
        {error, Error} ->
            lager:warning("Janus janus_start error: ~p", [Error]),
            {hangup, <<"MediaServer Error">>, Janus}
    end.


%% @doc Called when the client sends an START for a PLAY
-spec nkmedia_janus_candidate(App::binary(), Index::integer(), 
                              Candidate::binary(), janus()) ->
    {ok, janus()}.

nkmedia_janus_candidate(_App, _Index, _Candidate, Janus) ->
    lager:warning("Janus Proto unexpected ICE Candidate!"),
    {ok, Janus}.


%% @doc Called when the connection is stopped
-spec nkmedia_janus_terminate(Reason::term(), janus()) ->
    {ok, janus()}.

nkmedia_janus_terminate(_Reason, Janus) ->
    {ok, Janus}.


%% @doc 
-spec nkmedia_janus_handle_call(Msg::term(), {pid(), term()}, janus()) ->
    {ok, janus()} | continue().

nkmedia_janus_handle_call(Msg, _From, Janus) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {ok, Janus}.


%% @doc 
-spec nkmedia_janus_handle_cast(Msg::term(), janus()) ->
    {ok, janus()}.

nkmedia_janus_handle_cast(Msg, Janus) ->
    lager:error("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {ok, Janus}.


%% @doc 
-spec nkmedia_janus_handle_info(Msg::term(), janus()) ->
    {ok, Janus::map()}.

nkmedia_janus_handle_info(Msg, Janus) ->
    lager:error("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
    {ok, Janus}.


%% ===================================================================
%% Implemented Callbacks - nkmedia_session
%% ===================================================================


%% @private Error Codes -> 2150 range
error_code(_)               -> continue.


%% @private
%% If call has type 'nkmedia_janus' we will capture it
nkmedia_call_resolve(Callee, Acc, Call) ->
    case maps:get(type, Call, nkmedia_janus) of
        nkmedia_janus ->
            DestExts = [
                #{dest=>{nkmedia_janus, Pid}}
                || Pid <- nkmedia_janus_proto:find_user(Callee)
            ],
            {continue, [Callee, Acc++DestExts, Call]};
        _ ->
            continue
    end.


%% @private
%% When a call is sento to {nkmedia_janus, pid()}, we capture it here
%% We register with janus as {nkmedia_janus_call, CallId, PId},
%% and with the call as {nkmedia_janus, Pid}
nkmedia_call_invite(CallId, {nkmedia_janus, Pid}, Offer, _Meta, Call) when is_pid(Pid) ->
    Link = {nkmedia_janus_call, CallId, self()},
    ok = nkmedia_janus_proto:invite(Pid, CallId, Offer, Link),
    {ok, {nkmedia_janus, Pid}, Call};

nkmedia_call_invite(_CallId, _Dest, _Offer, _Meta, _Call) ->
    continue.


%% @private
%% Convenient functions in case we are registered with the call as
%% {nkmedia_jsnud CallId, Pid}
nkmedia_call_cancel(CallId, {nkmedia_janus, Pid}, _Call) when is_pid(Pid) ->
    nkmedia_janus_proto:hangup(Pid, CallId, originator_cancel),
    continue;

nkmedia_call_cancel(_CallId, _Link, _Call) ->
    continue.


%% @private
%% Convenient functions in case we are registered with the call as
%% {nkmedia_janus, CallId, Pid}
nkmedia_call_reg_event(_CallId, {nkmedia_janus, CallId, Pid}, {hangup, Reason}, _Call) ->
    lager:info("Janus stopping after call hangup: ~p", [Reason]),
    nkmedia_janus_proto:hangup(Pid, CallId, Reason),
    continue;

nkmedia_call_reg_event(_CallId, _Link, _Event, _Call) ->
    continue.

%% @private
%% Convenient functions in case we are registered with the session as
%% {nkmedia_janus, CallId, Pid}
nkmedia_session_reg_event(_SessId, {nkmedia_janus, CallId, Pid}, Event, _Call) ->
    case Event of
        {answer, Answer} ->
            % we may be blocked waiting for the same session creation
            case nkmedia_janus_proto:answer_async(Pid, CallId, Answer) of
                ok ->
                    ok;
                {error, Error} ->
                    lager:error("Error setting Janus answer: ~p", [Error])
            end;
        {stop, Reason} ->
            lager:info("Janus stopping after session stop: ~p", [Reason]),
            nkmedia_janus_proto:hangup(Pid, CallId, Reason);
        _ ->
            ok
    end,
    continue;

nkmedia_session_reg_event(_CallId, _Link, _Event, _Call) ->
    continue.




%% ===================================================================
%% Internal
%% ===================================================================


parse_listen(_Key, [{[{_, _, _, _}|_], Opts}|_]=Multi, _Ctx) when is_map(Opts) ->
    {ok, Multi};

parse_listen(janus_listen, Url, _Ctx) ->
    Opts = #{valid_schemes=>[janus], resolve_type=>listen},
    case nkpacket:multi_resolve(Url, Opts) of
        {ok, List} -> {ok, List};
        _ -> error
    end.


