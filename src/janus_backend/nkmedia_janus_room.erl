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

-module(nkmedia_janus_room).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([create/3, destroy/1, get_info/1, get_all/0]).
-export([event/2]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export([do_call/2]).

-define(TIMEOUT, 3600).       % secs

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Janus Room ~s "++Txt, [State#state.room | Args])).


%% ===================================================================
%% Types
%% ===================================================================

-type room() :: binary().

-type session() :: nkmedia_session:id().

-type config() ::
    #{
        % For room creation:
        audiocodec => opus | isac32 | isac16 | pcmu | pcma,
        videocodec => vp8 | vp9 | h264,
        bitrate => integer(),
        publishers => integer(),
        record => boolean(),
        rec_dir => binary(),
        timeout => integer()        % secs
    }.

-type info() ::
    config() |
    #{
        room => room(),
        publish => #{session() => map()},
        listen => #{session() => map()}
    }.




-type event() ::
    {publish, session(), map()} | {unpublish, session()} |
    {listen, session(), map()} | {unlisten, session()}.


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Creates a new room
-spec create(nkmedia_janus:id(), room(), config()) ->
    {ok, pid()} | {error, term()}.

create(JanusId, Room, Config) ->
    Room2 = nklib_util:to_binary(Room),
    case nkmedia_janus_session:create_room(JanusId, Room2, Config) of
        ok ->
            {ok, Pid} = gen_server:start(?MODULE, [JanusId, Room2, Config], []),
            {ok, Pid};
        {error, Error} ->
            {error, Error}
    end.


%% @doc
-spec destroy(room()) ->
    ok | {error, term()}.

destroy(Room) ->
    Room2 = nklib_util:to_binary(Room),
    do_call(Room2, destroy).


%% @doc
-spec get_info(room()) ->
    {ok, info()} | {error, term()}.

get_info(Room) ->
    Room2 = nklib_util:to_binary(Room),
    do_call(Room2, get_info).



%% @doc Gets all started rooms
-spec get_all() ->
    [{nkmedia_janus:id(), room(), pid()}].

get_all() ->
    [{JanusId, Room, Pid} || 
        {{JanusId, Room}, Pid}<- nklib_proc:values(?MODULE)].

%% ===================================================================
%% Internal
%% ===================================================================


-spec event(room(), event()) ->
    {ok, pid()} | {error, term()}.

event(1234, _) ->
    ok;

event(Room, Event) ->
    do_call(Room, {event, Event, self()}).




% ===================================================================
%% gen_server behaviour
%% ===================================================================


-record(state, {
    janus_id :: nkmedia_janus:id(),
    room :: room(),
    config :: config(),
    links :: nkmedia_links:links(),
    timer :: reference()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()} | {ok, tuple(), timeout()|hibernate} |
    {stop, term()} | ignore.

init([JanusId, Room, Config]) ->
    true = nklib_proc:reg({?MODULE, Room}, JanusId),
    nklib_proc:put(?MODULE, {JanusId, Room}),
    State = #state{
        janus_id = JanusId,
        room = Room,
        config =Config#{publish=>#{}, listen=>#{}},
        links = nkmedia_links:new()
    },
    ?LLOG(info, "started", [], State),
    {ok, restart_timer(State)}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(get_info, _From, #state{config=Config}=State) ->
    {reply, {ok, Config}, State};

handle_call({event, Event, Pid}, From, State) ->
    event(Event, Pid, From, State);

handle_call(destroy, _From, State) ->
    {stop, normal, ok, State};

handle_call(state, _From, State) ->
    {reply, State, State};

handle_call(Msg, _From, State) ->
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast(stop, State) ->
    lager:info("Conference destroyed"),
    {stop, normal, State};

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info(room_timeout, State) ->
    ?LLOG(notice, "room timeout", [], State),
    {stop, normal, State};

handle_info({'DOWN', Ref, process, _Pid, Reason}=Info, State) ->
    case extract_link_mon(Ref, State) of
        not_found ->
            lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
            {noreply, State};
        {ok, Session, Type, State2} ->
            case Reason of
                normal ->
                    ?LLOG(info, "linked ~p (~s) down (normal)", 
                          [Type, Session], State);
                _ ->
                    ?LLOG(info, "linked ~p (~s) down (~p)", 
                          [Type, Session, Reason], State)
            end,
            {ok, State3} = del(Type, Session, State2),
            {noreply, restart_timer(State3)}
    end;

handle_info(Info, State) -> 
    lager:warning("Module ~p received unexpected info: ~p (~p)", [?MODULE, Info]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(_Reason, #state{janus_id=JanusId, room=Room}=State) ->    
    case nkmedia_janus_session:destroy_room(JanusId, Room) of
        ok ->
            ?LLOG(notice, "stopping, destroying room", [], State);
        {error, Error} ->
            ?LLOG(warning, "could not destroy room: ~p", [Room, Error], State)
    end.


% ===================================================================
%% Internal
%% ===================================================================

%% @private
event({publish, Session, Info}, Pid, _From, State) ->
    case add(publish, Session, Info, Pid, State) of
        {ok, State2} ->
            {reply, {ok, self()}, restart_timer(State2)};
        {error, Error} ->
            {reply, {error, Error}, restart_timer(State)}
    end;

event({unpublish, Session}, _Pid, _From, State) ->
    case del(publish, Session, State) of
        {ok, State2} ->
            {reply, {ok, self()}, restart_timer(State2)};
        {error, Error} ->
            {reply, {error, Error}, restart_timer(State)}
    end;

event({listen, Session, Info}, Pid, _From, State) ->
    case add(listen, Session, Info, Pid, State) of
        {ok, State2} ->
            {reply, {ok, self()}, restart_timer(State2)};
        {error, Error} ->
            {reply, {error, Error}, restart_timer(State)}
    end;

event({unlisten, Session}, _Pid, _From, State) ->
    case del(listen, Session, State) of
        {ok, State2} ->
            {reply, {ok, self()}, restart_timer(State2)};
        {error, Error} ->
            {reply, {error, Error}, restart_timer(State)}
    end.


%% @private
add(Type, Session, Data, Pid, #state{config=Config}=State) ->
    Map = maps:get(Type, Config),
    case maps:is_key(Session, Map) of
        false ->
            Config2 = maps:put(Type, maps:put(Session, Data, Map), Config),
            State2 = State#state{config=Config2},
            {ok, add_link(Session, Type, Pid, State2)};
        true ->
            {error, duplicated_session}
    end.


%% @private
del(Type, Session, #state{config=Config}=State) ->
    Map = maps:get(Type, Config),
    case maps:is_key(Session, Map) of
        true -> 
            Config2 = maps:put(Type, maps:remove(Session, Map), Config),
            State2 = State#state{config=Config2},
            {ok, remove_link(Session, State2)};
        false ->
            {error, not_found}
    end.


%% @private
restart_timer(#state{timer=Timer, config=Config}=State) ->
    nklib_util:cancel_timer(Timer),
    Time = 1000 * maps:get(timeout, Config, ?TIMEOUT),
    State#state{timer=erlang:send_after(Time, self(), room_timeout)}.


%% @private
find(Pid) when is_pid(Pid) ->
    {ok, Pid};

find(Room) ->
    Room2 = nklib_util:to_binary(Room),
    case nklib_proc:values({?MODULE, Room2}) of
        [{_, Pid}] -> {ok, Pid};
        [] -> not_found
    end.


%% @private
do_call(Room, Msg) ->
    do_call(Room, Msg, 5000).


%% @private
do_call(Room, Msg, Timeout) ->
    case find(Room) of
        {ok, Pid} -> 
            nklib_util:call(Pid, Msg, Timeout);
        not_found -> 
            {error, not_found}
    end.


% %% @private
% do_cast(Room, Msg) ->
%     case find(Room) of
%         {ok, Pid} -> gen_server:cast(Pid, Msg);
%         not_found -> {error, not_found}
%     end.



%% @private
add_link(Id, Data, Pid, State) ->
    nkmedia_links:add(Id, Data, Pid, #state.links, State).


% %% @private
% get_link(Id, State) ->
%     nkmedia_links:get(Id, #state.links, State).


% %% @private
% update_link(Id, Data, State) ->
%     nkmedia_links:update(Id, Data, #state.links, State).


%% @private
remove_link(Id, State) ->
    nkmedia_links:remove(Id, #state.links, State).


%% @private
extract_link_mon(Mon, State) ->
    nkmedia_links:extract_mon(Mon, #state.links, State).


% %% @private
% iter_links(Fun, State) ->
%     nkmedia_links:iter(Fun, #state.links, State).