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

-export([start/2, stop/1, videocall/2, echo/2]).
-export([answer/2, reject/1]).
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


%% ===================================================================
%% Types
%% ===================================================================



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Starts a new session
-spec start(nkmedia:session_id(), nkmedia_janus:id()) ->
    {ok, pid()}.

start(SessId, JanusId) ->
    case nkmedia_janus_engine:get_conn(JanusId) of
        {ok, JanusPid} ->
            gen_server:start(?MODULE, {SessId, JanusId, JanusPid}, []);
        {error, Error} ->
            {error, Error}
    end.


%% @doc Stops a session
-spec stop(nkmedia:session_id()) ->
    ok.

stop(SessId) ->
    do_cast(SessId, stop).


%% @doc Starts a videocall inside the session.
%% The SDP offer for the remote party is returned.
-spec videocall(nkmedia_session:id(), nkmedia:offer()) ->
    {ok, nkmedia:offer()} | {error, term()}.

videocall(SessId, #{sdp:=SDP}) ->
    do_call(SessId, {videocall, SDP}).


%% @doc Starts a echo inside the session.
%% The SDP is returned.
-spec echo(nkmedia_session:id(), nkmedia:offer()) ->
    {ok, nkmedia:answer()} | {error, term()}.

echo(SessId, #{sdp:=SDP}) ->
    do_call(SessId, {echo, SDP}).


%% @doc Answers a videocall from the remote party.
%% The SDP answer for the calling party is returned.
-spec answer(nkmedia_session:id(), nkmedia:answer()) ->
    {ok, nkmedia:answer()} | {error, term()}.

answer(SessId, #{sdp:=SDP}) ->
    do_call(SessId, {answer, SDP}).


%% @doc Rejects a videocall
-spec reject(nkmedia_session:id()) ->
    ok | {error, term()}.

reject(SessId) ->
    do_cast(SessId, reject).



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

-type session() :: 
    #{
        janus_id_a => integer(),
        janus_id_b => integer(),
        handle_a => integer(),
        handle_b => integer()
    }.


-record(state, {
    id :: nkmedia_session:id(),
    janus_id :: nkmedia_janus:id(),
    janus_pid :: pid(),
    status = init :: init | start,
    type :: videocall,
    data = #{} :: session(),
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
    nklib_proc:put({?MODULE, SessId}),
    nklib_proc:put(?MODULE, SessId),
    {ok, status(start, State)}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call({videocall, SDP}, From, #state{status=start}=State) -> 
    case videocall_1(SDP, From, State) of
        {ok, State2} -> 
            {noreply, State2};
        {error, Error} ->
            ?LLOG(warning, "error calling janus for videocall: ~p", [Error], State),
            {stop, normal, State}
    end;

handle_call({videocall, _SDP}, _From, State) ->
    {reply, {error, already_attached}, State};

handle_call({echo, SDP}, From, #state{status=start}=State) -> 
    case echo_1(SDP, From, State) of
        {ok, State2} -> 
            {noreply, State2};
        {error, Error} ->
            ?LLOG(warning, "error calling janus for echo: ~p", [Error], State),
            {stop, normal, State}
    end;

handle_call({echo, _SDP}, _From, State) ->
    {reply, {error, already_attached}, State};

handle_call({answer, SDP}, From, #state{status=wait_videocall_5}=State) ->
    case videocall_5(SDP, State) of
        {ok, State2} -> 
            {noreply, State2#state{from=From}};
        {error, Error} ->
            ?LLOG(warning, "error calling janus for videocall: ~p", [Error], State),
            {stop, normal, State}
    end;

handle_call({answer, _SDP}, _From, State) ->
    {reply, {error, invalid_state}, State};

handle_call(Msg, _From, State) -> 
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {stop, unexpected_call, State}.
    

%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast(reject, #state{status=wait_videocall_5}=State) ->
    ?LLOG(info, "received reject", [], State),
    {stop, normal, State};

handle_cast({event, Id, Handle, Msg}, #state{status=wait_videocall_4}=State) ->
    #state{data=Data} = State,
    #{janus_id_b:=Id, janus_handle_b:=Handle} = Data,
    case videocall_4(Msg, State) of
        {ok, State2} ->
            {noreply, State2};
        {error, Error} ->
            ?LLOG(warning, "error in videocall_4: ~p", [Error], State),
            {stop, normal, State}
    end;

handle_cast({event, Id, Handle, Msg}, #state{status=wait_videocall_6}=State) ->
    #state{data=Data} = State,
    #{janus_id_a:=Id, janus_handle_a:=Handle} = Data,
    case videocall_6(Msg, State) of
        {ok, State2} ->
            {noreply, State2};
        {error, Error} ->
            ?LLOG(warning, "error in videocall_6: ~p", [Error], State),
            {stop, normal, State}
    end;

handle_cast({event, _Id, _Handle, stop}, State) ->
    ?LLOG(notice, "received stop from janus", [], State),
    {stop, normal, State};

handle_cast({event, _Id, _Handle, Msg}, State) ->
    ?LLOG(warning, "unexpected event: ~p", [event(Msg)], State),
    {noreply, State};

handle_cast(stop, State) ->
    ?LLOG(notice, "user stop", [], State),
    {stop, normal, State};

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {stop, unexpected_call, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

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

terminate(_Reason, #state{from=From, data=Data}=State) ->
    case maps:find(janus_id_a, Data) of
        {ok, IdA} -> destroy(IdA, State);
        error -> ok
    end,
    case maps:find(janus_id_b, Data) of
        {ok, IdB} -> destroy(IdB, State);
        error -> ok
    end,
    nklib_util:reply(From, {error, stopped}),
    ok.


% ===================================================================
%% Videocall
%% ===================================================================

%% @private First node registers
videocall_1(SDP, From, #state{data=Data}=State) ->
    case create(State) of
        {ok, Id} -> 
            case attach(Id, <<"videocall">>, State) of
                {ok, Handle} -> 
                    UserName = nklib_util:to_binary(Handle),
                    Body = #{request=>register, username=>UserName},
                    case message(Id, Handle, Body, State) of
                        {ok, #{<<"event">>:=<<"registered">>}, _} ->
                            Data2 = Data#{
                                janus_id_a => Id, 
                                janus_handle_a => Handle,
                                sdp_1_a => SDP
                            },
                            videocall_2(State#state{data=Data2, from=From});
                        {error, Error} ->
                            {error, {could_not_register, Error}}
                    end;
                {error, _} ->
                    {error, could_not_attach}
            end;
        {error, _} ->
            {error, could_not_create}
    end.


%% @private Second node registers
videocall_2(#state{data=Data}=State) ->
    case create(State) of
        {ok, Id} -> 
            case attach(Id, <<"videocall">>, State) of
                {ok, Handle} -> 
                    UserName = nklib_util:to_binary(Handle),
                    Body = #{request=>register, username=>UserName},
                    case message(Id, Handle, Body, State) of
                        {ok, #{<<"event">>:=<<"registered">>}, _} ->
                            Data2 = Data#{janus_id_b=>Id, janus_handle_b=>Handle},
                            videocall_3(State#state{data=Data2});
                        {error, Error} ->
                            {error, {could_not_register, Error}}
                    end;
                {error, _} ->
                    {error, could_not_attach}
            end;
        {error, _} ->
            {error, could_not_create}
    end.


%% @private We launch the call and wait for Juanus
videocall_3(#state{data=Data}=State) ->
    #{
        janus_id_a := Id, 
        janus_handle_a := Handle, 
        janus_handle_b := HandleB,
        sdp_1_a := SDP
    } = Data,
    Body = #{request=>call, username=>nklib_util:to_binary(HandleB)},
    Jsep = #{sdp=>SDP, type=>offer, trickle=>false},
    case message(Id, Handle, Body, Jsep, State) of
        {ok, #{<<"event">>:=<<"calling">>}, _} ->
            {ok, status(wait_videocall_4, State)};
        {error, Error} ->
            {error, {could_not_call, Error}}
    end.


%% @private Janus sends us the SDP for called party. We wait answer.
videocall_4(Msg, #state{from=From, data=Data}=State) ->
    case event(Msg) of
        {ok, <<"incomingcall">>, _, #{<<"sdp">>:=SDP}} ->
            gen_server:reply(From, {ok, #{sdp=>SDP}}),
            Data2 = Data#{sdp_2_a=>SDP},
            {ok, status(wait_videocall_5, State#state{data=Data2, from=undefined})};
        _ ->
            {error, {invalid_msg, Msg}}
    end.


%% @private. We receive answer from called party and wait Janus
videocall_5(SDP2B, #state{data=Data}=State) ->
    #{janus_id_b:=Id, janus_handle_b:=Handle} = Data,
    Body = #{request=>accept},
    Jsep = #{sdp=>SDP2B, type=>answer, trickle=>false},
    case message(Id, Handle, Body, Jsep, State) of
        {ok, #{<<"event">>:=<<"accepted">>}, _} ->
            Body2 = #{
                request => set,
                audio => true,
                video => true,
                bitrate => 0,
                record => true,
                filename => <<"/tmp/call_b">>
            },
            case message(Id, Handle, Body2, State) of
                {ok, #{<<"event">>:=<<"set">>}, _} ->
                    Data2 = Data#{sdp_2_b=>SDP2B},
                    {ok, status(wait_videocall_6, State#state{data=Data2})};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @private Janus send us the answer for caller
videocall_6(Msg, #state{from=From, data=Data}=State) ->
    #{janus_id_a:=Id, janus_handle_a:=Handle} = Data,
    case event(Msg) of
        {ok, <<"accepted">>, _, #{<<"sdp">>:=SDP}} -> 
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
                {ok, #{<<"event">>:=<<"set">>}, _} ->
                    Data2 = Data#{sdp_1_b=>SDP},
                    {ok, status(videocall, State#state{data=Data2, from=undefined})};
                {error, Error} ->
                    {error, Error}
            end;
        _ ->
            {error, {invalid_msg, Msg}}
    end.




% ===================================================================
%% Echo
%% ===================================================================

%% @private Echo plugin
echo_1(SDP, From, State) ->
    case create(State) of
        {ok, Id} -> 
            case attach(Id, <<"echotest">>, State) of
                {ok, Handle} -> 
                    Body = #{
                        audio => true, 
                        video => true, 
                        record => true,
                        filename => <<"/tmp/1">>
                    },
                    Jsep = #{sdp=>SDP, type=>offer, trickle=>false},
                    case message(Id, Handle, Body, Jsep, State) of
                        {ok, <<"ok">>, #{<<"sdp">>:=SDP2}} ->
                            nklib_util:reply(From, {ok, #{sdp=>SDP2}}),
                            {ok, status(echo, State)};
                        {error, Error} ->
                            {error, {could_not_register, Error}}
                    end;
                {error, _} ->
                    {error, could_not_attach}
            end;
        {error, _} ->
            {error, could_not_create}
    end.


% ===================================================================
%% Internal
%% ===================================================================



%% @private
create(#state{janus_pid=Pid}) ->
    nkmedia_janus_client:create(Pid, ?MODULE, {?MODULE, self()}).


%% @private
attach(SessId, Plugin, #state{janus_pid=Pid}) ->
    nkmedia_janus_client:attach(Pid, SessId, Plugin).


%% @private
message(SessId, Handle, Body, State) ->
    message(SessId, Handle, Body, #{}, State).


%% @private
message(SessId, Handle, Body, Jsep, #state{janus_pid=Pid}) ->
    case nkmedia_janus_client:message(Pid, SessId, Handle, Body, Jsep) of
        {ok, #{<<"data">>:=Data}, Jsep2} ->
            #{<<"result">>:=Result} = Data,
            {ok, Result, Jsep2};
        {error, Error} ->
            {error, Error}
    end.


%% @private
destroy(SessId, #state{janus_pid=Pid}) ->
    nkmedia_janus_client:destroy(Pid, SessId).


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
            {ok, Event, Result, Jsep};
        _  ->


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
        echo -> ?CALL_TIMEOUT
    end,
    NewTimer = erlang:start_timer(1000*Time, self(), status_timeout),
    State#state{timer=NewTimer}.



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

