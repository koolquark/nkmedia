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

%% @doc Conf Plugin API
-module(nkmedia_conf_api_events).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([event/3]).

% -include_lib("nkservice/include/nkservice.hrl").


%% ===================================================================
%% Events
%% ===================================================================


%% @private
-spec event(nkmedia_conf:id(), nkmedia_conf:event(), nkmedia_conf:conf()) ->
    {ok, nkmedia_conf:conf()}.

event(ConfId, started, Conf) ->
    Data = maps:with([audio_codec, video_codec, bitrate, class, backend], Conf),
    send_event(ConfId, created, Data, Conf);

event(ConfId, {stopped, Reason}, #{srv_id:=SrvId}=Conf) ->
    {Code, Txt} = nkservice_util:error_code(SrvId, Reason),
    send_event(ConfId, destroyed, #{code=>Code, reason=>Txt}, Conf);

event(ConfId, {started_member, SessId, Info}, Conf) ->
    send_event(ConfId, started_member, Info#{session_id=>SessId}, Conf);

event(ConfId, {stopped_member, SessId, Info}, Conf) ->
    send_event(ConfId, stopped_member, Info#{session_id=>SessId}, Conf);

event(_ConfId, _Event, Conf) ->
    {ok, Conf}.


%% @private
send_event(ConfId, Type, Body, #{srv_id:=SrvId}=Conf) ->
    nkmedia_api_events:send_event(SrvId, conf, ConfId, Type, Body),
    {ok, Conf}.



