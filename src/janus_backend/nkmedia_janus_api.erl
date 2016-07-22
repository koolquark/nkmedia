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

%% @doc NkMEDIA external API

-module(nkmedia_janus_api).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([cmd/4, syntax/5]).


-include_lib("nkservice/include/nkservice.hrl").
-include("../../include/nkmedia.hrl").


%% ===================================================================
%% Types
%% ===================================================================


%% ===================================================================
%% Commands
%% ===================================================================

%% @doc
-spec cmd(binary(), binary(), #api_req{}, State::map()) ->
    {ok, map(), State::map()} | {error, nkservice:error(), State::map()}.

cmd(<<"room">>, <<"create">>, #api_req{srv_id=SrvId, data=Data}, State) ->
    case nkmedia_janus_room:create(SrvId, Data) of
        {ok, Id, _Pid} ->
            {ok, #{id=>Id}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"room">>, <<"destroy">>, #api_req{data=#{id:=Id}}, State) ->
    case nkmedia_janus_room:destroy(Id) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"room">>, <<"list">>, _Req, State) ->
    Ids = [Id || {Id, _Eng, _Pid} <- nkmedia_janus_room:get_all()],
    {ok, #{ids=>Ids}, State};

cmd(<<"room">>, <<"info">>, #api_req{data=#{id:=Id}}, State) ->
    case nkmedia_janus_room:get_room(Id) of
        {ok, Room} ->
            List = [room_audio_codec, room_video_codec, room_bitrate,
                    publish, listen],
            Data = maps:with(List, Room),
            {ok, Data, State};

        {error, Error} ->
            {error, Error, State}
    end;

cmd(_Sub, _Cmd, _Data, _State) ->
    continue.


%% ===================================================================
%% Syntax
%% ===================================================================



%% @private
syntax(<<"session">>, <<"start">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            record => boolean,
            bitrate => {integer, 0, none},
            proxy_type => {enum, [webrtc, rtp]},
            room => binary,
            publisher => binary,
            use_audio => boolean,
            use_video => boolean,
            use_data => boolean,
            room_bitrate => {integer, 0, none},
            room_audio_codec => {enum, [opus, isac32, isac16, pcmu, pcma]},
            room_video_codec => {enum , [vp8, vp9, h264]}
        },
        Defaults,
        Mandatory
    };

syntax(<<"session">>, <<"update">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            bitrate => integer,
            use_audio => boolean,
            use_video => boolean,
            use_data => boolean,
            record => boolean,
            publisher => binary
        },
        Defaults,
        Mandatory
    };

syntax(<<"room">>, <<"create">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            id => binary,
            room_backend => atom,
            room_bitrate => {integer, 0, none},
            room_audio_codec => {enum, [opus, isac32, isac16, pcmu, pcma]},
            room_video_codec => {enum , [vp8, vp9, h264]}
        },
        Defaults,
        Mandatory
    };

syntax(<<"room">>, <<"destroy">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{id => binary},
        Defaults,
        [id|Mandatory]
    };

syntax(<<"room">>, <<"list">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{service => fun nkservice_api:parse_service/1},
        Defaults, 
        Mandatory
    };

syntax(<<"room">>, <<"info">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{id => binary},
        Defaults, 
        [id|Mandatory]
    };

syntax(_Sub, _Cmd, Syntax, Defaults, Mandatory) ->
    {Syntax, Defaults, Mandatory}.
