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

%% @doc Room Call Callbacks
-module(nkmedia_call_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_start/2, plugin_stop/2]).
-export([nkmedia_call_init/2, nkmedia_call_terminate/2, 
         nkmedia_call_resolve/3, nkmedia_call_invite/5, nkmedia_call_cancel/3, 
         nkmedia_call_event/3, nkmedia_call_reg_event/4, 
         nkmedia_call_handle_call/3, nkmedia_call_handle_cast/2, 
         nkmedia_call_handle_info/2]).
-export([nkmedia_session_reg_event/4]).
-export([error_code/1]).
-export([api_cmd/2, api_syntax/4]).


-include("../../include/nkmedia.hrl").
-include_lib("nkservice/include/nkservice.hrl").


-type continue() :: continue | {continue, list()}.




%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia].


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA CALL (~s) starting", [Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA CALL (~p) stopping", [Name]),
    {ok, Config}.



%% ===================================================================
%% Error Codes
%% ===================================================================

%% @doc NkMEDIA CALL 
-spec error_code(term()) ->
    {integer(), binary()} | continue.

error_code(call_error)              ->  {305001, "Call error"};
error_code(call_not_found)          ->  {305002, "Call not found"};
error_code(call_rejected)           ->  {305003, "Call rejected"};
error_code(no_destination)          ->  {305004, "No destination"};
error_code(no_answer)               ->  {305005, "No answer"};
error_code(already_answered)        ->  {305006, "Already answered"};
error_code(originator_cancel)       ->  {305007, "Originator cancel"};
error_code(_) -> continue.



%% ===================================================================
%% Implemented Callbacks
%% ===================================================================


%% @private
nkmedia_session_reg_event(_SessId, {nkmedia_call, CallId, _CallPid}, 
                          {stop, Reason}, Session) ->
    nkmedia_call:hangup(CallId, Reason),
    {ok, Session};

nkmedia_session_reg_event(_SessId, _Reg, _Ev, _Session) ->
    continue.


%% ===================================================================
%% Call Callbacks
%% ===================================================================

-type call_id() :: nkmedia_call:id().
-type call() :: nkmedia_call:call().


%% @doc Called when a new call starts
-spec nkmedia_call_init(call_id(), call()) ->
    {ok, call()}.

nkmedia_call_init(_Id, Call) ->
    {ok, Call}.

%% @doc Called when the call stops
-spec nkmedia_call_terminate(Reason::term(), call()) ->
    {ok, call()}.

nkmedia_call_terminate(_Reason, Call) ->
    {ok, Call}.


%% @doc Called when an call is created. The initial callee option is included,
%% along with the current destionations. You may add new destinations.
%% By default, it will look for types 'user' and 'session', adding 
%% {nkmedia_api, {user|session}, pid()} destinations
%% Then nkmedia_call_invite must send the real invitations
-spec nkmedia_call_resolve(nkmedia_call:callee(), [nkmedia_call:dest_ext()], call()) ->
    {ok, [nkmedia_call:dest_ext()], call()} | continue().

nkmedia_call_resolve(Callee, DestExts, Call) ->
    nkmedia_api:nkmedia_call_resolve(Callee, DestExts, Call).


%% @doc Called for each defined destination to be invited
%% The offer can be empty if it was not included in the call creation
%% You must return a nklib:link(), and include it when calling
%% nkmedia_call:ringing/3, answered/3 or rejected/3
-spec nkmedia_call_invite(call_id(), nkmedia_call:dest(), 
                          nkmedia:offer(), Meta::term(), call()) ->
    {ok, nklib:link(), call()} | 
    {retry, Secs::pos_integer(), call()} | 
    {remove, call()} | 
    continue().

nkmedia_call_invite(CallId, Dest, Offer, Meta, Call) ->
    nkmedia_api:nkmedia_call_invite(CallId, Dest, Offer, Meta, Call).


%% @doc Called when an outbound invite has been cancelled
-spec nkmedia_call_cancel(call_id(), nklib:link(), call()) ->
    {ok, call()} | continue().

nkmedia_call_cancel(CallId, Link, Call) ->
    nkmedia_api:nkmedia_call_cancel(CallId, Link, Call).


%% @doc Called when the status of the call changes
-spec nkmedia_call_event(call_id(), nkmedia_call:event(), call()) ->
    {ok, call()} | continue().

nkmedia_call_event(CallId, Event, Call) ->
    nkmedia_events:call_event(CallId, Event, Call).


%% @doc Called when the status of the call changes, for each registered
%% process to the session
-spec nkmedia_call_reg_event(call_id(), nklib:link(), nkmedia_call:event(), call()) ->
    {ok, call()} | continue().

% Automatic processing of calls linked to a session
nkmedia_call_reg_event(_CallId, {nkmedia_session, SessId}, Event, Call) ->
    case Event of
        {answer, _Callee, Answer} ->
            nkmedia_session:set_answer(SessId, Answer);
        {hangup, Reason} ->
            nkmedia_session:stop(SessId, Reason);
        _ ->
            ok
    end,
    {ok, Call};

nkmedia_call_reg_event(CallId, Link, Event, Call) ->
    nkmedia_api:nkmedia_call_reg_event(CallId, Link, Event, Call).


%% @doc
-spec nkmedia_call_handle_call(term(), {pid(), term()}, call()) ->
    {reply, term(), call()} | {noreply, call()} | continue().

nkmedia_call_handle_call(Msg, _From, Call) ->
    lager:error("Module nkmedia_call received unexpected call: ~p", [Msg]),
    {noreply, Call}.


%% @doc
-spec nkmedia_call_handle_cast(term(), call()) ->
    {noreply, call()} | continue().

nkmedia_call_handle_cast(Msg, Call) ->
    lager:error("Module nkmedia_call received unexpected call: ~p", [Msg]),
    {noreply, Call}.


%% @doc
-spec nkmedia_call_handle_info(term(), call()) ->
    {noreply, call()} | continue().

nkmedia_call_handle_info(Msg, Call) ->
    lager:warning("Module nkmedia_call received unexpected info: ~p", [Msg]),
    {noreply, Call}.



%% ===================================================================
%% API CMD
%% ===================================================================

%% @private
api_cmd(#api_req{class = <<"media">>, subclass = <<"call">>, cmd=Cmd}=Req, State) ->
    nkmedia_call_api:api_cmd(Cmd, Req, State);

api_cmd(_Req, _State) ->
    continue.


%% @privat
api_syntax(#api_req{class = <<"media">>, subclass = <<"call">>, cmd=Cmd}, 
           Syntax, Defaults, Mandatory) ->
    nkmedia_call_api:syntax(Cmd, Syntax, Defaults, Mandatory);
    
api_syntax(_Req, _Syntax, _Defaults, _Mandatory) ->
    continue.
