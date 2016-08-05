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

-export([plugin_deps/0, plugin_syntax/0, plugin_config/2,
         plugin_start/2, plugin_stop/2]).
-export([error_code/1]).
-export([nkmedia_janus_get_mediaserver/1]).
-export([nkmedia_session_init/2, nkmedia_session_terminate/2]).
-export([nkmedia_session_start/2, nkmedia_session_answer/3,
         nkmedia_session_update/4, nkmedia_session_stop/2, 
         nkmedia_session_handle_call/3, nkmedia_session_handle_info/2]).
-export([nkmedia_room_init/2, nkmedia_room_terminate/2, nkmedia_room_event/3,
         nkmedia_room_handle_cast/2]).
-export([api_cmd/2, api_syntax/4]).
-export([nkdocker_notify/2]).

-include_lib("nkservice/include/nkservice.hrl").



%% ===================================================================
%% Types
%% ===================================================================




%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia].


plugin_syntax() ->
    #{
        janus_docker_image => fun parse_image/3
    }.


plugin_config(Config, _Service) ->
    Cache = case Config of
        #{janus_docker_image:=FsConfig} -> FsConfig;
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
        [{FsId, _}|_] ->
            {ok, FsId};
        [] ->
            {error, no_mediaserver}
    end.




%% ===================================================================
%% Implemented Callbacks - error
%% ===================================================================

error_code(janus_error)             ->  {200, <<"Janus error">>};
error_code(janus_connection_error)  ->  {200, <<"Janus connection error">>};
error_code(janus_op_down)           ->  {200, <<"Janus op process down">>};
error_code(janus_bye)               ->  {200, <<"Janus bye">>};
error_code(invalid_publisher)       ->  {200, <<"Invalid publisher">>};
error_code(publisher_stopped)       ->  {200, <<"Publisher stopped">>};

error_code(_)                       ->  continue.


%% ===================================================================
%% Implemented Callbacks - nkmedia_session
%% ===================================================================

%% @private
nkmedia_session_init(Id, Session) ->
    State = maps:get(nkmedia_janus, Session, #{}),
    {ok, State2} = nkmedia_janus_session:init(Id, Session, State),
    {ok, update_state(State2, Session)}.


%% @private
nkmedia_session_terminate(Reason, Session) ->
    nkmedia_janus_session:terminate(Reason, Session, state(Session)),
    {ok, nkmedia_session:do_rm(nkmedia_janus, Session)}.


%% @private
nkmedia_session_start(Type, Session) ->
    case maps:get(backend, Session, nkmedia_janus) of
        nkmedia_janus ->
            State = state(Session),
            case nkmedia_janus_session:start(Type, Session, State) of
                {ok, Reply, ExtOps, State2} ->
                    Session2 = nkmedia_session:do_add(backend, nkmedia_janus, Session),
                    {ok, Reply, ExtOps, update_state(State2, Session2)};
                {error, Error, State2} ->
                    Session2 = nkmedia_session:do_add(backend, nkmedia_janus, Session),
                    {error, Error, update_state(State2, Session2)};
                continue ->
                    continue
            end;
        _ ->
            continue
    end.


%% @private
nkmedia_session_answer(Type, Answer, Session) ->
    case maps:get(backend, Session, nkmedia_janus) of
        nkmedia_janus ->
            State = state(Session),
            case nkmedia_janus_session:answer(Type, Answer, Session, State) of
                {ok, Reply, ExtOps, State2} ->
                    {ok, Reply, ExtOps, update_state(State2, Session)};
                {error, Error, State2} ->
                    {error, Error, update_state(State2, Session)};
                continue ->
                    continue
            end;
        _ ->
            continue
    end.



%% @private
nkmedia_session_update(Update, Opts, Type, Session) ->
    case maps:get(backend, Session, nkmedia_janus) of
        nkmedia_janus ->
            State = state(Session),
            case nkmedia_janus_session:update(Update, Opts, Type, Session, State) of
                {ok, Reply, ExtOps, State2} ->
                    {ok, Reply, ExtOps, update_state(State2, Session)};
                {error, Error, State2} ->
                    {error, Error, update_state(State2, Session)};
                continue ->
                    continue
            end;
        _ ->
            continue
    end.


%% @private
nkmedia_session_stop(Reason, Session) ->
    {ok, State2} = nkmedia_janus_session:stop(Reason, Session, state(Session)),
    {continue, [Reason, update_state(State2, Session)]}.


%% @private
nkmedia_session_handle_call(nkmedia_janus_get_room, _From, Session) ->
    Reply = case Session of
        #{srv_id:=SrvId, type:=publish, type_ext:=#{room_id:=Room}} ->
            {ok, SrvId, Room};
        _ ->
            {error, invalid_state}
    end,
    {reply, Reply, Session};

nkmedia_session_handle_call(_Msg, _From, _Session) ->
    continue.


%% @private The janus_op process is down
nkmedia_session_handle_info({'DOWN', Ref, process, _Pid, _Reason}, Session) ->
    case state(Session) of
        #{janus_mon:=Ref} ->
            nkmedia_session:stop(self(), janus_op_down),
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
    Class = maps:get(class, Room, sfu),
    Backend = maps:get(backend, Room, nkmedia_janus),
    case {Class, Backend} of
        {sfu, nkmedia_janus} ->
            case nkmedia_janus_room:init(Id, Room) of
                {ok, State} ->
                    Room2 = Room#{
                        class => sfu,
                        backend => nkmedia_janus,
                        nkmedia_janus => State,
                        publishers => #{},
                        listeners => #{}
                    },
                    {ok, Room2};
                {error, Error} ->
                    {error, Error}
            end;
        _ ->
            continue
    end.


%% @private
nkmedia_room_terminate(Reason, Room) ->
    case state(Room) of
        error ->
            continue;
        State ->
            {ok, State2} = nkmedia_janus_room:terminate(Reason, Room, State),
            {ok, update_state(State2, Room)}
    end.


%% @private
nkmedia_room_event(RoomId, Event, Room) ->
    case state(Room) of
        error ->
            continue;
        State ->
            {ok, State2} = nkmedia_janus_room:event(RoomId, Event, Room, State),
            {continue, [RoomId, Event, update_state(State2, Room)]}
    end.


% %% @private
% nkmedia_room_reg_event(_RoomId, _RegId, _Event, Room) ->
%     {ok, Room}.


% %% @private
% nkmedia_room_reg_down(_RoomId, _Link, _Reason, Session) ->
%     {stop, registered_down, Session}.


% %% @private
% nkmedia_room_handle_call({nkmedia_janus, Msg}, From, Room) ->
%     case nkmedia_janus_room:nkmedia_room_handle_call(Msg, From, Room, state(Room)) of
%         {reply, Reply, State2} ->
%             {reply, Reply, update_state(State2, Room)};
%         {noreply, State2} ->
%             {noreply, update_state(State2, Room)}
%     end;

% nkmedia_room_handle_call(_Msg, _From, _Room) ->
%     continue.


%% @private
nkmedia_room_handle_cast({nkmedia_janus, Msg}, Room) ->
    {noreply, State2} = 
        nkmedia_janus_room:nkmedia_room_handle_cast(Msg, Room, state(Room)),
    {noreply, update_state(State2, Room)};

nkmedia_room_handle_cast(_Msg, _Room) ->
    continue.


% %% @private
% nkmedia_room_handle_info(Msg, Room) ->
%     lager:warning("Module nkmedia_room received unexpected info: ~p", [Msg]),
%     {noreply, Room}.




%% ===================================================================
%% API
%% ===================================================================

%% @private
api_cmd(#api_req{class = <<"media">>}=Req, State) ->
    #api_req{subclass=Sub, cmd=Cmd} = Req,
    nkmedia_janus_api:cmd(Sub, Cmd, Req, State);

api_cmd(_Req, _State) ->
    continue.


%% @private
api_syntax(#api_req{class = <<"media">>}=Req, Syntax, Defaults, Mandatory) ->
    #api_req{subclass=Sub, cmd=Cmd} = Req,
    {S2, D2, M2} = nkmedia_janus_api:syntax(Sub, Cmd, Syntax, Defaults, Mandatory),
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
state(#{nkmedia_janus:=State}) ->
    State;

state(_) ->
    error.


%% @private
update_state(State, Session) ->
    nkmedia_session:do_add(nkmedia_janus, State, Session).


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
