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

%% @doc Plugin implementig the Kurento backend
-module(nkmedia_kms_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_group/0, plugin_syntax/0, plugin_config/2,
         plugin_start/2, plugin_stop/2]).
-export([nkmedia_kms_get_mediaserver/1]).
-export([error_code/1]).
-export([nkmedia_session_start/3, nkmedia_session_stop/2,
         nkmedia_session_offer/4, nkmedia_session_answer/4, nkmedia_session_cmd/3, 
         nkmedia_session_candidate/2,
         nkmedia_session_handle_call/3, nkmedia_session_handle_cast/2]).
-export([nkmedia_room_init/2, nkmedia_room_terminate/2, nkmedia_room_timeout/2]).
-export([api_server_cmd/2, api_server_syntax/4]).
-export([nkdocker_notify/2]).

-include_lib("nkservice/include/nkservice.hrl").
-include("../../include/nkmedia_room.hrl").


%% ===================================================================
%% Types
%% ===================================================================




%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia, nkmedia_room].


plugin_group() ->
    nkmedia_backends.


plugin_syntax() ->
    #{
        kms_docker_image => fun parse_image/3
    }.


plugin_config(Config, _Service) ->
    Cache = case Config of
        #{kms_docker_image:=KmsConfig} -> KmsConfig;
        _ -> nkmedia_kms_build:defaults(#{})
    end,
    {ok, Config, Cache}.


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA Kurento (~s) starting", [Name]),
    case nkdocker_monitor:register(?MODULE) of
        {ok, DockerMonId} ->
            nkmedia_app:put(docker_kms_mon_id, DockerMonId),
            lager:info("Installed images: ~s", 
                [nklib_util:bjoin(find_images(DockerMonId))]);
        {error, Error} ->
            lager:error("Could not start Docker Monitor: ~p", [Error]),
            error(docker_monitor)
    end,
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA Kurento (~p) stopping", [Name]),
    nkdocker_monitor:unregister(?MODULE),
    {ok, Config}.



%% ===================================================================
%% Offering Callbacks
%% ===================================================================


%% @private
-spec nkmedia_kms_get_mediaserver(nkservice:id()) ->
    {ok, nkmedia_kms_engine:id()} | {error, term()}.

nkmedia_kms_get_mediaserver(SrvId) ->
    case nkmedia_kms_engine:get_all(SrvId) of
        [{KmsId, _}|_] ->
            {ok, KmsId};
        [] ->
            {error, no_mediaserver}
    end.


%% ===================================================================
%% Implemented Callbacks - error
%% ===================================================================

%% @private See nkservice_callbacks
error_code({kms_error, Code, Txt})->  {303001, "Kurento error ~p: ~s", [Code, Txt]};
error_code(_) -> continue.


%% ===================================================================
%% Implemented Callbacks - nkmedia_session
%% ===================================================================

%% @private
nkmedia_session_start(Type, Role, Session) ->
    case maps:get(backend, Session, nkmedia_kms) of
        nkmedia_kms ->
            nkmedia_kms_session:start(Type, Role, Session);
        _ ->
            continue
    end.


%% @private
nkmedia_session_offer(Type, Role, Offer, #{nkmedia_kms_id:=_}=Session) ->
    nkmedia_kms_session:offer(Type, Role, Offer, Session);

nkmedia_session_offer(_Type, _Role, _Offer, _Session) ->
    continue.


%% @private
nkmedia_session_answer(Type, Role, Answer, #{nkmedia_kms_id:=_}=Session) ->
    nkmedia_kms_session:answer(Type, Role, Answer, Session);

nkmedia_session_answer(_Type, _Role, _Answer, _Session) ->
    continue.


%% @private
nkmedia_session_cmd(Cmd, Opts, #{nkmedia_kms_id:=_}=Session) ->
   nkmedia_kms_session:cmd(Cmd, Opts, Session);

nkmedia_session_cmd(_Cmd, _Opts, _Session) ->
    continue.


%% @private
nkmedia_session_candidate(Candidate, #{nkmedia_kms_id:=_}=Session) ->
    nkmedia_kms_session:candidate(Candidate, Session);

nkmedia_session_candidate(_Candidate, _Session) ->
    continue.


%% @private
nkmedia_session_stop(Reason, #{nkmedia_kms_id:=_}=Session) ->
    nkmedia_kms_session:stop(Reason, Session);

nkmedia_session_stop(_Reason, _Session) ->
    continue.


%% @private
nkmedia_session_handle_call({nkmedia_kms, Msg}, From, Session) ->
    nkmedia_kms_session:handle_call(Msg, From, Session);

nkmedia_session_handle_call(_Msg, _From, _Session) ->
    continue.


%% @private
nkmedia_session_handle_cast({nkmedia_kms, Msg}, Session) ->
    nkmedia_kms_session:handle_cast(Msg, Session);

nkmedia_session_handle_cast(_Msg, _Session) ->
    continue.



%% ===================================================================
%% Implemented Callbacks - nkmedia_room
%% ===================================================================

%% @private
nkmedia_room_init(Id, Room) ->
    case maps:get(backend, Room, nkmedia_kms) of
        nkmedia_kms ->
            case maps:get(class, Room, sfu) of
                sfu ->
                    nkmedia_kms_room:init(Id, Room);
                _ ->
                    {ok, Room}
            end;
        _ ->
            {ok, Room}
    end.


%% @private
nkmedia_room_terminate(Reason, #{nkmedia_kms_id:=_}=Room) ->
    nkmedia_kms_room:terminate(Reason, Room);

nkmedia_room_terminate(_Reason, Room) ->
    {ok, Room}.


%% @private
nkmedia_room_timeout(RoomId, #{nkmedia_kms_id:=_}=Room) ->
    nkmedia_kms_room:timeout(RoomId, Room);

nkmedia_room_timeout(_RoomId, _Room) ->
    continue.


% %% @private
% nkmedia_room_handle_cast({nkmedia_kms, Msg}, Room) ->
%     nkmedia_kms_room:handle_cast(Msg, Room);

% nkmedia_room_handle_cast(_Msg, _Room) ->
%     continue.




%% ===================================================================
%% API
%% ===================================================================

%% @private
api_server_cmd(#api_req{class=media, subclass=Sub, cmd=Cmd}=Req, State) ->
    nkmedia_kms_api:cmd(Sub, Cmd, Req, State);

api_server_cmd(_Req, _State) ->
    continue.


%% @private
api_server_syntax(#api_req{class=media}=Req, Syntax, Defaults, Mandatory) ->
    #api_req{subclass=Sub, cmd=Cmd} = Req,
    {S2, D2, M2} = nkmedia_kms_api_syntax:syntax(Sub, Cmd, Syntax, Defaults, Mandatory),
    {continue, [Req, S2, D2, M2]};

api_server_syntax(_Req, _Syntax, _Defaults, _Mandatory) ->
    continue.



%% ===================================================================
%% Docker Monitor Callbacks
%% ===================================================================

nkdocker_notify(MonId, {Op, {<<"nk_kms_", _/binary>>=Name, Data}}) ->
    nkmedia_kms_docker:notify(MonId, Op, Name, Data);

nkdocker_notify(_MonId, _Op) ->
    ok.



%% ===================================================================
%% Internal
%% ===================================================================



%% @private
parse_image(_Key, Map, _Ctx) when is_map(Map) ->
    {ok, Map};

parse_image(_, Image, _Ctx) ->
    case binary:split(Image, <<"/">>) of
        [Comp, <<"nk_kms:", Tag/binary>>] -> 
            [Vsn, Rel] = binary:split(Tag, <<"-">>),
            Def = #{comp=>Comp, vsn=>Vsn, rel=>Rel},
            {ok, nkmedia_kms_build:defaults(Def)};
        _ ->
            error
    end.


%% @private
find_images(MonId) ->
    {ok, Docker} = nkdocker_monitor:get_docker(MonId),
    {ok, Images} = nkdocker:images(Docker),
    Tags = lists:flatten([T || #{<<"RepoTags">>:=T} <- Images]),
    lists:filter(
        fun(Img) -> length(binary:split(Img, <<"/nk_kurento_">>))==2 end, Tags).
