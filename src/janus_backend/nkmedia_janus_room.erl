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
%% Rooms can be created directly or from nkmedia_janus_session (for publish)
%% When a new publisher or listener is started, nkmedia_janus_op sends an event
%% and we monitor it

-module(nkmedia_janus_room).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([init/2, terminate/3, nkmedia_room_tick/3, nkmedia_room_handle_cast/3]).
-export([janus_check/3, janus_event/2]).

-define(LLOG(Type, Txt, Args, Room),
    lager:Type("NkMEDIA Room ~s (~p) "++Txt, 
               [maps:get(room_id, Room), maps:get(class, Room) | Args])).


%% ===================================================================
%% Types
%% ===================================================================


-type room_id() :: nkmedia_room:id().

-type state() ::
    #{
        janus_id => nkmedia_janus:id()
    }.



%% ===================================================================
%% External
%% ===================================================================

%% @private Called from nkmedia_janus_op when new subscribers or listeners 
%% are added or removed
-spec janus_event(nkmedia_room:id(), nkmedia_room:update()) ->
    {ok, pid()} | {error, term()}.

janus_event(RoomId, Event) ->
    nkmedia_room:update(RoomId, Event).


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
                    destroy_room(JanusId, RoomId)
                end)
    end.




%% ===================================================================
%% Callbacks
%% ===================================================================

%% @doc Creates a new room
-spec init(nkmedia_room:id(), nkmedia_room:room()) ->
    {ok, state()} | {error, term()}.

init(RoomId, #{srv_id:=SrvId}=Config) ->
    case get_janus(SrvId, Config) of
        {ok, JanusId} ->
            Audio = maps:get(audio_codec, Config,
                        maps:get(room_audio_codec, Config, opus)),
            Video = maps:get(video_codec, Config,
                        maps:get(room_video_codec, Config, vp8)),
            Bitrate = maps:get(bitrate, Config,
                        maps:get(room_bitrate, Config, 0)),
            Create = #{        
                audiocodec => Audio,
                videocodec => Video,
                bitrate => Bitrate
            },
            case create_room(JanusId, RoomId, Create) of
                ok ->
                    {ok, #{janus_id=>JanusId}};
                {error, Error} ->
                    {error, Error}
            end;
        error ->
            {error, mediaserver_not_available}
    end.


%% @doc
-spec terminate(term(), state(), nkmedia_room:room()) ->
    ok | {error, term()}.

terminate(_Reason, #{room_id:=Id}=Room, #{janus_id:=JanusId}=State) ->
    case destroy_room(JanusId, Id) of
        ok ->
            ?LLOG(info, "stopping, destroying room", [], Room);
        {error, Error} ->
            ?LLOG(warning, "could not destroy room: ~p: ~p", [Id, Error], Room)
    end,
    {ok, State}.


%% @private
nkmedia_room_tick(Id, Room, #{janus_id:=JanusId}=State) ->
    #{publishers:=Publish} = Room,
    case map_size(Publish) of
        0 ->
            nkmedia_room:stop(self(), timeout);
        _ ->
           case nkmedia_janus_engine:check_room(JanusId, Id) of
                {ok, _} ->      
                    ok;
                _ ->
                    ?LLOG(warning, "room is not on engine ~p ~p", [JanusId, Id], Room),
                    nkmedia_room:stop(self(), timeout)
            end
    end,
    {ok, State}.


%% @private
nkmedia_room_handle_cast({participants, Num}, Room, State) ->
    #{publishers:=Publish} = Room,
    case map_size(Publish) of
        Num -> 
            ok;
        Other ->
            ?LLOG(notice, "Janus says ~p participants, we have ~p!", 
                  [Num, Other], Room),
            case Num of
                0 ->
                    nkmedia_room:stop(self(), no_participants);
                _ ->
                    ok
            end
    end,
    {noreply, State}.


% ===================================================================
%% Internal
%% ===================================================================

-spec create_room(nkmedia_janus:id(), room_id(), map()) ->
    ok | {error, term()}.

create_room(JanusId, RoomId, Opts) ->
    case nkmedia_janus_op:start(JanusId, RoomId) of
        {ok, Pid} ->
            nkmedia_janus_op:create_room(Pid, RoomId, Opts);
        {error, Error} ->
            {error, Error}
    end.


-spec destroy_room(nkmedia_janus:id(), room_id()) ->
    ok | {error, term()}.

destroy_room(JanusId, RoomId) ->
    case nkmedia_janus_op:start(JanusId, RoomId) of
        {ok, Pid} ->
            nkmedia_janus_op:destroy_room(Pid, RoomId);
        {error, Error} ->
            {error, Error}
    end.





%% @private
get_janus(_SrvId, #{janus_id:=JanusId}) ->
    {ok, JanusId};

get_janus(SrvId, _Config) ->
    case SrvId:nkmedia_janus_get_mediaserver(SrvId) of
        {ok, JanusId} ->
            {ok, JanusId};
        {error, _Error} ->
            error
    end.



% %% @private
% send_event(Type, Body, #state{srv_id=SrvId, id=Id, room=Room}) ->
%     RegId = #reg_id{
%         srv_id = SrvId,     
%         class = <<"media">>, 
%         subclass = <<"room">>,
%         type = Type,
%         obj_id = Id
%     },
%     nkservice_events:send(RegId, Body),
%     #{publish:=Publish, listen:=Listen} = Room,
%     Body2 = Body#{type=>Type, room=>Id},
%     lists:foreach(
%         fun(SessId) -> nkmedia_session:send_ext_event(SessId, room, Body2) end,
%         Publish ++ maps:keys(Listen)).




