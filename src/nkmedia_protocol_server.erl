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

%% @doc Implementation of the Media Management Interface (server)
-module(nkmedia_protocol_server).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([event/4]).
-export([transports/1, default_port/1]).
-export([conn_init/1, conn_encode/2, conn_parse/3, conn_handle_call/4, 
         conn_handle_cast/3, conn_handle_info/3, conn_stop/3]).
-export([get_all/0, print/3]).


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Admin Server (~s) "++Txt, [State#state.user | Args])).

-define(PRINT(Txt, Args, State), 
        % print(Txt, Args, State),    % Uncomment this for detailed logs
        ok).


-define(OP_TIME, 5).            % Maximum operation time (without ACK)
-define(ACKED_TIME, 180).       % Maximum operation time (with ACK)
-define(CALL_TIMEOUT, 180).     % 




%% ===================================================================
%% Types
%% ===================================================================


-type user_state() :: 
    #{
    }.


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Sends an event to the connection
event(Pid, Class, SubClass, Body) ->
    do_call(Pid, {event, Class, SubClass, Body}).


%% @private
-spec get_all() ->
    [pid()].

get_all() ->
    nklib_proc:values(?MODULE).


%% ===================================================================
%% Protocol callbacks
%% ===================================================================

-type tid() :: integer().

-record(trans, {
    op :: term(),
    timer :: reference(),
    from :: {pid(), term()} | {async, pid(), term()}
}).

-record(state, {
    srv_id :: nkservice:id(),
    user = <<"undefined">> :: binary(),
    session_id = <<>> :: binary(),
    trans :: #{tid() => #trans{}},
    tid :: integer(),
    user_state :: user_state()
}).


%% @private
-spec transports(nklib:scheme()) ->
    [nkpacket:transport()].

transports(_) -> [wss, ws].

-spec default_port(nkpacket:transport()) ->
    inet:port_number() | invalid.

default_port(ws) -> 9010;
default_port(wss) -> 9011.


-spec conn_init(nkpacket:nkport()) ->
    {ok, #state{}}.

conn_init(NkPort) ->
    % {ok, {nkmedia_admin, SrvId}, _} = nkpacket:get_user(NkPort),
    {ok, Remote} = nkpacket:get_remote_bin(NkPort),
    UserState = #{remote=>Remote},
    State1 = #state{
        trans = #{}, 
        tid = erlang:phash2(self()),
        user_state = UserState

    },
    nklib_proc:put(?MODULE, <<>>),
    lager:info("NkMEDIA Admin new connection (~s, ~p)", [Remote, self()]),
    {ok, State2} = handle(nkmedia_admin_init, [NkPort], State1),
    {ok, State2}.


%% @private
-spec conn_parse(term()|close, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_parse(close, _NkPort, State) ->
    {ok, State};

conn_parse({text, Data}, NkPort, State) ->
    Msg = case nklib_json:decode(Data) of
        error ->
            ?LLOG(warning, "JSON decode error: ~p", [Data], State),
            error(json_decode);
        Json ->
            Json
    end,
    ?PRINT("received ~s", [Msg], State),
    case Msg of
        #{<<"class">> := <<"nkmedia">>, <<"cmd">> := Cmd, <<"tid">> := TId} ->
            Data = maps:get(<<"data">>, Msg, #{}),
            case process_client_req(Cmd, Data, TId, NkPort, State) of
                {ok, State2} ->
                    {ok, State2};
                unrecognized ->
                    ?LLOG(warning, "unrecognized client request ~s: ~p", 
                          [Cmd, Data], State),
                    send_reply_error(1000, TId, NkPort, State)
            end;
        #{<<"result">> := Result, <<"tid">> := TId} ->
            case extract_op(TId, State) of
                {Trans, State2} ->
                    Data = maps:get(<<"data">>, Msg, #{}),
                    process_client_resp(Result, Data, Trans, NkPort, State2);
                not_found ->
                    ?LLOG(warning, "received client response for unknown req: ~p", 
                          [Msg], State),
                    {ok, State}
            end;
        #{<<"ack">> := TId} ->
            case extract_op(TId, State) of
                {Trans, State2} ->
                    {ok, extend_op(TId, Trans, State2)};
                not_found ->
                    ?LLOG(warning, "received client response for unknown req: ~p", 
                          [Msg], State),
                    {ok, State}
            end;
        _ ->
            ?LLOG(warning, "received unrecognized msg: ~p", [Msg], State),
            {stop, normal, State}
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
            handle(nkmedia_admin_handle_call, [Msg, From], State);
        Other ->
            Other
    end.


-spec conn_handle_cast(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_cast(Msg, NkPort, State) ->
    case handle_op(Msg, undefined, NkPort, State) of
        unknown_op ->
            handle(nkmedia_admin_handle_cast, [Msg], State);
        Other ->
            Other
    end.


-spec conn_handle_info(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

% conn_handle_info({'DOWN', Ref, process, _Pid, _Reason}=Info, _NkPort, State) ->
%     #state{calls=Calls} = State,
%     case lists:keyfind(Ref, 3, Calls) of
%         {_CallId, SessId, Ref} ->
%             ?LLOG(notice, "monitor process down for ~s", [SessId], State),
%             {stop, normal, State};
%         false ->
%             handle(nkmedia_admin_handle_info, [Info], State)
%     end;

conn_handle_info({timeout, _, {op_timeout, TId}}, _NkPort, State) ->
    case extract_op(TId, State) of
        {Trans, State2} ->
            user_reply(Trans, {error, timeout}),
            ?LLOG(warning, "operation ~p timeout!", [TId], State),
            {stop, normal, State2};
        not_found ->
            {ok, State}
    end;

conn_handle_info(Info, _NkPort, State) ->
    handle(nkmedia_admin_handle_info, [Info], State).


%% @doc Called when the connection stops
-spec conn_stop(Reason::term(), nkpacket:nkport(), #state{}) ->
    ok.

conn_stop(Reason, _NkPort, State) ->
    catch handle(nkmedia_admin_terminate, [Reason], State).



%% ===================================================================
%% Requests
%% ===================================================================

%% @private
handle_op({event, Class, Subclass, Body}, From, NkPort, State) ->
    Msg = #{
        cmd => event,
        data => #{
            class => Class,
            subclass => Subclass,
            body => Body
        }
    },
    send_request(Msg, From, NkPort, State);

handle_op(_Msg, _From, _NkPort, _State) ->
    unknown_op.


%% @private
process_client_req(<<"login">>, Data, TId, NkPort, State) ->
    case Data of
        #{<<"user">>:=User, <<"pass">>:=Pass} ->
            send_ack(TId, NkPort, State),
            case handle(nkmedia_admin_login, [User, Pass], State) of
                {true, State2} ->
                    SessId = nklib_util:uuid_4122(),
                    State3 = State2#state{user=User, session_id=SessId},
                    send_reply_ok(#{sess_id=>SessId}, TId, NkPort, State3);
                {false, State2} ->
                    send_reply_error(1001, TId, NkPort, State2)
            end;
        _ ->
            unrecognized
    end;

process_client_req(_Cmd, _Data, _TId, _NkPort, _State) ->
    unrecognized.


%% @private
process_client_resp(Result, Data, #trans{from=From}, _NkPort, State) ->
    nklib_util:reply(From, {ok, Result, Data}),
    {ok, State}.



%% ===================================================================
%% Util
%% ===================================================================

%% @private
do_call(Pid, Msg) ->
    nklib_util:call(Pid, Msg, 1000*?CALL_TIMEOUT).


%% @private
insert_op(TId, Op, From, #state{trans=AllTrans}=State) ->
    Trans = #trans{
        op = Op,
        from = From,
        timer = erlang:start_timer(1000*?OP_TIME, self(), {op_timeout, TId})
    },
    State#state{trans=maps:put(TId, Trans, AllTrans)}.


%% @private
extract_op(TId, #state{trans=AllTrans}=State) ->
    case maps:find(TId, AllTrans) of
        {ok, #trans{timer=Timer}=OldTrans} ->
            nklib_util:cancel_timer(Timer),
            State2 = State#state{trans=maps:remove(TId, AllTrans)},
            {OldTrans, State2};
        error ->
            not_found
    end.


%% @private
extend_op(TId, #trans{timer=Timer}=Trans, #state{trans=AllTrans}=State) ->
    nklib_util:cancel_timer(Timer),
    Timer2 = erlang:start_timer(1000*?ACKED_TIME, self(), {op_timeout, TId}),
    Trans2 = Trans#trans{timer=Timer2},
    State#state{trans=maps:put(TId, Trans2, AllTrans)}.


%% @private
send_request(Msg, From, NkPort, #state{tid=TId}=State) ->
    State2 = insert_op(TId, Msg, From, State),
    Msg2 = Msg#{tid=>TId},
    send(Msg2, NkPort, State2#state{tid=TId+1}).


%% @private
send_reply_ok(Data, TId, NkPort, State) ->
    Msg = #{
        result => ok,
        tid => TId,
        data => Data
    },
    send(Msg, NkPort, State).


%% @private
send_reply_error(Code, TId, NkPort, State) ->
    Msg = #{
        result => error,
        tid => TId,
        data => #{ 
            code => Code,
            error => code_to_error(Code)
        }
    },
    send(Msg, NkPort, State).


%% @private
send_ack(TId, NkPort, State) ->
    Msg = #{ack => TId},
    _ = send(Msg, NkPort, State),
    ok.


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
handle(Fun, Args, State) ->
    nklib_gen_server:handle_any(Fun, Args, State, #state.srv_id, #state.user_state).
    

%% @private
print(Txt, [#{}=Map], State) ->
    print(Txt, [nklib_json:encode_pretty(Map)], State);
print(Txt, Args, State) ->
    ?LLOG(info, Txt, Args, State).

 
%% @private
user_reply(#trans{from=undefined}, _Msg) ->
    ok;
user_reply(#trans{from={async, Pid, Ref}}, Msg) ->
    Pid ! {?MODULE, Ref, Msg};
user_reply(#trans{from=From}, Msg) ->
    gen_server:reply(From, Msg).


%% @private
code_to_error(100) -> <<"Invalid command">>;
code_to_error(_) -> <<"Undefined Error">>.
