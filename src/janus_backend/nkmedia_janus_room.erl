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

%% @doc Janus room (SFU) management
%% Rooms can be created directly or from nkmedia_janus_session (for publish)
%% When a new publisher or listener is started, nkmedia_janus_op sends an event
%% and we monitor it

-module(nkmedia_janus_room).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([create/2, destroy/1, get_room/1, get_all/0]).
-export([check/3, event/2]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export([do_call/2]).

-define(TIMEOUT, 30).       % secs

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Janus Room ~s "++Txt, [State#state.id | Args])).

-include_lib("nklib/include/nklib.hrl").
-include_lib("nkservice/include/nkservice.hrl").


%% ===================================================================
%% Types
%% ===================================================================

-type id() :: binary().

-type session_id() :: nkmedia_session:id().

-type config() ::
    #{
        % For room creation:
        room_audio_codec => opus | isac32 | isac16 | pcmu | pcma,
        room_video_codec => vp8 | vp9 | h264,
        room_bitrate => integer(),
        timeout => integer(),                   % Secs
        janus_id => nkmedia_janus_engine:id(),  % Forces engine
        id => id()                              % Forces id
    }.

-type room() ::
    config() |
    #{
        srv_id => nkservice:id(),
        publish => [session_id()],
        listen => #{session_id() => session_id()}
    }.


-type event() ::
    {publish, session_id()} | {unpublish, session_id()} |
    {listen, session_id(), Publish::session_id()} | {unlisten, session_id()}.


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Creates a new room
-spec create(nkservice:id(), config()) ->
    {ok, id(), pid()} | {error, term()}.

create(Srv, Config) ->
    {Id, Config2} = nkmedia_util:add_uuid(Config),
    case find(Id) of
        {ok, _} ->
            {error, already_started};
        not_found ->
            case nkservice_srv:get_srv_id(Srv) of
                {ok, SrvId} ->
                    case get_janus(SrvId, Config2) of
                        {ok, JanusId} ->
                            Config3 = Config2#{srv_id=>SrvId, janus_id=>JanusId},
                            Create = #{        
                                audiocodec => maps:get(room_audio_codec, Config, opus),
                                videocodec => maps:get(room_video_codec, Config, vp8),
                                bitrate => maps:get(room_bitrate, Config, 0)
                            },
                            case 
                                nkmedia_janus_op:create_room(JanusId, Id, Create) 
                            of
                                ok ->
                                    {ok, Pid} = gen_server:start(?MODULE, [Config3], []),
                                    {ok, Id, Pid};
                                {error, already_exists} ->
                                    {ok, Pid} = gen_server:start(?MODULE, [Config3], []),
                                    {ok, Id, Pid};
                                {error, Error} ->
                                    {error, Error}
                            end;
                        error ->
                            {error, mediaserver_not_available}
                    end;
                not_found ->
                    {error, service_not_found}
            end
    end.


%% @doc
-spec destroy(id()) ->
    ok | {error, term()}.

destroy(Id) ->
    Id2 = nklib_util:to_binary(Id),
    do_call(Id2, destroy).


%% @doc
-spec get_room(id()) ->
    {ok, room()} | {error, term()}.

get_room(Id) ->
    Id2 = nklib_util:to_binary(Id),
    do_call(Id2, get_room).



%% @doc Gets all started rooms
-spec get_all() ->
    [{id(), nkmedia_janus:id(), pid()}].

get_all() ->
    [{Id, JanusId, Pid} || 
        {{Id, JanusId}, Pid}<- nklib_proc:values(?MODULE)].


%% ===================================================================
%% Internal
%% ===================================================================

%% @private Called periodically from nkmedia_janus_engine
check(JanusId, RoomId, Data) ->
    case find(RoomId) of
        {ok, Pid} ->
            #{<<"num_participants">>:=Num} = Data,
            gen_server:cast(Pid, {participants, Num});
        not_found ->
            spawn(
                fun() -> 
                    lager:warning("Destroying orphan Janus room ~s", [RoomId]),
                    nkmedia_janus_op:destroy_room(JanusId, RoomId)
                end)
    end.


%% @private Called from nkmedia_janus_op when new subscribers or listeners 
%% are added or removed
-spec event(id(), event()) ->
    {ok, pid()} | {error, term()}.

event(RoomId, Event) ->
    do_call(RoomId, {event, Event, self()}).




% ===================================================================
%% gen_server behaviour
%% ===================================================================


-record(state, {
    id :: id(),
    srv_id :: nksevice:id(),
    janus_id :: nkmedia_janus:id(),
    room :: room(),
    links :: nklib_links:links(),
    timer :: reference()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()} | {ok, tuple(), timeout()|hibernate} |
    {stop, term()} | ignore.

init([#{srv_id:=SrvId, id:=Id, janus_id:=JanusId}=Config]) ->
    true = nklib_proc:reg({?MODULE, Id}, JanusId),
    nklib_proc:put(?MODULE, {Id, JanusId}),
    State = #state{
        id = Id,
        srv_id = SrvId,
        janus_id = JanusId,
        room =Config#{publish=>[], listen=>#{}},
        links = nklib_links:new()
    },
    Body = maps:with([room_audio_codec, room_video_codec, room_bitrate], Config),
    send_event(created, #{config=>Body}, State),
    ?LLOG(notice, "started", [], State),
    {ok, restart_timer(State)}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(get_room, _From, #state{room=Room}=State) ->
    {reply, {ok, Room}, State};

handle_call({event, Event, Pid}, From, State) ->
    gen_server:reply(From, {ok, Pid}),
    State2 = event(Event, Pid, State),
    {noreply, restart_timer(State2)};

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

handle_cast({participants, Num}, #state{room=Room}=State) ->
    #{publish:=Publish} = Room,
    case length(Publish) of
        Num -> 
            {noreply, State};
        Other ->
            ?LLOG(notice, "Janus says ~p participants, we have ~p!", 
                  [Num, Other], State),
            case Num of
                0 ->
                    {stop, normal, State};
                _ ->
                    {noreply, State}
            end
    end;

handle_cast(stop, State) ->
    lager:info("Conference destroyed"),
    {stop, normal, State};

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info(room_timeout, #state{janus_id=JanusId, id=Id, room=Room}=State) ->
    #{publish:=Publish} = Room,
    case length(Publish) of
        0 ->
            % ?LLOG(notice, "info timeout", [], State),
            {stop, normal, State};
        _ ->
            case nkmedia_janus_engine:check_room(JanusId, Id) of
                {ok, _} ->      
                    {noreply, restart_timer(State)};
                _ ->
                    ?LLOG(warning, "room is not on engine", [], State),
                    {stop, normal, State}
            end
    end;

handle_info({'DOWN', _Ref, process, Pid, Reason}=Info, State) ->
    case links_down(Pid, State) of
        {ok, SessId, Type, State2} ->
            % A publisher or listener is down
            case Reason of
                normal ->
                    ?LLOG(info, "linked ~p (~s) down (normal)", 
                          [Type, SessId], State);
                _ ->
                    ?LLOG(notice, "linked ~p (~s) down (~p)", 
                          [Type, SessId, Reason], State)
            end,
            State3 = case Type of
                publish -> event({unpublish, SessId}, Pid, State2);
                listen -> event({unlisten, SessId}, Pid, State2)
            end,
            {noreply, restart_timer(State3)};
        not_found ->
            lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
            {noreply, State}
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

terminate(_Reason, #state{janus_id=JanusId, id=Id, room=Room}=State) ->    
    #{publish:=Publish, listen:=Listen} = Room,
    lists:foreach(
        fun(SessId) -> nkmedia_session:stop(SessId, room_destroyed) end,
        Publish ++ maps:keys(Listen)),
    send_event(destroyed, #{}, State),
    timer:sleep(100),
    case nkmedia_janus_op:destroy_room(JanusId, Id) of
        ok ->
            ?LLOG(info, "stopping, destroying room", [], State);
        {error, Error} ->
            ?LLOG(warning, "could not destroy room: ~p: ~p", [Id, Error], State)
    end.


% ===================================================================
%% Internal
%% ===================================================================

%% @private
get_janus(_SrvId, #{janus_id:=JanusId}) ->
    {ok, JanusId};

get_janus(SrvId, _Config) ->
    case SrvId:nkmedia_janus_get_mediaserver(SrvId) of
        {ok, JanusId} ->
            {ok, JanusId};
        {error, _Error} ->
            error
    end.


%% @private
event({publish, SessId}, Pid, #state{id=_Id, room=Room}=State) ->
    #{publish:=Publish} = Room,
    Publish2 = nklib_util:store_value(SessId, Publish),
    State2 = State#state{room=Room#{publish:=Publish2}},
    % {ok, _} = nkmedia_session:register(SessId, {room, Id, self()}),
    send_event(started_publisher, #{publisher=>SessId}, State),
    links_add(SessId, publish, Pid, State2);

event({unpublish, SessId}, _Pid, #state{id=_Id, room=Room}=State) ->
    #{publish:=Publish, listen:=Listeners} = Room,
    ToStop = [LId || {LId, PId} <- maps:to_list(Listeners), PId==SessId],
    lists:foreach(
        fun(LId) -> nkmedia_session:stop(LId, publisher_stopped) end,
        ToStop),
    Publish2 = Publish -- [SessId],
    State2 = State#state{room=Room#{publish:=Publish2}},
    % nkmedia_session:unregister(SessId, {room, Id, self()}),
    send_event(stopped_publisher, #{publisher=>SessId}, State),
    links_remove(SessId, State2);

event({listen, SessId, Publisher}, Pid, #state{id=_Id, room=Room}=State) ->
    #{listen:=Listen} = Room,
    Listen2 = maps:put(SessId, Publisher, Listen),
    State2 = State#state{room=Room#{listen:=Listen2}},
    % {ok, _} = nkmedia_session:register(SessId, {room, Id, self()}),
    send_event(started_listener, #{listener=>SessId, publisher=>Publisher}, State),
    links_add(SessId, listen, Pid, State2);

event({unlisten, SessId}, _Pid, #state{id=_Id, room=Room}=State) ->
    #{listen:=Listen} = Room,
    Listen2 = maps:remove(SessId, Listen),
    State2 = State#state{room=Room#{listen:=Listen2}},
    % nkmedia_session:unregister(SessId, {room, Id, self()}),
    send_event(stopped_listener, #{listener=>SessId}, State),
    links_remove(SessId, State2).


%% @private
restart_timer(#state{timer=Timer, room=Room}=State) ->
    nklib_util:cancel_timer(Timer),
    Time = 1000 * maps:get(timeout, Room, ?TIMEOUT),
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
            nkservice_util:call(Pid, Msg, Timeout);
        not_found -> 
            {error, not_found}
    end.


%% @private
links_add(Id, Data, Pid, #state{links=Links}=State) ->
    State#state{links=nklib_links:add(Id, Data, Pid, Links)}.


% %% @private
% links_get(Id, #state{links=Links}) ->
%     nklib_links:get(Id, Links).


%% @private
links_remove(Id, #state{links=Links}=State) ->
    State#state{links=nklib_links:remove(Id, Links)}.


%% @private
links_down(Pid, #state{links=Links}=State) ->
    case nklib_links:down(Pid, Links) of
        {ok, Id, Data, Links2} -> {ok, Id, Data, State#state{links=Links2}};
        not_found -> not_found
    end.


% %% @private
% links_fold(Fun, Acc, #state{links=Links}) ->
%     nklib_links:fold(Fun, Acc, Links).



%% @private
send_event(Type, Body, #state{srv_id=SrvId, id=Id, room=Room}) ->
    RegId = #reg_id{
        srv_id = SrvId,     
        class = <<"media">>, 
        subclass = <<"room">>,
        type = Type,
        obj_id = Id
    },
    nkservice_events:send(RegId, Body),
    #{publish:=Publish, listen:=Listen} = Room,
    Body2 = Body#{type=>Type, room=>Id},
    lists:foreach(
        fun(SessId) -> nkmedia_session:send_ext_event(SessId, room, Body2) end,
        Publish ++ maps:keys(Listen)).




