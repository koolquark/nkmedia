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

-export([cmd/3]).

-include_lib("nkservice/include/nkservice.hrl").


%% ===================================================================
%% Commands
%% ===================================================================


cmd(<<"create">>, #api_req{srv_id=SrvId, data=Data}, State) ->
    case nkmedia_room:start(SrvId, Data) of
        {ok, Id, _Pid} ->
            {ok, #{room_id=>Id}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"destroy">>, #api_req{data=#{room_id:=Id}}, State) ->
    case nkmedia_room:stop(Id, api_stop) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"get_list">>, _Req, State) ->
    Ids = [#{room_id=>Id, class=>Class} || {Id, Class, _Pid} <- nkmedia_room:get_all()],
    {ok, Ids, State};

cmd(<<"get_info">>, #api_req{data=#{room_id:=RoomId}}, State) ->
    case nkmedia_room:get_info(RoomId) of
        {ok, Info} ->
            {ok, Info, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(_Cmd, _Data, _State) ->
    continue.

