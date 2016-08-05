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
-module(nkmedia_sip).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([send_invite/5, send_bye/1, register_incoming/2]).


% -define(OP_TIME, 15000).            % Maximum operation time
% -define(CALL_TIMEOUT, 30000).       % 


%% ===================================================================
%% Types
%% ===================================================================

-type invite_opts() ::
	#{
		body => binary(),
		from => nklib:user_uri(),
		pass => binary(),
		route => nklib:user_uri()
	}.


-type id() ::
    {nkmedia_session, nkmedia_session:id()} |
    {nkmedia_call, nkmedia_call:id()} |
    term().


%% ===================================================================
%% Public
%% ===================================================================


%% @doc
%% Launches an asynchronous invite, from a session or call
%% To recognize events, Id must be {nkmedia_session|nkmedia_call, Id}
-spec send_invite(nkservice:id(), nklib:user_uri(), nkmedia:offer(),
                  id(), invite_opts()) ->
	{ok, nklib:link()} | {error, term()}.

send_invite(Srv, Uri, #{sdp:=SDP}, Id, Opts) ->
    {ok, SrvId} = nkservice_srv:get_srv_id(Srv),
    Ref = make_ref(),
    Self = self(),
    Fun = fun
        ({req, _Req, _Call}) ->
            Self ! {Ref, self()};
        ({resp, Code, Resp, _Call}) when Code==180; Code==183 ->
            {ok, Body} = nksip_response:body(Resp),
            _Answer = case nksip_sdp:is_sdp(Body) of
                true -> #{sdp=>nksip_sdp:unparse(Body)};
                false -> #{}
            end,
            SrvId:nkmedia_sip_invite_ringing(Id);
        ({resp, Code, _Resp, _Call}) when Code < 200 ->
            ok;
        ({resp, Code, _Resp, _Call}) when Code >= 300 ->
            lager:notice("SIP reject code: ~p", [Code]),
            SrvId:nkmedia_sip_invite_rejected(Id);
        ({resp, _Code, Resp, _Call}) ->
            {ok, Dialog} = nksip_dialog:get_handle(Resp),
            %% We are storing this in the session's process (Self)
            nklib_proc:put({nkmedia_sip_dialog_to_id, Dialog}, Id),
            nklib_proc:put({nkmedia_sip_id_to_dialog, Id}, Dialog),
            {ok, Body} = nksip_response:body(Resp),
            case nksip_sdp:is_sdp(Body) of
                true ->
                    Answer = #{sdp=>nksip_sdp:unparse(Body)},
                    case SrvId:nkmedia_sip_invite_answered(Id, Answer) of
                        ok ->
                            ok;
                        Other ->
                            lager:warning("SIP error calling call answer: ~p", [Other]),
                            spawn(fun() -> nksip_uac:bye(Dialog, []) end)
                    end;
                false ->
                    lager:warning("SIP: missing SDP in response"),
                    spawn(fun() -> nksip_uac:bye(Dialog, []) end),
                    SrvId:nkmedia_sip_invite_rejected(Id)
            end
    end,
    lager:info("SIP calling ~s", [nklib_unparse:uri(Uri)]),
    SDP2 = nksip_sdp:parse(SDP),
    InvOpts1 = [async, {callback, Fun}, get_request, auto_2xx_ack, {body, SDP2}],
    InvOpts2 = case Opts of
        #{from:=From} -> [{from, From}|InvOpts1];
        _ -> InvOpts1
    end,
    InvOpts3 = case Opts of
        #{pass:=Pass} -> [{sip_pass, Pass}|InvOpts2];
        _ -> InvOpts2
    end,
    InvOpts4 = case Opts of
        #{proxy:=Proxy} -> [{route, Proxy}|InvOpts3];
        _ -> InvOpts3
    end,
    {async, Handle} = nksip_uac:invite(SrvId, Uri, InvOpts4),
    receive
        {Ref, Pid} ->
            nklib_proc:put({nkmedia_sip_id_to_handle, Id}, Handle, Pid),
            {ok, Pid}
    after
        5000 ->
            {error, sip_send_error}
    end.


%% @doc Tries to send a BYE for a registered SIP
-spec send_bye(id()) ->
    ok.

send_bye(Id) ->
    case nklib_proc:values({nkmedia_sip_id_to_dialog, Id}) of
        [{Dialog, _SipPid}|_] ->
            lager:info("SIP sending BYE for ~p", [Id]),
            nksip_uac:bye(Dialog, []);
        [] ->
            case nklib_proc:values({nkmedia_sip_id_to_handle, Id}) of
                [{Handle, _SiPid}|_] ->
                    lager:info("SIP sending CANCEL for ~p", [Id]),
                    nksip_uac:cancel(Handle, []);
                [] ->
                    ok
            end
    end.


%% @doc Reigisters an incoming SIP
-spec register_incoming(nksip:request(), id()) ->
    ok.

register_incoming(Req, Id) ->
    {ok, Handle} = nksip_request:get_handle(Req),
    {ok, Dialog} = nksip_dialog:get_handle(Req),
    nklib_proc:put({nkmedia_sip_dialog_to_id, Dialog}, Id),
    nklib_proc:put({nkmedia_sip_id_to_dialog, Id}, Dialog),
    nklib_proc:put({nkmedia_sip_handle_to_id, Handle}, Id),
    nklib_proc:put({nkmedia_sip_id_to_handle, Id}, Handle).










