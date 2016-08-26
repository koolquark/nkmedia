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
-export([answer/2, answer_async/2, client_candidate/2, server_candidate/2]).
-export([update/3, update_async/3, info/2]).
-export([register/2, unregister/2, link_slave/2, unlink_session/1]).
-export([get_all/0]).
-export([ext_ops/2, do_add/3, do_rm/2]).
-export([find/1, do_cast/2, do_call/2, do_call/3, do_info/2]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, config/0, session/0, event/0, type_ext/0, ext_ops/0]).

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Session ~s (~p) "++Txt, 
               [State#state.id, State#state.type | Args])).

-include("nkmedia.hrl").
-include_lib("nklib/include/nklib.hrl").
-include_lib("nkservice/include/nkservice.hrl").
-include_lib("nksip/include/nksip.hrl").

-define(MAX_ICE_TIME, 200).
-define(MAX_CALL_TIME, 5000).

%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().


%% Backend plugins expand the available types
-type type() :: p2p | atom().


%% Backend plugins expand the available types
-type update() :: term().


%% Session configuration
%% If we set a peer session, we will consider it 'master' and we are 'slave'
%% If one of them stops, the other will stop (see nkmedia_callbacks)
%% If the slave has an answer, it will send it back to the master
-type config() :: 
    #{
        session_id => id(),                         % Generated if not included
        peer_id => id(),                            % See above
        trickle_ice => boolean(),                   % Default false (candidates in SDP)
        wait_timeout => integer(),                  % Secs
        ready_timeout => integer(),
        backend => nkemdia:backend(),
        register => nklib:link(),
        user_id => nkservice:user_id(),             % Informative only
        user_session => nkservice:user_session(),   % Informative only
        term() => term()                            % Plugin data
    }.


-type session() ::
    config () | 
    #{
        srv_id => nkservice:id(),
        type => type(),
        type_ext => map(),
        master_peer => id(),
        slave_peer => id()
    }.


-type type_ext() :: {type(), map()}.


-type event() ::
    {answer, nkmedia:answer()}          |   % Answer SDP is available
    {updated_type, atom(), map()}       |
    {candidate, nkmedia:candidate()}    |
    {info, binary()}                    |   % User info
    {stop, nkservice:error()}           |   % Session is about to hangup
    {linked_down, id(), caller|callee, Reason::term()}.


-type ext_ops() ::
    #{
        offer => nkmedia:offer(),
        answer => nkmedia:answer(),
        type => type(),
        type_ext => map(),
        register => nklib:link(),
        wait_client_trickle_ice => boolean(),
        wait_server_trickle_ice => boolean()
    }.



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
            {SessId, Config3} = nkmedia_util:add_id(session_id, Config2),
            {ok, SessPid} = gen_server:start(?MODULE, [Config3], []),
            case gen_server:call(SessPid, do_start, ?MAX_CALL_TIME) of
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
    do_call(SessId, get_offer, ?MAX_CALL_TIME).


%% @doc Get current session answer
-spec get_answer(id()) ->
    {ok, nkmedia:answer()} | {error, nkservice:error()}.

get_answer(SessId) ->
    do_call(SessId, get_answer, ?MAX_CALL_TIME).


%% @doc Get current type, type_ext and remaining time to timeout
-spec get_type(id()) ->
    {ok, type(), map(), integer()} | {error, term()}.

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



%% @doc Sends a client ICE candidate to the backend
-spec client_candidate(id(), nkmedia:candidate()) ->
    ok | {error, term()}.

client_candidate(SessId, Candidate) ->
    do_cast(SessId, {client_candidate, Candidate}).


%% @doc Sends a client ICE candidate to the backend
-spec server_candidate(id(), nkmedia:candidate()) ->
    ok | {error, term()}.

server_candidate(SessId, Candidate) ->
    do_cast(SessId, {server_candidate, Candidate}).



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


%% @doc Links this session to another. We are master, other is slave
%% See peer option
-spec link_slave(id(), id()) ->
    {ok, pid()} | {error, nkservice:error()}.

link_slave(SessId, SessIdB) ->
    case find(SessIdB) of
        {ok, PidB} ->
            do_call(SessId, {link_to_slave, SessIdB, PidB});
        not_found ->
            {error, peer_session_not_found}
    end.


%% @doc Unkinks this session from its peer 
-spec unlink_session(id()) ->
    ok | {error, nkservice:error()}.

unlink_session(SessId) ->
    do_cast(SessId, unlink_session).


%% @doc Registers a process with the session
-spec register(id(), nklib:link()) ->
    {ok, pid()} | {error, nkservice:error()}.

register(SessId, Link) ->
    do_call(SessId, {register, Link}).


%% @doc Unregisters a process with the session
-spec unregister(id(), nklib:link()) ->
    ok | {error, nkservice:error()}.

unregister(SessId, Link) ->
    do_cast(SessId, {unregister, Link}).


%% @private
-spec get_all() ->
    [{id(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).


%% @private. Notifies that the type changed externally
-spec ext_ops(id(), ext_ops()) ->
    ok | {error, term()}.

ext_ops(SessId, ExtOps) ->
    do_cast(SessId, {ext_ops, ExtOps}).


%% ===================================================================
%% Internal
%% ===================================================================


%% @private
do_add(Key, Val, Session) ->
    maps:put(Key, Val, Session).


%% @private
do_rm(Key, Session) ->
    maps:remove(Key, Session).


% ===================================================================
%% gen_server behaviour
%% ===================================================================

-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    type :: type(),
    has_offer = false :: boolean(),
    has_answer = false :: boolean(),
    timer :: reference(),
    stop_sent = false :: boolean(),
    links :: nklib_links:links(),
    client_candidates = trickle :: trickle | last | [nkmedia:candidate()],
    server_candidates = trickle :: trickle | last | [nkmedia:candidate()],
    session :: session()
}).


%% @private
-spec init(term()) ->
    {ok, #state{}} | {error, term()}.

init([#{session_id:=Id, type:=Type, srv_id:=SrvId}=Session]) ->
    true = nklib_proc:reg({?MODULE, Id}),
    nklib_proc:put(?MODULE, Id),
    Session2 = ?SESSION(#{start_time=>nklib_util:l_timestamp()}, Session),
    Session3 = maps:merge(#{type_ext=>#{}}, Session2),
    State1 = #state{
        id = Id, 
        srv_id = SrvId, 
        type = Type,
        links = nklib_links:new(),
        session = Session3
    },
    State2 = case Session3 of
        #{register:=Link} -> 
            links_add(Link, State1);
        _ ->
            State1
    end,
    case Session3 of
        #{peer_id:=Peer} -> 
            case link_slave(Peer, Id) of
                {ok, _} -> 
                    ok;
                {error, _Error} -> 
                    stop(self(), peer_stopped)
            end;
        _ -> 
            ok
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

handle_call(get_type, _From, #state{type=Type, timer=Timer, session=Session}=State) ->
    #{type_ext:=TypeExt} = Session,
    reply({ok, Type, TypeExt, erlang:read_timer(Timer) div 1000}, State);

handle_call({answer, Answer}, From, State) ->
    do_set_answer(Answer, From, State);

handle_call({update, Update, Opts}, From, State) ->
    do_update(Update, Opts, From, State);

handle_call(get_state, _From, State) -> 
    reply(State, State);

handle_call(get_offer, _From, #state{session=Session}=State) -> 
    Reply = case maps:find(offer, Session) of
        {ok, Offer} -> {ok, Offer};
        error -> {error, offer_not_set}
    end,
    reply(Reply, State);

handle_call(get_answer, _From, #state{session=Session}=State) -> 
    Reply = case maps:find(answer, Session) of
        {ok, Answer} -> {ok, Answer};
        error -> {error, answer_not_set}
    end,
    reply(Reply, State);

handle_call({link_to_slave, IdB, PidB}, _From, #state{id=IdA}=State) ->
    ?LLOG(notice, "linked to slave session ~s", [IdB], State),
    do_cast(PidB, {link_to_master, IdA, self()}),
    State2 = links_add({slave_peer, IdB}, PidB, State),
    State3 = add_to_session(slave_peer, IdB, State2),
    reply({ok, self()}, State3);

handle_call({register, Link}, _From, State) ->
    ?LLOG(info, "registered link (~p)", [Link], State),
    State2 = links_add(Link, State),
    reply({ok, self()}, State2);

handle_call(Msg, From, State) -> 
    handle(nkmedia_session_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({client_candidate, Candidate}, State) ->
    noreply(do_client_candidate(Candidate, State));

handle_cast({server_candidate, Candidate}, State) ->
    noreply(do_server_candidate(Candidate, State));

handle_cast({answer, Answer}, State) ->
    do_set_answer(Answer, undefined, State);

handle_cast({update, Update, Opts}, State) ->
    do_update(Update, Opts, undefined, State);

handle_cast({info, Info}, State) ->
    noreply(event({info, Info}, State));

handle_cast({link_to_master, IdB, PidB}, State) ->
    ?LLOG(notice, "linked to master ~s", [IdB], State),
    State2 = links_add({master_peer, IdB}, PidB, State),
    State3 = add_to_session(master_peer, IdB, State2),
    noreply(State3);

handle_cast(unlink_session, #state{id=IdA, session=Session}=State) ->
    case maps:find(slave_peer, Session) of
        {ok, IdB} ->
            % We are a master, IdB is a slave
            do_cast(self(), {unlink_from_slave, IdB}),
            do_cast(IdB, {unlink_from_master, IdA});
        error ->
            ok
    end,
    case maps:find(master_peer, Session) of
        {ok, IdC} ->
            % We are a slave, IdC is a master
            do_cast(self(), {unlink_from_master, IdC}),
            do_cast(IdC, {unlink_from_slave, IdC});
        error ->
            ok
    end,
    noreply(State);

handle_cast({unlink_from_slave, IdB}, #state{session=Session}=State) ->
    case maps:find(slave_peer, Session) of
        {ok, IdB} ->
            ?LLOG(notice, "unlinked from slave ~s", [IdB], State),
            State2 = links_remove({slave_peer, IdB}, State),
            noreply(remove_from_session(slave_peer, State2));
        _ ->
            noreply(State)
    end;

handle_cast({unlink_from_master, IdB}, #state{session=Session}=State) ->
    case maps:find(master_peer, Session) of
        {ok, IdB} ->
            ?LLOG(notice, "unlinked from master ~s", [IdB], State),
            State2 = links_remove({master_peer, IdB}, State),
            noreply(remove_from_session(master_peer, State2));
        _ ->
            noreply(State)
    end;

handle_cast({unregister, Link}, State) ->
    ?LLOG(info, "proc unregistered (~p)", [Link], State),
    noreply(links_remove(Link, State));

handle_cast({ext_ops, ExtOps}, State) ->
    State2 = update_ext_ops_type(ExtOps, State),
    noreply(restart_timer(State2));
   
handle_cast({stop, Error}, State) ->
    do_stop(Error, State);

handle_cast(Msg, State) -> 
    handle(nkmedia_session_handle_cast, [Msg], State).


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({timeout, _, session_timeout}, State) ->
    ?LLOG(notice, "operation timeout", [], State),
    do_stop(session_timeout, State);

handle_info({timeout, _, client_ice_timeout}, State) ->
    ?LLOG(info, "Client ICE timeout", [], State),
    noreply(do_client_candidate(#candidate{last=true}, State));

handle_info({timeout, _, server_ice_timeout}, State) ->
    ?LLOG(info, "Server ICE timeout", [], State),
    noreply(do_server_candidate(#candidate{last=true}, State));

handle_info({'DOWN', Ref, process, _Pid, Reason}=Msg, #state{id=Id}=State) ->
    case links_down(Ref, State) of
        {ok, Link, State2} ->
            case handle(nkmedia_session_reg_down, [Id, Link, Reason], State2) of
                {ok, State3} ->
                    noreply(State3);
                {stop, normal, State3} ->
                    do_stop(normal, State3);    
                {stop, Error, State3} ->
                    ?LLOG(notice, "stopping beacuse of reg '~p' down (~p)",
                          [Link, Reason], State3),
                    do_stop(Error, State3)
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
            _ = do_stop(anormal_termination, State)
    end,
    {ok, _State2} = handle(nkmedia_session_terminate, [Reason], State).




%% ===================================================================
%% Internal
%% ===================================================================

%% @private
do_start(From, #state{type=Type, session=Session}=State) ->
    case handle(nkmedia_session_start, [Type, From], State) of
        {ok, Reply, ExtOps, State2} ->
            State3 = update_ext_ops_offer(ExtOps, State2),
            reply(Reply, From, restart_timer(State3));
        {ok, ExtOps, State2} ->
            State3 = update_ext_ops_offer(ExtOps, State2),
            noreply(restart_timer(State3));
        {wait_server_trickle_ice, State2} ->
            Time2 = maps:get(max_ice_time, Session, ?MAX_ICE_TIME),
            erlang:start_timer(Time2, self(), server_ice_timeout),
            ?LLOG(notice, "waiting for server Trickle ICE", [], State),
            noreply(State2#state{server_candidates=[]});
        {error, Error, State2} ->
            stop(self(), Error),
            reply({error, Error}, From, State2)
    end.


%% @private
do_set_answer(_Answer, From, #state{has_answer=true}=State) ->
    reply({error, answer_already_set}, From, State);

do_set_answer(Answer, From, #state{type=Type}=State) ->
    case handle(nkmedia_session_answer, [Type, Answer, From], State) of
        {ok, Reply, ExtOps, State2} ->
            State3 = update_ext_ops_answer(ExtOps, State2),
            reply(Reply, From, restart_timer(State3));
        {ok, ExtOps, State2} ->
            State3 = update_ext_ops_answer(ExtOps, State2),
            noreply(restart_timer(State3));
        {error, Error, State2} ->
            reply({error, Error}, From, State2)
    end.


%% @private
do_update(Update, Opts, From, #state{has_answer=true}=State) ->
    case handle(nkmedia_session_update, [Update, Opts, From], State) of
        {ok, Reply, ExtOps, State2} ->
            State3 = update_ext_ops_type(ExtOps, State2),
            reply(Reply, From, restart_timer(State3));
        {ok, ExtOps, State2} ->
            State3 = update_ext_ops_type(ExtOps, State2),
            noreply(restart_timer(State3));
        {error, Error, State2} ->
            reply({error, Error}, From, State2)
    end;

do_update(_Update, _Opts, From, State) ->
    reply({error, answer_not_set}, From, State).


%% @private
do_client_candidate(Candidate, #state{client_candidates=trickle}=State) ->
    {ok, State2} = handle(nkmedia_session_candidate, [Candidate], State),
    State2;

do_client_candidate(Candidate, #state{client_candidates=last}=State) ->
    case Candidate of
        #candidate{last=true} -> ok;
        _ -> ?LLOG(notice, "ignoring late client candidate", [], State)
    end,
    State;

do_client_candidate(#candidate{last=true}, State) ->
    #state{client_candidates=Candidates} = State,
    {ok, ExtOps, State2} = 
        handle(nkmedia_session_client_trickle_ready, [Candidates], State),
    State3 = update_ext_ops_offer(ExtOps, State2),
    State4 = State3#state{client_candidates=last},
    restart_timer(State4);

do_client_candidate(Candidate, #state{client_candidates=Candidates}=State) ->
    Candidates2 = [Candidate|Candidates],
    State#state{client_candidates=Candidates2}.


%% @private
do_server_candidate(Candidate, #state{server_candidates=trickle}=State) ->
    event({candidate, Candidate}, State);

do_server_candidate(Candidate, #state{server_candidates=last}=State) ->
    case Candidate of
        #candidate{last=true} -> ok;
        _ -> ?LLOG(notice, "ignoring late server candidate", [], State)
    end,
    State;

do_server_candidate(#candidate{last=true}, State) ->
    #state{server_candidates=Candidates} = State,
    {ok, ExtOps, State2} = 
        handle(nkmedia_session_server_trickle_ready, [Candidates], State),
    State3 = update_ext_ops_answer(ExtOps, State2),
    State4 = State3#state{server_candidates=last},
    restart_timer(State4);

do_server_candidate(Candidate, State) ->
    #state{server_candidates=Candidates} = State,
    Candidates2 = [Candidate|Candidates],
    State#state{server_candidates=Candidates2}.



%% ===================================================================
%% Util
%% ===================================================================


%% @private
update_ext_ops_offer(ExtOps, #state{session=Session}=State) ->
    State3 = case ExtOps of
        #{offer:=Offer} ->
            OldOffer = maps:get(offer, Session, #{}),
            NewOffer = maps:merge(OldOffer, Offer),
            State2 = add_to_session(offer, NewOffer, State),
            case NewOffer of
                #{sdp:=_} ->
                    ?LLOG(info, "offer set", [], State2),
                    event({offer, Offer}, State2#state{has_offer=true});
                _ ->
                    State2
            end;
        _ ->
            State
    end,
    update_ext_ops_answer(ExtOps, State3).


%% @private
update_ext_ops_answer(ExtOps, #state{session=Session}=State) ->
    State3 = case ExtOps of
        #{answer:=Answer} ->
            OldAnswer = maps:get(answer, Session, #{}),
            NewAnswer = maps:merge(OldAnswer, Answer),
            State2 = add_to_session(answer, NewAnswer, State),
            case NewAnswer of
                #{sdp:=_} ->
                    ?LLOG(info, "answer set", [], State2),
                    event({answer, Answer}, State2#state{has_answer=true});
                _ ->
                    State2
            end;
        _ ->
            State
    end,
    update_ext_ops_type(ExtOps, State3).


% %% @private
% update_ext_ops_trickle(ExtOps, #state{session=Session}=State) ->
%     State2 = case ExtOps of
%         #{wait_client_trickle_ice:=true} ->
%             Time1 = maps:get(max_ice_time, Session, ?MAX_ICE_TIME),
%             erlang:start_timer(Time1, self(), client_ice_timeout),
%             ?LLOG(notice, "waiting for client Trickle ICE", [], State),
%             State#state{client_candidates=[]};
%         _ ->
%             State
%     end,
%     State3 = case ExtOps of
%         #{wait_server_trickle_ice:=true} ->
%             lager:error("WAIT SERVER"),
%             Time2 = maps:get(max_ice_time, Session, ?MAX_ICE_TIME),
%             erlang:start_timer(Time2, self(), server_ice_timeout),
%             ?LLOG(notice, "waiting for server Trickle ICE", [], State),
%             State2#state{server_candidates=[]};
%         _ ->
%             State2
%     end,
%     update_ext_ops_type(ExtOps, State3).


update_ext_ops_type(ExtOps, #state{type=OldType, session=Session}=State) ->
    State2 = case ExtOps of
        #{register:=Link} ->
            links_add(Link, State);
        _ ->
            State
    end,
    Type = maps:get(type, ExtOps, OldType),
    OldExt = maps:get(type_ext, Session),
    DefExt = case Type==OldType of
        true -> OldExt;
        false -> #{}
    end,
    Ext = maps:get(type_ext, ExtOps, DefExt),
    case {Type, Ext} of
        {OldType, OldExt} ->
            State2;
        _ ->
            State3 = case Ext of
                OldExt -> State2;
                _ -> add_to_session(type_ext, Ext, State2)
            end,
            State4 = case Type of
                OldType -> State3;
                _ -> add_to_session(type, Type, State3#state{type=Type})
            end,
            ?LLOG(info, "session updated", [], State4),
            event({updated_type, Type, Ext}, State4)
    end.



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
reply(Reply, State) ->
    {reply, Reply, State}.


%% @private
reply(Reply, From, State) ->
    nklib_util:reply(From, Reply),
    noreply(State).


%% @private
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
        {offer, _} ->  ?LLOG(info, "sending 'offer'", [], State);
        {answer, _} -> ?LLOG(info, "sending 'answer'", [], State);
        _ ->           ?LLOG(info, "sending 'event': ~p", [Event], State)
    end,
    State2 = links_fold(
        fun(Link, AccState) ->
            {ok, AccState2} = 
                handle(nkmedia_session_reg_event, [Id, Link, Event], AccState),
                AccState2
        end,
        State,
        State),
    {ok, State3} = handle(nkmedia_session_event, [Id, Event], State2),
    State3.


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
do_info(SessId, Msg) ->
    case find(SessId) of
        {ok, Pid} -> Pid ! Msg;
        not_found -> {error, session_not_found}
    end.


%% @private
add_to_session(Key, Val, #state{session=Session}=State) ->
    Session2 = do_add(Key, Val, Session),
    State#state{session=Session2}.

remove_from_session(Key, #state{session=Session}=State) ->
    Session2 = do_rm(Key, Session),
    State#state{session=Session2}.



%% @private
links_add(Link, #state{links=Links}=State) ->
    State#state{links=nklib_links:add(Link, Links)}.


%% @private
links_add(Link, Pid, #state{links=Links}=State) ->
    State#state{links=nklib_links:add(Link, none, Pid, Links)}.


%% @private
links_remove(Link, #state{links=Links}=State) ->
    State#state{links=nklib_links:remove(Link, Links)}.


%% @private
links_down(Mon, #state{links=Links}=State) ->
    case nklib_links:down(Mon, Links) of
        {ok, Link, _Data, Links2} -> 
            {ok, Link, State#state{links=Links2}};
        not_found -> 
            not_found
    end.


%% @private
links_fold(Fun, Acc, #state{links=Links}) ->
    nklib_links:fold(Fun, Acc, Links).






