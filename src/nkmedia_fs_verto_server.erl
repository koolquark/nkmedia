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
-module(nkmedia_fs_verto_server).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(nkpacket_protocol).


-export([hangup/1, hangup/2, get_all/0]).
-export([transports/1, default_port/1]).
-export([conn_init/1, conn_encode/2, conn_parse/3, conn_handle_info/3, conn_stop/3]).

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA verto server (~s) "++Txt, [State#state.remote | Args])).

-define(HANDLE(Fun, Args, State), 
    nklib_gen_server:handle_any(Fun, Args, State, #state.callback, #state.substate)).

% -include_lib("nkpacket/include/nkpacket.hrl").


%% ===================================================================
%% Callbacks
%% ===================================================================


-callback nkmedia_verto_init(nkpacket:nkport(), State::map()) ->
    {ok, State::map()}.


-callback nkmedia_verto_login(VertoSessId::binary(), Login::binary(), Pass::binary(),
                              State::map()) ->
    {ok, State::map()} | {error, term(), State::map()}.


-callback nkmedia_verto_invite(Dest::binary(), CallId::binary(), SDP::binary(), 
                               Dialog::map(), nkpacket:nkport(), State::map()) ->
    {ok, SDP::binary(), State::map()} | {error, term(), State::map()}.


-callback nkmedia_verto_bye(CallId::binary(), State::map()) ->
    {ok, Code::integer(), Reason::binary(), State::map()} | 
    {error, term(), State::map()}.


-callback nkmedia_verto_dtmf(CallId::binary(), DTMF::binary(), State::map()) ->
    {ok, State::map()} | {error, term(), State::map()}.


-callback nkmedia_verto_terminate(Reason::term(), State::map()) ->
    ok.



%% ===================================================================
%% Public
%% ===================================================================


hangup(Pid) ->
    hangup(Pid, 16).

hangup(Pid, Code) ->
    Pid ! {hangup, Code}.


get_all() ->
    maps:from_list(
        [{Local, Remote} || {Remote, Local} <- nklib_proc:values(?MODULE)]).



%% ===================================================================
%% Protocol callbacks
%% ===================================================================


-record(state, {
    remote :: binary(),
    callback :: atom(),
    session :: binary(),
    current_id = 1 :: integer(),
    call_id :: binary(),
    bw_bytes :: integer(),
    bw_time :: integer(),
    substate :: term()
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
    {ok, SubState} = Callback:nkmedia_verto_init(NkPort, #{}),
    State = #state{remote=Remote, callback=Callback, substate=SubState},
    nklib_proc:put(?MODULE, undefined),
    ?LLOG(info, "new connection (~p)", [self()], State),
    {ok, State}.


%% @private
-spec conn_parse(term()|close, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_parse(close, _NkPort, State) ->
    {ok, State};

% conn_parse({text, <<"#S", _/binary>>=Msg}, _NkPort, State) ->
%     #state{fs_session_pid=FsSession} = State,
%     case FsSession of
%         undefined ->
%             ?LLOG(warning, "received bw test without login", [], State),
%             {stop, normal, State};
%         Pid ->
%             nkmedia_fs_verto_client:send_bw_test(Pid, Msg),
%             {ok, State}
%     end;

%% Start of client bandwith test
conn_parse({text, <<"#SPU ", BytesBin/binary>>}, _NkPort, State) ->
    Bytes = nklib_util:to_integer(BytesBin),
    262144 = Bytes,
    Now = nklib_util:l_timestamp(),
    lager:info("Client start BW test (SPU, ~p)", [Bytes]),
    State1 = State#state{bw_bytes=Bytes, bw_time=Now},
    {ok, State1};

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
            lager:info("BW client completed (~p msecs, ~p Kbps)", 
                         [ClientDiff, 262144*8 div ClientDiff]),
            %% We send start of server bw test
            Msg1 = <<"#SPU ", (nklib_util:to_binary(ClientDiff))/binary>>,
            case send(Msg1, NkPort) of
                ok ->
                    case send_bw_test(NkPort) of
                        {ok, ServerDiff} ->
                            lager:info("BW server completed (~p msecs, ~p Kpbs)", 
                                        [ServerDiff, 262144*8 div ServerDiff]),
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

conn_parse({text, Data}, NkPort, #state{session=SessionId}=State) ->
    Msg = case nklib_json:decode(Data) of
        error ->
            ?LLOG(warning, "JSON decode error: ~p", [Data], State),
            error(json_decode);
        Json ->
            Json
    end,
    nkmedia_fs_verto:print("Verto Server recv", Msg),
    case SessionId of
        undefined ->
            case Msg of
                #{<<"method">>:=<<"login">>} ->
                    parse_msg(Msg, NkPort, State);
                _ ->
                    ?LLOG(notice, "Invalid message without login: ~p", [Msg], State),
                    {stop, normal, State}
            end;
        _ ->
            parse_msg(Msg, NkPort, State)
    end.


-spec conn_encode(term(), nkpacket:nkport()) ->
    {ok, nkpacket:outcoming()} | continue | {error, term()}.

conn_encode(Msg, _NkPort) when is_map(Msg) ->
    Json = nklib_json:encode(Msg),
    {ok, {text, Json}};

conn_encode(Msg, _NkPort) when is_binary(Msg) ->
    {ok, {text, Msg}}.


-spec conn_handle_info(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

%% @doc In case we use the FS-based method
conn_handle_info({verto_bw_test, Data}, NkPort, State) ->
    send(Data, NkPort, State);

conn_handle_info({hangup, _Code}, _NkPort, State) ->
    %% TODO: Send proponer by
    {stop, normal, State};

% conn_handle_info({'DOWN', _, process, Pid, _}, _NkPort, #state{ch_pid=Pid}=State) ->
%     ?LLOG(notice, "remote channel stopped, hanging up", [], State),
%     {stop, normal, State};

conn_handle_info(Info, _NkPort, State) ->
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {ok, State}.


%% @doc Called when the connection stops
-spec conn_stop(Reason::term(), nkpacket:nkport(), #state{}) ->
    ok.

conn_stop(Reason, _NkPort, State) ->
    catch ?HANDLE(nkmedia_verto_terminate, [Reason], State).



%% ===================================================================
%% Requests
%% ===================================================================

%% @private
parse_msg(Msg, NkPort, State) ->
    case nkmedia_fs_verto:parse_class(Msg) of
        {{req, Method}, _Id} ->
            process_client_req(Method, Msg, NkPort, State);
        {{resp, Resp}, _Id} ->
            process_client_resp(Resp, Msg, NkPort, State);
        unknown ->
            {ok, State}
    end.

%% @private
process_client_req(<<"login">>, #{<<"params">>:=#{<<"passwd">>:=_}=Params}=Msg, 
                   NkPort, State) ->
    case Params of
        #{
            <<"login">> := Login,
            <<"passwd">> := Passwd,
            <<"sessid">> := SessId
        } ->
            case ?HANDLE(nkmedia_verto_login, [SessId, Login, Passwd], State) of
                {ok, State1} ->
                    ReplyParams = #{
                        <<"message">> => <<"logged in">>, 
                        <<"sessid">> => SessId
                    },
                    nklib_proc:put(?MODULE, {login, Login}),
                    Reply = nkmedia_fs_verto:make_resp(ReplyParams, Msg),
                    send(Reply, NkPort, State1#state{session=SessId});
                {error, Error, State1} ->
                    ?LLOG(notice, "login error for ~s: ~p", [Login, Error], State1),
                    Reply = nkmedia_fs_verto:make_error(
                                        -32001, <<"Authentication Failure">>, Msg),
                    send(Reply, NkPort, State1)
            end;
        _ ->
            ?LLOG(warning, "invalid login params: ~p", [Params], State),
            {stop, normal, State}
    end;

process_client_req(<<"login">>, Msg, NkPort, State) ->
    Reply = nkmedia_fs_verto:make_error(-32000, <<"Authentication Required">>, Msg),
    send(Reply, NkPort, State);

process_client_req(<<"verto.invite">>, Msg, NkPort, #state{call_id=undefined}=State) ->
    #{
        <<"params">> := #{
            <<"dialogParams">> := #{ 
                <<"destination_number">> := Dest,
                <<"callID">> := CallId
            } = Dialog,
            <<"sdp">> := SDP
        }
    } = Msg,
    case ?HANDLE(nkmedia_verto_invite, [Dest, CallId, SDP, Dialog, NkPort], State) of
        {ok, SDP2, State1} ->
            % monitor(process, ChPid),
            #state{session=SessionId} = State,
            Data1 = #{
                <<"callID">> => CallId,
                <<"message">> => <<"CALL CREATED">>,
                <<"sessid">> => SessionId
            },
            Msg1 = nkmedia_fs_verto:make_resp(Data1, Msg),
            Data2 = #{
                <<"callID">> => CallId,
                <<"sdp">> => SDP2
            },
            #state{current_id=Id} = State,
            Msg2 = nkmedia_fs_verto:make_req(Id, <<"verto.answer">>, Data2),
            State2 = State1#state{call_id = CallId},
            send([Msg1, Msg2], NkPort, State2);
        {error, Error, State2} ->
            ?LLOG(warning, "internal error sending invite: ~p", [Error], State),
            {stop, normal, State2}
    end;

process_client_req(<<"verto.invite">>, Msg, NkPort, State) ->
    Msg2 = nkmedia_fs_verto:make_error(-40000, <<"In Call">>, Msg),
    send(Msg2, NkPort, State);

process_client_req(<<"verto.bye">>, Msg, NkPort, #state{call_id=undefined}=State) ->
    Msg2 = nkmedia_fs_verto:make_error(-40000, <<"No Call">>, 
        Msg),
    send(Msg2, NkPort, State);

process_client_req(<<"verto.bye">>, Msg, NkPort, #state{call_id=CallId}=State) ->
    #{
        <<"params">> := #{
            <<"dialogParams">> := #{
                <<"callID">> := CallId
            }
        }
    } = Msg,
    State2 = State#state{call_id = undefined},
    case ?HANDLE(nkmedia_verto_bye, [CallId], State2) of
        {ok, Code, Cause, State3} ->
            #state{session=SessionId} = State,
            Data = #{
                <<"callID">> => CallId,
                <<"cause">> => Cause, %             <<"NORMAL_CLEARING">>,
                <<"causeCode">> => Code,            % 16,
                <<"message">> => <<"CALL ENDED">>,
                <<"sessid">> => SessionId
            },
            Msg2 = nkmedia_fs_verto:make_resp(Data, Msg),
            send(Msg2, NkPort, State3);
        {error, Error, State3} ->
            ?LLOG(warning, "error sending bye: ~p", [Error], State3),
            {stop, normal, State3}
    end;

process_client_req(<<"verto.info">>, Msg, NkPort, #state{call_id=undefined}=State) ->
    Msg2 = nkmedia_fs_verto:make_error(-40000, <<"No Call">>, Msg),
    send(Msg2, NkPort, State);

process_client_req(<<"verto.info">>, Msg, NkPort, #state{call_id=CallId}=State) ->
    #{
        <<"params">> := #{
            <<"dialogParams">> := #{
                <<"callID">> := CallId
            },
            <<"dtmf">> := DTMF
        }
    } = Msg,
    case ?HANDLE(nkmedia_verto_dtmf, [CallId, DTMF], State) of
        {ok, State2} ->
            #state{session=SessionId} = State,
            Data = #{
                <<"message">> => <<"SENT">>,
                <<"sessid">> => SessionId
            },
            Msg2 = nkmedia_fs_verto:make_resp(Data, Msg),
            send(Msg2, NkPort, State2);
        {error, Error, State2} ->
            ?LLOG(warning, "internal error sending dtmf: ~p", [Error], State),
            {stop, normal, State2}
    end;

process_client_req(Method, Msg, _NkPort, State) ->
    ?LLOG(warning, "unexpected client request ~s: ~p", [Method, Msg], State),
    {ok, State}.


%% @private
process_client_resp({ok, <<"verto.answer">>}, _, _NkPort, State) ->
    {ok, State};

process_client_resp(Resp, Msg, _NkPort, State) ->
    ?LLOG(warning, "unexpected client response ~p: ~p", [Resp, Msg], State),
    {ok, State}.


%% ===================================================================
%% Util
%% ===================================================================


%% @private
send(Msg, NkPort, State) ->
    case send(Msg, NkPort) of
        ok -> 
            {ok, State};
        error -> 
            ?LLOG(notice, "error sending reply:", [], State),
            {stop, normal, State}
    end.


send(Msg, NkPort) ->
    nkmedia_fs_verto:send("Verto Server send", Msg, NkPort).



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


