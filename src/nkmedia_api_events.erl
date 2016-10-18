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

-module(nkmedia_api_events).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([event/3, session_down/2]).
-export([send_event/5, send_event/6]).

-include_lib("nkservice/include/nkservice.hrl").
-include_lib("nksip/include/nksip.hrl").



%% ===================================================================
%% Callbacks
%% ===================================================================

%% @private
-spec event(nkmedia_session:id(), nkmedia_session:event(),
            nkmedia_session:session()) ->
	{ok, nkmedia_session:session()}.

event(SessId, {answer, Answer}, Session) ->
    do_send_event(SessId, answer, #{answer=>Answer}, Session);

event(SessId, {type, Type, Ext}, Session) ->
    do_send_event(SessId, type, Ext#{type=>Type}, Session);

event(SessId, {candidate, #candidate{last=true}}, Session) ->
    do_send_event(SessId, candidate_end, #{}, Session);

event(SessId, {candidate, #candidate{a_line=Line, m_id=Id, m_index=Index}}, Session) ->
    Data = #{sdpMid=>Id, sdpMLineIndex=>Index, candidate=>Line},
    do_send_event(SessId, candidate, Data, Session);

event(SessId, {info, Info, Meta}, Session) ->
    do_send_event(SessId, info, Meta#{info=>Info}, Session);

event(SessId, {stop, Reason}, #{srv_id:=SrvId}=Session) ->
    {Code, Txt} = nkservice_util:error_code(SrvId, Reason),
    do_send_event(SessId, destroyed, #{code=>Code, reason=>Txt}, Session);

event(_SessId, _Event, Session) ->
    {ok, Session}.



%% @private
-spec session_down(nkservice:id(), nkmedia_session:id()) ->
    ok.

session_down(SrvId, SessId) ->
    {Code, Txt} = nkservice_util:error_code(SrvId, process_down),
    send_event(SrvId, session, SessId, destroyed, #{code=>Code, reason=>Txt}).



%% ===================================================================
%% Internal
%% ===================================================================

%% @doc Sends an event
-spec send_event(nkservice:id(), atom(), binary(), atom(), map()) ->
    ok.

send_event(SrvId, Class, Id, Type, Body) ->
    send_event(SrvId, Class, Id, Type, Body, all).


%% @doc Sends an event
-spec send_event(nkservice:id(), atom(), binary(), atom(), map(), pid()) ->
    ok.

send_event(SrvId, Class, Id, Type, Body, Pid) ->
    lager:notice("MEDIA EVENT (~s:~s:~s): ~p", [Class, Type, Id, Body]),
    RegId = #reg_id{
        srv_id = SrvId,     
        class = <<"media">>, 
        subclass = nklib_util:to_binary(Class),
        type = nklib_util:to_binary(Type),
        obj_id = Id
    },
    nkservice_events:send(RegId, Body, Pid).


%% @private
do_send_event(SessId, Type, Body, #{srv_id:=SrvId}=Session) ->
    send_event(SrvId, session, SessId, Type, Body),
    {ok, Session}.



