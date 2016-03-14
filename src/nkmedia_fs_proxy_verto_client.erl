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
-module(nkmedia_fs_proxy_verto_client).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(nkpacket_protocol).

-export([start/1, send/2, stop/1]).
-export([get_all/0]).
-export([transports/1, default_port/1]).
-export([conn_init/1, conn_encode/2, conn_parse/3]).
-export([conn_handle_call/4, conn_handle_cast/3, conn_handle_info/3]).

-include("nkmedia.hrl").

-define(CHECK_TIME, 10000).
-define(MAX_REQ_TIME, 60000).
 
-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA verto proxy client (~s) "++Txt, [State#state.remote | Args])).


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Starts a new verto session to FS
-spec start(nkmedia_fs:start_opts()) ->
    {ok, pid()} | {error, term()}.

start(#{pos:=Pos, pass:=Pass}) ->
    {ok, Ip} = nklib_util:to_ip(nkmedia_app:get(docker_host)),
    ConnOpts = #{
        class => nkmedia_fs_proxy,
        monitor => self(),
        idle_timeout => ?WS_TIMEOUT,
        user => #{proxy=>self(), pass=>Pass}
    },
    Conn = {nkmedia_fs_proxy_verto_client, ws, Ip, 8181+Pos},
    nkpacket:connect(Conn, ConnOpts).


%% @doc 
stop(ConnPid) ->
    nkpacket_connection:stop(ConnPid).


%% @doc Sends data to a started proxy
-spec send(pid(), map()|binary()) ->
    ok | {error, term()}.

send(ConnPid, Data) ->
    gen_server:cast(ConnPid, {send, Data}).


%% @private
get_all() ->
    [Pid || {undefined, Pid}<- nklib_proc:values(?MODULE)].




%% ===================================================================
%% Protocol callbacks
%% ===================================================================


-record(trans, {
    % class :: client | server,
    % from :: {pid(), term()},
    req :: binary(),
    req_msg :: map(),
    resp :: {ok, binary()} | {error, {integer(), binary()}},
    resp_msg :: map(),
    time :: nklib_util:timestamp()
}).


-record(state, {
    proxy :: pid(),
    pass :: binary(),
    remote :: binary(),
    trans = #{} :: #{{client|server, integer()} => #trans{}},
    bw_in = 0 :: integer(),
    bw_out = 0 :: integer(),
    bw_time = 0 :: integer()
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
    {ok, _SrvId, #{proxy:=Pid, pass:=Pass}} = nkpacket:get_user(NkPort),
    State = #state{remote=Remote, proxy=Pid, pass=Pass},
    ?LLOG(notice, "new connection (~p)", [self()], State),
    nklib_proc:put(?MODULE),
    self() ! check_old_trans,
    {ok, State}.


%% @private
-spec conn_parse(term()|close, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_parse(close, _NkPort, State) ->
    {ok, State};

%% Messages received from FS
conn_parse({text, <<"#S", _/binary>>=Msg}, _NkPort, State) ->
    State1 = case Msg of
        <<"#SPU", _/binary>> ->
            lager:notice("FS BW REPLY1: ~s", [Msg]),
            State#state{bw_out=0, bw_time=nklib_util:l_timestamp()};
        <<"#SPB", _/binary>> -> 
            Size = byte_size(Msg),
            Out = State#state.bw_out +  Size,
            State#state{bw_out=Out};
        <<"#SPD", _/binary>> ->
            #state{bw_out=Out, bw_time=Time} = State,
            Diff = (nklib_util:l_timestamp() - Time) div 10000,
            lager:notice("FS BW REPLY2: ~s (~p, ~p)", [Msg, Out, Diff]),
            State#state{bw_out=0, bw_time=0}
    end,
    send_event(Msg, State1),
    {ok, State1};

conn_parse({text, Data}, _NkPort, State) ->
    Msg = nklib_json:decode(Data),
    case Msg of
        error -> 
            ?LLOG(warning, "JSON decode error: ~p", [Data], State),
            error(json_decode);
        _ ->
            ok
    end,
    % ?LLOG(notice, ("TEXT:\n~s", [nklib_json:encode_pretty(Data)]),
    send_event(Msg, State),
    {ok, update_server(Msg, State)}.


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

conn_handle_cast({send, <<"#S", _/binary>>=Msg}, NkPort, State) ->
    State1 = case Msg of
        <<"#SPU ", BytesBin/binary>> ->
            Bytes = nklib_util:to_integer(BytesBin),
            lager:notice("Client start BW test (SPU, ~p)", [Bytes]),
            State#state{bw_in=0, bw_time=nklib_util:l_timestamp()};
        <<"#SPE">> ->
            #state{bw_in=Bytes, bw_time=Start} = State,
            Len = (nklib_util:l_timestamp() - Start) div 1000,
            lager:notice("Client stops BW test (SPE, ~p, ~p)", [Bytes, Len]),
            State;
        <<"#SPB", _/binary>> -> 
            Size = byte_size(Msg),
            In = State#state.bw_in +  Size - 4,
            State#state{bw_in=In}
    end,
    case nkpacket_connection:send(NkPort, Msg) of
        ok -> {ok, State1};
        {error, Error} -> {stop, Error, State1}
    end;

conn_handle_cast({send, Msg}, NkPort, State) ->
    Msg1 = update_password(Msg, State),
    case nkpacket_connection:send(NkPort, Msg1) of
        ok -> 
            {ok, update_client(Msg1, State)};
        {error, Error} -> 
            {stop, Error, State}
    end;

conn_handle_cast(Msg, _NkPort, State) ->
    lager:error("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {ok, State}.


%% @private
-spec conn_handle_info(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_handle_info(check_old_trans, _NkPort, #state{trans=AllTrans}=State) ->
    Now = nklib_util:timestamp(),
    AllTrans1 = check_old_trans(Now, maps:to_list(AllTrans), []),
    erlang:send_after(?CHECK_TIME, self(), check_old_trans),
    {ok, State#state{trans=AllTrans1}};

conn_handle_info(Msg, _NkPort, State) ->
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
    {ok, State}.




%% ===================================================================
%% Util
%% ===================================================================


%% @private Process a client message
-spec update_client(map(), #state{}) ->
    #state{}.

update_client(Msg, #state{trans=AllTrans}=State) ->
    case nkmedia_fs_verto:parse_class(Msg) of
        {{req, Method}, Id} ->
            % Client is sending a request to the server
            false = maps:is_key({client, Id}, AllTrans),
            Trans = #trans{
                req = Method, 
                req_msg = Msg, 
                time = nklib_util:timestamp()
            },
            State#state{trans=maps:put({client, Id}, Trans, AllTrans)};
        {{resp, Result}, Id} ->
            % Client is responding a request from the server
            case maps:find({server, Id}, AllTrans) of
                {ok, Trans} ->
                    Trans1 = Trans#trans{resp=Result, resp_msg=Msg},
                    print_req(server, Trans1),
                    State#state{trans=maps:remove({server, Id}, AllTrans)};
                error ->
                    ?LLOG(warning, "unexpected verto msg: ~p", [Msg], State),
                    State
            end;
        event ->
            ?LLOG(notice, "Event from Client", [], State),
            State;
        unknown ->
            ?LLOG(warning, "unknown verto message: ~p", [Msg], State),
            State
    end.


%% @private Process a server message
-spec update_server(map(), #state{}) ->
    #state{}.

update_server(Msg, #state{trans=AllTrans}=State) ->
    case nkmedia_fs_verto:parse_class(Msg) of
        {{req, Method}, Id} ->
            % Server is sending a request to the client
            false = maps:is_key({server, Id}, AllTrans),
            Trans = #trans{
                req = Method, 
                req_msg = Msg, 
                time = nklib_util:timestamp()
            },
            State#state{trans=maps:put({server, Id}, Trans, AllTrans)};
        {{resp, Resp}, Id} ->
            % Server is responding a request from the client
            case maps:find({client, Id}, AllTrans) of
                {ok, Trans} ->
                    Trans1 = Trans#trans{resp=Resp, resp_msg=Msg},
                    print_req(client, Trans1),
                    State#state{trans=maps:remove({client, Id}, AllTrans)};
                error ->
                    ?LLOG(warning, "unexpected verto msg: ~p", [Msg], State),
                    State
            end;
        event ->
            % ?LLOG(notice, ("Event from Server"),
            State;
        unknown ->
            ?LLOG(warning, "unknown verto message: ~p", [Msg], State),
            State
    end.


%% @private
-spec send_event(binary()|map(), #state{}) ->
    ok.

send_event(Msg, #state{proxy=Pid}) ->
    ok = gen_server:call(Pid, {nkmedia_fs_verto, self(), Msg}).
    % Pid ! {nkmedia_fs_verto, self(), Msg},
    % ok.



%% @private
check_old_trans(_Now, [], Acc) ->
    maps:from_list(Acc);

check_old_trans(Now, [{{Type, Id}, #trans{time=Time}=Trans}|Rest], Acc) ->
    Acc1 = case Now - Time > (?MAX_REQ_TIME div 1000) of
        true ->
            lager:warning("NkMEDIA verto removing old request: ~p", [Trans]),
            Acc;
        false ->
            [{{Type, Id}, Trans}|Acc]
    end,
    check_old_trans(Now, Rest, Acc1).


%% @private
update_password(Msg, #state{pass=Pass}) ->
    case Msg of
        #{
            <<"method">> := <<"login">>,
            <<"params">> := #{<<"passwd">>:=_}=Params1
        } ->
            Params2 = Params1#{<<"passwd">>:=Pass},
            Msg#{<<"params">>:=Params2};
        _ ->
            Msg
    end.


%% @private
print_req(Class, #trans{req=Req, resp=Resp}=Trans) ->
    lager:info("Req from ~p: ~s -> ~p", [Class, Req, Resp]),
    case Req of
        <<"login">> -> 
            ok;
        _ ->
            #trans{req_msg=Msg1, resp_msg=Msg2} = Trans,
            lager:info("~s -> \n~s\n\n", 
                        [nklib_json:encode_pretty(Msg1), nklib_json:encode_pretty(Msg2)])
    end.
        






