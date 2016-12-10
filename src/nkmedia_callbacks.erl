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

-export([plugin_deps/0]).
-export([nkmedia_session_init/2, nkmedia_session_terminate/2, 
		 nkmedia_session_event/3, nkmedia_session_reg_event/4,
		 nkmedia_session_reg_down/4,
		 nkmedia_session_handle_call/3, nkmedia_session_handle_cast/2, 
		 nkmedia_session_handle_info/2]).
-export([nkmedia_session_start/3, nkmedia_session_stop/2,
	     nkmedia_session_offer/4, nkmedia_session_answer/4, 
		 nkmedia_session_cmd/3, nkmedia_session_candidate/2]).
-export([nkmedia_room_init/2, nkmedia_room_terminate/2, 
         nkmedia_room_event/3, nkmedia_room_reg_event/4, nkmedia_room_reg_down/4,
         nkmedia_room_check/2, nkmedia_room_timeout/2, nkmedia_room_stop/2,
         nkmedia_room_handle_call/3, nkmedia_room_handle_cast/2, 
         nkmedia_room_handle_info/2]).
-export([error_code/1]).
-export([api_server_cmd/2, api_server_syntax/4, api_server_reg_down/3]).
-export([nkdocker_notify/2]).

-include("nkmedia.hrl").
-include_lib("nkservice/include/nkservice.hrl").



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



%% ===================================================================
%% Error Codes
%% ===================================================================

%% @doc See nkservice_callbacks.erl
-spec error_code(term()) ->
	{integer(), binary()} | continue.

error_code(no_mediaserver) 			-> 	{300001, "No mediaserver available"};
error_code(different_mediaserver) 	-> 	{300002, "Different mediaserver"};
error_code(unknown_backend)         ->  {300003, "Unknown backend"};
error_code(session_failed) 			-> 	{300004, "Session has failed"};
error_code(incompatible_session)    -> 	{300005, "Incompatible session"};

error_code(offer_not_set) 			-> 	{300010, "Offer not set"};
error_code(offer_already_set) 		-> 	{300011, "Offer already set"};
error_code(answer_not_set) 			-> 	{300012, "Answer not set"};
error_code(answer_already_set) 		-> 	{300013, "Answer already set"};
error_code(no_ice_candidates) 		-> 	{300014, "No ICE candidates"};
error_code(missing_sdp) 			-> 	{300015, "Missing SDP"};

error_code(bridge_stop)       		->  {300020, "Bridge stop"};
error_code(peer_stopped)       		->  {300021, "Peer session stopped"};

error_code(no_active_recorder) 		->  {300030, "No active recorder"};
error_code(no_active_player) 		->  {300031, "No active player"};
error_code(no_active_room)	 		->  {300032, "No active room"};

error_code(room_not_found)          ->  {304001, "Room not found"};
error_code(room_already_exists)     ->  {304002, "Room already exists"};
error_code(room_destroyed)          ->  {304003, "Room destroyed"};
error_code(no_room_members)         ->  {304004, "No remaining room members"};
error_code(invalid_publisher)       ->  {304005, "Invalid publisher"};
error_code(publisher_stop)          ->  {304006, "Publisher stopped"};

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

nkmedia_session_start(p2p, _Role, Session) ->
	{ok, ?SESSION(#{backend=>p2p}, Session)};

nkmedia_session_start(_Type, _Role, Session) ->
	{error, not_implemented, Session}.
	

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


%% @private
-spec nkmedia_session_cmd(nkmedia_session:cmd(), Opts::map(), session()) ->
	{ok, Reply::map(), session()} |
	{error, term(), session()} | continue().

nkmedia_session_cmd(_Cmd, _Opts, Session) ->
	{error, not_implemented, Session}.


%% @private
-spec nkmedia_session_candidate(nkmedia:candidate(), session()) ->
	{ok, session()} | continue().

nkmedia_session_candidate(Candidate, Session) ->
	{continue, [Candidate, Session]}.


%% @private%% @doc Called when the status of the session changes
-spec nkmedia_session_event(session_id(), nkmedia_session:event(), session()) ->
	{ok, session()} | continue().

nkmedia_session_event(SessId, Event, Session) ->
	{ok, Session2} = nkmedia_session_api_events:event(SessId, Event, Session),
	{ok, Session2}.

				  
%% @doc Called when the status of the session changes, for each registered
%% process to the session
-spec nkmedia_session_reg_event(session_id(), nklib:link(), 
								media_session:event(), session()) ->
	{ok, session()} | continue().

nkmedia_session_reg_event(SessId, {nkmedia_api, Pid}, {stopped, _Reason}, Session) ->
	nkmedia_session_api:session_stopped(SessId, Pid, Session),
	{ok, Session};

nkmedia_session_reg_event(_SessId, _Link, _Event, Session) ->
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
%% Room Callbacks - Generated from nkmedia_room
%% ===================================================================

-type room_id() :: nkmedia_room:id().
-type room() :: nkmedia_room:room().



%% @doc Called when a new room starts
%% Backend must set the 'backend' property
-spec nkmedia_room_init(room_id(), room()) ->
    {ok, room()} | {error, term()}.

nkmedia_room_init(_RoomId, Room) ->
    {ok, Room}.


%% @doc Called when the room stops
-spec nkmedia_room_terminate(Reason::term(), room()) ->
    {ok, room()}.

nkmedia_room_terminate(_Reason, Room) ->
    {ok, Room}.


%% @doc Called when the status of the room changes
-spec nkmedia_room_event(room_id(), nkmedia_room:event(), room()) ->
    {ok, room()} | continue().

nkmedia_room_event(RoomId, Event, Room) ->
    ok = nkmedia_room_api_events:event(RoomId, Event, Room),
    {ok, Room}.


%% @doc Called when the status of the room changes, for each registered
%% process to the room
-spec nkmedia_room_reg_event(room_id(), nklib:link(), nkmedia_room:event(), room()) ->
    {ok, room()} | continue().

nkmedia_room_reg_event(_RoomId, _Link, _Event, Room) ->
    {ok, Room}.


%% @doc Called when a registered process fails
-spec nkmedia_room_reg_down(room_id(), nklib:link(), term(), room()) ->
    {ok, room()} | {stop, Reason::term(), room()} | continue().

nkmedia_room_reg_down(_RoomId, _Link, _Reason, Room) ->
    {stop, registered_down, Room}.


%% @doc Called when the check timer fires
-spec nkmedia_room_check(room_id(), room()) ->
    {ok, room()} | {stop, nkservice:error(), room()} | continue().

nkmedia_room_check(_RoomId, Room) ->
    {ok, Room}.


%% @doc Called when the timeout timer fires
-spec nkmedia_room_timeout(room_id(), room()) ->
    {ok, room()} | {stop, nkservice:error(), room()} | continue().

nkmedia_room_timeout(_RoomId, Room) ->
    {stop, timeout, Room}.


%% @doc Called when the timeout timer fires
-spec nkmedia_room_stop(term(), room()) ->
    {ok, room()}.

nkmedia_room_stop(_Reason, Room) ->
    {ok, Room}.


%% @doc
-spec nkmedia_room_handle_call(term(), {pid(), term()}, room()) ->
    {reply, term(), room()} | {noreply, room()} | continue().

nkmedia_room_handle_call(Msg, _From, Room) ->
    lager:error("Module nkmedia_room received unexpected call: ~p", [Msg]),
    {noreply, Room}.


%% @doc
-spec nkmedia_room_handle_cast(term(), room()) ->
    {noreply, room()} | continue().

nkmedia_room_handle_cast(Msg, Room) ->
    lager:error("Module nkmedia_room received unexpected cast: ~p", [Msg]),
    {noreply, Room}.


%% @doc
-spec nkmedia_room_handle_info(term(), room()) ->
    {noreply, room()} | continue().

nkmedia_room_handle_info(Msg, Room) ->
    lager:warning("Module nkmedia_room received unexpected info: ~p", [Msg]),
    {noreply, Room}.



% ===================================================================
%% API Server Callbacks
%% ===================================================================

%% @private
api_server_cmd(#api_req{class=media, subclass=session, cmd=Cmd}=Req, State) ->
	nkmedia_session_api:cmd(Cmd, Req, State);

api_server_cmd(#api_req{class=media, subclass=room, cmd=Cmd}=Req, State) ->
    nkmedia_room_api:cmd(Cmd, Req, State);

api_server_cmd(_Req, _State) ->
	continue.


%% @private
api_server_syntax(#api_req{class=media, subclass=session, cmd=Cmd}, 
		   		  Syntax, Defaults, Mandatory) ->
	nkmedia_session_api_syntax:syntax(Cmd, Syntax, Defaults, Mandatory);
	
api_server_syntax(#api_req{class=media, subclass=room, cmd=Cmd}, 
                  Syntax, Defaults, Mandatory) ->
    nkmedia_room_api_syntax:syntax(Cmd, Syntax, Defaults, Mandatory);

api_server_syntax(_Req, _Syntax, _Defaults, _Mandatory) ->
	continue.


%% @private
api_server_reg_down({nkmedia_session, SessId, _SessPid}, Reason, State) ->
	nkmedia_session_api:api_session_down(SessId, Reason, State),
	continue;

api_server_reg_down(_Link, _Reason, _State) ->
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


