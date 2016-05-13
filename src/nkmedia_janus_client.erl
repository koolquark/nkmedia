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
-export([info/1, create/3, destroy/2, message/4]).
-export([get_sessions/1]).

-export([transports/1, default_port/1]).
-export([conn_init/1, conn_encode/2, conn_parse/3, conn_stop/3]).
-export([conn_handle_call/4, conn_handle_cast/3, conn_handle_info/3]).
-export([print/3]).

-include("nkmedia.hrl").

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Janus Client "++Txt, Args)).

-define(PRINT(Txt, Args, State), 
        print(Txt, Args, State),    % Comment this
        ok).


-define(OP_TIME, 5*60*1000).    % Maximum operation time
-define(CALL_TIMEOUT, 5*60*1000).
-define(CODECS, [opus,vp8,speex,iLBC,'GSM','PCMU','PCMA']).

-define(JANUS_WS_TIMEOUT, 60*60*1000).


%% ===================================================================
%% Types
%% ===================================================================

-type id() :: {jc, integer(), integer()}.


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Starts a new verto session to FS
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


%% @doc Starts a new verto session to FS
-spec start(nkmedia_janus_engine:id()) ->
    {ok, pid()} | {error, term()}.

start(JanusId) ->
    case nkmedia_janus_engine:get_config(JanusId) of
        {ok, #{}=Config} -> 
            start(JanusId, Config);
        {error, Error} -> 
            {error, Error}
    end.


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


%% @doc Creates a new session
-spec create(pid(), nkmedia_session:id(), binary()) ->
    {ok, id()} | {error, term()}.

create(Pid, NkSessId, Plugin) ->
    case call(Pid, {create, NkSessId, self()}) of
        {ok, JanusSessId} ->
            Plugin2 = <<"janus.plugin.", (nklib_util:to_binary(Plugin))/binary>>,
            case call(Pid, {attach, JanusSessId, Plugin2}) of
                {ok, HandleId} ->
                    {ok, {jc, JanusSessId, HandleId}};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @doc Destroys a session
-spec destroy(pid(), id()) ->
    ok.

destroy(Pid, {jc, JanusSessId, HandleId}) ->
    cast(Pid, {detach, JanusSessId, HandleId}),
    cast(Pid, {destroy, JanusSessId}).


%% @doc
-spec message(pid(), id(), map(), map()) ->
    {ok, Res::map(), Jsep::map()} | {error, term()}. 

message(Pid, {jc, Id, HandleId}, Body, Jsep) ->
    call(Pid, {message, Id, HandleId, Body, Jsep}).


%% @private
-spec get_all() ->
    [{id(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).


%% @private
call(Pid, Msg) ->
    nklib_util:call(Pid, Msg, ?CALL_TIMEOUT).


%% @private
cast(Pid, Msg) ->
    gen_server:cast(Pid, Msg).


%% @private
get_sessions(Pid) ->
    call(Pid, get_sessions).



%% ===================================================================
%% Protocol callbacks
%% ===================================================================

-type op_id() :: {trans, integer()}.

-type op_type() :: info | create | attach.

-type session() :: {nkmedia_session:id(), pid(), reference()}.

-record(trans, {
    type :: op_type(),
    timer :: reference(),
    from :: {pid(), term()},
    data :: term()
}).

-record(state, {
    janus_id :: nkmedia_janus_engine:id(),
    remote :: binary(),
    pass :: binary(),
    sessions = #{} :: #{integer() => session()},
    session_mons = #{} :: #{reference() => integer()},
    trans = #{} :: #{op_id() => #trans{}}
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
        #{<<"janus">>:=<<"ack">>} ->
            {ok, State};
        #{<<"janus">>:=Cmd, <<"transaction">>:=Id} ->
            case extract_op({trans, Id}, State) of
                {Op, State2} ->
                    process_server_resp(Op, Cmd, Msg, NkPort, State2);
                not_found ->
                    process_server_req(Cmd, Msg, NkPort, State)
            end;
        #{<<"janus">>:=<<"timeout">>, <<"session_id">>:=Id} ->
            ?LLOG(notice, "server session timeout for ~p", [Id], State),
            State2 = removed_session(Id, State),
            {ok, State2};
        #{<<"janus">>:=<<"detached">>} ->
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
    gen_server:reply(From, State),
    {ok, State};

conn_handle_call(get_sessions, From, _NkPort, #state{sessions=Sessions}=State) ->
    gen_server:reply(From, {ok, Sessions}),
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

conn_handle_cast(Msg, NkPort, State) ->
    case handle_op(Msg, undefined, NkPort, State) of
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
        {#trans{from=From}, State2} ->
            gen_server:reply(From, {error, timeout}),
            ?LLOG(warning, "operation timeout", [], State),
            {stop, normal, State2};
        not_found ->
            {ok, State}
    end;

conn_handle_info({'DOWN', Ref, process, _Pid, Reason}=Msg, _NkPort, State) ->
    #state{session_mons=Mons}  = State,
    case maps:find(Ref, Mons) of
        {ok, Id} ->
            case Reason of
                normal ->
                    ?LLOG(info, "session ~p has stopped (normal)", [Id], State);
                _ ->
                    ?LLOG(notice, "session ~p has stopped (~p)", [Id, Reason], State)
            end,
            State2 = 
            removed_session(Id, State),
            {ok, State2};
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


% @private
handle_op(info, From, NkPort, State) ->
    send_client_req(info, #{}, From, NkPort, State);

handle_op({create, NkSessId, Pid}, From, NkPort, State) ->
    send_client_req(create, {NkSessId, Pid}, From, NkPort, State);

handle_op({attach, Id, Plugin}, From, NkPort, State) ->
    send_client_req(attach, {Id, Plugin}, From, NkPort, State);

handle_op({detach, Id, HandleId}, From, NkPort, State) ->
    send_client_req(detach, {Id, HandleId}, From, NkPort, State);

handle_op({destroy, Id}, From, NkPort, State) ->
    send_client_req(destroy, Id, From, NkPort, State);

handle_op({message, Id, HandleId, Body, Jsep}, From, NkPort, State) ->
    send_client_req(message, {Id, HandleId, Body, Jsep}, From, NkPort, State);

handle_op(_Op, _From, _NkPort, _State) ->
    unknown_op.


%% @private
process_server_resp(#trans{type=info}=Op, <<"server_info">>, Msg, _NkPort, State) ->
    #trans{type=info, from=From} = Op,
    nklib_util:reply(From, {ok, Msg}),
    {ok, State};

process_server_resp(#trans{type=create}=Op, <<"success">>, Msg, _NkPort, State) ->
    #trans{from=From, data={NkSessId, Pid}} = Op,
    #{<<"data">> := #{<<"id">> := Id}} = Msg,
    nklib_util:reply(From, {ok, Id}),
    State2 = added_session(Id, NkSessId, Pid, State),
    {ok, State2};

process_server_resp(#trans{type=attach}=Op, <<"success">>, Msg, _NkPort, State) ->
    #trans{from=From} = Op,
    #{<<"data">> := #{<<"id">> := Handle}} = Msg,
    nklib_util:reply(From, {ok, Handle}),
    {ok, State};

process_server_resp(#trans{type=destroy}=Op, <<"success">>, _Msg, _NkPort, State) ->
    #trans{from=From, data=Id} = Op,
    nklib_util:reply(From, ok),
    State2 = removed_session(Id, State),
    {ok, State2};

process_server_resp(#trans{type=message}=Op, <<"event">>, Msg, _NkPort, State) ->
    #trans{from=From} = Op,
    #{<<"plugindata">> := Data} = Msg,
    Jsep = maps:get(<<"jsep">>, Msg, #{}),
    nklib_util:reply(From, {ok, Data, Jsep}),
    {ok, State};

process_server_resp(Op, <<"success">>, _Msg, _NkPort, State) ->
    #trans{type=_Type, from=From} = Op,
    nklib_util:reply(From, ok),
    {ok, State};

process_server_resp(Op, <<"error">>, Msg, _NkPort, State) ->
    #{<<"error">> := #{<<"code">>:=Code, <<"reason">>:=Reason}} = Msg,
    #trans{type=_Type, from=From} = Op,
    nklib_util:reply(From, {error, {Code, Reason}}),
    {ok, State};

process_server_resp(Op, Other, Msg, _NkPort, State) ->
    #trans{type=_Type, from=From} = Op,
    nklib_util:reply(From, {{unknown, Other}, Msg}),
    {ok, State}.



%% @private
process_server_req(Cmd, _Msg, _NkPort, State) ->
    ?LLOG(warning, "Server REQ: ~s", [Cmd], State),
    {ok, State}.




%% ===================================================================
%% Util
%% ===================================================================


%% @private
send_client_req(Type, Data, From, NkPort, State) ->
    TransId = nklib_util:uid(),
    Msg = make_msg(TransId, Type, Data, State),
    State2 = insert_op({trans, TransId}, Type, From, Data, State),
    send(Msg, NkPort, State2).


%% @private
make_msg(TransId, info, _, _State) ->
    make_req(TransId, info, #{});

make_msg(TransId, create, _, _State) ->
    make_req(TransId, create, #{});

make_msg(TransId, attach, {Id, Plugin}, _State) ->
    Data = #{<<"plugin">>=>Plugin, <<"session_id">>=>Id},
    make_req(TransId, attach, Data);

make_msg(TransId, detach, {Id, HandleId}, _State) ->
    Data = #{<<"session_id">>=>Id, <<"handle_id">>=>HandleId},
    make_req(TransId, detach, Data);

make_msg(TransId, destroy, Id, _State) ->
    Data = #{<<"session_id">>=>Id},
    make_req(TransId, destroy, Data);

make_msg(TransId, message, {Id, HandleId, Body, Jsep}, _State) ->
    Msg1 = #{
        <<"body">> => Body,
        <<"handle_id">> => HandleId,
        <<"session_id">> => Id
    },
    Msg2 = case map_size(Jsep) of
        0 ->
            Msg1;
        _ ->
            Msg1#{<<"jsep">> => Jsep}
    end,
    make_req(TransId, message, Msg2).


%% @private
insert_op(OpId, Type, From, Data, #state{trans=AllOps}=State) ->
    NewOp = #trans{
        type = Type, 
        timer = erlang:start_timer(?OP_TIME, self(), {op_timeout, OpId}),
        from = From,
        data = Data
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
added_session(Id, NkSessId, Pid, State) ->
    #state{sessions=Sessions, session_mons=Mons} = State,
    Mon = monitor(process, Pid),
    Sessions2 = maps:put(Id, {NkSessId, Pid, Mon}, Sessions),
    Mons2 = maps:put(Mon, Id, Mons),
    State#state{sessions=Sessions2, session_mons=Mons2}.


%% @private
removed_session(Id, State) ->
    #state{sessions=Sessions, session_mons=Mons} = State,
    case maps:find(Id, Sessions) of
        {ok, {NkSessId, _Pid, Mon}} ->
            nklib_util:demonitor(Mon),
            Sessions2 = maps:remove(Id, Sessions),
            Mons2 = maps:remove(Mon, Mons),
            event(NkSessId, stop, State),
            State#state{sessions=Sessions2, session_mons=Mons2};
        error ->
            State
    end.


%% @private
event(NkSessId, Event, #state{janus_id=JanusId}=State) ->
    nkmedia_session:ms_event(NkSessId, JanusId, Event),
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
make_req(TransId, Cmd, Data) ->
    Data#{<<"janus">> => Cmd, <<"transaction">> => TransId}.



%% @private
print(Txt, [#{}=Map], State) ->
    print(Txt, [nklib_json:encode_pretty(Map)], State);
print(Txt, Args, _State) ->
    ?LLOG(info, Txt, Args, _State).








