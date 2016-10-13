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

%% @doc Janus conf (SFU) management
-module(nkmedia_janus_conf).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([init/2, terminate/2, tick/2, handle_cast/2]).
-export([janus_check/3]).

-define(LLOG(Type, Txt, Args, Conf),
    lager:Type("NkMEDIA Janus Conferece ~s "++Txt, [maps:get(conf_id, Conf) | Args])).

-include("../../include/nkmedia_conf.hrl").


%% ===================================================================
%% Types
%% ===================================================================


-type conf_id() :: nkmedia_conf:id().

-type conf() ::
    nkmedia_conf:conf() |
    #{
        nkmedia_janus_id => nkmedia_janus:id()
    }.



%% ===================================================================
%% External
%% ===================================================================

%% @private Called periodically from nkmedia_janus_engine
janus_check(JanusId, ConfId, Data) ->
    case nkmedia_conf:find(ConfId) of
        {ok, Pid} ->
            #{<<"num_participants">>:=Num} = Data,
            gen_server:cast(Pid, {nkmedia_janus, {participants, Num}});
        not_found ->
            spawn(
                fun() -> 
                    lager:warning("Destroying orphan Janus conf ~s", [ConfId]),
                    destroy_conf(#{nkmedia_janus_id=>JanusId, conf_id=>ConfId})
                end)
    end.



%% ===================================================================
%% Callbacks
%% ===================================================================

%% @doc Creates a new conf
%% Use nkmedia_janus_op:list_rooms/1 to check rooms directly on Janus
-spec init(conf_id(), conf()) ->
    {ok, conf()} | {error, term()}.

init(_ConfId, Conf) ->
    case get_janus(Conf) of
        {ok, Conf2} ->
            case create_conf(Conf2) of
                {ok, Conf3} ->
                    {ok, ?CONF(#{class=>sfu, backend=>nkmedia_janus}, Conf3)};
                {error, Error} ->
                    {error, Error}
            end;
       error ->
            {error, mediaserver_not_available}
    end.


%% @doc
-spec terminate(term(), conf()) ->
    {ok, conf()} | {error, term()}.

terminate(_Reason, Conf) ->
    case destroy_conf(Conf) of
        ok ->
            ?LLOG(info, "stopping, destroying conf", [], Conf);
        {error, Error} ->
            ?LLOG(warning, "could not destroy conf: ~p", [Error], Conf)
    end,
    {ok, Conf}.



%% @private
-spec tick(conf_id(), conf()) ->
    {ok, conf()} | {stop, nkservice:error(), conf()}.

tick(ConfId, #{nkmedia_janus_id:=JanusId}=Conf) ->
    case length(nkmedia_conf:get_all_with_role(publisher, Conf)) of
        0 ->
            nkmedia_conf:stop(self(), timeout);
        _ ->
           case nkmedia_janus_engine:check_conf(JanusId, ConfId) of
                {ok, _} ->      
                    ok;
                _ ->
                    ?LLOG(warning, "conf is not on engine ~p ~p", 
                          [JanusId, ConfId], Conf),
                    nkmedia_conf:stop(self(), timeout)
            end
    end,
    {ok, Conf}.


%% @private
-spec handle_cast(term(), conf()) ->
    {noreply, conf()}.

handle_cast({participants, Num}, Conf) ->
    case length(nkmedia_conf:get_all_with_role(publisher, Conf)) of
        Num -> 
            ok;
        Other ->
            ?LLOG(notice, "Janus says ~p participants, we have ~p!", 
                  [Num, Other], Conf),
            case Num of
                0 ->
                    nkmedia_conf:stop(self(), no_conf_members);
                _ ->
                    ok
            end
    end,
    {noreply, Conf}.




% ===================================================================
%% Internal
%% ===================================================================


%% @private
-spec get_janus(conf()) ->
    {ok, conf()} | error.

get_janus(#{nkmedia_janus_id:=_}=Conf) ->
    {ok, Conf};

get_janus(#{srv_id:=SrvId}=Conf) ->
    case SrvId:nkmedia_janus_get_mediaserver(SrvId) of
        {ok, JanusId} ->
            {ok, ?CONF(#{nkmedia_janus_id=>JanusId}, Conf)};
        {error, _Error} ->
            error
    end.


%% @private
-spec create_conf(conf()) ->
    {ok, conf()} | {error, term()}.

create_conf(#{nkmedia_janus_id:=JanusId, conf_id:=ConfId}=Conf) ->
    Merge = #{audio_codec=>opus, video_codec=>vp8, bitrate=>500000},
    Conf2 = ?CONF_MERGE(Merge, Conf),
    Opts = #{        
        audiocodec => maps:get(audio_codec, Conf2),
        videocodec => maps:get(video_codec, Conf2),
        bitrate => maps:get(bitrate, Conf2)
    },
    case nkmedia_janus_op:start(JanusId, ConfId) of
        {ok, Pid} ->
            case nkmedia_janus_op:create_room(Pid, ConfId, Opts) of
                ok ->
                    {ok, Conf2};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


-spec destroy_conf(conf()) ->
    ok | {error, term()}.

destroy_conf(#{nkmedia_janus_id:=JanusId, conf_id:=ConfId}) ->
    case nkmedia_janus_op:start(JanusId, ConfId) of
        {ok, Pid} ->
            nkmedia_janus_op:destroy_room(Pid, ConfId);
        {error, Error} ->
            {error, Error}
    end.


