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

-export([plugin_deps/0, plugin_group/0, plugin_syntax/0, plugin_config/2,
         plugin_start/2, plugin_stop/2]).
-export([error_code/1]).
-export([nkmedia_fs_get_mediaserver/1]).
-export([nkmedia_session_start/2, nkmedia_session_answer/3,
         nkmedia_session_update/3, nkmedia_session_stop/2,
         nkmedia_session_client_trickle_ready/2,
         nkmedia_session_handle_call/3, nkmedia_session_handle_cast/2]).
-export([api_syntax/4]).
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


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA Freeswitch (~s) starting", [Name]),
    case nkdocker_monitor:register(?MODULE) of
        {ok, DockerMonId} ->
            nkmedia_app:put(docker_fs_mon_id, DockerMonId),
            lager:info("Installed images: ~s", 
                [nklib_util:bjoin(find_images(DockerMonId))]);
        {error, Error} ->
            lager:error("Could not start Docker Monitor: ~p", [Error]),
            erlang:error(docker_monitor)
    end,
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA Freeswitch (~p) stopping", [Name]),
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

%% @private Error Codes -> 23XX range
error_code(fs_error)             ->  {2300, <<"Freeswitch internal error">>};
error_code(fs_get_answer_error)  ->  {2301, <<"Freeswitch get answer error">>};
error_code(fs_get_offer_error)   ->  {2302, <<"Freeswitch get offer error">>};
error_code(fs_channel_stop)      ->  {2303, <<"Freeswitch channel stop">>};
error_code(fs_transfer_error)    ->  {2304, <<"Freeswitch transfer error">>};
error_code(fs_bridge_error)      ->  {2305, <<"Freeswitch bridge error">>};
error_code(_)                    ->  continue.


%% ===================================================================
%% Implemented Callbacks - nkmedia_session
%% ===================================================================


%% @private
nkmedia_session_start(Type, Session) ->
    case maps:get(backend, Session, nkmedia_fs) of
        nkmedia_fs ->
            nkmedia_fs_session:start(Type, Session);
        _ ->
            continue
    end.


%% @private
nkmedia_session_answer(Type, Answer, #{backend:=nkmedia_fs}=Session) ->
    nkmedia_fs_session:answer(Type, Answer, Session);

nkmedia_session_answer(_Type, _Answer, _Session) ->
    continue.


%% @private
nkmedia_session_update(Update, Opts, #{backend:=nkmedia_fs}=Session) ->
   nkmedia_fs_session:update(Update, Opts, Session);

nkmedia_session_update(_Update, _Opts, _Session) ->
    continue.


%% @private
nkmedia_session_client_trickle_ready(Candidates, #{backend:=nkmedia_fs}=Session) ->
    nkmedia_fs_session:client_trickle_ready(Candidates, Session);

nkmedia_session_client_trickle_ready(_Candidates, _Session) ->
    continue.


%% @private
nkmedia_session_stop(Reason, #{backend:=nkmedia_fs}=Session) ->
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
%% API
%% ===================================================================

%% @private
api_syntax(#api_req{class = <<"media">>}=Req, Syntax, Defaults, Mandatory) ->
    #api_req{subclass=Sub, cmd=Cmd} = Req,
    {S2, D2, M2} = syntax(Sub, Cmd, Syntax, Defaults, Mandatory),
    {continue, [Req, S2, D2, M2]};

api_syntax(_Req, _Syntax, _Defaults, _Mandatory) ->
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
syntax(<<"session">>, <<"start">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            room_id => binary,
            mcu_layout => binary,
            park_after_bridge => boolean
        },
        Defaults,
        Mandatory
    };

syntax(<<"session">>, <<"update">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            type => atom,
            session_type => atom,
            room_id => binary,
            mcu_layout => binary
        },
        Defaults,
        Mandatory
    };

syntax(_Sub, _Cmd, Syntax, Defaults, Mandatory) ->
    {Syntax, Defaults, Mandatory}.



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
