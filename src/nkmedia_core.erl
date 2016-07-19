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
-export([plugin_listen/2, plugin_start/2, plugin_stop/2]).
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
        % nksip_trace => {console, all},    % Add nksip_trace
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


plugin_start(Config, _Service) ->
    lager:info("NkMEDIA Core Service starting"),
    {ok, Config}.


plugin_stop(Config, _Service) ->
    lager:info("NkMEDIA Core Service stopping"),
    {ok, Config}.




%% ===================================================================
%% SIP callbacks
%% ===================================================================


% sip_route(sip, User, <<"nkmedia">>, _Req, _Call) ->
%     case nksip_registrar:find(test, sip, User, <<"nkmedia">>) of
%         [Uri|_] ->
%             {proxy, Uri};
%         [] ->
%             {reply, forbidden}
%     end;

sip_route(_Scheme, _User, _Domain, _Req, _Call) ->
    % lager:warning("ROUTE: ~p, ~p, ~p", [Scheme, User, Domain]),
    process.


sip_invite(Req, _Call) ->
    {ok, AOR} = nksip_request:meta(aor, Req),
    {ok, _Dialog} = nksip_dialog:get_handle(Req),
    case AOR of
        % {sip, <<"nkmedia-", SessId/binary>>, _Domain} ->
        %     case nklib_proc:values({?MODULE, session, SessId}) of
        %         [{Module, Pid}|_] ->
        %             nklib_proc:put({?MODULE, dialog, Dialog}, Module, Pid),
        %             case erlang:function_exported(Module, sip_invite, 3) of
        %                 true ->
        %                     Module:sip_invite(Pid, Req, Call);
        %                 false ->
        %                     lager:notice("Unmanaged NkMEDIA Core SIP INVITE"),
        %                     {reply, decline}
        %             end;
        %         [] ->
        %             lager:notice("Unmanaged NkMEDIA Core SIP INVITE"),
        %             {reply, internal_error}
        %     end;
        {sip, User, Domain} ->
            case catch binary_to_existing_atom(Domain, latin1) of
                {'EXIT', _} ->
                    {reply, forbidden};
                Module ->
                    case erlang:function_exported(Module, nkmedia_sip_invite, 2) of
                        true ->
                            Module:nkmedia_sip_invite(User, Req);
                        false ->
                            {reply, forbidden}
                    end
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


% parse_listen(_Key, [{[{_, _, _, _}|_], Opts}|_]=Multi, _Ctx) when is_map(Opts) ->
%     {ok, Multi};

% parse_listen(_Key, Url, _Ctx) ->
%     Opts = #{valid_schemes=>[nkmedia], resolve_type=>listen},
%     case nkpacket:multi_resolve(Url, Opts) of
%         {ok, List} -> {ok, List};
%         _ -> error
%     end.






