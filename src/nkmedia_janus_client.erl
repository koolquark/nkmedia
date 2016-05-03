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
-module(nkmedia_janus_client).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/2, stop/1, get_all/0]).
-export([info/1]).

-export([transports/1, default_port/1]).
-export([conn_init/1, conn_encode/2, conn_parse/3, conn_stop/3]).
-export([conn_handle_call/4, conn_handle_cast/3, conn_handle_info/3]).
-export([print/3]).

-include("nkmedia.hrl").



-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Janus Client "++Txt, Args)).

-define(PRINT(Txt, Args, State), 
        % print(Txt, Args, State),    % Comment this
        ok).


-define(OP_TIME, 5*60*1000).    % Maximum operation time
-define(CALL_TIMEOUT, 5*60*1000).
-define(CODECS, [opus,vp8,speex,iLBC,'GSM','PCMU','PCMA']).

-define(JANUS_WS_TIMEOUT, 60*60*1000).


%% ===================================================================
%% Types
%% ===================================================================

-type id() :: binary().


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Starts a new verto session to FS
-spec start(id(), nkmedia_janus_engine:id()) ->
    {ok, pid()} | {error, term()}.

start(Host, Pass) ->
    ConnOpts = #{
        class => ?MODULE,
        monitor => self(),
        idle_timeout => ?JANUS_WS_TIMEOUT,
        user => #{pass=>Pass},
        ws_proto => <<"janus-protocol">>
    },
    {ok, Ip} = nklib_util:to_ip(Host),
    Conn = {?MODULE, ws, Ip, ?JANUS_WS_PORT},
    % Conn = {?MODULE, wss, Ip, 8989},
    case nkpacket:connect(Conn, ConnOpts) of
        {ok, Pid} -> 
            {ok, Pid};
        {error, Error} -> 
            {error, Error}
    end.


%% @doc 
stop(SessId) ->
    cast(SessId, stop).


%% @doc
%% sdp and callee_id are expected, verto_params is supported
-spec info(id()|pid()) ->
    {ok, map()} | {error, term()}.

info(Id) ->
    call(Id, info).


-spec get_all() ->
    [{id(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).


%% @private
call(SessId, Msg) ->
    case find(SessId) of
        {ok, Pid} -> nklib_util:call(Pid, Msg, ?CALL_TIMEOUT);
        not_found -> {error, janus_client_not_found}
    end.


%% @private
cast(SessId, Msg) ->
    case find(SessId) of
        {ok, Pid} -> gen_server:cast(Pid, Msg);
        not_found -> {error, janus_client_not_found}
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
    janus_id :: nkmedia_janus_engine:id(),
    remote :: binary(),
    pass :: binary(),
    session_ops = #{} :: #{op_id() => #session_op{}}
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

%% TODO: Send and receive pings from session when they are not in same cluster
conn_init(NkPort) ->
    {ok, Remote} = nkpacket:get_remote_bin(NkPort),
    {ok, _Class, User} = nkpacket:get_user(NkPort),
    #{pass:=Pass} = User,
    State = #state{
        pass = Pass,
        remote = Remote
    },
    ?LLOG(info, "new session (~p)", [self()], State),
    nklib_proc:put(?MODULE),
    {ok, State}.


%% @private
-spec conn_parse(term()|close, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_parse(close, _NkPort, State) ->
    {ok, State};

%% Messages received from Janus
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
        #{<<"janus">>:=Cmd, <<"transaction">>:=Id} ->
            case extract_op({trans, Id}, State) of
                {Op, State2} ->
                    process_server_resp(Op, Cmd, Msg, NkPort, State2);
                not_found ->
                    process_server_req(Cmd, Msg, NkPort, State)
            end;
        #{<<"janus">>:=Cmd} ->
            ?LLOG(noticer, "Msg: ~s: ~p", [Cmd, Msg], State)
    end,
    {ok, State}.


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


% @private
handle_op(info, From, NkPort, State) ->
    send_client_req(info, #{}, From, NkPort, State);

handle_op(_Op, _From, _NkPort, _State) ->
    unknown_op.


%% @private
process_server_resp(Op, <<"server_info">>, Msg, _NkPort, State) ->
    #session_op{type=info, from=From} = Op,
    nklib_util:reply(From, {ok, Msg}),
    State;

process_server_resp(Op, <<"success">>, Msg, _NkPort, State) ->
    #session_op{type=_Type, from=From} = Op,
    nklib_util:reply(From, {ok, Msg}),
    State;

process_server_resp(Op, <<"error">>, Msg, _NkPort, State) ->
    #session_op{type=_Type, from=From} = Op,
    nklib_util:reply(From, {error, Msg}),
    State;

process_server_resp(Op, Other, Msg, _NkPort, State) ->
    #session_op{type=_Type, from=From} = Op,
    nklib_util:reply(From, {{unknown, Other}, Msg}),
    State.



% %% @private
process_server_req(Cmd, _Msg, _NkPort, State) ->
    ?LLOG(warning, "Server REQ: ~s", [Cmd], State),
    State.




%% ===================================================================
%% Util
%% ===================================================================


%% @private
send_client_req(Type, Data, From, NkPort, State) ->
    Id = nklib_util:uid(),
    Msg = make_msg(Id, Type, Data, State),
    State2 = insert_op({trans, Id}, Type, From, State),
    send(Msg, NkPort, State2).


%% @private
make_msg(Id, info, _, _State) ->
    make_req(Id, info, #{}).



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
make_req(Id, Cmd, Data) ->
    Data#{<<"janus">> => Cmd, <<"transaction">> => Id}.



%% @private
print(Txt, [#{}=Map], State) ->
    print(Txt, [nklib_json:encode_pretty(Map)], State);
print(Txt, Args, _State) ->
    ?LLOG(info, Txt, Args, _State).








