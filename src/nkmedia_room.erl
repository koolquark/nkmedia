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

%% @doc Room management
-module(nkmedia_room).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start/2, stop/1, stop/2, get_room/1, register/2, unregister/2, get_all/0]).
-export([update/2, restart_timer/0, find/1]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, room/0, event/0]).


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Room ~s (~p) "++Txt, [State#state.id, State#state.class | Args])).

-include("nkmedia.hrl").
-include_lib("nkservice/include/nkservice.hrl").

-define(TIMEOUT, 180000).


%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().


-type config() ::
    #{
        audio_codec => opus | isac32 | isac16 | pcmu | pcma,
        video_codec => vp8 | vp9 | h264,
        bitrate => integer(),
        class => atom(),        % sfu | mcu
        backend => atom()       % nkmedia_janus...
    }.


-type member_opts() ::
    #{
        user => binary(),
        pid => pid(),
        peer => binary()
    }.




-type room() ::
    config() |
    #{
        srv_id => nkservice:id(),
        id => id(),
        publishers => #{session_id() => member_opts()},
        listeners => #{session_id() => member_opts()},
        links => nklib:links()
    }.

-type session_id() :: nkmedia_session:id().


-type event() ::
    {started, room()} | {destroyed, nkservice:error()} | timeout |
    {started_publisher, session_id(), member_opts()} | 
    {stopped_publisher, session_id(), member_opts()} |
    {started_listener, session_id(), member_opts()} | 
    {stopped_listener, session_id(), member_opts()}.


-type update() ::
    {started_publisher, nkmedia_session:id(), member_opts()} |
    {stopped_publisher, nkmedia_session:id(), member_opts()} |
    {started_listener, nkmedia_session:id(), member_opts()} |
    {stopped_listener, nkmedia_session:id(), member_opts()}.

 


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Creates a new room
-spec start(nkservice:id(), config()) ->
    {ok, id(), pid()} | {error, term()}.

start(Srv, Config) ->
    {Id, Config2} = nkmedia_util:add_uuid(Config),
    case find(Id) of
        {ok, _} ->
            {error, room_already_exists};
        not_found ->
            case nkservice_srv:get_srv_id(Srv) of
                {ok, SrvId} ->
                    Config3 = Config2#{srv_id=>SrvId},
                    case SrvId:nkmedia_room_init(Id, Config3) of
                        {ok, Config4} ->
                            {ok, Pid} = gen_server:start(?MODULE, [Config4], []),
                            {ok, Id, Pid};
                        {error, Error} ->
                            {error, Error}
                    end;
                not_found ->
                    {error, service_not_found}
            end
    end.


%% @doc
-spec stop(id()) ->
    ok | {error, term()}.

stop(Id) ->
    stop(Id, normal).


%% @doc
-spec stop(id(), nkservice:error()) ->
    ok | {error, term()}.

stop(Id, Reason) ->
    Id2 = nklib_util:to_binary(Id),
    do_cast(Id2, {stop, Reason}).


%% @doc
-spec get_room(id()) ->
    {ok, room()} | {error, term()}.

get_room(Id) ->
    Id2 = nklib_util:to_binary(Id),
    do_call(Id2, get_room).


%% @private
-spec update(id(), update()) ->
    {ok, pid()} | {error, term()}.

update(Id, Update) ->
    do_call(Id, {update, Update}).


%% @doc Registers a process with the call
-spec register(id(), nklib:proc_id()) ->     
    {ok, pid()} | {error, nkservice:error()}.

register(CallId, ProcId) ->
    do_call(CallId, {register, ProcId}).


%% @doc Registers a process with the call
-spec unregister(id(), nklib:proc_id()) ->
    ok | {error, nkservice:error()}.

unregister(CallId, ProcId) ->
    do_call(CallId, {unregister, ProcId}).


%% @doc Gets all started rooms
-spec get_all() ->
    [{id(), nkmedia_janus:id(), pid()}].

get_all() ->
    [{Id, Class, Pid} || 
        {{Id, Class}, Pid}<- nklib_proc:values(?MODULE)].


%% @private
restart_timer() ->
    gen_server:cast(self(), restart_timer).



% ===================================================================
%% gen_server behaviour
%% ===================================================================


-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    class :: atom(),
    timer :: reference(),
    stop_sent = false :: boolean(),
    room :: room()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()}.

init([#{srv_id:=SrvId, id:=RoomId, class:=Class}=Room]) ->
    nklib_proc:put(?MODULE, {RoomId, Class}),
    nklib_proc:put({?MODULE, RoomId}),
    State1 = #state{
        id = RoomId, 
        srv_id = SrvId, 
        class = Class,
        room = Room#{links=>nklib_links:new()}
    },
    State2 = case Room of
        #{register:=ProcId} -> 
            ProcPid = nklib_links:get_pid(ProcId),            
            links_add(ProcId, reg, ProcPid, State1);
        _ ->
            State1
    end,
    ?LLOG(notice, "started", [], State2),
    {ok, event({started, Room}, State2)}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(get_room, _From, #state{room=Room}=State) -> 
    {reply, {ok, Room}, State};

handle_call({update, Update}, _From, State) ->
    case do_update(Update, State) of
        {ok, State2} ->
            {reply, {ok, self()}, State2}; 
        {error, Error, State2} ->
            {reply, {error, Error}, State2}
    end; 

handle_call({register, ProcId}, _From, State) ->
    ?LLOG(info, "proc registered (~p)", [ProcId], State),
    Pid = nklib_links:get_pid(ProcId),
    State2 = links_add(ProcId, reg, Pid, State),
    {reply, {ok, self()}, State2};

handle_call(get_state, _From, State) ->
    {reply, State, State};

handle_call(Msg, From, State) -> 
    handle(nkmedia_room_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

%% @private
handle_cast({unregister, ProcId}, State) ->
    ?LLOG(info, "proc unregistered (~p)", [ProcId], State),
    {noreply, links_remove(ProcId, State)};

handle_cast(restart_timer, State) ->
    {noreply, restart_timer(State)};

handle_cast({stop, Reason}, State) ->
    ?LLOG(info, "external stop: ~p", [Reason], State),
    do_stop(Reason, State);

handle_cast(Msg, State) -> 
    handle(nkmedia_room_handle_cast, [Msg], State).


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info(room_timeout, State) ->
    {noreply, event(timeout, State)};

handle_info({'DOWN', _Ref, process, Pid, Reason}=Msg, #state{id=Id}=State) ->
    case links_down(Pid, State) of
        {ok, SessId, publisher, State2} ->
            {ok, State3} = do_update({stopped_publisher, SessId}, State2),
            {noreply, State3};
        {ok, SessId, listener, State2} ->
            {ok, State3} = do_update({stopped_listener, SessId}, State2),
            {noreply, State3};
        {ok, ProcId, reg, State2} ->
            case handle(nkmedia_room_reg_down, [Id, ProcId, Reason], State2) of
                {ok, State3} ->
                    {noreply, State3};
                {stop, normal, State3} ->
                    do_stop(normal, State3);    
                {stop, Error, State3} ->
                    ?LLOG(notice, "stopping beacuse of reg '~p' down (~p)",
                          [ProcId, Error], State3),
                    do_stop(Error, State3)
            end;
        not_found ->
            handle(nkmedia_room_handle_info, [Msg], State)
    end;

handle_info(Msg, #state{}=State) -> 
    handle(nkmedia_room_handle_info, [Msg], State).


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

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
    end,    {ok, State2} = handle(nkmedia_room_terminate, [Reason], State),
    #state{room=Room} = State2,
    lists:foreach(
        fun(SessId) -> nkmedia_session:stop(SessId, room_destroyed) end,
        maps:keys(maps:get(publishers, Room, #{}))),
    lists:foreach(
        fun(SessId) -> nkmedia_session:stop(SessId, room_destroyed) end,
        maps:keys(maps:get(listeners, Room, #{}))),
    event(destroyed, State),
    timer:sleep(100),
    ?LLOG(info, "stopped: ~p", [Reason], State).


% ===================================================================
%% Internal
%% ===================================================================

%% @private
find(Pid) when is_pid(Pid) ->
    {ok, Pid};

find(Id) ->
    Id2 = nklib_util:to_binary(Id),
    case nklib_proc:values({?MODULE, Id2}) of
        [{_, Pid}] -> {ok, Pid};
        [] -> not_found
    end.


%% @private
do_call(Id, Msg) ->
    do_call(Id, Msg, 5000).


%% @private
do_call(Id, Msg, Timeout) ->
    case find(Id) of
        {ok, Pid} -> 
            nkservice_util:call(Pid, Msg, Timeout);
        not_found -> 
            {error, room_not_found}
    end.


%% @private
do_cast(Id, Msg) ->
    case find(Id) of
        {ok, Pid} -> 
            gen_server:cast(Pid, Msg);
        not_found -> 
            {error, room_not_found}
    end.


%% @private
do_update({started_publisher, SessId, Opts}, #state{room=Room}=State) ->
    UserId = maps:get(user, Opts, <<>>),
    Pid = maps:get(pid, Opts, none),
    MemberOpts = #{user=>UserId},
    Publish1 = maps:get(publishers, Room, #{}),
    Publish2 = maps:put(SessId, MemberOpts, Publish1),
    State2 = update_room(publishers, Publish2, State),
    State3 = links_add(SessId, publisher, Pid, State2),
    {ok, event({started_publisher, SessId, MemberOpts}, State3)};

do_update({stopped_publisher, SessId},  #state{room=Room}=State) ->
    Publish1 = maps:get(publishers, Room, #{}),
    MemberOpts = maps:get(SessId, Publish1, #{}),
    Publish2 = maps:remove(SessId, Publish1),
    State2 = update_room(publishers, Publish2, State),
    State3 = links_remove(SessId, State2),
    Listen = maps:get(listeners, Room, #{}),
    ToStop = [LId || {LId, #{peer:=PId}} <- maps:to_list(Listen), PId==SessId],
    lists:foreach(
        fun(LId) -> nkmedia_session:stop(LId, publisher_stopped) end,
        ToStop),
    {ok, event({stopped_publisher, SessId, MemberOpts}, State3)};
    
do_update({started_listener, SessId, Opts}, #state{room=Room}=State) ->
    UserId = maps:get(user, Opts, <<>>),
    Pid = maps:get(pid, Opts, none),
    Peer = maps:get(peer, Opts, <<>>),
    MemberOpts = #{user=>UserId, peer=>Peer},
    Listen1 = maps:get(listeners, Room, #{}),
    Listen2 = maps:put(SessId, MemberOpts, Listen1),
    State2 = update_room(listeners, Listen2, State),
    Pid = maps:get(pid, Opts, none),
    State3 = links_add(SessId, listener, Pid, State2),
    {ok, event({started_listener, SessId, MemberOpts}, State3)};

do_update({stopped_listener, SessId}, #state{room=Room}=State) ->
    Listen1 = maps:get(listeners, Room, #{}),
    MemberOpts = maps:get(SessId, Listen1, #{}),
    Listen2 = maps:remove(SessId, Listen1),
    State2 = update_room(listeners, Listen2, State),
    State3 = links_remove(SessId, State2),
    {ok, event({stopped_listener, SessId, MemberOpts}, State3)};

do_update(Other, State) ->
    {error, {invalid_update, Other}, State}.


%% @private
do_stop(_Reason, #state{stop_sent=true}=State) ->
    {stop, normal, State};

do_stop(Reason, State) ->
    State2 = event({destroyed, Reason}, State#state{stop_sent=true}),
    % Allow events to be processed
    timer:sleep(100),
    {stop, normal, State2}.


%% @private
event(Event, #state{id=Id}=State) ->
    ?LLOG(info, "sending 'event': ~p", [Event], State),
    State2 = links_fold(
        fun
            (ProcId, reg, AccState) ->
                {ok, AccState2} = 
                    handle(nkmedia_room_reg_event, [Id, ProcId, Event], AccState),
                    AccState2;
            (_ProcId, _Type, AccState) ->   % publisher | listener
                    AccState
        end,
        State,
        State),
    {ok, State3} = handle(nkmedia_room_event, [Id, Event], State2),
    State3.


restart_timer(#state{timer=Timer, room=Room}=State) ->
    nklib_util:cancel_timer(Timer),
    Time = 1000 * maps:get(timeout, Room, ?TIMEOUT),
    State#state{timer=erlang:send_after(Time, self(), room_timeout)}.


%% @private
handle(Fun, Args, State) ->
    nklib_gen_server:handle_any(Fun, Args, State, #state.srv_id, #state.room).


%% @private
update_room(Key, Val, #state{room=Room}=State) ->
    Room2 = maps:put(Key, Val, Room),
    State#state{room=Room2}.


%% @private
links_add(Id, Data, Pid, #state{room=#{links:=Links}}=State) ->
    update_room(links, nklib_links:add(Id, Data, Pid, Links), State).


%% @private
links_remove(Id, #state{room=#{links:=Links}}=State) ->
    update_room(links, nklib_links:remove(Id, Links), State).


%% @private
links_down(Pid, #state{room=#{links:=Links}}=State) ->
    case nklib_links:down(Pid, Links) of
        {ok, Id, Data, Links2} -> 
            {ok, Id, Data, update_room(links, Links2, State)};
        not_found -> 
            not_found
    end.

%% @private
links_fold(Fun, Acc, #state{room=#{links:=Links}}) ->
    nklib_links:fold(Fun, Acc, Links).


