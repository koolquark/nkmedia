
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

-export([start/3, get_type/1, get_status/1, get_session/1, get_offer/1, get_answer/1]).
-export([set_answer/2, set_type/3, cmd/3, cmd_async/3, send_info/3]).
-export([update_history/3, update_status/2]).
-export([stop/1, stop/2, stop_all/0]).
-export([candidate/2]).
-export([register/2, unregister/2]).
-export([link_to_slave/2, unlink_session/1, unlink_session/2]).
-export([get_all/0, get_session_file/1]).
-export([set_slave_answer/3, backend_candidate/2, update_session/2]).
-export([find/1, do_cast/2, do_call/2, do_call/3, do_info/2]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, config/0, session/0, event/0, type_ext/0]).

% To debug, set debug => [{nkmedia_session, #{media=>true}}]

-define(DEBUG(Txt, Args, State),
    case erlang:get(nkmedia_session_debug) of
        true -> ?LLOG(debug, Txt, Args, State);
        _ -> ok
    end).

-define(MEDIA(Txt, Args, State),
    case erlang:get(nkmedia_session_debug_media) of
        true -> ?LLOG(debug, Txt, Args, State);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args, State),
    lager:Type(
            [
                {media_session_id, State#state.id}, 
                {user_id, State#state.user_id},
                {session_id, State#state.session_id}
            ],
           "NkMEDIA Session ~s (~s, ~p) "++Txt, 
           [State#state.id, State#state.user_id, State#state.type | Args])).

-include("nkmedia.hrl").
-include_lib("nklib/include/nklib.hrl").
-include_lib("nkservice/include/nkservice.hrl").
-include_lib("nksip/include/nksip.hrl").

-define(MAX_ICE_TIME, 5000).
-define(MAX_CALL_TIME, 5000).



%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().


%% Backend plugins expand the available types
-type type() :: p2p | atom().


%% Backend plugins expand the available types
-type cmd() :: term().


%% Session configuration
%% If we set a master session, we will set this as a 'slave' of that 'master' session
%% If one of them stops, the other one will also stop.
%% If the slave has an answer, it will invoke nkmedia_session_slave_answer in master
%% If it has an ICE candidate to send, it will invoke nkmedia_session_peer_candidate
%% in master instead of sending the event {candidate, Candidate}
%% If the master has an ICE candidate to send, will invoke nkmedia_session_peer_candidate
%% in slave
-type config() :: 
    #{
        session_id => id(),                         % Generated if not included
        offer => nkmedia:offer(),
        no_offer_trickle_ice => boolean(),          % Buffer candidates and insert in SDP
        no_answer_trickle_ice => boolean(),       
        trickle_ice_timeout => integer(),
        sdp_type => webrtc | rtp,
        backend => nkemdia:backend(),
        master_id => id(),                          % See above
        set_master_answer => boolean(),             % Send answer to master. Def false
        stop_after_peer => boolean(),               % Stop if peer stops. Def true
        register => nklib:link(),
        wait_timeout => integer(),                  % Secs
        ready_timeout => integer(),

        user_id => nkservice:user_id(),             % Informative only
        user_session => nkservice:user_session(),   % Informative only
        
        room_id => binary(),                        % To be used in backends
        publisher_id => binary(),
        mute_audio => boolean(),
        mute_video => boolean(),
        mute_data => boolean(),
        bitrate => integer(),
        record => boolean(),
        record_uri => binary(),
        player_uri => binary(),

        term() => term()                            % Plugin data
    }.


-type session() ::
    config () | 
    #{
        srv_id => nkservice:id(),
        backend_role => offerer | offeree,
        type => type(),
        type_ext => type_ext(),
        slave_id => id(),
        status => status(),
        call_id => binary(),                        % Used by nkcollab_call
        record_pos => integer(),                    % Record position
        player_loops => boolean() |integer()
    }.


-type status() :: 
    #{
        mute_audio => boolean(),
        mute_video => boolean(),
        mute_data => boolean(),
        bitrate => integer(),
        ice_status => gathering | connecting | connected | ready | failed,
        webrtc_ready => boolean(),
        audio_status => started | stopped,
        video_status => started | stopped,
        data_status => started | stopped,
        record => boolean(),
        uri => binary(),
        slow_link => false | #{date=>nklib_util:timestamp(), term()=>term()}
    }.

-type type_ext() :: map().

-type info() :: atom().

-type event() ::
    created                                             |
    {offer, nkmedia:offer()}                            | 
    {answer, nkmedia:answer()}                          | 
    {type, atom(), map()}                               |
    {candidate, nkmedia:candidate()}                    |
    {status, status()}                                  |
    {info, info(), map()}                               |  % User info
    {stopped, nkservice:error()}                        |  % Session is about to stop
    {record, [{integer(), map()}]}                      |
    destroyed.


-type from() :: {pid(), term()}.


% ===================================================================
% Public
% ===================================================================

%% @private
-spec start(nkservice:id(), type(), config()) ->
    {ok, id(), pid()} | {error, nkservice:error()}.

start(Srv, Type, Config) ->
    case nkservice_srv:get_srv_id(Srv) of
        {ok, SrvId} ->
            Config2 = Config#{type=>Type, srv_id=>SrvId},
            {SessId, Config3} = nkmedia_util:add_id(session_id, Config2, session),
            {ok, SessPid} = gen_server:start(?MODULE, [Config3], []),
            {ok, SessId, SessPid};
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
    {ok, type(), type_ext(), integer()} | {error, term()}.

get_type(SessId) ->
    do_call(SessId, get_type).


%% @doc Get current status
-spec get_status(id()) ->
    {ok, status()} | {error, term()}.

get_status(SessId) ->
    do_call(SessId, get_status).


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
-spec set_answer(id(), nkmedia:answer()) ->
    ok | {error, nkservice:error()}.

set_answer(SessId, Answer) ->
    do_cast(SessId, {set_answer, Answer}).


%% @doc Updates the session's current type
-spec set_type(id(), type(), type_ext()) ->
    ok | {error, nkservice:error()}.

set_type(SessId, Type, TypeExt) ->
    do_cast(SessId, {set_type, Type, TypeExt}).


%% @doc Sends a ICE candidate from the client to the backend
-spec candidate(id(), nkmedia:candidate()) ->
    ok | {error, term()}.

candidate(SessId, #candidate{}=Candidate) ->
    do_cast(SessId, {client_candidate, Candidate}).


%% @doc Sends a command to the session
-spec cmd(id(), cmd(), Opts::map()) ->
    {ok, term()} | {error, nkservice:error()}.

cmd(SessId, Cmd, Opts) ->
    do_call(SessId, {cmd, Cmd, Opts}).


%% @doc Equivalent to cmd/3, but does not wait for operation's result
-spec cmd_async(id(), cmd(), Opts::map()) ->
    ok | {error, nkservice:error()}.

cmd_async(SessId, Cmd, Opts) ->
    do_cast(SessId, {cmd, Cmd, Opts}).


%% @doc Sends an info to the sesison
-spec update_status(id(), status()) ->
    ok | {error, nkservice:error()}.

update_status(SessId, Data) ->
    do_cast(SessId, {update_status, Data}).


%% @doc Update session data (like media status)
-spec update_session(id(), map()) ->
    ok | {error, nkservice:error()}.

update_session(SessId, Data) when is_map(Data) ->
    do_cast(SessId, {update_session, Data}).


%% @doc Sends an info to the sesison
-spec send_info(id(), info(), map()) ->
    ok | {error, nkservice:error()}.

send_info(SessId, Info, Meta) when is_map(Meta) ->
    do_cast(SessId, {send_info, Info, Meta}).


%% @doc Sends an info to the sesison
-spec update_history(id(), atom(), map()) ->
    ok | {error, nkservice:error()}.

update_history(SessId, Op, Data) when is_map(Data) ->
    do_cast(SessId, {update_history, Op, Data}).


%% @doc Links this session to another. We are master, other is slave
-spec link_to_slave(id(), id()) ->
    {ok, pid()} | {error, nkservice:error()}.

link_to_slave(MasterId, SlaveId) ->
    case find(SlaveId) of
        {ok, PidB} ->
            do_call(MasterId, {link_to_slave, SlaveId, PidB});
        not_found ->
            {error, peer_session_not_found}
    end.


%% @doc Unkinks this session from its peer 
-spec unlink_session(id()) ->
    ok | {error, nkservice:error()}.

unlink_session(SessId) ->
    do_cast(SessId, unlink_session).


%% @doc Unkinks this session from its peer 
-spec unlink_session(id(), id()) ->
    ok | {error, nkservice:error()}.

unlink_session(SessId, PeerId) ->
    do_cast(SessId, {unlink_session, PeerId}).


%% @doc Registers a process with the session
-spec register(id(), nklib:link()) ->
    {ok, pid()} | {error, nkservice:error()}.

register(SessId, Link) ->
    case find(SessId) of
        {ok, Pid} -> 
            do_cast(Pid, {register, Link}),
            {ok, Pid};
        not_found ->
            {error, session_not_found}
    end.


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


%% ===================================================================
%% Internal
%% ===================================================================


%% @private
-spec get_session_file(session()) ->
    {binary(), session()}.

get_session_file(#{session_id:=SessId}=Session) ->
    Pos = maps:get(record_pos, Session, 0),
    Name = list_to_binary(io_lib:format("~s_p~4..0w.webm", [SessId, Pos])),
    {Name, ?SESSION(#{record_pos=>Pos+1}, Session)}.


%% @private
-spec set_slave_answer(id(), id(), nkmedia:answer()) ->
    ok | {error, term()}.

set_slave_answer(MasterId, SlaveId, Answer) ->
    do_cast(MasterId, {set_slave_answer, SlaveId, Answer}).


%% @private
-spec backend_candidate(id(), nkmedia:candidate()) ->
    ok | {error, term()}.

backend_candidate(SessId, Candidate) ->
    do_cast(SessId, {backend_candidate, Candidate}).



% ===================================================================
%% gen_server behaviour
%% ===================================================================

-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    backend_role :: offerer | offeree,
    type :: type(),
    type_ext :: type_ext(),
    has_offer = false :: boolean(),
    has_answer = false :: boolean(),
    timer :: reference(),
    wait_offer = [] :: [from()],
    wait_answer = [] :: [from()],
    stop_reason = false :: false | nkservice:error(),
    links :: nklib_links:links(),
    client_candidates = trickle :: trickle | last | [nkmedia:candidate()],
    backend_candidates = trickle :: trickle | last | [nkmedia:candidate()],
    session :: session(),
    user_id :: binary(),
    session_id :: binary(),
    started :: nklib_util:l_timestamp(),
    history = [] :: [{integer(), atom()|map()}]

}).


%% @private
-spec init(term()) ->
    {ok, #state{}} | {error, term()}.

init([#{session_id:=Id, type:=Type, srv_id:=SrvId}=Session]) ->
    true = nklib_proc:reg({?MODULE, Id}),
    nklib_proc:put(?MODULE, Id),
    PeerId = maps:get(peer_id, Session, undefined),
    % If there is no offer, the backed must make one (offerer)
    % If there is an offer, the backend must make the answer (offeree)
    % unless this is a slave p2p session
    Role = case maps:is_key(offer, Session) of
        true when Type==p2p, PeerId/=undefined -> offerer;
        true -> offeree;
        false -> offerer
    end,
    Session2 = Session#{
        backend_role => Role,       
        type => Type,
        type_ext => #{},
        start_time => nklib_util:timestamp(),
        status => #{}
    },
    Session3 = case Type of
        p2p -> Session2#{backend=>p2p};
        _ -> Session2
    end,
    State1 = #state{
        id = Id, 
        srv_id = SrvId, 
        backend_role = Role,
        type = Type,
        type_ext = #{},
        links = nklib_links:new(),
        session = Session3,
        started = nklib_util:l_timestamp(),
        user_id = maps:get(user_id, Session, <<>>),
        session_id = maps:get(user_session, Session, <<>>)
    },
    State2 = case Session3 of
        #{register:=Link} ->
            links_add(Link, State1);
        _ ->
            State1
    end,
    set_log(State2),
    nkservice_util:register_for_changes(SrvId),
    ?LLOG(info, "starting (~p, ~p)", [Role, self()], State2),
    ?DEBUG("config: ~p", [Session3], State2),
    gen_server:cast(self(), do_start),
    {ok, State3} = handle(nkmedia_session_init, [Id], State2),
    {ok, event(created, State3)}.
        

%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call({cmd, set_answer, #{answer:=Answer}}, _From, State) ->
    case do_set_answer(Answer, State) of
        {ok, State2} ->
            reply({ok, #{}}, State2);
        {error, Error, State2} ->
            reply({error, Error}, State2)
    end;

handle_call({cmd, Cmd, Opts}, _From, State) ->
    {Reply, State2} = do_cmd(Cmd, Opts, State),
    reply(Reply, State2);

handle_call({link_to_slave, SlaveId, PidB}, _From, #state{id=MasterId}=State) ->
    % We are Master of SlaveId
    ?DEBUG("linked to slave session ~s", [SlaveId], State),
    do_cast(PidB, {link_to_master, MasterId, self()}),
    reply({ok, self()}, link_to_slave(SlaveId, PidB, State));
    
handle_call(get_session, _From, #state{session=Session}=State) ->
    reply({ok, Session}, State);

handle_call(get_status, _From, #state{session=Session}=State) ->
    reply({ok, maps:get(status, Session)}, State);

handle_call(get_type, _From, #state{type=Type, timer=Timer, session=Session}=State) ->
    #{type_ext:=TypeExt} = Session,
    reply({ok, Type, TypeExt, erlang:read_timer(Timer) div 1000}, State);

handle_call(get_offer, _From, #state{has_offer=true, session=Session}=State) -> 
    reply({ok, maps:get(offer, Session)}, State);

handle_call(get_offer, From, #state{wait_offer=Wait}=State) -> 
    noreply(State#state{wait_offer=[From|Wait]});

handle_call(get_answer, _From, #state{has_answer=true, session=Session}=State) -> 
    reply({ok, maps:get(answer, Session)}, State);

handle_call(get_answer, From, #state{wait_answer=Wait}=State) -> 
    noreply(State#state{wait_answer=[From|Wait]});

handle_call(get_state, _From, State) -> 
    reply(State, State);

handle_call(Msg, From, State) -> 
    handle(nkmedia_session_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast(do_start, #state{id=Id, session=Session}=State) ->
    case Session of
        #{master_id:=MasterId} ->
            case link_to_slave(MasterId, Id) of
                {ok, _} ->
                    do_start(State);
                _ ->
                    do_stop(peer_stopped, State)
            end;
        _ ->
            do_start(State)
    end;

handle_cast({set_answer, Answer}, State) ->
    case do_set_answer(Answer, State) of
        {ok, State2} ->
            noreply(State2);
        {error, Error, State2} ->
            ?LLOG(notice, "set_answer error: ~p", [Error], State2),
            do_stop(Error, State2)
    end;

handle_cast({set_slave_answer, SlaveId, Answer}, #state{session=Session}=State) ->
    case Session of
        #{slave_id:=SlaveId} ->
            case handle(nkmedia_session_slave_answer, [Answer], State) of
                {ok, Answer2, State2} ->
                    handle_cast({set_answer, Answer2}, State2);
                {ignore, State2} ->
                    {noreply, State2}
            end;
        _ ->
            ?LLOG(info, "received answer from unknown slave ~s", [SlaveId], State),
            noreply(State)
    end;

handle_cast({set_type, Type, TypeExt}, #state{session=Session}=State) ->
    Session2 = ?SESSION(#{type=>Type, type_ext=>TypeExt}, Session),
    {ok, #state{}=State2} = check_type(State#state{session=Session2}),
    noreply(State2);

handle_cast({cmd, Cmd, Opts}, State) ->
    {_Reply, State2} = do_cmd(Cmd, Opts, State),
    noreply(State2);

handle_cast({update_status, Data}, #state{session=Session}=State) ->
    Status1 = maps:get(status, Session),
    Status2 = maps:merge(Status1, Data),
    State2 = add_to_session(status, Status2, State),
    State3 = add_history(updated_status, Data, State2),
    ?LLOG(info, "updated status: ~p", [Data], State3),
    {noreply, event({status, Data}, State3)};

handle_cast({update_history, Op, Data}, State) ->
    {noreply, add_history(Op, Data, State)};

handle_cast({send_info, Info, Meta}, State) ->
    noreply(event({info, Info, Meta}, State));

handle_cast({client_candidate, Candidate}, State) ->
    noreply(do_client_candidate(Candidate, State));

handle_cast({backend_candidate, Candidate}, State) ->
    noreply(do_backend_candidate(Candidate, State));

handle_cast({link_to_master, MasterId, PidB}, State) ->
    % We are Slave of MasterId
    ?DEBUG("linked to master ~s", [MasterId], State),
    noreply(link_to_master(MasterId, PidB, State));

handle_cast({unlink_session, PeerId}, #state{id=SessId, session=Session}=State) ->
    State2 = case maps:find(slave_id, Session) of
        {ok, PeerId} ->
            % We are Master of PeerId
            do_cast(PeerId, {unlink_from_master, SessId}),
            unlink_from_slave(PeerId, State);
        _ ->
            State
    end,
    State3 = case maps:find(master_id, Session) of
        {ok, PeerId} ->
            % We are Slave of PeerId
            do_cast(PeerId, {unlink_from_slave, SessId}),
            unlink_from_master(PeerId, State2);
        _ ->
            State2
    end,
    noreply(State3);

handle_cast(unlink_session, #state{id=SessId, session=Session}=State) ->
    State2 = case maps:find(slave_id, Session) of
        {ok, SlaveId} ->
            % We are Master of SlaveId
            do_cast(SlaveId, {unlink_from_master, SessId}),
            unlink_from_slave(SlaveId, State);
        error ->
            State
    end,
    State3 = case maps:find(master_id, Session) of
        {ok, MasterId} ->
            % We are Slave of MasterId
            do_cast(MasterId, {unlink_from_slave, SessId}),
            unlink_from_master(MasterId, State2);
        error ->
            State2
    end,
    noreply(State3);

handle_cast({register, Link}, State) ->
    ?DEBUG("registered link (~p)", [Link], State),
    noreply(links_add(Link, State));

handle_cast({unregister, Link}, State) ->
    ?DEBUG("proc unregistered (~p)", [Link], State),
    noreply(links_remove(Link, State));

handle_cast({peer_stopped, PeerId}, #state{session=Session}=State) ->
    case Session of
        #{stop_after_peer:=false} ->
            handle_cast({unlink_session, PeerId}, State);
        _ ->
            do_stop(peer_stopped, State)
    end;

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

handle_info({timeout, _, client_ice_timeout}, State) ->
    ?MEDIA("Client ICE timeout", [], State),
    State2 = add_history(client_ice_timeout, State),
    noreply(do_client_candidate(#candidate{last=true}, State2));

handle_info({timeout, _, backend_ice_timeout}, State) ->
    ?MEDIA("Backend ICE timeout", [], State),
    State2 = add_history(backend_ice_timeout, State),
    noreply(do_backend_candidate(#candidate{last=true}, State2));

handle_info({'DOWN', Ref, process, _Pid, Reason}=Msg, State) ->
    #state{id=Id, stop_reason=Stop} = State,
    case links_down(Ref, State) of
        {ok, Link, State2} when Stop==false ->
            case handle(nkmedia_session_reg_down, [Id, Link, Reason], State2) of
                {ok, State3} ->
                    noreply(State3);
                {stop, normal, State3} ->
                    do_stop(normal, State3);    
                {stop, Error, State3} ->
                    case Reason of
                        normal ->
                            ?DEBUG("reg '~p' down (~p)", [Link, Reason], State3);
                        _ ->
                            ?LLOG(info, "reg '~p' down (~p)", [Link, Reason], State3)
                    end,
                    do_stop(Error, State3)
            end;
        {ok, _, State2} ->
            {noreply, State2};
        not_found ->
            handle(nkmedia_session_handle_info, [Msg], State)
    end;

handle_info(destroy, State) ->
    {stop, normal, State};

handle_info({nkservice_updated, _SrvId}, State) ->
    {noreply, set_log(State)};

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

terminate(Reason, #state{stop_reason=Stop, history=History}=State) ->
    case Stop of
        false ->
            Ref = nklib_util:uid(),
            ?LLOG(notice, "terminate error ~s: ~p", [Ref, Reason], State),
            {noreply, State2} = do_stop({internal_error, Ref}, State);
        _ ->
            State2 = State
    end,
    State3 = event({record, lists:reverse(History)}, State2),
    State4 = event(destroyed, State3),
    {ok, _State5} = handle(nkmedia_session_terminate, [Reason], State4),
    ok.




%% ===================================================================
%% Internal
%% ===================================================================

%% @private
set_log(#state{srv_id=SrvId}=State) ->
    {Debug, Media} = case nkservice_util:get_debug_info(SrvId, ?MODULE) of
        {true, #{media:=true}} -> {true, true};
        {true, _} -> {true, false};
        _ -> {false, false}
    end,
    put(nkmedia_session_debug, Debug),
    put(nkmedia_session_debug_media, Media),
    State.


%% @private
do_start(#state{type=Type, backend_role=Role}=State) ->
    case handle(nkmedia_session_start, [Type, Role], State) of
        {ok, State2} ->
            case check_offer(State2) of
                {ok, State3} ->
                    noreply(restart_timer(State3));
                {error, Error, State3} ->
                    ?LLOG(info, "do_start error: ~p", [Error], State3),
                    do_stop(Error, State3)
            end;
       {error, Error, State2} ->
            ?LLOG(info, "do_start error: ~p", [Error], State2),
            do_stop(Error, State2)
    end.


%% @private
do_cmd(Cmd, Opts, State) ->
    case handle(nkmedia_session_cmd, [Cmd, Opts], State) of
        {ok, Reply, State2} -> 
            {{ok, Reply}, State2};
        {error, Error, State2} ->
            {{error, Error}, State2}
    end.



%% @private
check_offer(#state{has_offer=false, session=#{offer:=Offer}}=State) ->
    % The callback can update the answer and type here also
    case do_set_offer(Offer, State) of
        {ok, State2} -> 
            check_answer(State2);
        {error, Error, State2} -> 
            {error, Error, State2}
    end;

check_offer(State) ->
    check_answer(State).


%% @private
check_answer(#state{has_answer=false, session=#{answer:=Answer}}=State) ->
    % The callback can update the type here also
    case do_set_answer(Answer, State) of
        {ok, State2} -> 
            check_type(State2);
        {error, Error, State2} -> 
            {error, Error, State2}
    end;

check_answer(State) ->
    check_type(State).


%% @private
check_type(#state{type=OldType, type_ext=OldExt, session=Session}=State) ->
    case Session of
        #{type:=OldType, type_ext:=OldExt} ->
            {ok, State};
        #{type:=Type, type_ext:=Ext} ->
            State2 = State#state{type=Type, type_ext=Ext},
            State3 = add_history(updated_type, #{type=>Type, type_ext=>Ext}, State2),
            ?LLOG(info, "session updated (~p)", [Ext], State3),
            {ok, event({type, Type, Ext}, State3)}
    end.


%% @private
do_set_offer(_Offer, #state{has_offer=true}=State) ->
    {error, offer_already_set, State};

do_set_offer(Offer, #state{type=Type, backend_role=Role, session=Session}=State) ->
    NoTrickleIce = maps:get(no_offer_trickle_ice, Session, false),
    case Offer of
        #{trickle_ice:=true} when NoTrickleIce ->
            Time = maps:get(trickle_ice_timeout, Session, ?MAX_ICE_TIME),
            State2 = add_to_session(offer, Offer, State),
            case Role of
                offerer ->
                    % Offer is from backend
                    #state{backend_candidates=trickle} = State,
                    ?MEDIA("starting buffering trickle ICE for backend offer"
                           " (~p msecs)", [Time], State),
                    erlang:start_timer(Time, self(), backend_ice_timeout),
                    State3 = add_history(start_backed_offer_buffer, State2),
                    State4 = State3#state{backend_candidates=[]};
                offeree ->
                    % Offer is from client
                    #state{client_candidates=trickle} = State,
                    ?MEDIA("starting buffering trickle ICE for client offer"
                           " (~p msecs)", [Time], State),
                    erlang:start_timer(Time, self(), client_ice_timeout),
                    State3 = add_history(start_client_offer_buffer, State2),
                    State4 = State3#state{client_candidates=[]}
            end,
            {ok, State4};
        _ ->
            case handle(nkmedia_session_offer, [Type, Role, Offer], State) of
                {ok, Offer2, State2} ->
                    #state{wait_offer=Wait, session=Session2} = State2,
                    reply_all_waiting({ok, Offer2}, Wait),
                    State3 = State2#state{
                        has_offer = true, 
                        session = ?SESSION(#{offer=>Offer}, Session2),
                        wait_offer = []
                    },
                    ?DEBUG("offer set", [], State3),
                    ?MEDIA("offer:\n~s", [maps:get(sdp, Offer2, <<>>)], State3),
                    State4 = case Role of
                        offerer ->
                            event({offer, Offer2}, State3);
                        offeree ->
                            State3
                    end,
                    {ok, add_history(offer_set, State4)};
                {ignore, State2} ->
                    {ok, State2};
                {error, Error, State2} ->
                    {error, Error, State2}
            end
    end.


%% @private
do_set_answer(_Answer, #state{has_offer=false}=State) ->
    {error, offer_not_set, State};

do_set_answer(_Answer, #state{has_answer=true}=State) ->
    {error, answer_already_set, State};

do_set_answer(Answer, #state{type=Type, backend_role=Role, session=Session}=State) ->
    NoTrickleIce = maps:get(no_answer_trickle_ice, Session, false),
    case Answer of
        #{trickle_ice:=true} when NoTrickleIce ->
            Time = maps:get(trickle_ice_timeout, Session, ?MAX_ICE_TIME),
            State2 = add_to_session(answer, Answer, State),
            case Role of
                offerer ->
                    % Answer is from client
                    #state{client_candidates=trickle} = State,
                    ?MEDIA("starting buffering trickle ICE for client answer"
                           " (~p msecs)", [Time], State),
                    erlang:start_timer(Time, self(), client_ice_timeout),
                    State3 = add_history(start_client_answer_buffer, State2),
                    State4 = State3#state{client_candidates=[]};
                offeree ->
                    #state{backend_candidates=trickle} = State,
                    ?MEDIA("starting buffering trickle ICE for backend answer"
                           " (~p msecs)", [Time], State),
                    erlang:start_timer(Time, self(), backend_ice_timeout),
                    State3 = add_history(start_backend_answer_buffer, State2),
                    State4 = State3#state{backend_candidates=[]}
            end,
            {ok, State4};
        _ ->
            case handle(nkmedia_session_answer, [Type, Role, Answer], State) of
                {ok, Answer2, State2} ->
                    #state{wait_answer=Wait, session=Session2} = State2,
                    reply_all_waiting({ok, Answer2}, Wait),
                    State3 = State2#state{
                        has_answer = true, 
                        session = ?SESSION(#{answer=>Answer2}, Session2),
                        wait_answer = []
                    },
                    ?DEBUG("answer set", [], State3),
                    ?MEDIA("answer:\n~s", [maps:get(sdp, Answer2, <<>>)], State3),
                    State4 = case Session of
                        #{set_master_answer:=true, master_id:=MasterId} ->
                            ?DEBUG("calling set_answer for ~s", [MasterId], State3),
                            set_answer(MasterId, Answer2),
                            State3;
                        _ ->
                            event({answer, Answer2}, State3)
                    end,
                    State5 = add_history(answer_set, State4),
                    {ok, restart_timer(State5)};
                {ignore, State2} ->
                    {ok, State2};
                {error, Error, State2} ->
                    {error, Error, State2}
            end
    end.


%% @private
do_client_candidate(Candidate, #state{client_candidates=trickle}=State) ->
    % We are not storing candidates (we are using Trickle ICE)
    % Send the candidate to the backend
    #candidate{a_line=Line, last=Last} = Candidate,
    case handle(nkmedia_session_candidate, [Candidate], State) of
        {ok, State2} when Last->
            ?MEDIA("sent last client candidate to backend", [], State),
            add_history(sent_last_client_candidate_to_backend, State2);
        {ok, State2} ->
            ?MEDIA("sent client candidate ~s to backend", [Line], State),
            State2;
        {continue, #state{session=#{master_id:=MasterId}}=State2} ->
            % If we receive a client candidate, a no backend takes it,
            % let's send it to my salve as a backend candidate. 
            ?MEDIA("sent client candidate ~s to MASTER", [Line], State),
            backend_candidate(MasterId, Candidate),
            State2;
        {continue, #state{session=#{slave_id:=SlaveId}}=State2} ->
            ?MEDIA("sent client candidate ~s to SLAVE", [Line], State),
            backend_candidate(SlaveId, Candidate),
            State2;
        {continue, State2} ->
            ?LLOG(info, "unmanaged offer candidate!", [], State2),
            State2
    end;

do_client_candidate(#candidate{last=true}, #state{client_candidates=last}=State) ->
    State;

do_client_candidate(#candidate{last=true}, #state{client_candidates=[]}=State) ->
    ?LLOG(info, "no received client candidates!", [], State),
    stop(self(), no_ice_candidates),
    State;

do_client_candidate(Candidate, #state{client_candidates=last}=State) ->
    ?MEDIA("ignoring late client candidate ~p", [Candidate], State),
    add_history(ignoring_late_client_candidate, State);

do_client_candidate(#candidate{last=true}, #state{backend_role=offerer}=State) ->
    % This candidate is for an answer
    ?MEDIA("last client answer candidate received", [], State),
    #state{client_candidates=Candidates} = State,
    State2 = add_history(last_client_answer_candidate_received, State),
    candidate_answer(Candidates, State2#state{client_candidates=last});

do_client_candidate(#candidate{last=true}, #state{backend_role=offeree}=State) ->
    % This candidate is for an offer
    ?MEDIA("last client offer candidate received", [], State),
    #state{client_candidates=Candidates} = State,
    State2 = add_history(last_client_offer_candidate_received, State),
    candidate_offer(Candidates, State2#state{client_candidates=last});

do_client_candidate(Candidate, #state{client_candidates=Candidates}=State) ->
    ?MEDIA("storing client candidate ~s", [Candidate#candidate.a_line], State),
    Candidates2 = [Candidate|Candidates],
    State#state{client_candidates=Candidates2}.


%% @private
do_backend_candidate(Candidate, #state{backend_candidates=trickle}=State) ->
    % We are not storing candidates (we are using Trickle ICE)
    % Send the client to the client
    #candidate{a_line=Line, last=Last} = Candidate,
    case Last of
        true ->
            ?MEDIA("sent backend candidate ~s to client (event)", [Line], State),
            State2 = State;
        false ->
            ?MEDIA("sent last backend candidate to client (event)", [], State),
            State2 = add_history(sent_last_backend_candidate_to_clint, State)
    end,
    event({candidate, Candidate}, State2);

do_backend_candidate(#candidate{last=true}, #state{backend_candidates=last}=State) ->
    State;

do_backend_candidate(#candidate{last=true}, #state{backend_candidates=[]}=State) ->
    ?LLOG(info, "no received backend candidates!", [], State),
    stop(self(), no_ice_candidates),
    State;

do_backend_candidate(Candidate, #state{backend_candidates=last}=State) ->
    ?MEDIA("ignoring late backend candidate ~p", [Candidate], State),
    add_history(ignoring_late_backend_candidate, State);

do_backend_candidate(#candidate{last=true}, #state{backend_role=offerer}=State) ->
    % This candidate is for an offer
    #state{backend_candidates=Candidates} = State,
    ?MEDIA("last backend offer candidate received", [], State),
    State2 = add_history(last_backend_offer_candidate_received, State),
    candidate_offer(Candidates, State2#state{backend_candidates=last});

do_backend_candidate(#candidate{last=true}, #state{backend_role=offeree}=State) ->
    % This candidate is for an answer
    #state{backend_candidates=Candidates} = State,
    ?MEDIA("last backend answer candidate received", [], State),
    State2 = add_history(last_backend_answer_candidate_received, State),
    candidate_answer(Candidates, State2#state{backend_candidates=last});

do_backend_candidate(Candidate, #state{backend_candidates=Candidates}=State) ->
    ?MEDIA("storing backend candidate ~s", [Candidate#candidate.a_line], State),
    Candidates2 = [Candidate|Candidates],
    State#state{backend_candidates=Candidates2}.


%% @private
candidate_offer(Candidates, #state{session=Session}=State) ->
    #{offer:=#{sdp:=SDP1}=Offer} = Session,
    SDP2 = nksip_sdp_util:add_candidates(SDP1, lists:reverse(lists:sort(Candidates))),
    Offer2 = Offer#{sdp:=nksip_sdp:unparse(SDP2), trickle_ice=>false},
    ?LLOG(info, "generating new offer with ~p received candidates", 
           [length(Candidates)], State),
    State2 = add_to_session(offer, Offer2, State),
    State3 = add_history(generated_new_offer, State2),
    case check_offer(State3) of
        {ok, State4} ->
            State4;
        {error, Error, State4} ->
            ?LLOG(info, "ICE error after last candidate: ~p", [Error], State4),
            stop(self(), Error),
            State4
    end.


%% @private
candidate_answer(Candidates, #state{session=Session}=State) ->
    #{answer:=#{sdp:=SDP1}=Answer} = Session,
    SDP2 = nksip_sdp_util:add_candidates(SDP1, Candidates),
    Answer2 = Answer#{sdp:=nksip_sdp:unparse(SDP2), trickle_ice=>false},
    ?LLOG(info, "generating new answer with ~p received candidates", 
           [length(Candidates)], State),
    State2 = add_to_session(answer, Answer2, State),
    State3 = add_history(generated_new_answer, State2),
    case check_offer(State3) of
        {ok, State4} ->
            State4;
        {error, Error, State4} ->
            ?LLOG(info, "ICE error after last candidate: ~p", [Error], State4),
            stop(self(), Error),
            State4
    end.




%% ===================================================================
%% Util
%% ===================================================================


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
reply_all_waiting(Msg, List) ->
    lists:foreach(fun(From) -> nklib_util:reply(From, Msg) end, List).



%% @private
noreply(State) ->
    {noreply, State}.


%% @private
do_stop(Reason, #state{srv_id=SrvId, stop_reason=false}=State) ->
    ?LLOG(info, "stopped: ~p", [Reason], State),
    #state{wait_offer=WaitOffer, wait_answer=WaitAnswer} = State,
    reply_all_waiting({error, session_stopped}, WaitOffer),
    reply_all_waiting({error, session_stopped}, WaitAnswer),
    send_stop_peers(State),
    % Give time for possible registrations to success and capture stop event
    timer:sleep(100),           
    State2 = event({stopped, Reason}, State),
    {ok, State3} = handle(nkmedia_session_stop, [Reason], State2),
    {_Code, Txt} = nkservice_util:error_code(SrvId, Reason),
    State4 = add_history(stopped, #{reason=>Txt}, State3),
    % Delay the destroyed event
    erlang:send_after(5000, self(), destroy),
    {noreply, State4#state{stop_reason=Reason}};

do_stop(_Reason, State) ->
    % destroy already sent
    {noreply, State}.


%% @private
send_stop_peers( #state{id=SessId, session=Session}) ->
    case Session of
        #{master_id:=MasterId} -> 
            do_cast(MasterId, {peer_stopped, SessId});
        _ -> 
            ok
    end,
    case Session of
        #{slave_id:=SlaveId} -> 
            do_cast(SlaveId, {peer_stopped, SessId});
        _ -> 
            ok
    end.


%% @private
event(Event, #state{id=Id}=State) ->
    ?DEBUG("sending 'event': ~p", [Event], State),
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
    Session2 = maps:put(Key, Val, Session),
    State#state{session=Session2}.

remove_from_session(Key, #state{session=Session}=State) ->
    Session2 = maps:remove(Key, Session),
    State#state{session=Session2}.


%% @private
link_to_master(MasterId, PidB, State) ->
    State2 = links_add({master_id, MasterId}, PidB, State),
    add_to_session(master_id, MasterId, State2).


%% @private
link_to_slave(SlaveId, PidB, State) ->
    State2 = links_add({slave_id, SlaveId}, PidB, State),
    add_to_session(slave_id, SlaveId, State2).


unlink_from_slave(SlaveId, #state{session=Session}=State) ->
    case maps:find(slave_id, Session) of
        {ok, SlaveId} ->
            ?DEBUG("unlinked from slave ~s", [SlaveId], State),
            State2 = links_remove({slave_id, SlaveId}, State),
            remove_from_session(slave_id, State2);
        _ ->
            State
    end.


%% @private
unlink_from_master(MasterId, #state{session=Session}=State) ->
    case maps:find(master_id, Session) of
        {ok, MasterId} ->
            ?DEBUG("unlinked from master ~s", [MasterId], State),
            State2 = links_remove({master_id, MasterId}, State),
            remove_from_session(master_id, State2);
        _ ->
            State
    end.


%% @private
add_history(Op, State) ->
    add_history(Op, #{}, State).

%% @private
add_history(Op, Data, #state{started=Started, history=History}=State) ->
    Time = (nklib_util:l_timestamp() - Started) div 1000,
    State#state{history=[{Time, Data#{op=>Op}}|History]}.



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

