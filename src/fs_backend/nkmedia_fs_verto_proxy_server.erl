
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
-module(nkmedia_fs_verto_proxy_server).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([get_all/0, send_reply/2]).
-export([transports/1, default_port/1]).
-export([conn_init/1, conn_encode/2, conn_parse/3, conn_stop/3,
         conn_handle_call/4, conn_handle_cast/3, conn_handle_info/3]).


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA VERTO Proxy Server (~s) "++Txt, [State#state.remote | Args])).



%% ===================================================================
%% Types
%% ===================================================================

-type user_state() :: nkmedia_fs_verto_proxy:state().


%% ===================================================================
%% Public
%% ===================================================================

get_all() ->
    [{Local, Remote} || {Remote, Local} <- nklib_proc:values(?MODULE)].


send_reply(Pid, Event) ->
    gen_server:call(Pid, {send_reply, Event}).



%% ===================================================================
%% Protocol callbacks
%% ===================================================================


-record(state, {
    srv_id :: nkservice:id(),
    remote :: binary(),
    proxy :: pid(),
    user_state :: user_state()
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
    {ok, {_, SrvId}, _} = nkpacket:get_user(NkPort),
    {ok, Remote} = nkpacket:get_remote_bin(NkPort),
    State = #state{srv_id=SrvId, remote=Remote},
    ?LLOG(notice, "new connection (~p)", [self()], State),
    {ok, State2} = handle(nkmedia_fs_verto_proxy_init, [NkPort], State),
    {ok, List, State3} = handle(nkmedia_fs_verto_proxy_find_fs, [SrvId], State2),
    connect(List, State3).

  
%% @private
-spec conn_parse(term()|close, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_parse(close, _NkPort, State) ->
    {ok, State};

conn_parse({text, <<"#S", _/binary>>=Msg}, _NkPort, #state{proxy=Pid}=State) ->
    nkmedia_fs_verto_proxy_client:send(Pid, Msg),
    {ok, State};

conn_parse({text, Data}, _NkPort, #state{proxy=Pid}=State) ->
    Msg = case nklib_json:decode(Data) of
        error ->
            ?LLOG(warning, "JSON decode error: ~p", [Data], State),
            error(json_decode);
        Json ->
            Json
    end,
    % ?LLOG(info, "received\n~s", [nklib_json:encode_pretty(Msg)], State),
    case handle(nkmedia_fs_verto_proxy_in, [Msg], State) of
        {ok, Msg2, State2} ->
            ok = nkmedia_fs_verto_proxy_client:send(Pid, Msg2),
            {ok, State2};
        {stop, Reason, State2} ->
            {stop, Reason, State2}
    end.

%% @private
-spec conn_encode(term(), nkpacket:nkport()) ->
    {ok, nkpacket:outcoming()} | continue | {error, term()}.

conn_encode(Msg, _NkPort) when is_map(Msg) ->
    Json = nklib_json:encode(Msg),
    {ok, {text, Json}};

conn_encode(Msg, _NkPort) when is_binary(Msg) ->
    {ok, {text, Msg}}.


%% @doc Called when the connection received an erlang message
-spec conn_handle_call(term(), term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_call({send_reply, Event}, From, NkPort, State) ->
    % ?LLOG(info, "sending\n~s", [nklib_json:encode_pretty(Event)], State),
    case handle(nkmedia_fs_verto_proxy_out, [Event], State) of
        {ok, Event2, State2} ->
            case nkpacket_connection:send(NkPort, Event2) of
                ok -> 
                    gen_server:reply(From, ok),
                    {ok, State2};
                {error, Error} -> 
                    gen_server:reply(From, error),
                    ?LLOG(notice, "error sending event: ~p", [Error], State),
                    {stop, normal, State2}
            end;
        {stop, Reason, State2} ->
            {stop, Reason, State2}
    end;

conn_handle_call(Msg, From, _NkPort, State) ->
    handle(nkmedia_fs_verto_proxy_handle_call, [Msg, From], State).


-spec conn_handle_cast(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_cast(Msg, _NkPort, State) ->
    handle(nkmedia_fs_verto_proxy_handle_cast, [Msg], State).


%% @doc Called when the connection received an erlang message
-spec conn_handle_info(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_info({'DOWN', _Ref, process, Pid, Reason}, _NkPort, 
                 #state{proxy=Pid}=State) ->
    ?LLOG(notice, "stopped because server stopped (~p)", [Reason], State),
    {stop, normal, State};

conn_handle_info(Msg, _NkPort, State) ->
    handle(nkmedia_fs_verto_proxy_handle_info, [Msg], State).


%% @doc Called when the connection stops
-spec conn_stop(Reason::term(), nkpacket:nkport(), #state{}) ->
    ok.

conn_stop(Reason, _NkPort, State) ->
    catch handle(nkmedia_fs_verto_proxy_terminate, [Reason], State).




%% ===================================================================
%% Internal
%% ===================================================================

%% @private
handle(Fun, Args, State) ->
    nklib_gen_server:handle_any(Fun, Args, State, #state.srv_id, #state.user_state).
    

%% @private
connect([], _State) ->
    {stop, no_fs_available};

connect([Name|Rest], State) ->
    case nkmedia_fs_verto_proxy_client:start(Name) of
        {ok, ProxyPid} ->
            ?LLOG(info, "connected to Freeswitch server ~s", [Name], State),
            monitor(process, ProxyPid),
            nklib_proc:put(?MODULE, {proxy_client, ProxyPid}),
            {ok, State#state{proxy=ProxyPid}};
        {error, Error} ->
            ?LLOG(warning, "could not start proxy to ~s: ~p", 
                  [Name, Error], State),
            connect(Rest, State)
    end.



