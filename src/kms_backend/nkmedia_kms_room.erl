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

-export([init/2, terminate/3, nkmedia_room_tick/3]).

-define(LLOG(Type, Txt, Args, Room),
    lager:Type("NkMEDIA Room ~s (~p) "++Txt, 
               [maps:get(room_id, Room), maps:get(class, Room) | Args])).


%% ===================================================================
%% Types
%% ===================================================================

-type state() ::
    #{
        kms_id => nkmedia_kms:id()
    }.



%% ===================================================================
%% External
%% ===================================================================




%% ===================================================================
%% Callbacks
%% ===================================================================

%% @doc Creates a new room
-spec init(nkmedia_room:id(), nkmedia_room:room()) ->
    {ok, state()} | {error, term()}.

init(_Id, #{srv_id:=SrvId}=Config) ->
    case get_kms(SrvId, Config) of
        {ok, KmsId} ->
            {ok, #{kms_id=>KmsId}};
        error ->
            {error, mediaserver_not_available}
    end.


%% @doc
-spec terminate(term(), state(), nkmedia_room:room()) ->
    ok | {error, term()}.

terminate(_Reason, Room, State) ->
    ?LLOG(info, "stopping, destroying room", [], Room),
    {ok, State}.


%% @private
nkmedia_room_tick(_Id, Room, State) ->
    #{publishers:=Publish} = Room,
    case map_size(Publish) of
        0 ->
            nkmedia_room:stop(self(), timeout);
        _ ->
            ok
    end,
    {ok, State}.


%% @private
% nkmedia_room_handle_cast({participants, Num}, Room, State) ->


% ===================================================================
%% Internal
%% ===================================================================

%% @private
get_kms(_SrvId, #{nkmedia_kms:=KmsId}=Room) ->
    ?LLOG(notice, "using provided engine: ~s", [KmsId], Room),
    {ok, KmsId};

get_kms(SrvId, _Config) ->
    case SrvId:nkmedia_kms_get_mediaserver(SrvId) of
        {ok, KmsId} ->
            {ok, KmsId};
        {error, _Error} ->
            error
    end.
