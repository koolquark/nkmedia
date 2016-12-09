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

%% @doc Janus room (SFU) management
-module(nkmedia_janus_room).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([room_exists/2]).
-export([init/2, check/1, timeout/1, stop/2]).

-define(DEBUG(Txt, Args, State),
    case erlang:get(nkmedia_room_debug) of
        true -> ?LLOG(debug, Txt, Args, State);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args, Room),
    lager:Type("NkMEDIA Janus Room '~s' "++Txt, [maps:get(room_id, Room) | Args])).


-include("../../include/nkmedia_room.hrl").



%% ===================================================================
%% Types
%% ===================================================================


-type room_id() :: nkmedia_room:id().

-type room() ::
    nkmedia_room:room() |
    #{
        nkmedia_janus_id => nkmedia_janus:id()
    }.
        



%% ===================================================================
%% External
%% ===================================================================


%% @private
room_exists(JanusId, RoomId) ->
    case nklib_proc:values({?MODULE, JanusId, RoomId}) of
        [{_, _Pid}] -> true;
        _ -> false
    end.



%% ===================================================================
%% Callbacks
%% ===================================================================

%% @doc Creates a new room
%% Use nkmedia_janus_op:list_rooms/1 to check rooms directly on Janus
-spec init(room_id(), room()) ->
    {ok, room()} | {error, term()}.

init(RoomId, Room) ->
    case get_janus(Room) of
        {ok, JanusId} ->
            true = nklib_proc:reg({?MODULE, JanusId, RoomId}),
            create_room(JanusId, RoomId, Room);
        error ->
            {error, no_mediaserver}
    end.


%% @private
-spec check(room()) ->
    {ok, room()} | {stop, room_not_found, room()}.

check(#{nkmedia_janus_id:=JanusId, room_id:=RoomId}=Room) ->
    case nkmedia_janus_engine:get_room(JanusId, RoomId) of
        {ok, #{<<"num_participants">>:=Num}=Data} ->
            case length(nkmedia_room:get_all_with_role(publisher, Room)) of
                Num -> 
                    ?DEBUG("Janus check: ~p", [Data], Room),
                    ok;
                Other ->
                    ?LLOG(notice, "Janus says ~p participants, we have ~p!", 
                          [Num, Other], Room)
            end,
            {ok, Room};
        {error, room_not_found} ->
            ?LLOG(warning, "room not found on Janus!", [], Room),
            {stop, room_not_found, Room};
        {error, no_mediaserver} ->
            ?LLOG(warning, "mediaserver not found on check!", [], Room),
            {stop, no_mediaserver, Room};
        _ ->
            {ok, Room}
    end.


%% @private
-spec timeout(room()) ->
    {ok, room()} | {stop, nkservice:error(), room()}.

timeout(Room) ->
    case length(nkmedia_room:get_all_with_role(publisher, Room)) of
        0 ->
            {stop, timeout, Room};
        _ ->
            {ok, Room}
 end.


%% @doc
-spec stop(term(), room()) ->
    {ok, room()} | {error, term()}.

stop(_Reason, #{nkmedia_janus_id:=JanusId, room_id:=RoomId}=Room) ->
    case nkmedia_janus_engine:destroy_room(JanusId, RoomId) of
        ok ->
            ?DEBUG("stopping, destroying room", [], Room);
        {error, room_not_found} ->
            ok;
        {error, Error} ->
            ?LLOG(notice, "could not destroy room: ~p", [Error], Room)
    end,
    {ok, Room}.






% ===================================================================
%% Internal
%% ===================================================================


%% @private
-spec get_janus(room()) ->
    {ok, nkmedia_janus_engine:id()} | error.

get_janus(#{nkmedia_janus_id:=JanusId}) ->
    {ok, JanusId};

get_janus(#{srv_id:=SrvId}) ->
    case SrvId:nkmedia_janus_get_mediaserver(SrvId) of
        {ok, JanusId} ->
            {ok, JanusId};
            % ?ROOM(#{nkmedia_janus_id=>JanusId}, Room)};
        {error, _Error} ->
            error
    end.


%% @private
-spec create_room(nkmedia_janus_engine:id(), room_id(), room()) ->
    {ok, room()} | {error, term()}.

create_room(JanusId, RoomId, Room) ->
    Base = #{
        audio_codec => opus, 
        video_codec => vp8,
        bitrate => nkmedia_app:get(default_room_bitrate),
        nkmedia_janus_id => JanusId
    },
    Room2 = ?ROOM_MERGE(Base, Room),
    Opts = #{        
        audiocodec => maps:get(audio_codec, Room2),
        videocodec => maps:get(video_codec, Room2),
        bitrate => maps:get(bitrate, Room2)             % Default for publishers
    },                                                  
    case nkmedia_janus_engine:create_room(JanusId, RoomId, Opts) of
        ok ->
            Janus = #{
                class=>sfu, 
                backend=>nkmedia_janus,
                nkmedia_janus_id => JanusId
            },
            {ok, ?ROOM(Janus, Room2)};
        {error, room_already_exists} ->
            case nkmedia_janus_engine:destroy_room(JanusId, RoomId) of
                ok ->
                    create_room(JanusId, RoomId, Room);
                {error, Error} ->
                    ?LLOG(warning, "error removing starting room: ~p", [Error], Room),
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.

