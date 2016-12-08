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

%% @doc Plugin implementig the Freeswitch backend
-module(nkmedia_fs_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_group/0, plugin_syntax/0, plugin_config/2, plugin_stop/2]).
-export([error_code/1]).
-export([service_init/2]).
-export([nkmedia_fs_get_mediaserver/1]).
-export([nkmedia_session_start/3, nkmedia_session_stop/2,
         nkmedia_session_offer/4, nkmedia_session_answer/4, nkmedia_session_cmd/3, 
         nkmedia_session_handle_call/3, nkmedia_session_handle_cast/2]).
-export([api_server_syntax/4]).
-export([nkdocker_notify/2]).

-include_lib("nkservice/include/nkservice.hrl").



%% ===================================================================
%% Types
%% ===================================================================

% -type continue() :: continue | {continue, list()}.



%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia].


plugin_group() ->
    nkmedia_backends.


plugin_syntax() ->
    #{
        fs_docker_image => fun parse_image/3
    }.


plugin_config(Config, _Service) ->
    Cache = case Config of
        #{fs_docker_image:=FsConfig} -> FsConfig;
        _ -> nkmedia_fs_build:defaults(#{})
    end,
    {ok, Config, Cache}.


plugin_stop(Config, _Service) ->
    nkdocker_monitor:unregister(?MODULE),
    {ok, Config}.



%% ===================================================================
%% Offering Callbacks
%% ===================================================================


%% @private
-spec nkmedia_fs_get_mediaserver(nkservice:id()) ->
    {ok, nkmedia_fs_engine:id()} | {error, term()}.

nkmedia_fs_get_mediaserver(SrvId) ->
    case nkmedia_fs_engine:get_all(SrvId) of
        [{FsId, _}|_] ->
            {ok, FsId};
        [] ->
            {error, no_mediaserver}
    end.




%% ===================================================================
%% Implemented Callbacks - error
%% ===================================================================

%% @private See nkservice_callbacks
error_code({fs_error, Error})    ->  {302001, "Freeswitch error: ~s", [Error]};
error_code(fs_invite_error)      ->  {302002, "Freeswitch invite error"};
error_code(fs_get_answer_error)  ->  {302003, "Freeswitch get answer error"};
error_code(fs_get_offer_error)   ->  {302004, "Freeswitch get offer error"};
error_code(fs_channel_parked)    ->  {302005, "Freeswitch channel parked"};
error_code(fs_channel_stop)      ->  {302006, "Freeswitch channel stop"};
error_code(fs_transfer_error)    ->  {302007, "Freeswitch transfer error"};
error_code(fs_bridge_error)      ->  {302008, "Freeswitch bridge error"};
error_code(_)                    ->  continue.


%% ===================================================================
%% Implemented Callbacks - nkservice
%% ===================================================================

service_init(_Service, State) ->
    case nkdocker_monitor:register(?MODULE) of
        {ok, DockerMonId} ->
            nkmedia_app:put(docker_fs_mon_id, DockerMonId),
            lager:info("NkMEDIA FS installed images: ~s", 
                [nklib_util:bjoin(find_images(DockerMonId))]);
        {error, Error} ->
            lager:error("Could not start Docker Monitor: ~p", [Error]),
            erlang:error(docker_monitor)
    end,
    {ok, State}.




%% ===================================================================
%% Implemented Callbacks - nkmedia_session
%% ===================================================================


%% @private
nkmedia_session_start(Type, Role, Session) ->
    case maps:get(backend, Session, nkmedia_fs) of
        nkmedia_fs ->
            nkmedia_fs_session:start(Type, Role, Session);
        _ ->
            continue
    end.


%% @private
nkmedia_session_offer(Type, Role, Offer, #{nkmedia_fs_id:=_}=Session) ->
    nkmedia_fs_session:offer(Type, Role, Offer, Session);

nkmedia_session_offer(_Type, _Role, _Offer, _Session) ->
    continue.


%% @private
nkmedia_session_answer(Type, Role, Answer, #{nkmedia_fs_id:=_}=Session) ->
    nkmedia_fs_session:answer(Type, Role, Answer, Session);

nkmedia_session_answer(_Type, _Role, _Answer, _Session) ->
    continue.


%% @private
nkmedia_session_cmd(Update, Opts, #{nkmedia_fs_id:=_}=Session) ->
   nkmedia_fs_session:cmd(Update, Opts, Session);

nkmedia_session_cmd(_Update, _Opts, _Session) ->
    continue.


%% @private
nkmedia_session_stop(Reason, #{nkmedia_fs_id:=_}=Session) ->
    nkmedia_fs_session:stop(Reason, Session);

nkmedia_session_stop(_Reason, _Session) ->
    continue.


%% @private
nkmedia_session_handle_call({nkmedia_fs, Msg}, From, Session) ->
    nkmedia_fs_session:handle_call(Msg, From, Session);

nkmedia_session_handle_call(_Msg, _From, _Session) ->
    continue.


%% @private
nkmedia_session_handle_cast({nkmedia_fs, Msg}, Session) ->
    nkmedia_fs_session:handle_cast(Msg, Session);

nkmedia_session_handle_cast(_Msg, _Session) ->
    continue.


%% ===================================================================
%% API Server
%% ===================================================================

%% @private
api_server_syntax(#api_req{class=media}=Req, Syntax, Defaults, Mandatory) ->
    #api_req{subclass=Sub, cmd=Cmd} = Req,
    {S2, D2, M2} = nkmedia_fs_api_syntax:syntax(Sub, Cmd, Syntax, Defaults, Mandatory),
    {continue, [Req, S2, D2, M2]};

api_server_syntax(_Req, _Syntax, _Defaults, _Mandatory) ->
    continue.


%% ===================================================================
%% Docker Monitor Callbacks
%% ===================================================================

nkdocker_notify(MonId, {Op, {<<"nk_fs_", _/binary>>=Name, Data}}) ->
    nkmedia_fs_docker:notify(MonId, Op, Name, Data);

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
        [Comp, <<"nk_freeswitch:", Tag/binary>>] -> 
            [Vsn, Rel] = binary:split(Tag, <<"-">>),
            Def = #{comp=>Comp, vsn=>Vsn, rel=>Rel},
            {ok, nkmedia_fs_build:defaults(Def)};
        _ ->
            error
    end.


%% @private
find_images(MonId) ->
    {ok, Docker} = nkdocker_monitor:get_docker(MonId),
    {ok, Images} = nkdocker:images(Docker),
    Tags = lists:flatten([T || #{<<"RepoTags">>:=T} <- Images]),
    lists:filter(
        fun(Img) -> length(binary:split(Img, <<"/nk_freeswitch_">>))==2 end, Tags).
