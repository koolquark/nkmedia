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

%% @doc Kurento room management
-module(nkmedia_kms_room).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([init/2, stop/2, timeout/2]).

-define(DEBUG(Txt, Args, State),
    case erlang:get(nkmedia_room_debug) of
        true -> ?LLOG(debug, Txt, Args, State);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args, Room),
    lager:Type("NkMEDIA Kms Room ~s "++Txt, [maps:get(room_id, Room) | Args])).

-include("../../include/nkmedia_room.hrl").


%% ===================================================================
%% Types
%% ===================================================================


-type room_id() :: nkmedia_room:id().

-type room() ::
    nkmedia_room:room() |
    #{
        nkmedia_kms_id => nkmedia_kms:id()
    }.



%% ===================================================================
%% External
%% ===================================================================




%% ===================================================================
%% Callbacks
%% ===================================================================



%% @doc Creates a new room
-spec init(room_id(), room()) ->
    {ok, room()} | {error, term()}.

init(_RoomId, Room) ->
    case get_kms(Room) of
        {ok, Room2} ->
            {ok, ?ROOM(#{class=>sfu, backend=>nkmedia_kms}, Room2)};
       error ->
            {error, no_mediaserver}
    end.


%% @doc
-spec stop(term(), room()) ->
    {ok, room()} | {error, term()}.

stop(_Reason, Room) ->
    ?DEBUG("stopping, destroying room", [], Room),
    {ok, Room}.



%% @private
-spec timeout(room_id(), room()) ->
    {ok, room()} | {stop, nkservice:error(), room()}.

timeout(_RoomId, Room) ->
    case length(nkmedia_room:get_all_with_role(publisher, Room)) of
        0 ->
            {stop, timeout, Room};
        _ ->
            {ok, Room}
    end.



% ===================================================================
%% Internal
%% ===================================================================


%% @private
get_kms(#{nkmedia_kms_id:=_}=Room) ->
    {ok, Room};

get_kms(#{srv_id:=SrvId}=Room) ->
    case SrvId:nkmedia_kms_get_mediaserver(SrvId) of
        {ok, KmsId} ->
            {ok, ?ROOM(#{nkmedia_kms_id=>KmsId}, Room)};
        {error, _Error} ->
            error
    end.
