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

%% @doc Room Plugin Callbacks
-module(nkmedia_room_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_start/2, plugin_stop/2]).
-export([nkmedia_room_init/2, nkmedia_room_terminate/2, 
         nkmedia_room_event/3, nkmedia_room_reg_event/4, nkmedia_room_reg_down/4,
         nkmedia_room_timeout/2, 
         nkmedia_room_handle_call/3, nkmedia_room_handle_cast/2, 
         nkmedia_room_handle_info/2]).
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
    lager:info("Plugin NkMEDIA ROOM (~s) starting", [Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA ROOM (~p) stopping", [Name]),
    {ok, Config}.



%% ===================================================================
%% Error Codes
%% ===================================================================

%% @doc See nkservice_callbacks
-spec error_code(term()) ->
    {integer(), binary()} | continue.

error_code(room_not_found)          ->  {304001, "Room not found"};
error_code(room_already_exists)     ->  {304002, "Room already exists"};
error_code(room_destroyed)          ->  {304003, "Room destroyed"};
error_code(no_room_members)         ->  {304004, "No remaining room members"};
error_code(invalid_publisher)       ->  {304005, "Invalid publisher"};
error_code(publisher_stop)          ->  {304006, "Publisher stopped"};

error_code(_) -> continue.



%% ===================================================================
%% Room Callbacks - Generated from nkmedia_room
%% ===================================================================

-type room_id() :: nkmedia_room:id().
-type room() :: nkmedia_room:room().



%% @doc Called when a new room starts
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
    nkmedia_room_api_events:event(RoomId, Event, Room).


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


%% @doc Called when the timeout timer fires
-spec nkmedia_room_timeout(room_id(), room()) ->
    {ok, room()} | {stop, nkservice:error(), room()} | continue().

nkmedia_room_timeout(_RoomId, Room) ->
    {stop, timeout, Room}.


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



%% ===================================================================
%% API CMD
%% ===================================================================

%% @private
api_cmd(#api_req{class = <<"media">>, subclass = <<"room">>, cmd=Cmd}=Req, State) ->
    nkmedia_room_api:cmd(Cmd, Req, State);

api_cmd(_Req, _State) ->
    continue.


%% @private
api_syntax(#api_req{class = <<"media">>, subclass = <<"room">>, cmd=Cmd}, 
           Syntax, Defaults, Mandatory) ->
    nkmedia_room_api_syntax:syntax(Cmd, Syntax, Defaults, Mandatory);
    
api_syntax(_Req, _Syntax, _Defaults, _Mandatory) ->
    continue.



%% ===================================================================
%% API Server
%% ===================================================================

