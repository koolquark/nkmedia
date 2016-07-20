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

%% @doc Session Management


-module(nkmedia_session).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start/3, get_type/1, get_session/1, get_offer/1, get_answer/1]).
-export([stop/1, stop/2, stop_all/0]).
-export([answer/2, answer_async/2, update/3, update_async/3, info/2]).
-export([register/2, unregister/2, link_session/3, get_all/0,  peer_event/3]).
-export([get_call_data/1, send_ext_event/3]).
-export([find/1, do_cast/2, do_call/2, do_call/3]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, config/0, session/0, event/0]).

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Session ~s (~p) "++Txt, 
               [State#state.id, State#state.type | Args])).

-include("nkmedia.hrl").
-include_lib("nklib/include/nklib.hrl").
-include_lib("nkservice/include/nkservice.hrl").


%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().


%% Backend plugins expand the available types
-type type() :: p2p | term().


%% Backend plugins expand the available types
-type update() :: term().



-type config() :: 
    #{
        id => id(),                             % Generated if not included
        wait_timeout => integer(),              % Secs
        ready_timeout => integer(),
        backend => nkemdia:backend(),
        register => nklib:proc_id(),
        term() => term()                        % Plugin data
    }.




-type session() ::
    config () | 
    #{
        srv_id => nkservice:id(),
        type => type()
    }.



-type event() ::
    {answer, nkmedia:answer()}          |   % Answer SDP is available
    {updated_type, atom()}             |
    {info, binary()}                      |   % User info
    {stop, nkservice:error()}           |   % Session is about to hangup
    {linked_down, id(), caller|callee, Reason::term()}.



%% ===================================================================
%% Public
%% ===================================================================

%% @private
-spec start(nkservice:id(), type(), config()) ->
    {ok, id(), pid(), Reply::map()} | {error, nkservice:error()}.

start(Srv, Type, Config) ->
    case nkservice_srv:get_srv_id(Srv) of
        {ok, SrvId} ->
            Config2 = Config#{type=>Type, srv_id=>SrvId},
            {SessId, Config3} = nkmedia_util:add_uuid(Config2),
            {ok, SessPid} = gen_server:start(?MODULE, [Config3], []),
            case gen_server:call(SessPid, do_start) of
                {ok, Reply} ->
                    {ok, SessId, SessPid, Reply};
                {error, Error} ->
                    {error, Error}
            end;
        not_found ->
            {error, service_not_found}
    end.


%% @doc Get current session data
-spec get_session(id()) ->
    {ok, session()} | {error, nkservice:error()}.

get_session(SessId) ->
    do_call(SessId, get_session).


%% @doc Get current session offer
-spec get_offer(id()) ->
    {ok, nkmedia:offer()} | {error, nkservice:error()}.

get_offer(SessId) ->
    do_call(SessId, get_offer).


%% @doc Get current session answer
-spec get_answer(id()) ->
    {ok, nkmedia:answer()} | {error, nkservice:error()}.

get_answer(SessId) ->
    do_call(SessId, get_answer).


%% @doc Get current status and remaining time to timeout
-spec get_type(id()) ->
    {ok, map(), integer()}.

get_type(SessId) ->
    do_call(SessId, get_type).


%% @doc Hangups the session
-spec stop(id()) ->
    ok | {error, nkservice:error()}.

stop(SessId) ->
    stop(SessId, user_stop).


%% @doc Hangups the session
-spec stop(id(), nkservice:error()) ->
    ok | {error, nkservice:error()}.

stop(SessId, Reason) ->
    do_cast(SessId, {stop, Reason}).


%% @private Hangups all sessions
stop_all() ->
    lists:foreach(fun({SessId, _Pid}) -> stop(SessId) end, get_all()).


%% @doc Sets the session's current answer operation.
%% See each operation's doc for returned info
%% Some backends my support updating answer (like Freeswitch)
-spec answer(id(), nkmedia:answer()) ->
    {ok, map()} | {error, nkservice:error()}.

answer(SessId, Answer) ->
    do_call(SessId, {answer, Answer}).


%% @doc Equivalent to answer/3, but does not wait for operation's result
-spec answer_async(id(), nkmedia:answer()) ->
    ok | {error, nkservice:error()}.

answer_async(SessId, Answer) ->
    do_cast(SessId, {answer, Answer}).


%% @doc Sets the session's current answer operation.
%% See each operation's doc for returned info
%% Some backends my support updating answer (like Freeswitch)
-spec update(id(), update(), Opts::map()) ->
    ok | {error, nkservice:error()}.

update(SessId, Update, Opts) ->
    do_call(SessId, {update, Update, Opts}).


%% @doc Equivalent to update/3, but does not wait for operation's result
-spec update_async(id(), update(), Opts::map()) ->
    ok | {error, nkservice:error()}.

update_async(SessId, Update, Opts) ->
    do_cast(SessId, {update, Update, Opts}).


%% @doc Hangups the session
-spec info(id(), binary()) ->
    ok | {error, nkservice:error()}.

info(SessId, Info) ->
    do_cast(SessId, {info, nklib_util:to_binary(Info)}).


%% @doc Links this session to another
%% If the other session fails, an event will be generated
-spec link_session(id(), id(), #{send_events=>boolean()}) ->
    ok | {error, nkservice:error()}.

link_session(SessId, SessIdB, Opts) ->
    do_call(SessId, {link_session, SessIdB, Opts}).


%% @doc Registers a process with the session
-spec register(id(), nklib:proc_id()) ->
    {ok, pid()} | {error, nkservice:error()}.

register(SessId, ProcId) ->
    do_call(SessId, {register, ProcId}).


%% @doc Registers a process with the session
-spec unregister(id(), nklib:proc_id()) ->
    ok | {error, nkservice:error()}.

unregister(SessId, ProcId) ->
    do_call(SessId, {unregister, ProcId}).


%% @doc Sends a event inside the session
-spec send_ext_event(id(), atom(), map()) ->
    ok | {error, term()}.

send_ext_event(SessId, Type, Body) ->
    do_cast(SessId, {send_ext_event, Type, Body}).


%% @private
-spec get_all() ->
    [{id(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).


%% @private
-spec get_call_data(id()) ->
    {ok, nkservice:id(), nkmedia:offer(), pid()} | {error, term()}.

get_call_data(SessId) ->
    do_call(SessId, get_call_data).





%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec peer_event(id(), id(), event()) ->
    ok | {error, nkservice:error()}.

peer_event(Id, IdB, Event) ->
    do_cast(Id, {peer_event, IdB, Event}).


% ===================================================================
%% gen_server behaviour
%% ===================================================================

-type link_id() ::
    {reg, nklib:proc_id()} | {peer, id()}.

-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    type :: type(),
    has_answer = false :: boolean(),
    links :: nklib_links:links(link_id()),
    timer :: reference(),
    stop_sent = false :: boolean(),
    hibernate = false :: boolean(),
    session :: session()
}).


%% @private
-spec init(term()) ->
    {ok, #state{}} | {error, term()}.

init([#{id:=Id, type:=Type, srv_id:=SrvId}=Session]) ->
    true = nklib_proc:reg({?MODULE, Id}),
    nklib_proc:put(?MODULE, Id),
    State1 = #state{
        id = Id, 
        srv_id = SrvId, 
        type = Type,
        links = nklib_links:new(),
        session = Session
    },
    State2 = case Session of
        #{register:=ProcId} -> 
            ProcPid = nklib_links:get_pid(ProcId),            
            links_add({reg, ProcId}, none, ProcPid, State1);
        _ ->
            State1
    end,
    lager:info("NkMEDIA Session ~s starting (~p)", [Id, self()]),
    handle(nkmedia_session_init, [Id], restart_timer(State2)).
        

%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(do_start, From, State) ->
    do_start(From, State);

handle_call(get_session, _From, #state{session=Session}=State) ->
    reply({ok, Session}, State);

handle_call(get_type, _From, #state{type=Type, timer=Timer}=State) ->
    reply({ok, Type, erlang:read_timer(Timer) div 1000}, State);

handle_call({answer, Answer}, From, State) ->
    do_set_answer(Answer, From, State);

handle_call({update, Update, Opts}, From, State) ->
    do_update(Update, Opts, From, State);

handle_call(get_state, _From, State) -> 
    reply(State, State);

handle_call(get_offer, _From, #state{session=#{offer:=Offer}}=State) -> 
    reply({ok, Offer}, State);

handle_call(get_answer, _From, #state{session=Session}=State) -> 
    Reply = case maps:find(answer, Session) of
        {ok, Answer} -> {ok, Answer};
        error -> {error, answer_not_set}
    end,
    reply(Reply, State);

handle_call(get_call_data, _From, #state{srv_id=SrvId, session=Session}=State) -> 
    #{offer:=Offer} = Session,
    reply({ok, SrvId, Offer, self()}, State);

handle_call({link_session, IdA, Opts}, _From, #state{id=IdB}=State) ->
    case find(IdA) of
        {ok, Pid} ->
            Events = maps:get(send_events, Opts, false),
            ?LLOG(info, "linked to ~s (events:~p)", [IdA, Events], State),
            gen_server:cast(Pid, {link_session_back, IdB, self(), Events}),
            State2 = links_add({peer, IdA}, {caller, Events}, Pid, State),
            reply(ok, State2);
        not_found ->
            ?LLOG(warning, "trying to link unknown session ~s", [IdB], State),
            do_stop(unknown_linked_session, State)
    end;

handle_call({register, ProcId}, _From, State) ->
    ?LLOG(info, "proc registered (~p)", [ProcId], State),
    Pid = nklib_links:get_pid(ProcId),
    State2 = links_add({reg, ProcId}, none, Pid, State),
    reply({ok, self()}, State2);

handle_call({unregister, ProcId}, _From, State) ->
    ?LLOG(info, "proc unregistered (~p)", [ProcId], State),
    State2 = links_remove({reg, ProcId}, State),
    reply(ok, State2);

handle_call(Msg, From, State) -> 
    handle(nkmedia_session_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({answer, Answer}, State) ->
    do_set_answer(Answer, undefined, State);

handle_cast({update, Update, Opts}, State) ->
    do_update(Update, Opts, undefined, State);

handle_cast({info, Info}, State) ->
    noreply(event({info, Info}, State));

handle_cast({link_session_back, IdB, Pid, Events}, State) ->
    ?LLOG(info, "linked back from ~s (events:~p)", [IdB, Events], State),
    State2 = links_add({peer, IdB}, {callee, Events}, Pid, State),
    noreply(State2);

handle_cast({peer_event, PeerId, Event}, State) ->
    case links_get({peer, PeerId}, State) of
        {ok, {Type, true}} ->
            {ok, State2} = 
                handle(nkmedia_session_peer_event, [PeerId, Type, Event], State),
            noreply(State2);
        _ ->            
            noreply(State)
    end;

handle_cast({send_ext_event, EvType, Body}, State) ->
    do_send_ext_event(EvType, Body, State),
    noreply(State);

handle_cast({stop, Error}, State) ->
    do_stop(Error, State);

handle_cast(Msg, State) -> 
    handle(nkmedia_session_handle_cast, [Msg], State).


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({timeout, _, session_timeout}, State) ->
    ?LLOG(info, "operation timeout", [], State),
    do_stop(session_timeout, State);

handle_info({'DOWN', _Ref, process, Pid, Reason}=Msg, State) ->
    case links_down(Pid, State) of
        {ok, Id, Data, State2} ->
            case Reason of
                normal ->
                    ?LLOG(info, "linked ~p down (normal)", [Id], State);
                _ ->
                    ?LLOG(notice, "linked ~p down (~p)", [Id, Reason], State)
            end,
            case Id of
                {reg, _Term} ->
                    do_stop(registered_stop, State2);
                {peer, IdB} ->
                    {Type, _Events} = Data,  % caller | callee
                    event({linked_down, IdB, Type, Reason}, State),
                    noreply(State2)
            end;
        not_found ->
            handle(nkmedia_session_handle_info, [Msg], State)
    end;
    
handle_info(Msg, State) -> 
    handle(nkmedia_session_handle_info, [Msg], State).


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(OldVsn, State, Extra) ->
    nklib_gen_server:code_change(nkmedia_session_code_change, 
                                 OldVsn, State, Extra, 
                                 #state.srv_id, #state.session).

%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(Reason, State) ->
    case Reason of
        normal ->
            ?LLOG(info, "terminate: ~p", [Reason], State),
            _ = do_stop(normal, State);
        _ ->
            ?LLOG(notice, "terminate: ~p", [Reason], State),
            _ = do_stop(anormal, State)
    end,
    {ok, _State2} = handle(nkmedia_session_terminate, [Reason], State).




%% ===================================================================
%% Internal
%% ===================================================================


%% @private
do_start(From, #state{type=Type}=State) ->
    case handle(nkmedia_session_start, [Type], State) of
        {ok, Type2, Reply, #state{session=Session2}=State2} ->
            case Session2 of
                #{offer:=#{sdp:=_}} ->
                    HasAnswer = case Session2 of
                        #{answer:=#{sdp:=_}} -> true;
                        _ -> false
                    end,
                    State3 = State2#state{has_answer=HasAnswer},
                    do_start_ok(Type2, Reply, From, State3);
                _ ->
                    do_start_error(missing_offer, From, State2)
            end;
        {error, Error, State2} ->
            do_start_error(Error, From, State2)
    end.


%% @private
do_start_ok(Type, Reply, From, State) ->
    State2 = restart_timer(update_type(Type, State)),
    ?LLOG(info, "started ok", [], State2),
    reply({ok, Reply}, From, State2).


%% @private
do_start_error(Error, From, State) ->
    stop(self(), invalid_parameters),
    reply({error, Error}, From, State).


%% @private
do_set_answer(_Answer, From, #state{has_answer=true}=State) ->
    reply({error, answer_already_set}, From, State);

do_set_answer(Answer, From, #state{type=Type}=State) ->
    case handle(nkmedia_session_answer, [Type, Answer], State) of
        {ok, Reply, #{sdp:=_}=Answer2, State2} ->
            State3 = update_session(answer, Answer2, State2),
            State4 = restart_timer(State3#state{has_answer=true}),
            State5 = event({answer, Answer2}, State4),
            ?LLOG(info, "answer set", [], State),
            reply({ok, Reply}, From, State5);
        {ok, _Reply, _Answer, State2} ->
            reply({error, invalid_answer}, From, State2);
        {error, Error, State2} ->
            reply({error, Error}, From, State2)
    end.


%% @private
do_update(Update, Opts, From, #state{type=Type, has_answer=true}=State) ->
    case handle(nkmedia_session_update, [Update, Opts, Type], State) of
        {ok, Type2, Reply, State2} ->
            State3 = update_type(Type2, State2),
            ?LLOG(info, "session updated", [], State3),
           reply({ok, Reply}, From, State3);
        {error, Error, State2} ->
            reply({error, Error}, From, State2)
    end;

do_update(_Update, _Opts, From, State) ->
    reply({error, answer_not_set}, From, State).




%% ===================================================================
%% Util
%% ===================================================================


%% @private
update_type(Type, #state{type=Type}=State) ->
    State;

update_type(Type, State) ->
    State2 = update_session(type, Type, State),
    event({updated_type, Type}, State2#state{type=Type}).


%% @private
restart_timer(State) ->
    #state{
        timer = Timer, 
        session = Session, 
        has_answer = HasAnswer
    } = State,
    nklib_util:cancel_timer(Timer),
    Time = case HasAnswer of
        true -> maps:get(ready_timeout, Session, ?DEF_READY_TIMEOUT);
        false -> maps:get(wait_timeout, Session, ?DEF_WAIT_TIMEOUT)
    end,
    NewTimer = erlang:start_timer(1000*Time, self(), session_timeout),
    State#state{timer=NewTimer}.


%% @private
reply(Reply, #state{hibernate=true}=State) ->
    {reply, Reply, State#state{hibernate=false}, hibernate};
reply(Reply, State) ->
    {reply, Reply, State}.


%% @private
reply(Reply, From, State) ->
    nklib_util:reply(From, Reply),
    noreply(State).


%% @private
noreply(#state{hibernate=true}=State) ->
    {noreply, State#state{hibernate=false}, hibernate};
noreply(State) ->
    {noreply, State}.


%% @private
do_stop(_Reason, #state{stop_sent=true}=State) ->
    {stop, normal, State};

do_stop(Reason, State) ->
    {ok, State2} = handle(nkmedia_session_stop, [Reason], State),
    State3 = event({stop, Reason}, State2#state{stop_sent=true}),
    % Allow events to be processed
    timer:sleep(100),
    {stop, normal, State3}.


%% @private
event(Event, #state{id=Id}=State) ->
    case Event of
        {answer, _} ->
            ?LLOG(info, "sending 'answer'", [], State);
        _ -> 
            ?LLOG(info, "sending 'event': ~p", [Event], State)
    end,
    links_iter(
        fun
            ({peer, PeerId}, {_Type, true}) -> 
                peer_event(PeerId, Id, Event);
            (_, _) ->
                ok
        end,
        State),
    State2 = links_fold(
        fun
            ({reg, Reg}, none, AccState) ->
                {ok, AccState2} = 
                    handle(nkmedia_session_reg_event, [Id, Reg, Event], AccState),
                    AccState2;
            (_, _, AccState) -> 
                AccState
        end,
        State,
        State),
    {ok, State3} = handle(nkmedia_session_event, [Id, Event], State2),
    ext_event(Event, State3).


%% @private
ext_event(Event, #state{srv_id=SrvId}=State) ->
    Send = case Event of
        {answer, Answer} ->
            {answer, #{answer=>Answer}};
        {info, Info} ->
            {info, #{info=>Info}};
        {updated_type, Type} ->
            {updated_type, #{type=>Type}};
        {stop, Reason} ->
            {Code, Txt} = SrvId:error_code(Reason),
            {stop, #{code=>Code, reason=>Txt}};
        _ ->
            ignore
    end,
    case Send of
        {EvType, Body} ->
            do_send_ext_event(EvType, Body, State);
        ignore ->
            ok
    end,
    State.


%% @private
do_send_ext_event(Type, Body, #state{srv_id=SrvId, id=SessId}=State) ->
    RegId = #reg_id{
        srv_id = SrvId,     
        class = <<"media">>, 
        subclass = <<"session">>,
        type = nklib_util:to_binary(Type),
        obj_id = SessId
    },
    ?LLOG(info, "ext event: ~p", [RegId], State),
    nkservice_events:send(RegId, Body).


%% @private
handle(Fun, Args, State) ->
    nklib_gen_server:handle_any(Fun, Args, State, #state.srv_id, #state.session).


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
    do_call(SessId, Msg, ?DEF_SYNC_TIMEOUT).


%% @private
do_call(SessId, Msg, Timeout) ->
    case find(SessId) of
        {ok, Pid} -> nkservice_util:call(Pid, Msg, Timeout);
        not_found -> {error, session_not_found}
    end.


%% @private
do_cast(SessId, Msg) ->
    case find(SessId) of
        {ok, Pid} -> gen_server:cast(Pid, Msg);
        not_found -> {error, session_not_found}
    end.


%% @private
update_session(Key, Val, #state{session=Session}=State) ->
    Session2 = maps:put(Key, Val, Session),
    State#state{session=Session2}.


%% @private
links_add(Id, Data, Pid, #state{links=Links}=State) ->
    State#state{links=nklib_links:add(Id, Data, Pid, Links)}.


%% @private
links_get(Id, #state{links=Links}) ->
    nklib_links:get(Id, Links).


%% @private
links_remove(Id, #state{links=Links}=State) ->
    State#state{links=nklib_links:remove(Id, Links)}.


%% @private
links_down(Pid, #state{links=Links}=State) ->
    case nklib_links:down(Pid, Links) of
        {ok, Id, Data, Links2} -> {ok, Id, Data, State#state{links=Links2}};
        not_found -> not_found
    end.


%% @private
links_iter(Fun, #state{links=Links}) ->
    nklib_links:iter(Fun, Links).


%% @private
links_fold(Fun, Acc, #state{links=Links}) ->
    nklib_links:fold(Fun, Acc, Links).






