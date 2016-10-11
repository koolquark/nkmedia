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

%% @doc Plugin implementig the Janus backend
-module(nkmedia_janus_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_group/0, plugin_syntax/0, plugin_config/2,
         plugin_start/2, plugin_stop/2]).
-export([error_code/1]).
-export([nkmedia_janus_get_mediaserver/1]).
-export([nkmedia_session_start/3, nkmedia_session_stop/2,
         nkmedia_session_offer/4, nkmedia_session_answer/4,
         nkmedia_session_candidate/2,
         nkmedia_session_cmd/3,
         nkmedia_session_handle_call/3, nkmedia_session_handle_cast/2, 
         nkmedia_session_handle_info/2]).
-export([nkmedia_room_init/2, nkmedia_room_terminate/2, nkmedia_room_tick/2,
         nkmedia_room_handle_cast/2]).
-export([nkmedia_call_start_caller_session/3, nkmedia_call_start_callee_session/4,
         nkmedia_call_set_answer/5]).


-export([api_syntax/4]).
-export([nkdocker_notify/2]).

-include_lib("nkservice/include/nkservice.hrl").
-include("../../include/nkmedia.hrl").
-include("../../include/nkmedia_call.hrl").


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
        janus_docker_image => fun parse_image/3
    }.


plugin_config(Config, _Service) ->
    Cache = case Config of
        #{janus_docker_image:=JanusConfig} -> JanusConfig;
        _ -> nkmedia_janus_build:defaults(#{})
    end,
    {ok, Config, Cache}.


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA Janus (~s) starting", [Name]),
    case nkdocker_monitor:register(?MODULE) of
        {ok, DockerMonId} ->
            nkmedia_app:put(docker_janus_mon_id, DockerMonId),
            lager:info("Installed images: ~s", 
                [nklib_util:bjoin(find_images(DockerMonId))]);
        {error, Error} ->
            lager:error("Could not start Docker Monitor: ~p", [Error]),
            error(docker_monitor)
    end,
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA Janus (~p) stopping", [Name]),
    nkdocker_monitor:unregister(?MODULE),
    {ok, Config}.



%% ===================================================================
%% Offering Callbacks
%% ===================================================================


%% @private
-spec nkmedia_janus_get_mediaserver(nkservice:id()) ->
    {ok, nkmedia_janus_engine:id()} | {error, term()}.

nkmedia_janus_get_mediaserver(SrvId) ->
    case nkmedia_janus_engine:get_all(SrvId) of
        [{JanusId, _}|_] ->
            {ok, JanusId};
        [] ->
            {error, no_mediaserver}
    end.




%% ===================================================================
%% Implemented Callbacks - error
%% ===================================================================

%% @private See nkservice_callbacks
error_code({janus_error, Code, Txt})    ->  {301001, "Janus error ~p: ~s", Code, Txt};
error_code(janus_connection_error)      ->  {301002, <<"Janus connection error">>};
error_code(janus_session_down)          ->  {301003, <<"Janus op process down">>};
error_code(janus_bye)                   ->  {301004, <<"Janus bye">>};
error_code(_)                           ->  continue.


%% ===================================================================
%% Implemented Callbacks - nkmedia_session
%% ===================================================================



%% @private
nkmedia_session_start(Type, Role, Session) ->
    case maps:get(backend, Session, nkmedia_janus) of
        nkmedia_janus ->
            nkmedia_janus_session:start(Type, Role, Session);
        _ ->
            continue
    end.


%% @private
nkmedia_session_offer(Type, Role, Offer, #{nkmedia_janus_id:=_}=Session) ->
    nkmedia_janus_session:offer(Type, Role, Offer, Session);

nkmedia_session_offer(_Type, _Role, _Offer, _Session) ->
    continue.


%% @private
nkmedia_session_answer(Type, Role, Answer, #{nkmedia_janus_id:=_}=Session) ->
    nkmedia_janus_session:answer(Type, Role, Answer, Session);

nkmedia_session_answer(_Type, _Role, _Answer, _Session) ->
    continue.


%% @private
nkmedia_session_cmd(Update, Opts, #{nkmedia_janus_id:=_}=Session) ->
    nkmedia_janus_session:cmd(Update, Opts, Session);

nkmedia_session_cmd(_Update, _Opts, _Session) ->
    continue.


%% @private
nkmedia_session_candidate(Candidate, #{nkmedia_janus_id:=_}=Session) ->
    nkmedia_janus_session:candidate(Candidate, Session);

nkmedia_session_candidate(_Candidate, _Session) ->
    continue.


% %% @private
% nkmedia_session_peer_candidate(Candidate, #{nkmedia_janus_id:=_}=Session) ->
%     nkmedia_janus_session:peer_candidate(Candidate, Session);

% nkmedia_session_peer_candidate(_Candidate, _Session) ->
%     continue.


%% @private
nkmedia_session_stop(Reason, #{nkmedia_janus_id:=_}=Session) ->
    nkmedia_janus_session:stop(Reason, Session);

nkmedia_session_stop(_Reason, _Session) ->
    continue.


% @private
nkmedia_session_handle_call({nkmedia_janus, Msg}, From, Session) ->
    nkmedia_janus_session:handle_call(Msg, From, Session);

nkmedia_session_handle_call(_Msg, _From, _Session) ->
    continue.


% @private
nkmedia_session_handle_cast({nkmedia_janus, Msg}, Session) ->
    nkmedia_janus_session:handle_cast(Msg, Session);

nkmedia_session_handle_cast(_Msg, _Session) ->
    continue.



%% @private The janus_op process is down
nkmedia_session_handle_info({'DOWN', Ref, process, _Pid, _Reason}, Session) ->
    case Session of
        #{nkmedia_janus_mon:=Ref} ->
            nkmedia_session:stop(self(), janus_session_down),
            {noreply, Session};
        _ ->
            continue
    end;

nkmedia_session_handle_info(_Msg, _Session) ->
    continue.


%% ===================================================================
%% Implemented Callbacks - nkmedia_room
%% ===================================================================

%% @private
nkmedia_room_init(Id, Room) ->
    case maps:get(backend, Room, nkmedia_janus) of
        nkmedia_janus  ->
            case maps:get(class, Room, sfu) of
                sfu ->
                    nkmedia_janus_room:init(Id, Room);
                _ ->
                    {ok, Room}
            end;
        _ ->
            {ok, Room}
    end.


%% @private
nkmedia_room_terminate(Reason, #{nkmedia_janus_id:=_}=Room) ->
    nkmedia_janus_room:terminate(Reason, Room);

nkmedia_room_terminate(_Reason, Room) ->
    {ok, Room}.


%% @private
nkmedia_room_tick(RoomId, #{nkmedia_janus_id:=_}=Room) ->
    nkmedia_janus_room:tick(RoomId, Room);

nkmedia_room_tick(_RoomId, _Room) ->
    continue.


%% @private
nkmedia_room_handle_cast({nkmedia_janus, Msg}, Room) ->
    nkmedia_janus_room:handle_cast(Msg, Room);

nkmedia_room_handle_cast(_Msg, _Room) ->
    continue.



%% ===================================================================
%% Implemented Callbacks - nkmedia_call
%% ===================================================================


nkmedia_call_start_caller_session(CallId, Config, #{srv_id:=SrvId, offer:=Offer}=Call) ->
    case maps:get(backend, Call, nkmedia_janus) of
        nkmedia_janus ->
            Config2 = Config#{
                backend => nkmedia_janus, 
                offer => Offer,
                call_id => CallId
            },
            {ok, MasterId, Pid} = nkmedia_session:start(SrvId, proxy, Config2),
            {ok, MasterId, Pid, ?CALL(#{backend=>nkmedia_janus}, Call)};
        _ ->
            continue
    end.


nkmedia_call_start_callee_session(CallId, MasterId, Config, 
                                  #{backend:=nkmedia_janus, srv_id:=SrvId}=Call) ->
    case nkmedia_session:cmd(MasterId, get_type, #{}) of
        {ok, #{type:=proxy, backend:=nkmedia_janus}} ->
            Config2 = Config#{
                backend => nkmedia_janus,
                peer_id => MasterId,
                call_id => CallId
            },
            {ok, SlaveId, Pid} = nkmedia_session:start(SrvId, bridge, Config2),
            case nkmedia_session:get_offer(SlaveId) of
                {ok, Offer} ->
                    {ok, SlaveId, Pid, Offer, Call};
                {error, Error} ->
                    {error, Error, Call}
            end;
        _ ->
            {error, incompatible_session, Call}
    end;

nkmedia_call_start_callee_session(_CallId, _MasterId, _Config, _Call) ->
    continue.


nkmedia_call_set_answer(_CallId, _MasterId, SlaveId, Answer, 
                        #{backend:=nkmedia_janus}=Call) ->
    case nkmedia_session:set_answer(SlaveId, Answer) of
        ok ->
            {ok, Call};
        {error, Error} ->
            {error, Error, Call}
    end;

nkmedia_call_set_answer(_CallId, _MasterId, _SlaveId, _Answer, _Call) ->
    continue.



%% ===================================================================
%% API
%% ===================================================================

% %% @private
% api_cmd(#api_req{class = <<"media">>}=Req, State) ->
%     #api_req{subclass=Sub, cmd=Cmd} = Req,
%     nkmedia_janus_api:cmd(Sub, Cmd, Req, State);

% api_cmd(_Req, _State) ->
%     continue.


%% @private
api_syntax(#api_req{class = <<"media">>}=Req, Syntax, Defaults, Mandatory) ->
    #api_req{subclass=Sub, cmd=Cmd} = Req,
    {S2, D2, M2} = nkmedia_janus_api_syntax:syntax(Sub, Cmd, Syntax, Defaults, Mandatory),
    {continue, [Req, S2, D2, M2]};

api_syntax(_Req, _Syntax, _Defaults, _Mandatory) ->
    continue.



%% ===================================================================
%% Docker Monitor Callbacks
%% ===================================================================

nkdocker_notify(MonId, {Op, {<<"nk_janus_", _/binary>>=Name, Data}}) ->
    nkmedia_janus_docker:notify(MonId, Op, Name, Data);

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
        [Comp, <<"nk_janus:", Tag/binary>>] -> 
            [Vsn, Rel] = binary:split(Tag, <<"-">>),
            Def = #{comp=>Comp, vsn=>Vsn, rel=>Rel},
            {ok, nkmedia_janus_build:defaults(Def)};
        _ ->
            error
    end.


%% @private
find_images(MonId) ->
    {ok, Docker} = nkdocker_monitor:get_docker(MonId),
    {ok, Images} = nkdocker:images(Docker),
    Tags = lists:flatten([T || #{<<"RepoTags">>:=T} <- Images]),
    lists:filter(
        fun(Img) -> length(binary:split(Img, <<"/nk_janus_">>))==2 end, Tags).
