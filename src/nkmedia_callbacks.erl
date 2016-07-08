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
		 nkmedia_session_event/3, nkmedia_session_peer_event/4, 
		 nkmedia_session_reg_event/4,
		 nkmedia_session_handle_call/3, nkmedia_session_handle_cast/2, 
		 nkmedia_session_handle_info/2]).
-export([nkmedia_session_type/2, nkmedia_session_answer/3, 
	     nkmedia_session_update/4, nkmedia_session_stop/2]).
-export([nkmedia_call_init/2, nkmedia_call_terminate/2, 
		 nkmedia_call_invite/4, nkmedia_call_cancel/3, nkmedia_call_event/3, 
		 nkmedia_call_handle_call/3, nkmedia_call_handle_cast/2, 
		 nkmedia_call_handle_info/2]).
-export([error_code/1]).
-export([api_cmd/8, api_cmd_syntax/6]).
-export([api_server_cmd/5, api_server_handle_info/2]).
-export([nkdocker_notify/2]).

-include("nkmedia.hrl").

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


-spec nkmedia_session_type(nkmedia_session:type(), session()) ->
	{ok, nkmedia_session:type(), Reply::map(), session()} |
	{error, nkservice:error(), session()} | continue().

nkmedia_session_type(p2p, Session) ->
	{ok, p2p, #{}, Session};

nkmedia_session_type(_Type, Session) ->
	{error, unknown_session_class, Session}.


%% @private
-spec nkmedia_session_answer(nkmedia_session:type(), nkmedia:answer(), session()) ->
	{ok, Reply::map(), nkmedia:answer(), session()} |
	{error, term(), session()} | continue().

nkmedia_session_answer(_Type, Answer, Session) ->
	{ok, #{}, Answer, Session}.


%% @private
-spec nkmedia_session_update(nkmedia_session:update(), map(),
					         nkmedia_session:type(), session()) ->
	{ok, nkmedia_session:type(), Reply::map(), session()} |
	{error, term(), session()} | continue().

nkmedia_session_update(_Update, _Opts, _Type, Session) ->
	{error, unknown_operation, Session}.


%% @private%% @doc Called when the status of the session changes
-spec nkmedia_session_event(nkmedia_session:id(), nkmedia_session:event(), session()) ->
	{ok, session()} | continue().

nkmedia_session_event(SessId, Event, Session) ->
	case Session of
		#{{link, nkmedia_cmd}:=Pid} ->
			nkmedia_cmd:session_event(SessId, Event, Pid);
		_ ->
			ok
	end,
	{ok, Session}.

				  
%% @doc Called when the status of the session changes
-spec nkmedia_session_peer_event(nkmedia_session:id(), nkmedia_session:event(), 
								 caller|callee, session()) ->
	{ok, session()} | continue().

nkmedia_session_peer_event(_SessId, _Type, _Event, Session) ->
	{ok, Session}.


%% @doc Called when the status of the session changes, for each registered
%% process to the session
-spec nkmedia_session_reg_event(nkmedia_session:id(), term(), 
								nkmedia_session:event(), session()) ->
	{ok, session()} | continue().

% nkmedia_session_reg_event(SessId, {nkmedia_api, Events, Pid}, Event, Session) ->
% 	#{srv_id:=SrvId} = Session,
% 	nkmedia_api:session_event(SrvId, SessId, Event, Pid, Events),
% 	{ok, Session};

nkmedia_session_reg_event(_SessId, _RegId, _Event, Session) ->
	{ok, Session}.


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
-spec nkmedia_call_invite(call_id(), nkmedia_call:dest(), nkmedia:offer(), call()) ->
	{ok, nklib:proc_id(), call()} | 
	{retry, Secs::pos_integer(), call()} | 
	{remove, call()} | 
	continue().

nkmedia_call_invite(_CallId, _Offer, _Dest, Call) ->
	{remove, Call}.


%% @doc Called when an outbound call is to be sent
-spec nkmedia_call_cancel(call_id(), nklib:proc_id(), call()) ->
	{ok, call()} | continue().

nkmedia_call_cancel(_CallId, _ProcId, Call) ->
	{ok, Call}.


%% @doc Called when the status of the call changes
-spec nkmedia_call_event(call_id(), nkmedia_call:event(), call()) ->
	{ok, call()} | continue().

nkmedia_call_event(_CallId, _Event, Call) ->
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
api_cmd(SrvId, _User, _SessId, <<"media">>, Cmd, Parsed, _TId, State) ->
	nkmedia_api:cmd(SrvId, Cmd, Parsed, State);

api_cmd(_SrvId, _User, _SessId, _Class, _Cmd, _Parsed, _TId, _State) ->
	continue.


%% @private
api_cmd_syntax(<<"media">>, Cmd, _Data, Syntax, Defaults, Mandatory) ->
	nkmedia_api:syntax(Cmd, Syntax, Defaults, Mandatory);
	
api_cmd_syntax(_Class, _Cmd, _Data, _Syntax, _Defaults, _Mandatory) ->
	continue.



% ===================================================================
%% API Server Callbacks
%% ===================================================================

%% @private
api_server_cmd(<<"media">>, Cmd, Data, TId, State) ->
	#{srv_id:=SrvId, user:=User, session_id:=SessId} = State,
	nkservice_api:launch(SrvId, User, SessId, <<"media">>, Cmd, Data, TId, State);
	
api_server_cmd(_Class, _Cmd, _Data, _TId, _State) ->
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


