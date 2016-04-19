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

-export([invite/4, answer/3, bye/2, bye/3, get_user/1, get_all/0]).
-export([transports/1, default_port/1]).
-export([conn_init/1, conn_encode/2, conn_parse/3, conn_handle_call/4, 
         conn_handle_cast/3, conn_handle_info/3, conn_stop/3]).
-export([print/3]).
-export_type([invite_opts/0]).


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Verto Plugin (~s) "++Txt, [State#state.user | Args])).

-define(PRINT(Txt, Args, State), 
        % print(Txt, Args, State),    % Uncomment this for detailed logs
        ok).


-define(OP_TIME, 15000).            % Maximum operation time
-define(CALL_TIMEOUT, 30000).       % 


%% ===================================================================
%% Public
%% ===================================================================


-type invite_opts() ::
    #{
        async => boolean(),
        callee_id_name => binary(),
        callee_id_number => binary(),
        caller_id_name => binary(),
        caller_id_number => binary()
    }.


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Sends an INVITE. 
%% If async=true, the pid() of the process and a reference() will be returned,
%% and a message {?MODULE, Ref, {ok, SDP, Dialog}} or {?MODULE, Ref, {error, Error}}
%% will be sent to the calling process
-spec invite(pid(), binary(), binary(), invite_opts()) ->
    {ok, SDP::binary(), Dialog::map()} | {error, term()} |
    {async, pid(), reference()}.
    
invite(Pid, CallId, SDP, Opts) ->
    call(Pid, {invite, CallId, SDP, Opts}).


%% @doc Sends an ANSWER
-spec answer(pid(), binary(), binary()) ->
    ok | {error, term()}.

answer(Pid, CallId, SDP) ->
    call(Pid, {answer, CallId, SDP}).


%% @doc Equivalent to bye(Pid, CallId, 16)
-spec bye(pid(), binary()) ->
    ok.

bye(Pid, CallId) ->
    bye(Pid, CallId, 16).


%% @doc Sends a BYE. It is non-blocking
-spec bye(pid(), binary(), integer()) ->
    ok | {error, term()}.

bye(Pid, CallId, Code) when is_integer(Code)->
    gen_server:cast(Pid, {bye, CallId, Code}).


%% @doc Gets the pids() for currently logged user
-spec get_user(binary()) ->
    [pid()].

get_user(Login) ->
    Login2 = nklib_util:to_binary(Login),
    [Pid || {undefined, Pid} <- nklib_proc:values({?MODULE, user, Login2})].


%% @private
-spec get_all() ->
    [pid()].

get_all() ->
    [Pid || {undefined, Pid} <- nklib_proc:values(?MODULE)].


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
    remote :: binary(),
    callback :: atom(),
    sess_id = <<>> :: binary(),
    user = <<"undefined">> :: binary(),
    current_id = 1 :: integer(),
    bw_bytes :: integer(),
    bw_time :: integer(),
    session_ops :: #{op_id() => #session_op{}},
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
    State1 = #state{
        remote = Remote, 
        callback = Callback, 
        session_ops = #{},
        substate=#{}
    },
    nklib_proc:put(?MODULE),
    ?LLOG(info, "new connection (~p, ~p)", [Callback, self()], State1),
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
            case handle(nkmedia_verto_handle_call, [Msg, From], State) of
                {continue, [Msg2, _From2, State2]} ->
                    lager:error("Module ~p received unexpected call: ~p", 
                                [?MODULE, Msg2]),
                    {ok, State2};
                Other ->
                    Other
            end;
        Other ->
            Other
    end.


-spec conn_handle_cast(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_cast(Msg, NkPort, State) ->
    case handle_op(Msg, undefined, NkPort, State) of
        unknown_op ->
            case handle(nkmedia_verto_handle_cast, [Msg], State) of
                {continue, [Msg2, State2]} ->
                    lager:error("Module ~p received unexpected cast: ~p", 
                                [?MODULE, Msg2]),
                    {ok, State2};
                Other ->
                    Other
            end;
        Other ->
            Other
    end.


-spec conn_handle_info(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_info({timeout, _, {op_timeout, OpId}}, _NkPort, State) ->
    case extract_op(OpId, State) of
        {#session_op{from=From}, State2} ->
            case From of
                {async, Pid, Ref} ->
                    Pid ! {?MODULE, Ref, {error, timeout}};
                {_, _} ->
                    gen_server:reply(From, {error, timeout})
            end,
            ?LLOG(warning, "operation timeout", [], State),
            {ok, State2};
        not_found ->
            {ok, State}
    end;

conn_handle_info(Info, _NkPort, State) ->
    case handle(nkmedia_verto_handle_info, [Info], State) of
        {continue, [Msg2, State2]} ->
            lager:error("Module ~p received unexpected info: ~p", 
                        [?MODULE, Msg2]),
            {ok, State2};
        Other ->
            Other
    end.



%% @doc Called when the connection stops
-spec conn_stop(Reason::term(), nkpacket:nkport(), #state{}) ->
    ok.

conn_stop(Reason, _NkPort, State) ->
    catch handle(nkmedia_verto_terminate, [Reason], State).



%% ===================================================================
%% Requests
%% ===================================================================

%% @private
handle_op({invite, CallId, SDP, Opts}, From, NkPort, State) ->
    send_client_req({invite, CallId, SDP, Opts}, From, NkPort, State);

handle_op({answer, CallId, SDP}, From, NkPort, State) ->
    send_client_req({answer, CallId, SDP}, From, NkPort, State);

handle_op({bye, CallId, Code}, From, NkPort, State) ->
    send_client_req({bye, CallId, Code}, From, NkPort, State);

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
                    ReplyParams = #{
                        <<"message">> => <<"logged in">>, 
                        <<"sessid">> => SessId
                    },
                    nklib_proc:put({?MODULE, user, Login}),
                    Reply = nkmedia_fs_util:verto_resp(ReplyParams, Msg),
                    State3 = State2#state{sess_id=SessId, user=Login},
                    send(Reply, NkPort, State3);
                {false, State2} ->
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
    case handle(nkmedia_verto_invite, [CallId, Dest, SDP, Dialog], State) of
        {ok, State2} -> 
            ok;
        {answer, SDP_B, State2} -> 
            gen_server:cast(self(), {answer, CallId, SDP_B});
        {bye, Code, State2} -> 
            bye(self(), CallId, Code)
    end,
    #state{sess_id=SessionId} = State,
    Data = #{
        <<"callID">> => CallId,
        <<"message">> => <<"CALL CREATED">>,
        <<"sessid">> => SessionId
    },
    Resp = nkmedia_fs_util:verto_resp(Data, Msg),
    send(Resp, NkPort, State2);

process_client_req(<<"verto.answer">>, Msg, NkPort, State) ->
    #{<<"params">> := #{
        <<"dialogParams">> := Dialog,  
        <<"sdp">> := SDP, 
        <<"sessid">> := SessId}
    } = Msg,
    #{<<"callID">> := CallId} = Dialog,
    case handle(nkmedia_verto_answer, [CallId, SDP, Dialog], State) of
        {ok, State2} -> 
            ok;
        {bye, Code, State2} -> 
            bye(self(), CallId, Code)
    end,
    case extract_op({wait_answer, CallId}, State2) of
        {#session_op{from={async, Pid, Ref}}, State3} ->
            Pid ! {?MODULE, Ref, {ok, SDP, Dialog}};
        {#session_op{from=From}, State3} ->
            gen_server:reply(From, {ok, SDP, Dialog});
        not_found ->
            ?LLOG(warning, "received unexpected answer", [], State),
            bye(self(), CallId, 503),
            State3 = State
    end,
    #state{sess_id=SessId} = State,
    Data = #{<<"sessid">> => SessId},
    Resp = nkmedia_fs_util:verto_resp(Data, Msg),
    send(Resp, NkPort, State3);

process_client_req(<<"verto.bye">>, Msg, NkPort, State) ->
    #{<<"params">> := #{<<"dialogParams">>:=Dialog,  <<"sessid">>:=SessId}} = Msg,
    #{<<"callID">> := CallId} = Dialog,
    #state{sess_id=SessId} = State,
    {ok, State2} = handle(nkmedia_verto_bye, [CallId], State),
    Data = #{
        <<"callID">> => CallId,
        % <<"cause">> => <<"NORMAL_CLEARING">>,
        % <<"causeCode">> => 16,
        % <<"message">> => <<"CALL ENDED">>,
        <<"sessid">> => SessId
    },
    Resp = nkmedia_fs_util:verto_resp(Data, Msg),
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
    Resp = nkmedia_fs_util:verto_resp(Data, Msg),
    send(Resp, NkPort, State2);

process_client_req(Method, Msg, _NkPort, State) ->
    ?LLOG(warning, "unexpected client request ~s: ~p", [Method, Msg], State),
    {ok, State}.


%% @private
process_client_resp(#session_op{type={invite, CallId, _SDP, Opts}, from=From}, 
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
        {ok, _} -> nklib_util:reply(From, ok);
        {error, Code, Error} -> nklib_util:reply(From, {error, {Code, Error}})
    end,
    {ok, State}.



%% ===================================================================
%% Util
%% ===================================================================

%% @private
call(VertoPid, Msg) ->
    nklib_util:call(VertoPid, Msg, ?CALL_TIMEOUT).


%% @private
send_client_req(Type, From, NkPort, #state{current_id=Id}=State) ->
    {ok, Msg} = make_msg(Id, Type, State),
    State2 = insert_op({trans, Id}, Type, From, State),
    send(Msg, NkPort, State2#state{current_id=Id+1}).


%% @private
make_msg(Id, {invite, CallId, SDP, Opts}, State) ->
    #state{sess_id=SessId} = State,
    Params = #{
        <<"callID">> => CallId, 
        <<"sdp">> => SDP,
        <<"callee_id_name">> => maps:get(callee_id_name, Opts, <<"Outbound Call">>),
        <<"callee_id_number">> => maps:get(callee_id_number, Opts, SessId),
        <<"caller_id_name">> => maps:get(caller_id_name, Opts, <<"My Name">>),
        <<"caller_id_number">> => maps:get(callee_id_number, Opts, <<"0000000000">>),
        <<"display_direction">> => <<"outbound">>
    },
    {ok, nkmedia_fs_util:verto_req(Id, <<"verto.invite">>, Params)};

make_msg(Id, {answer, CallId, SDP}, _State) ->
    Params = #{<<"callID">> => CallId, <<"sdp">> => SDP},
    {ok, nkmedia_fs_util:verto_req(Id, <<"verto.answer">>, Params)};

make_msg(Id, {bye, CallId, Code}, _State) ->
    Reason = nkmedia_util:q850_to_msg(Code),
    Params = #{<<"callID">>=>CallId, <<"causeCode">>=>Code, <<"cause">>=>Reason},
    {ok, nkmedia_fs_util:verto_req(Id, <<"verto.bye">>, Params)}.


%% @private
insert_op(OpId, Type, From, #state{session_ops=AllOps}=State) ->
    NewOp = #session_op{
        type = Type,
        from = From,
        timer = erlang:start_timer(?OP_TIME, self(), {op_timeout, OpId})
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
    nklib_gen_server:handle_any(Fun, Args, State, #state.callback, #state.substate).
    

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


