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

-export([plugin_deps/0, plugin_syntax/0, plugin_defaults/0, plugin_config/2,
         plugin_start/2, plugin_stop/2]).
-export([nkmedia_kms_get_mediaserver/1]).
-export([nkmedia_session_init/2, nkmedia_session_terminate/2]).
-export([nkmedia_session_offer_op/4, nkmedia_session_answer_op/4,
         nkmedia_session_hangup/2]).
-export([nkmedia_session_updated_answer/2]).
-export([nkmedia_session_peer_event/4, nkmedia_session_handle_cast/2]).
-export([nkdocker_notify/2]).

-include_lib("nkservice/include/nkservice.hrl").



%% ===================================================================
%% Types
%% ===================================================================

-type session() :: nkmedia_session:session().
% -type continue() :: continue | {continue, list()}.



%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia].


plugin_syntax() ->
    #{
        docker_company => binary,
        kms_version => binary,
        kms_release => binary
    }.


plugin_defaults() ->
    Defs = nkmedia_kms_build:defaults(#{}),
    #{
        docker_company => maps:get(comp, Defs),
        kms_version => maps:get(vsn, Defs),
        kms_release => maps:get(rel, Defs)
    }.


plugin_config(Config, _Service) ->
    Cache = maps:with([docker_company, kms_version, kms_release], Config),
    {ok, Config, Cache}.


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA KMS (~s) starting", [Name]),
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
    lager:info("Plugin NkMEDIA KMS (~p) stopping", [Name]),
    nkdocker_monitor:unregister(?MODULE),
    {ok, Config}.



%% ===================================================================
%% Offering Callbacks
%% ===================================================================


%% @private
-spec nkmedia_kms_get_mediaserver(session()) ->
    {ok, nkmedia_kms_engine:id()} | {error, term()}.

nkmedia_kms_get_mediaserver(#{srv_id:=SrvId}) ->
    case nkmedia_kms_engine:get_all(SrvId) of
        [{FsId, _}|_] ->
            {ok, FsId};
        [] ->
            {error, no_mediaserver_available}
    end.




%% ===================================================================
%% Implemented Callbacks - nkmedia_session
%% ===================================================================

%% @private
nkmedia_session_init(Id, Session) ->
    State = maps:get(nkmedia_kms, Session, #{}),
    {ok, State2} = nkmedia_kms_session:init(Id, Session, State),
    {ok, Session#{nkmedia_kms=>State2}}.


%% @private
nkmedia_session_terminate(Reason, Session) ->
    nkmedia_kms_session:terminate(Reason, Session, state(Session)),
    {ok, maps:remove(nkmedia_kms, Session)}.


%% @private
nkmedia_session_offer_op(Op, Opts, HasOffer, Session) ->
    case maps:get(backend, Session, freeswitch) of
        freeswitch ->
            State = state(Session),
            case 
                nkmedia_kms_session:offer_op(Op, Opts, HasOffer, Session, State)
            of
                {ok, Offer, Op2, Opts2, State2} ->
                    {ok, Offer, Op2, Opts2, session(State2, Session)};
                {error, Error, State2} ->
                    {error, Error, session(State2, Session)};
                continue ->
                    continue
            end;
        _ ->
            continue
    end.


%% @private
nkmedia_session_answer_op(Op, Opts, HasAnswer, Session) ->
    case maps:get(backend, Session, freeswitch) of
        freeswitch ->
            State = state(Session),
            case 
                nkmedia_kms_session:answer_op(Op, Opts, HasAnswer, Session, State)
            of
                {ok, Answer, Op2, Opts2, State2} ->
                    {ok, Answer, Op2, Opts2, session(State2, Session)};
                {error, Error, State2} ->
                    {error, Error, session(State2, Session)};
                continue ->
                    continue
            end;
        _ ->
            continue
    end.


%% @private
nkmedia_session_updated_answer(#{sdp:=_}=Answer, Session) ->
    case nkmedia_kms_session:updated_answer(Answer, Session, state(Session)) of
        {ok, Answer2, State2} ->
            {ok, Answer2, session(State2, Session)};
        {error, Error, State2} ->
            {error, Error, session(State2, Session)};
        continue ->
            continue
    end;

nkmedia_session_updated_answer(_Answer, _Session) ->
    continue.


%% @private
nkmedia_session_peer_event(SessId, Type, Event, Session) ->
    case Event of
        {answer_op, _, _} ->
            State = state(Session),
            nkmedia_kms_session:peer_event(SessId, Type, Event, Session, State);
        {hangup, _} ->
            State = state(Session),
            nkmedia_kms_session:peer_event(SessId, Type, Event, Session, State);
        _ ->
            ok
    end,
    continue.
        

%% @private
nkmedia_session_hangup(Reason, Session) ->
    {ok, State2} = nkmedia_kms_session:hangup(Reason, Session, state(Session)),
    {continue, [Reason, session(State2, Session)]}.


%% @private
nkmedia_session_handle_cast({kms_event, FsId, Event}, Session) ->
    case Session of
        #{nkmedia_kms:=#{kms_id:=FsId}} ->
            State = state(Session),
            {ok, State2} = nkmedia_kms_session:do_kms_event(Event, Session, State),
            {noreply, session(State2, Session)};
        _ ->
            lager:warning("NkMEDIA FS received unexpected FS event"),
            {ok, Session}
    end;

nkmedia_session_handle_cast(_Msg, _Session) ->
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
state(#{nkmedia_kms:=State}) ->
    State.


%% @private
session(State, Session) ->
    Session#{nkmedia_kms:=State}.


%% @private
find_images(MonId) ->
    {ok, Docker} = nkdocker_monitor:get_docker(MonId),
    {ok, Images} = nkdocker:images(Docker),
    Tags = lists:flatten([T || #{<<"RepoTags">>:=T} <- Images]),
    lists:filter(fun(Img) -> length(binary:split(Img, <<"/nk_kms_">>))==2 end, Tags).
