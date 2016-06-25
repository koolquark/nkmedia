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
-export([info/1]).

-export([transports/1, default_port/1]).
-export([conn_init/1, conn_encode/2, conn_parse/3, conn_stop/3]).
-export([conn_handle_call/4, conn_handle_cast/3, conn_handle_info/3]).
-export([print/3]).

-include("nkmedia.hrl").

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA KMS Client "++Txt, Args)).

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
    case nkpacket:connect(Conn, ConnOpts) of
        {ok, Pid} ->
            call(Pid, get_info);
        {error, Error} ->
            {error, Error}
    end.


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
    cast(Pid, stop).


%% @doc 
-spec stop_all() ->
    ok.

stop_all() ->
    lists:foreach(fun({_, Pid}) -> stop(Pid) end, get_all()).


%% @doc Gets info from Kurento
-spec info(pid()) ->
    {ok, map()} | {error, term()}.

info(Pid) ->
    call(Pid, info).


%% @private
-spec get_all() ->
    [{id(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).


%% @private
call(Pid, Msg) ->
    nkservice_util:call(Pid, Msg, ?CALL_TIMEOUT).


%% @private
cast(Pid, Msg) ->
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
    from :: {pid(), term()},
    info :: map()
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
    gen_server:cast(self(), get_info1),
    self() ! send_ping,
    {ok, State}.


%% @private
-spec conn_parse(term()|close, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_parse(close, _NkPort, State) ->
    {ok, State};

%% Messages received from Kurento
conn_parse({text, Data}, NkPort, State) ->
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
        #{<<"id">>:=Id, <<"method">>:=Method} ->
            process_server_req(Id, Method, NkPort, State);
        #{<<"id">>:=Id, <<"result">>:=Result} ->
            case extract_op(Id, State) of
                {Op, State2} ->
                    process_server_resp(Op, Result, NkPort, State2);
                not_found ->
                    ?LLOG(warning, "received unexpected server result!", [], State),
                    {ok, State}
            end;
        #{<<"method">>:=<<"onEvent">>, <<"params">>:=Params} ->
            process_server_event(Params, NkPort, State);
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

conn_handle_call(get_info, From, _NkPort, #state{info=Info}=State) ->
    case is_map(Info) of
        true ->
            nklib_util:reply(From, {ok, self(), Info}),
            {ok, State};
        false ->
            {ok, State#state{from=From}}
    end;

conn_handle_call(get_state, From, _NkPort, State) ->
    nklib_util:reply(From, State),
    {ok, State};

conn_handle_call(Msg, From, NkPort, State) ->
    case send_client_req(Msg, From, NkPort, State) of
        unknown_op ->
            lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
            {stop, unexpected_call, State};
        Other ->
            Other
    end.


-spec conn_handle_cast(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_handle_cast(stop, _NkPort, State) ->
    {stop, normal, State};

conn_handle_cast(Msg, NkPort, State) ->
    case send_client_req(Msg, undefined, NkPort, State) of
        unknown_op ->
            lager:error("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
            {stop, unexpected_cast, State};
        Other ->
            Other
    end.


%% @private
-spec conn_handle_info(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_handle_info(send_ping, NkPort, State) ->
    send_client_req(ping, undefined, NkPort, State);

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
    % session_event(stop, State),
    ?LLOG(info, "connection stop: ~p", [Reason], _State).


%% ===================================================================
%% Requests
%% ===================================================================

%% @private
send_client_req(Op, From, NkPort, #state{pos=Pos}=State) ->
    case make_msg(Op, State) of
        {ok, Msg} ->
            State2 = insert_op(Op, From, State),
            send(Msg, NkPort, State2#state{pos=Pos+1});
        {error, Error} ->
            nklib_util:reply(From, {error, Error}),
            {ok, State}
    end.


%% @private
make_msg(ping, State) ->
    erlang:send_after(?PING_INTERVAL, self(), send_ping),
    {ok, make_req(ping, #{interval=>?PING_TIMEOUT}, State)};

make_msg(get_info1, State) ->
    Params = #{object=><<"manager_ServerManager">>},
    {ok, make_req(describe, Params, State)};

make_msg(get_info2, #state{sess_id=SessId}=State) ->
    Params = #{
        object => <<"manager_ServerManager">>, 
        operation => getInfo,
        sessionId => SessId
    },
    {ok, make_req(invoke, Params, State)};

make_msg(Op, _State) ->
    ?LLOG(warning, "unknown op: ~p", [Op], State),
    {error, {unknown_op, Op}}.


%% @private
process_server_resp(#trans{op=get_info1, from=From}, Result, NkPort, State) ->
    #{<<"sessionId">>:=SessId} = Result,
    nklib_proc:put(?MODULE, SessId),
    nklib_proc:put({?MODULE, SessId}),
    send_client_req(get_info2, From, NkPort, State#state{sess_id=SessId});

process_server_resp(#trans{op=get_info2, from=From}, Result, _NkPort, State) ->
    nklib_util:reply(From, {ok, Result}),
    State2 = case State of
        #state{from=UserFrom} when UserFrom /= undefined ->
            nklib_util:reply(UserFrom, {ok, self(), Result}),
            State#state{from=undefined};
        _ ->
            State
    end,
    {ok, State2#state{info=Result}};

process_server_resp(#trans{from=From}, Result, _NkPort, State) ->
    nklib_util:reply(From, {ok, Result}),
    {ok, State}.


%% @private
process_server_req(Request, Params, _NkPort, State) ->
    ?LLOG(warning, "unexpected server req: ~s, ~p", [Request, Params], State),
    {ok, State}.


%% @private
process_server_event(Params, _NkPort, State) ->
    ?LLOG(warning, "unexpected server event: ~p", [Params], State),
    {ok, State}.
   


%% ===================================================================
%% Util
%% ===================================================================

%% @private
insert_op(Op, From, #state{trans=AllOps, pos=Pos}=State) ->
    Time = case Op of
        ping -> ?PING_TIMEOUT;
        _ -> ?OP_TIMEOUT
    end,
    NewOp = #trans{
        op = Op,
        from = From,
        timer = erlang:start_timer(Time, self(), {op_timeout, Pos})
    },
    State#state{trans=maps:put(Pos, NewOp, AllOps)}.


%% @private
extract_op(Id, #state{trans=AllOps}=State) ->
    case maps:find(Id, AllOps) of
        {ok, #trans{timer=Timer}=Op} ->
            nklib_util:cancel_timer(Timer),
            State2 = State#state{trans=maps:remove(Id, AllOps)},
            {Op, State2};
        error ->
            not_found
    end.




% %% @private
% event(undefined, _ClientId, _SessId, _Handle, _Event, State) ->
%     State;

% event(CallBack, ClientId, SessId, Handle, Event, State) ->
%     case catch CallBack:kms_event(ClientId, SessId, Handle, Event) of
%         ok ->
%             ok;
%         _ ->
%             ?LLOG(warning, "Error calling ~p:kms_event/4: ~p", [CallBack], Error)
%     end,
%     State.


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
make_req(Method, Params, #state{pos=Pos}) ->
    #{
        id => Pos,
        jsonrpc => <<"2.0">>,
        method => Method,
        params => Params
    }.


%% @private
print(_Txt, [#{method:=ping}], _State) ->
    ok;
print(_Txt, [#{<<"result">>:=#{<<"value">>:=<<"pong">>}}], _State) ->
    ok;
print(Txt, [#{}=Map], State) ->
    print(Txt, [nklib_json:encode_pretty(Map)], State);
print(Txt, Args, _State) ->
    ?LLOG(info, Txt, Args, _State).








