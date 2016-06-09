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
		 nkmedia_session_invite/4, 
		 nkmedia_session_handle_call/3, nkmedia_session_handle_cast/2, 
		 nkmedia_session_handle_info/2]).
-export([nkmedia_session_offer_op/4, nkmedia_session_answer_op/4,
		 nkmedia_session_hangup/2,
		 nkmedia_session_updated_offer/2, nkmedia_session_updated_answer/2]).
-export([nkmedia_call_init/2, nkmedia_call_terminate/2, 
		 nkmedia_call_resolve/2, nkmedia_call_invite/3, 
		 nkmedia_call_event/3, 
		 nkmedia_call_handle_call/3, nkmedia_call_handle_cast/2, 
		 nkmedia_call_handle_info/2]).

-export([nkdocker_notify/2]).

-include("nkmedia.hrl").


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
    lager:info("Plugin NkMEDIA (~s) starting", [Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA (~p) stopping", [Name]),
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


%% @doc Called when the status of the session changes
-spec nkmedia_session_event(nkmedia_session:id(), nkmedia_session:event(), session()) ->
	{ok, session()} | continue().

nkmedia_session_event(_SessId, _Event, Session) ->
	{ok, Session}.

				  
%% @doc Called when the status of the session changes
-spec nkmedia_session_peer_event(nkmedia_session:id(), nkmedia_session:event(), 
								 caller|callee, session()) ->
	{ok, session()} | continue().

nkmedia_session_peer_event(_SessId, _Type, _Event, Session) ->
	{ok, Session}.


%% @doc Called when a new call must be sent from the session
%% If an answer is included, it can contain a pid() tha will be monitorized
%% New answers will be merged, but only one can contain an SDP
-spec nkmedia_session_invite(session_id(), nkmedia_session:call_dest(), 
						  nkmedia:offer(), session()) ->
	{ringing, nkmedia:answer(), session()} | 
	{answer, nkmedia:answer(), session()}  | 
	{async, nkmedia:answer(), session()}   |
	{hangup, nkmedia:hangup_reason(), session()}.

nkmedia_session_invite(_SessId, _CallDest, _Offer, Session) ->
	{hangup, <<"Unrecognized Destination">>, Session}.


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


%% @private You must generte an offer() for this offer_op()
%% ReplyOpts will only we used for user notification
-spec nkmedia_session_offer_op(nkmedia:offer_op(), nkmedia:op_opts(), 
							   HasOffer::boolean(), session()) ->
	{ok, nkmedia:offer(), Op::atom(), Opts::map(), session()} |
	{error, term(), session()} | continue().

nkmedia_session_offer_op(sdp, Opts, false, Session) ->
	{ok, maps:get(offer, Opts, #{}), sdp, Opts, Session};

nkmedia_session_offer_op(sdp, _Opts, teue, Session) ->
	{error, offer_already_set, Session};

nkmedia_session_offer_op(OfferOp, _Opts, _HasOffer, Session) ->
	{error, {unknown_op, OfferOp}, Session}.


%% @private
-spec nkmedia_session_answer_op(nkmedia:answer_op(), nkmedia:op_opts(), 
							     HasAnswer::boolean(), session()) ->
	{ok, nkmedia:answer(), Op::atom(), Opts::map(), session()} |
	{error, term(), session()} | continue().

nkmedia_session_answer_op(sdp, Opts, false, Session) ->
	{ok, maps:get(answer, Opts, #{}), sdp, Opts, Session};

nkmedia_session_answer_op(sdp, _Opts, true, Session) ->
	{error, answer_already_set, Session};

nkmedia_session_answer_op(invite, Opts, false, Session) ->
	{ok, maps:get(answer, Opts, #{}), invite, Opts, Session};

nkmedia_session_answer_op(invite, _Opts, true, Session) ->
	{error, answer_already_set, Session};

nkmedia_session_answer_op(AnswerOp, _Opts, _HasAnswer, Session) ->
	{error, {unknown_op, AnswerOp}, Session}.


%% @private
-spec nkmedia_session_updated_offer(nkmedia:offer(), session()) ->
	{ok, nkmedia:offer(), session()} |
	{error, term(), session()} | continue().

nkmedia_session_updated_offer(Offer, Session) ->
	{ok, Offer, Session}.


%% @private
-spec nkmedia_session_updated_answer(nkmedia:answer(), session()) ->
	{ok, nkmedia:answer(), session()} |
	{error, term(), session()} | continue().

nkmedia_session_updated_answer(Answer, Session) ->
	{ok, Answer, Session}.


%% @private
-spec nkmedia_session_hangup(nkmedia:hangup_reason(), session()) ->
	{ok, session()} | continue().

nkmedia_session_hangup(_Reason, Session) ->
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


%% @doc Called when the status of the call changes
-spec nkmedia_call_event(call_id(), nkmedia_call:event(), call()) ->
	{ok, call()} | continue().

nkmedia_call_event(_CallId, _Event, Call) ->
	{ok, Call}.


%% @doc Called when a call specificatio must be resolved
-spec nkmedia_call_resolve(nkmedia:call_dest(), call()) ->
	{ok, nkmedia_call:call_out_spec(), call()} | 
	{hangup, nkmedia:hangup_reason(), call()} |
	continue().

nkmedia_call_resolve(_Dest, Call) ->
	{hangup,  <<"Unknown Destination">>, Call}.


%% @doc Called when an outbound call is to be sent
-spec nkmedia_call_invite(session_id(), nkmedia_session:call_dest(), call()) ->
	{call, nkmedia_session:call_dest(), call()} | 
	{retry, Secs::pos_integer(), call()} | 
	{remove, call()} | 
	continue().

nkmedia_call_invite(_SessId, Dest, Call) ->
	{call, Dest, Call}.


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
%% Docker Monitor Callbacks
%% ===================================================================

nkdocker_notify(MonId, {Op, {<<"nk_fs_", _/binary>>=Name, Data}}) ->
	nkmedia_fs_docker:notify(MonId, Op, Name, Data);

nkdocker_notify(MonId, {Op, {<<"nk_janus_", _/binary>>=Name, Data}}) ->
	nkmedia_janus_docker:notify(MonId, Op, Name, Data);

nkdocker_notify(_MonId, _Op) ->
	ok.


