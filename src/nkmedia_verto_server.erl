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

%% @doc Full verto server to use with verto clients
-module(nkmedia_verto_server).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([invite/4, answer/4, bye/2, get_user/1, get_all/0]).
-export([transports/1, default_port/1]).
-export([conn_init/1, conn_encode/2, conn_parse/3, conn_handle_call/4, 
         conn_handle_info/3, conn_stop/3]).
-export([print/3]).

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA verto server (~s) "++Txt, 
               [State#state.user | Args])).

-define(PRINT(Txt, Args, State), 
        print(Txt, Args, State),    % Comment this
        ok).

-define(OP_TIME, 15000).    % Maximum operation time
-define(CALL_TIMEOUT, 30000).


%% ===================================================================
%% Callbacks
%% ===================================================================


-callback nkmedia_verto_init(nkpacket:nkport(), State::map()) ->
    {ok, State::map()}.


-callback nkmedia_verto_login(VertoSessId::binary(), Login::binary(), Pass::binary(),
                              State::map()) ->
    {ok, State::map()} | {error, term(), State::map()}.


-callback nkmedia_verto_invite(CallId::binary(), Dest::binary(), SDP::binary(),
                               Dialog::map(), State::map()) ->
    {ok, State::map()}.

-callback nkmedia_verto_answer(CallId::binary(), SDP::binary(), Dialog::map(), 
                               State::map()) ->
    {ok, State::map()}.

-callback nkmedia_verto_bye(CallId::binary(), State::map()) ->
    {ok, State::map()}.


-callback nkmedia_verto_dtmf(CallId::binary(), DTMF::binary(), State::map()) ->
    {ok, State::map()}.


-callback nkmedia_verto_terminate(Reason::term(), State::map()) ->
    {ok, State::map()}.

-callback nkmedia_verto_handle_call(Msg::term(), {pid(), term()}, State::map()) ->
    {ok, State::map()}.

-callback nkmedia_verto_handle_cast(Msg::term(), State::map()) ->
    {ok, State::map()}.

-callback nkmedia_verto_handle_info(Msg::term(), State::map()) ->
    {ok, State::map()}.


%% ===================================================================
%% Public
%% ===================================================================


%% @doc
-spec invite(pid(), binary(), binary(), map()) ->
    ok | {error, term()}.

invite(Pid, CallId, SDP, Dialog) ->
    call(Pid, {invite, CallId, SDP, Dialog}).


%% @doc
-spec answer(pid(), binary(), binary(), map()) ->
    ok | {error, term()}.

answer(Pid, CallId, SDP, Dialog) ->
    call(Pid, {answer, CallId, SDP, Dialog}).


%% @doc
-spec bye(pid(), binary()) ->
    ok.

bye(Pid, CallId) ->
    call(Pid, {bye, CallId}).


%% @doc
-spec get_user(binary()) ->
    {map(), pid()}.

get_user(Login) ->
    nklib_proc:values({?MODULE, user, nklib_util:to_binary(Login)}).


%% @doc
-spec get_all() ->
    {map(), pid()}.

get_all() ->
    nklib_proc:values(?MODULE).


%% @private
call(VertoPid, Msg) ->
    nklib_util:call(VertoPid, Msg, ?CALL_TIMEOUT).



%% ===================================================================
%% Protocol callbacks
%% ===================================================================

-type op_id() :: {invite|answer|bye, binary()}.

-record(session_op, {
    timer :: reference(),
    from :: {pid(), term()}
}).

-record(state, {
    remote :: binary(),
    callback :: atom(),
    sess_id = <<>> :: binary(),
    user = <<"undefined">> :: binary(),
    current_id = 1 :: integer(),
    bw_bytes :: integer(),
    bw_time :: integer(),
    timer :: reference(),
    session_ops = #{} :: #{op_id() => #session_op{}},
    call_id = <<>> :: binary(),
    substate :: map()
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
    {ok, _Class, #{callback:=Callback}} = nkpacket:get_user(NkPort),
    {ok, Remote} = nkpacket:get_remote_bin(NkPort),
    case erlang:function_exported(Callback, nkmedia_verto_init, 2) of
        true ->
            {ok, SubState} = Callback:nkmedia_verto_init(NkPort, #{});
        false ->
            SubState = #{}
    end,
    State = #state{remote=Remote, callback=Callback, substate=SubState},
    nklib_proc:put(?MODULE, #{remote=>Remote}),
    ?LLOG(info, "new connection (~p, ~p)", [Callback, self()], State),
    {ok, State}.


%% @private
-spec conn_parse(term()|close, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_parse(close, _NkPort, State) ->
    {ok, State};

% conn_parse({text, <<"#S", _/binary>>=Msg}, _NkPort, State) ->
%     #state{fs_sess_id_pid=FsSession} = State,
%     case FsSession of
%         undefined ->
%             ?LLOG(warning, "received bw test without login", [], State),
%             {stop, normal, State};
%         Pid ->
%             nkmedia_verto_client:send_bw_test(Pid, Msg),
%             {ok, State}
%     end;

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
    case nkmedia_verto_util:parse_class(Msg) of
        {{req, Method}, _Id} ->
            process_client_req(Method, Msg, NkPort, State);
        {{resp, Resp}, _Id} ->
            process_client_resp(Resp, Msg, NkPort, State);
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

conn_handle_call({invite, CallId, SDP, Dialog}, From, NkPort, State) ->
    #state{sess_id=SessId} = State,
    State2 = insert_op({invite, CallId}, From, State),
    Default = #{
        <<"callee_id_name">> => <<"Outbound Call">>,
        <<"callee_id_number">> => SessId,
        <<"caller_id_name">> => <<"My Name">>,
        <<"caller_id_number">> => <<"0000000000">>,
        <<"display_direction">> => <<"outbound">>
    },
    Data1 = maps:merge(Default, Dialog),
    Data2 = Data1#{<<"callID">>=>CallId, <<"sdp">> => SDP},
    send_req(<<"verto.invite">>, Data2, NkPort, State2);

conn_handle_call({answer, CallId, SDP, _Dialog}, From, NkPort, State) ->
    State2 = insert_op({answer, CallId}, From, State),
    Data = #{<<"dialogParams">>=>#{<<"callID">>=>CallId}, <<"sdp">>=>SDP},
    send_req(<<"verto.answer">>, Data, NkPort, State2);

conn_handle_call({bye, CallId}, From, NkPort, State) ->
    #state{sess_id=SessId} = State,
    State2 = insert_op({bye, CallId}, From, State),
    Data = #{<<"dialogParams">>=>#{<<"callID">>=>CallId}, <<"sessid">>=>SessId},
    send_req(<<"verto.bye">>, Data, NkPort, State2);

conn_handle_call(Msg, From, _NkPort, State) ->
    handle(nkmedia_verto_handle_call, [Msg, From], State).


-spec conn_handle_info(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_info({timeout, _, {op_timeout, OpId}}, _NkPort, State) ->
    case extract_op(OpId, State) of
        {#session_op{from=From}, State2} ->
            gen_server:reply(From, {error, timeout}),
            ?LLOG(warning, "operation timeout", [], State),
            {stop, normal, State2};
        not_found ->
            {ok, State}
    end;

conn_handle_info(Info, _NkPort, State) ->
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {ok, State}.


%% @doc Called when the connection stops
-spec conn_stop(Reason::term(), nkpacket:nkport(), #state{}) ->
    ok.

conn_stop(Reason, _NkPort, State) ->
    handle(nkmedia_verto_terminate, [Reason], State).



%% ===================================================================
%% Requests
%% ===================================================================

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
                {ok, State2} ->
                    ReplyParams = #{
                        <<"message">> => <<"logged in">>, 
                        <<"sessid">> => SessId
                    },
                    #state{remote=Remote} = State,
                    nklib_proc:put(?MODULE, Login),
                    nklib_proc:put({?MODULE, user, Login}, #{remote=>Remote}),
                    Reply = nkmedia_verto_util:make_resp(ReplyParams, Msg),
                    State3 = State2#state{sess_id=SessId, user=Login},
                    send(Reply, NkPort, State3);
                {error, Error, State2} ->
                    ?LLOG(info, "login user error for ~s: ~p", [Login, Error], State2),
                    Reply = make_error(-32001, "Authentication Failure", Msg),
                    send(Reply, NkPort, State2)
            end;
        _ ->
            Reply = make_error(-32000, "Authentication Required", Msg),
            send(Reply, NkPort, State)
    end;

process_client_req(_, Msg, NkPort, #state{sess_id = <<>>}=State) ->
    Reply = make_error(-32000, "Authentication Required", Msg),
    send(Reply, NkPort, State);

process_client_req(<<"verto.invite">>, Msg, NkPort, State) ->
    #{<<"params">> := #{<<"dialogParams">>:=Dialog, <<"sdp">>:=SDP}} = Msg,
    #{<<"callID">> := CallId, <<"destination_number">> := Dest} = Dialog,
    {ok, State2} = handle(nkmedia_verto_invite, [CallId, Dest, SDP, Dialog], State),
    #state{sess_id=SessionId} = State,
    Data = #{
        <<"callID">> => CallId,
        <<"message">> => <<"CALL CREATED">>,
        <<"sessid">> => SessionId
    },
    Resp = nkmedia_verto_util:make_resp(Data, Msg),
    send(Resp, NkPort, State2);

process_client_req(<<"verto.answer">>, Msg, NkPort, State) ->
    #{<<"params">> := #{
        <<"dialogParams">> := Dialog,  
        <<"sdp">> := SDP, 
        <<"sessid">> := SessId}
    } = Msg,
    #{<<"callID">> := CallId} = Dialog,
    #state{sess_id=SessId} = State,
    {ok, State2} = handle(nkmedia_verto_answer, [CallId, SDP, Dialog], State),
    Data = #{<<"method">> => <<"verto.answer">>},
    Resp = nkmedia_verto_util:make_resp(Data, Msg),
    send(Resp, NkPort, State2);

process_client_req(<<"verto.bye">>, Msg, NkPort, State) ->
    #{<<"params">> := #{<<"dialogParams">>:=Dialog,  <<"sessid">>:=SessId}} = Msg,
    #{<<"callID">> := CallId} = Dialog,
    #state{sess_id=SessId} = State,
    {ok, State2} = handle(nkmedia_verto_bye, [CallId], State),
    Data = #{
        <<"callID">> => CallId,
        <<"cause">> => <<"NORMAL_CLEARING">>,
        <<"causeCode">> => 16,
        <<"message">> => <<"CALL ENDED">>,
        <<"sessid">> => SessId
    },
    Resp = nkmedia_verto_util:make_resp(Data, Msg),
    send(Resp, NkPort, State2);

process_client_req(<<"verto.info">>, Msg, NkPort, State) ->
    #{<<"params">> := #{
        <<"dialogParams">> := Dialog,  
        <<"dtmf">> := DTMF, 
        <<"sessid">> := SessId}
    } = Msg,
    #{<<"callID">> := CallId} = Dialog,
    #state{sess_id=SessId} = State,
    {ok, State2} = handle(nkmedia_verto_dtmf, [CallId, DTMF], State),
    Data = #{
        <<"message">> => <<"SENT">>,
        <<"sessid">> => SessId
    },
    Resp = nkmedia_verto_util:make_resp(Data, Msg),
    send(Resp, NkPort, State2);

process_client_req(Method, Msg, _NkPort, State) ->
    ?LLOG(warning, "unexpected client request ~s: ~p", [Method, Msg], State),
    {ok, State}.


%% @private
process_client_resp({ok, <<"verto.invite">>}, Msg, _NkPort, State) ->
    #{<<"params">> := Params} = Msg,
    #{<<"callID">> := CallId} = Params, 
    case extract_op({invite, CallId}, State) of
        {#session_op{from=From}, State2} ->
            nklib_util:reply(From, ok),
            {ok, State2};
        not_found ->
            ?LLOG(warning, "received unexpected INVITE from Client", [], State),
            {stop, normal, State}
    end;

process_client_resp({ok, <<"verto.answer">>}, Msg, _NkPort, State) ->
    #{<<"params">> := #{<<"callID">>:=CallId}} = Msg,
    case extract_op({answer, CallId}, State) of
        {#session_op{from=From}, State2} ->
            nklib_util:reply(From, ok),
            {ok, State2};
        not_found ->
            ?LLOG(warning, "received unexpected ANSWER from Client", [], State),
            {stop, normal, State}
    end;

process_client_resp({ok, <<"verto.bye">>}, Msg, _NkPort, State) ->
    #{<<"params">> := #{<<"callID">>:=CallId}} = Msg,
    case extract_op({bye, CallId}, State) of
        {#session_op{from=From}, State2} ->
            nklib_util:reply(From, ok),
            {ok, State2};
        not_found ->
            ?LLOG(warning, "received unexpected BYE from Client", [], State),
            {stop, normal, State}
    end;

process_client_resp(Resp, Msg, _NkPort, State) ->
    ?LLOG(warning, "unexpected client response ~p: ~p", [Resp, Msg], State),
    {ok, State}.


%% ===================================================================
%% Util
%% ===================================================================

%% @private
insert_op(OpId, From, #state{session_ops=AllOps}=State) ->
    NewOp = #session_op{
        timer = erlang:start_timer(?OP_TIME, self(), op_timeout),
        from = From
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
send_req(Method, Data, NkPort, #state{current_id=Id}=State) ->
    Req = nkmedia_verto_util:make_req(Id, Method, Data),
    send(Req, NkPort, State#state{current_id=Id+1}).


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


% %% @private
% update_status(Status, #state{status=Status}=State) ->
%     State;

% update_status(NewStatus, #state{status=OldStatus, timer=Timer}=State) ->
%     nklib_util:cancel_timer(Timer),
%     Time = case NewStatus of
%         registered -> 0
%     end,
%     Timer = case Time of
%         0 -> undefined;
%         _ -> elang:start_timer(1000*Time, self(), nkmedia_timeout)
%     end,
%     ?LLOG(info, "status ~p -> ~p", [OldStatus, NewStatus], State),
%     State#state{timer=Timer}.


%% @private
make_error(Code, Txt, Msg) ->
    nkmedia_verto_util:make_error(Code, Txt, Msg).


%% @private
handle(Fun, Args, State) ->
    case 
        nklib_gen_server:handle_any(Fun, Args, State, #state.callback, #state.substate)
    of
        nklib_not_exported -> {ok, State};
        Other -> Other
    end.


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


%% @private Send 256*1024 => 262144 bytes
bw_frames() ->
    [{text, bw_msg()} || _ <- lists:seq(1,256)].


%% @private. A 1024 value
bw_msg() ->
     <<"#SPB............................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................">>.


