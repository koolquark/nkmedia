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
-module(nkmedia_verto_client).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/1, stop/1, get_all/0]).
-export([bw_test/2, invite/4, bye/2, dtmf/3, outbound/2, answer/4]).
-export([transports/1, default_port/1]).
-export([conn_init/1, conn_encode/2, conn_parse/3, conn_stop/3]).
-export([conn_handle_call/4, conn_handle_cast/3, conn_handle_info/3]).

-include("nkmedia.hrl").


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA verto client (~s) "++Txt, [State#state.call_id | Args])).

-define(PRINT(Txt, Args, State), 
        print(Txt, Args, State),    % Comment this
        ok).


-define(IN_BW, 12800).
-define(OUT_BW, 4800).
-define(OP_TIME, 15000).    % Maximum operation time
-define(CALL_TIMEOUT, 30000).


%% ===================================================================
%% Types
%% ===================================================================



%% ===================================================================
%% Public
%% ===================================================================



%% @doc Starts a new verto session to FS
-spec start(pid()) ->
    {ok, VertoId::binary(), pid()} | {error, term()}.

start(FsPid) ->
    {ok, #{host:=Host, pass:=Pass}} = nkmedia_fs_engine:get_config(FsPid),
    SessId = nklib_util:uuid_4122(),
    ConnOpts = #{
        class => ?MODULE,
        monitor => self(),
        idle_timeout => ?VERTO_WS_TIMEOUT,
        user => #{pass=>Pass, sess_id=>SessId}
    },
    {ok, Ip} = nklib_util:to_ip(Host),
    Conn = {?MODULE, ws, Ip, 8081},
    case nkpacket:connect(Conn, ConnOpts) of
        {ok, Pid} -> {ok, SessId, Pid};
        {error, Error} -> {error, Error}
    end.


%% @doc 
stop(VertoPid) ->
    nkpacket_connection:stop(VertoPid).


%% @doc
-spec bw_test(pid(), binary()) ->
    ok.

bw_test(VertoPid, <<"#S", _/binary>>=Data) ->
    nklib_util:call(VertoPid, {bw_test, Data, self()}, 30000).


%% @doc
-spec invite(pid(), binary(), binary(), #{binary() => term()}) ->
    {ok, CallId::binary(), SDP::binary()} | {error, term()}.

invite(VertoPid, Dest, SDP, Dialog) ->
    Dest1 = nklib_util:to_binary(Dest),
    SDP1 = nklib_util:to_binary(SDP), 
    Dialog2 = Dialog#{
        <<"incomingBandwidth">> => ?IN_BW,
        <<"outgoingBandwidth">> => ?OUT_BW
    },
    call(VertoPid, {invite, Dest1, SDP1, Dialog2}).


%% @doc
-spec bye(pid(), binary()) ->
    ok | {error, term()}.

bye(VertoPid, CallId) ->
    call(VertoPid, {bye, CallId}).


-spec dtmf(pid(), binary(), binary()) ->
    ok | {error, term()}.

dtmf(VertoPid, CallId, DTMF) ->
    call(VertoPid, {info, CallId, DTMF}).


-spec outbound(pid(), map()) ->
    {ok, CallId::binary(), SDP::binary()} | {error, term()}.

outbound(VertoPid, Dialog) ->
    call(VertoPid, {outbound, Dialog}).


%% @doc
answer(VertoPid, CallId, SDP, Dialog) ->
    Dialog2 = Dialog#{
        <<"incomingBandwidth">> => ?IN_BW,
        <<"outgoingBandwidth">> => ?OUT_BW
    },
    call(VertoPid, {answer, CallId, SDP, Dialog2}).


%% @private
get_all() ->
    [Pid || {undefined, Pid}<- nklib_proc:values(?MODULE)].


%% @private
call(VertoPid, Msg) ->
    nklib_util:call(VertoPid, Msg, ?CALL_TIMEOUT).


%% ===================================================================
%% Protocol callbacks
%% ===================================================================

-type op_id() :: bw_test | {trans, integer()} | {invite, binary()} | {answer, binary()}.

-type op_type() :: login1 | login2 | invite | subscription | bye | info | none.

-record(session_op, {
    type :: op_type(),
    timer :: reference(),
    from :: {pid(), term()}
}).

-record(state, {
    remote :: binary(),
    sess_id :: binary(),
    pass :: binary(),
    current_id = 1 :: pos_integer(),
    session_ops = #{} :: #{op_id() => #session_op{}},
    call_id = <<>> :: binary()
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
    {ok, Remote} = nkpacket:get_remote_bin(NkPort),
    {ok, _Class, User} = nkpacket:get_user(NkPort),
    #{pass:=Pass, sess_id:=SessId} = User,
    State = #state{
        sess_id = SessId,
        pass = Pass,
        remote = Remote
    },
    ?LLOG(info, "new connection (~p)", [self()], State),
    nklib_proc:put(?MODULE),
    self() ! login,
    % self() ! check_old_requests,
    {ok, State}.


%% @private
-spec conn_parse(term()|close, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_parse(close, _NkPort, State) ->
    {ok, State};

%% Messages received from FS
conn_parse({text, <<"#S", _/binary>>=Msg}, _NkPort, State) ->
    case extract_op(bw_test, State) of
        {#session_op{from=From}, State2} ->
            gen_server:reply(From, {ok, Msg}),
            {ok, State2};
        not_found ->
            ?LLOG(warning, "BW test reply without client", [], State),
            {ok, State}
    end;

conn_parse({text, Data}, NkPort, State) ->
    Msg = nklib_json:decode(Data),
    case Msg of
        error -> 
            ?LLOG(warning, "JSON decode error: ~p", [Data], State),
            error(json_decode);
        _ ->
            ok
    end,
    ?PRINT("received ~s", [Msg], State),
    case nkmedia_verto_util:parse_class(Msg) of
        {{req, Method}, _Id} ->
            process_server_req(Method, Msg, NkPort, State);
        {{resp, Resp}, Id} ->
            case extract_op({trans, Id}, State) of
                {Op, State2} ->
                    process_server_resp(Op, Resp, Msg, NkPort, State2);
                not_found ->
                    ?LLOG(warning, "received FS response for unknown req: ~p", 
                          [Msg], State),
                    {ok, State}
            end;
        event ->
            process_server_event(Msg, NkPort, State);
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


%% @private
-spec conn_handle_call(term(), {pid(), term()}, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_handle_call({bw_test, Data}, From, NkPort, State) -> 
    State2 = insert_op(bw_test, none, From, State),
    send(Data, NkPort, State2);

conn_handle_call({invite, Dest, SDP, Dialog}, From, NkPort, State) ->
    send_client_req(invite, {Dest, SDP, Dialog}, From, NkPort, State);

conn_handle_call({bye, CallId}, From, NkPort, State) ->
    send_client_req(bye, #{call_id=>CallId}, From, NkPort, State);

conn_handle_call({info, CallId, DTMF}, From, NkPort, State) ->
    send_client_req(info, #{call_id=>CallId, dtmf=>DTMF}, From, NkPort, State);

conn_handle_call({outbound, CallId, _Dialog}, From, _NkPort, State) ->
    State2 = insert_op({invite, CallId}, none, From, State),
    {ok, State2};

conn_handle_call({answer, CallId, SDP, Dialog}, From, NkPort, State) ->
    send_client_req(answer, {CallId, SDP, Dialog}, From, NkPort, State);

conn_handle_call(get_state, From, _NkPort, State) ->
    gen_server:reply(From, State),
    {ok, State};

conn_handle_call(Msg, _From, _NkPort, State) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {stop, unexpected_call, State}.


-spec conn_handle_cast(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_handle_cast(Msg, _NkPort, State) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {ok, State}.


%% @private
-spec conn_handle_info(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_handle_info(login, NkPort, State) ->
    send_client_req(login1, #{}, NkPort, undefined, State);

conn_handle_info({timeout, _, {op_timeout, OpId}}, _NkPort, State) ->
    case extract_op(OpId, State) of
        {#session_op{from=From}, State2} ->
            gen_server:reply(From, {error, timeout}),
            ?LLOG(warning, "operation timeout", [], State),
            {stop, normal, State2};
        not_found ->
            {ok, State}
    end;

conn_handle_info(Msg, _NkPort, State) ->
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
    {ok, State}.


%% @doc Called when the connection stops
-spec conn_stop(Reason::term(), nkpacket:nkport(), #state{}) ->
    ok.

conn_stop(_Reason, _NkPort, State) ->
    ?LLOG(notice, "connection stop", [], State).


%% ===================================================================
%% Util
%% ===================================================================



%% @private
send_client_req(Type, Data, From, NkPort, State) ->
    #state{current_id=Id} = State,
    {ok, Msg} = make_msg(Id, Type, Data, State),
    State2 = insert_op({trans, Id}, Type, From, State),
    send(Msg, NkPort, State2#state{current_id=Id+1}).


%% @private
process_server_resp(#session_op{type=login1}, {error, -32000, _},
                    _Msg, NkPort, State) ->
    send_client_req(login2, #{}, undefined, NkPort, State);

process_server_resp(#session_op{type=login2}, {ok, _}, _Msg, _NkPort, State) ->
    {ok, State};

process_server_resp(#session_op{type=login2}, {error, -32001, _},
                    _Msg, _NkPort, State) ->
    ?LLOG(warning, "auth error!", [], State),
    {stop, fs_auth_error, State};

process_server_resp(#session_op{type=invite, from=From}, {ok, _}, Msg, _NkPort, State) ->
    #{<<"result">> := #{<<"callID">> := CallId}} = Msg,
    State2 = insert_op({answer, CallId}, none, From, State),
    {ok, State2#state{call_id=CallId}};

process_server_resp(#session_op{type=invite}, {error, Code, Error}, 
                    _Msg, _NkPort, State) ->
    ?LLOG(warning, "invite error: ~p, ~p", [Code, Error], State),
    {stop, normal, State};

process_server_resp(#session_op{from=From}, {ok, _}, _Msg, _NkPort, State) ->
    nklib_util:reply(From, ok),
    {ok, State};

process_server_resp(#session_op{type=Type}, {error, Code, Error}, _Msg, _NkPort, State) ->
    ?LLOG(warning, "error response to ~p: ~p (~s)", [Type, Code, Error], State),
    {stop, normal, State}.


%% @private
process_server_req(<<"verto.invite">>, Msg, NkPort, State) ->
    #{<<"params">> := Params} = Msg,
    #{<<"callID">> := CallId, <<"sdp">> := SDP} = Params, 
    case extract_op({invite, CallId}, State) of
        {#session_op{from=From}, State2} ->
            nklib_util:reply(From, {ok, CallId, SDP}),
            Resp = nkmedia_verto_util:make_resp(<<"verto.invite">>, Msg),
            send(Resp, NkPort, State2#state{call_id=CallId});
        not_found ->
            ?LLOG(warning, "received unexpected INVITE from FS", [], State),
            {stop, normal, State}
    end;

process_server_req(<<"verto.answer">>, Msg, NkPort, State) ->
    #{<<"params">> := #{<<"callID">>:=CallId, <<"sdp">>:=SDP}} = Msg,
    case extract_op({answer, CallId}, State) of
        {#session_op{from=From}, State2} ->
            nklib_util:reply(From, {ok, CallId, SDP}),
            Resp = nkmedia_verto_util:make_resp(<<"verto.answer">>, Msg),
            send(Resp, NkPort, State2#state{call_id=CallId});
        error ->
            ?LLOG(warning, "unxpected verto.answer", [], State),
            {stop, normal, State}
    end;

process_server_req(<<"verto.attach">>, Msg, NkPort, State) ->
    #{<<"params">>:=#{<<"callID">>:=_CallId, <<"sdp">>:=_SDP}} = Msg,
    Msg2 = nkmedia_verto_util:make_resp(<<"verto.attach">>, Msg),
    send(Msg2, NkPort, State);

process_server_req(<<"verto.bye">>, Msg, NkPort, State) ->
    #{<<"params">>:=#{<<"callID">>:=_CallId}} = Msg,
    Msg2 = nkmedia_verto_util:make_resp(<<"verto.bye">>, Msg),
    send(Msg2, NkPort, State);

%% Sent when FS detects another session for the same session id
process_server_req(<<"verto.punt">>, _Msg, _NkPort, State) ->
    ?LLOG(notice, "stopping connection because of verto.punt", [], State),
    {stop, normal, State};
    
process_server_req(<<"verto.display">>, _Msg, _NkPort, State) ->
    {ok, State};

process_server_req(Req, Msg, _NkPort, State) ->
    ?LLOG(warning, "unexpected FS request ~s: ~p", [Req, Msg], State),
    {ok, State}.


%% @private
process_server_event(_Event, _NkPort, State) ->
    % lager:notice("Process server event: ~p", [Event]),
    {ok, State}.


%% @private
make_msg(Id, login1, _, State) ->
    #state{sess_id=SessId} = State,
    Params = #{<<"sessid">>=>SessId},
    {ok, nkmedia_verto_util:make_req(Id, <<"login">>, Params)};

make_msg(Id, login2, _, #state{pass=Pass}=State) ->
    #state{sess_id=SessId} = State,
    Params = #{
        <<"login">> => SessId,
        <<"passwd">> => Pass,
        <<"sessid">> => SessId
    },
    {ok, nkmedia_verto_util:make_req(Id, <<"login">>, Params)};

make_msg(Id, invite, {Dest, SDP, Dialog}, _State) ->
    CallId = case maps:find(<<"callID">>, Dialog) of
        {ok, CallId0} -> CallId0;
        error -> nklib_util:uuid_4122()
    end,
    Params = #{
        <<"dialogParams">> => 
            Dialog#{
                <<"callID">> => CallId,
                <<"destination_number">> => Dest
            },
        <<"sdp">> => SDP
    },
    % lager:warning("P: ~s", [nklib_json:encode_pretty(Params)]),
    {ok, nkmedia_verto_util:make_req(Id, <<"verto.invite">>, Params)};

make_msg(Id, bye, #{call_id:=CallId}, State) ->
    #state{sess_id = SessId} = State,
    Params = #{
        <<"dialogParams">> => #{ <<"CallID">> => CallId },
        <<"sessid">> => SessId
    },
    {ok, nkmedia_verto_util:make_req(Id, <<"verto.bye">>, Params)};

make_msg(Id, info, #{call_id:=CallId, dtmf:=DTMF}, State) ->
    #state{sess_id = SessId} = State,
    Params = #{
        <<"dialogParams">> => #{ <<"CallID">> => CallId },
        <<"dtmf">> => DTMF,
        <<"sessid">> => SessId
    },
    {ok, nkmedia_verto_util:make_req(Id, <<"verto.info">>, Params)};

make_msg(Id, answer, {CallId, SDP, Dialog}, _State) ->
    Params = #{
        <<"dialogParams">> => Dialog#{<<"callID">> => CallId},
        <<"sdp">> => SDP
    },
    {ok, nkmedia_verto_util:make_req(Id, <<"verto.answer">>, Params)}.


%% @private
insert_op(OpId, Type, From, #state{session_ops=AllOps}=State) ->
    NewOp = #session_op{
        type = Type, 
        timer = erlang:start_timer(?OP_TIME, self(), {op_timeout, OpId}),
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


send(Msg, NkPort, State) ->
    ?PRINT("sending ~s", [Msg], State),
    case send(Msg, NkPort) of
        ok -> 
            {ok, State};
        error -> 
            ?LLOG(notice, "error sending msg", [], State),
            {stop, normal, State}
    end.


%% @private
send(Msg, NkPort) ->
    nkpacket_connection:send(NkPort, Msg).


%% @private
print(Txt, [#{}=Map], State) ->
    print(Txt, [nklib_json:encode_pretty(Map)], State);
print(Txt, Args, State) ->
    ?LLOG(info, Txt, Args, State).








