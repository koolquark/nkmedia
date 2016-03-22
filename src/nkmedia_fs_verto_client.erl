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
-module(nkmedia_fs_verto_client).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(nkpacket_protocol).

-export([start/1, stop/1, get_all/0, invite/4, bye/2, dtmf/3, answer/3]).
-export([send_bw_test/2, get_server/1]).
-export([transports/1, default_port/1]).
-export([conn_init/1, conn_encode/2, conn_parse/3, conn_stop/3]).
-export([conn_handle_call/4, conn_handle_cast/3, conn_handle_info/3]).

-include("nkmedia.hrl").

-define(CALL_TIMEOUT, 30000).

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA verto client (~s) "++Txt, [State#state.remote | Args])).


-define(IN_BW, 12800).
-define(OUT_BW, 4800).






%% ===================================================================
%% Types
%% ===================================================================

-type op_type() :: login1 | login2 | invite | wait_answer | subscription | bye |
                   info.



%% ===================================================================
%% Public
%% ===================================================================



%% @doc Starts a new verto session to FS
-spec start(pid()) ->
    {ok, VertoId::binary(), pid()} | {error, term()}.

start(ServerPid) ->
    case nkmedia_fs_server:get_config(ServerPid) of
        {ok, #{ip:=Ip, index:=Index, password:=Pass}} ->
            ConnOpts = #{
                class => nkmedia_fs,
                monitor => self(),
                idle_timeout => ?WS_TIMEOUT,
                user => #{server_pid => ServerPid, pass => Pass}
            },
            Conn = {nkmedia_fs_verto_client, ws, Ip, 8181+Index},
            case nkpacket:connect(Conn, ConnOpts) of
                {ok, Pid} ->
                    case nklib_util:call(Pid, login, ?CALL_TIMEOUT) of
                        {ok, Id} ->
                            {ok, Id, Pid};
                        {error, Error} ->
                            {error, Error}
                    end;
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @doc 
stop(SessionPid) ->
    nkpacket_connection:stop(SessionPid).


%% @doc
send_bw_test(SessionPid, <<"#S", _/binary>>=Data) ->
    gen_server:cast(SessionPid, {send_bw_test, Data, self()}).


%% @doc
-spec invite(pid(), binary(), binary(), #{binary() => term()}) ->
    {ok, SDP::binary()} | {error, term()}.

invite(SessionPid, Dest, SDP, Dialog) ->
    Dest1 = nklib_util:to_binary(Dest),
    SDP1 = nklib_util:to_binary(SDP), 
    Dialog2 = Dialog#{
        <<"incomingBandwidth">> => ?IN_BW,
        <<"outgoingBandwidth">> => ?OUT_BW
    },
    nklib_util:call(SessionPid, {invite, Dest1, SDP1, Dialog2}, ?CALL_TIMEOUT).


%% @doc
-spec bye(pid(), binary()) ->
    ok | {error, term()}.

bye(SessionPid, CallId) ->
    nklib_util:call(SessionPid, {bye, CallId}, ?CALL_TIMEOUT).


-spec dtmf(pid(), binary(), binary()) ->
    ok | {error, term()}.

dtmf(SessionPid, CallId, DTMF) ->
    nklib_util:call(SessionPid, {info, CallId, DTMF}, ?CALL_TIMEOUT).


%% @doc
answer(SessionPid, SDP, Dialog) ->
    Dialog2 = Dialog#{
        <<"incomingBandwidth">> => ?IN_BW,
        <<"outgoingBandwidth">> => ?OUT_BW
    },
    nklib_util:call(SessionPid, {answer, SDP, Dialog2}, ?CALL_TIMEOUT).


-spec get_server(pid()) ->
    {ok, pid()} | {error, term()}.

get_server(SessionPid) ->
    nklib_util:call(SessionPid, get_server, ?CALL_TIMEOUT).


%% @private
get_all() ->
    [Pid || {undefined, Pid}<- nklib_proc:values(?MODULE)].




%% ===================================================================
%% Protocol callbacks
%% ===================================================================


-record(session_op, {
    type :: op_type(),
    time :: nklib_util:timestamp()
}).

-record(state, {
    id :: binary(),
    server_pid :: pid(),
    pass :: binary(),
    remote :: binary(),
    current_id = 1 :: pos_integer(),
    bw_test :: pid(),
    client_reply :: {pid(), term()},
    session_ops = #{} :: #{{client|server, integer()} => #session_op{}},
    fs_waiting :: {answer, binary()}
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
    #{server_pid:=ServerPid, pass:=Pass} = User,
    State = #state{
        id = nklib_util:uuid_4122(),
        server_pid = ServerPid,
        pass = Pass,
        remote = Remote
    },
    ?LLOG(info, "new connection (~p)", [self()], State),
    nklib_proc:put(?MODULE),
    % self() ! check_old_requests,
    {ok, State}.


%% @private
-spec conn_parse(term()|close, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_parse(close, _NkPort, State) ->
    {ok, State};

%% Messages received from FS
conn_parse({text, <<"#S", _/binary>>=Msg}, _NkPort, State) ->
    case State of
        #state{bw_test=Pid} when is_pid(Pid) -> 
            Pid ! {verto_bw_test, Msg};
        _ -> 
            ?LLOG(warning, "BW test reply without client", [], State)
    end,
    {ok, State};

conn_parse({text, Data}, NkPort, State) ->
    Msg = nklib_json:decode(Data),
    case Msg of
        error -> 
            ?LLOG(warning, "JSON decode error: ~p", [Data], State),
            error(json_decode);
        _ ->
            ok
    end,
    nkmedia_fs_verto:print("NkMEDIA Verto Client recv", Msg),
    case nkmedia_fs_verto:parse_class(Msg) of
        {{req, Method}, _Id} ->
            process_server_req(Method, Msg, NkPort, State);
        {{resp, Resp}, Id} ->
            #state{session_ops=Ops} = State,
            case maps:find({client, Id}, Ops) of
                {ok, Op} ->
                    State2 = State#state{session_ops=maps:remove({client, Id}, Ops)},
                    process_server_resp(Op, Resp, Msg, NkPort, State2);
                error ->
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

conn_handle_call(login, From, NkPort, State) ->
    case send_client_req(login1, #{}, NkPort, State) of
        {ok, State2} ->
            {ok, State2#state{client_reply=From}};
        {error, _Error} ->
            {stop, normal, State}
    end;

conn_handle_call({invite, Dest, SDP, Dialog}, From, NkPort, 
                 #state{client_reply=undefined}=State) ->
    case send_client_req(invite, {Dest, SDP, Dialog}, NkPort, State) of
        {ok, State2} ->
            {ok, State2#state{client_reply=From}};
        {error, Error} ->
            gen_server:reply(From, {error, Error}),
            {stop, normal, State}
    end;

conn_handle_call({invite, _}, From, _NkPort, State) ->
    gen_server:reply(From, {error, not_ready}),
    {ok, State};

conn_handle_call({answer, SDP, Dialog}, From, NkPort, 
                 #state{client_reply=undefined, fs_waiting={answer, _}}=State) ->
    case send_client_req(answer, {SDP, Dialog}, NkPort, State) of
        {ok, State2} ->
            gen_server:reply(From, ok),
            {ok, State2};
        {error, Error} ->
            gen_server:reply(From, {error, Error}),
            {stop, normal, State}
    end;

conn_handle_call({answer, _SDP, _Dialog}, From, _NkPort, State) ->
    gen_server:reply(From, {error, not_ready}),
    {ok, State};

conn_handle_call({bye, CallId}, From, NkPort, State) ->
    case send_client_req(bye, #{call_id=>CallId}, NkPort, State) of
        {ok, State2} ->
            gen_server:reply(From, ok),
            {ok, State2};
        {error, Error} ->
            gen_server:reply(From, {error, Error}),
            {stop, normal, State}
    end;

conn_handle_call({info, CallId, DTMF}, From, NkPort, State) ->
    case send_client_req(info, #{call_id=>CallId, dtmf=>DTMF}, NkPort, State) of
        {ok, State2} ->
            gen_server:reply(From, ok),
            {ok, State2};
        {error, Error} ->
            gen_server:reply(From, {error, Error}),
            {stop, normal, State}
    end;

conn_handle_call(get_server, From, _NkPort, #state{server_pid=Pid}=State) ->
    gen_server:reply(From, {ok, Pid}),
    {ok, State};

conn_handle_call(get_state, From, _NkPort, State) ->
    gen_server:reply(From, State),
    {ok, State};

conn_handle_call(Msg, _From, _NkPort, State) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {stop, unexpected_call, State}.


-spec conn_handle_cast(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_handle_cast({send_bw_test, Data, Pid}, NkPort, State) -> 
    case send(Data, NkPort) of
        ok ->
            {ok, State#state{bw_test=Pid}};
        error ->
            {stop, normal, State}
    end;

conn_handle_cast(Msg, _NkPort, State) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {ok, State}.


%% @private
-spec conn_handle_info(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

% conn_handle_info(check_old_requests, _NkPort, State) ->
%     #state{client_reqs=ClientReqs, server_reqs=ServerReqs} = State,
%     Now = nklib_util:timestamp(),
%     ClientReqs1 = check_old_requests(Now, maps:to_list(ClientReqs), []),
%     ServerReqs1 = check_old_requests(Now, maps:to_list(ServerReqs), []),
%     erlang:send_after(?CHECK_TIME, self(), check_old_requests),
%     State1 = State#state{client_reqs=ClientReqs1, server_reqs=ServerReqs1},
%     {ok, State1};

% conn_handle_info({'DOWN', _Ref, process, Pid, _Reason}, _NkPort, 
%                  #state{cal=Pid}=State) ->
%     lager:notice("VERTO FS stopping: caller stopped"),
%     {stop, normal, State};

conn_handle_info(Msg, _NkPort, State) ->
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
    {ok, State}.


%% @doc Called when the connection stops
-spec conn_stop(Reason::term(), nkpacket:nkport(), #state{}) ->
    ok.

conn_stop(_Reason, _NkPort, State) ->
    client_reply({error, connection_down}, State).



%% ===================================================================
%% Util
%% ===================================================================


%% @private
send_client_req(Type, Data, NkPort, State) ->
    #state{current_id=Id, session_ops=Ops} = State,
    {ok, Msg} = make_msg(Id, Type, Data, State),
    case send(Msg, NkPort) of
        ok ->
            Op = #session_op{type=Type, time=nklib_util:timestamp()},
            Ops2 = maps:put({client, Id}, Op, Ops),
            {ok, State#state{session_ops=Ops2, current_id=Id+1}};
        error ->
            {error, connection_error}
    end.


%% @private
process_server_resp(#session_op{type=login1}, {error, -32000, _},
                    _Msg, NkPort, State) ->
    send_client_req(login2, #{}, NkPort, State);

process_server_resp(#session_op{type=login2}, {ok, _}, _Msg, _NkPort, State) ->
    #state{id=Id} = State,
    State2 = client_reply({ok, Id}, State),
    {ok, State2};

process_server_resp(#session_op{type=login2}, {error, -32001, _},
                    _Msg, _NkPort, State) ->
    {stop, fs_auth_error, State};

process_server_resp(#session_op{type=invite}, {ok, _}, Msg, _NkPort, State) ->
    #{<<"result">>:=#{<<"callID">>:=CallId}} = Msg,
    Op = #session_op{
        type = wait_answer,
        time = nklib_util:timestamp()
    },
    #state{session_ops=Ops} = State,
    Ops2 = maps:put({client, CallId}, Op, Ops),
    {ok, State#state{session_ops=Ops2}};

process_server_resp(#session_op{type=invite}, {error, Code, Error}, 
                    _Msg, _NkPort, State) ->
    {stop, {fs_invite_error, Code, Error}, State};

process_server_resp(#session_op{type=Type}, Resp, _Msg, _NkPort, State)
        when Type==bye; Type==info; Type==answer ->
    case Resp of
        {ok, _} -> 
            ok;
        {error, Code, Error} ->
            ?LLOG(warning, "error response to ~p: ~p (~s)", [Type, Code, Error], State)
    end,
    {ok, State};

process_server_resp(Op, _Resp, Msg, _NkPort, State) ->
    ?LLOG(warning, "Unexpected server response for ~p: ~p", [Op, Msg], State),
    {ok, State}.


%% @private
process_server_req(<<"verto.answer">>, Msg, NkPort, State) ->
    #{<<"params">>:=#{<<"callID">>:=CallId, <<"sdp">>:=SDP}} = Msg,
    #state{session_ops=Ops} = State,
    case maps:find({client, CallId}, Ops) of
        {ok, _} ->
            State2 = State#state{session_ops=maps:remove({client, CallId}, Ops)},
            State3 = client_reply({ok, SDP}, State2),
            Msg2 = nkmedia_fs_verto:make_resp(<<"verto.answer">>, Msg),
            case send(Msg2, NkPort) of
                ok ->
                    {ok, State3};
                error ->
                    {stop, normal, State3}
            end;
        error ->
            ?LLOG(warning, "unxpected verto.answer", [], State),
            {stop, normal, State}
    end;

process_server_req(<<"verto.attach">>, Msg, NkPort, State) ->
    #{<<"params">>:=#{<<"callID">>:=_CallId, <<"sdp">>:=_SDP}} = Msg,
    Msg2 = nkmedia_fs_verto:make_resp(<<"verto.attach">>, Msg),
    case send(Msg2, NkPort) of
        ok ->
            {ok, State};
        error ->
            {stop, normal, State}
    end;

process_server_req(<<"verto.bye">>, Msg, NkPort, State) ->
    #{<<"params">>:=#{<<"callID">>:=CallId}} = Msg,
    ?LLOG(info, "received BYE for ~s", [CallId], State),
    Msg2 = nkmedia_fs_verto:make_resp(<<"verto.bye">>, Msg),
    case send(Msg2, NkPort) of
        ok ->
            {ok, State};
        error ->
            {stop, normal, State}
    end;

%% Sent when FS detects another session for the same session id
process_server_req(<<"verto.punt">>, _Msg, _NkPort, State) ->
    ?LLOG(notice, "stopping connection because of verto.punt", [], State),
    {stop, normal, State};
    
process_server_req(<<"verto.invite">>, Msg, NkPort, State) ->
    #{<<"params">>:=Params} = Msg,
    #{<<"callID">>:=CallId, <<"sdp">>:=_SDP} = Params, 
    ?LLOG(notice, "INVITE from FS", [], State),
    Msg2 = nkmedia_fs_verto:make_resp(<<"verto.invite">>, Msg),
    case send(Msg2, NkPort) of
        ok ->
            {ok, State#state{fs_waiting={answer, CallId}}};
        error ->
            {stop, normal, State}
    end;

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
    #state{id=SessionId} = State,
    Params = #{<<"sessid">>=>SessionId},
    {ok, nkmedia_fs_verto:make_req(Id, <<"login">>, Params)};

make_msg(Id, login2, _, #state{pass=Pass}=State) ->
    #state{id=SessionId} = State,
    Params = #{
        <<"login">> => SessionId,
        <<"passwd">> => Pass,
        <<"sessid">> => SessionId
    },
    {ok, nkmedia_fs_verto:make_req(Id, <<"login">>, Params)};

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
    {ok, nkmedia_fs_verto:make_req(Id, <<"verto.invite">>, Params)};

make_msg(Id, bye, #{call_id:=CallId}, State) ->
    #state{id = SessId} = State,
    Params = #{
        <<"dialogParams">> => #{ <<"CallID">> => CallId },
        <<"sessid">> => SessId
    },
    {ok, nkmedia_fs_verto:make_req(Id, <<"verto.bye">>, Params)};

make_msg(Id, info, #{call_id:=CallId, dtmf:=DTMF}, State) ->
    #state{id = SessId} = State,
    Params = #{
        <<"dialogParams">> => #{ <<"CallID">> => CallId },
        <<"dtmf">> => DTMF,
        <<"sessid">> => SessId
    },
    {ok, nkmedia_fs_verto:make_req(Id, <<"verto.info">>, Params)};

make_msg(Id, answer, {SDP, Dialog}, #state{fs_waiting={answer, CallId}}) ->
    Params = #{
        <<"dialogParams">> => Dialog#{<<"callID">> => CallId},
        <<"sdp">> => SDP
    },
    {ok, nkmedia_fs_verto:make_req(Id, <<"verto.answer">>, Params)}.

% %% @private
% send_to_client(Msg, #state{user_pid=Pid}=State) ->
%     Pid ! {nkmedia_fs_verto, self(), Msg},
%     State.


%% @private
client_reply(Reply, #state{client_reply=From}=State) when is_tuple(From) ->
    gen_server:reply(From, Reply),
    State#state{client_reply=undefined};

client_reply(_Reply, State) ->
    State.


send(Msg, NkPort) ->
    nkmedia_fs_verto:send("Verto Client send", Msg, NkPort).



% %% @private
% check_old_requests(_Now, [], Acc) ->
%     maps:from_list(Acc);

% check_old_requests(Now, [{Id, #request{time=Time}=Req}|Rest], Acc) ->
%     Acc1 = case Now - Time > (?MAX_REQ_TIME div 1000) of
%         true ->
%             lager:warning("Removing old request: ~p", [Req]),
%             Acc;
%         false ->
%             [{Id, Req}|Acc]
%     end,
%     check_old_requests(Now, Rest, Acc1).







