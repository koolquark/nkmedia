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

%% @doc Call Callbacks
-module(nkmedia_call_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_start/2, plugin_stop/2]).
-export([nkmedia_call_init/2, nkmedia_call_terminate/2, 
         nkmedia_call_resolve/4, nkmedia_call_invite/5, nkmedia_call_cancelled/3, 
         nkmedia_call_answer/4, nkmedia_call_candidate/4,
         nkmedia_call_event/3, nkmedia_call_reg_event/4, 
         nkmedia_call_handle_call/3, nkmedia_call_handle_cast/2, 
         nkmedia_call_handle_info/2,
         nkmedia_call_start_caller_session/2, 
         nkmedia_call_start_callee_session/3,
         nkmedia_call_set_answer/5]).
-export([error_code/1]).
-export([api_cmd/2, api_syntax/4]).
-export([nkmedia_session_reg_event/4, nkmedia_session_handle_call/3]).

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
error_code(ring_timeout)            ->  {305004, "Ring timeout"};
error_code(no_destination)          ->  {305005, "No destination"};
error_code(no_answer)               ->  {305006, "No answer"};
error_code(already_answered)        ->  {305007, "Already answered"};
error_code(originator_cancel)       ->  {305008, "Originator cancel"};
error_code(caller_stopped)          ->  {305009, "Caller stopped"};
error_code(callee_stopped)          ->  {305010, "Callee stopped"};
error_code(_) -> continue.



%% ===================================================================
%% Call Callbacks
%% ===================================================================

-type call_id() :: nkmedia_call:id().
-type dest() :: nkmedia_call:dest().
-type dest_ext() :: nkmedia_call:dest_ext().
-type caller() :: nkmedia_call:caller().
-type callee() :: nkmedia_call:callee().
-type call() :: nkmedia_call:call().
-type session_id() :: nkmedia_session:id().


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


%% @doc Called when an call is created. The initial callee is included,
%% along with the current desti nations. You may add new destinations.
%%
%% The default implementation will look for types 'user' and 'session', adding 
%% {nkmedia_api, {user|session, pid()}} destinations
%% Then nkmedia_call_invite must send the real invitations
-spec nkmedia_call_resolve(callee(), nkmedia_call:call_type(), [dest_ext()], call()) ->
    {ok, [dest_ext()], call()} | continue().

nkmedia_call_resolve(Callee, Type, DestExts, Call) ->
    nkmedia_call_lib:resolve(Callee, Type, DestExts, Call).


%% @doc Called for each defined destination to be invited
%% A new session has already been started.
%% (You can however start your own session and return its is)
%% Then link will be registered with the session, and if it is selected, with the call
%% If accepted, must call nkmedia_call:ringing/answered/rejected
%% nkmeida_call will "bridge" the sessions
-spec nkmedia_call_invite(call_id(), dest(), session_id(), caller(), call()) ->
    {ok, nklib:link(), call()} | 
    {ok, nklib:link(), session_id(), call()} | 
    {retry, Secs::pos_integer(), call()} | 
    {remove, call()} | 
    continue().

nkmedia_call_invite(CallId, Dest, SessId, Caller, Call) ->
    nkmedia_call_lib:invite(CallId, Dest, SessId, Caller, Call).


%% @doc Called when an outbound invite has been cancelled
-spec nkmedia_call_cancelled(call_id(), nklib:link(), call()) ->
    {ok, call()} | continue().

nkmedia_call_cancelled(CallId, CalleeLink, Call) ->
    nkmedia_call_lib:cancel(CallId, CalleeLink, Call).


%% Called when the calling party has the answer available
-spec nkmedia_call_answer(call_id(), nklib:link(), callee(), call()) ->
    {ok, call()} | {error, nkservice:error(), call()}.

nkmedia_call_answer(_CallId, _CallerLink, _Callee, Call) ->
    {error, not_implemented, Call}.


%% Called when caller or callee has a new candidate availableanswer available
-spec nkmedia_call_candidate(call_id(), nklib:link(), nkmedia:candidate(), call()) ->
    {ok, call()} | {error, nkservice:error(), call()}.

nkmedia_call_candidate(_CallId, _Link, _Candidate, Call) ->
    {error, not_implemented, Call}.


%% @doc Called when the status of the call changes
-spec nkmedia_call_event(call_id(), nkmedia_call:event(), call()) ->
    {ok, call()} | continue().

nkmedia_call_event(CallId, Event, Call) ->
    nkmedia_call_api_events:event(CallId, Event, Call).


%% @doc Called when the status of the call changes, for each registered
%% process to the session
-spec nkmedia_call_reg_event(call_id(), nklib:link(), nkmedia_call:event(), call()) ->
    {ok, call()} | continue().


nkmedia_call_reg_event(CallId, {nkmedia_api, Pid}, {hangup, _Reason}, Call) ->
    nkservice_api_server:unregister(Pid, {nkmedia_call, CallId, self()}),


    gen_server:cast(Pid, {nkmedia_api_call_hangup, CallId, self()}),
    {ok, Call};

nkmedia_call_reg_event(_CallId, _Link, _Event, Call) ->
    {ok, Call}.


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


%% @doc Called when the Call must start the 'caller' session
%% Implemented by backends
-spec nkmedia_call_start_caller_session(call_id(), call()) ->
    {ok, nkmedia_session:id(), call()} | {error, nkservice:error(), call()} |
    continue().

nkmedia_call_start_caller_session(_CallId, Call) ->
    {error, not_implemented, Call}.


%% @doc Called when the Call must start a 'callee' session
%% Implemented by backends
-spec nkmedia_call_start_callee_session(call_id(), nkmedia_session:id(), call()) ->
    {ok, nkmedia_session:id(), map(), call()} | 
    {error, nkservice:error(), call()} |
    continue().

nkmedia_call_start_callee_session(_CallId, _SessId, Call) ->
    {error, not_implemented, Call}.


%% @doc Called when the call has both sessions and must be connected
%% Implemented by backend
-spec nkmedia_call_set_answer(call_id(), session_id(), session_id(), callee(), call()) ->
    {ok, call()} | {error, nkservice:error(), term()} | continue().

nkmedia_call_set_answer(_CallId, _CallerSessId, _CalleeSessId, _Callee, Call) ->
    {error, not_implemented, Call}.





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


%% ===================================================================
%% nkmedia_session
%% ===================================================================


%% @private
%% Convenient functions in case we are registered with the session as
%% {nkmedia_verto, CallId, Pid}
nkmedia_session_reg_event(SessId, {nkmedia_call, CallId, _Pid}, Event, _Session) ->
    nkmedia_call:session_event(CallId, SessId, Event),
    continue;

nkmedia_session_reg_event(_SessId, _Link, _Event, _Session) ->
    continue.



%% @private
nkmedia_session_handle_call({nkmedia_call, CallId, CallPid}, _From, Session) ->
    #{srv_id:=SrvId} = Session,
    nkmedia_session:register(self(), {nkmedia_call, CallId, CallPid}),
    Session2 = ?SESSION(#{call_id=>CallId}, Session),
    {reply, {ok, SrvId, self()}, Session2};

nkmedia_session_handle_call(_Msg, _From, _Session) ->
    continue.

