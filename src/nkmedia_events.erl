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

%% @doc NkMEDIA external events processing

-module(nkmedia_events).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([send_event/5]).
-export([session_event/3, call_event/3, room_event/3]).

-include_lib("nkservice/include/nkservice.hrl").



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Sends a room event
-spec send_event(nkservice:id(), atom(), binary(), atom(), map()) ->
    ok.

send_event(SrvId, Class, Id, Type, Body) ->
    lager:info("MEDIA EVENT (~s:~s:~s): ~p", [Class, Type, Id, Body]),
    RegId = #reg_id{
        srv_id = SrvId,     
        class = <<"media">>, 
        subclass = nklib_util:to_binary(Class),
        type = nklib_util:to_binary(Type),
        obj_id = Id
    },
    nkservice_events:send(RegId, Body).



%% ===================================================================
%% Callbacks
%% ===================================================================

%% @private
-spec session_event(nkmedia_session:id(), nkmedia_session:event(), 
				    nkmedia_session:session()) ->
	{ok, nkmedia_sesison:session()}.

session_event(SessId, Event, #{srv_id:=SrvId}=Session) ->
    Send = case Event of
        {answer, Answer} ->
            {answer, #{answer=>Answer}};
        {info, Info} ->
            {info, #{info=>Info}};
        {session_type, Type, Ext} ->
            {session_type, Ext#{type=>Type}};
        {stop, Reason} ->
            {Code, Txt} = SrvId:error_code(Reason),
            {stop, #{code=>Code, reason=>Txt}};
        _ ->
            ignore
    end,
    case Send of
        {EvType, Body} ->
            send_event(SrvId, session, SessId, EvType, Body);
        ignore ->
            ok
    end,
    {ok, Session}.



%% @private
-spec call_event(nkmedia_call:id(), nkmedia_call:event(), nkmedia_call:call()) ->
	{ok, nkmedia_call:call()}.

call_event(CallId, Event, #{srv_id:=SrvId}=Call) ->
    Send = case Event of
        {ringing, _, Answer} when map_size(Answer) > 0 -> 
            {ringing, #{answer=>Answer}};
        {ringing, _, _Answer} ->
            {ringing, #{}};
        {answer, _, Answer} when map_size(Answer) > 0 ->
            {answer, #{answer=>Answer}};
        {answer, _, _Answer} ->
            {answer, #{}};
        {hangup, Reason} ->
            {Code, Txt} = SrvId:error_code(Reason),
            {hangup, #{code=>Code, reason=>Txt}};
        _ ->
        	ignore
    end,
    case Send of
        {EvType, Body} ->
            send_event(SrvId, call, CallId, EvType, Body);
        ignore ->
            ok
    end,
    {ok, Call}.



%% ===================================================================
%% Internal
%% ===================================================================



