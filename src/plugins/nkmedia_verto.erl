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

%% @doc Plugin implementing a Verto server
-module(nkmedia_verto).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([invite/3, answer/3, hangup/2, hangup/3]).
-export([find_user/1, find_call_id/1, get_all/0]).
-export([transports/1, default_port/1]).
-export([conn_init/1, conn_encode/2, conn_parse/3, conn_handle_call/4, 
         conn_handle_cast/3, conn_handle_info/3, conn_stop/3]).
-export([print/3]).
-export_type([offer/0, answer/0, call_id/0, verto/0]).

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Verto (~s) "++Txt, [State#state.user | Args])).

-define(PRINT(Txt, Args, State), 
        % print(Txt, Args, State),    % Uncomment this for detailed logs
        ok).


-define(OP_TIMEOUT, 15).            % Maximum operation time (not for invite)
-define(CALL_TIMEOUT, 180).         % 




%% ===================================================================
%% Types
%% ===================================================================


% Recognized: sdp, callee_name, callee_id, caller_name, caller
-type offer() :: nkmedia:offer() | #{async => boolean(), monitor=>pid()}.      

% Included: sdp, sdp_type, verto_params
-type answer() :: nkmedia:answer() | #{monitor=>pid()}.

-type call_id() :: binary().

-type verto() :: 
    #{
        remote => binary(),
        srv_id => nkservice:id(),
        sess_id => binary(),
        user => binary()
    }.


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


%% @private
-spec get_all() ->
    [pid()].

get_all() ->
    nklib_proc:values(?MODULE).


%% ===================================================================
%% Protocol callbacks
%% ===================================================================

-type op_id() :: {trans, integer()}.



-record(session_op, {
    type :: term(),
    timer :: reference(),
    from :: {pid(), term()} | {async, pid(), term()}
}).

-record(state, {
    srv_id ::  nkservice:id(),
    sess_id = <<>> :: binary(),
    user = <<"undefined">> :: binary(),
    current_id = 1 :: integer(),
    bw_bytes :: integer(),
    bw_time :: integer(),
    session_ops :: #{op_id() => #session_op{}},
    calls = #{} :: #{CallId::binary() => {pid(), reference()}},
    verto :: verto()
}).


%% @private
-spec transports(nklib:scheme()) ->
    [nkpacket:transport()].

transports(_) -> [wss, ws].

-spec default_port(nkpacket:transport()) ->
    inet:port_number() | invalid.

default_port(ws) -> 8081;
default_port(wss) -> 8082.


-spec conn_init(nkpacket:nkport()) ->
    {ok, #state{}}.

conn_init(NkPort) ->
    {ok, {nkmedia_verto, SrvId}, _} = nkpacket:get_user(NkPort),
    {ok, Remote} = nkpacket:get_remote_bin(NkPort),
    Verto = #{remote=>Remote, srv_id=>SrvId},
    State1 = #state{srv_id=SrvId, session_ops=#{}, verto=Verto},
    nklib_proc:put(?MODULE, <<>>),
    lager:info("NkMEDIA Verto new connection (~s, ~p)", [Remote, self()]),
    {ok, State2} = handle(nkmedia_verto_init, [NkPort], State1),
    {ok, State2}.


%% @private
-spec conn_parse(term()|close, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_parse(close, _NkPort, State) ->
    {ok, State};

%% Start of client bandwith test
conn_parse({text, <<"#SPU ", BytesBin/binary>>}, _NkPort, State) ->
    Bytes = nklib_util:to_integer(BytesBin),
    262144 = Bytes,
    Now = nklib_util:l_timestamp(),
    ?PRINT("client BW start test (SPU, ~p)", [Bytes], State),
    State2 = State#state{bw_bytes=Bytes, bw_time=Now},
    {ok, State2};

%% Client sends bw data
conn_parse({text, <<"#SPB", _/binary>>=Msg}, _NkPort, State) ->
    Size = byte_size(Msg) - 4,
    #state{bw_bytes=Bytes} = State,
    {ok, State#state{bw_bytes=Bytes-Size}};

%% Client sends bw end
conn_parse({text, <<"#SPE">>}, NkPort, State) ->
    #state{bw_bytes=Bytes, bw_time=Time} = State,
    Now = nklib_util:l_timestamp(),
    case (Now - Time) div 1000 of
        0 -> 
            ?LLOG(warning, "client bw test error1", [], State),
            {ok, State};
        ClientDiff when Bytes==0 ->
            ?PRINT("client BW completed (~p msecs, ~p Kbps)", 
                   [ClientDiff, 262144*8 div ClientDiff], State),
            %% We send start of server bw test
            Msg1 = <<"#SPU ", (nklib_util:to_binary(ClientDiff))/binary>>,
            case send(Msg1, NkPort) of
                ok ->
                    case send_bw_test(NkPort) of
                        {ok, ServerDiff} ->
                            ?PRINT("BW server completed (~p msecs, ~p Kpbs)",
                                   [ServerDiff, 262144*8 div ServerDiff], State),
                            %% We send end of server bw test
                            Msg2 = <<"#SPD ", (nklib_util:to_binary(ServerDiff))/binary>>,
                            send(Msg2, NkPort, State);
                        {error, Error} ->
                           ?LLOG(warning, "server bw test error2: ~p", [Error], State),
                           {stop, normal, State}
                    end;
                {error, _} ->
                    {stop, normal, State}
            end;
        _ ->
            ?LLOG(warning, "client bw test error3", [], State),
            {stop, normal, State}
    end;

conn_parse({text, Data}, NkPort, State) ->
    Msg = case nklib_json:decode(Data) of
        error ->
            ?LLOG(warning, "JSON decode error: ~p", [Data], State),
            error(json_decode);
        Json ->
            Json
    end,
    ?PRINT("received ~s", [Msg], State),
    case nkmedia_fs_util:verto_class(Msg) of
        {{req, Method}, _Id} ->
            process_client_req(Method, Msg, NkPort, State);
        {{resp, Resp}, Id} ->
            case extract_op({trans, Id}, State) of
                {Op, State2} ->
                    process_client_resp(Op, Resp, Msg, NkPort, State2);
                not_found ->
                    ?LLOG(warning, "received client response for unknown req: ~p", 
                          [Msg], State),
                    {ok, State}
            end;
        unknown ->
            {ok, State}
    end.


-spec conn_encode(term(), nkpacket:nkport()) ->
    {ok, nkpacket:outcoming()} | continue | {error, term()}.

conn_encode(Msg, _NkPort) when is_map(Msg) ->
    Json = nklib_json:encode(Msg),
    {ok, {text, Json}};

conn_encode(Msg, _NkPort) when is_binary(Msg) ->
    {ok, {text, Msg}}.


-spec conn_handle_call(term(), {pid(), term()}, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_call(Msg, From, NkPort, State) ->
    case handle_op(Msg, From, NkPort, State) of
        unknown_op ->
            handle(nkmedia_verto_handle_call, [Msg, From], State);
        Other ->
            Other
    end.


-spec conn_handle_cast(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_cast(Msg, NkPort, State) ->
    case handle_op(Msg, undefined, NkPort, State) of
        unknown_op ->
            handle(nkmedia_verto_handle_cast, [Msg], State);
        Other ->
            Other
    end.


-spec conn_handle_info(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_info({'DOWN', Ref, process, _Pid, _Reason}=Info, _NkPort, State) ->
    #state{calls=Calls} = State,
    case lists:keyfind(Ref, 2, maps:to_list(Calls)) of
        {CallId, Ref} ->
            ?LLOG(notice, "monitor process down for ~s", [CallId], State),
            hangup(self(), CallId, <<"Process Down">>),
            Calls2 = maps:remove(CallId, Calls),
            {ok, State#state{calls=Calls2}};
        false ->
            handle(nkmedia_verto_handle_info, [Info], State)
    end;

conn_handle_info({timeout, _, {op_timeout, OpId}}, _NkPort, State) ->
    case extract_op(OpId, State) of
        {Op, State2} ->
            user_reply(Op, {error, timeout}),
            ?LLOG(warning, "operation ~p timeout!", [OpId], State),
            {stop, normal, State2};
        not_found ->
            {ok, State}
    end;

conn_handle_info(Info, _NkPort, State) ->
    handle(nkmedia_verto_handle_info, [Info], State).


%% @doc Called when the connection stops
-spec conn_stop(Reason::term(), nkpacket:nkport(), #state{}) ->
    ok.

conn_stop(Reason, _NkPort, State) ->
    catch handle(nkmedia_verto_terminate, [Reason], State).



%% ===================================================================
%% Requests
%% ===================================================================

%% @private
handle_op({invite, CallId, Opts}, From, NkPort, State) ->
    Pid = maps:get(monitor, Opts, undefined),
    State2 = add_call(CallId, Pid, State),
    send_client_req({invite, CallId, Opts}, From, NkPort, State2);

handle_op({answer, CallId, Opts}, From, NkPort, State) ->
    send_client_req({answer, CallId, Opts}, From, NkPort, State);

handle_op({hangup, CallId, Reason}, From, NkPort, #state{calls=Calls}=State) ->
    case maps:is_key(CallId, Calls) of
        true ->
            State2 = del_call(CallId, State),
            send_client_req({hangup, CallId, Reason}, From, NkPort, State2);
        false ->
            {ok, State}
    end;

handle_op(_Op, _From, _NkPort, _State) ->
    unknown_op.


%% @private
process_client_req(<<"login">>, Msg, NkPort, State) ->
    #{<<"params">> := Params} = Msg,
    case Params of
        #{
            <<"login">> := Login,
            <<"passwd">> := Passwd,
            <<"sessid">> := SessId
        } ->
            case handle(nkmedia_verto_login, [SessId, Login, Passwd], State) of
                {true, State2} ->
                    Login2 = Login;
                {true, Login2, State2} ->
                    ok;
                {false, State2} ->
                    Login2 = unauthorized
            end,
            case Login2 of
                unauthorized ->
                    Reply = make_error(-32001, "Authentication Failure", Msg),
                    send(Reply, NkPort, State2);
                _ ->
                    nklib_proc:put(?MODULE, Login2),
                    nklib_proc:put({?MODULE, user, Login2}),
                    State3 = State2#state{sess_id=SessId, user=Login2},
                    ReplyParams = #{
                        <<"message">> => <<"logged in">>, 
                        <<"sessid">> => SessId
                    },
                    Reply = nkmedia_fs_util:verto_resp(ReplyParams, Msg),
                    send(Reply, NkPort, State3)
            end;
        _ ->
            Reply = make_error(-32000, "Authentication Required", Msg),
            send(Reply, NkPort, State)
    end;

process_client_req(_, Msg, NkPort, #state{sess_id = <<>>}=State) ->
    Reply = make_error(-32000, "Authentication Required", Msg),
    send(Reply, NkPort, State);

process_client_req(<<"verto.invite">>, Msg, NkPort, State) ->
    #{<<"params">> := #{<<"dialogParams">>:=Params, <<"sdp">>:=SDP}} = Msg,
    #{
        <<"callID">> := CallId, 
        <<"destination_number">> := Dest,
        <<"caller_id_name">> := CallerName,
        <<"caller_id_number">> := CallerId,
        <<"incomingBandwidth">> := InBW,
        <<"outgoingBandwidth">> := OutBW,
        <<"remote_caller_id_name">> := CalleeName,
        <<"remote_caller_id_number">> := CalleeId,
        <<"screenShare">> := UseScreen,
        <<"useStereo">> := UseStereo,
        <<"useVideo">> :=  UseVideo
    } = Params,
    #state{sess_id=SessionId} = State,
    nklib_proc:put({?MODULE, call, CallId}),
    Offer = #{
        sdp => SDP, 
        sdp_type => webrtc, 
        use_audio => true,
        use_stereo => UseStereo,
        use_video => UseVideo,
        use_sceen => UseScreen,
        in_bw => InBW,
        out_bw => OutBW,
        caller_name => CallerName,
        caller_id => CallerId,
        callee_name => CalleeName,
        callee_id => CalleeId,
        dest => Dest,
        verto_params => Params
    },
    case handle(nkmedia_verto_invite, [CallId, Offer], State) of
        {ok, Pid, State2} -> 
            ok;
        {answer, Answer, Pid, State2} -> 
            gen_server:cast(self(), {answer, CallId, Answer});
        {hangup, Reason, State2} -> 
            Pid = undefined,
            hangup(self(), CallId, Reason)
    end,
    State3 = add_call(CallId, Pid, State2),
    Data = #{
        <<"callID">> => CallId,
        <<"message">> => <<"CALL CREATED">>,
        <<"sessid">> => SessionId
    },
    Resp = nkmedia_fs_util:verto_resp(Data, Msg),
    send(Resp, NkPort, State3);

process_client_req(<<"verto.answer">>, Msg, NkPort, State) ->
    #{<<"params">> := #{
        <<"dialogParams">> := Params,  
        <<"sdp">> := SDP, 
        <<"sessid">> := SessId}
    } = Msg,
    #{<<"callID">> := CallId} = Params,
    Answer = #{sdp=>SDP, sdp_type=>webrtc, verto_params=>Params},
    case extract_op({wait_answer, CallId}, State) of
        not_found ->
            ?LLOG(warning, "received unexpected answer", [], State),
            hangup(self(), CallId, 503),
            State2 = State;
        {Op, State2} ->
            user_reply(Op, {answered, Answer})
    end,
    case handle(nkmedia_verto_answer, [CallId, Answer], State2) of
        {ok, State3} -> 
            ok;
        {hangup, Reason, State3} -> 
            hangup(self(), CallId, Reason)
    end,
    #state{sess_id=SessId} = State3,
    Data = #{<<"sessid">> => SessId},
    Resp = nkmedia_fs_util:verto_resp(Data, Msg),
    send(Resp, NkPort, State3);

process_client_req(<<"verto.bye">>, Msg, NkPort, State) ->
    #{<<"params">> := #{<<"dialogParams">>:=Params,  <<"sessid">>:=SessId}} = Msg,
    #{<<"callID">> := CallId} = Params,
    case extract_op({wait_answer, CallId}, State) of
        not_found ->
            State2 = State;
        {Op, State2} ->
            user_reply(Op, hangup)
    end,
    State3 = del_call(CallId, State2),
    {ok, State4} = handle(nkmedia_verto_bye, [CallId], State3),
    #state{sess_id=SessId} = State4,
    Data = #{<<"callID">> => CallId, <<"sessid">> => SessId},
    Resp = nkmedia_fs_util:verto_resp(Data, Msg),
    send(Resp, NkPort, State4);

process_client_req(<<"verto.info">>, Msg, NkPort, State) ->
    #{<<"params">> := #{
        <<"dialogParams">> := Params,  
        <<"dtmf">> := DTMF, 
        <<"sessid">> := SessId}
    } = Msg,
    #{<<"callID">> := CallId} = Params,
    {ok, State2} = handle(nkmedia_verto_dtmf, [CallId, DTMF], State),
    #state{sess_id=SessId} = State2,
    Data = #{<<"message">> => <<"SENT">>, <<"sessid">> => SessId},
    Resp = nkmedia_fs_util:verto_resp(Data, Msg),
    send(Resp, NkPort, State2);

process_client_req(Method, Msg, _NkPort, State) ->
    ?LLOG(warning, "unexpected client request ~s: ~p", [Method, Msg], State),
    {ok, State}.


%% @private
process_client_resp(#session_op{type={invite, CallId, Opts}, from=From}, 
                    Resp, _Msg, _NkPort, State) ->
    Async = maps:get(async, Opts, false),
    case Resp of
        {ok, _} when Async -> 
            Ref = make_ref(),
            gen_server:reply(From, {async, self(), Ref}),
            {Pid, _} = From,
            {ok, insert_op({wait_answer, CallId}, none, {async, Pid, Ref}, State)};
        {ok, _} ->
            {ok, insert_op({wait_answer, CallId}, none, From, State)};
        {error, Code, Error} -> 
            nklib_util:reply(From, {error, {Code, Error}}),
            {ok, State}
    end;

process_client_resp(#session_op{from=From}, Resp, _Msg, _NkPort, State) ->
    case Resp of
        {ok, _} -> 
            nklib_util:reply(From, ok);
        {error, Code, Error} -> 
            nklib_util:reply(From, {error, {Code, Error}})
    end,
    {ok, State}.



%% ===================================================================
%% Util
%% ===================================================================

%% @private
call(VertoPid, Msg) ->
    nklib_util:call(VertoPid, Msg, 1000*?CALL_TIMEOUT).


%% @private
send_client_req(Type, From, NkPort, #state{current_id=Id}=State) ->
    {ok, Msg} = make_msg(Id, Type, State),
    State2 = insert_op({trans, Id}, Type, From, State),
    send(Msg, NkPort, State2#state{current_id=Id+1}).


%% @private
make_msg(Id, {invite, CallId, Opts}, State) ->
    #state{sess_id=SessId} = State,
    Params = #{
        <<"callID">> => CallId, 
        <<"sdp">> => maps:get(sdp, Opts),
        <<"callee_id_name">> => maps:get(callee_name, Opts, <<"Outbound Call">>),
        <<"callee_id_number">> => maps:get(callee_id, Opts, SessId),
        <<"caller_id_name">> => maps:get(caller_name, Opts, <<"My Name">>),
        <<"caller_id_number">> => maps:get(caller_id, Opts, <<"0000000000">>),
        <<"display_direction">> => <<"outbound">>
    },
    {ok, nkmedia_fs_util:verto_req(Id, <<"verto.invite">>, Params)};

make_msg(Id, {answer, CallId, Opts}, _State) ->
    #{sdp:=SDP} = Opts,
    Params = #{<<"callID">> => CallId, <<"sdp">> => SDP},
    {ok, nkmedia_fs_util:verto_req(Id, <<"verto.answer">>, Params)};

make_msg(Id, {hangup, CallId, Reason}, _State) ->
    {Code, Text} = nkmedia_util:get_q850(Reason),
    Params = #{<<"callID">>=>CallId, <<"causeCode">>=>Code, <<"cause">>=>Text},
    {ok, nkmedia_fs_util:verto_req(Id, <<"verto.bye">>, Params)}.


%% @private
insert_op(OpId, Type, From, #state{session_ops=AllOps}=State) ->
    Time = case OpId of
        {wait_answer, _} -> ?CALL_TIMEOUT;
        _ -> ?OP_TIMEOUT
    end,
    NewOp = #session_op{
        type = Type,
        from = From,
        timer = erlang:start_timer(1000*Time, self(), {op_timeout, OpId})
    },
    State#state{session_ops=maps:put(OpId, NewOp, AllOps)}.


%% @private
extract_op(OpId, #state{session_ops=AllOps}=State) ->
    case maps:find(OpId, AllOps) of
        {ok, #session_op{timer=Timer}=OldOp} ->
            nklib_util:cancel_timer(Timer),
            State2 = State#state{session_ops=maps:remove(OpId, AllOps)},
            {OldOp, State2};
        error ->
            not_found
    end.


%% @private
add_call(CallId, Pid, #state{calls=Calls}=State) ->
    nklib_proc:put({?MODULE, call, CallId}),
    case maps:is_key(CallId, Calls) of
        false ->
            Ref = case is_pid(Pid) of
                true -> monitor(process, Pid);
                _ -> undefined
            end,
            Calls2 = maps:put(CallId, Ref, Calls),
            State#state{calls=Calls2};
        true ->
            ?LLOG(notice, "duplicated reg!", [], State),
            State
    end.


%% @private
del_call(CallId, #state{calls=Calls}=State) ->
    nklib_proc:del({?MODULE, call, CallId}),
    case maps:find(CallId, Calls) of
        {ok, Ref} -> nklib_util:demonitor(Ref);
        error -> ok
    end,
    State#state{calls=maps:remove(CallId, Calls)}.


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
make_error(Code, Txt, Msg) ->
    nkmedia_fs_util:verto_error(Code, Txt, Msg).


%% @private
handle(Fun, Args, State) ->
    nklib_gen_server:handle_any(Fun, Args, State, #state.srv_id, #state.verto).
    

%% @private
print(Txt, [#{}=Map], State) ->
    print(Txt, [nklib_json:encode_pretty(Map)], State);
print(Txt, Args, State) ->
    ?LLOG(info, Txt, Args, State).


%%%% Bandwith test


%% @private
send_bw_test(NkPort) ->
    case send_bw_test(10, 0, NkPort) of
        {ok, Time} -> {ok, max(1, Time div 10)};
        {error, Error} -> {error, Error}
    end.


%% @private
send_bw_test(0, Acc, _NkPort) ->
    {ok, Acc};

send_bw_test(Iter, Acc, NkPort) ->
    Start = nklib_util:l_timestamp(),
    case nkpacket_connection_lib:raw_send(NkPort, fun bw_frames/0) of
        ok -> 
            Time = (nklib_util:l_timestamp() - Start) div 1000,
            % lager:warning("TIME: ~p", [Time]),
            send_bw_test(Iter-1, Acc+Time, NkPort);
        {error, Error} -> 
            {error, Error}
    end.


%% @private
user_reply(#session_op{from={async, Pid, Ref}}, Msg) ->
    Pid ! {?MODULE, Ref, Msg};
user_reply(#session_op{from=From}, Msg) ->
    gen_server:reply(From, Msg).


%% @private Send 256*1024 => 262144 bytes
bw_frames() ->
    [{text, bw_msg()} || _ <- lists:seq(1,256)].


%% @private. A 1024 value
bw_msg() ->
     <<"#SPB............................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................">>.


