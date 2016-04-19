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

%% @doc NkMEDIA SIP utilities

-module(nkmedia_sip).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/0, stop/0, register_call_id/2]).
-export([sip_invite/2, sip_reinvite/2, sip_bye/2]).


%% ===================================================================
%% Types
%% ===================================================================



%% ===================================================================
%% Public functions
%% ===================================================================


%% @private
%% Starts a nkservice called 'nkmedia_sip', listening for sip
start() ->
    Port = nkmedia_app:get(sip_port),
    Dummy = case Port of
        0 ->
            %% Avoid openning 5060 but open a random port
            case gen_udp:open(5060, [{ip, {0,0,0,0}}]) of
                {ok, Socket} -> Socket;
                {error, _} -> false
            end;
        _ ->
            false
    end,
    Opts = #{
        class => nkmedia_sip,
        plugins => [nkmedia_sip, nksip, nksip_trace, nksip_uac_auto_auth],
        nksip_trace => {console, all},
        sip_listen => <<"sip:all:", (nklib_util:to_binary(Port))/binary>>
    },
    {ok, bnulhwa} = nkservice:start(nkmedia_sip, Opts),
    case Dummy of
        false -> ok;
        _ -> gen_udp:close(Dummy)
    end,
    [Listener] = nkservice:get_listeners(bnulhwa, nksip),
    {ok, {nksip_protocol, udp, _Ip, Port2}} = nkpacket:get_local(Listener),
    nkmedia_app:put(sip_port, Port2).


%% @private
stop() ->
	nkservice:stop(nkmedia_sip).


%% @private
register_call_id(Module, CallId) ->
    nklib_proc:put({?MODULE, call, CallId}, Module).







%% ===================================================================
%% SIP callbacks
%% ===================================================================


sip_invite(Req, Call) ->
    {ok, AOR} = nksip_request:meta(aor, Req),
    {ok, Dialog} = nksip_dialog:get_handle(Req),
    case AOR of
        {sip, <<"nkmedia-", CallId/binary>>, _Domain} ->
            case nklib_proc:values({?MODULE, call, CallId}) of
                [{Module, Pid}|_] ->
                    nklib_proc:put({?MODULE, dialog, Dialog}, Module, Pid),
                    case erlang:function_exported(Module, sip_invite, 3) of
                        true ->
                            Module:sip_invite(Pid, Req, Call);
                        false ->
                            lager:error("Unrecognized NkMEDIA SIP Call"),
                            {reply, decline}
                    end;
                [] ->
                    lager:error("Error decoding SIP PID"),
                    {reply, internal_error}
            end;
        _ ->
            {reply, decline}
    end.


sip_reinvite(Req, Call) ->
    {ok, Dialog} = nksip_dialog:get_handle(Req),
    case nklib_proc:values({?MODULE, dialog, Dialog}) of
        [{Module, Pid}|_] ->
            case erlang:function_exported(Module, sip_reinvite, 3) of
                true ->
                    Module:sip_reinvite(Pid, Req, Call);
                false ->
                    lager:warning("NcsMEDIA ignoring REINVITE"),
                    {reply, decline}
            end;
        [] ->
            lager:warning("NcsMEDIA ignoring REINVITE"),
            {reply, decline}
    end.


sip_bye(Req, Call) ->
    {ok, Dialog} = nksip_dialog:get_handle(Req),
    case nklib_proc:values({?MODULE, dialog, Dialog}) of
        [{Module, Pid}|_] ->
            case erlang:function_exported(Module, sip_bye, 3) of
                true ->
                    Module:sip_bye(Pid, Req, Call);
                false ->
                    lager:warning("NcsMEDIA ignoring BYE"),
                    {reply, ok}
            end;
        [] ->
            lager:warning("NcsMEDIA ignoring BYE"),
            {reply, ok}
    end.
    
    
