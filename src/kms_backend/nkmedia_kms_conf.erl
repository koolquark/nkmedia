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

%% @doc Kurento conf management
-module(nkmedia_kms_conf).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([init/2, terminate/2, tick/2]).

-define(LLOG(Type, Txt, Args, Conf),
    lager:Type("NkMEDIA Kms Conference ~s "++Txt, [maps:get(conf_id, Conf) | Args])).

-include("../../include/nkmedia_conf.hrl").


%% ===================================================================
%% Types
%% ===================================================================


-type conf_id() :: nkmedia_conf:id().

-type conf() ::
    nkmedia_conf:conf() |
    #{
        nkmedia_kms_id => nkmedia_kms:id()
    }.



%% ===================================================================
%% External
%% ===================================================================




%% ===================================================================
%% Callbacks
%% ===================================================================



%% @doc Creates a new conf
-spec init(conf_id(), conf()) ->
    {ok, conf()} | {error, term()}.

init(_ConfId, Conf) ->
    case get_kms(Conf) of
        {ok, Conf2} ->
            {ok, ?CONF(#{class=>sfu, backend=>nkmedia_kms}, Conf2)};
       error ->
            {error, mediaserver_not_available}
    end.


%% @doc
-spec terminate(term(), conf()) ->
    {ok, conf()} | {error, term()}.

terminate(_Reason, Conf) ->
    ?LLOG(info, "stopping, destroying conf", [], Conf),
    {ok, Conf}.



%% @private
-spec tick(conf_id(), conf()) ->
    {ok, conf()} | {stop, nkservice:error(), conf()}.

tick(_ConfId, Conf) ->
    case length(nkmedia_conf:get_all_with_role(publisher, Conf)) of
        0 ->
            nkmedia_conf:stop(self(), timeout);
        _ ->
            ok
    end,
    {ok, Conf}.



% ===================================================================
%% Internal
%% ===================================================================


%% @private
get_kms(#{nkmedia_kms_id:=_}=Conf) ->
    {ok, Conf};

get_kms(#{srv_id:=SrvId}=Conf) ->
    case SrvId:nkmedia_kms_get_mediaserver(SrvId) of
        {ok, KmsId} ->
            {ok, ?CONF(#{nkmedia_kms_id=>KmsId}, Conf)};
        {error, _Error} ->
            error
    end.
