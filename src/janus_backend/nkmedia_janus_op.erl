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


-module(nkmedia_janus_op).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start/1, stop/1, videocall/4, echo/4, play/4]).
-export([list_rooms/1, create_room/3, destroy_room/2]).
-export([publish/5, unpublish/1]).
-export([listen/5, listen_switch/3, unlisten/1]).
-export([from_sip/2, to_sip/2]).
-export([sip_registered/2, sip_offer/2]).
-export([answer/2]).
-export([get_all/0, stop_all/0, janus_event/4]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Janus Session ~s (~p) "++Txt, 
               [State#state.id, State#state.status | Args])).

-include("nkmedia.hrl").


-define(OP_TIMEOUT, 50).
-define(RING_TIMEOUT, 50).
-define(CALL_TIMEOUT, 4*60*60).
-define(KEEPALIVE, 20).

%% ===================================================================
%% Types
%% ===================================================================

-type id() :: binary().

-type room() :: binary().

-type play() :: binary().

-type session() :: nkmedia_session:id().

-type room_opts() ::
    #{
        audiocodec => opus | isac32 | isac16 | pcmu | pcma,
        videocodec => vp8 | vp9 | h264,
        description => binary(),
        bitrate => integer(),
        publishers => integer(),
        record => boolean(),
        rec_dir => binary()
    }.

-type media_opts() ::
    #{
        audio => boolean(),
        video => boolean(),
        data => boolean(),
        bitrate => integer(),
        record => boolean(),
        filename => binary(),       % Without dir for publish, with dir for others
        info => term()
    }.

-type listen_opts() ::
    #{
        audio => boolean(),
        video => boolean(),
        data => boolean()
    }.


-type status() ::
    wait | videocall | echo | publish | listen.



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Starts a new session
-spec start(nkmedia_janus:id()) ->
    {ok, id(), pid()}.

start(JanusId) ->
    Id = nklib_util:uuid_4122(),
    {ok, Pid} = gen_server:start(?MODULE, {Id, JanusId, self()}, []),
    {ok, Id, Pid}.


%% @doc Stops a session
-spec stop(id()|pid()) ->
    ok.

stop(Id) ->
    do_cast(Id, stop).


%% @doc Stops a session
-spec stop_all() ->
    ok.

stop_all() ->
    lists:foreach(fun({_Id, Pid}) -> stop(Pid) end, get_all()).



%% @doc Starts a videocall inside the session.
%% The SDP offer for the remote party is returned.
%% You must call answer/2
-spec videocall(id()|pid(), session(), nkmedia:offer(), media_opts()) ->
    {ok, nkmedia:offer()} | {error, term()}.

videocall(Id, Session, Offer, Opts) ->
    do_call(Id, {videocall, Session, Offer, Opts}).


%% @doc Starts a echo inside the session.
%% The SDP is returned.
-spec echo(id()|pid(), session(), nkmedia:offer(), media_opts()) ->
    {ok, nkmedia:answer()} | {error, term()}.

echo(Id, Session, Offer, Opts) ->
    do_call(Id, {echo, Session, Offer, Opts}).


%% @doc Starts playing a file
%% The offer SDP is returned.
-spec play(id()|pid(), play(), session(), media_opts()) ->
    {ok, nkmedia:offer()} | {error, term()}.

play(Id, Play, Session, Opts) ->
    do_call(Id, {play, Session, Play, Opts}).


%% @doc List all videorooms
-spec list_rooms(id()|pid()) ->
    {ok, list()} | {error, term()}.

list_rooms(Id) ->
    do_call(Id, list_rooms).


%% @doc Creates a new videoroom
-spec create_room(id()|pid(), room(), room_opts()) ->
    {ok, room()} | {error, term()}.

create_room(Id, Room, Opts) ->
    do_call(Id, {create_room, to_room(Room), Opts}).


%% @doc Destroys a videoroom
-spec destroy_room(id()|pid(), room()) ->
    ok | {error, term()}.

destroy_room(Id, Room) ->
    do_call(Id, {destroy_room, to_room(Room)}).


%% @doc Starts a conection to a videoroom.
%% caller_id is taked from offer.
-spec publish(id()|pid(), room(), session(), nkmedia:offer(), media_opts()) ->
    {ok, nkmedia:answer()} | {error, term()}.

publish(Id, Room, Session, Offer, Opts) when is_binary(Session) ->
    do_call(Id, {publish, to_room(Room), Session, Offer, Opts}).


%% @doc Starts a conection to a videoroom.
%% caller_id is taked from offer.
-spec unpublish(id()|pid()) ->
    ok | {error, term()}.

unpublish(Id) ->
    do_call(Id, unpublish).


%% @doc Starts a conection to a videoroom
-spec listen(id()|pid(), room(), session(), session(), listen_opts()) ->
    {ok, nkmedia:offer()} | {error, term()}.

listen(Id, Room, Session, Listen, Opts) when is_binary(Session), is_binary(Listen) ->
    do_call(Id, {listen, to_room(Room), Session, Listen, Opts}).


%% @doc Answers a listen
-spec listen_switch(id()|pid(), session(), listen_opts()) ->
    ok | {error, term()}.

listen_switch(Id, Listen, Opts) ->
    Listen2 = nklib_util:to_binary(Listen),
    do_call(Id, {listen_switch, Listen2, Opts}).


%% @doc
-spec unlisten(id()|pid()) ->
    ok | {error, term()}.

unlisten(Id) ->
    do_call(Id, unlisten).


%% @doc Receives a SIP offer, generates a WebRTC offer
%% You must call answer/2 when you have the WebRTC answer
-spec from_sip(id()|pid(), nkmedia:offer()) ->
    {ok, nkmedia:offer()} | {error, term()}.

from_sip(Id, Offer) ->
    do_call(Id, {from_sip, Offer}).


%% @doc Receives an WebRTC offer, generates a SIP offer
%% You must call answer/2 when you have the SIP answer
-spec to_sip(id()|pid(), nkmedia:offer()) ->
    {ok, nkmedia:offer()} | {error, term()}.

to_sip(Id, Offer) ->
    do_call(Id, {to_sip, Offer}).


%% @doc Answers a pending request
%% Get Janus' answer (except for listen and play)
-spec answer(id()|pid(), nkmedia:answer()) ->
    ok | {ok, nkmedia:answer()} | {error, term()}.

answer(Id, Answer) ->
    do_call(Id, {answer, Answer}).


%% @private
-spec get_all() ->
    [{term(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).



%% ===================================================================
%% Internal
%% ===================================================================

janus_event({?MODULE, Pid}, JanusSessId, JanusHandle, Msg) ->
    % lager:error("Event: ~p", [Msg]),
    gen_server:cast(Pid, {event, JanusSessId, JanusHandle, Msg}).


%% @private
-spec sip_registered(id(), nklib:uri()) ->
    boolean() | {error, term()}.

sip_registered(Id, Contact) ->
    do_call(Id, {sip_registered, Contact}).


%% @private
-spec sip_offer(id(), nkmedia:offer()) ->
    ok | {error, term()}.

sip_offer(Id, Offer) ->
    do_call(Id, {sip_offer, Offer}).



%% ===================================================================
%% gen_server behaviour
%% ===================================================================


-record(state, {
    id :: id(),
    janus_id :: nkmedia_janus:id(),
    mon :: reference(),
    status = init :: status() | init,
    session_id :: integer(),
    handle_id :: integer(),
    handle_id2 :: integer(),
    room :: room(),
    room_mon :: reference(),
    session ::session(),
    sip_handle :: term(),
    sip_dialog :: term(),
    sip_contact :: nklib:uri(),
    offer :: nkmedia:offer(),
    from :: {pid(), term()},
    opts :: map(),
    timer :: reference()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()}.

init({Id, JanusId, CallerPid}) ->
    {ok, Pid} = nkmedia_janus_engine:get_conn(JanusId),
    {ok, SessId} = nkmedia_janus_client:create(Pid, ?MODULE, {?MODULE, self()}),
    State = #state{
        id = Id, 
        janus_id = JanusId, 
        mon = monitor(process, CallerPid),
        session_id = SessId
    },
    true = nklib_proc:reg({?MODULE, Id}),
    nklib_proc:put(?MODULE, Id),
    self() ! send_keepalive,
    {ok, status(wait, State)}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call({echo, Session, Offer, Opts}, _From, #state{status=wait}=State) -> 
    Opts2 = case Opts of
        #{filename:=File} -> 
            Opts#{filename:=nklib_util:to_binary(File)};
        _ ->
            Opts#{filename=><<"/tmp/echo_", Session/binary>>}
    end,
    do_echo(Offer, State#state{session=Session, opts=Opts2});

handle_call({play, Session, File, Opts}, _From, #state{status=wait}=State) -> 
    do_play(File, State#state{session=Session, opts=Opts});

handle_call({videocall, Session, Offer, Opts}, From, #state{status=wait}=State) -> 
    Opts2 = case Opts of
        #{filename:=File} -> 
            Opts#{filename:=<<(nklib_util:to_binary(File))/binary, "_a">>};
        _ ->
            Opts#{filename=><<"/tmp/call_", Session/binary, "_a">>}
    end,
    do_videocall(Offer, From, State#state{session=Session, opts=Opts2});

handle_call(list_rooms, _From, #state{status=wait}=State) -> 
    do_list_rooms(State);

handle_call({create_room, Room, Opts}, _From, #state{status=wait}=State) -> 
    do_create_room(State#state{room=Room, opts=Opts});

handle_call({destroy_room, Room}, _From, #state{status=wait}=State) -> 
    do_destroy_room(State#state{room=Room});

handle_call({publish, Room, Session, Offer, Opts}, _From, #state{status=wait}=State) -> 
    Opts2 = case Opts of
        #{filename:=File} -> 
            Opts#{filename:=nklib_util:to_binary(File)};
        _ ->
            Opts#{filename=><<"publish_", Session/binary>>}
    end,
    do_publish(Offer, State#state{session=Session, room=Room, opts=Opts2});

handle_call(upublish, _From, #state{status=publish}=State) -> 
    do_unpublish(State);

handle_call({listen, Room, Session, Listen, Opts}, _From, #state{status=wait}=State) -> 
    do_listen(Listen, State#state{session=Session, room=Room, opts=Opts});

handle_call({listen_switch, Listen, Opts}, _From, #state{status=listen}=State) -> 
    do_listen_switch(Listen, State#state{opts=Opts});

handle_call(unlisten, _From, #state{status=listen}=State) -> 
    do_unlisten(State);

handle_call({from_sip, Offer}, From, #state{status=wait}=State) ->
    sip_register(from_sip, State#state{from=From, offer=Offer});

handle_call({to_sip, Offer}, From, #state{status=wait}=State) ->
    sip_register(to_sip, State#state{from=From, offer=Offer});

handle_call({sip_registered, Contact}, _From, #state{status=Status}=State) ->
    case Status of
        {wait, to_sip} ->
            reply(true, State#state{sip_contact=Contact});
        {wait, from_sip} ->
            reply(true, State#state{sip_contact=Contact});
        sip ->
            reply(true, State);
        _ ->
            reply(false, State)
    end;

handle_call({sip_offer, Handle, Dialog, Offer}, From, 
            #state{status={wait, sip_offer}}=State) ->
    #state{from=From} = State,
    gen_server:reply(From, {ok, Offer}),
    State2 = State#state{sip_handle=Handle, sip_dialog=Dialog, from=undefined},
    reply(ok, status({wait, to_sip_answer}, State2));

handle_call({answer, #{sdp:=SDP}=Answer}, From, #state{status=Status}=State) ->
    case Status of
        {wait, videocall_answer} ->
            do_videocall_answer(Answer, From, State);
        {wait, listen_answer} ->
            do_listen_answer(Answer, State);
        {wait, play_answer} ->
            do_play_answer(Answer, State);
        {wait, from_sip_answer_2} ->
            do_from_sip_answer(Answer, From, State);
        {wait, to_sip_answer} ->
            #state{sip_handle=Handle} = State,
            case nksip_request:reply(Handle, {answer, SDP}) of
                ok ->
                    noreply(status({wait, to_sip_reply}, State#state{from=From}));
                {error, Error} ->
                    reply_error({sip_error, Error}, State)
            end
    end;

   
handle_call(_Msg, _From, State) -> 
    reply({error, invalid_state}, State).
    

%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({event, _Id, _Handle, stop}, State) ->
    ?LLOG(notice, "received stop from janus", [], State),
    {stop, normal, State};

handle_cast({event, Id, Handle, Msg}, State) ->
    case parse_event(Msg) of
        error ->
            ?LLOG(warning, "unrecognized event: ~p", [Msg], State),
            noreply(State);
        {data, #{<<"echotest">>:=<<"event">>, <<"result">>:=<<"done">>}} ->    
            noreply(State);
        Event ->
            do_event(Id, Handle, Event, State)
    end;

handle_cast({invite, {ok, Body}}, #state{status={wait, from_sip_invite}}=State) ->
    #state{from=From} =State,
    gen_server:reply(From, {ok, #{sdp=>nksip_sdp:unparse(Body)}}),
    noreply(status(sdp, State#state{from=undefined}));

handle_cast({invite, {error, Error}}, #state{status={wait, from_sip_invite}}=State) ->
    #state{from=From} =State,
    ?LLOG(notice, "invite error: ~p", [Error], State),
    gen_server:reply(From, {error, Error}),
    {stop, normal, State#state{from=undefined}};

handle_cast(stop, State) ->
    ?LLOG(info, "user stop", [], State),
    {stop, normal, State};

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {stop, unexpected_call, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info(send_keepalive, State) ->
    keepalive(State),
    erlang:send_after(1000*?KEEPALIVE, self(), send_keepalive),
    noreply(State);

handle_info({timeout, _, status_timeout}, State) ->
    ?LLOG(info, "status timeout", [], State),
    {stop, normal, State};

handle_info({'DOWN', Ref, process, _Pid, Reason}, #state{mon=Ref}=State) ->
    case Reason of
        normal ->
            ?LLOG(info, "caller monitor stop", [], State);
        _ ->
            ?LLOG(notice, "caller monitor stop: ~p", [Reason], State)
    end,
    {stop, normal, State};

handle_info({'DOWN', Ref, process, _Pid, Reason}, #state{room_mon=Ref}=State) ->
    case Reason of
        normal ->
            ?LLOG(info, "room monitor stop", [], State);
        _ ->
            ?LLOG(notice, "room monitor stop: ~p", [Reason], State)
    end,
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
    #state{from=From, status=Status} = State,
    destroy(State),
    case Status of
        publisher ->
            #state{room=Room, session=Session} = State,
            _ = nkmedia_janus_room:event(Room, {unpublish, Session});
        listener ->
            #state{room=Room, session=Session} = State,
            _ = nkmedia_janus_room:event(Room, {unlisten, Session});
        _ ->
            ok
    end,
    nklib_util:reply(From, {error, stopped}),
    ok.


%% ===================================================================
%% Echo
%% ===================================================================

%% @private Echo plugin
do_echo(#{sdp:=SDP}, #state{session_id=Id}=State) ->
    {ok, Handle} = attach(echotest, State),
    Body = get_body(#{}, State),
    Jsep = #{sdp=>SDP, type=>offer, trickle=>false},
    case message(Handle, Body, Jsep, State) of
        {ok, #{<<"result">>:=<<"ok">>}, #{<<"sdp">>:=SDP2}} ->
            State2 = State#state{session_id=Id, handle_id=Handle},
            reply({ok, #{sdp=>SDP2}}, status(echo, State2));
        {error, Error} ->
            reply_error({echo_error, Error}, State)
    end.



%% ===================================================================
%% Play
%% ===================================================================


%% @private Create session and join
do_play(File, State) ->
    {ok, Handle} = attach(recordplay, State),
    State2 = State#state{handle_id=Handle},
    case message(Handle, #{request=>update}, #{}, State2) of
        {ok, #{<<"list">>:=List}, _} ->
            case message(Handle, #{request=>list}, #{}, State2) of
                {ok, #{<<"list">>:=List}, _} ->
                    lager:error("List: ~p", [List]),
                    case message(Handle, #{request=>play, id=>File}, #{}, State2) of
                        {ok, 
                            #{<<"result">>:=#{<<"status">>:=<<"preparing">>}}, 
                            #{<<"sdp">>:=SDP}
                        } ->
                            State3 = status({wait, play_answer}, State2),
                            reply({ok, #{sdp=>SDP}}, State3);
                        {ok, #{<<"error">>:=Error}, _} ->
                            {error, {could_not_join, Error}}
                    end;
                {error, Error} ->
                    
                    reply_error({list_error, Error}, State2)
            end;
        {error, Error} ->
            reply_error({update_error, Error}, State2)
    end.
    

%% @private Caller answers
do_play_answer(#{sdp:=SDP}, #state{handle_id=Handle} = State) ->
    Body = #{request=>start},
    Jsep = #{sdp=>SDP, type=>answer, trickle=>false},
    case message(Handle, Body, Jsep, State) of
        {ok, #{<<"result">>:=#{<<"status">>:=<<"playing">>}}, _} ->
            reply(ok, status(play, State));
        {error, Error} ->
            reply_error({start_error, Error}, State)
    end.


%% ===================================================================
%% Videocall
%% ===================================================================

%% @private First node registers
do_videocall(#{sdp:=SDP}, From, #state{session_id=Id}=State) ->
    {ok, Handle} = attach(videocall, State),
    UserName = nklib_util:to_binary(Handle),
    Body = #{request=>register, username=>UserName},
    case message(Handle, Body, #{}, State) of
        {ok, #{<<"result">>:=#{<<"event">>:=<<"registered">>}}, _} ->
            State2 = State#state{
                session_id = Id,
                handle_id = Handle,
                from = From
            },
            do_videocall_2(SDP, State2);
        {error, Error} ->
            reply_error({could_not_register, Error}, State)
    end.


%% @private Second node registers
do_videocall_2(SDP, State) ->
    {ok, Handle2} = attach(<<"videocall">>, State),
    UserName2 = nklib_util:to_binary(Handle2),
    Body = #{request=>register, username=>UserName2},
    case message(Handle2, Body, #{}, State) of
        {ok, #{<<"result">>:=#{<<"event">>:=<<"registered">>}}, _} ->
            State2 = State#state{
                handle_id2 = Handle2
            },
            do_videocall_3(SDP, State2);
        {error, Error} ->
            reply({could_not_register, Error}, State)
    end.


%% @private We launch the call and wait for Juanus
do_videocall_3(SDP, State) ->
    #state{
        handle_id = Handle, 
        handle_id2 = Handle2
    } = State,
    Body = #{request=>call, username=>nklib_util:to_binary(Handle2)},
    Jsep = #{sdp=>SDP, type=>offer, trickle=>false},
    case message(Handle, Body, Jsep, State) of
        {ok, #{<<"result">>:=#{<<"event">>:=<<"calling">>}}, _} ->
            noreply(status({wait, videocall_offer}, State));
        {error, Error} ->
            reply_error({could_not_call, Error}, State)
    end.


%% @private. We receive answer from called party and wait Janus
do_videocall_answer(#{sdp:=SDP}, From, State) ->
    #state{handle_id=Handle, opts=Opts, handle_id2=Handle2} = State,
    #state{} = State,
    Body1 = #{request=>accept},
    Jsep = #{sdp=>SDP, type=>answer, trickle=>false},
    case message(Handle2, Body1, Jsep, State) of
        {ok, #{<<"result">>:=#{<<"event">>:=<<"accepted">>}}, _} ->
            Body2 = get_body(#{request=>set}, State),
            case message(Handle, Body2, #{}, State) of
                {ok, #{<<"result">>:=#{<<"event">>:=<<"set">>}}, _} ->
                    #{filename:=File} = Opts,
                    Length = byte_size(File)-2,
                    <<Base:Length/binary, _/binary>> = File,
                    Opts2 = Opts#{filename:=<<Base/binary, "_b">>},
                    Body3 = get_body(#{request=>set}, State#state{opts=Opts2}),
                    case message(Handle2, Body3, #{}, State) of
                        {ok, #{<<"result">>:=#{<<"event">>:=<<"set">>}}, _} ->
                            State2 = State#state{from=From},
                            noreply(status({wait, videocall_reply}, State2));
                        {error, Error} ->
                            reply_error({set_error, Error}, State)
                    end;
                {error, Error} ->
                    reply_error({set_error, Error}, State)
            end;
        {error, Error} ->
            reply_error({accepted_error, Error}, State)
    end.



%% ===================================================================
%% Rooms
%% ===================================================================

%% @private
do_list_rooms(State) ->
    {ok, Handle} = attach(videoroom, State),
    Body = #{request => list}, 
    case message(Handle, Body, #{}, State) of
        {ok, #{<<"list">>:=List}, _} ->
            List2 = [{Desc, Data} || #{<<"description">>:=Desc}=Data <- List],
            reply_stop({ok, maps:from_list(List2)}, State);
        {error, Error} ->
            reply_error({create_error, Error}, State)
    end.


%% @private
do_create_room(#state{room=Room, opts=Opts}=State) ->
    {ok, Handle} = attach(videoroom, State),
    RoomId = to_room_id(Room),
    Body = #{
        request => create, 
        description => nklib_util:to_binary(Room),
        bitrate => maps:get(bitrate, Opts, 128000),
        publishers => maps:get(publishers, Opts, 6),
        audiocodec => maps:get(audiocodec, Opts, opus),
        videocodec => maps:get(videocodec, Opts, vp8),
        record => maps:get(record, Opts, false),
        rec_dir => nklib_util:to_binary(maps:get(rec_dir, Opts, <<"/tmp">>)),
        is_private => false,
        permanent => false,
        room => RoomId
        % fir_freq
    },
    case message(Handle, Body, #{}, State) of
        {ok, #{<<"videoroom">>:=<<"created">>, <<"room">>:=RoomId}, _} ->
            reply_stop(ok, State);
        {ok, #{<<"error_code">>:=427}, _} ->
            reply_error(already_exists, State);
        {ok, #{<<"error">>:=Error}, _} ->
            reply_error({create_error, Error}, State);
        {error, Error} ->
            reply_error({create_error, Error}, State)
    end.


%% @private
do_destroy_room(#state{room=Room}=State) ->
    {ok, Handle} = attach(videoroom, State),
    RoomId = to_room_id(Room),
    Body = #{request => destroy, room => RoomId},
    case message(Handle, Body, #{}, State) of
        {ok, #{<<"videoroom">>:=<<"destroyed">>}, _} ->
            reply_stop(ok, State);
        {ok, #{<<"error_code">>:=426}, _} ->
            reply_error(room_not_found, State);
        {ok, #{<<"error">>:=Error}, _} ->
            reply_error(Error, State);
        {error, Error} ->
            reply_error({destroy_error, Error}, State)
    end.





%% ===================================================================
%% Publisher
%% ===================================================================

%% @private Create session and join
do_publish(#{sdp:=SDP}, #state{room=Room, session=Session} = State) ->
    {ok, Handle} = attach(videoroom, State),
    RoomId = to_room_id(Room),
    Feed = erlang:phash2(Session),
    Body = #{
        request => join, 
        room => RoomId,
        ptype => publisher,
        display => Session,
        id => Feed
    },
    case message(Handle, Body, #{}, State) of
        {ok, #{<<"videoroom">>:=<<"joined">>, <<"id">>:=Feed}, _} ->
            State2 = State#state{handle_id=Handle},
            do_publish_2(SDP, State2);
        {ok, #{<<"error_code">>:=426}, _} ->
            reply_error(unknown_room, State);
        {ok, #{<<"error">>:=Error}, _} ->
            reply_error(Error, State);
        {error, Error} ->
            reply_error({joined_error, Error}, State)
    end.


%% @private
do_publish_2(SDP_A, State) ->
    #state{
        handle_id = Handle, 
        room = Room, 
        session = Session,
        opts = Opts
    } = State,
    DefFile = <<"publish_", Session/binary>>,
    Body = #{
        request => configure,
        audio => maps:get(audio, Opts, true),
        video => maps:get(video, Opts, true),
        data => maps:get(data, Opts, true),
        bitrate => maps:get(bitrate, Opts, 0),
        record => maps:get(record, Opts, false),
        filename => nklib_util:to_binary(maps:get(filename, Opts, DefFile))
    },
    Jsep = #{sdp=>SDP_A, type=>offer, trickle=>false},
    case message(Handle, Body, Jsep, State) of
        {ok, #{<<"configured">>:=<<"ok">>}, #{<<"sdp">>:=SDP_B}} ->
            case nkmedia_janus_room:event(Room, {publish, Session, Opts}) of
                {ok, Pid} ->
                    Mon = erlang:monitor(process, Pid),
                    State2 = State#state{room_mon=Mon},
                    reply({ok, #{sdp=>SDP_B}}, status(publish, State2));
                {error, Error} ->
                    reply_error({nkmedia_room_error, Error}, State)
            end;
        {error, Error} ->
            reply_error({configure_error, Error}, State)
    end.


%% @private
do_unpublish(#state{handle_id=Handle} = State) ->
    Body = #{request => unpublish},
    case message(Handle, Body, #{}, State) of
        {ok, #{<<"videoroom">>:=<<"unpublished">>}, _} ->
            reply_stop(ok, State);
        {error, Error} ->
            reply_error({joined_error, Error}, State)
    end.





%% ===================================================================
%% Listener
%% ===================================================================


%% @private Create session and join
do_listen(Listen, #state{room=Room, session=Session, opts=Opts}=State) ->
    {ok, Handle} = attach(videoroom, State),
    Feed = erlang:phash2(Listen),
    Body = #{
        request => join, 
        room => to_room_id(Room),
        ptype => listener,
        feed => Feed,
        audio => maps:get(audio, Opts, true),
        video => maps:get(video, Opts, true),
        data => maps:get(data, Opts, true)
    },
    case message(Handle, Body, #{}, State) of
        {ok, #{<<"videoroom">>:=<<"attached">>}, #{<<"sdp">>:=SDP}} ->
            State2 = State#state{handle_id=Handle},
            case nkmedia_janus_room:event(Room, {listen, Session, Opts}) of
                {ok, Pid} ->
                    Mon = erlang:monitor(process, Pid),
                    State3 = State2#state{room_mon=Mon},
                    reply({ok, #{sdp=>SDP}}, status({wait, listen_answer}, State3));
                {error, Error} ->
                    reply_error({nkmedia_room_error, Error}, State2)
            end;
        {ok, #{<<"error">>:=Error}, _} ->
            reply_error(Error, State);
        {error, Error} ->
            {error, {could_not_join, Error}}
    end.


%% @private Caller answers
do_listen_answer(#{sdp:=SDP}, State) ->
    #state{handle_id=Handle, room=Room} = State,
    Body = #{request=>start, room=>Room},
    Jsep = #{sdp=>SDP, type=>answer, trickle=>false},
    case message(Handle, Body, Jsep, State) of
        {ok, #{<<"started">>:=<<"ok">>}, _} ->
            reply(ok, status(listen, State));
        {error, Error} ->
            reply_error({start_error, Error}, State)
    end.



%% @private Create session and join
do_listen_switch(Listen, #state{handle_id=Handle, opts=Opts}=State) ->
    Feed = erlang:phash2(Listen),
    Body = #{
        request => switch,        
        feed => Feed,
        audio => maps:get(audio, Opts, true),
        video => maps:get(video, Opts, true),
        data => maps:get(data, Opts, true)
    },
    case message(Handle, Body, #{}, State) of
        {ok, #{<<"switched">>:=<<"ok">>}, _} ->
            reply(ok, State);
        {ok, #{<<"error">>:=Error}, _} ->
            reply({error, Error}, State);
        {error, Error} ->
            {error, {could_not_join, Error}}
    end.


%% @private
do_unlisten(#state{handle_id=Handle}=State) ->
    Body = #{request => leave},
    case message(Handle, Body, #{}, State) of
        {ok, #{<<"videoroom">>:=<<"unpublished">>}, _} ->
            reply_stop(ok, State);
        {error, Error} ->
            reply_error({leave_error, Error}, State)
    end.


%% ===================================================================
%% SIP 
%% ===================================================================

%% @private
do_from_sip(#state{sip_contact=Contact, offer=Offer}=State) ->
    Self = self(),
    spawn_link(
        fun() ->
            % We call Janus using SIP
            Result = case nkmedia_core_sip:invite(Contact, Offer) of
                {ok, 200, [{dialog, _Dialog}, {body, Body}]} ->
                    {ok, Body};
                Other ->
                    {error, Other}
            end,
            gen_server:cast(Self, {invite, Result})
        end),
    noreply(status({wait, janus_from_sip_answer_1}, State#state{offer=undefined})).


%% @private
do_from_sip_answer(#{sdp:=SDP}, From, State) ->
    #state{handle_id=Handle} = State,
    Body = #{request=>accept},
    Jsep = #{sdp=>SDP, type=>answer, trickle=>false},
    case message(Handle, Body, Jsep, State) of
        {ok, #{<<"result">>:=#{<<"event">>:=<<"accepted">>}}, _} ->
            noreply(status({wait, from_sip_invite}, State#state{from=From}));
        {error, Error} ->
            reply_error({accepted_error, Error}, State)
    end.


%% @private
do_to_sip(#state{id=Id, handle_id=Handle, offer=#{sdp:=SDP}}=State) ->
    Body = #{
        request => call,
        uri => <<"sip:janus-", Id/binary, "@nkmedia">>
    },
    Jsep = #{sdp=>SDP, type=>offer},
    case message(Handle, Body, Jsep, State) of
        {ok, #{<<"result">>:=#{<<"event">>:=<<"calling">>}}, _} ->
            State2 = State#state{offer=undefined},
            noreply(status({wait, sip_offer}, State2));
        {error, Error} ->
            reply_error({accepted_error, Error}, State)
    end.





%% ===================================================================
%% Events
%% ===================================================================

%% @private
do_event(Id, Handle, {event, <<"incomingcall">>, _, #{<<"sdp">>:=SDP}}, State) ->
    case State of
        #state{status={wait, videocall_offer}, session_id=Id, handle_id2=Handle} ->
            #state{from=From} = State,
            gen_server:reply(From, {ok, #{sdp=>SDP}}),
            State2 = State#state{from=undefined},
            noreply(status({wait, videocall_answer}, State2));
        #state{status={wait, janus_from_sip_answer_1}, session_id=Id, handle_id=Handle} ->
            #state{from=From} = State,
            gen_server:reply(From, {ok, #{sdp=>SDP, sdp_type=>webrtc}}),
            State2 = State#state{from=undefined},
            noreply(status({wait, from_sip_answer_2}, State2));
        _ ->
            ?LLOG(warning, "unexpected incomingcall", [], State),
            {stop, normal, State}
    end;

do_event(Id, Handle, {event, <<"accepted">>, _, #{<<"sdp">>:=SDP}}, State) ->
    case State of
        #state{status={wait, videocall_reply}, session_id=Id, handle_id=Handle} ->
            #state{from=From} = State,
            gen_server:reply(From, {ok, #{sdp=>SDP}}),
            Body = get_body(#{request=>set}, State),
            case message(Handle, Body, #{}, State) of
                {ok, #{<<"result">>:=#{<<"event">>:=<<"set">>}}, _} ->
                    State2 = State#state{from=undefined},
                    noreply(status(videocall, State2));
                {error, Error} ->
                    ?LLOG(warning, "error sending set: ~p", [Error], State),
                    {stop, normal, State}
            end;
        #state{status={wait, to_sip_reply}, session_id=Id, handle_id=Handle} ->
            #state{from=From} = State,
            gen_server:reply(From, {ok, #{sdp=>SDP}}),
            State2 = State#state{from=undefined},
            noreply(status(sip, State2));
        _ ->
            ?LLOG(warning, "unexpected incomingcall!", [], State),
            {stop, normal, State}
    end;

do_event(_Id, _Handle, {data, #{<<"publishers">>:=_}}, State) ->
    noreply(State);

do_event(_Id, _Handle, {data, #{<<"videoroom">>:=<<"destroyed">>}}, State) ->
    ?LLOG(notice, "videoroom destroyed", [], State),
    {stop, normal, State};

do_event(_Id, _Handle, {event, <<"registered">>, _, _}, State) ->
    case State of
        #state{status={wait, from_sip}, sip_contact=Uri} when Uri /= undefined ->
            do_from_sip(State);
        #state{status={wait, to_sip}} ->
            timer:sleep(2000),
            do_to_sip(State);
        _ ->
            ?LLOG(warning, "unexpected registered", [], State),
            noreply(State)
    end;

do_event(_Id, _Handle, {event, <<"registration_failed">>, _, _}, State) ->
    ?LLOG(warning, "registration error", [], State),
    {stop, normal, State};

do_event(_Id, _Handle, {event, <<"hangup">>, _, _}, State) ->
    ?LLOG(notice, "hangup from Janus", [], State),
    {stop, normal, State};

do_event(_Id, _Handle, Event, State) ->
    ?LLOG(warning, "unexpected event: ~p", [Event], State),
    noreply(State).




%% ===================================================================
%% Internal
%% ===================================================================

%% @private
attach(Plugin, #state{session_id=SessId}=State) ->
    {ok, Pid} = get_janus_pid(State),
    nkmedia_janus_client:attach(Pid, SessId, nklib_util:to_binary(Plugin)).


%% @private
message(Handle, Body, Jsep, #state{session_id=SessId}=State) ->
    {ok, Pid} = get_janus_pid(State),
    case nkmedia_janus_client:message(Pid, SessId, Handle, Body, Jsep) of
        {ok, #{<<"data">>:=Data}, Jsep2} ->
            {ok, Data, Jsep2};
        {error, Error} ->
            {error, Error}
    end.


%% @private
destroy(#state{session_id=SessId}=State) ->
    {ok, Pid} = get_janus_pid(State),
    nkmedia_janus_client:destroy(Pid, SessId).


%% @private
keepalive(#state{session_id=SessId}=State) ->
    {ok, Pid} = get_janus_pid(State),
    nkmedia_janus_client:keepalive(Pid, SessId).


%% @private
get_janus_pid(#state{janus_id=JanusId}) ->
    nkmedia_janus_engine:get_conn(JanusId).


%% @private
sip_register(Status, #state{id=Id}=State) ->
    {ok, Handle} = attach(sip, State),
    Ip = nklib_util:to_host(nkmedia_app:get(erlang_ip)),
    Port = nkmedia_app:get(sip_port),
    Body = #{
        request => register,
        proxy => <<"sip:", Ip/binary, ":",(nklib_util:to_binary(Port))/binary>>,
        % username => <<"sip:jb@test">>,
        username => <<"sip:janus-", Id/binary, "@nkmedia">>,
        secret => <<"test">>
    },
    case message(Handle, Body, #{}, State) of
        {ok, #{<<"result">>:=#{<<"event">>:=<<"registering">>}}, _} ->
            State2 = State#state{handle_id=Handle},
            noreply(status({wait, Status}, State2));
        {ok, #{<<"error">>:=Error}, _} ->
            reply_error(Error, State);
        {error, Error} ->
            reply_error({could_not_join, Error}, State)
    end.



%% @private
parse_event(Msg) ->
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
            error
    end.



%% @private
status(NewStatus, #state{status=OldStatus, timer=Timer}=State) ->
    case NewStatus of
        OldStatus -> ok;
        _ -> ?LLOG(info, "status changed to ~p", [NewStatus], State)
    end,
    nklib_util:cancel_timer(Timer),
    Time = case NewStatus of
        {wait, _} -> ?OP_TIMEOUT;
        _ -> ?CALL_TIMEOUT
    end,
    NewTimer = erlang:start_timer(1000*Time, self(), status_timeout),
    State#state{status=NewStatus, timer=NewTimer}.


%% @private
reply(Reply, State) ->
    {reply, Reply, State, get_hibernate(State)}.


%% @private
reply_stop(Reply, State) ->
    {stop, normal, Reply, State}.


%% @private
reply_error(Error, State) ->
    {stop, normal, {error, Error}, State}.


%% @private
noreply(State) ->
    {noreply, State, get_hibernate(State)}.


%% @private
get_hibernate(#state{status=Status})
    when Status==echo; Status==videocall; 
         Status==publish; Status==listen ->
    hibernate;
get_hibernate(_) ->
    infinity.


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
        {ok, Pid} -> 
            nklib_util:call(Pid, Msg, Timeout);
        not_found -> 
            case start(SessId) of
                {ok, _, Pid} ->
                    nklib_util:call(Pid, Msg, Timeout);
                _ ->
                    {error, session_not_found}
            end
    end.


%% @private
do_cast(SessId, Msg) ->
    case find(SessId) of
        {ok, Pid} -> gen_server:cast(Pid, Msg);
        not_found -> {error, session_not_found}
    end.



%% @private
get_body(Body, #state{opts=Opts}) ->
    Body#{
        audio => maps:get(audio, Opts, true),
        video => maps:get(video, Opts, true),
        data => maps:get(data, Opts, true),
        bitrate => maps:get(bitrate, Opts, 0),
        record => maps:get(record, Opts, false),
        filename => maps:get(filename, Opts)
    }.



%% @private
to_room(Room) when is_integer(Room) -> Room;
to_room(Room) -> nklib_util:to_binary(Room).


%% @private
to_room_id(Room) when is_integer(Room) -> Room;
to_room_id(Room) when is_binary(Room) -> erlang:phash2(Room).
