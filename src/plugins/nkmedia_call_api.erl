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
-module(nkmedia_call_api).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([cmd/4]).
-export([nkmedia_call_invite/5, nkmedia_call_resolve/3, 
         nkmedia_call_cancel/3, nkmedia_call_reg_event/4]).
-export([api_server_reg_down/3, api_server_handle_cast/2]).

-include_lib("nkservice/include/nkservice.hrl").


%% ===================================================================
%% Commands
%% ===================================================================


%% Registers the call session with the API session (to monitor DOWNs)
%% as (nkmedia_call, CallId, CallPid)
%% Registers the API session with the media session (as nkmedia_api, pid())
%% Subscribes to events
cmd(<<"call">>, <<"start">>, Req, State) ->
    #api_req{srv_id=SrvId, data=Data, user=User, session=UserSession} = Req,
    #{callee:=Callee} = Data,
    Config = Data#{
        register => {nkmedia_api, self()},
        user_id => User,
        user_session => UserSession
    },
    {ok, CallId, Pid} = nkmedia_call:start(SrvId, Callee, Config),
    nkservice_api_server:register(self(), {nkmedia_call, CallId, Pid}), 
    case maps:get(subscribe, Data, true) of
        true ->
            % In case of no_destination, the call will wait 100msecs before stop
            RegId = call_reg_id(SrvId, <<"*">>, CallId),
            Body = maps:get(events_body, Data, #{}),
            nkservice_api_server:register_events(self(), RegId, Body);
        false ->
            ok
    end,
    {ok, #{call_id=>CallId}, State};

cmd(<<"call">>, <<"ringing">>, #api_req{data=Data}, State) ->
    #{call_id:=CallId} = Data,
    Answer = maps:get(answer, Data, #{}),
    lager:error("CALL RINGING2: ~p", [CallId]),
    case nkmedia_call:ringing(CallId, {nkmedia_api, self()}, Answer) of
        ok ->
            {ok, #{}, State};
        {error, invite_not_found} ->
            {error, already_answered, State};
        {error, call_not_found} ->
            {error, call_not_found, State};
        {error, Error} ->
            lager:warning("Error in call ringing: ~p", [Error]),
            {error, call_error, State}
    end;

cmd(<<"call">>, <<"answered">>, #api_req{srv_id=SrvId, data=Data}, State) ->
    #{call_id:=CallId} = Data,
    Answer = maps:get(answer, Data, #{}),
    case nkmedia_call:answered(CallId, {nkmedia_api, self()}, Answer) of
        ok ->
            % We are the 'B' leg of the call, let's register with it
            % and start events
            {ok, _CallPid} = nkmedia_call:register(CallId, {nkmedia_api, self()}),
            case maps:get(subscribe, Data, true) of
                true ->
                    RegId = call_reg_id(SrvId, <<"*">>, CallId),
                    Body = maps:get(events_body, Data, #{}),
                    nkservice_api_server:register_events(self(), RegId, Body);
                false -> 
                    ok
            end,
            {ok, #{}, State};
        {error, invite_not_found} ->
            {error, already_answered, State};
        {error, call_not_found} ->
            {error, call_not_found, State};
        {error, Error} ->
            lager:warning("Error in call answered: ~p", [Error]),
            {error, call_error, State}
    end;

cmd(<<"call">>, <<"rejected">>, #api_req{data=Data}, State) ->
    #{call_id:=CallId} = Data,
    case nkmedia_call:rejected(CallId, {nkmedia_api, self()}) of
        ok ->
            {ok, #{}, State};
        {error, invite_not_found} ->
            {ok, #{}, State};
        {error, call_not_found} ->
            {error, call_not_found, State};
        {error, Error} ->
            lager:warning("Error in call answered: ~p", [Error]),
            {error, call_error, State}
    end;

cmd(<<"call">>, <<"hangup">>, #api_req{data=Data}, State) ->
    #{call_id:=CallId} = Data,
    Reason = maps:get(reason, Data, <<"user_hangup">>),
    case nkmedia_call:hangup(CallId, Reason) of
        ok ->
            {ok, #{}, State};
        {error, call_not_found} ->
            {error, call_not_found, State};
        {error, Error} ->
            lager:warning("Error in call answered: ~p", [Error]),
            {error, call_error, State}
    end;

cmd(_SrvId, Other, _Data, State) ->
    {error, {unknown_command, Other}, State}.



%% ===================================================================
%% Call callbacks
%% ===================================================================


%% @private
nkmedia_call_resolve(Dest, Acc, Call) ->
    Acc2 = case maps:get(type, Call, user) of
        user ->
            Acc ++ [
                #{dest=>{nkmedia_api, {user, Pid}}} 
                || {_, Pid} <- nkservice_api_server:find_user(Dest)
            ];
        _ ->
            Acc
    end,
    Acc3 = case maps:get(type, Call, session) of
        session ->
            Acc2 ++ case nkservice_api_server:find_session(Dest) of
                {ok, _User, Pid} ->
                    [#{dest=>{nkmedia_api, {session, Pid}}}];
                _ ->
                    []
            end;
        _ ->
            Acc2
    end,
    {ok, Acc3, Call}.


%% @private
%% Type would be user or session
nkmedia_call_invite(CallId, {nkmedia_api, {Type, Pid}}, Offer, Meta, Call) ->
    Data1 = #{call_id=>CallId, type=>Type},
    Data2 = case is_map(Offer) andalso map_size(Offer) > 0 of
        true -> Data1#{offer=>Offer};
        false -> Data1
    end,
    Data3 = case is_map(Meta) andalso map_size(Meta) > 0 of
        true -> Data2#{meta=>Meta};
        false -> Data2
    end,
    case nkservice_api_server:cmd(Pid, media, call, invite, Data3) of
        {ok, <<"ok">>, #{<<"retry">>:=Retry}} ->
            case is_integer(Retry) andalso Retry>0 of
                true -> {retry, Retry, Call};
                false -> {remove, Call}
            end;
        {ok, <<"ok">>, _} ->
            % The link is {nkmedia_api, Pid}
            {ok, {nkmedia_api, Pid}, Call};
        {ok, <<"error">>, _} ->
            {remove, Call};
        {error, _Error} ->
            {remove, Call}
    end;

nkmedia_call_invite(_CallId, _Dest, _Offer, _Meta, Call) ->
    {remove, Call}.


%% @private
nkmedia_call_cancel(CallId, {nkmedia_api, Pid}, #{srv_id:=SrvId}=Call) ->
    lager:error("CALL CANCELLED: ~p", [Pid]),
    {Code, Text} = nkservice_util:error_code(SrvId, originator_cancel),
    Body = #{code=>Code, reason=>Text},
    RegId = call_reg_id(SrvId, hangup, CallId),
    nkservice_events:send(RegId, Body, Pid),
    {ok, Call};

nkmedia_call_cancel(_CallId, _Link, Call) ->
    {ok, Call}.


%% @private
nkmedia_call_reg_event(CallId, {nkmedia_api, Pid}, {hangup, _Reason}, Call) ->
    gen_server:cast(Pid, {nkmedia_api_call_hangup, CallId, self()}),
    {ok, Call};

nkmedia_call_reg_event(_CallId, _RegId, _Event, Call) ->
    {ok, Call}.


%% @private
call_reg_id(SrvId, Type, CallId) ->
    #reg_id{
        srv_id = SrvId,     
        class = <<"media">>, 
        subclass = <<"call">>,
        type = nklib_util:to_binary(Type),
        obj_id = CallId
    }.


%% ===================================================================
%% API server callbacks
%% ===================================================================


%% @private Called from nkmedia_callbacks, if a registered link is down
api_server_reg_down({nkmedia_call, CallId, _CallPid}, Reason, State) ->
    lager:warning("API Server: Call ~s is down: ~p", [CallId, Reason]),
    {ok, State};

api_server_reg_down(_Link, _Reason, _State) ->
    continue.


%% @private
api_server_handle_cast({nkmedia_api_call_hangup, CallId, Pid}, State) ->
    nkservice_api_server:unregister(self(), {nkmedia_call, CallId, Pid}),
    {ok, State};

api_server_handle_cast(_Msg, _State) ->
    continue.



