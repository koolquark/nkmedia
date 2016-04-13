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

-module(nkmedia_session).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start_link/0, start_link/1]).
-export([call/3, update_config/2, put_in_ms/2]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Session ~s (~p) "++Txt, 
               [State#state.id, State#state.status | Args])).

-define(DEF_WAIT_TIMEOUT, 30).

-callback nkmedia_session_init(id(), config()) ->
    {ok, config()}.

-callback nkmedia_session_update(id(), config()) ->
    {ok, config()}.

-callback nkmedia_session_terminate(Reason::term(), config()) ->
    {ok, config()}.

-callback nkmedia_session_status(status(), config()) ->
    {ok, config()}.

-callback nkmedia_session_handle_call(term(), {pid(), term()}, config()) ->
    nklib_gen_server:reply().

-callback nkmedia_session_handle_cast(term(), config()) ->
    nklib_gen_server:noreply().

-callback nkmedia_session_handle_info(term(), config()) ->
    nklib_gen_server:noreply().

-callback nkmedia_session_code_change(term()|{down, term()}, tuple(), term()) ->
    {ok, config()} | {error, term()}.



%% ===================================================================
%% Types
%% ===================================================================


-type id() :: 
    term().


-type config() :: 
    #{
        srv_id => nkservice:id(),
        monitor => pid(),
        type => inbound | outbound,
        % role => caller | callee,
        sdp_a => binary(),
        sdp_b => binary(),
        call => call_dest(),                        % Call to this
        wait_timeout => integer(),                  % Secs

        id => id(),                     % Non user-modificable values
        answered => true,
        peer => {sessid, id()}

    }.

-type status() ::
    init | wait | {route, term()} | {call, term()} | ringing.


-type call_dest() ::
    {room, binary()} | {sip, Url::binary(), Opts::list()}.

-type mediaserver() ::
    {fs, Name::binary()}.


%% ===================================================================
%% Public
%% ===================================================================


start_link() ->
    start_link(#{}).


start_link(Config) ->
    Config2 = case Config of
        #{id:=SessId} -> 
            Config;
        _ -> 
            Config#{id=>SessId=make_id()}
    end,
    {ok, Pid} = gen_server:start_link(?MODULE, [Config2], []),
    {ok, Pid, SessId}.


-spec call(id(), call_dest(), config()) ->
    {ok, id()} | {error, term()}.

call(SessId, CallDest, Config) ->
    do_call(SessId, {call, CallDest, Config}).


%% @doc Updates user configurable parameters
-spec update_config(id(), config()) ->
    ok | {error, term()}.

update_config(SessId, Config) ->
    do_call(SessId, {update_config, Config}).


-spec put_in_ms(id(), mediaserver()) ->
    ok | {error, term()}.

put_in_ms(SessId, MS) ->
    do_call(SessId, {put_in_ms, MS}).



%% ===================================================================
%% Internal
%% ===================================================================




% ===================================================================
%% gen_server behaviour
%% ===================================================================


-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    config = #{} :: config(),
    user_mon :: reference(),
    status :: status(),
    timer :: reference(),
    ms :: {module(), term()},
    calls = [] :: [{id(), pid(), reference()}]
}).



%% @private
-spec init(term()) ->
    {ok, tuple()}.

init([#{id:=Id}=Config]) ->
    SrvId = maps:get(service, Config, nkmedia_callbacks),
    Mon = case maps:find(monitor, Config) of
        {ok, Pid} -> monitor:process(Pid);
        error -> undefined
    end,
    case erlang:function_exported(SrvId, nkmedia_session_init, 2) of
        true ->
            {ok, Config2} = SrvId:nkmedia_session_init(Id, Config);
        false ->
            Config2 = Config
    end,
    State = #state{
        id = Id, 
        srv_id = SrvId, 
        user_mon = Mon,
        config = Config2,
        status = init
    },
    lager:notice("NkMEDIA Session ~s starting (~p)", [Id, self()]),
    {ok, update_status(wait, State)}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call({call, Dest, CallConfig}, From, #state{config=Config}=State) ->
    case Config of
        #{answered:=true} ->
            case Config of
                #{call_fail_if_answered:=false} ->
                    {NewId, State2} = make_call(Dest, CallConfig, State),
                    gen_server:reply(From, {ok, NewId}),
                    {noreply, State2};
                _ ->
                    {reply, {error, already_answered}, State}
            end;
        _ ->
            {NewId, State2} = make_call(Dest, CallConfig, State),
            gen_server:reply(From, {ok, NewId}),
            {noreply, State2}
    end;

handle_call({update_config, NewConfig}, _From, #state{config=Config}=State) ->
    State2 = State#state{config=maps:merge(Config, NewConfig)},
    case 
        nklib_gen_server:handle_any(nkmedia_session_update_config, [], State2,
                                    #state.srv_id, #state.config)
    of
        nklib_not_exported -> {reply, ok, State2};
        {ok, Config2} -> {reply, ok, State#state{config=Config2}}
    end;

handle_call(Msg, From, State) -> 
    nklib_gen_server:handle_call(nkmedia_session_handle_cast, Msg, From, State,
                                 #state.srv_id, #state.config).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast(Msg, State) -> 
    nklib_gen_server:handle_cast(nkmedia_session_handle_cast, Msg, State,
                                 #state.srv_id, #state.config).


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({timeout, _, status_timeout}, State) ->
    ?LLOG(warning, "status timeout", [], State),
    {stop, normal, State};

handle_info({'DOWN', Ref, process, _Pid, Reason}, #state{user_mon=Ref}=State) ->
    ?LLOG(warning, "caller process stopped: ~p", [Reason], State),
    {stop, Reason, State};

handle_info({'DOWN', Ref, process, CallPid, Reason}=Msg, #state{calls=Calls}=State) ->
    case lists:keyfind(Ref, 3, Calls) of
        {CallId, CallPid, Ref} ->
            ?LLOG(notice, "call ~s down! (~p)", [CallId, Reason], State),
            Calls2 = lists:keydelete(Ref, 3, Calls),
            {noreply, State#state{calls=Calls2}};
        error ->
            handle(nkmedia_session_handle_info, [Msg], State)
    end;

handle_info(Msg, State) ->
    nklib_gen_server:handle_info(nkmedia_session_handle_info, Msg, State,
                                 #state.srv_id, #state.config).


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(OldVsn, State, Extra) ->
    nklib_gen_server:code_change(nkmedia_session_code_change, 
                                 OldVsn, State, Extra, 
                                 #state.srv_id, #state.config).

%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(Reason, State) ->
    catch nklib_gen_server:terminate(nkmedia_session_terminate, Reason, State,
                                     #state.srv_id, #state.config),
    ?LLOG(info, "stopped (~p)", [Reason], State).


% ===================================================================
%% Internal
%% ===================================================================


%% @private
make_call(Dest, CallConfig, #state{config=Config, calls=Calls}=State) ->
    CallId = make_id(),
    CallConfig2 = CallConfig#{
        id => CallId,
        type => outbound,
        call => Dest,
        monitor => self()
    },
    {ok, CallPid} = start_link(CallConfig2),
    Mon = monitor(process, CallPid),
    Calls2 = [{CallId, CallPid, Mon}|Calls],
    State2 = State#state{config=Config#{role=>caller}, calls=Calls2},
    {CallId, update_status(calling, State2)}.


%% @private
make_id() ->
    nklib_util:uid().


%% @private
update_status(Status, #state{status=Status}=State) ->
    State;

update_status(NewStatus, #state{status=OldStatus}=State) ->
    State2 = restart_timer(NewStatus, State),
    ?LLOG(info, "status ~p -> ~p", [OldStatus, NewStatus], State),
    {ok, State3} = handle(nkmedia_session_status, [NewStatus], State2),
    State3.


%% @private
restart_timer(Status, #state{timer=Timer, config=Config}=State) ->
    nklib_util:cancel_timer(Timer),
    Time = case Status of
        wait -> maps:get(wait_timeout, Config, ?DEF_WAIT_TIMEOUT)
    end,
    NewTimer = erlang:start_timer(1000*Time, self(), status_timeout),
    State#state{timer=NewTimer, status=Status}.


%% @private
handle(Fun, Args, State) ->
    case nklib_gen_server:handle_any(Fun, Args, State, #state.srv_id, #state.config) of
        nklib_not_exported ->
            {ok, State};
        Other ->
            Other
    end.


%% @private
find(Pid) when is_pid(Pid) ->
    {ok, Pid};

find(SessId) ->
    case nklib_proc:values({?MODULE, SessId}) of
        [{undefined, Pid}] -> {ok, Pid};
        [] -> not_found
    end.


%% @private
do_call(SessId, Msg) ->
    do_call(SessId, Msg, 5000).


%% @private
do_call(SessId, Msg, Timeout) ->
    case find(SessId) of
        {ok, Pid} -> nklib_util:call(Pid, Msg, Timeout);
        not_found -> {error, session_not_found}
    end.


