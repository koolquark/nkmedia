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

%% @doc NkMEDIA callbacks

-module(nkmedia_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_start/2, plugin_stop/2]).
-export([nkmedia_session_init/2, nkmedia_session_terminate/2, 
		 nkmedia_session_event/3, nkmedia_session_reg_event/4,
		 nkmedia_session_handle_call/3, nkmedia_session_handle_cast/2, 
		 nkmedia_session_handle_info/2]).
-export([nkmedia_session_start/2, nkmedia_session_answer/3, 
	     nkmedia_session_update/4, nkmedia_session_stop/2]).
-export([nkmedia_call_init/2, nkmedia_call_terminate/2, 
		 nkmedia_call_resolve/3, nkmedia_call_invite/4, nkmedia_call_cancel/3, 
		 nkmedia_call_event/3, nkmedia_call_reg_event/4, nkmedia_session_reg_down/4,
		 nkmedia_call_handle_call/3, nkmedia_call_handle_cast/2, 
		 nkmedia_call_handle_info/2]).
-export([error_code/1]).
-export([api_cmd/2, api_syntax/4]).
-export([api_server_cmd/2, api_server_handle_cast/2, api_server_handle_info/2]).
-export([nkdocker_notify/2]).

-include("nkmedia.hrl").
-include_lib("nkservice/include/nkservice.hrl").


-define(BASE_ERROR, 2000).

%% ===================================================================
%% Types
%% ===================================================================

-type continue() :: continue | {continue, list()}.



%% ===================================================================
%% Plugin callbacks
%%
%% These are used when NkMEDIA is started as a NkSERVICE plugin
%% ===================================================================


plugin_deps() ->
    [nksip].


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA CORE (~s) starting", [Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA CORE (~p) stopping", [Name]),
    {ok, Config}.







%% ===================================================================
%% Session Callbacks
%% ===================================================================

-type session_id() :: nkmedia_session:id().
-type session() :: nkmedia_session:session().


%% @doc Called when a new session starts
-spec nkmedia_session_init(session_id(), session()) ->
	{ok, session()} | {stop, Reason::term()}.

nkmedia_session_init(_Id, Session) ->
	{ok, Session}. 

%% @doc Called when the session stops
-spec nkmedia_session_terminate(Reason::term(), session()) ->
	{ok, session()}.

nkmedia_session_terminate(_Reason, Session) ->
	{ok, Session}.


-spec nkmedia_session_start(nkmedia_session:type(), session()) ->
	{ok, Reply::map(), nkmedia_session:ext_ops(), session()} |
	{error, nkservice:error(), session()} | continue().

nkmedia_session_start(p2p, Session) ->
	{ok, #{}, #{}, Session};

nkmedia_session_start(_Type, Session) ->
	{error, unknown_session_type, Session}.


%% @private
-spec nkmedia_session_answer(nkmedia_session:type(), nkmedia:answer(), session()) ->
	{ok, Reply::map(), nkmedia_session:ext_ops(), session()} |
	{error, term(), session()} | continue().

nkmedia_session_answer(Type, Answer, Session) ->
	{ok, #{}, #{answer=>Answer}, Session}.


%% @private
-spec nkmedia_session_update(nkmedia_session:update(), map(),
					         nkmedia_session:type(), session()) ->
	{ok, Reply::map(), nkmedia_session:ext_ops(), session()} |
	{error, term(), session()} | continue().

nkmedia_session_update(_Update, _Opts, _Type, Session) ->
	{error, invalid_operation, Session}.


%% @private%% @doc Called when the status of the session changes
-spec nkmedia_session_event(session_id(), nkmedia_session:event(), session()) ->
	{ok, session()} | continue().

nkmedia_session_event(_SessId, _Event, Session) ->
	{ok, Session}.

				  
%% @doc Called when the status of the session changes, for each registered
%% process to the session
-spec nkmedia_session_reg_event(session_id(), term(), 
								media_session:event(), session()) ->
	{ok, session()} | continue().

nkmedia_session_reg_event(_SessId, {caller_peer, SessIdB}, Event, Session) ->
	case Event of
		{answer, Answer} ->
			nkmedia_session:answer(SessIdB, Answer);
		{stop, Reason} ->
			nkmedia_session:stop(SessIdB, Reason);
		_ ->
			ok
	end,
	{ok, Session};

nkmedia_session_reg_event(_SessId, {callee_peer, SessIdB}, {stop, Reason}, Session) ->
	nkmedia_session:stop(SessIdB, Reason),
	{ok, Session};

nkmedia_session_reg_event(_SessId, {nkmedia_call, CallId, _CallPid}, {stop, Reason}, 						  Session) ->
	nkmedia_call:hangup(CallId, Reason),
	{ok, Session};

nkmedia_session_reg_event(SessId, {nkmedia_api, Pid}, {stop, _Reason}, Session) ->
	nkmedia_api:session_stop(Pid, SessId),
	{ok, Session};

nkmedia_session_reg_event(_SessId, _RegId, _Event, Session) ->
	{ok, Session}.


%% @doc Called when a registered process fails
-spec nkmedia_session_reg_down(session_id(), nklib:proc_id(), term(), session()) ->
	{ok, session()} | {stop, Reason::term(), session()} | continue().

nkmedia_session_reg_down(_SessId, _ProcId, _Reason, Session) ->
	{stop, registered_down, Session}.


%% @doc
-spec nkmedia_session_handle_call(term(), {pid(), term()}, session()) ->
	{reply, term(), session()} | {noreply, session()} | continue().

nkmedia_session_handle_call(Msg, _From, Session) ->
	lager:error("Module nkmedia_session received unexpected call: ~p", [Msg]),
	{noreply, Session}.


%% @doc
-spec nkmedia_session_handle_cast(term(), session()) ->
	{noreply, session()} | continue().

nkmedia_session_handle_cast(Msg, Session) ->
	lager:error("Module nkmedia_session received unexpected cast: ~p", [Msg]),
	{noreply, Session}.


%% @doc
-spec nkmedia_session_handle_info(term(), session()) ->
	{noreply, session()} | continue().

nkmedia_session_handle_info(Msg, Session) ->
	lager:warning("Module nkmedia_session received unexpected info: ~p", [Msg]),
	{noreply, Session}.


%% @private
-spec nkmedia_session_stop(nkservice:error(), session()) ->
	{ok, session()} | continue().

nkmedia_session_stop(_Reason, Session) ->
	{ok, Session}.


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


%% @doc Called when an outbound call is to be sent
-spec nkmedia_call_resolve(nkmedia_call:callee(), [nkmedia_call:dest_ext()], call()) ->
	{ok, [nkmedia_call:dest_ext()], call()} | continue().

nkmedia_call_resolve(Callee, DestExts, Call) ->
	nkmedia_api:call_resolve(Callee, DestExts, Call).


%% @doc Called when an outbound call is to be sent
-spec nkmedia_call_invite(call_id(), nkmedia_call:dest(), nkmedia:offer(), call()) ->
	{ok, nklib:proc_id(), call()} | 
	{retry, Secs::pos_integer(), call()} | 
	{remove, call()} | 
	continue().

nkmedia_call_invite(CallId, {nkmedia_api, Data}, Offer, Call) ->
	nkmedia_api:call_invite(CallId, Offer, Data, Call);

nkmedia_call_invite(_CallId, _Dest, _Offer, Call) ->
	{remove, Call}.


%% @doc Called when an outbound call is to be sent
-spec nkmedia_call_cancel(call_id(), nklib:proc_id(), call()) ->
	{ok, call()} | continue().

nkmedia_call_cancel(CallId, {nkmedia_api, Pid}, Call) ->
	nkmedia_api:call_cancel(CallId, Pid, Call);

nkmedia_call_cancel(_CallId, _ProcId, Call) ->
	{ok, Call}.


%% @doc Called when the status of the call changes
-spec nkmedia_call_event(call_id(), nkmedia_call:event(), call()) ->
	{ok, call()} | continue().

nkmedia_call_event(_CallId, _Event, Call) ->
	{ok, Call}.


%% @doc Called when the status of the call changes, for each registered
%% process to the session
-spec nkmedia_call_reg_event(call_id(),	term(), nkmedia_call:event(), call()) ->
	{ok, session()} | continue().

nkmedia_call_reg_event(_CallId, {nkmedia_session, SessId}, Event, Call) ->
	case Event of
		{answer, _Callee, Answer} ->
			nkmedia_session:answer(SessId, Answer);
		{hangup, Reason} ->
			nkmedia_session:stop(SessId, Reason);
		_ ->
			ok
	end,
	{ok, Call};

nkmedia_call_reg_event(CallId, {nkmedia_api, Pid}, {hangup, Reason}, Call) ->
	nkmedia_api:call_hangup(Pid, CallId, Reason),
	{ok, Call};

nkmedia_call_reg_event(_CallId, _RegId, _Event, Call) ->
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


%% ===================================================================
%% Error Codes

%% ===================================================================

%% @doc
-spec error_code(term()) ->
	{integer(), binary()} | continue.

error_code(Error) ->
	case nkmedia_util:error(Error) of
		not_found -> continue;
		{Code, Txt} -> {?BASE_ERROR+Code, Txt}
	end.



%% ===================================================================
%% API CMD
%% ===================================================================

%% @private
api_cmd(#api_req{class = <<"media">>}=Req, State) ->
	#api_req{subclass=Sub, cmd=Cmd} = Req,
	nkmedia_api:cmd(Sub, Cmd, Req, State);

api_cmd(_Req, _State) ->
	continue.


%% @private
api_syntax(#api_req{class = <<"media">>}=Req, Syntax, Defaults, Mandatory) ->
	#api_req{subclass=Sub, cmd=Cmd} = Req,
	nkmedia_api_syntax:syntax(Sub, Cmd, Syntax, Defaults, Mandatory);
	
api_syntax(_Req, _Syntax, _Defaults, _Mandatory) ->
	continue.



% ===================================================================
%% API Server Callbacks
%% ===================================================================

%% @private
api_server_cmd(#api_req{class = <<"media">>}=Req, State) ->
	nkservice_api:launch(Req, State);
	
api_server_cmd(_Req, _State) ->
    continue.


%% @private
api_server_handle_cast({nkmedia_api_session_stop, SessId}, State) ->
	nkmedia_api:nkmedia_api_session_stop(SessId, State);

api_server_handle_cast({nkmedia_api_call_hangup, CallId}, State) ->
	nkmedia_api:nkmedia_api_call_hangup(CallId, State);

api_server_handle_cast(_Msg, _State) ->
	continue.


%% @private
api_server_handle_info({'DOWN', Ref, process, _Pid, Reason}, State) ->
	#{srv_id:=SrvId} = State,
	nkmedia_api:handle_down(SrvId, Ref, Reason, State);

api_server_handle_info(_Msg, _State) ->
	continue.



%% ===================================================================
%% Docker Monitor Callbacks
%% ===================================================================

nkdocker_notify(MonId, {Op, {<<"nk_fs_", _/binary>>=Name, Data}}) ->
	nkmedia_fs_docker:notify(MonId, Op, Name, Data);

nkdocker_notify(MonId, {Op, {<<"nk_janus_", _/binary>>=Name, Data}}) ->
	nkmedia_janus_docker:notify(MonId, Op, Name, Data);

nkdocker_notify(_MonId, _Op) ->
	ok.


