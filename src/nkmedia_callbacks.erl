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
		 nkmedia_session_reg_down/4,
		 nkmedia_session_handle_call/3, nkmedia_session_handle_cast/2, 
		 nkmedia_session_handle_info/2]).
-export([nkmedia_session_start/3, nkmedia_session_stop/2,
	     nkmedia_session_offer/4, nkmedia_session_answer/4, 
		 nkmedia_session_cmd/3, nkmedia_session_candidate/2]).
-export([error_code/1]).
-export([api_cmd/2, api_syntax/4]).
-export([api_server_cmd/2, api_server_reg_down/3, 
	     api_server_handle_cast/2, api_server_handle_info/2]).
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
%% Error Codes
%% ===================================================================

%% @doc NkMEDIA - 2XXX range
-spec error_code(term()) ->
	{integer(), binary()} | continue.


error_code(no_mediaserver) 			-> 	{2001, <<"No mediaserver available">>};
error_code(different_mediaserver) 	-> 	{2002, <<"Different mediaserver">>};
error_code(unknown_session_type) 	-> 	{2003, <<"Unknown session type">>};
error_code(backed_error) 			-> 	{2004, <<"Backend error">>};

error_code(missing_offer) 			-> 	{2010, <<"Missing offer">>};
error_code(duplicated_offer) 		-> 	{2011, <<"Duplicated offer">>};
error_code(offer_not_set) 			-> 	{2012, <<"Offer not set">>};
error_code(offer_already_set) 		-> 	{2013, <<"Offer already set">>};
error_code(remote_offer_error) 		-> 	{2014, <<"Remote offer error">>};
error_code(duplicated_answer) 		-> 	{2015, <<"Duplicated answer">>};
error_code(answer_not_set) 			-> 	{2016, <<"Answer not set">>};
error_code(answer_already_set) 		-> 	{2017, <<"Answer already set">>};
error_code(no_ice_candidates) 		-> 	{2018, <<"No ICE candidates">>};

error_code(call_not_found) 			->  {2020, <<"Call not found">>};
error_code(call_rejected)			->  {2021, <<"Call rejected">>};
error_code(no_destination) 			->  {2022, <<"No destination">>};
error_code(no_answer) 				->  {2023, <<"No answer">>};
error_code(already_answered) 		->  {2024, <<"Already answered">>};
error_code(originator_cancel)		-> 	{2025, <<"Originator cancel">>};
error_code(peer_hangup)				-> 	{2026, <<"Peer hangup">>};

error_code(room_srv_not_started)	->  {2030, <<"Room plugin not started">>};
error_code(room_not_found)			->  {2031, <<"Room not found">>};
error_code(room_already_exists)	    ->  {2032, <<"Room already exists">>};
error_code(room_destroyed)          ->  {2033, <<"Room destroyed">>};
error_code(no_room_members)		    ->  {2034, <<"No remaining room members">>};
error_code(unknown_publisher)	    ->  {2035, <<"Unknown publisher">>};
error_code(invalid_publisher)       ->  {2036, <<"Invalid publisher">>};
error_code(publisher_stopped)       ->  {2037, <<"Publisher stopped">>};

error_code(call_error)       		->  {2040, <<"Call error">>};
error_code(bridge_stop)       		->  {2041, <<"Bridge stop">>};
error_code(peer_stopped)       		->  {2042, <<"Peer session stopped">>};

error_code(no_active_recorder) 		->  {2050, <<"No active recorder">>};
error_code(record_start_error) 		->  {2051, <<"Record start error">>};

error_code(no_active_player) 		->  {2060, <<"No active player">>};
error_code(player_start_error) 		->  {2061, <<"Player start error">>};

error_code(set_media_not_allowed) 	->  {2070, <<"Update media not allowed">>};

% error_code(Code) when is_integer(Code) -> get_q850(Code);
error_code(_) -> continue.



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


%% @private
-spec nkmedia_session_start(nkmedia_session:type(), nkmedia:role(), session()) ->
	{ok, session()} |
	{error, nkservice:error(), session()} | continue().

nkmedia_session_start(_Type, _Role, Session) ->
	{ok, Session}.


%% @private
%% Plugin can update the offer
-spec nkmedia_session_offer(nkmedia_session:type(), nkmedia:role(), 
							nkmedia:offer(), session()) ->
	{ok, nkmedia:offer(), session()} | {ignore, session()} | 
	{error, nkservice:error(), session()} | continue().

nkmedia_session_offer(_Type, _Role, Offer, Session) ->
	{ok, Offer, Session}.


%% @private
%% Plugin can update the answer
-spec nkmedia_session_answer(nkmedia_session:type(), nkmedia:role(), 
							 nkmedia:answer(), session()) ->
	{ok, nkmedia:answer(), session()} | {ignore, session()} | 
	{error, nkservice:error(), session()} | continue().

nkmedia_session_answer(_Type, _Role, Answer, Session) ->
	{ok, Answer, Session}.


% %% @private
% -spec nkmedia_session_slave_answer(nkmedia:answer(), session()) ->
% 	{ok, nkmedia:answer(), session()} | {ignore, session()} | continue().

% nkmedia_session_slave_answer(Answer, Session) ->
% 	{ok, Answer, Session}.


%% @private
-spec nkmedia_session_cmd(nkmedia_session:cmd(), Opts::map(), session()) ->
	{ok, Reply::map(), session()} |
	{error, term(), session()} | continue().

nkmedia_session_cmd(_Cmd, _Opts, Session) ->
	{error, invalid_operation, Session}.


%% @private
-spec nkmedia_session_candidate(nkmedia:candidate(), session()) ->
	{ok, session()} | continue().

nkmedia_session_candidate(Candidate, Session) ->
	{continue, [Candidate, Session]}.


% %% @private
% -spec nkmedia_session_peer_candidate(nkmedia:candidate(), session()) ->
% 	{ok, nkmedia:candidate(), session()} | {ignore, session()} | continue().

% nkmedia_session_peer_candidate(Candidate, Session) ->
% 	{ok, Candidate, Session}.


%% @private%% @doc Called when the status of the session changes
-spec nkmedia_session_event(session_id(), nkmedia_session:event(), session()) ->
	{ok, session()} | continue().

nkmedia_session_event(SessId, Event, Session) ->
	{ok, Session2} = nkmedia_api_events:event(SessId, Event, Session),
	{ok, Session2}.

				  
%% @doc Called when the status of the session changes, for each registered
%% process to the session
-spec nkmedia_session_reg_event(session_id(), nklib:link(), 
								media_session:event(), session()) ->
	{ok, session()} | continue().

nkmedia_session_reg_event(_SessId, {nkmedia_call, CallId, _CallPid}, {stop, Reason}, 						  Session) ->
	nkmedia_call:hangup(CallId, Reason),
	{ok, Session};

nkmedia_session_reg_event(SessId, Link, Event, Session) ->
	% lager:warning("RE: ~p, ~p", [Link, Event]),
	nkmedia_api:nkmedia_session_reg_event(SessId, Link, Event, Session),
	{ok, Session}.


%% @doc Called when a registered process fails
-spec nkmedia_session_reg_down(session_id(), nklib:link(), term(), session()) ->
	{ok, session()} | {stop, Reason::term(), session()} | continue().

nkmedia_session_reg_down(_SessId, _Link, _Reason, Session) ->
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

%% @private Launch class media (api_cmd/2 will be called)
api_server_cmd(#api_req{class = <<"media">>}=Req, State) ->
	nkservice_api:launch(Req, State);
	
api_server_cmd(_Req, _State) ->
    continue.


%% @private
api_server_reg_down(Link, Reason, State) ->
	nkmedia_api:api_server_reg_down(Link, Reason, State).


%% @private
api_server_handle_cast(Msg, State) ->
	nkmedia_api:api_server_handle_cast(Msg, State).


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


