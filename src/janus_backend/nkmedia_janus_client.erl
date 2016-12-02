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

-export([start/1, start/2, stop/1, get_all/0]).
-export([info/1, create/3, attach/3, message/5, detach/3, destroy/2]).
-export([keepalive/2, candidate/4, get_clients/1]).

-export([transports/1, default_port/1]).
-export([conn_init/1, conn_encode/2, conn_parse/3, conn_stop/3]).
-export([conn_handle_call/4, conn_handle_cast/3, conn_handle_info/3]).
-export([print/3]).

-include_lib("nksip/include/nksip.hrl").

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Janus Client (~p) "++Txt, [self()|Args])).

-define(PRINT(Txt, Args, State), 
        % print(Txt, Args, State),    % Comment this
        ok).


% -define(OP_TIME, 5*60*1000).    % Maximum operation time
-define(OP_TIME, 30*1000).    % Maximum operation time
-define(CALL_TIMEOUT, 5*60*1000).
-define(CODECS, [opus,vp8,speex,iLBC,'GSM','PCMU','PCMA']).

-define(JANUS_WS_TIMEOUT, 60*60*1000).


%% ===================================================================
%% Types
%% ===================================================================

-type id() :: integer().
-type handle() :: integer().


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Starts a new Janus session
-spec start(nkmedia_janus_engine:id()) ->
    {ok, pid()} | {error, term()}.

start(JanusId) ->
    case nkmedia_janus_engine:get_config(JanusId) of
        {ok, #{}=Config} -> 
            start(JanusId, Config);
        {error, Error} -> 
            {error, Error}
    end.


%% @doc Starts a new Janus session
-spec start(nkmedia_janus_engine:id(), nkmedia_janus:config()) ->
    {ok, pid()} | {error, term()}.

start(JanusId, #{host:=Host, base:=Base, pass:=Pass}) ->
    ConnOpts = #{
        class => ?MODULE,
        monitor => self(),
        idle_timeout => ?JANUS_WS_TIMEOUT,
        user => #{pass=>Pass, janus_id=>JanusId},
        ws_proto => <<"janus-protocol">>
    },
    {ok, Ip} = nklib_util:to_ip(Host),
    Conn = {?MODULE, ws, Ip, Base},
    nkpacket:connect(Conn, ConnOpts).


%% @doc 
-spec stop(pid()) ->
    ok.

stop(Pid) ->
    cast(Pid, stop).


%% @doc Gets info from Janus
-spec info(pid()) ->
    {ok, map()} | {error, term()}.

info(Pid) ->
    call(Pid, info).


%% @doc Creates a new session. 
%% Events for the session will be sent to the callback as
%% CallBack:janus_event(Id, JanusId, Handle, Msg).
%% The calling process will be monitorized
-spec create(pid(), module(), term()) ->
    {ok, id()} | {error, term()}.

create(Pid, CallBack, Id) ->
    call(Pid, {create, CallBack, Id, self()}).
    

%% @doc Creates a new session
-spec attach(pid(), id(), binary()) ->
    {ok, handle()} | {error, term()}.

attach(Pid, SessId, Plugin) ->
    Plugin2 = <<"janus.plugin.", (nklib_util:to_binary(Plugin))/binary>>,
    call(Pid, {attach, SessId, Plugin2}).


%% @doc
-spec message(pid(), id(), handle(), map(), map()) ->
    {ok, Data::map(), Jsep::map()} | {error, term()}. 

message(Pid, Id, Handle, Body, Jsep) ->
    call(Pid, {message, Id, Handle, Body, Jsep}).


%% @doc Destroys a session
-spec detach(pid(), id(), handle()) ->
    ok.

detach(Pid, SessId, Handle) ->
    cast(Pid, {detach, SessId, Handle}).


%% @doc Destroys a session
-spec destroy(pid(), id()) ->
    ok.

destroy(Pid, SessId) ->
    cast(Pid, {destroy, SessId}).


%% @doc Destroys a session
-spec keepalive(pid(), id()) ->
    ok.

keepalive(Pid, SessId) ->
    cast(Pid, {keepalive, SessId}).


%% @doc Sends a trickle candidate to the server
-spec candidate(pid(), id(), handle(), nkmedia:candidate()) ->
    ok.

candidate(Pid, SessId, Handle, Candidate) ->
    cast(Pid, {candidate, SessId, Handle, Candidate}).


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


%% @private
get_clients(Pid) ->
    call(Pid, get_clients).



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
    janus_id :: nkmedia_janus_engine:id(),
    remote :: binary(),
    pass :: binary(),
    clients = #{} :: #{id() => {module(), Id::term(), reference()}},
    mons = #{} :: #{reference() => id()},
    trans = #{} :: #{op_id() => #trans{}},
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

%% TODO: Send and receive pings from session when they are not in same cluster
conn_init(NkPort) ->
    {ok, Remote} = nkpacket:get_remote_bin(NkPort),
    {ok, _Class, User} = nkpacket:get_user(NkPort),
    #{pass:=Pass, janus_id:=JanusId} = User,
    State = #state{
        janus_id = JanusId,
        pass = Pass,
        remote = Remote,
        pos = erlang:phash2(nklib_util:uid())
    },
    ?LLOG(info, "new session", [], State),
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
        #{<<"janus">>:=BinCmd, <<"transaction">>:=Trans} ->
            OpId = {trans, Trans},
            Cmd = case catch binary_to_existing_atom(BinCmd, latin1) of
                {'EXIT', _} -> BinCmd;
                Cmd2 -> Cmd2
            end,
            case extract_op(OpId, State) of
                {#trans{req=Req, from=From}, State2} ->
                    process_server_resp(Cmd, OpId, Req, From, Msg, NkPort, State2);
                not_found when Cmd==ack->
                    {ok, State};
                not_found when Cmd==event ->
                    % Some events have an (invalid) transaction
                    #{<<"session_id">>:=Id, <<"sender">>:=Handle} = Msg,
                    case get_client(Id, State) of
                        {ok, CallBack, ClientId} ->
                            event(CallBack, ClientId, Id, Handle, Msg, State),
                            {ok, State};
                        not_found ->
                            ?LLOG(notice, "unexpected server event2: ~p", [Msg], State),
                            {ok, State}
                    end;
                not_found ->
                    process_server_req(Cmd, Msg, NkPort, State)
            end;
        #{<<"janus">>:=<<"event">>, <<"session_id">>:=Id, <<"sender">>:=Handle} ->
            case get_client(Id, State) of
                {ok, CallBack, ClientId} ->
                    event(CallBack, ClientId, Id, Handle, Msg, State),
                    {ok, State};
                not_found ->
                    ?LLOG(notice, "unexpected server event: ~p", [Msg], State),
                    {ok, State}
            end;
        #{<<"janus">>:=<<"timeout">>, <<"session_id">>:=Id} ->
            ?LLOG(notice, "server session timeout for ~p", [Id], State),
            State2 = del_client(Id, State),
            {ok, State2};
        #{<<"janus">>:=<<"detached">>} ->
            {ok, State};
        #{<<"janus">>:=Cmd, <<"session_id">>:=Id, <<"sender">>:=Handle} ->
            case get_client(Id, State) of
                {ok, CallBack, ClientId} ->
                    event(CallBack, ClientId, Id, Handle, Msg, State);
                not_found ->
                    ?LLOG(notice, "unexpected ~s for ~p", [Cmd, Id], State)
            end,
            {ok, State};
        #{<<"janus">>:=Cmd} ->
            ?LLOG(notice, "unknown msg: ~s: ~p", [Cmd, Msg], State),
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
    nklib_util:reply(From, State),
    {ok, State};

conn_handle_call(get_clients, From, _NkPort, #state{clients=Clients}=State) ->
    nklib_util:reply(From, {ok, [{CallBack, Id} || {CallBack, Id, _Mon} <- Clients]}),
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

conn_handle_info({timeout, _, {op_timeout, OpId}}, _NkPort, State) ->
    case extract_op(OpId, State) of
        {#trans{req={candidate, _, _, _}}, State2} ->
            % ?LLOG(info, "candidate not replied from Janus", [], State),
            % Candidates are sometimes? not replied by Janus...
            {ok, State2};
        {#trans{from=From, req=Req}, State2} ->
            nklib_util:reply(From, {error, timeout}),
            ?LLOG(warning, "operation timeout: ~p", [Req], State),
            {ok, State2};
        not_found ->
            {ok, State}
    end;

conn_handle_info({'DOWN', Ref, process, _Pid, Reason}=Msg, NkPort, State) ->
    #state{mons=Mons}  = State,
    case maps:find(Ref, Mons) of
        {ok, Id} ->
            case Reason of
                normal ->
                    ?LLOG(info, "session ~p has stopped (normal)", [Id], State);
                _ ->
                    ?LLOG(notice, "session ~p has stopped (~p)", [Id, Reason], State)
            end,
            State2 = del_client(Id, State),
            send_client_req({destroy, Id}, undefined, NkPort, State2);
        _ ->
            lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
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
send_client_req(Msg, From, NkPort, #state{pos=Pos}=State) ->
    TransId = nklib_util:to_binary(Pos),
    case make_msg(Msg, TransId, State) of
        unknown_op ->
            uknown_op;
        Req ->
            State2 = insert_op({trans, TransId}, Msg, From, State),
            Pos2 = (Pos+1) rem 100000000000,
            send(Req, NkPort, State2#state{pos=Pos2})
    end.


%% @private
make_msg(info, TransId, State) ->
    make_req(info, TransId, #{}, State);

make_msg({create, _CallBack, _ClientId, _Pid}, TransId, State) ->
    make_req(create, TransId, #{}, State);

make_msg({attach, Id, Plugin}, TransId, State) ->
    Data = #{plugin=>Plugin, session_id=>Id},
    make_req(attach, TransId, Data, State);

make_msg({detach, Id, Handle}, TransId, State) ->
    Data = #{session_id=>Id, handle_id=>Handle},
    make_req(detach, TransId, Data, State);

make_msg({destroy, Id}, TransId, State) ->
    Data = #{session_id=>Id},
    make_req(destroy, TransId, Data, State);

make_msg({message, Id, Handle, Body, Jsep}, TransId, State) ->
    Msg1 = #{
        body => Body,
        handle_id => Handle,
        session_id => Id
    },
    Msg2 = case map_size(Jsep) of
        0 ->
            Msg1;
        _ ->
            Msg1#{jsep=>Jsep}
    end,
    make_req(message, TransId, Msg2, State);

make_msg({keepalive, Id}, TransId, State) ->
    Data = #{session_id=>Id},
    make_req(keepalive, TransId, Data, State);

make_msg({candidate, Id, Handle, #candidate{last=true}}, TransId, State) ->
    Data = #{
        session_id => Id,
        handle_id => Handle,
        candidate => #{completed=>true}
    },
    make_req(trickle, TransId, Data, State);

make_msg({candidate, Id, Handle, Candidate}, TransId, State) ->
    #candidate{m_id=MId, m_index=MLineIndex, a_line=ALine} = Candidate,
    Data = #{
        session_id => Id,
        handle_id => Handle,
        candidate => #{
            sdpMid => MId,
            sdpMLineIndex => MLineIndex,
            candidate => ALine
        }
    },
    make_req(trickle, TransId, Data, State);


make_msg(_Type, _TransId, _State) ->
    unknown_op.


%% @private
process_server_resp(ack, _OpId, {keepalive, _}, From, _Msg, _NkPort, State) ->
    nklib_util:reply(From, ok),
    {ok, State};

process_server_resp(ack, OpId, Req, From, _Msg, _NkPort, State) ->
    State2 = insert_op(OpId, Req, From, State),
    {ok, State2};

process_server_resp(server_info, _OpId, info, From, Msg, _NkPort, State) ->
    nklib_util:reply(From, {ok, Msg}),
    {ok, State};

process_server_resp(success, _OpId, Req, From, Msg, _NkPort, State) ->
    {Reply, State2} = case Req of
        {create, CallBack, ClientId, Pid} ->
            #{<<"data">> := #{<<"id">> := Id}} = Msg,
            {{ok, Id}, add_client(Id, CallBack, ClientId, Pid, State)};
        {attach, _Id, _Plugin} ->
            #{<<"data">> := #{<<"id">> := Handle}} = Msg,
            {{ok, Handle}, State};
        {detach, _Id, _Handle} ->
            {ok, State};
        {destroy, Id} ->
            {ok, del_client(Id, State)};
        {message, _Id, _Handle, _Body, _Jsep} ->
            #{<<"plugindata">>:=Data} = Msg,
            {{ok, Data, #{}}, State}
    end,
    nklib_util:reply(From, Reply),
    {ok, State2};

process_server_resp(event, _OpId, Req, From, Msg, _NkPort, State) ->
    {message, _Id, _Handle, _Body, _Jsep} = Req,
    #{<<"plugindata">> := Data} = Msg,
    Jsep = maps:get(<<"jsep">>, Msg, #{}),
    nklib_util:reply(From, {ok, Data, Jsep}),
    {ok, State};

process_server_resp(error, _OpId, _Req, From, Msg, _NkPort, State) ->
    #{<<"error">> := #{<<"code">>:=Code, <<"reason">>:=Reason}} = Msg,
    Error = list_to_binary(["(", nklib_util:to_binary(Code), "): ", Reason]),
    nklib_util:reply(From, {error, Error}),
    {ok, State};

process_server_resp(Other, _OpId, _Req, From, Msg, _NkPort, State) ->
    nklib_util:reply(From, {{unknown_response, Other}, Msg}),
    {ok, State}.


%% @private
process_server_req(Cmd, _Msg, _NkPort, State) ->
    ?LLOG(warning, "unexpected server req: ~s, ~p", [Cmd, _Msg], State),
    {ok, State}.

   


%% ===================================================================
%% Util
%% ===================================================================

%% @private
insert_op(OpId, Req, From, #state{trans=AllOps}=State) ->
    NewOp = #trans{
        req = Req, 
        timer = erlang:start_timer(?OP_TIME, self(), {op_timeout, OpId}),
        from = From
    },
    State#state{trans=maps:put(OpId, NewOp, AllOps)}.


%% @private
extract_op(OpId, #state{trans=AllOps}=State) ->
    case maps:find(OpId, AllOps) of
        {ok, #trans{timer=Timer}=OldOp} ->
            nklib_util:cancel_timer(Timer),
            State2 = State#state{trans=maps:remove(OpId, AllOps)},
            {OldOp, State2};
        error ->
            not_found
    end.


%% @private
get_client(SessId, #state{clients=Clients}) ->
    case maps:find(SessId, Clients) of
        {ok, {CallBack, Id, _Mon}} ->
            {ok, CallBack, Id};
        error ->
            not_found
    end.


%% @private
add_client(SessId, CallBack, Id, Pid, State) ->
    #state{clients=Clients, mons=Mons} = State,
    Mon = monitor(process, Pid),
    Clients2 = maps:put(SessId, {CallBack, Id, Mon}, Clients),
    Mons2 = maps:put(Mon, SessId, Mons),
    State#state{clients=Clients2, mons=Mons2}.


%% @private
del_client(SessId, State) ->
    #state{clients=Clients, mons=Mons} = State,
    case maps:find(SessId, Clients) of
        {ok, {CallBack, Id, Mon}} ->
            nklib_util:demonitor(Mon),
            Clients2 = maps:remove(SessId, Clients),
            Mons2 = maps:remove(Mon, Mons),
            event(CallBack, Id, SessId, 0, stop, State),
            State#state{clients=Clients2, mons=Mons2};
        error ->
            State
    end.


%% @private
event(undefined, _ClientId, _SessId, _Handle, _Event, State) ->
    State;

event(CallBack, ClientId, SessId, Handle, Event, State) ->
    case catch CallBack:janus_event(ClientId, SessId, Handle, Event) of
        ok ->
            ok;
        _ ->
            ?LLOG(warning, "Error calling ~p:janus_event/4: ~p", [CallBack], Error)
    end,
    State.


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
make_req(Cmd, TransId, Data, #state{pass=Pass}) ->
    Data#{
        janus => Cmd, 
        transaction => TransId,
        apisecret => Pass
    }.


%% @private
print(_Txt, [#{janus:=keepalive}], _State) ->
    ok;
print(_Txt, [#{<<"janus">>:=<<"ack">>}], _State) ->
    ok;
print(Txt, [#{<<"jsep">>:=Jsep}=Msg], State) ->
    Msg2 = Msg#{<<"jsep">>:=Jsep#{<<"sdp">>:=<<"...">>}},
    print(Txt, [nklib_json:encode_pretty(Msg2)], State),
    timer:sleep(10),
    io:format("\n~s\n", [maps:get(<<"sdp">>, Jsep)]);
print(Txt, [#{jsep:=Jsep}=Msg], State) ->
    Msg2 = Msg#{jsep:=Jsep#{sdp:=<<"...">>}},
    print(Txt, [nklib_json:encode_pretty(Msg2)], State),
    timer:sleep(10),
    io:format("\n~s\n", [maps:get(sdp, Jsep)]);
print(Txt, [#{}=Map], State) ->
    print(Txt, [nklib_json:encode_pretty(Map)], State);
print(Txt, Args, _State) ->
    ?LLOG(notice, Txt, Args, _State).








