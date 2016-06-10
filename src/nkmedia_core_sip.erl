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

-module(nkmedia_core_sip).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/0, stop/0, register_session/2, invite/2]).
-export([sip_invite/2, sip_reinvite/2, sip_bye/2, sip_register/2]).


%% ===================================================================
%% Types
%% ===================================================================



%% ===================================================================
%% Public functions
%% ===================================================================


%% @private
%% Starts a nkservice called 'nkmedia_core_sip', listening for sip
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
        class => nkmedia_core_sip,
        plugins => [?MODULE, nksip, nksip_uac_auto_auth, nksip_registrar, nksip_trace],
        nksip_trace => {console, all},
        sip_listen => <<"sip:all:", (nklib_util:to_binary(Port))/binary>>
    },
    {ok, SrvId} = nkservice:start(nkmedia_core_sip, Opts),
    case Dummy of
        false -> ok;
        _ -> gen_udp:close(Dummy)
    end,
    [Listener] = nkservice:get_listeners(SrvId, nksip),
    {ok, {nksip_protocol, udp, _Ip, Port2}} = nkpacket:get_local(Listener),
    nkmedia_app:put(sip_port, Port2).


%% @private
stop() ->
	nkservice:stop(nkmedia_core_sip).


%% @private
register_session(SessId, Module) ->
    nklib_proc:put({?MODULE, session, SessId}, Module).


%% @private
invite(Contact, #{sdp:=SDP}) ->
    SDP2 = nksip_sdp:parse(SDP),
    Opts = [{body, SDP2}, auto_2xx_ack, {meta, [body]}],
    nksip_uac:invite(nkmedia_core_sip, Contact, Opts).





%% ===================================================================
%% SIP callbacks
%% ===================================================================


sip_invite(Req, Call) ->
    {ok, AOR} = nksip_request:meta(aor, Req),
    {ok, Handle} = nksip_request:get_handle(Req),
    {ok, Dialog} = nksip_dialog:get_handle(Req),
    case AOR of
        {sip, <<"nkmedia-", SessId/binary>>, _Domain} ->
            case nklib_proc:values({?MODULE, session, SessId}) of
                [{Module, Pid}|_] ->
                    nklib_proc:put({?MODULE, dialog, Dialog}, Module, Pid),
                    case erlang:function_exported(Module, sip_invite, 3) of
                        true ->
                            Module:sip_invite(Pid, Req, Call);
                        false ->
                            lager:notice("Unmanaged NkMEDIA Core SIP INVITE"),
                            {reply, decline}
                    end;
                [] ->
                    lager:notice("Unmanaged NkMEDIA Core SIP INVITE"),
                    {reply, internal_error}
            end;
        {sip, <<"janus-", SessId/binary>>, _Domain} ->
            {ok, Body} = nksip_request:body(Req),
            SDP = nksip_sdp:unparse(Body),
            case 
                nkmedia_janus_op:sip_offer(SessId, Handle, Dialog, #{sdp=>SDP})
            of
                ok ->
                    noreply;
                {error, _Error} ->
                    {reply, forbidden}
            end;
        _ ->
            lager:warning("Unexpected NkMEDIA Core SIP: ~p", [AOR]),
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
                    lager:notice("Unmanaged NkMEDIA Core SIP ReINVITE"),
                    {reply, decline}
            end;
        [] ->
            lager:notice("Unmanaged NkMEDIA Core SIP ReINVITE"),
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
                    lager:info("Unmanaged NkMEDIA Core SIP BYE"),
                    {reply, ok}
            end;
        [] ->
            {reply, ok}
    end.
    
    
sip_register(Req, _Call) ->
    case nksip_request:meta(from_user, Req) of
        {ok, <<"janus-", Id/binary>>} ->
            case nksip_request:meta(contacts, Req) of
                {ok, [Contact]} ->
                    case catch 
                        nkmedia_janus_op:sip_registered(Id, Contact) 
                    of
                        true -> 
                            lager:info("Core SIP Janus reg: ~s", [Id]),
                            continue;
                        _Error ->
                            % lager:info("Core SIP janus reg error: ~p (~s)", 
                            %            [_Error, Id]),
                            {reply, forbidden}
                    end;
                Other ->
                    lager:warning("Core SIP: invalid Janus Contact: ~p", [Other]),
                    {reply, forbidden}
            end;
        _ ->
            lager:warning("UNEXPECTED SIP CORE REG"),
            {reply, forbidden}
    end.







