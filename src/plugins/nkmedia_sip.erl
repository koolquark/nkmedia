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
-export([send_invite/4, send_hangup/1]).

-define(LLOG(Type, Txt, Args),
    lager:Type("NkMEDIA SIP Plugin (~s) "++Txt, [CallId|Args])).


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



%% ===================================================================
%% Public
%% ===================================================================


%% @private
%% Launches an asynchronous invite
%% Stores {?MODULE, cancel, CallId} under the current caller
%% If the call is answered, stored also dialog and call
-spec send_invite(nkservice:id(), nkmedia_call:id(),
                  nklib:user_uri(), invite_opts()) ->
	{ok, nklib:proc_id()} | {error, term()}.

send_invite(SrvId, CallId, Uri, Opts) ->
    Ref = make_ref(),
    Self = self(),
    Fun = fun
        ({req, _Req, _Call}) ->
            Self ! {Ref, self()};
        ({resp, Code, Resp, _Call}) when Code==180; Code==183 ->
            ProcId = {nkmedia_sip, Ref, self()},
            {ok, Body} = nksip_response:body(Resp),
            case nksip_sdp:is_sdp(Body) of
                true ->
                    _SDP = nksip_sdp:unparse(Body),
                    nkmedia_call:ringing(CallId, ProcId);
                false ->
                    nkmedia_call:ringing(CallId, ProcId)
            end;
        ({resp, Code, _Resp, _Call}) when Code < 200 ->
            ok;
        ({resp, Code, _Resp, _Call}) when Code >= 300 ->
            lager:notice("SIP reject code: ~p", [Code]),
            ProcId = {nkmedia_sip, Ref, self()},
            nkmedia_call:rejected(CallId, ProcId);
        ({resp, _Code, Resp, _Call}) ->
            {ok, Dialog} = nksip_dialog:get_handle(Resp),
            %% We are storing this in the session's process (Self)
            nklib_proc:put({?MODULE, dialog, Dialog}, CallId, Self),
            nklib_proc:put({?MODULE, call, CallId}, Dialog, Self),
            ProcId = {nkmedia_sip, Ref, self()},
            {ok, Body} = nksip_response:body(Resp),
            case nksip_sdp:is_sdp(Body) of
                true ->
                    Answer = #{sdp=>nksip_sdp:unparse(Body)},
                    case nkmedia_call:answered(CallId, ProcId, Answer) of
                        ok ->
                            ok;
                        Other ->
                            ?LLOG(warning, "error calling call answer: ~p", 
                                  [Other]),
                            spawn(fun() -> nksip_uac:bye(Dialog, []) end)
                    end;
                false ->
                    ?LLOG(notice, "missing SDP in response", []),
                    spawn(fun() -> nksip_uac:bye(Dialog, []) end),
                    nkmedia_call:rejected(CallId, ProcId)
            end
    end,
    ?LLOG(info, "calling ~s", [nklib_unparse:uri(Uri)]),
    InvOpts1 = [async, {callback, Fun}, get_request, auto_2xx_ack],
    InvOpts2 = case Opts of
        #{sdp:=SDP} -> 
            SDP2 = nksip_sdp:parse(SDP),
            [{body, SDP2}|InvOpts1];
        _ -> 
            InvOpts1
    end,
    InvOpts3 = case Opts of
        #{from:=From} -> [{from, From}|InvOpts2];
        _ -> InvOpts2
    end,
    InvOpts4 = case Opts of
        #{pass:=Pass} -> [{sip_pass, Pass}|InvOpts3];
        _ -> InvOpts3
    end,
    InvOpts5 = case Opts of
        #{proxy:=Proxy} -> [{route, Proxy}|InvOpts4];
        _ -> InvOpts4
    end,
    {async, Handle} = nksip_uac:invite(SrvId, Uri, InvOpts5),
    nklib_proc:put({?MODULE, cancel, CallId}, Handle),
    receive
        {Ref, Pid} ->
            {ok, {nkmedia_sip, Ref, Pid}}
    after
        5000 ->
            {error, sip_send_error}
    end.



%% @private
send_hangup(CallId) ->
    case nklib_proc:values({?MODULE, call, CallId}) of
        [{Dialog, _SessPid}|_] ->
            nksip_uac:bye(Dialog, []);
        [] ->
            case nklib_proc:values({?MODULE, cancel, CallId}) of
                [{Handle, _SessPid}|_] ->
                    nksip_uac:cancel(Handle, []);
                [] ->
                    lager:notice("Sending Hangup for unknown SIP")
            end
    end.
