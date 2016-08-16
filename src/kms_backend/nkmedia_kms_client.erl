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
-module(nkmedia_kms_client).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/1, start/2, stop/1, stop_all/0, get_all/0]).
-export([get_info/1, create/4, invoke/4, release/2, subscribe/3, unsubscribe/3]).
-export([register/4]).
-export([transports/1, default_port/1]).
-export([conn_init/1, conn_encode/2, conn_parse/3, conn_stop/3]).
-export([conn_handle_call/4, conn_handle_cast/3, conn_handle_info/3]).
-export([print/3]).

-include("../../include/nkmedia.hrl").

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA KMS Client ~s "++Txt, [State#state.sess_id|Args])).

-define(PRINT(Txt, Args, State), 
        % print(Txt, Args, State),    % Comment this
        ok).


-define(CALL_TIMEOUT, 5*60*1000).
-define(OP_TIMEOUT, 5*60*1000).    % Maximum operation time
-define(PING_TIMEOUT, 5000).
-define(PING_INTERVAL, 60000).
-define(WS_TIMEOUT, 60*60*1000).


%% ===================================================================
%% Types
%% ===================================================================

-type id() :: integer().


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Starts a new verto session to FS
-spec start(nkmedia_kms_engine:id(), nkmedia_kms:config()) ->
    {ok, pid()} | {error, term()}.

start(KurentoId, #{host:=Host, base:=Base}) ->
    ConnOpts = #{
        class => ?MODULE,
        monitor => self(),
        idle_timeout => ?WS_TIMEOUT,
        user => #{kms_id=>KurentoId},
        path => <<"/kurento">>
    },
    {ok, Ip} = nklib_util:to_ip(Host),
    Conn = {?MODULE, ws, Ip, Base},
    nkpacket:connect(Conn, ConnOpts).


%% @doc Starts a new verto session to FS
-spec start(nkmedia_kms_engine:id()) ->
    {ok, pid()} | {error, term()}.

start(KurentoId) ->
    case nkmedia_kms_engine:get_config(KurentoId) of
        {ok, #{}=Config} -> 
            start(KurentoId, Config);
        {error, Error} -> 
            {error, Error}
    end.


%% @doc 
-spec stop(pid()) ->
    ok.

stop(Pid) ->
    do_cast(Pid, stop).


%% @doc 
-spec stop_all() ->
    ok.

stop_all() ->
    lists:foreach(fun({_, Pid}) -> stop(Pid) end, get_all()).


%% @doc Gets info from Kurento
-spec get_info(pid()) ->
    {ok, map()} | {error, term()}.

get_info(Pid) ->
    do_call(Pid, get_info).


%% @doc Registers with this process
-spec register(pid(), module(), atom(), list()) ->
    {ok, pid()} | {error, term()}.

register(Pid, Module, Fun, Args) ->
    do_call(Pid, {register, Module, Fun, Args}).


%% @doc Creates media pipelines and media elements
-spec create(pid(), binary(), map(), map()) ->
    {ok, ObjId::binary(), SessId::binary()} | {error, term()}.

create(Pid, Type, Params, Properties) ->
    do_call(Pid, {create, Type, Params, Properties}).


%% @doc
-spec invoke(pid(), binary(), map(), map()) ->
    {ok, map()|null} | {error, term()}.

invoke(Pid, ObjId, Operation, Params) ->
    do_call(Pid, {invoke, ObjId, Operation, Params}).


%% @doc
-spec release(pid(), binary()) ->
    ok | {error, term()}.

release(Pid, ObjId) ->
    do_call(Pid, {release, ObjId}).


%% @doc
-spec subscribe(pid(), binary(), binary()) ->
    {ok, SubsId::binary()} | {error, term()}.

subscribe(Pid, ObjId, Type) ->
    do_call(Pid, {subscribe, ObjId, Type}).


%% @doc
-spec unsubscribe(pid(), binary(), binary()) ->
    ok | {error, term()}.

unsubscribe(Pid, ObjId, SubsId) ->
    do_call(Pid, {subscribe, ObjId, SubsId}).


%% @private
-spec get_all() ->
    [{id(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).


%% @private
do_call(Pid, Msg) ->
    nkservice_util:call(Pid, Msg, ?CALL_TIMEOUT).


%% @private
do_cast(Pid, Msg) ->
    gen_server:cast(Pid, Msg).



%% ===================================================================
%% Protocol callbacks
%% ===================================================================

-record(trans, {
    op :: term(),
    timer :: reference(),
    from :: {pid(), term()}
}).

-record(state, {
    kms_id :: nkmedia_kms_engine:id(),
    remote :: binary(),
    trans = #{} :: #{integer() => #trans{}},
    sess_id :: binary(),
    pos :: integer(),
    callback :: {Mod::module(), Fun::atom(), Args::list()}
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
    {ok, Remote} = nkpacket:get_remote_bin(NkPort),
    {ok, _Class, User} = nkpacket:get_user(NkPort),
    #{kms_id:=KurentoId} = User,
    State = #state{
        kms_id = KurentoId,
        remote = Remote,
        pos = 0
    },
    ?LLOG(info, "new session (~p)", [self()], State),
    nklib_proc:put(?MODULE),
    % gen_server:cast(self(), get_info),
    self() ! send_ping,
    {ok, State}.


%% @private
-spec conn_parse(term()|close, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_parse(close, _NkPort, State) ->
    ?LLOG(warning, "TCP close", [], State),
    {ok, State};

%% Messages received from Kurento
conn_parse({text, Data}, NkPort, #state{sess_id=SessId}=State) ->
    Msg = nklib_json:decode(Data),
    case Msg of
        error -> 
            ?LLOG(warning, "JSON decode error: ~p", [Data], State),
            error(json_decode);
        _ ->
            ok
    end,
    ?PRINT("receiving ~s", [Msg], State),
    case Msg of
        #{<<"id">>:=TransId, <<"method">>:=Method} ->
            process_server_req(TransId, Method, NkPort, State);
        #{<<"id">>:=TransId, <<"result">>:=Result} ->
            case extract_op(TransId, State) of
                {Op, State2} ->
                    State3 = case Result of
                        #{<<"sessionId">>:=MsgSessId} when SessId==undefined ->
                            ?LLOG(info, "session id is ~s", [MsgSessId], State),
                            nklib_proc:put(?MODULE, SessId),
                            nklib_proc:put({?MODULE, SessId}),
                            State2#state{sess_id=MsgSessId};
                        _ ->
                            State2
                    end,
                    process_resp(Op, Result, NkPort, State3);
                not_found ->
                    ?LLOG(warning, "received unexpected server result!", [], State),
                    {ok, State}
            end;
        #{<<"id">>:=TransId, <<"error">>:=Result} ->
            #{<<"code">>:=Code, <<"message">>:=Error} = Result,
            case extract_op(TransId, State) of
                {#trans{from=From}, State2} ->
                    nklib_util:reply(From, {error, {kms_error, Code, Error}}),
                    {ok, State2};
                not_found ->
                    ?LLOG(warning, "received unexpected server result!", [], State),
                    {ok, State}
            end;
        #{<<"method">>:=<<"onEvent">>, <<"params">> := #{<<"value">>:=Value}} ->
            process_server_event(Value, NkPort, State);
        _ ->
            ?LLOG(warning, "unrecognized msg: ~s", 
                  [nklib_json:encode_pretty(Msg)], State),
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

conn_handle_call({register, M, F, A}, From, _NkPort, State) ->
    gen_server:reply(From, ok),
    {ok, State#state{callback={M, F, A}}};

conn_handle_call(get_state, From, _NkPort, State) ->
    nklib_util:reply(From, State),
    {ok, State};

conn_handle_call(Msg, From, NkPort, State) ->
    case send_req(Msg, From, NkPort, State) of
        unknown_op ->
            lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
            {stop, unexpected_call, State};
        missing_session ->
            {reply, {error, missing_session}, State};
        Other ->
            Other
    end.


-spec conn_handle_cast(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_handle_cast(stop, _NkPort, State) ->
    lager:error("User stop"),
    {stop, normal, State};

conn_handle_cast(Msg, NkPort, State) ->
    case send_req(Msg, undefined, NkPort, State) of
        unknown_op ->
            lager:error("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
            {stop, unexpected_cast, State};
        missing_session ->
            {stop, missing_session, State};
        Other ->
            Other
    end.


%% @private
-spec conn_handle_info(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_handle_info(send_ping, NkPort, State) ->
    Res = conn_handle_cast(ping, NkPort, State),
    erlang:send_after(?PING_INTERVAL, self(), send_ping),
    Res;

conn_handle_info({timeout, _, {op_timeout, OpId}}, _NkPort, State) ->
    case extract_op(OpId, State) of
        {#trans{op=Op, from=From}, State2} ->
            nklib_util:reply(From, {error, timeout}),
            ?LLOG(warning, "operation ~p timeout", [Op], State),
            {ok, State2};
        not_found ->
            {ok, State}
    end;

conn_handle_info(Msg, _NkPort, State) ->
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
    {ok, State}.


%% @doc Called when the connection stops
-spec conn_stop(Reason::term(), nkpacket:nkport(), #state{}) ->
    ok.

conn_stop(Reason, _NkPort, _State) ->
    ?LLOG(info, "connection stop: ~p", [Reason], _State).


%% ===================================================================
%% Requests
%% ===================================================================

%% @private
send_req(Op, From, NkPort, State) ->
    case make_msg(Op, State) of
        unknown_op ->
            unknown_op;
        missing_session ->
            missing_session;
        Req when is_map(Req) ->
            State2 = insert_op(Op, From, State),
            send(Req, NkPort, State2)
    end.


%% @private
make_msg(ping, State) ->
    make_req(ping, #{interval=>?PING_TIMEOUT}, State);

make_msg(get_info, State) ->
    Params = #{object => manager_ServerManager},
    make_req(describe, Params, State);

make_msg({create, Type, Params, Properties}, #state{sess_id=undefined}=State) ->
    Data = #{
        type => Type,
        constructorParams => Params,
        properties => Properties
    },
    make_req(create, Data, State);

make_msg(_, #state{sess_id=undefined}) ->
    missing_session;

make_msg(get_info2, #state{sess_id=SessId}=State) ->
    Params = #{
        object => manager_ServerManager,
        operation => getInfo,
        sessionId => SessId
    },
    make_req(invoke, Params, State);

make_msg({create, Type, Params, Properties}, #state{sess_id=SessId}=State) ->
    Data = #{
        type => Type,
        constructorParams => Params,
        properties => Properties,
        sessionId => SessId
    },
    make_req(create, Data, State);

make_msg({invoke, ObjId, Operation, Params}, #state{sess_id=SessId}=State) ->
    Data = #{
        object => ObjId,
        operation => Operation,
        operationParams => Params,
        sessionId => SessId
    },
    make_req(invoke, Data, State);

make_msg({release, ObjId}, #state{sess_id=SessId}=State) ->
    Data = #{
        object => ObjId,
        sessionId => SessId
    },
    make_req(release, Data, State);

make_msg({subscribe, ObjId, Type}, #state{sess_id=SessId}=State) ->
    Data = #{
        object => ObjId,
        type => Type,
        sessionId => SessId
    },
    make_req(subscribe, Data, State);

make_msg({unsubscribe, ObjId, SubsId}, #state{sess_id=SessId}=State) ->
    Data = #{
        object => ObjId,
        subscription => SubsId,
        sessionId => SessId
    },
    make_req(unsubscribe, Data, State);

make_msg(_Op, _State) ->
    unknown_op.



%% @private
process_resp(#trans{op=get_info, from=From}, #{<<"hierarchy">>:=_}, NkPort, State) ->
    send_req(get_info2, From, NkPort, State);

process_resp(#trans{op={create, _, _, _}, from=From}, #{<<"value">>:=Value}, 
             _NkPort, #state{sess_id=SessId}=State) ->
    nklib_util:reply(From, {ok, Value, SessId}),
    {ok, State};

process_resp(#trans{op={invoke, _, _, _}, from=From}, Result, _NkPort, State) ->
    nklib_util:reply(From, {ok, maps:get(<<"value">>, Result, null)}),
    {ok, State};

process_resp(#trans{op={subscribe, _, _}, from=From}, Result, _NkPort, State) ->
    nklib_util:reply(From, {ok, maps:get(<<"value">>, Result)}),
    {ok, State};

process_resp(#trans{op={unsubscribe, _, _}, from=From}, _Result, _NkPort, State) ->
    nklib_util:reply(From, ok),
    {ok, State};

process_resp(#trans{op={release, _}, from=From}, _Result, _NkPort, State) ->
    nklib_util:reply(From, ok),
    {ok, State};

process_resp(#trans{from=From}=_Op, Result, _NkPort, State) ->
    % lager:error("RES: ~p ~p", [Op#trans.op, Result]),
    nklib_util:reply(From, {ok, Result}),
    {ok, State}.


%% @private
process_server_req(Request, Params, _NkPort, State) ->
    ?LLOG(warning, "unexpected server req: ~s, ~p", [Request, Params], State),
    {ok, State}.


%% @private
%% @private
process_server_event(#{<<"type">>:=<<"OnIceCandidate">>}=Params, _NkPort, State) ->
    #{
        <<"object">> := ObjId,
        <<"data">> := #{
            <<"source">> := _SrcId,
            <<"candidate">> := #{
                <<"sdpMid">> := MId,
                <<"sdpMLineIndex">> := MIndex,
                <<"candidate">> := ALine
            }
        }
    } = Params,
    Candidate = #candidate{m_id=MId, m_index=MIndex, a_line=ALine},
    send_event({candidate, ObjId, Candidate}, State),
    {ok, State};

process_server_event(#{<<"type">>:=<<"OnIceGatheringDone">>}=Params, _NkPort, State) ->
    #{
        <<"object">> := ObjId,
        <<"data">> := #{
            <<"source">> := _SrcId
        }
    } = Params,
    Candidate = #candidate{last=true},
    send_event({candidate, ObjId, Candidate}, State),
    {ok, State};

process_server_event(Params, _NkPort, State) ->
    ?LLOG(warning, "unexpected server event: ~s", [nklib_json:encode_pretty(Params)], State),
    {ok, State}.
   


%% ===================================================================
%% Util
%% ===================================================================

%% @private
insert_op(Op, From, #state{trans=AllTrans, pos=Pos}=State) ->
    Time = case Op of
        ping -> ?PING_TIMEOUT;
        _ -> ?OP_TIMEOUT
    end,
    NewOp = #trans{
        op = Op,
        from = From,
        timer = erlang:start_timer(Time, self(), {op_timeout, Pos})
    },
    Pos2 = (Pos+1) rem 100000000000,
    State#state{trans=maps:put(Pos, NewOp, AllTrans), pos=Pos2}.


%% @private
extract_op(TransId, #state{trans=AllTrans}=State) ->
    case maps:find(TransId, AllTrans) of
        {ok, #trans{timer=Timer}=Op} ->
            nklib_util:cancel_timer(Timer),
            State2 = State#state{trans=maps:remove(TransId, AllTrans)},
            {Op, State2};
        error ->
            not_found
    end.


%% @private
make_req(Method, Params, #state{pos=Pos}) ->
    #{
        jsonrpc => <<"2.0">>,
        id => Pos,
        method => Method,
        params => Params
    }.


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
send_event(Event, #state{callback={Module, Fun, Args}}) ->
    apply(Module, Fun, Args++[Event]);

send_event(Event, State) ->
    ?LLOG(warning, "could not send event: ~p", [Event], State).


%% @private
print(_Txt, [#{method:=ping}], _State) ->
    ok;
print(_Txt, [#{<<"result">>:=#{<<"value">>:=<<"pong">>}}], _State) ->
    ok;
print(Txt, [#{}=Map], State) ->
    print(Txt, [nklib_json:encode_pretty(Map)], State);
print(Txt, Args, _State) ->
    ?LLOG(info, Txt, Args, _State).








