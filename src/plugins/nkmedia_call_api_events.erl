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

%% @doc Call Plugin API
-module(nkmedia_call_api_events).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([event/3]).

% -include_lib("nkservice/include/nkservice.hrl").




%% ===================================================================
%% Events
%% ===================================================================


%% @private
-spec event(nkmedia_call:id(), nkmedia_call:event(), nkmedia_call:call()) ->
    {ok, nkmedia_call:call()}.

event(CallId, {ringing, _, Answer}, Call) when map_size(Answer) > 0 -> 
    send_event(CallId, ringing, #{answer=>Answer}, Call);

event(CallId, {ringing, _, _Answer}, Call) ->
    send_event(CallId, ringing, #{}, Call);

event(CallId, {answer, _, Answer}, Call) when map_size(Answer) > 0 ->
    send_event(CallId, answer, #{answer=>Answer}, Call);

event(CallId, {answer, _, _Answer}, Call) ->
    send_event(CallId, answer, #{}, Call);

event(CallId, {hangup, Reason}, #{srv_id:=SrvId}=Call) ->
    {Code, Txt} = SrvId:error_code(Reason),
    send_event(CallId, hangup, #{code=>Code, reason=>Txt}, Call);

event(_CallId, _Event, Call) ->
    {ok, Call}.


%% @private
send_event(CallId, Type, Body, #{srv_id:=SrvId}=Call) ->
    nkmedia_api_events:send_event(SrvId, call, CallId, Type, Body),
    {ok, Call}.


