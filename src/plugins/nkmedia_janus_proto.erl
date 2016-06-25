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

%% @doc 
-module(nkmedia_janus_proto).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([invite/3, answer/3, hangup/2, hangup/3]).
-export([find_user/1, find_call_id/1, get_all/0]).
-export([register_play/3]).
-export([transports/1, default_port/1]).
-export([conn_init/1, conn_encode/2, conn_parse/3, conn_stop/3,
         conn_handle_call/4, conn_handle_cast/3, conn_handle_info/3]).
-export([print/3]).

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Janus Proto (~s) "++Txt, [State#state.user | Args])).

-define(PRINT(Txt, Args, State), 
        % print(Txt, Args, State),    % Uncomment this for detailed logs
        ok).


-define(OP_TIME, 15000).            % Maximum operation time
-define(CALL_TIMEOUT, 30000).       % 


%% ===================================================================
%% Types
%% ===================================================================

% Recognized: sdp, callee_name, callee_id, caller_name, caller
-type offer() :: nkmedia:offer() | #{async => boolean(), monitor=>pid()}.      

% Included: sdp, sdp_type, verto_params
-type answer() :: nkmedia:answer() | #{monitor=>pid()}.

-type janus() ::
	#{
        remote => binary(),
        srv_id => nkservice:id(),
        sess_id => binary(),
        user => binary()
	}.

-type call_id() :: binary().


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Sends an INVITE. 
%% If async=true, the pid() of the process and a reference() will be returned,
%% and a message {?MODULE, Ref, {ok, answer()}} or {?MODULE, Ref, {error, Error}}
%% will be sent to the calling process
%% A new call will be added (see find_call_id/1)
%% If 'monitor' is used, this process will be monitorized 
%% and the call will be hangup if it fails before a hangup is sent or received
-spec invite(pid(), call_id(), offer()) ->
    {answer, answer()} | rejected | {async, pid(), reference()} |
    {error, term()}.
    
invite(Pid, CallId, Offer) ->
    call(Pid, {invite, CallId, Offer}).


%% @doc Sends an ANSWER (only sdp is used in answer())
-spec answer(pid(), call_id(), answer()) ->
    ok | {error, term()}.

answer(Pid, CallId, Answer) ->
    call(Pid, {answer, CallId, Answer}).


%% @doc Equivalent to hangup(Pid, CallId, 16)
-spec hangup(pid(), binary()) ->
    ok.

hangup(Pid, CallId) ->
    hangup(Pid, CallId, 16).


%% @doc Sends a BYE (non-blocking)
%% The call will be removed and demonitorized
-spec hangup(pid(), binary(), nkmedia:hangup_reason()) ->
    ok | {error, term()}.

hangup(Pid, CallId, Reason) ->
    gen_server:cast(Pid, {hangup, CallId, Reason}).


%% @doc Gets the pids() for currently logged user
-spec find_user(binary()) ->
    [pid()].

find_user(Login) ->
    Login2 = nklib_util:to_binary(Login),
    [Pid || {undefined, Pid} <- nklib_proc:values({?MODULE, user, Login2})].


%% @doc Gets the pids() for currently logged user
-spec find_call_id(binary()) ->
    [pid()].

find_call_id(CallId) ->
    CallId2 = nklib_util:to_binary(CallId),
    [Pid || {undefined, Pid} <- nklib_proc:values({?MODULE, call, CallId2})].


-spec register_play(string()|binary(), pid(), nkmedia:offer()) ->
    ok.

register_play(CallId, Pid, Offer) ->
    Obj = #{call_id=>CallId, offer=>Offer, pid=>Pid},
    nkmedia_app:put(nkmedia_janus_proto_play_reg, Obj).


get_all() ->
    [{Local, Remote} || {Remote, Local} <- nklib_proc:values(?MODULE)].




%% ===================================================================
%% Protocol callbacks
%% ===================================================================


-type op_id() :: {trans, integer()}.

-record(trans, {
    req :: term(),
    timer :: reference(),
    from :: {pid(), term()}
}).

-record(state, {
    srv_id ::  nkservice:id(),
    trans = #{} :: #{op_id() => #trans{}},
    session_id :: integer(),
    plugin :: videocall | recordplay,
    handle :: integer(),
    user :: binary(),
    calls = [] :: [{CallId::binary(), reference()}],
    janus :: janus(),
    pos :: integer()
}).


%% @private
-spec transports(nklib:scheme()) ->
    [nkpacket:transport()].

transports(_) -> [wss, ws].

-spec default_port(nkpacket:transport()) ->
    inet:port_number() | invalid.

default_port(ws) -> 8188;
default_port(wss) -> 8989.


-spec conn_init(nkpacket:nkport()) ->
    {ok, #state{}}.

conn_init(NkPort) ->
    {ok, {nkmedia_janus_proto, SrvId}, _} = nkpacket:get_user(NkPort),
    {ok, Remote} = nkpacket:get_remote_bin(NkPort),
    Janus = #{remote=>Remote, srv_id=>SrvId},
    State1 = #state{
        srv_id = SrvId, 
        janus = Janus,
        pos = erlang:phash2(make_ref())
    },
    nklib_proc:put(?MODULE, <<>>),
    lager:info("NkMEDIA Janus Proto new connection (~s, ~p)", [Remote, self()]),
    {ok, State2} = handle(nkmedia_janus_init, [NkPort], State1),
    {ok, State2}.


%% @private
-spec conn_parse(term()|close, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_parse(close, _NkPort, State) ->
    {ok, State};

conn_parse({text, Data}, NkPort, State) ->
    Msg = case nklib_json:decode(Data) of
        error ->
            ?LLOG(warning, "JSON decode error: ~p", [Data], State),
            error(json_decode);
        Json ->
            Json
    end,
    ?PRINT("receiving ~s", [Msg], State),
    case Msg of
        #{<<"janus">>:=BinCmd, <<"transaction">>:=_Trans} ->
            Cmd = case catch binary_to_existing_atom(BinCmd, latin1) of
                {'EXIT', _} -> BinCmd;
                Cmd2 -> Cmd2
            end,
            process_client_req(Cmd, Msg, NkPort, State);
        #{<<"janus">>:=Cmd} ->
            ?LLOG(notice, "unknown msg: ~s: ~p", [Cmd, Msg], State),
            {ok, State}
    end.


%% @private
-spec conn_encode(term(), nkpacket:nkport()) ->
    {ok, nkpacket:outcoming()} | continue | {error, term()}.

conn_encode(Msg, _NkPort) when is_map(Msg) ->
    Json = nklib_json:encode(Msg),
    {ok, {text, Json}};

conn_encode(Msg, _NkPort) when is_binary(Msg) ->
    {ok, {text, Msg}}.


%% @doc Called when the connection received an erlang message
-spec conn_handle_call(term(), term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_call(Msg, From, NkPort, State) ->
    case send_req(Msg, From, NkPort, State) of
        unknown_op ->
            handle(nkmedia_janus_handle_call, [Msg, From], State);
        Other ->
            Other
    end.


-spec conn_handle_cast(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_cast(Msg, NkPort, State) ->
    case send_req(Msg, undefined, NkPort, State) of
        unknown_op ->
            handle(nkmedia_janus_handle_cast, [Msg], State);
        Other ->
            Other
    end.


%% @doc Called when the connection received an erlang message
-spec conn_handle_info(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_info({'DOWN', Ref, process, _Pid, Reason}=Info, _NkPort, State) ->
    #state{calls=Calls} = State,
    case lists:keytake(Ref, 2, Calls) of
        {value, {CallId, Ref}, Calls2} ->
            ?LLOG(notice, "call ~s down: ~p", [CallId, Reason], State),
            hangup(self(), CallId, <<"Process Down">>),
            {ok, State#state{calls=Calls2}};
        false ->
            ?LLOG(notice, "down not found: ~p, ~p", [Ref, Calls], State),
            handle(nkmedia_janus_handle_info, [Info], State)
    end;

conn_handle_info(Info, _NkPort, State) ->
    handle(nkmedia_janus_handle_info, [Info], State).


%% @doc Called when the connection stops
-spec conn_stop(Reason::term(), nkpacket:nkport(), #state{}) ->
    ok.

conn_stop(Reason, _NkPort, State) ->
    catch handle(nkmedia_janus_terminate, [Reason], State).


%% ===================================================================
%% Requests
%% ===================================================================

send_req({invite, CallId, #{sdp:=SDP}=Opts}, From, NkPort, State) ->
    nklib_util:reply(From, ok),
    ?LLOG(info, "ordered INVITE (~s)", [CallId], State),
    Result = #{
        event => incomingcall, 
        username => unknown
    },
    Jsep = #{sdp=>SDP, type=>offer, trickle=>false},
    Req = make_videocall_req(Result, Jsep, State),
    Pid = maps:get(monitor, Opts, undefined),
    State2 = add_call(CallId, Pid, State),
    % Client will send us accept
    send(Req, NkPort, State2);

send_req({answer, CallId, #{sdp:=SDP}}, From, NkPort, #state{calls=Calls}=State) ->
    ?LLOG(info, "ordered ANSWER (~s)", [CallId], State),
    case Calls of
        [{CallId, _}|_] ->
            ok;
        Other ->
            ?LLOG(warning, "answer for unknown call: ~p", [Other], State)
    end,
    Result = #{
        event => accepted, 
        username => unknown
    },
    Jsep = #{sdp=>SDP, type=>answer, trickle=>false},
    Req = make_videocall_req(Result, Jsep, State),
    nklib_util:reply(From, ok),
    send(Req, NkPort, State);

send_req({hangup, _CallId, _Reason}, _From, _NkPort, #state{plugin=recordplay}=State) ->
    {stop, normal, State};

send_req({hangup, CallId, Reason}, From, NkPort, State) ->
    ?LLOG(info, "ordered HANGUP (~s, ~p)", [CallId, Reason], State),
    nklib_util:reply(From, ok),
    Result = #{
        event => hangup, 
        reason => nklib_util:to_binary(Reason), 
        username => unknown
    },
    Req = make_videocall_req(Result, #{}, State),
    State2 = del_call(CallId, State),
    send(Req, NkPort, State2);

send_req(_Op, _From, _NkPort, _State) ->
    unknown_op.



%% @private
process_client_req(create, Msg, NkPort, State) ->
	Id = erlang:phash2(make_ref()),
	Resp = make_resp(#{janus=>success, data=>#{id=>Id}}, Msg),
	send(Resp, NkPort, State#state{session_id=Id});

process_client_req(attach, Msg, NkPort, #state{session_id=SessionId}=State) ->
    #{<<"plugin">>:=Plugin, <<"session_id">>:=SessionId} = Msg,
    Plugin2 = case Plugin of
        <<"janus.plugin.videocall">> -> videocall;
        <<"janus.plugin.recordplay">> -> recordplay;
        _ -> error({invalid_plugin, Plugin})
    end,
    Handle = erlang:phash2(make_ref()),
    Resp = make_resp(#{janus=>success, data=>#{id=>Handle}}, Msg),
    send(Resp, NkPort, State#state{handle=Handle, plugin=Plugin2});

process_client_req(message, Msg, NkPort, #state{plugin=recordplay}=State) ->
    #state{session_id=SessionId, handle=Handle} = State,
    #{<<"body">>:=Body, <<"session_id">>:=SessionId, <<"handle_id">>:=Handle} = Msg,
    #{<<"request">> := BinReq} = Body,
    Req = case catch binary_to_existing_atom(BinReq, latin1) of
        {'EXIT', _} -> BinReq;
        Req2 -> Req2
    end,
   process_client_msg(Req, Body, Msg, NkPort, State);

process_client_req(message, Msg, NkPort, #state{plugin=videocall}=State) ->
    #state{session_id=SessionId, handle=Handle} = State,
    #{<<"body">>:=Body, <<"session_id">>:=SessionId, <<"handle_id">>:=Handle} = Msg,
    #{<<"request">> := BinReq} = Body,
    Req = case catch binary_to_existing_atom(BinReq, latin1) of
        {'EXIT', _} -> BinReq;
        Req2 -> Req2
    end,
    case Req of
        list ->
           process_client_msg(Req, Body, Msg, NkPort, State); 
        _ ->
            Ack = make_resp(#{janus=>ack, session_id=>SessionId}, Msg),
            case send(Ack, NkPort, State) of
                {ok, State2} ->
                   process_client_msg(Req, Body, Msg, NkPort, State2);
                Other ->
                    Other
            end
    end;

process_client_req(detach, Msg, NkPort, State) ->
    #state{session_id=SessionId, handle=Handle} = State,
    #{<<"session_id">>:=SessionId, <<"handle_id">>:=Handle} = Msg,
    Resp = make_resp(#{janus=>success, session_id=>SessionId}, Msg),
    send(Resp, NkPort, State#state{handle=undefined});

process_client_req(destroy, Msg, NkPort, #state{session_id=SessionId}=State) ->
    #{<<"session_id">>:=SessionId} = Msg,
    Resp = make_resp(#{janus=>success, session_id=>SessionId}, Msg),
    send(Resp, NkPort, State#state{session_id=undefined});

process_client_req(keepalive, Msg, NkPort, #state{session_id=SessionId}=State) ->
    Resp = make_resp(#{janus=>ack, session_id=>SessionId}, Msg),
    send(Resp, NkPort, State);

process_client_req(Cmd, _Msg, _NkPort, State) ->
    ?LLOG(warning, "unexpected client REQ: ~s", [Cmd], State),
    {ok, State}.


%% @private
process_client_msg(register, Body, Msg, NkPort, State) ->
    #{<<"username">>:=User} = Body,
    ?LLOG(info, "received REGISTER (~s)", [User], State),
    nklib_proc:put(?MODULE, User),
    nklib_proc:put({?MODULE, user, User}),
    Result = #{event=>registered, username=>User},
    Resp = make_videocall_resp(Result, Msg, State),
    send(Resp, NkPort, State#state{user=User});

process_client_msg(call, Body, Msg, NkPort, State) ->
    CallId = nklib_util:uuid_4122(),
    ?LLOG(info, "received CALL (~s)", [CallId], State),
    #{<<"username">>:=Dest} = Body,
    #{<<"jsep">>:=#{<<"sdp">>:=SDP}} = Msg,
    Offer = #{dest=>Dest, sdp=>SDP, sdp_type=>webrtc},
    case handle(nkmedia_janus_invite, [CallId, Offer], State) of
        {ok, Pid, State2} ->
            ok;
        {answer, Answer, Pid, State2} ->
            gen_server:cast(self(), {answer, CallId, Answer});
        {hangup, Reason, State2} ->
            Pid = undefined,
            hangup(self(), CallId, Reason)
    end,
    State3 = add_call(CallId, Pid, State2),
    Resp = make_videocall_resp(#{event=>calling}, Msg, State3),
    send(Resp, NkPort, State3);

process_client_msg(accept, _Body, Msg, NkPort, #state{calls=Calls}=State) ->
    [{CallId, _}|_] = Calls,
    ?LLOG(info, "received ACCEPT (~s)", [CallId], State),
    #{<<"jsep">>:=#{<<"sdp">>:=SDP}} = Msg,
    Answer = #{sdp=>SDP, sdp_type=>webrtc},
    case handle(nkmedia_janus_answer, [CallId, Answer], State) of
        {ok, State2} ->
            ok;
        {hangup, Reason, State2} ->
            hangup(self(), CallId, Reason)
    end,

    %% FALTA SDP
    Resp = make_videocall_resp(#{event=>accepted}, Msg, State2),
    send(Resp, NkPort, State2);

process_client_msg(hangup, _Body, _Msg, _NkPort, #state{calls=Calls}=State) ->
    State3 = case Calls of
        [{CallId, _}|_] ->
            {ok, State2} = handle(nkmedia_janus_bye, [CallId], State),
            del_call(CallId, State2);
        [] ->
            CallId = <<>>,
            State
    end,
    ?LLOG(info, "received HANGUP (~s)", [CallId], State3),
    {ok, State3};

process_client_msg(list, _Body, Msg, NkPort, #state{plugin=videocall}=State) ->
    Resp = make_videocall_resp(#{list=>[]}, Msg, State),
    send(Resp, NkPort, State);

process_client_msg(list, _Body, Msg, NkPort, #state{plugin=recordplay}=State) ->
    ?LLOG(info, "received LIST", [], State),
    List = case nkmedia_app:get(nkmedia_janus_proto_play_reg) of
        #{
            call_id := CallId,
            offer := _Offer
        } ->
            [#{
                id => erlang:phash2(CallId),
                name => CallId,
                audio => <<"true">>,
                video => <<"true">>,
                date => <<>>
            }];
        _ ->
            []
    end,
    Resp = make_recordplay_resp1(#{list=>List, recordplay=>list}, Msg, State),
    send(Resp, NkPort, State);

process_client_msg(play, Body, Msg, NkPort, State) ->
    #{<<"id">> := Id} = Body,
    case nkmedia_app:get(nkmedia_janus_proto_play_reg) of
        #{
            call_id := CallId,
            offer := #{sdp:=SDP},
            pid := Pid
        } = Reg ->
            case erlang:phash2(CallId) of
                Id ->
                    ?LLOG(info, "received PLAY (~s)", [CallId], State),
                    Pid = maps:get(pid, Reg, undefined),
                    State2 = add_call(CallId, Pid, State),
                    Data = #{
                        recordplay => event,
                        result => #{id=>Id, status=>preparing}
                    },
                    Jsep = #{sdp=>SDP, type=>offer},
                    Resp = make_recordplay_resp2(Data, Jsep, Msg, State),
                    send(Resp, NkPort, State2);
                _ ->
                    error(invalid_id1)
            end;
        O ->
            error({invalid_id2, O})
    end;

process_client_msg(start, _Body, Msg, NkPort, #state{calls=Calls}=State) ->
    #{<<"jsep">>:=#{<<"sdp">>:=SDP}} = Msg,
    #{call_id := CallId} = nkmedia_app:get(nkmedia_janus_proto_play_reg),
    nkmedia_app:del(nkmedia_janus_proto_play_reg),
    [{CallId, _}|_] = Calls,
    ?LLOG(info, "received START (~s)", [CallId], State),
    case handle(nkmedia_janus_start, [CallId, #{sdp=>SDP}], State) of
        {ok, State2} ->
            ok;
        {hangup, Reason, State2} ->
            hangup(self(), CallId, Reason)
    end,
    Data = #{recordplay=>event, result=>#{status=>playing}},
    Resp = make_recordplay_resp2(Data, #{}, Msg, State2),
    send(Resp, NkPort, State2);


process_client_msg(stop, _Body, _Msg, _NkPort, State) ->
    ?LLOG(warning, "received STOP", [], State),
    {ok, State};

process_client_msg(Cmd, _Body, _Msg, _NkPort, State) ->
    ?LLOG(warning, "unexpected client MESSAGE: ~s", [Cmd], State),
    {ok, State}.


% %% @private
% process_client_resp(Cmd, _OpId, _Req, _From, _Msg, _NkPort, State) ->
%     ?LLOG(warning, "Server REQ: ~s", [Cmd], State),
%     {ok, State}.









%% ===================================================================
%% Util
%% ===================================================================


% %% @private
% make_msg(Body, Msg, From, State) ->
%     #state{session_id=SessionId, handle=Handle, pos=Pos} = State,
%     TransId = nklib_util:to_binary(Pos),
%     State2 = insert_op({trans, TransId}, Msg, From, State),
%     Req = #{
%         janus => message,
%         body => Body,
%         session_id => SessionId,
%         handle_id => Handle,
%         transaction => TransId
%     },
%     {Req, State2#state{pos=Pos+1}}.



%% @private
make_videocall_req(Result, Jsep, #state{plugin=videocall}=State) ->
    #state{session_id=SessionId, handle=Handle} = State,
    Req = #{
        janus => event,
        plugindata => #{
            data => #{
                result => Result,
                videocall => event
            },
            plugin => <<"janus.plugin.videocall">>
        },
        sender => Handle,
        session_id => SessionId
    },
    case maps:size(Jsep) of
        0 -> Req;
        _ -> Req#{jsep=>Jsep}
    end.


%% @private
make_videocall_resp(Result, Msg, State) ->
    Req = make_videocall_req(Result, #{}, State),
    make_resp(Req, Msg).



%% @private
make_recordplay_resp1(Data, Msg, #state{plugin=recordplay}=State) ->
    #state{session_id=SessionId, handle=Handle} = State,
    Resp = #{
        janus => success,
        plugindata => #{
            data => Data,
            plugin => <<"janus.plugin.recordplay">>
        },
        sender => Handle,
        session_id => SessionId
    },
    make_resp(Resp, Msg).


%% @private
make_recordplay_resp2(Data, Jsep, Msg, #state{plugin=recordplay}=State) ->
    #state{session_id=SessionId, handle=Handle} = State,
    Resp1 = #{
        janus => event,
        plugindata => #{
            data => Data,
            plugin => <<"janus.plugin.recordplay">>
        },
        sender => Handle,
        session_id => SessionId
    },
    Resp2 = case maps:size(Jsep) of
        0 -> Resp1;
        _ -> Resp1#{jsep=>Jsep}
    end,
    make_resp(Resp2, Msg).


%% @private
make_resp(Data, Msg) ->
    #{<<"transaction">>:=Trans} = Msg,
    Data#{transaction => Trans}.
    %% @private


%% @private
call(JanusPid, Msg) ->
    nkservice_util:call(JanusPid, Msg, 1000*?CALL_TIMEOUT).



%% @private
add_call(CallId, Pid, #state{calls=Calls}=State) ->
    nklib_proc:put({?MODULE, call, CallId}),
    case lists:keymember(CallId, 1, Calls) of
        false ->
            Ref = case is_pid(Pid) of
                true -> monitor(process, Pid);
                _ -> undefined
            end,
            State#state{calls=[{CallId, Ref}|Calls]};
        true ->
            ?LLOG(notice, "duplicated reg!", [], State),
            State
    end.


%% @private
del_call(CallId, #state{calls=Calls}=State) ->
    nklib_proc:del({?MODULE, call, CallId}),
    case lists:keytake(CallId, 1, Calls) of
        {value, {CallId, Ref}, Calls2} -> 
            nklib_util:demonitor(Ref),
            State#state{calls=Calls2};
        false ->
            State
    end.
    


% %% @private
% insert_op(OpId, Req, From, #state{trans=AllOps}=State) ->
%     NewOp = #trans{
%         req = Req, 
%         timer = erlang:start_timer(?OP_TIME, self(), {op_timeout, OpId}),
%         from = From
%     },
%     State#state{trans=maps:put(OpId, NewOp, AllOps)}.



% extract_op(OpId, #state{trans=AllOps}=State) ->
%     case maps:find(OpId, AllOps) of
%         {ok, #trans{timer=Timer}=OldOp} ->
%             nklib_util:cancel_timer(Timer),
%             State2 = State#state{trans=maps:remove(OpId, AllOps)},
%             {OldOp, State2};
%         error ->
%             not_found
%     end.


%% @private
send(Msg, NkPort, State) ->
    ?PRINT("sending ~s", [Msg], State),
    case send(Msg, NkPort) of
        ok -> 
            {ok, State};
        error -> 
            ?LLOG(notice, "error sending reply:", [], State),
            {stop, normal, State}
    end.


%% @private
send(Msg, NkPort) ->
    nkpacket_connection:send(NkPort, Msg).


%% @private
handle(Fun, Args, State) ->
    nklib_gen_server:handle_any(Fun, Args, State, #state.srv_id, #state.janus).




% %% @private
% user_reply(#trans{from={async, Pid, Ref}}, Msg) ->
%     Pid ! {?MODULE, Ref, Msg};
% user_reply(#trans{from=From}, Msg) ->
%     nklib_util:reply(From, Msg).


%% @private
print(_Txt, [#{<<"janus">>:=<<"keepalive">>}], _State) ->
    ok;
print(_Txt, [#{janus:=ack}], _State) ->
    ok;
print(Txt, [#{}=Map], State) ->
    Map2 = case Map of
        #{jsep:=#{sdp:=_SDP}=Jsep} -> 
            Map#{jsep:=Jsep#{sdp=><<"...">>}};
        #{<<"jsep">>:=#{<<"sdp">>:=_SDP}=Jsep} -> 
            Map#{<<"jsep">>:=Jsep#{<<"sdp">>=><<"...">>}};
        _ -> 
            _SDP = <<>>,
            Map
    end,
    % io:format("~s\n", [_SDP]),
    print(Txt, [nklib_json:encode_pretty(Map2)], State);
print(Txt, Args, State) ->
    ?LLOG(info, Txt, Args, State).



% {
%   "janus": "event",
%   "plugindata": {
%     "data": {
%       "error": "You can't call yourself... use the EchoTest for that",
%       "error_code": 479,
%       "videocall": "event"
%     },
%     "plugin": "janus.plugin.videocall"
%   },
%   "sender": 2256035211,
%   "session_id": 1837249640,
%   "transaction": "YFTMkOeSwwAo"
% }
