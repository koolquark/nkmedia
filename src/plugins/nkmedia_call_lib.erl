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

%% @doc Call Li
%%
%% Typical call process:
%% - A session is started
%% - A call is started, linking it with the session (using session_id)
%% - The call registers itself with the session
%% - When the call has an answer, it is captured in nkmedia_call_reg_event
%%   (nkmedia_callbacks) and sent to the session. Same with hangups
%% - If the session stops, it is captured in nkmedia_session_reg_event
%% - When the call stops, the called process must detect it in nkmedia_call_reg_event

-module(nkmedia_call_lib).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([resolve/4, invite/4, cancel/3]).
% -include("../../include/nkmedia.hrl").
% -include("../../include/nkmedia_call.hrl").
% -include_lib("nkservice/include/nkservice.hrl").



%% ===================================================================
%% Types
%% ===================================================================




%% ===================================================================
%% Public
%% ===================================================================



%% @private
resolve(User, user, Acc, Call) ->
    Dests = [
        #{dest=>{nkmedia_api_user, SessId, Pid}} 
        || {SessId, Pid} <- nkservice_api_server:find_user(User)
    ],
    {ok, Acc++Dests, Call};

resolve(Callee, session, Acc, Call) ->
    Callee2 = nklib_util:to_binary(Callee),
    Dests = case nkservice_api_server:find_session(Callee2) of
        {ok, _User, Pid} ->
            [#{dest=>{nkmedia_api_session, Callee2, Pid}}];
        not_found ->
            []
    end,
    {ok, Acc++Dests, Call};

resolve(Callee, all, Acc, Call) ->
    {ok, Acc2, Call2} = resolve(Callee, user, Acc, Call),
    resolve(Callee, session, Acc2, Call2);

resolve(_Callee, _Type, Acc, Call) ->
    {ok, Acc, Call}.



%% @private Sends a call INVITE over the API (for user or session types)
invite({nkmedia_api_user, Pid}, Caller, CallId, Call) ->
    do_invite(Pid, user, Caller, CallId, Call);

invite({nkmedia_api_session, Pid}, Caller, CallId, Call) ->
    do_invite(Pid, user, Caller, CallId, Call);

invite(_Dest, _Caller, _CallId, Call) ->
    {remove, Call}.


%% @private
cancel(_CallId, _CalleeId, #{srv_id:=_SrvId}=Call) ->
    % lager:error("CALL CANCELLED"),
    % {Code, Text} = nkservice_util:error_code(SrvId, originator_cancel),
    % Body = #{code=>Code, reason=>Text},
    % RegId = call_reg_id(SrvId, hangup, CallId),
    % case nkservice_api_server:find_session(CalleeId) of
    %     {ok, _User, Pid} ->
    %         % Send the event only to this session
    %         nkservice_events:send(RegId, Body, Pid);
    %     not_found ->
    %         lager:warning("Call cancelled for no sesssion: ~s", [CalleeId])
    % end,
    {ok, Call}.


%% ===================================================================
%% Internal
%% ===================================================================

do_invite(Pid, Type, Caller, CallId, Call) ->
    Data = Caller#{call_id=>CallId, type=>Type},
    case nkservice_api_server:cmd(Pid, media, call, invite, Data) of
        {ok, <<"ok">>, #{<<"retry">>:=Retry}} ->
            case is_integer(Retry) andalso Retry>0 of
                true -> {retry, Retry, Call};
                false -> {remove, Call}
            end;
        {ok, <<"ok">>, _} ->
            % SessId will be our CalleeId
            {ok, Call};
        {ok, <<"error">>, _} ->
            {remove, Call};
        {error, _Error} ->
            {remove, Call}
    end.


