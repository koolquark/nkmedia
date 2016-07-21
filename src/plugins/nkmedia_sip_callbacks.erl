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
-export([nkmedia_sip_invite/5]).
-export([nkmedia_sip_invite_ringing/1, nkmedia_sip_invite_rejected/1, 
         nkmedia_sip_invite_answered/2]).
-export([sip_get_user_pass/4, sip_authorize/3]).
-export([sip_invite/2, sip_reinvite/2, sip_cancel/3, sip_bye/2]).
-export([nkmedia_call_resolve/3, nkmedia_call_invite/4, nkmedia_call_cancel/3,
         nkmedia_call_reg_event/4]).
-export([nkmedia_session_reg_event/4]).

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

%% @doc Called when a new SIP invite arrives
-spec nkmedia_sip_invite(nkservice:id(), nksip:aor(), 
                         nkmedia:offer(), nksip:request(), nksip:call()) ->
    {ok, nklib:proc_id()} | {rejected, nkservice:error()} | continue().

nkmedia_sip_invite(_SrvId, _AOR, _Offer, _Req, _Call) ->
    {rejected, <<"Not Implemented">>}.


%% @doc Called when a SIP INVITE we are launching is ringing
-spec nkmedia_sip_invite_ringing(Id::term()) ->
    ok.

nkmedia_sip_invite_ringing({nkmedia_call, CallId}) ->
    nkmedia_call:ringing(CallId, {nkmedia_sip, self()});

nkmedia_sip_invite_ringing(_Id) ->
    ok.


%% @doc Called when a SIP INVITE we are launching has been rejected
-spec nkmedia_sip_invite_rejected(Id::term()) ->
    ok.

nkmedia_sip_invite_rejected({nkmedia_call, CallId}) ->
    nkmedia_call:rejected(CallId, {nkmedia_sip, self()});

nkmedia_sip_invite_rejected({nkmedia_session, SessId}) ->
    nkmedia_session:stop(SessId, sip_rejected);

nkmedia_sip_invite_rejected(_Id) ->
    ok.


%% @doc Called when a SIP INVITE we are launching has been answered
-spec nkmedia_sip_invite_answered(Id::term(), nkmedia:answer()) ->
    ok | {error, term()}.

nkmedia_sip_invite_answered({nkmedia_call, CallId}, Answer) ->
    nkmedia_call:answered(CallId, {nkmedia_sip, self()}, Answer);

nkmedia_sip_invite_answered({nkmedia_session, SessId}, Answer) ->
    case nkmedia_session:answer(SessId, Answer) of
        {ok, _} -> ok;
        {error, Error} -> {error, Error}
    end;

nkmedia_sip_invite_answered(_Id, _Answer) ->
    {error, not_implemented}.

    



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
        true -> #{sdp=>nksip_sdp:unparse(Body), sdp_type=>rtp};
        false -> #{}
    end,
    case SrvId:nkmedia_sip_invite(SrvId, AOR, Offer, Req, Call) of
        {ok, _ProcId} ->
            % {ok, Handle} = nksip_request:get_handle(Req),
            % {ok, Dialog} = nksip_dialog:get_handle(Req),
            % nklib_proc:put({nkmedia_sip, dialog, Dialog}, ProcId),
            % nklib_proc:put({nkmedia_sip, cancel, Handle}, ProcId),
            noreply;
        {reply, Reply} ->
            {reply, Reply};
        {rejected, Reason} ->
            lager:notice("SIP invite rejected: ~p", [Reason]),
            {reply, decline}
    end.
        

%% @private
sip_reinvite(_Req, _Call) ->
    {reply, decline}.


%% @private
sip_cancel(InviteReq, _Request, _Call) ->
    {ok, Handle} = nksip_request:get_handle(InviteReq),
    case nklib_proc:values({nkmedia_sip_handle_to_id, Handle}) of
        [{{nkmedia_session, SessId}, _}|_] ->
            nkmedia_session:stop(SessId, sip_cancel),
            ok;
        [] ->
            ok
    end.


%% @private Called when a BYE is received from SIP
sip_bye(Req, _Call) ->
	{ok, Dialog} = nksip_dialog:get_handle(Req),
    case nklib_proc:values({nkmedia_sip_dialog_to_id, Dialog}) of
        [{{nkmedia_call, CallId}, _}|_] ->
            nkmedia_call:hangup(CallId, sip_bye);
        [{{nkmedia_session, SessId}, _}|_] ->
            nkmedia_session:stop(SessId, sip_bye);
        [] ->
            lager:notice("Received SIP BYE for unknown session")
    end,
	continue.


%% ===================================================================
%% Implemented Callbacks - Error
%% ===================================================================

% @private
error_code({sip_code, Code}) ->
    {1500, nklib_util:msg("SIP Code ~p", [Code])};

error_code(sip_bye)         -> {1501, <<"SIP Bye">>};
error_code(sip_cancel)      -> {1501, <<"SIP Cancel">>};
error_code(sip_no_sdp)      -> {1501, <<"SIP Missing SDP">>};
error_code(sip_send_error)  -> {1501, <<"SIP Send Error">>};
error_code(_) -> continue.


%% ===================================================================
%% Implemented Callbacks - Call
%% ===================================================================


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
    case nkmedia_sip:send_invite(SrvId, Uri, Offer, {nkmedia_call, CallId}, []) of
        {ok, _Handle, Pid} -> 
            {ok, {nkmedia_sip, Pid}, Call};
        {error, Error} ->
            lager:error("error sending sip: ~p", [Error]),
            {remove, Call}
    end;

nkmedia_call_invite(_CallId, _Dest, _Offer, _Call) ->
    continue.


%% @private
nkmedia_call_cancel(CallId, {nkmedia_sip, _Pid}, _Call) ->
    nkmedia_sip:send_bye({nkmedia_call, CallId}),
    continue;

nkmedia_call_cancel(_CallId, _ProcId, _Call) ->
    continue.


nkmedia_call_reg_event(CallId, {nkmedia_sip, _Pid}, {hangup, _Reason}, _Call) ->
    nkmedia_sip:send_bye({nkmedia_call, CallId}),
    continue;

nkmedia_call_reg_event(_CallId, _ProcId, _Event, _Call) ->
    continue.


%% ===================================================================
%% Implemented Callbacks - Session
%% ===================================================================


%% @private
%% We recognize for Id:
%% - {incoming, Handle, Dialog}:
%% - {nkmedia_session, SessId}
nkmedia_session_reg_event(SessId, {nkmedia_sip, in, _SipPid}, Event, Session) ->
    Id = {nkmedia_session, SessId},
    spawn(
        fun() ->
            case Event of
                {answer, #{sdp:=SDP}} ->
                    [{Handle, _}|_] = nklib_proc:values({nkmedia_sip_id_to_handle, Id}),
                    Body = nksip_sdp:parse(SDP),
                    case nksip_request:reply({answer, Body}, Handle) of
                        ok ->
                            ok;
                        {error, Error} ->
                            lager:error("Error in SIP reply: ~p", [Error]),
                            nkmedia_session:stop(self(), process_down)
                    end;
                {stop, _Reason} ->
                    case Session of
                        #{answer:=#{sdp:=_}} ->
                            nkmedia_sip:send_bye({nkmedia_session,  SessId});
                        _ ->
                            [{Handle, _}|_] = 
                                nklib_proc:values({nkmedia_sip_id_to_handle, Id}),
                            nksip_request:reply(decline, Handle)
                    end;
                _ ->
                    ok
            end
        end),
    {ok, Session};

nkmedia_session_reg_event(SessId, {nkmedia_sip, out, _SipPid}, 
                          {stop, _Reason}, Session) ->
    spawn(fun() -> nkmedia_sip:send_bye({nkmedia_session, SessId}) end),
    {ok, Session};

nkmedia_session_reg_event(_SessId, _ProcId, _Event, _Session) ->
    continue.





% %% @private
% nkmedia_session_event(_SessId, {answer, Answer}, 
%                       #{offer:=#{nkmedia_sip:={in, Handle, _Dialog}}}) ->
%     #{sdp:=SDP1} = Answer,
%     lager:info("SIP calling media available"),
%     SDP2 = nksip_sdp:parse(SDP1),
%     ok = nksip_request:reply({answer, SDP2}, Handle),
%     continue;

% nkmedia_session_event(_SessId, {hangup, _}, 
%                       #{offer:=#{nkmedia_sip:={in, _Handle, Dialog}}}) ->
%     spawn(fun() -> nksip_uac:bye(Dialog, []) end),
%     continue;

% nkmedia_session_event(SessId, {hangup, _}, 
%                       #{answer:=#{nkmedia_sip:=out}}) ->
%     nkmedia_sip:send_hangup(SessId),
%     continue;

% nkmedia_session_event(_SessId, _Event, _Session) ->
%     continue.


% %% @private
% nkmedia_session_invite(SessId, {nkmedia_sip, Uri, Opts}, Offer, Session) ->
%     #{srv_id:=SrvId} = Session,
%     case Offer of
%         #{sdp_type:=rtp, sdp:=SDP} ->
%             ok = nkmedia_sip:send_invite(SrvId, SessId, Uri, Opts#{sdp=>SDP}),
%             {async, #{nkmedia_sip=>out}, Session};
%         _ ->
%             {rejected, <<"Invalid SIP SDP">>, Session}
%     end;

% nkmedia_session_invite(_SessId, _Dest, _Offer, _Session) ->
% 	continue.






