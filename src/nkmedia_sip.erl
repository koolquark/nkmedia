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

-export([start/0, stop/0]).
-export([sip_invite/2, sip_reinvite/2, sip_bye/2]).


%% ===================================================================
%% Types
%% ===================================================================



%% ===================================================================
%% Public functions
%% ===================================================================


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


stop() ->
	nkservice:stop(nkmedia_sip).



% start() ->
%     Host = nkmedia_app:get(local_host),
%     {ok, Ip} = nklib_util:to_ip(Host),
%     %% Avoid openning 5060 but open a random port
%     Dummy = case gen_udp:open(5060, [{ip, Ip}]) of
%         {ok, Socket} -> Socket;
%         {error, _} -> none
%     end,
%     Sip = <<"sip:", Host/binary>>,
%     Opts = #{
%         class => nkmedia_sip,
%         plugins => [nkmedia_sip, nksip],
%         sip_listen => Sip
%     },
%     {ok, bnulhwa} = nkservice:start(nkmedia_sip, Opts),
%     case Dummy of
%         error -> ok;
%         DummySocket -> gen_udp:close(DummySocket)
%     end,
%     [Listener] = nkservice:get_listeners(bnulhwa, nksip),
%     {ok, {nksip_protocol, udp, Ip, Port}} = nkpacket:get_local(Listener),
%     nkmedia_app:put(sip_port, Port).



%% ===================================================================
%% SIP callbacks
%% ===================================================================


sip_invite(Req, _Call) ->
    {ok, UA} = nksip_request:header(<<"user-agent">>, Req),
    {ok, AOR} = nksip_request:meta(aor, Req),
    {ok, SDP} =  nksip_request:meta(body, Req),
    HasSDP = nksip_sdp:is_sdp(SDP),
    case {UA, AOR} of
        {[<<"FreeSWITCH", _/binary>>], {sip, CallId, _Domain}} when HasSDP ->
            {ok, Handle} = nksip_request:get_handle(Req),
            {ok, Dialog} = nksip_dialog:get_handle(Req),
            case nkmedia_fs_channel:sip_inbound_invite(CallId, Handle, Dialog, SDP) of
                ok -> 
                    {reply, ringing};
                {error, Error} ->
                    lager:warning("FS SIP Call error: ~p", [Error]),
                    {reply, internal_error}
            end;
        _ ->
            {reply, decline}
    end.


sip_reinvite(_Req, _Call) ->
    lager:warning("NcsMEDIA ignoring REINVITE"),
    {reply, decline}.


sip_bye(Req, _Call) ->
    {ok, UA} = nksip_request:header(<<"user-agent">>, Req),
    case UA of
        [<<"FreeSWITCH", _/binary>>] ->
            {ok, {sip, User, _}} = nksip_request:meta(aor, Req),
            lager:info("BYE FROM FS: ~s", [User]);
        _ ->
            {ok, Dialog} = nksip_dialog:get_handle(Req),
            gotools_call_fs:sip_bye(Dialog),
            ok
    end,
    {reply, ok}.
    
    
