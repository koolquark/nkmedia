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

-export([plugin_deps/0, plugin_syntax/0, plugin_defaults/0, plugin_config/2,
         plugin_start/2, plugin_stop/2]).
-export([nkmedia_fs_get_mediaserver/1]).
-export([nkmedia_session_init/2, nkmedia_session_terminate/2]).
-export([nkmedia_session_offer_op/3, nkmedia_session_answer_op/3,
         nkmedia_session_update/3, nkmedia_session_hangup/2]).
-export([nkmedia_session_updated_answer/2]).
-export([nkmedia_session_event/3, nkmedia_session_handle_cast/2]).
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
        fs_version => binary,
        fs_release => binary
    }.


plugin_defaults() ->
    #{
        docker_company => <<"netcomposer">>,
        fs_version => <<"v1.6.8">>,
        fs_release => <<"r01">>
    }.


plugin_config(Config, _Service) ->
    Cache = maps:with([docker_company, fs_version, fs_release], Config),
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
            error(docker_monitor)
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
-spec nkmedia_fs_get_mediaserver(session()) ->
    {ok, nkmedia_fs_engine:id(), session()} | {error, term()}.

nkmedia_fs_get_mediaserver(#{srv_id:=SrvId}=Session) ->
    case nkmedia_fs_engine:get_all(SrvId) of
        [{FsId, _}|_] ->
            {ok, FsId, Session};
        [] ->
            {error, no_mediaserver_available}
    end.




%% ===================================================================
%% Implemented Callbacks - nkmedia_session
%% ===================================================================

%% @private
nkmedia_session_init(Id, Session) ->
    nkmedia_fs_session:init(Id, Session).


%% @private
nkmedia_session_terminate(Reason, Session) ->
    nkmedia_fs_session:terminate(Reason, Session).


%% @private
nkmedia_session_offer_op(OfferOp, Opts, Session) ->
    case maps:get(backend, Session, freeswitch) of
        freeswitch ->
            #{nkmedia_fs:=State} = Session,
            nkmedia_fs_session:offer_op(OfferOp, Opts, State, Session);
        _ ->
            continue
    end.


%% @private
nkmedia_session_answer_op(AnswerOp, Opts, Session) ->
    case maps:get(backend, Session, freeswitch) of
        freeswitch ->
            #{nkmedia_fs:=State} = Session,
            nkmedia_fs_session:answer_op(AnswerOp, Opts, State, Session);
        _ ->
            continue
    end.


%% @private
nkmedia_session_update(Update, Opts, Session) ->
    case maps:get(backend, Session, freeswitch) of
        freeswitch ->
            #{nkmedia_fs:=State} = Session,
            nkmedia_fs_session:update(Update, Opts, State, Session);
        _ ->
            continue
    end.


%% @private
nkmedia_session_event(_SessId, Event, Session) ->
    case Session of
        #{nkmedia_fs:=#{peer:={_PeerId, _Ref}}=State} ->
            nkmedia_fs_session:peer_event(Event, State, Session),
            continue;
        _ ->
            continue
    end.


%% @private
nkmedia_session_hangup(Reason, Session) ->
    #{nkmedia_fs:=State} = Session,
    nkmedia_fs_session:hangup(Reason, State, State, Session).



%% @private
nkmedia_session_updated_answer(Answer, Session) ->
    #{nkmedia_fs:=State} = Session,
    nkmedia_fs_session:updated_answer(Answer, State, Session).


%% @private
nkmedia_session_handle_cast({fs_event, FsId, Event}, Session) ->
    case Session of
        #{nkmedia_fs:=#{fs_id:=FsId}} ->
            nkmedia_fs_session:do_fs_event(Event, Session);
        _ ->
            lager:warning("NkMEDIA FS received unexpected FS event"),
            {ok, Session}
    end;

nkmedia_session_handle_cast(_Msg, _Session) ->
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
find_images(MonId) ->
    {ok, Docker} = nkdocker_monitor:get_docker(MonId),
    {ok, Images} = nkdocker:images(Docker),
    Tags = lists:flatten([T || #{<<"RepoTags">>:=T} <- Images]),
    lists:filter(fun(Img) -> length(binary:split(Img, <<"/nk_fs_">>))==2 end, Tags).
