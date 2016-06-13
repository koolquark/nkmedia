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

-export([start/2, stop/1, videocall/3, echo/3, play/3]).
-export([list_rooms/1, create_room/3, destroy_room/2]).
-export([publish/4, unpublish/1]).
-export([listen/4, listen_switch/3, unlisten/1]).
-export([from_sip/3, to_sip/3]).
-export([nkmedia_sip_register/2, nkmedia_sip_invite/2]).
-export([answer/2]).
-export([get_all/0, stop_all/0, janus_event/4]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Janus Session ~p (~p) "++Txt, 
               [State#state.janus_sess_id, State#state.status | Args])).

-include("nkmedia.hrl").


-define(WAIT_TIMEOUT, 10).      % Secs
-define(OP_TIMEOUT, 4*60*60).   
-define(KEEPALIVE, 20).

%% ===================================================================
%% Types
%% ===================================================================


-type janus_id() :: nkmedia_janus_engine:id().

-type room() :: binary().

-type play() :: binary().


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
    wait | videocall | echo | publish | listen | sdp.



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Starts a new session
-spec start(janus_id(), nkmedia_session:id()) ->
    {ok, pid()}.

start(JanusId, SessionId) ->
    gen_server:start(?MODULE, {JanusId, SessionId, self()}, []).


%% @doc Stops a session
-spec stop(pid()|janus_id()) ->
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
-spec videocall(pid()|janus_id(), nkmedia:offer(), media_opts()) ->
    {ok, nkmedia:offer()} | {error, term()}.

videocall(Id, Offer, Opts) ->
    do_call(Id, {videocall, Offer, Opts}).


%% @doc Starts a echo inside the session.
%% The SDP is returned.
-spec echo(pid()|janus_id(), nkmedia:offer(), media_opts()) ->
    {ok, nkmedia:answer()} | {error, term()}.

echo(Id, Offer, Opts) ->
    do_call(Id, {echo, Offer, Opts}).


%% @doc Starts playing a file
%% The offer SDP is returned.
-spec play(pid()|janus_id(), play(), media_opts()) ->
    {ok, nkmedia:offer()} | {error, term()}.

play(Id, Play, Opts) ->
    do_call(Id, {play, Play, Opts}).


%% @doc List all videorooms
-spec list_rooms(pid()|janus_id()) ->
    {ok, list()} | {error, term()}.

list_rooms(Id) ->
    do_call(Id, list_rooms).


%% @doc Creates a new videoroom
-spec create_room(pid()|janus_id(), room(), room_opts()) ->
    {ok, room()} | {error, term()}.

create_room(Id, Room, Opts) ->
    do_call(Id, {create_room, to_room(Room), Opts}).


%% @doc Destroys a videoroom
-spec destroy_room(pid()|janus_id(), room()) ->
    ok | {error, term()}.

destroy_room(Id, Room) ->
    do_call(Id, {destroy_room, to_room(Room)}).


%% @doc Starts a conection to a videoroom.
%% caller_id is taked from offer.
-spec publish(pid()|janus_id(), room(), nkmedia:offer(), media_opts()) ->
    {ok, nkmedia:answer()} | {error, term()}.

publish(Id, Room, Offer, Opts) ->
    do_call(Id, {publish, to_room(Room), Offer, Opts}).


%% @doc Starts a conection to a videoroom.
%% caller_id is taked from offer.
-spec unpublish(pid()|janus_id()) ->
    ok | {error, term()}.

unpublish(Id) ->
    do_call(Id, unpublish).


%% @doc Starts a conection to a videoroom
-spec listen(pid()|janus_id(), room(), nkmedia_session:id(), listen_opts()) ->
    {ok, nkmedia:offer()} | {error, term()}.

listen(Id, Room, Listen, Opts) ->
    do_call(Id, {listen, to_room(Room), Listen, Opts}).


%% @doc Answers a listen
-spec listen_switch(pid()|janus_id(), nkmedia_session:id(), listen_opts()) ->
    ok | {error, term()}.

listen_switch(Id, Listen, Opts) ->
    Listen2 = nklib_util:to_binary(Listen),
    do_call(Id, {listen_switch, Listen2, Opts}).


%% @doc
-spec unlisten(pid()|janus_id()) ->
    ok | {error, term()}.

unlisten(Id) ->
    do_call(Id, unlisten).


%% @doc Receives a SIP offer, generates a WebRTC offer
%% You must call answer/2 when you have the WebRTC answer
-spec from_sip(pid()|janus_id(), nkmedia:offer(), #{}) ->
    {ok, nkmedia:offer()} | {error, term()}.

from_sip(Id, Offer, Opts) ->
    do_call(Id, {from_sip, Offer, Opts}).


%% @doc Receives an WebRTC offer, generates a SIP offer
%% You must call answer/2 when you have the SIP answer
-spec to_sip(pid()|janus_id(), nkmedia:offer(), #{}) ->
    {ok, nkmedia:offer()} | {error, term()}.

to_sip(Id, Offer, Opts) ->
    do_call(Id, {to_sip, Offer, Opts}).


%% @doc Answers a pending request
%% Get Janus' answer (except for listen and play)
-spec answer(pid()|janus_id(), nkmedia:answer()) ->
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

janus_event(Pid, JanusSessId, JanusHandle, Msg) ->
    % lager:error("Event: ~p", [Msg]),
    gen_server:cast(Pid, {event, JanusSessId, JanusHandle, Msg}).


%% @private
-spec nkmedia_sip_register(binary(), nksip:request()) ->
    continue | {reply, forbidden}.

nkmedia_sip_register(User, Req) ->
    Id = nklib_util:to_integer(User),
    case nksip_request:meta(contacts, Req) of
        {ok, [Contact]} ->
            case do_call(Id, {sip_registered, Contact}) of
                true ->
                    {reply, ok};
                false ->
                    {reply, forbidden};
                {error, Error} ->
                    lager:info("JANUS OP ~p Reg error: ~p", [Id, Error]),
                    {reply, forbidden}
            end;
        Other ->
            lager:warning("JANUS OP SIP: invalid Janus Contact: ~p", [Other]),
            {reply, forbidden}
    end.


%% @private
-spec nkmedia_sip_invite(binary(), nksip:request()) ->
    noreply | {reply, forbidden}.

nkmedia_sip_invite(User, Req) ->
    Id = binary_to_integer(User),
    {ok, Handle} = nksip_request:get_handle(Req),
    {ok, Dialog} = nksip_dialog:get_handle(Req),
    {ok, Body} = nksip_request:body(Req),
    SDP = nksip_sdp:unparse(Body),
    case do_call(Id, {sip_invite, Handle, Dialog, SDP}) of
        ok ->
            noreply;
            % {reply, ringing};
        {error, Error} ->
            lager:info("JANUS OP ~p Invite error: ~p", [Id, Error]),
            {reply, forbidden}
    end.

    


%% ===================================================================
%% gen_server behaviour
%% ===================================================================


-record(state, {
    janus_id :: nkmedia_janus:id(),
    nkmedia_id ::nkmedia_session:id(),
    conn ::  pid(),
    conn_mon :: reference(),
    user_mon :: reference(),
    status = init :: status() | init,
    wait :: term(),
    janus_sess_id :: integer(),
    handle_id :: integer(),
    handle_id2 :: integer(),
    room :: room(),
    room_mon :: reference(),
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

init({JanusId, MediaSessId, CallerPid}) ->
    case nkmedia_janus_client:start(JanusId) of
        {ok, Pid} ->
            {ok, JanusSessId} = nkmedia_janus_client:create(Pid, ?MODULE, self()),
            State = #state{
                janus_id = JanusId, 
                nkmedia_id = MediaSessId,
                janus_sess_id = JanusSessId,
                conn = Pid,
                conn_mon = monitor(process, Pid),
                user_mon = monitor(process, CallerPid)
            },
            true = nklib_proc:reg({?MODULE, JanusSessId}),
            nklib_proc:put(?MODULE, JanusSessId),
            self() ! send_keepalive,
            {ok, status(wait, State)};
        {error, Error} ->
            {stop, Error}
    end.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call({echo, Offer, Opts}, _From, #state{status=wait}=State) -> 
    Opts2 = case Opts of
        #{filename:=File} -> 
            Opts#{filename:=nklib_util:to_binary(File)};
        _ ->
            #state{nkmedia_id=SessId} = State,
            Opts#{filename=><<"/tmp/echo_", SessId/binary>>}
    end,
    do_echo(Offer, State#state{opts=Opts2});

handle_call({play, File, Opts}, _From, #state{status=wait}=State) -> 
    do_play(File, State#state{opts=Opts});

handle_call({videocall, Offer, Opts}, From, #state{status=wait}=State) -> 
    Opts2 = case Opts of
        #{filename:=File} -> 
            Opts#{filename:=<<(nklib_util:to_binary(File))/binary, "_a">>};
        _ ->
            #state{nkmedia_id=SessId} = State,
            Opts#{filename=><<"/tmp/call_", SessId/binary, "_a">>}
    end,
    do_videocall(Offer, From, State#state{opts=Opts2});

handle_call(list_rooms, _From, #state{status=wait}=State) -> 
    do_list_rooms(State);

handle_call({create_room, Room, Opts}, _From, #state{status=wait}=State) -> 
    do_create_room(State#state{room=Room, opts=Opts});

handle_call({destroy_room, Room}, _From, #state{status=wait}=State) -> 
    do_destroy_room(State#state{room=Room});

handle_call({publish, Room, Offer, Opts}, _From, #state{status=wait}=State) -> 
    Opts2 = case Opts of
        #{filename:=File} -> 
            Opts#{filename:=nklib_util:to_binary(File)};
        _ ->
            #state{nkmedia_id=SessId} = State,
            Opts#{filename=><<"publish_", SessId/binary>>}
    end,
    do_publish(Offer, State#state{room=Room, opts=Opts2});

handle_call(upublish, _From, #state{status=publish}=State) -> 
    do_unpublish(State);

handle_call({listen, Room, Listen, Opts}, _From, #state{status=wait}=State) -> 
    do_listen(Listen, State#state{room=Room, opts=Opts});

handle_call({listen_switch, Listen, Opts}, _From, #state{status=listen}=State) -> 
    do_listen_switch(Listen, State#state{opts=Opts});

handle_call(unlisten, _From, #state{status=listen}=State) -> 
    do_unlisten(State);

handle_call({from_sip, Offer, _Opts}, From, #state{status=wait}=State) ->
    % We tell Janus to register, wait the registration and
    % call do_from_sip/1
    do_from_sip_register(State#state{from=From, offer=Offer});

handle_call({to_sip, Offer, _Opts}, From, #state{status=wait}=State) ->
    do_to_sip_register(State#state{from=From, offer=Offer});

handle_call({sip_registered, Contact}, _From, #state{status=Status, wait=Wait}=State) ->
    case {Status, Wait} of
        {wait, to_sip} ->
            reply(true, State#state{sip_contact=Contact});
        {wait, from_sip} ->
            reply(true, State#state{sip_contact=Contact});
        {sip, _} ->
            reply(true, State);
        _ ->
            reply(false, State)
    end;

handle_call({sip_invite, Handle, Dialog, SDP}, _From, 
            #state{status=wait, wait=to_sip_invite}=State) ->
    #state{from=UserFrom} = State,
    gen_server:reply(UserFrom, {ok, #{sdp=>SDP, sdp_type=>rtp}}),
    State2 = State#state{sip_handle=Handle, sip_dialog=Dialog, from=undefined},
    reply(ok, wait(to_sip_answer, State2));

handle_call({answer, Answer}, From, State) ->
    #state{status=Status, wait=Wait} = State,
    case {Status, Wait} of
        {wait, videocall_answer} ->
            do_videocall_answer(Answer, From, State);
        {wait, listen_answer} ->
            do_listen_answer(Answer, State);
        {wait, play_answer} ->
            do_play_answer(Answer, State);
        {wait, from_sip_answer_2} ->
            do_from_sip_answer(Answer, From, State);
        {wait, to_sip_answer} ->
            do_to_sip_answer(Answer, From, State);
        _ ->
            reply_error(invalid_state, State)
    end;

   
handle_call(_Msg, _From, State) -> 
    reply({error, invalid_state}, State).
    

%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({event, _Id, _Handle, stop}, State) ->
    ?LLOG(notice, "received stop from janus", [], State),
    {stop, normal, State};

handle_cast({event, _Id, _Handle, #{<<"janus">>:=<<"hangup">>}=Msg}, State) ->
    #{<<"reason">>:=Reason} = Msg,
    ?LLOG(notice, "hangup from janus (~s)", [Reason], State),
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

handle_cast({invite, {ok, Body}}, #state{status=wait, wait=from_sip_invite}=State) ->
    #state{from=From} =State,
    gen_server:reply(From, {ok, #{sdp=>nksip_sdp:unparse(Body)}}),
    noreply(status(from_sip, State#state{from=undefined}));

handle_cast({invite, {error, Error}}, #state{status=wait, wait=from_sip_invite}=State) ->
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

handle_info({'DOWN', Ref, process, _Pid, Reason}, #state{user_mon=Ref}=State) ->
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
            #state{room=Room, nkmedia_id=SessId} = State,
            _ = nkmedia_janus_room:event(Room, {unpublish, SessId});
        listener ->
            #state{room=Room, nkmedia_id=SessId} = State,
            _ = nkmedia_janus_room:event(Room, {unlisten, SessId});
        _ ->
            ok
    end,
    nklib_util:reply(From, {error, process_stopped}),
    ok.


%% ===================================================================
%% Echo
%% ===================================================================

%% @private Echo plugin
do_echo(#{sdp:=SDP}, State) ->
    {ok, Handle} = attach(echotest, State),
    Body = get_body(#{}, State),
    Jsep = #{sdp=>SDP, type=>offer, trickle=>false},
    case message(Handle, Body, Jsep, State) of
        {ok, #{<<"result">>:=<<"ok">>}, #{<<"sdp">>:=SDP2}} ->
            State2 = State#state{handle_id=Handle},
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
                            State3 = wait(play_answer, State2),
                            reply({ok, #{sdp=>SDP}}, State3);
                        {ok, #{<<"error">>:=Error}, _} ->
                            reply_error({could_not_join, Error}, State2)
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
do_videocall(#{sdp:=SDP}, From, State) ->
    {ok, Handle} = attach(videocall, State),
    UserName = nklib_util:to_binary(Handle),
    Body = #{request=>register, username=>UserName},
    case message(Handle, Body, #{}, State) of
        {ok, #{<<"result">>:=#{<<"event">>:=<<"registered">>}}, _} ->
            State2 = State#state{handle_id = Handle, from = From},
            do_videocall_2(SDP, State2);
        {error, Error} ->
            reply_error({could_not_register, Error}, State)
    end.


%% @private Second node registers
do_videocall_2(SDP, State) ->
    {ok, Handle2} = attach(videocall, State),
    UserName2 = nklib_util:to_binary(Handle2),
    Body = #{request=>register, username=>UserName2},
    case message(Handle2, Body, #{}, State) of
        {ok, #{<<"result">>:=#{<<"event">>:=<<"registered">>}}, _} ->
            State2 = State#state{handle_id2 = Handle2},
            do_videocall_3(SDP, State2);
        {error, Error} ->
            reply({could_not_register, Error}, State)
    end.


%% @private We launch the call and wait for Juanus
do_videocall_3(SDP, State) ->
    #state{handle_id = Handle, handle_id2 = Handle2} = State,
    Body = #{request=>call, username=>nklib_util:to_binary(Handle2)},
    Jsep = #{sdp=>SDP, type=>offer, trickle=>false},
    case message(Handle, Body, Jsep, State) of
        {ok, #{<<"result">>:=#{<<"event">>:=<<"calling">>}}, _} ->
            noreply(wait(videocall_offer, State));
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
                            noreply(wait(videocall_reply, State2));
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
            detach(Handle, State),
            reply({ok, maps:from_list(List2)}, status(wait, State));
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
        {ok, Msg, _} ->
            Reply = case Msg of
                #{<<"videoroom">>:=<<"created">>, <<"room">>:=RoomId} ->
                    ok;
                #{<<"error_code">>:=427} ->
                    {error, already_exists};
                #{<<"error">>:=Error} ->
                    {error, {create_error, Error}}
            end,
            detach(Handle, State),
            reply(Reply, status(wait, State));
        {error, Error} ->
            reply_error({create_error, Error}, State)
    end.


%% @private
do_destroy_room(#state{room=Room}=State) ->
    {ok, Handle} = attach(videoroom, State),
    RoomId = to_room_id(Room),
    Body = #{request => destroy, room => RoomId},
    case message(Handle, Body, #{}, State) of
        {ok, Msg, _} ->
            Reply = case Msg of
                #{<<"videoroom">>:=<<"destroyed">>} ->
                    ok;
                #{<<"error_code">>:=426} ->
                    {error, room_not_found};
                #{<<"error">>:=Error} ->
                    {error, {destroy_error, Error}}
            end,
            detach(Handle, State),
            reply(Reply, status(wait, State));
        {error, Error} ->
            reply_error({destroy_error, Error}, State)
    end.



%% ===================================================================
%% Publisher
%% ===================================================================

%% @private Create session and join
do_publish(#{sdp:=SDP}, #state{room=Room, nkmedia_id=SessId} = State) ->
    {ok, Handle} = attach(videoroom, State),
    RoomId = to_room_id(Room),
    Feed = erlang:phash2(SessId),
    Body = #{
        request => join, 
        room => RoomId,
        ptype => publisher,
        display => SessId,
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
        nkmedia_id = SessId,
        opts = Opts
    } = State,
    DefFile = <<"publish_", SessId/binary>>,
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
            case nkmedia_janus_room:event(Room, {publish, SessId, Opts}) of
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
do_listen(Listen, #state{room=Room, nkmedia_id=SessId, opts=Opts}=State) ->
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
            case nkmedia_janus_room:event(Room, {listen, SessId, Opts}) of
                {ok, Pid} ->
                    Mon = erlang:monitor(process, Pid),
                    State3 = State2#state{room_mon=Mon},
                    reply({ok, #{sdp=>SDP}}, wait(listen_answer, State3));
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
do_from_sip_register(#state{janus_sess_id=Id}=State) ->
    {ok, Handle} = attach(sip, State),
    Ip = nklib_util:to_host(nkmedia_app:get(erlang_ip)),
    Port = nkmedia_app:get(sip_port),
    Body = #{
        request => register,
        proxy => <<"sip:", Ip/binary, ":",(nklib_util:to_binary(Port))/binary>>,
        username => <<"sip:", (nklib_util:to_binary(Id))/binary, "@nkmedia_janus_op">>,
        secret => <<"test">>
    },
    case message(Handle, Body, #{}, State) of
        {ok, #{<<"result">>:=#{<<"event">>:=<<"registering">>}}, _} ->
            State2 = State#state{handle_id=Handle},
            noreply(wait(from_sip, State2));
        {ok, #{<<"error">>:=Error}, _} ->
            reply_error(Error, State);
        {error, Error} ->
            reply_error({could_not_join, Error}, State)
    end.


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
    noreply(wait(from_sip_answer_1, State#state{offer=undefined})).


%% @private
do_from_sip_answer(#{sdp:=SDP}, From, State) ->
    #state{handle_id=Handle} = State,
    Body = #{request=>accept},
    Jsep = #{sdp=>SDP, type=>answer, trickle=>false},
    case message(Handle, Body, Jsep, State) of
        {ok, #{<<"result">>:=#{<<"event">>:=<<"accepted">>}}, _} ->
            noreply(wait(from_sip_invite, State#state{from=From}));
        {error, Error} ->
            reply_error({accepted_error, Error}, State)
    end.


%% @private
do_to_sip_register(State) ->
    {ok, Handle} = attach(sip, State),
    Ip = nklib_util:to_host(nkmedia_app:get(erlang_ip)),
    Port = nkmedia_app:get(sip_port),
    Body = #{
        request => register,
        proxy => <<"sip:", Ip/binary, ":",(nklib_util:to_binary(Port))/binary>>,
        type => guest
    },
    case message(Handle, Body, #{}, State) of
        {ok, #{<<"result">>:=#{<<"event">>:=<<"registered">>}}, _} ->
            State2 = State#state{handle_id=Handle},
            do_to_sip(State2);
        {ok, #{<<"error">>:=Error}, _} ->
            reply_error(Error, State);
        {error, Error} ->
            reply_error({could_not_join, Error}, State)
    end.


%% @private
do_to_sip(#state{janus_sess_id=Id, handle_id=Handle, offer=#{sdp:=SDP}}=State) ->
    Body = #{
        request => call,
        uri => <<"sip:", (nklib_util:to_binary(Id))/binary, "@nkmedia_janus_op">>
    },
    Jsep = #{sdp=>SDP, type=>offer},
    case message(Handle, Body, Jsep, State) of
        {ok, #{<<"result">>:=#{<<"event">>:=<<"calling">>}}, _} ->
            State2 = State#state{offer=undefined},
            noreply(wait(to_sip_invite, State2));
        {error, Error} ->
            reply_error({accepted_error, Error}, State)
    end.


%% @private
do_to_sip_answer(#{sdp:=SDP}, From, State) ->
    #state{sip_handle=Handle} = State,
    case nksip_request:reply({answer, SDP}, Handle) of
        ok ->
            noreply(wait(to_sip_reply, State#state{from=From}));
        {error, Error} ->
            reply_error({sip_error, Error}, State)
    end.


%% ===================================================================
%% Events
%% ===================================================================

%% @private
do_event(Id, Handle, {event, <<"incomingcall">>, _, #{<<"sdp">>:=SDP}}, State) ->
    case State of
        #state{status=wait, wait=videocall_offer, 
               janus_sess_id=Id, handle_id2=Handle} ->
            #state{from=From} = State,
            gen_server:reply(From, {ok, #{sdp=>SDP}}),
            State2 = State#state{from=undefined},
            noreply(wait(videocall_answer, State2));
        #state{status=wait, wait=from_sip_answer_1, 
               janus_sess_id=Id, handle_id=Handle} ->
            #state{from=From} = State,
            gen_server:reply(From, {ok, #{sdp=>SDP, sdp_type=>webrtc}}),
            State2 = State#state{from=undefined},
            noreply(wait(from_sip_answer_2, State2));
        _ ->
            ?LLOG(warning, "unexpected incomingcall", [], State),
            {stop, normal, State}
    end;

do_event(Id, Handle, {event, <<"accepted">>, _, #{<<"sdp">>:=SDP}}, State) ->
    case State of
        #state{status=wait, wait=videocall_reply, janus_sess_id=Id, handle_id=Handle} ->
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
        #state{status=wait, wait=to_sip_reply, janus_sess_id=Id, handle_id=Handle} ->
            lager:warning("ACCEPTED!"),


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
        #state{status=wait, wait=from_sip, sip_contact=Uri} when Uri /= undefined ->
            do_from_sip(State);
        #state{status=wait, wait=to_sip} ->
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
attach(Plugin, #state{janus_sess_id=SessId, conn=Pid}) ->
    nkmedia_janus_client:attach(Pid, SessId, nklib_util:to_binary(Plugin)).


%% @private
detach(Handle, #state{janus_sess_id=SessId, conn=Pid}) ->
    nkmedia_janus_client:detach(Pid, SessId, Handle).


%% @private
message(Handle, Body, Jsep, #state{janus_sess_id=SessId, conn=Pid}) ->
    case nkmedia_janus_client:message(Pid, SessId, Handle, Body, Jsep) of
        {ok, #{<<"data">>:=Data}, Jsep2} ->
            {ok, Data, Jsep2};
        {error, Error} ->
            {error, Error}
    end.


%% @private
destroy(#state{janus_sess_id=SessId, conn=Pid}) ->
    nkmedia_janus_client:destroy(Pid, SessId).


%% @private
keepalive(#state{janus_sess_id=SessId, conn=Pid}) ->
    nkmedia_janus_client:keepalive(Pid, SessId).


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
wait(Reason, State) ->
    State2 = status(wait, State),
    State2#state{wait=Reason}.


%% @private
status(NewStatus, #state{status=OldStatus, timer=Timer}=State) ->
    case NewStatus of
        OldStatus -> ok;
        _ -> ?LLOG(info, "status changed to ~p", [NewStatus], State)
    end,
    nklib_util:cancel_timer(Timer),
    Time = case NewStatus of
        wait -> ?WAIT_TIMEOUT;
        _ -> ?OP_TIMEOUT
    end,
    NewTimer = erlang:start_timer(1000*Time, self(), status_timeout),
    State#state{status=NewStatus, wait=undefined, timer=NewTimer}.


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
    do_call(SessId, Msg, 1000*?WAIT_TIMEOUT).


%% @private
do_call(SessId, Msg, Timeout) ->
    case find(SessId) of
        {ok, Pid} -> 
            nklib_util:call(Pid, Msg, Timeout);
        not_found -> 
            case start(SessId, <<>>) of
                {ok, Pid} ->
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
