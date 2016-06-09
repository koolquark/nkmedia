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
-module(nkmedia_kms_proxy_client).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/1, send/3, stop/1]).
-export([get_all/0]).
-export([transports/1, default_port/1]).
-export([conn_init/1, conn_encode/2, conn_parse/3]).
-export([conn_handle_call/4, conn_handle_cast/3, conn_handle_info/3]).

-include("nkmedia.hrl").

-define(CHECK_TIME, 10000).
-define(MAX_REQ_TIME, 60000).
 
-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Kurento proxy client (~s) "++Txt, [State#state.remote | Args])).

-define(KMS_WS_TIMEOUT, 60*60*1000).

-define(PRINT(Msg, Args, State),
    % ?LLOG(notice, Msg, Args, State),
    ok).




%% ===================================================================
%% Public
%% ===================================================================


%% @doc Starts a new verto session to Kurento
-spec start(pid()) ->
    {ok, pid()} | {error, term()}.

start(KurentoPid) ->
    {ok, Config} = nkmedia_kms_engine:get_config(KurentoPid),
    #{host:=Host, base:=Base} = Config,
    ConnOpts = #{
        class => ?MODULE,
        monitor => self(),
        idle_timeout => ?KMS_WS_TIMEOUT,
        user => #{proxy=>self()},
        path => <<"/kurento">>
    },
    {ok, Ip} = nklib_util:to_ip(Host),
    Conn = {?MODULE, ws, Ip, Base},
    nkpacket:connect(Conn, ConnOpts).


%% @doc 
stop(ConnPid) ->
    nkpacket_connection:stop(ConnPid).


%% @doc Sends data to a started proxy
-spec send(pid(), pid(), map()|binary()) ->
    ok | {error, term()}.

send(ConnPid, Pid, Data) ->
    gen_server:cast(ConnPid, {send, Pid, Data}).


%% @private
get_all() ->
    [Pid || {undefined, Pid}<- nklib_proc:values(?MODULE)].




%% ===================================================================
%% Protocol callbacks
%% ===================================================================


-record(trans, {
    dir :: c2s | s2c,
    method :: binary(),
    params :: map(),
    result :: map(),
    time :: nklib_util:timestamp()
}).


-record(state, {
    proxy :: pid(),
    remote :: binary(),
    trans = #{} :: #{{client|server, binary()} => #trans{}}
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
    {ok, _SrvId, #{proxy:=Pid}} = nkpacket:get_user(NkPort),
    State = #state{remote=Remote, proxy=Pid},
    ?LLOG(notice, "new connection (~p)", [self()], State),
    nklib_proc:put(?MODULE),
    % self() ! check_old_trans,
    {ok, State}.


%% @private
-spec conn_parse(term()|close, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_parse(close, _NkPort, State) ->
    {ok, State};

conn_parse({text, Data}, _NkPort, #state{proxy=_Pid}=State) ->
    Msg = nklib_json:decode(Data),
    case Msg of
        error -> 
            ?LLOG(warning, "JSON decode error: ~p", [Data], State),
            error(json_decode);
        _ ->
            ok
    end,
    ?PRINT("from server to client ~p\n~s", [_Pid, nklib_json:encode_pretty(Msg)], State),
    send_reply(Msg, State),
    {ok, update(s2c, Msg, State)}.


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

conn_handle_call(Msg, _From, _NkPort, State) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {stop, unexpected_call, State}.


-spec conn_handle_cast(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_handle_cast({send, _Pid, Msg}, NkPort, State) ->
    ?PRINT("from client ~p to server\n~s", [_Pid, nklib_json:encode_pretty(Msg)], State),
    case do_send(Msg, NkPort, State) of
        {ok, State2} -> 
            {ok, update(c2s, Msg, State2)};
        Other ->
            Other
    end;

conn_handle_cast(Msg, _NkPort, State) ->
    lager:error("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {ok, State}.


%% @private
-spec conn_handle_info(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

% conn_handle_info(check_old_trans, _NkPort, #state{trans=AllTrans}=State) ->
%     Now = nklib_util:timestamp(),
%     AllTrans1 = check_old_trans(Now, maps:to_list(AllTrans), []),
%     erlang:send_after(?CHECK_TIME, self(), check_old_trans),
%     {ok, State#state{trans=AllTrans1}};

conn_handle_info(Msg, _NkPort, State) ->
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
    {ok, State}.




%% ===================================================================
%% Util
%% ===================================================================


%% @private Process a client message
-spec update(c2s|s2c, map(), #state{}) ->
    #state{}.

update(Dir, #{<<"id">>:=Id, <<"method">>:=Method}=Msg, State) ->
    #state{trans=AllTrans} = State,
    case maps:find(Id, AllTrans) of
        error ->
            Trans = #trans{
                method = Method, 
                params = maps:get(<<"params">>, Msg, #{}), 
                dir = Dir,
                time = nklib_util:timestamp()
            },
            State#state{trans=maps:put(Id, Trans, AllTrans)};
        {ok, _} ->
            ?LLOG(warning, "Duplicated Id!", [], State),
            State#state{trans=maps:remove(Id, AllTrans)}
    end;

update(_Dir, #{<<"id">>:=Id, <<"result">>:=Result}, State) ->
    #state{trans=AllTrans} = State,
    case maps:find(Id, AllTrans) of
        {ok, Trans} ->
            Trans2 = Trans#trans{result=Result},
            print_trans(Trans2);
        error ->
            ?LLOG(warning, "Result for unkown Id!", [], State)
    end,
    State#state{trans=maps:remove(Id, AllTrans)};

update(Dir, #{<<"method">>:=<<"onEvent">>, <<"params">>:=Params}, State) ->
    Trans = #trans{
        dir = Dir,
        method = <<"onEvent">>, 
        params = Params,
        result = #{}
    },
    print_trans(Trans),
    State;

update(_Dir, Msg, State) ->
    ?LLOG(warning, "unrecognized msg: ~s", [nklib_json:encode_pretty(Msg)], State),
    State.





%% @private
-spec send_reply(binary()|map(), #state{}) ->
    ok.

send_reply(Msg, #state{proxy=Pid}) ->
    ok = nkmedia_kms_proxy_server:send_reply(Pid, Msg).


%% @private
do_send(Msg, NkPort, State) ->
    case nkpacket_connection:send(NkPort, Msg, State) of
        ok -> {ok, State};
        {error, Error} -> {stop, Error, State}
    end.


%% @private
% check_old_trans(_Now, [], Acc) ->
%     maps:from_list(Acc);

% check_old_trans(Now, [{{Type, Id}, #trans{time=Time}=Trans}|Rest], Acc) ->
%     Acc1 = case Now - Time > (?MAX_REQ_TIME div 1000) of
%         true ->
%             lager:warning("NkMEDIA verto removing old request: ~p", [Trans]),
%             Acc;
%         false ->
%             [{{Type, Id}, Trans}|Acc]
%     end,
    % check_old_trans(Now, Rest, Acc1).



%% @private
% print_trans(_Class, _Trans) -> ok.

print_trans(#trans{dir=Dir, method=Req, params=Params, result=Result}) ->
    T1 = case Dir of
        c2s -> "C->S";
        s2c -> "S->C"
    end,
    lager:info("~s method '~s' -> OK\n~s ->\n~s", 
               [T1, Req, nklib_json:encode_pretty(Params), 
                         nklib_json:encode_pretty(Result)]).




        




%% ===================================================================
%% Util
%% ===================================================================


% parse_kms(#{<<"kms">>:=Kurento, <<"transaction">>:=TransId}) ->
%     case Kurento of
%         <<"success">> -> {resp, Kurento, TransId};
%         <<"error">> -> {resp, Kurento, TransId};
%         <<"ack">> -> {ack, TransId};
%         <<"event">> -> {event, TransId};
%         _ -> {req, Kurento, TransId}
%     end;

% parse_kms(#{<<"kms">>:=Kurento}) ->
%     {cmd, Kurento}.


