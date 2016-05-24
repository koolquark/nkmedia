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


-module(nkmedia_janus_session).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start/2, stop/1, videocall/2, videocall_answer/2, echo/2]).
-export([publisher/3, listener/3, listener_answer/2]).
-export([get_all/0, janus_event/4]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Janus Session ~s (~s) "++Txt, 
               [State#state.id, State#state.type | Args])).

-include("nkmedia.hrl").


-define(OP_TIMEOUT, 50).
-define(RING_TIMEOUT, 50).
-define(CALL_TIMEOUT, 4*60*60).
-define(KEEPALIVE, 20).

%% ===================================================================
%% Types
%% ===================================================================

-type session_id() :: nkmedia:session_id().

-type room_user_id() :: integer().


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Starts a new session
-spec start(session_id(), nkmedia_janus:id()) ->
    {ok, pid()}.

start(SessId, JanusId) ->
    case nkmedia_janus_engine:get_conn(JanusId) of
        {ok, JanusPid} ->
            gen_server:start(?MODULE, {SessId, JanusId, JanusPid}, []);
        {error, Error} ->
            {error, Error}
    end.


%% @doc Stops a session
-spec stop(session_id()) ->
    ok.

stop(SessId) ->
    do_cast(SessId, stop).


%% @doc Starts a videocall inside the session.
%% The SDP offer for the remote party is returned.
-spec videocall(nkmedia_session:id(), nkmedia:offer()) ->
    {ok, nkmedia:offer()} | {error, term()}.

videocall(SessId, Offer) ->
    do_call(SessId, {videocall, Offer}).


%% @doc Answers a videocall from the remote party.
%% The SDP answer for the calling party is returned.
-spec videocall_answer(nkmedia_session:id(), nkmedia:answer()) ->
    {ok, nkmedia:answer()} | {error, term()}.

videocall_answer(SessId, Answer) ->
    do_call(SessId, {videocall_answer, Answer}).


%% @doc Starts a echo inside the session.
%% The SDP is returned.
-spec echo(nkmedia_session:id(), nkmedia:offer()) ->
    {ok, nkmedia:answer()} | {error, term()}.

echo(SessId, Offer) ->
    do_call(SessId, {echo, Offer}).


%% @doc Starts a conection to a videoroom.
%% caller_id is taked from offer.
-spec publisher(session_id(), integer(), nkmedia:offer()) ->
    {ok, room_user_id(), nkmedia:answer()} | {error, term()}.

publisher(SessId, Room, Offer) ->
    do_call(SessId, {publisher, Room, Offer}).


%% @doc Starts a conection to a videoroom
-spec listener(session_id(), integer(), room_user_id()) ->
    {ok, nkmedia:offer()} | {error, term()}.

listener(SessId, Room, UserId) ->
    do_call(SessId, {listener, Room, UserId}).


%% @doc Answers a listener
-spec listener_answer(session_id(), nkmedia:answer()) ->
    ok | {error, term()}.

listener_answer(SessId, Answer) ->
    do_call(SessId, {listener_answer, Answer}).


%% @private
-spec get_all() ->
    [{term(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).



%% ===================================================================
%% Internal
%% ===================================================================

janus_event({?MODULE, Pid}, JanusSessId, JanusHandle, Msg) ->
    gen_server:cast(Pid, {event, JanusSessId, JanusHandle, Msg}).



% ===================================================================
%% gen_server behaviour
%% ===================================================================

% -type session() :: 
%     #{
%         janus_id => integer(),
%         janus_handle => integer(),
%         janus_id_2 => integer(),
%         janus_handle_2 => integer(),
%     }.


-record(state, {
    id :: nkmedia_session:id(),
    janus_id :: nkmedia_janus:id(),
    janus_pid :: pid(),
    status = init :: init | start | videocall | echo | videoroom,
    type :: videocall,
    session_id :: integer(),
    handle_id :: integer(),
    session_id2 :: integer(),
    handle_id2 :: integer(),
    % data = #{} :: session(),
    room_id :: integer(),
    from :: {pid(), term()},
    timer :: reference()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()}.

init({SessId, JanusId, JanusPid}) ->
    State = #state{
        id = SessId, 
        janus_id = JanusId, 
        janus_pid = JanusPid
    },
    true = nklib_proc:reg({?MODULE, SessId}),
    nklib_proc:put(?MODULE, SessId),

    self() ! send_keepalive,
    {ok, status(start, State)}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call({videocall, Offer}, From, #state{status=start}=State) -> 
    result(videocall_1(Offer, From, State), State);

handle_call({videocall_answer, Answer}, From, #state{status=wait_videocall_5}=State) ->
    result(videocall_5(Answer, From, State), State);

handle_call({echo, Offer}, _From, #state{status=start}=State) -> 
    result(echo_1(Offer, State), State);

handle_call({publisher, Room, Offer}, _From, #state{status=start}=State) -> 
    result(publisher_1(Room, Offer, State), State);

handle_call({listener, Room, UserId}, _From, #state{status=start}=State) -> 
    result(listener_1(Room, UserId, State), State);

handle_call({listener_answer, Answer}, _From, #state{status=wait_listener_2}=State) -> 
    result(listener_2(Answer, State), State);

handle_call(_Msg, _From, State) -> 
    result({reply, {error, invalid_state}, State}, State).
    

%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({event, Id, Handle, Msg}, #state{status=wait_videocall_4}=State) ->
    #state{session_id2=Id, handle_id2=Handle} = State,
    result(videocall_4(Msg, State), State);

handle_cast({event, Id, Handle, Msg}, #state{status=wait_videocall_6}=State) ->
    #state{session_id=Id, handle_id=Handle} = State,
    result(videocall_6(Msg, State), State);

handle_cast({event, _Id, _Handle, stop}, State) ->
    ?LLOG(notice, "received stop from janus", [], State),
    {stop, normal, State};

handle_cast({event, _Id, _Handle, Msg}, State) ->
    case Msg of
        {data, #{<<"echotest">>:=<<"event">>, <<"result">>:=<<"done">>}} ->
            ok;
        _ ->
            ?LLOG(notice, "unexpected event: ~p", [event(Msg)], State)
    end,
    result({noreply, State}, State);

handle_cast(stop, State) ->
    ?LLOG(info, "user stop", [], State),
    {stop, normal, State};

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {stop, unexpected_call, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info(send_keepalive, #state{session_id=Id1, session_id2=Id2}=State) ->
    case is_integer(Id1) of
        true -> keepalive(Id1, State);
        false -> ok
    end,
    case is_integer(Id2) of
        true -> keepalive(Id2, State);
        false -> ok
    end,
    erlang:send_after(1000*?KEEPALIVE, self(), send_keepalive),
    result({noreply, State}, State);

handle_info({timeout, _, status_timeout}, State) ->
    ?LLOG(info, "status timeout", [], State),
    {stop, normal, State};

handle_info(Msg, State) -> 
    lager:warning("Module ~p received unexpected info ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(_Reason, State) ->
    #state{from=From, session_id=Id, session_id2=Id2} = State,
    case Id of
        undefined -> ok;
        _ -> destroy(Id, State)
    end,
    case Id2 of
        undefined -> ok;
        _ -> destroy(Id2, State)
    end,
    nklib_util:reply(From, {error, stopped}),
    ok.


% ===================================================================
%% Videocall
%% ===================================================================

%% @private First node registers
videocall_1(#{sdp:=SDP}, From, State) ->
    case create(State) of
        {ok, Id} -> 
            case attach(Id, videocall, State) of
                {ok, Handle} -> 
                    UserName = nklib_util:to_binary(Handle),
                    Body = #{request=>register, username=>UserName},
                    case message(Id, Handle, Body, State) of
                        {ok, #{<<"result">>:=#{<<"event">>:=<<"registered">>}}, _} ->
                            State2 = State#state{
                                session_id = Id,
                                handle_id = Handle,
                                from = From
                            },
                            videocall_2(SDP, State2);
                        {error, Error} ->
                            {error, {videocall_could_not_register, Error}, State}
                    end;
                {error, Error} ->
                    {error, {could_not_attach, Error}, State}
            end;
        {error, Error} ->
            {error, {could_not_create, Error}, State}
    end.


%% @private Second node registers
videocall_2(SDP, State) ->
    case create(State) of
        {ok, Id2} -> 
            case attach(Id2, <<"videocall">>, State) of
                {ok, Handle2} -> 
                    UserName2 = nklib_util:to_binary(Handle2),
                    Body = #{request=>register, username=>UserName2},
                    case message(Id2, Handle2, Body, State) of
                        {ok, #{<<"result">>:=#{<<"event">>:=<<"registered">>}}, _} ->
                            State2 = State#state{
                                session_id2 = Id2,
                                handle_id2 = Handle2
                            },
                            videocall_3(SDP, State2);
                        {error, Error} ->
                            {error, {videocall_could_not_register, Error}}
                    end;
                {error, Error} ->
                    {error, {could_not_attach, Error}}
            end;
        {error, Error} ->
            {error, {could_not_create, Error}}
    end.


%% @private We launch the call and wait for Juanus
videocall_3(SDP, State) ->
    #state{
        session_id = Id, 
        handle_id = Handle, 
        handle_id2 = Handle2
    } = State,
    Body = #{request=>call, username=>nklib_util:to_binary(Handle2)},
    Jsep = #{sdp=>SDP, type=>offer, trickle=>false},
    case message(Id, Handle, Body, Jsep, State) of
        {ok, #{<<"result">>:=#{<<"event">>:=<<"calling">>}}, _} ->
            {noreply, status(wait_videocall_4, State)};
        {error, Error} ->
            {error, {videocall_could_not_call, Error}}
    end.


%% @private Janus sends us the SDP for called party. We wait answer.
videocall_4(Msg, #state{from=From}=State) ->
    case event(Msg) of
        {event, <<"incomingcall">>, _, #{<<"sdp">>:=SDP}} ->
            gen_server:reply(From, {ok, #{sdp=>SDP}}),
            State2 = State#state{from=undefined},
            {noreply, status(wait_videocall_5, State2)};
        Other ->
            {error, {videocall_invalid_msg, Other}}
    end.


%% @private. We receive answer from called party and wait Janus
videocall_5(#{sdp:=SDP}, From, State) ->
    #state{session_id2=Id, handle_id2=Handle} = State,
    Body = #{request=>accept},
    Jsep = #{sdp=>SDP, type=>answer, trickle=>false},
    case message(Id, Handle, Body, Jsep, State) of
        {ok, #{<<"result">>:=#{<<"event">>:=<<"accepted">>}}, _} ->
            Body2 = #{
                request => set,
                audio => true,
                video => true,
                bitrate => 0,
                record => true,
                filename => <<"/tmp/call_b">>
            },
            case message(Id, Handle, Body2, State) of
                {ok, #{<<"result">>:=#{<<"event">>:=<<"set">>}}, _} ->
                    State2 = State#state{from=From},
                    {noreply, status(wait_videocall_6, State2)};
                {error, Error} ->
                    {error, {videocall_set_error, Error}}
            end;
        Res ->
            {error, {videocall_invalid_mesg, Res}}
    end.


%% @private Janus send us the answer for caller
videocall_6(Msg, #state{from=From}=State) ->
    #state{session_id=Id, handle_id=Handle} = State,
    case event(Msg) of
        {event, <<"accepted">>, _, #{<<"sdp">>:=SDP}} -> 
            gen_server:reply(From, {ok, #{sdp=>SDP}}),
            Body = #{
                request => set,
                audio => true,
                video => true,
                bitrate => 0,
                record => true,
                filename => <<"/tmp/call_a">>
            },
            case message(Id, Handle, Body, State) of
                {ok, #{<<"result">>:=#{<<"event">>:=<<"set">>}}, _} ->
                    State2 = State#state{from=undefined},
                    {noreply, status(videocall, State2)};
                {error, Error} ->
                    {error, {videocall_set_error, Error}}
            end;
        Other ->
            {error, {invalid_msg, Other}}
    end.




% ===================================================================
%% Echo
%% ===================================================================

%% @private Echo plugin
echo_1(#{sdp:=SDP}, State) ->
    case create(State) of
        {ok, Id} -> 
            case attach(Id, echotest, State) of
                {ok, Handle} -> 
                    Body = #{
                        audio => true, 
                        video => true, 
                        record => true,
                        filename => <<"/tmp/1">>
                    },
                    Jsep = #{sdp=>SDP, type=>offer, trickle=>false},
                    case message(Id, Handle, Body, Jsep, State) of
                        {ok, #{<<"result">>:=<<"ok">>}, #{<<"sdp">>:=SDP2}} ->
                            State2 = State#state{session_id=Id, handle_id=Handle},
                            {reply, {ok, #{sdp=>SDP2}}, status(echo, State2)};
                        {error, Error} ->
                            {error, {could_not_register, Error}}
                    end;
                {error, Error} ->
                    {error, {could_not_attach, Error}}
            end;
        {error, Error} ->
            {error, {could_not_create, Error}}
    end.


% ===================================================================
%% Publisher
%% ===================================================================

%% @private Create session and join
publisher_1(Room, #{sdp:=SDP}=Offer, State) ->
    case create(State) of
        {ok, Id} -> 
            case attach(Id, videoroom, State) of
                {ok, Handle} -> 
                    Display = maps:get(caller_id, Offer, <<"undefined">>),
                    Body = #{
                        request => join, 
                        room => Room,
                        ptype => publisher,
                        display => nklib_util:to_binary(Display)
                    },
                    case message(Id, Handle, Body, State) of
                        {ok, #{<<"videoroom">>:=<<"joined">>, <<"id">>:=UserId}, _} ->
                            State2 = State#state{session_id=Id, handle_id=Handle},
                            publisher_2(UserId, SDP, State2);
                        {error, Error} ->
                            {error, {could_not_join, Error}}
                    end;
                {error, _} ->
                    {error, could_not_attach}
            end;
        {error, _} ->
            {error, could_not_create}
    end.


%% @private
publisher_2(UserId, SDP_A, State) ->
    #state{session_id=Id, handle_id=Handle} = State,
    Body = #{
        request => configure,
        audio => true,
        video => true
    },
    Jsep = #{sdp=>SDP_A, type=>offer, trickle=>false},
    case message(Id, Handle, Body, Jsep, State) of
        {ok, #{<<"configured">>:=<<"ok">>}, #{<<"sdp">>:=SDP_B}} ->
            {reply, {ok, UserId, #{sdp=>SDP_B}}, status(publisher, State)};
        {error, Error} ->
            {error, {could_not_join, Error}}
    end.




% ===================================================================
%% Listener
%% ===================================================================


%% @private Create session and join
listener_1(Room, UserId, State) ->
    case create(State) of
        {ok, Id} -> 
            case attach(Id, videoroom, State) of
                {ok, Handle} -> 
                    Body = #{
                        request => join, 
                        room => Room,
                        ptype => listener,
                        feed => UserId
                    },
                    case message(Id, Handle, Body, State) of
                        {ok, #{<<"videoroom">>:=<<"attached">>}, #{<<"sdp">>:=SDP}} ->
                            State2 = State#state{
                                session_id = Id, 
                                handle_id = Handle,
                                room_id = Room
                            },
                            {reply, {ok, #{sdp=>SDP}}, status(wait_listener_2, State2)};
                        {error, Error} ->
                            {error, {could_not_join, Error}}
                    end;
                {error, _} ->
                    {error, could_not_attach}
            end;
        {error, _} ->
            {error, could_not_create}
    end.


%% @private Caller answers
listener_2(#{sdp:=SDP}, State) ->
    #state{session_id=Id, handle_id=Handle, room_id=Room} = State,
    Body = #{request=>start, room=>Room},
    Jsep = #{sdp=>SDP, type=>answer, trickle=>false},
    case message(Id, Handle, Body, Jsep, State) of
        {ok, #{<<"started">>:=<<"ok">>}, _} ->
            {reply, ok, status(listener, State)};
        {error, Error} ->
            {error, {could_not_start, Error}}
    end.








% ===================================================================
%% Internal
%% ===================================================================



%% @private
create(#state{janus_pid=Pid}) ->
    nkmedia_janus_client:create(Pid, ?MODULE, {?MODULE, self()}).


%% @private
attach(SessId, Plugin, #state{janus_pid=Pid}) ->
    nkmedia_janus_client:attach(Pid, SessId, nklib_util:to_binary(Plugin)).


%% @private
message(SessId, Handle, Body, State) ->
    message(SessId, Handle, Body, #{}, State).


%% @private
message(SessId, Handle, Body, Jsep, #state{janus_pid=Pid}) ->
    case nkmedia_janus_client:message(Pid, SessId, Handle, Body, Jsep) of
        {ok, #{<<"data">>:=Data}, Jsep2} ->
            {ok, Data, Jsep2};
        {error, Error} ->
            {error, Error}
    end.


%% @private
destroy(SessId, #state{janus_pid=Pid}) ->
    nkmedia_janus_client:destroy(Pid, SessId).


%% @private
keepalive(SessId, #state{janus_pid=Pid}) ->
    nkmedia_janus_client:keepalive(Pid, SessId).


%% @private
event(Msg) ->
    Jsep = maps:get(<<"jsep">>, Msg, #{}),
    case Msg of
        #{
            <<"plugindata">> := #{
                <<"data">> := #{
                    <<"result">> := #{<<"event">> := Event} = Result
                }
            }
        } ->
            {event, Event, Result, Jsep};
        #{<<"plugindata">> := #{<<"data">> := Data}} ->
            {data, Data};
        _ ->
            {error, {invalid_msg, Msg}}
    end.


%% @private
status(NewStatus, #state{}=State) ->
    ?LLOG(info, "status changed to ~p", [NewStatus], State),
    restart_timer(State#state{status=NewStatus}).


%% @private
restart_timer(#state{status=Status, timer=Timer}=State) ->
    nklib_util:cancel_timer(Timer),
    Time = case Status of
        start -> ?OP_TIMEOUT;
        wait_videocall_4 -> ?OP_TIMEOUT;
        wait_videocall_5 -> ?RING_TIMEOUT;
        wait_videocall_6 -> ?OP_TIMEOUT;
        videocall -> ?CALL_TIMEOUT;
        wait_listener_2 -> ?RING_TIMEOUT;
        publisher -> ?CALL_TIMEOUT;
        listener -> ?CALL_TIMEOUT;
        echo -> ?CALL_TIMEOUT
    end,
    NewTimer = erlang:start_timer(1000*Time, self(), status_timeout),
    State#state{timer=NewTimer}.


%% @private
result({noreply, #state{status=Status}=State}, _) 
    when Status==videocall; Status==publisher; Status==listener; Status==echo ->
    {noreply, State, hibernate};

result({noreply, State}, _) ->
    {noreply, State};

result({reply, Reply, #state{status=Status}=State}, _) 
    when Status==videocall; Status==publisher; Status==listener; Status==echo ->
    {reply, Reply, State, hibernate};

result({reply, Reply, State}, _) ->
    {reply, Reply, State};

result({error, Error}, State) ->
    ?LLOG(warning, "error calling op: ~p", [Error], State),
    {stop, normal, State}.



%% @private
find(Pid) when is_pid(Pid) ->
    {ok, Pid};

find(SessId) ->
    lager:warning("SESSID: ~p", [SessId]),
    case nklib_proc:values({?MODULE, SessId}) of
        [{undefined, Pid}] -> {ok, Pid};
        [] -> not_found
    end.


%% @private
do_call(SessId, Msg) ->
    do_call(SessId, Msg, 1000*?RING_TIMEOUT).


%% @private
do_call(SessId, Msg, Timeout) ->
    case find(SessId) of
        {ok, Pid} -> nklib_util:call(Pid, Msg, Timeout);
        not_found -> {error, session_not_found}
    end.


%% @private
do_cast(SessId, Msg) ->
    case find(SessId) of
        {ok, Pid} -> gen_server:cast(Pid, Msg);
        not_found -> {error, session_not_found}
    end.

