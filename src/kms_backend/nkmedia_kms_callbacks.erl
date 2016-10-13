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
-export([nkmedia_conf_init/2, nkmedia_conf_terminate/2, nkmedia_conf_tick/2]).
-export([nkmedia_call_start_caller_session/3, nkmedia_call_start_callee_session/4,
         nkmedia_call_set_answer/5]).
-export([api_cmd/2, api_syntax/4]).
-export([nkdocker_notify/2]).

-include_lib("nkservice/include/nkservice.hrl").
-include("../../include/nkmedia_conf.hrl").
-include("../../include/nkmedia_call.hrl").


%% ===================================================================
%% Types
%% ===================================================================




%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia, nkmedia_conf].


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
error_code({kms_error, Code, Txt})->  {303001, {"Kurento error ~p: ~s", [Code, Txt]}};
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
%% Implemented Callbacks - nkmedia_conf
%% ===================================================================

%% @private
nkmedia_conf_init(Id, Conf) ->
    case maps:get(backend, Conf, nkmedia_kms) of
        nkmedia_kms ->
            case maps:get(class, Conf, sfu) of
                sfu ->
                    nkmedia_kms_conf:init(Id, Conf);
                _ ->
                    {ok, Conf}
            end;
        _ ->
            {ok, Conf}
    end.


%% @private
nkmedia_conf_terminate(Reason, #{nkmedia_kms_id:=_}=Conf) ->
    nkmedia_kms_conf:terminate(Reason, Conf);

nkmedia_conf_terminate(_Reason, Conf) ->
    {ok, Conf}.


%% @private
nkmedia_conf_tick(ConfId, #{nkmedia_kms_id:=_}=Conf) ->
    nkmedia_kms_conf:tick(ConfId, Conf);

nkmedia_conf_tick(_ConfId, _Conf) ->
    continue.


% %% @private
% nkmedia_conf_handle_cast({nkmedia_kms, Msg}, Conf) ->
%     nkmedia_kms_conf:handle_cast(Msg, Conf);

% nkmedia_conf_handle_cast(_Msg, _Conf) ->
%     continue.



%% ===================================================================
%% Implemented Callbacks - nkmedia_call
%% ===================================================================


nkmedia_call_start_caller_session(CallId, Config, #{srv_id:=SrvId, offer:=Offer}=Call) ->
    case maps:get(backend, Call, nkmedia_kms) of
        nkmedia_kms ->
            Config2 = Config#{
                backend => nkmedia_kms, 
                offer => Offer,
                call_id => CallId
            },
            {ok, MasterId, Pid} = nkmedia_session:start(SrvId, park, Config2),
            {ok, MasterId, Pid, ?CALL(#{backend=>nkmedia_kms}, Call)};
        _ ->
            continue
    end.

nkmedia_call_start_callee_session(CallId, _MasterId, Config, 
                                  #{backend:=nkmedia_kms, srv_id:=SrvId}=Call) ->
    Config2 = Config#{
        backend => nkmedia_kms,
        call_id => CallId
    },
    {ok, SlaveId, Pid} = nkmedia_session:start(SrvId, park, Config2),
    case nkmedia_session:get_offer(SlaveId) of
        {ok, Offer} ->
            {ok, SlaveId, Pid, Offer, Call};
        {error, Error} ->
            {error, Error, Call}
    end;

nkmedia_call_start_callee_session(_CallId, _MasterId, _Config, _Call) ->
    continue.


nkmedia_call_set_answer(_CallId, MasterId, SlaveId, Answer, 
                        #{backend:=nkmedia_kms}=Call) ->
    case nkmedia_session:set_answer(SlaveId, Answer) of
        ok ->
            Opts = #{type=>bridge, peer_id=>MasterId},
            case nkmedia_session:cmd(SlaveId, set_type, Opts) of
                {ok, _} ->
                    {ok, Call};
                {error, Error} ->
                    {error, Error, Call}
            end;
        {error, Error} ->
            {error, Error, Call}
    end;

nkmedia_call_set_answer(_CallId, _MasterId, _SlaveId, _Answer, _Call) ->
    continue.


%% ===================================================================
%% API
%% ===================================================================

%% @private
api_cmd(#api_req{class = <<"media">>}=Req, State) ->
    #api_req{subclass=Sub, cmd=Cmd} = Req,
    nkmedia_kms_api:cmd(Sub, Cmd, Req, State);

api_cmd(_Req, _State) ->
    continue.


%% @private
api_syntax(#api_req{class = <<"media">>}=Req, Syntax, Defaults, Mandatory) ->
    #api_req{subclass=Sub, cmd=Cmd} = Req,
    {S2, D2, M2} = nkmedia_kms_api_syntax:syntax(Sub, Cmd, Syntax, Defaults, Mandatory),
    {continue, [Req, S2, D2, M2]};

api_syntax(_Req, _Syntax, _Defaults, _Mandatory) ->
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
