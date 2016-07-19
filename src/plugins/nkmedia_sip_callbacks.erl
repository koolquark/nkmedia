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
-export([error_code/1]).
-export([nkmedia_sip_invite/4]).
-export([sip_get_user_pass/4, sip_authorize/3]).
-export([sip_invite/2, sip_reinvite/2, sip_cancel/3, sip_bye/2]).
-export([nkmedia_call_resolve/3, nkmedia_call_invite/4, nkmedia_call_cancel/3,
         nkmedia_call_reg_event/4]).


-export([nkmedia_session_invite/4, nkmedia_session_event/3]).

-include_lib("nklib/include/nklib.hrl").


%% ===================================================================
%% Types
%% ===================================================================


-type continue() :: continue | {continue, list()}.




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

-spec nkmedia_sip_invite(nkmnedia_session:id(), nksip:aor(), 
                         nkmedia:offer(), nksip:call()) ->
    ok | {rejected, nkservice:error()} | continue().

nkmedia_sip_invite(_SrvId, _AOR, _Offer, _Call) ->
    {rejected, <<"Not Implemented">>}.






%% ===================================================================
%% Implemented Callbacks - nksip
%% ===================================================================


%% @private
sip_get_user_pass(_User, _Realm, _Req, _Call) ->
    true.


%% @private
sip_authorize(_AuthList, _Req, _Call) ->
    ok.


%% @private
sip_invite(Req, Call) ->
    SrvId = nksip_call:srv_id(Call),
    {ok, AOR} = nksip_request:meta(aor, Req),
    {ok, Body} = nksip_request:meta(body, Req),
    Offer = case nksip_sdp:is_sdp(Body) of
        true -> #{sdp=>nksip_sdp:unparse(Body)};
        false -> #{}
    end,
    % {ok, Handle} = nksip_request:get_handle(Req),
    % {ok, Dialog} = nksip_dialog:get_handle(Req),
    % nklib_proc:put({nkmedia_sip, dialog, Dialog}, SessId),
    % nklib_proc:put({nkmedia_sip, cancel, Handle}, SessId),
    case SrvId:nkmedia_sip_invite(SrvId, AOR, Offer, Call) of
        ok ->
            noreply;
        {rejected, _Reason} ->
            {reply, decline}
    end.
        

%% @private
sip_reinvite(_Req, _Call) ->
    {reply, decline}.


%% @private
sip_cancel(InviteReq, _Request, _Call) ->
    {ok, Handle} = nksip_request:get_handle(InviteReq),
    case nklib_proc:values({nkmedia_sip, cancel, Handle}) of
        [{SessId, _}|_] ->
            nkmedia_session:stop(SessId, sip_cancel),
            ok;
        [] ->
            ok
    end.


%% @private Called when a BYE is received from SIP
sip_bye(Req, _Call) ->
	{ok, Dialog} = nksip_dialog:get_handle(Req),
    case nklib_proc:values({nkmedia_sip, dialog, Dialog}) of
        [{CallId, _SessPid}] ->
            nkmedia_call:hangup(CallId, sip_bye);
        [] ->
            lager:notice("Received SIP BYE for unknown session")
    end,
	continue.


%% ===================================================================
%% Implemented Callbacks
%% ===================================================================

% @private
error_code({sip_code, Code}) ->
    {1500, nklib_util:msg("SIP Code ~p", [Code])};

error_code(sip_bye)         -> {1501, <<"SIP Bye">>};
error_code(sip_cancel)      -> {1501, <<"SIP Cancel">>};
error_code(sip_no_sdp)      -> {1501, <<"SIP Missing SDP">>};
error_code(sip_send_error)  -> {1501, <<"SIP Send Error">>};
error_code(_) -> continue.


%% @private
nkmedia_call_resolve(Callee, Acc, #{srv_id:=SrvId}=Call) ->
    case maps:get(type, Call, nkmedia_sip) of
        nkmedia_sip ->
            Uris1 = case nklib_parse:uris(Callee) of
                error -> 
                    [];
                Parsed -> 
                    [U || #uri{scheme=S}=U <- Parsed, S==sip orelse S==sips]
            end,
            Uris2 = case binary:split(Callee, <<"@">>) of
                [User, Domain] ->
                    nksip_registrar:find(SrvId, sip, User, Domain) ++
                    nksip_registrar:find(SrvId, sips, User, Domain);
                _ ->
                    []
            end,
            DestExts = [#{dest=>{nkmedia_sip, U}} || U <- Uris1++Uris2],
            {continue, [Callee, Acc++DestExts, Call]};
        _ ->
            continue
    end.


%% @private
nkmedia_call_invite(CallId, {nkmedia_sip, Uri}, Offer, #{srv_id:=SrvId}=Call) ->
    Opts1 = case Offer of
        #{sdp:=SDP} -> #{sdp=>SDP};
        _ -> #{}
    end,
    case nkmedia_sip:send_invite(SrvId, CallId, Uri, Opts1) of
        {ok, ProcId} -> 
            {ok, ProcId, Call};
        {error, Error} ->
            lager:error("error sending sip: ~p", [Error]),
            {remove, Call}
    end;

nkmedia_call_invite(_CallId, _Dest, _Offer, _Call) ->
    continue.


%% @private
nkmedia_call_cancel(CallId, {nkmedia_sip, _Ref, _Pid}, _Call) ->
    nkmedia_sip:send_hangup(CallId),
    continue;

nkmedia_call_cancel(_CallId, _ProcId, _Call) ->
    continue.


nkmedia_call_reg_event(CallId, {nkmedia_sip, _Ref, _Pid}, {hangup, _Reason}, _Call) ->
    nkmedia_sip:send_hangup(CallId),
    continue;

nkmedia_call_reg_event(_CallId, _ProcId, _Event, _Call) ->
    continue.





%% ===================================================================
%% Implemented Callbacks - nkmedia
%% ===================================================================


%% @private
nkmedia_session_event(_SessId, {answer, Answer}, 
                      #{offer:=#{nkmedia_sip:={in, Handle, _Dialog}}}) ->
    #{sdp:=SDP1} = Answer,
    lager:info("SIP calling media available"),
    SDP2 = nksip_sdp:parse(SDP1),
    ok = nksip_request:reply({answer, SDP2}, Handle),
    continue;

nkmedia_session_event(_SessId, {hangup, _}, 
                      #{offer:=#{nkmedia_sip:={in, _Handle, Dialog}}}) ->
    spawn(fun() -> nksip_uac:bye(Dialog, []) end),
    continue;

nkmedia_session_event(SessId, {hangup, _}, 
                      #{answer:=#{nkmedia_sip:=out}}) ->
    nkmedia_sip:send_hangup(SessId),
    continue;

nkmedia_session_event(_SessId, _Event, _Session) ->
    continue.


%% @private
nkmedia_session_invite(SessId, {nkmedia_sip, Uri, Opts}, Offer, Session) ->
    #{srv_id:=SrvId} = Session,
    case Offer of
        #{sdp_type:=rtp, sdp:=SDP} ->
            ok = nkmedia_sip:send_invite(SrvId, SessId, Uri, Opts#{sdp=>SDP}),
            {async, #{nkmedia_sip=>out}, Session};
        _ ->
            {rejected, <<"Invalid SIP SDP">>, Session}
    end;

nkmedia_session_invite(_SessId, _Dest, _Offer, _Session) ->
	continue.






