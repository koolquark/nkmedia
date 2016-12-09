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

-module(nkmedia_session_api_events).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([event/3, event_session_down/3]).

-include_lib("nkservice/include/nkservice.hrl").
-include_lib("nksip/include/nksip.hrl").



%% ===================================================================
%% Callbacks
%% ===================================================================

%% @private
-spec event(nkmedia_session:id(), nkmedia_session:event(),
            nkmedia_session:session()) ->
	{ok, nkmedia_session:session()}.

event(SessId, created, Session) ->
    Data = nkmedia_session_api_syntax:get_info(Session),
    send_event(SessId, created, Data, Session);

event(SessId, {answer, Answer}, Session) ->
    send_event(SessId, answer, #{answer=>Answer}, Session);

event(SessId, {type, Type, Ext}, Session) ->
    send_event(SessId, type, Ext#{type=>Type}, Session);

event(SessId, {candidate, #candidate{last=true}}, Session) ->
    send_event(SessId, candidate_end, #{}, Session);

event(SessId, {candidate, #candidate{a_line=Line, m_id=Id, m_index=Index}}, Session) ->
    Data = #{sdpMid=>Id, sdpMLineIndex=>Index, candidate=>Line},
    send_event(SessId, candidate, Data, Session);

event(SessId, {status, Update}, Session) ->
    send_event(SessId, status, Update, Session);

event(SessId, {info, Info, Meta}, Session) ->
    send_event(SessId, info, Meta#{info=>Info}, Session);

% The 'destroyed' event is only internal, to remove things, etc.
event(SessId, {stopped, Reason}, #{srv_id:=SrvId}=Session) ->
    {Code, Txt} = nkservice_util:error_code(SrvId, Reason),
    send_event(SessId, destroyed, #{code=>Code, reason=>Txt}, Session);

event(SessId, {record, Info}, Session) ->
    send_event(SessId, record, #{timelog=>Info}, Session);

event(_SessId, _Event, Session) ->
    {ok, Session}.


%% @private
-spec event_session_down(nkservice:id(), nkmedia_session:id(), term()) ->
    ok.

event_session_down(SrvId, SessId, ConnId) ->
    {Code, Txt} = nkservice_util:error_code(SrvId, process_down),
    Fake = #{
        srv_id => SrvId, 
        user_session => ConnId,
        session_events => [<<"destroyed">>]
    },
    send_event(SessId, destroyed, #{code=>Code, reason=>Txt}, Fake).


%% ===================================================================
%% Internal
%% ===================================================================


%% @doc Sends an event
-spec send_event(nkmedia_session:id(), nkservice_events:type(), 
                 nkservice_events:body(), nkmedia_session:session()) ->
    ok.

%% @private
send_event(SessId, Type, Body, #{srv_id:=SrvId}=Session) ->

    Type2 = nklib_util:to_binary(Type),
    Event = #event{
        srv_id = SrvId,     
        class = <<"media">>, 
        subclass = <<"session">>,
        type = Type2,
        obj_id = SessId,
        body = Body
    },
    case Session of
        #{session_events:=Events, user_session:=ConnId} ->
            case lists:member(Type2, Events) of
                true ->
                    Event2 = case Session of
                        #{session_events_body:=Body2} ->
                            Event#event{body=maps:merge(Body, Body2)};
                        _ ->
                            Event
                    end,
                    nkservice_api_server:event(ConnId, Event2);
                false ->
                    ok
            end;
        _ ->
            ok
    end,
    nkservice_events:send(Event),
    {ok, Session}.


