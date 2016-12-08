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

%% @doc NkMEDIA Core service

-module(nkmedia_core).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/0, stop/0, register_session/2, invite/2]).
-export([plugin_listen/2]).
-export([sip_route/5]).
-export([sip_invite/2, sip_reinvite/2, sip_bye/2, sip_register/2]).

-define(WS_TIMEOUT, 5*60*1000).

%% ===================================================================
%% Types
%% ===================================================================



%% ===================================================================
%% Public functions
%% ===================================================================


%% @private
%% Starts a nkservice called 'nkmedia_core'
start() ->
    %% Avoid openning 5060 but open a random port
    Dummy = case gen_udp:open(5060, [{ip, {0,0,0,0}}]) of
        {ok, Socket} -> Socket;
        {error, _} -> false
    end,
    Opts = #{
        class => nkmedia_core,
        plugins => [?MODULE, nksip, nksip_uac_auto_auth, nksip_registrar],
        nksip_trace => {console, all},    % Add nksip_trace
        sip_listen => <<"sip:all">>
    },
    {ok, SrvId} = nkservice:start(nkmedia_core, Opts),
    case Dummy of
        false -> ok;
        _ -> gen_udp:close(Dummy)
    end,
    [Listener] = nkservice:get_listeners(SrvId, nksip),
    {ok, {nksip_protocol, udp, _Ip, Port2}} = nkpacket:get_local(Listener),
    nkmedia_app:put(sip_port, Port2).


%% @private
stop() ->
	nkservice:stop(nkmedia_core).


%% @private
register_session(SessId, Module) ->
    nklib_proc:put({?MODULE, session, SessId}, Module).


%% @private
invite(Contact, #{sdp:=SDP}) ->
    SDP2 = nksip_sdp:parse(SDP),
    Opts = [{body, SDP2}, auto_2xx_ack, {meta, [body]}],
    nksip_uac:invite(nkmedia_core, Contact, Opts).




%% ===================================================================
%% Plugin functions
%% ===================================================================



% plugin_syntax() ->
%     nkpacket:register_protocol(nkmedia, nkmedia_protocol_server),
%     #{
%         admin_url => fun parse_listen/3,
%         admin_pass => binary
%     }.


plugin_listen(Config, _Service) ->
    Listen = maps:get(admin_url, Config, []),
    Opts = #{
        class => nkmedia_admin,
        idle_timeout => ?WS_TIMEOUT
    },                                  
    [{Conns, maps:merge(ConnOpts, Opts)} || {Conns, ConnOpts} <- Listen].




%% ===================================================================
%% SIP callbacks
%% ===================================================================


sip_route(_Scheme, _User, _Domain, _Req, _Call) ->
    process.


sip_invite(Req, _Call) ->
    apply_mod(Req, nkmedia_sip_invite).


sip_reinvite(Req, _Call) ->
    apply_mod(Req, nkmedia_sip_reinvite).


sip_bye(Req, _Call) ->
    apply_mod(Req, nkmedia_sip_bye).

   
sip_register(Req, _Call) ->
    {ok, Domain} = nksip_request:meta(from_domain, Req),
    case catch binary_to_existing_atom(Domain, latin1) of
        {'EXIT', _} ->
            {reply, forbidden};
        Module ->
            {ok, User} = nksip_request:meta(from_user, Req),
            Module:nkmedia_sip_register(User, Req)
    end.





%% ===================================================================
%% Internal
%% ===================================================================




apply_mod(Req, Fun) ->
    case nksip_request:meta(aor, Req) of
        {ok, {sip, User, _}} ->
            case binary:split(User, <<"-">>) of
                [Head, Id] ->
                    case catch binary_to_existing_atom(Head, latin1) of
                        {'EXIT', _} -> 
                            {reply, forbidden};
                        Mod -> 
                            case erlang:function_exported(Mod, Fun, 2) of
                                true ->
                                    apply(Mod, Fun, [Id, Req]);
                                false ->
                                    {reply, forbidden}
                            end
                    end;
                _ ->
                    {reply, forbidden}
            end;
        _ ->
            {reply, forbidden}
    end.



