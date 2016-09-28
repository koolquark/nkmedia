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

-export([init/2, terminate/2, tick/2, handle_cast/2]).
-export([janus_check/3]).

-define(LLOG(Type, Txt, Args, Room),
    lager:Type("NkMEDIA Janus Room ~s "++Txt, [maps:get(room_id, Room) | Args])).

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

%% @private Called periodically from nkmedia_janus_engine
janus_check(JanusId, RoomId, Data) ->
    case nkmedia_room:find(RoomId) of
        {ok, Pid} ->
            #{<<"num_participants">>:=Num} = Data,
            gen_server:cast(Pid, {nkmedia_janus, {participants, Num}});
        not_found ->
            spawn(
                fun() -> 
                    lager:warning("Destroying orphan Janus room ~s", [RoomId]),
                    destroy_room(#{nkmedia_janus_id=>JanusId, room_id=>RoomId})
                end)
    end.



%% ===================================================================
%% Callbacks
%% ===================================================================

%% @doc Creates a new room
%% Use nkmedia_janus_op:list_rooms/1 to check rooms directly on Janus
-spec init(room_id(), room()) ->
    {ok, room()} | {error, term()}.

init(_RoomId, Room) ->
    case get_janus(Room) of
        {ok, Room2} ->
            case create_room(Room2) of
                {ok, Room3} ->
                    {ok, ?ROOM(#{class=>sfu, backend=>nkmedia_janus}, Room3)};
                {error, Error} ->
                    {error, Error}
            end;
       error ->
            {error, mediaserver_not_available}
    end.


%% @doc
-spec terminate(term(), room()) ->
    {ok, room()} | {error, term()}.

terminate(_Reason, Room) ->
    case destroy_room(Room) of
        ok ->
            ?LLOG(info, "stopping, destroying room", [], Room);
        {error, Error} ->
            ?LLOG(warning, "could not destroy room: ~p", [Error], Room)
    end,
    {ok, Room}.



%% @private
-spec tick(room_id(), room()) ->
    {ok, room()} | {stop, nkservice:error(), room()}.

tick(RoomId, #{nkmedia_janus_id:=JanusId}=Room) ->
    case length(nkmedia_room:get_all_with_role(publisher, Room)) of
        0 ->
            nkmedia_room:stop(self(), timeout);
        _ ->
           case nkmedia_janus_engine:check_room(JanusId, RoomId) of
                {ok, _} ->      
                    ok;
                _ ->
                    ?LLOG(warning, "room is not on engine ~p ~p", 
                          [JanusId, RoomId], Room),
                    nkmedia_room:stop(self(), timeout)
            end
    end,
    {ok, Room}.


%% @private
-spec handle_cast(term(), room()) ->
    {noreply, room()}.

handle_cast({participants, Num}, Room) ->
    case length(nkmedia_room:get_all_with_role(publisher, Room)) of
        Num -> 
            ok;
        Other ->
            ?LLOG(notice, "Janus says ~p participants, we have ~p!", 
                  [Num, Other], Room),
            case Num of
                0 ->
                    nkmedia_room:stop(self(), no_room_members);
                _ ->
                    ok
            end
    end,
    {noreply, Room}.




% ===================================================================
%% Internal
%% ===================================================================


%% @private
-spec get_janus(room()) ->
    {ok, room()} | error.

get_janus(#{nkmedia_janus_id:=_}=Room) ->
    {ok, Room};

get_janus(#{srv_id:=SrvId}=Room) ->
    case SrvId:nkmedia_janus_get_mediaserver(SrvId) of
        {ok, JanusId} ->
            {ok, ?ROOM(#{nkmedia_janus_id=>JanusId}, Room)};
        {error, _Error} ->
            error
    end.


%% @private
-spec create_room(room()) ->
    {ok, room()} | {error, term()}.

create_room(#{nkmedia_janus_id:=JanusId, room_id:=RoomId}=Room) ->
    Merge = #{audio_codec=>opus, video_codec=>vp8, bitrate=>500000},
    Room2 = ?ROOM_MERGE(Merge, Room),
    Opts = #{        
        audiocodec => maps:get(audio_codec, Room2),
        videocodec => maps:get(video_codec, Room2),
        bitrate => maps:get(bitrate, Room2)
    },
    case nkmedia_janus_op:start(JanusId, RoomId) of
        {ok, Pid} ->
            case nkmedia_janus_op:create_room(Pid, RoomId, Opts) of
                ok ->
                    {ok, Room2};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


-spec destroy_room(room()) ->
    ok | {error, term()}.

destroy_room(#{nkmedia_janus_id:=JanusId, room_id:=RoomId}) ->
    case nkmedia_janus_op:start(JanusId, RoomId) of
        {ok, Pid} ->
            nkmedia_janus_op:destroy_room(Pid, RoomId);
        {error, Error} ->
            {error, Error}
    end.


