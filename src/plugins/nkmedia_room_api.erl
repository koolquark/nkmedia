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

%% @doc Room Plugin API
-module(nkmedia_room_api).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([cmd/4, syntax/5, event/3]).

-include_lib("nkservice/include/nkservice.hrl").


%% ===================================================================
%% Commands
%% ===================================================================


cmd(<<"room">>, <<"create">>, #api_req{srv_id=SrvId, data=Data}, State) ->
    case nkmedia_room:start(SrvId, Data) of
        {ok, Id, _Pid} ->
            {ok, #{room_id=>Id}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"room">>, <<"destroy">>, #api_req{data=#{room_id:=Id}}, State) ->
    case nkmedia_room:stop(Id, user_stop) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"room">>, <<"list">>, _Req, State) ->
    Ids = [#{room_id=>Id, class=>Class} || {Id, Class, _Pid} <- nkmedia_room:get_all()],
    {ok, Ids, State};

cmd(<<"room">>, <<"info">>, #api_req{data=#{room_id:=RoomId}}, State) ->
    case nkmedia_room:get_room(RoomId) of
        {ok, Room} ->
            Keys = [audio_codec, video_codec, bitrate, class, backend, 
                    publishers, listeners],
            {ok, maps:with(Keys, Room), State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(_SrvId, _Other, _Data, State) ->
    {error, unknown_command, State}.



%% ===================================================================
%% Commands
%% ===================================================================

syntax(<<"room">>, <<"create">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            class => atom,
            room_id => binary,
            backend => atom,
            bitrate => {integer, 0, none},
            audio_codec => {enum, [opus, isac32, isac16, pcmu, pcma]},
            video_codec => {enum , [vp8, vp9, h264]}
        },
        Defaults,
        [class|Mandatory]
    };

syntax(<<"room">>, <<"destroy">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{room_id => binary},
        Defaults,
        [room_id|Mandatory]
    };

syntax(<<"room">>, <<"list">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{service => fun nkservice_api:parse_service/1},
        Defaults, 
        Mandatory
    };

syntax(<<"room">>, <<"info">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{room_id => binary},
        Defaults, 
        [room_id|Mandatory]
    };

syntax(_Sub, _Cmd, Syntax, Defaults, Mandatory) ->
    {Syntax, Defaults, Mandatory}.



%% ===================================================================
%% Events
%% ===================================================================


%% @private
-spec event(nkmedia_room:id(), nkmedia_room:event(), nkmedia_room:room()) ->
    {ok, nkmedia_room:room()}.

event(RoomId, started, Room) ->
    Data = maps:with([audio_codec, video_codec, bitrate, class, backend], Room),
    send_event(RoomId, started, Data, Room);

event(RoomId, {stopped, Reason}, #{srv_id:=SrvId}=Room) ->
    {Code, Txt} = SrvId:error_code(Reason),
    send_event(RoomId, destroyed, #{code=>Code, reason=>Txt}, Room);

event(RoomId, {started_member, SessId, #{role:=publisher}=Info}, Room) ->
    UserId = maps:get(user_id, Info, <<>>),
    send_event(RoomId, started_publisher, #{session_id=>SessId, user=>UserId}, Room);

event(RoomId, {started_member, SessId, #{role:=listener}=Info}, Room) ->
    UserId = maps:get(user_id, Info, <<>>),
    PeerId = maps:get(peer_id, Info, <<>>),
    Data = #{session_id=>SessId, user=>UserId, peer_id=>PeerId},
    send_event(RoomId, started_listener, Data, Room);

event(RoomId, {stopped_member, SessId, #{role:=publisher}=Info}, Room) ->
    User = maps:get(user_id, Info, <<>>),
    send_event(RoomId, stopped_publisher, #{session_id=>SessId, user=>User}, Room);

event(RoomId, {stopped_member, SessId, #{role:=listener}=Info}, Room) ->
    UserId = maps:get(user_id, Info, <<>>),
    PeerId = maps:get(peer_id, Info, <<>>),
    Data = #{session_id=>SessId, user=>UserId, peer_id=>PeerId},
    send_event(RoomId, stopped_listener, Data, Room);

event(_RoomId, _Event, Room) ->
    {ok, Room}.


%% @private
send_event(RoomId, Type, Body, #{srv_id:=SrvId}=Room) ->
    nkmedia_events:send_event(SrvId, room, RoomId, Type, Body),
    {ok, Room}.



