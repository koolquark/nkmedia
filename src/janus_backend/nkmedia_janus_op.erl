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

%% @doc Janus Operations
%% A process is stared from nkmedia_janus_session for each operation
%% It monitors the session (nkmedia_session)
%% It starts and monitors a new connection to Janus

-module(nkmedia_janus_op).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start/2, stop/1, videocall/3, echo/3, play/3]).
-export([list_rooms/1, create_room/3, destroy_room/2]).
-export([publish/4, unpublish/1]).
-export([listen/4, listen_switch/3, unlisten/1]).
-export([from_sip/3, to_sip/3, to_sip_record/2]).
-export([nkmedia_sip_register/2, nkmedia_sip_invite/2]).
-export([answer/2, update/2]).
-export([get_all/0, stop_all/0, janus_event/4]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Janus OP ~s (~p ~p) "++Txt, 
               [State#state.nkmedia_id, State#state.janus_sess_id, State#state.status | Args])).

-include_lib("nksip/include/nksip.hrl").
-include("../../include/nkmedia.hrl").


-define(WAIT_TIMEOUT, 60).      % Secs
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
        publishers => integer()
    }.

-type media_opts() ::
    #{
        use_audio => boolean(),
        use_video => boolean(),
        use_data => boolean(),
        bitrate => integer(),
        record => boolean(),   
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
%% Starts a new Janus client
%% Monitors calling process
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


%% @doc Starts an echo session.
%% The SDP is returned.
-spec echo(pid()|janus_id(), nkmedia:offer(), media_opts()) ->
    {ok, nkmedia:answer()} | {error, nkservice:error()}.

echo(Id, Offer, Opts) ->
    OfferOpts = maps:with([use_audio, use_video, use_data], Offer),
    do_call(Id, {echo, Offer, maps:merge(OfferOpts, Opts)}).


%% @doc Starts a videocall inside the session.
%% The SDP offer for the remote party is returned.
%% You must call answer/2
-spec videocall(pid()|janus_id(), nkmedia:offer(), media_opts()) ->
    {ok, nkmedia:offer()} | {error, nkservice:error()}.

videocall(Id, Offer, Opts) ->
    do_call(Id, {videocall, Offer, Opts}).


%% @doc Starts playing a file
%% The offer SDP is returned.
-spec play(pid()|janus_id(), play(), media_opts()) ->
    {ok, nkmedia:offer()} | {error, nkservice:error()}.

play(Id, Play, Opts) ->
    do_call(Id, {play, Play, Opts}).


%% @doc List all videorooms
-spec list_rooms(pid()|janus_id()) ->
    {ok, list()} | {error, nkservice:error()}.

list_rooms(Id) ->
    do_call(Id, list_rooms).


%% @doc Creates a new videoroom
-spec create_room(pid()|janus_id(), room(), room_opts()) ->
    {ok, room()} | {error, nkservice:error()}.

create_room(Id, Room, Opts) ->
    do_call(Id, {create_room, to_room(Room), Opts}).


%% @doc Destroys a videoroom
-spec destroy_room(pid()|janus_id(), room()) ->
    ok | {error, nkservice:error()}.

destroy_room(Id, Room) ->
    do_call(Id, {destroy_room, to_room(Room)}).


%% @doc Starts a conection to a videoroom.
%% caller_id is taked from offer.
-spec publish(pid()|janus_id(), room(), nkmedia:offer(), media_opts()) ->
    {ok, nkmedia:answer()} | {error, nkservice:error()}.

publish(Id, Room, Offer, Opts) ->
    do_call(Id, {publish, to_room(Room), Offer, Opts}).


%% @doc Starts a conection to a videoroom.
%% caller_id is taked from offer.
-spec unpublish(pid()|janus_id()) ->
    ok | {error, nkservice:error()}.

unpublish(Id) ->
    do_call(Id, unpublish).


%% @doc Starts a conection to a videoroom
-spec listen(pid()|janus_id(), room(), nkmedia_session:id(), listen_opts()) ->
    {ok, nkmedia:offer()} | {error, nkservice:error()}.

listen(Id, Room, Listen, Opts) ->
    do_call(Id, {listen, to_room(Room), Listen, Opts}).


%% @doc Answers a listen
-spec listen_switch(pid()|janus_id(), nkmedia_session:id(), listen_opts()) ->
    ok | {error, nkservice:error()}.

listen_switch(Id, Listen, Opts) ->
    Listen2 = nklib_util:to_binary(Listen),
    do_call(Id, {listen_switch, Listen2, Opts}).


%% @doc
-spec unlisten(pid()|janus_id()) ->
    ok | {error, nkservice:error()}.

unlisten(Id) ->
    do_call(Id, unlisten).


%% @doc Receives a SIP offer, generates a WebRTC offer
%% You must call answer/2 when you have the WebRTC answer
-spec from_sip(pid()|janus_id(), nkmedia:offer(), #{}) ->
    {ok, nkmedia:offer()} | {error, nkservice:error()}.

from_sip(Id, Offer, Opts) ->
    do_call(Id, {from_sip, Offer, Opts}).


%% @doc Receives an WebRTC offer, generates a SIP offer
%% You must call answer/2 when you have the SIP answer
-spec to_sip(pid()|janus_id(), nkmedia:offer(), #{}) ->
    {ok, nkmedia:offer()} | {error, nkservice:error()}.

to_sip(Id, Offer, Opts) ->
    do_call(Id, {to_sip, Offer, Opts}).


to_sip_record(Id, Opts) ->
    do_call(Id, {to_sip_record, Opts}).


%% @doc Answers a pending request
%% Get Janus' answer (except for listen and play)
-spec answer(pid()|janus_id(), nkmedia:answer()) ->
    ok | {ok, nkmedia:answer()} | {error, nkservice:error()}.

answer(Id, Answer) ->
    do_call(Id, {answer, Answer}).


%% @doc Updates a session
-spec update(pid()|janus_id(), media_opts()) ->
    ok | {error, nkservice:error()}.

update(Id, Update) ->
    do_call(Id, {update, Update}).


%% @private
-spec get_all() ->
    [{JanusSessId::term(), nkmedia:session_id(), pid()}].

get_all() ->
    [{JSId, SId, Pid} || {{JSId, SId}, Pid}<- nklib_proc:values(?MODULE)].



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
            {reply, ringing};
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
            nklib_proc:put(?MODULE, {JanusSessId, MediaSessId}),
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
    do_echo(Offer, State#state{opts=Opts});

handle_call({play, File, Opts}, _From, #state{status=wait}=State) -> 
    do_play(File, State#state{opts=Opts});

handle_call({videocall, Offer, Opts}, From, #state{status=wait}=State) -> 
    do_videocall(Offer, From, State#state{opts=Opts});

handle_call(list_rooms, _From, #state{status=wait}=State) -> 
    do_list_rooms(State);

handle_call({create_room, Room, Opts}, _From, #state{status=wait}=State) -> 
    do_create_room(State#state{room=Room, opts=Opts});

handle_call({destroy_room, Room}, _From, #state{status=wait}=State) -> 
    do_destroy_room(State#state{room=Room});

handle_call({publish, Room, Offer, Opts}, _From, #state{status=wait}=State) -> 
    do_publish(Offer, State#state{room=Room, opts=Opts});

handle_call(upublish, _From, #state{status=publish}=State) -> 
    do_unpublish(State);

handle_call({listen, Room, Listen, Opts}, _From, #state{status=wait}=State) -> 
    do_listen(Listen, State#state{room=Room, opts=Opts});

handle_call({listen_switch, Listen, Opts}, _From, #state{status=listen}=State) -> 
    #state{opts=Opts0} = State,
    do_listen_switch(Listen, State#state{opts=maps:merge(Opts0, Opts)});

handle_call(unlisten, _From, #state{status=listen}=State) -> 
    do_unlisten(State);

handle_call({from_sip, Offer, Opts}, From, #state{status=wait}=State) ->
    % We tell Janus to register, wait the registration and
    % call do_from_sip/1
    do_from_sip_register(State#state{from=From, offer=Offer, opts=Opts});

handle_call({to_sip, Offer, Opts}, From, #state{status=wait}=State) ->
    lager:warning("Opts: ~p", [Opts]),
    do_to_sip_register(State#state{from=From, offer=Offer, opts=Opts});

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
            reply_stop({error, invalid_state}, State)
    end;

handle_call({update, Opts}, _From, #state{status=Status, opts=Opts0}=State) ->
    State2 = State#state{opts=maps:merge(Opts0, Opts)},
    case Status of
        echo -> 
            do_echo_update(Opts, State2);
        videocall ->
            do_videocall_update(Opts, State2);
        publish ->
            do_publish_update(Opts, State2);
        sip ->
            do_sip_update(Opts, State2);
        _ ->
            reply_stop({error, invalid_state}, State2)
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
    ?LLOG(info, "hangup from janus (~s)", [Reason], State),
    {stop, normal, State};

handle_cast({event, _Id, _Handle, #{<<"janus">>:=<<"webrtcup">>}}, State) ->
    ?LLOG(info, "WEBRTC UP", [], State),
    {noreply, State};

handle_cast({event, _Id, _Handle, #{<<"janus">>:=<<"media">>}=Msg}, State) ->
    #{<<"type">>:=Type, <<"receiving">>:=Bool} = Msg,
    ?LLOG(info, "WEBRTC Media ~s: ~s", [Type, Bool], State),
    {noreply, State};

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

handle_info({'DOWN', Ref, process, _Pid, Reason}, #state{conn_mon=Ref}=State) ->
    ?LLOG(notice, "client monitor stop: ~p", [Reason], State),
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

terminate(Reason, State) ->
    #state{from=From, status=Status} = State,
    case Status of
        publisher ->
            #state{room=Room, nkmedia_id=SessId} = State,
            nkmedia_janus_room:event(Room, {unpublish, SessId});
        listener ->
            #state{room=Room, nkmedia_id=SessId} = State,
            nkmedia_janus_room:event(Room, {unlisten, SessId});
        _ ->
            ok
    end,
    destroy(State),
    ?LLOG(info, "process stop: ~p", [Reason], State),
    nklib_util:reply(From, {error, process_down}),
    ok.


%% ===================================================================
%% Echo
%% ===================================================================

%% @private Echo plugin
do_echo(#{sdp:=SDP}, #state{opts=Opts}=State) ->
    {ok, Handle} = attach(echotest, State),
    Body = get_body(Opts),
    Jsep = #{sdp=>SDP, type=>offer, trickle=>false},
    case message(Handle, Body, Jsep, State) of
        {ok, #{<<"result">>:=<<"ok">>}, #{<<"sdp">>:=SDP2}} ->
            State2 = State#state{handle_id=Handle},
            reply({ok, #{sdp=>SDP2}}, status(echo, State2));
        {error, Error} ->
            ?LLOG(notice, "echo error: ~p", [Error], State),
            reply_stop({error, Error}, State)
    end.


%% @private
do_echo_update(Opts, #state{handle_id=Handle}=State) ->
    Body = update_body(Opts),
    case message(Handle, Body, #{}, State) of
        {ok, #{<<"result">>:=<<"ok">>}, _} ->
            reply(ok, State);
        {error, Error} ->
            ?LLOG(notice, "echo update error: ~p", [Error], State),
            reply({error, Error}, State)
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
                        {error, Error} ->
                            ?LLOG(notice, "play error1: ~p", [Error], State),
                            reply_stop({error, Error}, State2)
                    end;
                {error, Error} ->
                    ?LLOG(notice, "play error2: ~p", [Error], State),
                    reply_stop({error, Error}, State2)
            end;
        {error, Error} ->
            ?LLOG(notice, "play error3: ~p", [Error], State),
            reply_stop({error, Error}, State2)
    end.
    

%% @private Caller answers
do_play_answer(#{sdp:=SDP}, #state{handle_id=Handle} = State) ->
    Body = #{request=>start},
    Jsep = #{sdp=>SDP, type=>answer, trickle=>false},
    case message(Handle, Body, Jsep, State) of
        {ok, #{<<"result">>:=#{<<"status">>:=<<"playing">>}}, _} ->
            reply(ok, status(play, State));
        {error, Error} ->
            ?LLOG(notice, "play answer error: ~p", [Error], State),
            reply_stop({error, Error}, State)
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
            ?LLOG(notice, "videocall error1: ~p", [Error], State),
            reply_stop({error, Error}, State)
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
            ?LLOG(notice, "videocall error2: ~p", [Error], State),
            reply({error, Error}, State)
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
            ?LLOG(notice, "videocall error3: ~p", [Error], State),
            reply_stop({error, Error}, State)
    end.


%% @private. We receive answer from called party and wait Janus
do_videocall_answer(#{sdp:=SDP}, From, State) ->
    #state{opts=Opts, handle_id2=Handle2} = State,
    Body = #{request=>accept},
    Jsep = #{sdp=>SDP, type=>answer, trickle=>false},
    case message(Handle2, Body, Jsep, State) of
        {ok, #{<<"result">>:=#{<<"event">>:=<<"accepted">>}}, _} ->
            Set1 = get_body(append_file(Opts, <<"b">>)),
            Set2 = Set1#{request=>set},
            case message(Handle2, Set2, #{}, State) of
                {ok, #{<<"result">>:=#{<<"event">>:=<<"set">>}}, _} ->
                    State2 = State#state{from=From},
                    noreply(wait(videocall_reply, State2));
                {error, Error} ->
                    ?LLOG(notice, "videocall error4: ~p", [Error], State),
                    reply_stop({error, Error}, State)
            end;
        {error, Error} ->
            ?LLOG(notice, "videocall error5: ~p", [Error], State),
            reply_stop({error, Error}, State)
    end.


%% @private
do_videocall_update(Opts, #state{handle_id=Handle1, handle_id2=Handle2}=State) ->
    BodyA = update_body(append_file(Opts, <<"a">>)),
    case message(Handle1, BodyA#{request=>set}, #{}, State) of
        {ok, #{<<"result">> := #{<<"event">>:=<<"set">>}}, _} ->
            BodyB = update_body(append_file(Opts, <<"b">>)),
            case message(Handle2, BodyB#{request=>set}, #{}, State) of
                {ok, #{<<"result">>:=#{<<"event">>:=<<"set">>}}, _} ->
                    reply(ok, State);
                {error, Error} ->
                    ?LLOG(notice, "videocall update1 error: ~p", [Error], State),
                    reply({error, Error}, State)
            end;
        {error, Error} ->
            ?LLOG(notice, "videocall update2 error: ~p", [Error], State),
            reply({error, Error}, State)
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
            % detach(Handle, State),
            reply_stop({ok, maps:from_list(List2)}, State);
        {error, Error} ->
            ?LLOG(notice, "list_rooms error: ~p", [Error], State),
            reply_stop({error, Error}, State)
    end.


%% @private
do_create_room(#state{room=Room, opts=Opts}=State) ->
    {ok, Handle} = attach(videoroom, State),
    RoomId = to_room_id(Room),
    Body = #{
        request => create, 
        description => nklib_util:to_binary(Room),
        bitrate => maps:get(bitrate, Opts, 128000),
        publishers => 1000,
        audiocodec => maps:get(audiocodec, Opts, opus),
        videocodec => maps:get(videocodec, Opts, vp8),
        % record => maps:get(record, Opts, false),
        is_private => false,
        permanent => false,
        room => RoomId
        % fir_freq
    },
    case message(Handle, Body, #{}, State) of
        {ok, Msg, _} ->
            #{<<"videoroom">>:=<<"created">>, <<"room">>:=RoomId} = Msg,
            reply_stop(ok, State);
        {error, Error} ->
            reply_stop({error, Error}, State)
    end.


%% @private
%% Connected peers will receive event from Janus and will stop
do_destroy_room(#state{room=Room}=State) ->
    {ok, Handle} = attach(videoroom, State),
    RoomId = to_room_id(Room),
    Body = #{request => destroy, room => RoomId},
    case message(Handle, Body, #{}, State) of
        {ok, Msg, _} ->
            #{<<"videoroom">>:=<<"destroyed">>} = Msg,
            reply_stop(ok, State);
        {error, Error} ->
            ?LLOG(notice, "destroy_room error: ~p", [Error], State),
            reply_stop({error, Error}, State)
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
        {error, Error} ->
            ?LLOG(notice, "publish error1: ~p", [Error], State),
            reply_stop({error, Error}, State)
    end.


%% @private
do_publish_2(SDP_A, State) ->
    #state{
        handle_id = Handle, 
        room = Room, 
        nkmedia_id = SessId,
        opts = Opts
    } = State,
    Body = get_body(Opts),
    Jsep = #{sdp=>SDP_A, type=>offer, trickle=>false},
    case message(Handle, Body#{request=>configure}, Jsep, State) of
        {ok, #{<<"configured">>:=<<"ok">>}, #{<<"sdp">>:=SDP_B}} ->
            case nkmedia_janus_room:event(Room, {publish, SessId}) of
                {ok, Pid} ->
                    Mon = erlang:monitor(process, Pid),
                    State2 = State#state{room_mon=Mon},
                    reply({ok, #{sdp=>SDP_B}}, status(publish, State2));
                {error, Error} ->
                    ?LLOG(notice, "publish error2: ~p", [Error], State),
                    reply_stop({error, room_not_found}, State)
            end;
        {error, Error} ->
            ?LLOG(notice, "publish error3: ~p", [Error], State),
            reply_stop({error, Error}, State)
    end.


%% @private
do_unpublish(#state{handle_id=Handle} = State) ->
    Body = #{request => unpublish},
    case message(Handle, Body, #{}, State) of
        {ok, #{<<"videoroom">>:=<<"unpublished">>}, _} ->
            reply_stop(ok, State);
        {error, Error} ->
            ?LLOG(notice, "unpublish error: ~p", [Error], State),
            reply_stop({error, Error}, State)
    end.


%% @private
do_publish_update(Opts, #state{handle_id=Handle}=State) ->
    Body = update_body(Opts),
    case message(Handle, Body#{request=>configure}, #{}, State) of
        {ok, #{<<"configured">>:=<<"ok">>}, _} ->
            reply(ok, State);
        {error, Error} ->
            ?LLOG(notice, "publish update error: ~p", [Error], State),
            reply({error, Error}, State)
    end.



%% ===================================================================
%% Listener
%% ===================================================================


%% @private Create session and join
do_listen(Listen, #state{room=Room, nkmedia_id=SessId, opts=Opts}=State) ->
    {ok, Handle} = attach(videoroom, State),
    Feed = erlang:phash2(Listen),
    Body1 = get_body(Opts),
    Body2 = Body1#{
        request => join, 
        room => to_room_id(Room),
        ptype => listener,
        feed => Feed
    },
    case message(Handle, Body2, #{}, State) of
        {ok, #{<<"videoroom">>:=<<"attached">>}, #{<<"sdp">>:=SDP}} ->
            State2 = State#state{handle_id=Handle},
            case nkmedia_janus_room:event(Room, {listen, SessId, Listen}) of
                {ok, Pid} ->
                    Mon = erlang:monitor(process, Pid),
                    State3 = State2#state{room_mon=Mon},
                    reply({ok, #{sdp=>SDP}}, wait(listen_answer, State3));
                {error, Error} ->
                    ?LLOG(notice, "listen error1: ~p", [Error], State),
                    reply_stop({error, room_not_found}, State)
            end;
        {error, Error} ->
            ?LLOG(notice, "listen error2: ~p", [Error], State),
            reply_stop({error, Error}, State)
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
            ?LLOG(notice, "listen answer error: ~p", [Error], State),
            reply_stop({error, Error}, State)
    end.


%% @private Create session and join
do_listen_switch(Listen, State) ->
    #state{handle_id=Handle, nkmedia_id=SessId, room=Room, opts=Opts} = State,
    Feed = erlang:phash2(Listen),
    Body1 = get_body(Opts),
    Body2 = Body1#{
        request => switch,        
        feed => Feed
    },
    case message(Handle, Body2, #{}, State) of
        {ok, #{<<"switched">>:=<<"ok">>}, _} ->
            Opts2 = Opts#{publisher=>Listen},
            {ok, _} = nkmedia_janus_room:event(Room, {listen, SessId, Opts2}),
            reply(ok, State);
        {error, Error} ->
            ?LLOG(notice, "listen switch error: ~p", [Error], State),
            reply({error, Error}, State)
    end.


%% @private
do_unlisten(#state{handle_id=Handle}=State) ->
    Body = #{request => leave},
    case message(Handle, Body, #{}, State) of
        {ok, #{<<"videoroom">>:=<<"unpublished">>}, _} ->
            reply_stop(ok, State);
        {error, Error} ->
            ?LLOG(notice, "unlisten error: ~p", [Error], State),
            reply_stop({error, Error}, State)
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
        {error, Error} ->
            ?LLOG(notice, "from_sip error: ~p", [Error], State),
            reply_stop({error, Error}, State)
    end.


%% @private
do_from_sip(#state{sip_contact=Contact, offer=Offer}=State) ->
    Self = self(),
    spawn_link(
        fun() ->
            % We call Janus using SIP
            Result = case nkmedia_core:invite(Contact, Offer) of
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
            ?LLOG(notice, "from_sip answer error: ~p", [Error], State),
            reply_stop({error, Error}, State)
    end.


%% @private
do_to_sip_register(State) ->
    {ok, Handle} = attach(sip, State),
    Ip = nklib_util:to_host(nkmedia_app:get(erlang_ip)),
    Port = nkmedia_app:get(sip_port),
    Body = #{
        request => register,
        proxy => <<"sip:", Ip/binary, ":",(nklib_util:to_binary(Port))/binary>>,
        type => guest,
        username => <<"sip:test@test">>
    },
    case message(Handle, Body, #{}, State) of
        {ok, #{<<"result">>:=#{<<"event">>:=<<"registered">>}}, _} ->
            State2 = State#state{handle_id=Handle},
            do_to_sip(State2);
        {error, Error} ->
            ?LLOG(notice, "to_sip error1: ~p", [Error], State),
            reply_stop({error, Error}, State)
    end.


%% @private
do_to_sip(#state{janus_sess_id=Id, handle_id=Handle, offer=#{sdp:=SDP}}=State) ->
    SDP2 = remove_sdp_application(SDP),
    Body = #{
        request => call,
        uri => <<"sip:", (nklib_util:to_binary(Id))/binary, "@nkmedia_janus_op">>
    },
    Jsep = #{sdp=>SDP2, type=>offer, trickle=>false},
    case message(Handle, Body, Jsep, State) of
        {ok, #{<<"result">>:=#{<<"event">>:=<<"calling">>}}, _} ->
            State2 = State#state{offer=undefined},
            noreply(wait(to_sip_invite, State2));
        {error, Error} ->
            ?LLOG(notice, "to_sip error2: ~p", [Error], State),
            reply_stop({error, Error}, State)
    end.


%% @private
do_to_sip_answer(#{sdp:=SDP}, From, State) ->
    #state{sip_handle=Handle} = State,
    Body = nksip_sdp:parse(SDP),
    case nksip_request:reply({answer, Body}, Handle) of
        ok ->
            noreply(wait(to_sip_reply, State#state{from=From}));
        {error, Error} ->
            ?LLOG(notice, "to_sip answer: ~p", [Error], State),
            reply_stop({error, {sip_error, Error}}, State)
    end.


%% @private
do_sip_update(#{record:=_}, #state{handle_id=Handle, opts=Opts}=State) ->
    Audio = maps:get(use_audio, Opts, true),
    Video = maps:get(use_video, Opts, true),
    Body1 = #{
        request => recording,
        audio => Audio,
        video => Video,
        peer_audio => Audio,
        peer_video => Video
    },
    Body2 = case Opts of
        #{record:=true, filename:=Filename} ->
            Body1#{action => start, filename => Filename};
        _ ->
            Body1#{action => stop}
    end,
    case message(Handle, Body2, #{}, State) of
        {ok, #{<<"result">>:=#{<<"event">>:=<<"recordingupdated">>}}, _} ->
            reply(ok, State);
        {error, Error} ->
            ?LLOG(notice, "sip update error: ~p", [Error], State),
            reply({error, Error}, State)
    end;

do_sip_update(#{dtmf:=DTMF}, #state{handle_id=Handle}=State) ->
    Body = #{
        request => dtmf_info,
        digit => DTMF
    },
    case message(Handle, Body, #{}, State) of
        {ok, #{<<"sip">>:=<<"event">>}, _} ->
            reply(ok, State);
        {error, Error} ->
            ?LLOG(notice, "sip update error: ~p", [Error], State),
            reply({error, Error}, State)
    end;

do_sip_update(_Opts, State) ->
    reply({error, invalid_parameters}, State).



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
            #state{from=From, opts=Opts} = State,
            gen_server:reply(From, {ok, #{sdp=>SDP}}),
            Set1 = get_body(append_file(Opts, <<"a">>)),
            Set2 = Set1#{request=>set},
            case message(Handle, Set2, #{}, State) of
                {ok, #{<<"result">>:=#{<<"event">>:=<<"set">>}}, _} ->
                    State2 = State#state{from=undefined},
                    noreply(status(videocall, State2));
                {error, Error} ->
                    ?LLOG(warning, "error sending set: ~p", [Error], State),
                    {stop, normal, State}
            end;
        #state{status=wait, wait=to_sip_reply, janus_sess_id=Id, handle_id=Handle} ->
            #state{from=From, opts=Opts} = State,
            State2 = State#state{from=undefined},
            case Opts of
                #{record:=true} ->
                    case do_sip_update(#{record=>true}, State2) of
                        {reply, ok, State3, _} ->
                            gen_server:reply(From, {ok, #{sdp=>SDP}}),
                            noreply(status(sip, State3));
                        {error, _Error, State3} ->
                            {stop, normal, State3}
                    end;
                _ ->
                    noreply(status(sip, State2))
            end;
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

do_event(_Id, _Handle, {event, <<"proceeding">>, _, _}, State) ->
    {noreply, State};

do_event(_Id, _Handle, {event, <<"hangingup">>, _, _}, State) ->
    {noreply, State};

do_event(_Id, _Handle, {event, <<"registration_failed">>, _, _}, State) ->
    ?LLOG(warning, "registration error", [], State),
    {stop, normal, State};

do_event(_Id, _Handle, {event, <<"hangup">>, _, _}, State) ->
    ?LLOG(notice, "hangup from Janus", [], State),
    {stop, normal, State};

do_event(_Id, _Handle, 
         {data, #{<<"videoroom">>:=<<"slow_link">>, <<"current-bitrate">>:=BR}}, 
         State) ->
    ?LLOG(notice, "videroom slow_link (~p)", [BR], State),
    {noreply, State};

do_event(_Id, _Handle, {data, #{<<"result">>:=Result}}, State) ->
    case Result of
        #{<<"status">>:=Status, <<"bitrate">>:=Bitrate} ->
            ?LLOG(notice, "status: ~s, bitrate: ~p", [Status, Bitrate], State);
        _ ->
            ?LLOG(warning, "unexpected result: ~p", [Result], State)
    end,
    {noreply, State};

do_event(_Id, _Handle, {data, #{<<"unpublished">>:=_User, <<"room">>:=_Room}}, State) ->
    % ?LLOG(notice, "unpublished: ~p (room ~p)", [Id, Room], State),
    {noreply, State};

do_event(_Id, _Handle, {data, #{<<"leaving">>:=_User, <<"room">>:=_Room}}, State) ->
    % ?LLOG(notice, "leaving: ~p (room ~p)", [Id, Room], State),
    {noreply, State};

do_event(_Id, _Handle, Event, State) ->
    ?LLOG(warning, "unexpected event: ~p", [Event], State),
    noreply(State).




%% ===================================================================
%% Internal
%% ===================================================================

%% @private
attach(Plugin, #state{janus_sess_id=SessId, conn=Pid}) ->
    nkmedia_janus_client:attach(Pid, SessId, nklib_util:to_binary(Plugin)).


% %% @private
% detach(Handle, #state{janus_sess_id=SessId, conn=Pid}) ->
%     nkmedia_janus_client:detach(Pid, SessId, Handle).


%% @private
message(Handle, Body, Jsep, #state{janus_sess_id=SessId, conn=Pid}) ->
    case nkmedia_janus_client:message(Pid, SessId, Handle, Body, Jsep) of
        {ok, #{<<"data">>:=Data}, Jsep2} ->
            case Data of
                #{<<"error">>:=Error, <<"error_code">>:=Code} ->
                    Error2 = case Code of
                        413 -> invalid_parameters;
                        426 -> room_not_found;
                        428 -> invalid_publisher;
                        465 -> invalid_sdp;
                        427 -> room_already_exists;
                        444 -> invalid_parameters;
                        _ -> 
                            lager:notice("Unknown Janus error (~p): ~s", [Code, Error]),
                            janus_error
                    end,
                    {error, Error2};
                _ ->
                    {ok, Data, Jsep2}
            end;
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
            nkservice_util:call(Pid, Msg, Timeout);
        not_found -> 
            case start(SessId, <<>>) of
                {ok, Pid} ->
                    nkservice_util:call(Pid, Msg, Timeout);
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
get_body(Opts) ->
    #{
        audio => maps:get(use_audio, Opts, true),
        video => maps:get(use_video, Opts, true),
        data => maps:get(use_data, Opts, true),
        bitrate => maps:get(bitrate, Opts, 0),
        record => maps:get(record, Opts, false),
        filename => maps:get(filename, Opts, <<>>)
    }.


%% @private
update_body(Opts) ->
    Body = [
        case maps:find(use_audio, Opts) of
            {ok, Audio} -> {audio, Audio};
            error -> []
        end,
        case maps:find(use_video, Opts) of
            {ok, Video} -> {video, Video};
            error -> []
        end,
        case maps:find(use_data, Opts) of
            {ok, Data} -> {data, Data};
            error -> []
        end,
        case maps:find(bitrate, Opts) of
            {ok, Bitrate} -> {bitrate, Bitrate};
            error -> []
        end,
        case maps:find(record, Opts) of
            {ok, Record} -> {record, Record};
            error -> []
        end,
        case maps:find(filename, Opts) of
            {ok, Filename} -> {filename, Filename};
            error -> []
        end
    ],
    maps:from_list(lists:flatten(Body)).


append_file(Opts, Txt) ->
    case Opts of
        #{filename:=File} ->
            Opts#{filename:=<<File/binary, $_, Txt/binary>>};
        _ ->
            Opts
    end.


%% @private Removes the datachannel (m=application)
remove_sdp_application(SDP) ->
    #sdp{medias=Medias} = SDP2 = nksip_sdp:parse(SDP),
    Medias2 = [Media || #sdp_m{media=Name}=Media <- Medias, Name /= <<"application">>],
    SDP3 = SDP2#sdp{medias=Medias2},
    nksip_sdp:unparse(SDP3).


%% @private
to_room(Room) when is_integer(Room) -> Room;
to_room(Room) -> nklib_util:to_binary(Room).


%% @private
to_room_id(Room) when is_integer(Room) -> Room;
to_room_id(Room) when is_binary(Room) -> erlang:phash2(Room).


