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

%% @doc Plugin implementing a SIP server and client
-module(nkmedia_sip_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_start/2, plugin_stop/2]).
-export([sip_bye/2]).
-export([nkmedia_session_invite/4, nkmedia_session_event/3]).


%% ===================================================================
%% Types
%% ===================================================================




%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia, nksip].


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA SIP (~s) starting", [Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA SIP (~p) stopping", [Name]),
    {ok, Config}.



%% ===================================================================
%% Offering Callbacks
%% ===================================================================







%% ===================================================================
%% Implemented Callbacks
%% ===================================================================


%% @private Called when a BYE is received from SIP
sip_bye(Req, _Call) ->
	{ok, Dialog} = nksip_dialog:get_handle(Req),
	nkmedia_sip:sip_bye(Dialog),
	continue.


%% @private
nkmedia_session_invite(SessId, {nkmedia_sip, Uri, Opts}, Offer, Session) ->
    #{srv_id:=SrvId} = Session,
    case Offer of
        #{sdp_type:=sip, sdp:=SDP} ->
            ok = nkmedia_sip:send_invite(SrvId, SessId, Uri, Opts#{sdp=>SDP}),
            {async, undefined, Session#{nkmedia_sip_out=>true}};
        _ ->
            {hangup, <<"Invalid SIP SDP">>, Session}
    end;

nkmedia_session_invite(_SessId, _Dest, _Offer, _Session) ->
	continue.


%% @private
nkmedia_session_event(SessId, {hangup, _}, #{nkmedia_sip_out:=true}) ->
    nkmedia_sip:send_hangup(SessId),
    continue;

nkmedia_session_event(_SessId, _Event, _Session) ->
    continue.





