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
-module(nkmedia_fs_verto).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start_in/3, start_out/3, answer_out/2, start/1, start/2, stop/1, get_all/0]).
-export([bw_test/2, invite/3, hangup/2, dtmf/3, outbound/3, answer/3, cmd/2]).
-export([transports/1, default_port/1]).
-export([conn_init/1, conn_encode/2, conn_parse/3, conn_stop/3]).
-export([conn_handle_call/4, conn_handle_cast/3, conn_handle_info/3]).
-export([print/3]).

-include("nkmedia.hrl").



-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA FS Verto (~s) "++Txt, [State#state.sess_id | Args])).

-define(PRINT(Txt, Args, State), 
        % print(Txt, Args, State),    % Comment this
        ok).


-define(OP_TIME, 5*60*1000).    % Maximum operation time
-define(CALL_TIMEOUT, 5*60*1000).
-define(CODECS, [opus,vp8,speex,iLBC,'GSM','PCMU','PCMA']).

-define(VERTO_WS_TIMEOUT, 60*60*1000).


%% ===================================================================
%% Types
%% ===================================================================

-type id() :: binary().


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Starts a new verto session and place an inbound call with the same 
%% CallId as the SessId.
-spec start_in(id(), nkmedia_fs_engine:id(), nkmedia:offer()) ->
    {ok, SDP::binary()} | {error, term()}.

start_in(SessId, FsId, Offer) ->
    case start(SessId, FsId) of
        {ok, SessPid} ->
            invite(SessPid, SessId, Offer#{callee_id=><<"nkmedia_in">>});
        {error, Error} ->
            {error, Error}
    end.


%% @doc Starts a new verto session and generates an outbound call with the same
%% CallId as the SessId. Must call answer_out/3.
-spec start_out(id(), nkmedia_fs_engine:id(), map()) ->
    {ok, SDP::binary()} | {error, term()}.

start_out(SessId, FsId, Opts) ->
    case start(SessId, FsId) of
        {ok, SessPid} ->
            outbound(SessPid, SessId, Opts);
        {error, Error} ->
            {error, Error}
    end.


%% @doc
-spec answer_out(id()|pid(), nkmedia:answer()) ->
    ok | {error, term()}.

answer_out(SessId, Answer) ->
    answer(SessId, SessId, Answer).


%% @doc Starts a new verto session to FS
-spec start(nkmedia_fs_engine:id()) ->
    {ok, pid()} | {error, term()}.

start(FsId) ->
    start(nklib_util:uuid_4122(), FsId).


%% @doc Starts a new verto session to FS
-spec start(id(), nkmedia_fs_engine:id()) ->
    {ok, pid()} | {error, term()}.

start(SessId, FsId) ->
    {ok, Config} = nkmedia_fs_engine:get_config(FsId),
    #{host:=Host, base:=Base, pass:=Pass} = Config,
    ConnOpts = #{
        class => ?MODULE,
        monitor => self(),
        idle_timeout => ?VERTO_WS_TIMEOUT,
        user => #{fs_id=>FsId, pass=>Pass, sess_id=>SessId}
    },
    {ok, Ip} = nklib_util:to_ip(Host),
    Conn = {?MODULE, ws, Ip, Base+1},
    case nkpacket:connect(Conn, ConnOpts) of
        {ok, Pid} -> 
            case nklib_util:call(Pid, login) of
                ok ->
                    {ok, Pid};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} -> 
            {error, Error}
    end.


%% @doc 
stop(SessId) ->
    cast(SessId, stop).


%% @doc
-spec bw_test(pid(), binary()) ->
    ok.

bw_test(SessId, <<"#S", _/binary>>=Data) ->
    call(SessId, {bw_test, Data, self()}).


%% @doc Sends an INVITE to FS
%% sdp and callee_id are expected, verto_params is supported
-spec invite(id()|pid(), binary(), nkmedia:offer()) ->
    {ok, SDP::binary()} | {error, term()}.

invite(SessId, CallId, #{sdp:=_, callee_id:=_}=Offer) ->
    call(SessId, {invite, CallId, Offer}).


%% @doc
-spec hangup(id()|pid(), binary()) ->
    ok | {error, term()}.

hangup(SessId, CallId) ->
    call(SessId, {hangup, CallId}).


-spec dtmf(id()|pid(), binary(), binary()) ->
    ok | {error, term()}.

dtmf(SessId, CallId, DTMF) ->
    call(SessId, {info, CallId, DTMF}).


-spec outbound(id()|pid(), binary(), OriginateVars::map()) ->
    {ok, SDP::binary()} | {error, term()}.

outbound(SessId, CallId, Opts) ->
    call(SessId, {outbound, CallId, Opts}).


%% @doc
-spec answer(id()|pid(), binary(), nkmedia:answer()) ->
    ok | {error, term()}.

answer(SessId, CallId, Answer) ->
    call(SessId, {answer, CallId, Answer}).


%% @private
cmd(SessId, Cmd) ->
    call(SessId, {cmd, Cmd}).


%% @private
-spec get_all() ->
    [{id(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).


%% @private
call(SessId, Msg) ->
    case find(SessId) of
        {ok, Pid} -> nklib_util:call(Pid, Msg, ?CALL_TIMEOUT);
        not_found -> {error, verto_client_not_found}
    end.


%% @private
cast(SessId, Msg) ->
    case find(SessId) of
        {ok, Pid} -> gen_server:cast(Pid, Msg);
        not_found -> {error, verto_client_not_found}
    end.


%% @private
find(Pid) when is_pid(Pid) ->
    {ok, Pid};

find(Id) ->
    case nklib_proc:values({?MODULE, Id}) of
        [{undefined, Pid}] -> {ok, Pid};
        [] -> not_found
    end.


%% ===================================================================
%% Protocol callbacks
%% ===================================================================

-type op_id() :: bw_test | {trans, integer()} | {invite, binary()} | {answer, binary()}.

-type op_type() :: login1 | login2 | invite | subscription | hangup | info | none.

-record(session_op, {
    type :: op_type(),
    timer :: reference(),
    from :: {pid(), term()}
}).

-record(state, {
    fs_id :: nkmedia_fs_engine:id(),
    remote :: binary(),
    sess_id :: binary(),
    pass :: binary(),
    current_id = 1 :: pos_integer(),
    session_ops = #{} :: #{op_id() => #session_op{}},
    originates = [] :: [pid()]
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

%% TODO: Send and receive pings from session when they are not in same cluster
conn_init(NkPort) ->
    {ok, Remote} = nkpacket:get_remote_bin(NkPort),
    {ok, _Class, User} = nkpacket:get_user(NkPort),
    #{fs_id:=FsId, pass:=Pass, sess_id:=SessId} = User,
    State = #state{
        fs_id = FsId,
        sess_id = SessId,
        pass = Pass,
        remote = Remote
    },
    ?LLOG(info, "new session (~p)", [self()], State),
    true = nklib_proc:reg({?MODULE, SessId}),
    nklib_proc:put(?MODULE, SessId),
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
    case nkmedia_fs_util:verto_class(Msg) of
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

conn_handle_call(get_state, From, _NkPort, State) ->
    gen_server:reply(From, State),
    {ok, State};

conn_handle_call(Msg, From, NkPort, State) ->
    case handle_op(Msg, From, NkPort, State) of
        unknown_op ->
            lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
            {stop, unexpected_call, State};
        Other ->
            Other
    end.


-spec conn_handle_cast(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_handle_cast(stop, _NkPort, State) ->
    lager:warning("RECEIVED STOP"),
    {stop, normal, State};

conn_handle_cast({originate_error, CallId, Error}, _NkPort, State) ->
    case extract_op({invite, CallId}, State) of
        #session_op{from=From} ->
            gen_server:reply(From, {error, Error}),
            ?LLOG(notice, "originate error: ~p", [Error], State),
            {stop, normal, State};
        _ ->
            lager:error("ORIGINATE ERROR: ~s, ~p", [CallId, Error]),
            {ok, State}
    end;

conn_handle_cast(Msg, _NkPort, State) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {ok, State}.


%% @private
-spec conn_handle_info(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_handle_info({timeout, _, {op_timeout, OpId}}, _NkPort, State) ->
    case extract_op(OpId, State) of
        {#session_op{from=From}, State2} ->
            gen_server:reply(From, {error, timeout}),
            ?LLOG(warning, "operation timeout", [], State),
            {stop, normal, State2};
        not_found ->
            {ok, State}
    end;

conn_handle_info({'EXIT', Pid, _Reason}=Msg, _NkPort, #state{originates=Pids}=State) ->
    case lists:member(Pid, Pids) of
        true ->
            {ok, State#state{originates=Pids--[Pid]}};
        false ->
            lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
            {ok, State}
    end;

conn_handle_info(Msg, _NkPort, State) ->
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
    {ok, State}.


%% @doc Called when the connection stops
-spec conn_stop(Reason::term(), nkpacket:nkport(), #state{}) ->
    ok.

conn_stop(Reason, _NkPort, State) ->
    session_event(stop, State),
    ?LLOG(info, "connection stop: ~p", [Reason], State).


%% ===================================================================
%% Requests
%% ===================================================================


%% @private
handle_op(login, From, NkPort, State) ->
    send_client_req(login1, #{}, From, NkPort, State);

handle_op({bw_test, Data}, From, NkPort, State) -> 
    State2 = insert_op(bw_test, none, From, State),
    send(Data, NkPort, State2);

handle_op({invite, CallId, Offer}, From, NkPort, State) ->
    send_client_req(invite, {CallId, Offer}, From, NkPort, State);

handle_op({hangup, CallId}, From, NkPort, State) ->
    send_client_req(hangup, #{call_id=>CallId}, From, NkPort, State);

handle_op({info, CallId, DTMF}, From, NkPort, State) ->
    send_client_req(info, #{call_id=>CallId, dtmf=>DTMF}, From, NkPort, State);

handle_op({outbound, CallId, Opts}, From, _NkPort, State) ->
    State2 = originate(CallId, Opts, State),
    State3 = insert_op({invite, CallId}, none, From, State2),
    {ok, State3};

handle_op({answer, CallId, Answer}, From, NkPort, State) ->
    send_client_req(answer, {CallId, Answer}, From, NkPort, State);

handle_op({cmd, Cmd}, From, NkPort, State) ->
    send_client_req(cmd, Cmd, From, NkPort, State);

handle_op(_Op, _From, _NkPort, _State) ->
    unknown_op.


%% @private
process_server_resp(#session_op{type=login1, from=From}, {error, -32000, _},
                    _Msg, NkPort, State) ->
    send_client_req(login2, #{}, From, NkPort, State);

process_server_resp(#session_op{type=login2, from=From}, {ok, _}, _Msg, _NkPort, State) ->
    nklib_util:reply(From, ok),
    {ok, State};

process_server_resp(#session_op{type=login2}, {error, -32001, _},
                    _Msg, _NkPort, State) ->
    ?LLOG(warning, "auth error!", [], State),
    {stop, fs_auth_error, State};

process_server_resp(#session_op{type=invite, from=From}, {ok, _}, Msg, _NkPort, State) ->
    #{<<"result">> := #{<<"callID">> := CallId}} = Msg,
    {ok, insert_op({answer, CallId}, none, From, State)};

process_server_resp(#session_op{type=invite}, {error, Code, Error}, 
                    _Msg, _NkPort, State) ->
    ?LLOG(warning, "invite error: ~p, ~p", [Code, Error], State),
    {stop, normal, State};

process_server_resp(#session_op{type=hangup, from=From}, {ok, _}, _Msg, _NkPort, State) ->
    nklib_util:reply(From, ok),
    {stop, normal, session_event({hangup, 16}, State)};

process_server_resp(#session_op{type=hangup}, {error, Code, Error}, _Msg, _NkPort, State) ->
    ?LLOG(info, "error response to hangup: ~p (~s)", [Code, Error], State),
    {stop, normal, State};

process_server_resp(#session_op{type=info, from=From}, {ok, _}, _Msg, _NkPort, State) ->
    nklib_util:reply(From, ok),
    {ok, State};

process_server_resp(#session_op{type=cmd, from=From}, {ok, _}, Msg, _NkPort, State) ->
    #{<<"result">> := Result} = Msg,
    gen_server:reply(From, {ok, Result}),
    {ok, State};

process_server_resp(#session_op{type=cmd, from=From}, {error, Code, Error}, 
                    _Msg, _NkPort, State) ->
    gen_server:reply(From, {error, {Code, Error}}),
    {ok, State};

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
            nklib_util:reply(From, {ok, SDP}),
            Resp = nkmedia_fs_util:verto_resp(<<"verto.invite">>, Msg),
            send(Resp, NkPort, State2);
        not_found ->
            ?LLOG(warning, "received unexpected INVITE from FS", [], State),
            {stop, normal, State}
    end;

process_server_req(<<"verto.answer">>, Msg, NkPort, State) ->
    #{<<"params">> := #{<<"callID">>:=CallId, <<"sdp">>:=SDP}} = Msg,
    case extract_op({answer, CallId}, State) of
        {#session_op{from=From}, State2} ->
            nklib_util:reply(From, {ok, SDP}),
            Resp = nkmedia_fs_util:verto_resp(<<"verto.answer">>, Msg),
            send(Resp, NkPort, State2);
        error ->
            ?LLOG(warning, "unexpected verto.answer", [], State),
            {stop, normal, State}
    end;

process_server_req(<<"verto.attach">>, Msg, NkPort, State) ->
    #{<<"params">>:=#{<<"callID">>:=_CallId, <<"sdp">>:=_SDP}} = Msg,
    Msg2 = nkmedia_fs_util:verto_resp(<<"verto.attach">>, Msg),
    send(Msg2, NkPort, State);

process_server_req(<<"verto.bye">>, Msg, NkPort, State) ->
    #{<<"params">>:=#{<<"callID">>:=_CallId}} = Msg,
    Msg2 = nkmedia_fs_util:verto_resp(<<"verto.bye">>, Msg),
    _ = send(Msg2, NkPort, State),
    {stop, normal, session_event({hangup, 16}, State)};

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


%% ===================================================================
%% Util
%% ===================================================================


%% @private
session_event(Status, #state{sess_id=SessId, fs_id=FsId}=State) ->
   nkmedia_session:pbx_event(SessId, FsId, Status),
   State.


%% @private
send_client_req(Type, Data, From, NkPort, State) ->
    #state{current_id=Id} = State,
    {ok, Msg} = make_msg(Id, Type, Data, State),
    State2 = insert_op({trans, Id}, Type, From, State),
    send(Msg, NkPort, State2#state{current_id=Id+1}).


%% @private
make_msg(Id, login1, _, State) ->
    #state{sess_id=SessId} = State,
    Params = #{<<"sessid">>=>SessId},
    {ok, nkmedia_fs_util:verto_req(Id, <<"login">>, Params)};

make_msg(Id, login2, _, #state{pass=Pass}=State) ->
    #state{sess_id=SessId} = State,
    Params = #{
        <<"login">> => SessId,
        <<"passwd">> => Pass,
        <<"sessid">> => SessId
    },
    {ok, nkmedia_fs_util:verto_req(Id, <<"login">>, Params)};

make_msg(Id, invite, {CallId, Offer}, _State) ->
    #{sdp:=SDP, callee_id:=Dest} = Offer,
    Dialog = maps:get(verto_params, Offer, #{}),
    UserVariables1 = maps:get(<<"userVariables">>, Dialog, #{}),
    UserVariables2 = UserVariables1#{<<"nkmedia_callback">>=><<"nkmedia_fs_verto">>},
    Params = #{
        <<"dialogParams">> => 
            Dialog#{
                <<"callID">> => nklib_util:to_binary(CallId),
                <<"destination_number">> => nklib_util:to_binary(Dest),
                <<"userVariables">> => UserVariables2
            },
        <<"sdp">> => SDP
    },
    % lager:warning("P: ~s", [nklib_json:encode_pretty(Params)]),
    {ok, nkmedia_fs_util:verto_req(Id, <<"verto.invite">>, Params)};

make_msg(Id, hangup, #{call_id:=CallId}, State) ->
    #state{sess_id = SessId} = State,
    Params = #{
        <<"dialogParams">> => #{ <<"CallID">> => CallId },
        <<"sessid">> => SessId
    },
    {ok, nkmedia_fs_util:verto_req(Id, <<"verto.bye">>, Params)};

make_msg(Id, info, #{call_id:=CallId, dtmf:=DTMF}, State) ->
    #state{sess_id = SessId} = State,
    Params = #{
        <<"dialogParams">> => #{ <<"CallID">> => CallId },
        <<"dtmf">> => DTMF,
        <<"sessid">> => SessId
    },
    {ok, nkmedia_fs_util:verto_req(Id, <<"verto.info">>, Params)};

make_msg(Id, answer, {CallId, Answer}, _State) ->
    #{sdp:=SDP} = Answer,
    Dialog = maps:get(verto_params, Answer, #{}),
    Params = #{
        <<"dialogParams">> => Dialog#{<<"callID">> => CallId},
        <<"sdp">> => SDP
    },
    {ok, nkmedia_fs_util:verto_req(Id, <<"verto.answer">>, Params)};

make_msg(Id, cmd, Cmd, _State) ->
    Params = #{
        <<"command">> => nklib_util:to_binary(Cmd),
        % <<"format">> => <<"pretty">>,
        <<"data">> => #{}
    },
    {ok, nkmedia_fs_util:verto_req(Id, <<"jsapi">>, Params)}.


%% @private
originate(CallId, Opts, #state{fs_id=FsId, sess_id=SessId, originates=Pids}=State) ->
    Dest = <<"verto.rtc/u:", SessId/binary>>,
    Vars = [{<<"nkstatus">>, <<"outbound">>}], 
    Opts2 = Opts#{vars => Vars, call_id=>CallId, timeout=>5*60},
    Self = self(),
    Pid = spawn_link(
        fun() ->
            case nkmedia_fs_cmd:call(FsId, Dest, <<"nkmedia_out">>, Opts2) of
                {ok, CallId} -> 
                    ok;
                {error, Error} -> 
                    gen_server:cast(Self, {originate_error, CallId, Error})
            end
        end),
    State#state{originates=[Pid|Pids]}.


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


%% @private
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








