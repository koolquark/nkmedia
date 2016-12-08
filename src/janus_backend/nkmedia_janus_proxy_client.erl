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
-module(nkmedia_janus_proxy_client).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/1, send/3, stop/1]).
-export([get_all/0]).
-export([transports/1, default_port/1]).
-export([conn_init/1, conn_encode/2, conn_parse/3]).
-export([conn_handle_call/4, conn_handle_cast/3, conn_handle_info/3]).

-include("../../include/nkmedia.hrl").

-define(CHECK_TIME, 10000).
-define(MAX_REQ_TIME, 60000).
 
-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Janus proxy client (~s) "++Txt, [State#state.remote | Args])).

-define(JANUS_WS_TIMEOUT, 60*60*1000).

-define(PRINT(Msg, Args, State),
    ?LLOG(notice, Msg, Args, State),
    ok).




%% ===================================================================
%% Public
%% ===================================================================


%% @doc Starts a new verto session to Janus
-spec start(pid()) ->
    {ok, pid()} | {error, term()}.

start(JanusPid) ->
    {ok, Config} = nkmedia_janus_engine:get_config(JanusPid),
    #{host:=Host, base:=Base, pass:=Pass} = Config,
    ConnOpts = #{
        class => ?MODULE,
        monitor => self(),
        idle_timeout => ?JANUS_WS_TIMEOUT,
        user => #{proxy=>self(), pass=>Pass},
        ws_proto => <<"janus-protocol">>
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
    req :: binary(),
    req_msg :: map(),
    resp :: {ok, binary()} | {error, {integer(), binary()}},
    resp_msg :: map(),
    has_ack :: boolean(),
    time :: nklib_util:timestamp()
}).


-record(state, {
    proxy :: pid(),
    pass :: binary(),
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
    {ok, _SrvId, #{proxy:=Pid, pass:=Pass}} = nkpacket:get_user(NkPort),
    State = #state{remote=Remote, proxy=Pid, pass=Pass},
    ?LLOG(notice, "new connection (~p)", [self()], State),
    nklib_proc:put(?MODULE),
    % self() ! check_old_trans,
    {ok, State}.


%% @private
-spec conn_parse(term()|close, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_parse(close, _NkPort, State) ->
    {ok, State};

conn_parse({text, Data}, _NkPort, #state{proxy=Pid}=State) ->
    Msg = nklib_json:decode(Data),
    case Msg of
        error -> 
            ?LLOG(warning, "JSON decode error: ~p", [Data], State),
            error(json_decode);
        _ ->
            ok
    end,
    case Msg of
        #{<<"jsep">>:=Jsep} ->
            Msg2 = Msg#{<<"jsep">>:=Jsep#{<<"sdp">>:=<<"...">>}},
            ?PRINT("from server ~p to client \n~s", 
                   [Pid, nklib_json:encode_pretty(Msg2)], State),
            timer:sleep(10),
            io:format("\n~s\n", [maps:get(<<"sdp">>, Jsep)]);
        _ ->
            ?PRINT("from server ~p to client \n~s", 
                   [Pid, nklib_json:encode_pretty(Msg)], State)
    end,
    send_reply(Msg, State),
    {ok, update(Msg, State)}.


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

conn_handle_cast({send, Pid, Msg}, NkPort, State) ->
    case Msg of
        #{<<"jsep">>:=Jsep} ->
            Msg2 = Msg#{<<"jsep">>:=Jsep#{<<"sdp">>:=<<"...">>}},
            ?PRINT("from client ~p to server \n~s", 
                   [Pid, nklib_json:encode_pretty(Msg2)], State),
            timer:sleep(10),
            io:format("\n~s\n", [maps:get(<<"sdp">>, Jsep)]);
        _ ->
            ?PRINT("from client ~p to server \n~s", 
                   [Pid, nklib_json:encode_pretty(Msg)], State)
    end,
    case do_send(Msg, NkPort, State) of
        {ok, State2} -> 
            {ok, update(Msg, State2)};
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
-spec update(map(), #state{}) ->
    #state{}.

update(#{<<"janus">>:=Janus, <<"transaction">>:=Id}=Msg, State) ->
    #state{trans=AllTrans} = State,
    case maps:find(Id, AllTrans) of
        error ->
            Trans = #trans{
                req = Janus, 
                req_msg = Msg, 
                has_ack = false,
                time = nklib_util:timestamp()
            },
            State#state{trans=maps:put(Id, Trans, AllTrans)};
        {ok, Trans} when Janus == <<"ack">> ->
            Trans2 = Trans#trans{has_ack=true},
            State#state{trans=maps:put(Id, Trans2, AllTrans)};
        {ok, _Trans} ->
            % Trans2 = Trans#trans{resp=Janus, resp_msg=Msg},
            % print_trans(Trans2),
            State#state{trans=maps:remove(Id, AllTrans)}
    end;

update(#{<<"janus">>:=_Janus}=_Msg, State) ->
    % ?LLOG(info, "server event '~s':\n~s", 
    %       [Janus, nklib_json:encode_pretty(Msg)], State),
    State.

%% @private
-spec send_reply(binary()|map(), #state{}) ->
    ok.

send_reply(Msg, #state{proxy=Pid}) ->
    ok = nkmedia_janus_proxy_server:send_reply(Pid, Msg).


%% @private
do_send(Msg, NkPort, #state{pass=Pass}=State) ->
    case nkpacket_connection:send(NkPort, Msg#{apisecret=>Pass}, State) of
        ok -> {ok, State};
        {error, Error} -> {stop, Error, State}
    end.
