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

%% @doc Room Management Plugin
%% This process models a room in a mediaserver, implemented as a plugin
%% Backends must implement callback functions
-module(nkmedia_room).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start/2, stop/1, stop/2, get_room/1, get_status/1]).
-export([started_member/3, started_member/4, stopped_member/2]).
-export([send_info/3, update_status/2]).
-export([restart_timeout/1, register/2, unregister/2, get_all/0]).
-export([get_all_with_role/2]).
-export([find/1, find_backend/1, do_call/2, do_call/3, do_cast/2]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, room/0, event/0]).


% To debug, set debug => [nkmedia_room]

-define(DEBUG(Txt, Args, State),
    case erlang:get(nkmedia_room_debug) of
        true -> ?LLOG(debug, Txt, Args, State);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Room '~s' (~p) "++Txt, 
               [State#state.id, State#state.backend | Args])).

-include("nkmedia_room.hrl").
-include_lib("nkservice/include/nkservice.hrl").


%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().

-type session_id() :: nkmedia_session:id().

-type config() ::
    #{
        class => atom(),                    % sfu | mcu
        backend => nkmedia:backend(),
        timeout => integer(),               % secs
        register => nklib:link(),    
        audio_codec => opus | isac32 | isac16 | pcmu | pcma,    % info only
        video_codec => vp8 | vp9 | h264,                        % "
        bitrate => integer()
    }.

-type room() ::
    config() |
    #{
        room_id => id(),
        srv_id => nkservice:id(),
        engine_id => term(),
        members => #{session_id() => member_info()},
        status => status()
    }.

-type member_info() ::
    #{
        role => publisher | listener,
        user_id => binary(),
        peer_id => session_id()
    }.


-type status() :: 
    #{
        slow_link => false | #{date=>nklib_util:timestamp(), term()=>term()}
    }.


-type info() :: atom().


-type event() :: 
    created                                         |
    {started_member, session_id(), member_info()}   |
    {stopped_member, session_id(), member_info()}   |
    {status, status()}                              |
    {info, info(), map()}                           |
    {stopped, nkservice:error()}                    |
    destroyed.


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Creates a new room
-spec start(nkservice:id(), config()) ->
    {ok, id(), pid()} | {error, term()}.

start(Srv, Config) ->
    {RoomId, Config2} = nkmedia_util:add_id(room_id, Config, room),
    case find(RoomId) of
        {ok, _} ->
            {error, room_already_exists};
        not_found ->
            case nkservice_srv:get_srv_id(Srv) of
                {ok, SrvId} ->
                    Config3 = Config2#{room_id=>RoomId, srv_id=>SrvId},
                    case gen_server:start(?MODULE, [Config3], []) of
                        {ok, Pid} ->
                            {ok, RoomId, Pid};
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
    stop(Id, user_stop).


%% @doc
-spec stop(id(), nkservice:error()) ->
    ok | {error, term()}.

stop(Id, Reason) ->
    do_cast(Id, {stop, Reason}).


%% @doc
-spec get_room(id()) ->
    {ok, room()} | {error, term()}.

get_room(Id) ->
    do_call(Id, get_room).


%% @doc
-spec get_status(id()) ->
    {ok, room()} | {error, term()}.

get_status(Id) ->
    do_call(Id, get_status).


%% @doc
-spec started_member(id(), session_id(), member_info()) ->
    ok | {error, term()}.

started_member(RoomId, SessId, MemberInfo) ->
    started_member(RoomId, SessId, MemberInfo, undefined).


%% @doc
-spec started_member(id(), session_id(), member_info(), pid()|undefined) ->
    ok | {error, term()}.

started_member(RoomId, SessId, MemberInfo, Pid) ->
    do_cast(RoomId, {started_member, SessId, MemberInfo, Pid}).


%% @doc
-spec stopped_member(id(), session_id()) ->
    ok | {error, term()}.

stopped_member(RoomId, SessId) ->
    do_cast(RoomId, {stopped_member, SessId}).


%% @private
-spec update_status(id(), status()) ->
    ok | {error, term()}.

update_status(Id, Data) when is_map(Data) ->
    do_cast(Id, {update_status, Data}).


%% @private
-spec send_info(id(), info(), map()) ->
    ok | {error, term()}.

send_info(Id, Info, Meta) when is_map(Meta) ->
    do_cast(Id, {info, Info, Meta}).


%% @private
-spec restart_timeout(id()) ->
    ok | {error, term()}.

restart_timeout(Id) ->
    do_cast(Id, restart_timeout).


%% @doc Registers a process with the room
-spec register(id(), nklib:link()) ->     
    {ok, pid()} | {error, nkservice:error()}.

register(RoomId, Link) ->
    case find(RoomId) of
        {ok, Pid} -> 
            do_cast(RoomId, {register, Link}),
            {ok, Pid};
        not_found ->
            {error, room_not_found}
    end.


%% @doc Registers a process with the call
-spec unregister(id(), nklib:link()) ->
    ok | {error, nkservice:error()}.

unregister(RoomId, Link) ->
    do_cast(RoomId, {unregister, Link}).


%% @doc Gets all started rooms
-spec get_all() ->
    [{id(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).


% ===================================================================
%% gen_server behaviour
%% ===================================================================


-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    backend :: nkmedia:backend(),
    timer :: reference(),
    stop_reason = false :: false | nkservice:error(),
    links :: nklib_links:links(),
    room :: room()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()}.

init([#{srv_id:=SrvId, room_id:=RoomId}=Room]) ->
    true = nklib_proc:reg({?MODULE, RoomId}),
    nklib_proc:put(?MODULE, RoomId),
    Room2 = Room#{members=>#{}, status=>#{}},
    case SrvId:nkmedia_room_init(RoomId, Room2) of
        {ok, #{backend:=Backend}=Room3} ->
            State1 = #state{
                id = RoomId, 
                srv_id = SrvId, 
                backend = Backend,
                links = nklib_links:new(),
                room = Room3
            },
            State2 = case Room of
                #{register:=Link} ->
                    links_add(Link, State1);
                _ ->
                    State1
            end,
            set_log(State2),
            nkservice_util:register_for_changes(SrvId),
            ?LLOG(info, "started", [], State2),
            State3 = do_event(created, State2),
            {ok, do_restart_timeout(State3)};
        {ok, _} ->
            {stop, not_implemented};
        {error, Error} ->
            {stop, Error}
    end.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(get_room, _From, #state{room=Room}=State) -> 
    {reply, {ok, Room}, State};

handle_call(get_status, _From, #state{room=Room}=State) ->
    {reply, {ok, maps:get(status, Room)}, State};

handle_call(get_state, _From, State) ->
    {reply, State, State};

handle_call(Msg, From, State) -> 
    handle(nkmedia_room_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

%% @private
handle_cast({started_member, SessId, Info, Pid}, State) ->
    State2 = do_restart_timeout(State),
    {noreply, do_started_member(SessId, Info, Pid, State2)};

handle_cast({stopped_member, SessId}, State) ->
    State2 = do_restart_timeout(State),
    {noreply, do_stopped_member(SessId, State2)};

handle_cast(restart_timeout, State) ->
    {noreply, do_restart_timeout(State)};

handle_cast({update_status, Data}, #state{room=Room}=State) ->
    State2 = do_restart_timeout(State),
    Status1 = maps:get(status, Room),
    Status2 = maps:merge(Status1, Data),
    State3 = State2#state{room=?ROOM(#{status=>Status2}, Room)},
    {noreply, do_event({status, Data}, State3)};

handle_cast({send_info, Info, Meta}, State) ->
    State2 = do_restart_timeout(State),
    {noreply, do_event({info, Info, Meta}, State2)};

handle_cast({register, Link}, State) ->
    ?DEBUG("proc registered (~p)", [Link], State),
    State2 = links_add(Link, State),
    {noreply, State2};

handle_cast({unregister, Link}, State) ->
    ?DEBUG("proc unregistered (~p)", [Link], State),
    {noreply, links_remove(Link, State)};

handle_cast({stop, Reason}, State) ->
    ?DEBUG("external stop: ~p", [Reason], State),
    do_stop(Reason, State);

handle_cast(Msg, State) -> 
    handle(nkmedia_room_handle_cast, [Msg], State).


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info(room_timeout, #state{id=RoomId}=State) ->
    case handle(nkmedia_room_timeout, [RoomId], State) of
        {ok, State2} ->
            {noreply, do_restart_timeout(State2)};
        {stop, Reason, State2} ->
            do_stop(Reason, State2)
    end;

handle_info({'DOWN', Ref, process, _Pid, Reason}=M, State) ->
    #state{stop_reason=Stop} = State,
    case links_down(Ref, State) of
        {ok, _, _, State2} when Stop /= false ->
            {noreply, State2};
        {ok, SessId, member, State2} ->
            ?DEBUG("member ~s down", [SessId], State2),
            {noreply, do_stopped_member(SessId, State2)};
        {ok, Link, reg, State2} ->
            case Reason of
                normal ->
                    ?DEBUG("stopping because of reg '~p' down (~p)",
                           [Link, Reason], State2);
                _ ->
                    ?LLOG(notice, "stopping because of reg '~p' down (~p)",
                          [Link, Reason], State2)
            end,
            do_stop(registered_down, State2);
        not_found ->
            handle(nkmedia_room_handle_info, [M], State)
    end;

handle_info(destroy, State) ->
    {stop, normal, State};

handle_info({nkservice_updated, _SrvId}, State) ->
    {noreply, set_log(State)};

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

terminate(Reason, #state{stop_reason=Stop}=State) ->
    case Stop of
        false ->
            Ref = nklib_util:uid(),
            ?LLOG(notice, "terminate error ~s: ~p", [Ref, Reason], State),
            {noreply, State2} = do_stop({internal_error, Ref}, State);
        _ ->
            State2 = State
    end,
    State3 = do_event(destroyed, State2),
    {ok, _State4} = handle(nkmedia_room_terminate, [Reason], State3),
    ok.


% ===================================================================
%% Internal
%% ===================================================================


%% @private
set_log(#state{srv_id=SrvId}=State) ->
    Debug = case nkservice_util:get_debug_info(SrvId, ?MODULE) of
        {true, _} -> true;
        _ -> false
    end,
    put(nkmedia_room_debug, Debug),
    State.


%% @private
get_all_with_role(Role, #{members:=Members}) ->
    [Id ||  
        {Id, Info} <- maps:to_list(Members), {ok, Role}==maps:find(role, Info)].

%% @private
do_started_member(SessId, Info, Pid, #state{room=#{members:=Members}=Room}=State) ->
    State2 = links_remove(SessId, State),
    State3 = case is_pid(Pid) of
        true ->
            links_add(SessId, member, Pid, State2);
        _ ->
            State2
    end,
    Room2 = ?ROOM(#{members=>maps:put(SessId, Info, Members)}, Room),
    State4 = State3#state{room=Room2},
    do_event({started_member, SessId, Info}, State4).


%% @private
do_stopped_member(SessId, #state{room=#{members:=Members}=Room}=State) ->
    case maps:find(SessId, Members) of
        {ok, Info} ->
            State2 = links_remove(SessId, State),
            case Info of
                #{role:=publisher} ->
                    stop_listeners(SessId, maps:to_list(Members));
                _ ->
                    ok
            end,
            Members2 = maps:remove(SessId, Members),
            Room2 = ?ROOM(#{members=>Members2}, Room),
            State3 = State2#state{room=Room2},
            do_event({stopped_member, SessId, Info}, State3);
        error ->
            State
    end.


%% @private
stop_listeners(_PubId, []) ->
    ok;

stop_listeners(PubId, [{ListenId, Info}|Rest]) ->
    case Info of
        #{role:=listener, peer_id:=PubId} ->
            nkmedia_session:stop(ListenId, publisher_stop);
        _ ->
            ok            
    end,
    stop_listeners(PubId, Rest).



%% @private
find(Pid) when is_pid(Pid) ->
    {ok, Pid};

find(#{room_id:=RoomId}) ->
    find(RoomId);

find(Id) ->
    Id2 = nklib_util:to_binary(Id),
    case nklib_proc:values({?MODULE, Id2}) of
        [{_, Pid}] -> {ok, Pid};
        [] -> not_found
    end.


%% @private
find_backend(Id) ->
    Id2 = nklib_util:to_binary(Id),
    case nklib_proc:values({?MODULE, Id2}) of
        [{{Backend, EngineId}, _Pid}] -> {ok, Backend, EngineId};
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
do_stop(Reason, #state{stop_reason=false}=State) ->
    ?LLOG(info, "stopped: ~p", [Reason], State),
    do_stop_all(State),
    % Give time for possible registrations to success and capture stop event
    timer:sleep(100),
    % Give time for registrations to success
    State2 = do_event({stopped, Reason}, State),
    {ok, State3} = handle(nkmedia_room_stop, [Reason], State2),
    erlang:send_after(?SRV_DELAYED_DESTROY, self(), destroy),
    {noreply, State3#state{stop_reason=Reason}};

do_stop(_Reason, State) ->
    % destroy already sent
    {noreply, State}.


%% @private
do_stop_all(#state{room=#{members:=Members}}) ->
    lists:foreach(
        fun({SessId, _}) -> nkmedia_session:stop(SessId, room_destroyed) end,
        maps:to_list(Members)).


%% @private
do_event(Event, #state{id=Id}=State) ->
    ?DEBUG("sending 'event': ~p", [Event], State),
    State2 = links_fold(
        fun
            (Link, reg, AccState) ->
                {ok, AccState2} = 
                    handle(nkmedia_room_reg_event, [Id, Link, Event], AccState),
                    AccState2;
            (_SessId, member, AccState) ->
                AccState
        end,
        State,
        State),
    {ok, State3} = handle(nkmedia_room_event, [Id, Event], State2),
    State3.


%% @private
handle(Fun, Args, State) ->
    nklib_gen_server:handle_any(Fun, Args, State, #state.srv_id, #state.room).


%% @private
links_add(Id, #state{links=Links}=State) ->
    Pid = nklib_links:get_pid(Id),
    State#state{links=nklib_links:add(Id, reg, Pid, Links)}.


%% @private
links_add(Id, Data, Pid, #state{links=Links}=State) ->
    State#state{links=nklib_links:add(Id, Data, Pid, Links)}.


%% @private
links_remove(Id, #state{links=Links}=State) ->
    State#state{links=nklib_links:remove(Id, Links)}.


%% @private
links_down(Ref, #state{links=Links}=State) ->
    case nklib_links:down(Ref, Links) of
        {ok, Link, Data, Links2} -> 
            {ok, Link, Data, State#state{links=Links2}};
        not_found -> 
            not_found
    end.

%% @private
links_fold(Fun, Acc, #state{links=Links}) ->
    nklib_links:fold_values(Fun, Acc, Links).


%% @private
do_restart_timeout(#state{timer=Timer, room=Room}=State) ->
    nklib_util:cancel_timer(Timer),
    Time = case maps:find(timeout, Room) of
        {ok, UserTime} -> UserTime;
        error -> nkmedia_app:get(room_timeout)
    end,
    State#state{timer=erlang:send_after(1000*Time, self(), room_timeout)}.

