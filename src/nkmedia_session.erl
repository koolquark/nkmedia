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

%% @doc Session Management


-module(nkmedia_session).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start/2, get_status/1, get_session/1]).
-export([hangup/1, hangup/2, hangup_all/0]).
-export([set_offer/3, set_answer/3, set_pbx/3]).
-export([invite_reply/2]).
-export([pbx_event/3, call_event/3, get_all/0, find/1]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, config/0, status/0, session/0, event/0]).
-export_type([call_dest/0]).


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Session ~s (~p, ~p) "++Txt, 
               [State#state.id, State#state.type, State#state.status | Args])).

-include("nkmedia.hrl").

%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().

-type config() :: 
    #{
        id => id(),                             % Generated if not included
        type => type(),
        offer => nkmedia:offer(),               
        answer => nkmedia:offer(),              
        mediaserver => mediaserver(),           % Forces mediaserver
        wait_timeout => integer(),              % Secs
        ring_timeout => integer(),          
        call_timeout => integer(),
        class => term(),                        % For user or caller
        monitor => pid()                        % Monitor this process
}.

-type type() :: p2p | proxy | pbx.

-type call_dest() :: term().

-type status() ::
    wait      |   % Waiting for an operation, no media
    offer     |   % We have an offer, waiting for operation
    calling   |   % Launching an invite
    ringing   |   % Received 'ringing'
    answer    |   % We have offer and answer, waiting for operation
    echo      |   % We are sending echo
    call      |   % Session is connected to another
    mcu       | 
    publisher |
    listener  | 
    hangup.


%% Extended status
-type ext_status() ::
    #{
        offer => nkmedia:offer(),               % For 'offer' status
        dest => binary(),                       % For 'calling' status
        answer => nkmedia:answer(),             % For ringing, answer

        peer => id(),                           % Bridged, p2p
        room_name => binary(),                  % For mcu
        room_member => binary(),
        hangup_reason => nkmedia_util:hangup_reason()
    }.


-type session() ::
    config () | 
    #{
        srv_id => nkservice:id(),
        status => status(),
        ext_status => ext_status()
    }.

-type offer_op() ::
    nkmedia:offer() |                               % Set raw offer 
    {listener, Room::integer(), User::integer()}.   % Get offer from listener


-type answer_op() ::
    nkmedia:answer()             |      % Set raw answer
    echo                         |      % Perform media echo
    {mcu, Room::binary()}        |      % Connect offer to mcu
    {publisher, Room::integer()} |      % Connect offer to publisher
    {call, Dest::call_dest()}    |      % Get answer from complex call
    {invite, Dest::call_dest()}.        % Get answer from invite


-type pbx_op() ::
    echo                         |      % Perform media echo
    {mcu, Room::binary()}        |      % Connect offer to mcu
    {call, Dest::call_dest()}    |      % Get answer from complex call
    {invite, Dest::call_dest()}.        % Get answer from invite


-type op_opts() ::  
    #{
        type => type(),                     % You can set the type
        sync => boolean(),                  % Wait for session reply
        get_offer => boolean(),             % Return the offer        
        get_answer => boolean()            % Return the answer

    }.


-type op_result() ::  
    #{
        offer => nkmedia:offer(),           % if asked to, the offer is returned
        answer => nkmedia:answer()          % if asked to, the answer is returned
    }.


-type invite_reply() :: 
    ringing |                           % Informs invite is ringing
    {ringing, nkmedia:answer()} |       % The same, with answer
    {answered, nkmedia:answer()}.       % Invite is answered


-type event() ::
    {status, status(), ext_status()} | 
    {info, term()}.


-type pbx_event() ::
    parked | {hangup, term()} | {bridge, id()} | {mcu, map()}.


-type mediaserver() ::
    {fs, nkmedia_fs:id()} | {janus, nkmedia_janus:id()}.



%% ===================================================================
%% Public
%% ===================================================================

%% @private
-spec start(nkservice:id(), config()) ->
    {ok, id(), pid()} | {error, term()}.

start(Service, Config) ->
    case nkservice_srv:get_srv_id(Service) of
        {ok, SrvId} ->
            Config2 = Config#{srv_id=>SrvId},
            {SessId, Config3} = nkmedia_util:add_uuid(Config2),
            {ok, SessPid} = gen_server:start(?MODULE, [Config3], []),
            {ok, SessId, SessPid};
        not_found ->
            {error, service_not_found}
    end.


%% @doc Get current session data
-spec get_session(id()) ->
    {ok, session()} | {error, term()}.

get_session(SessId) ->
    do_call(SessId, get_session).


%% @doc Get current status and remaining time to timeout
-spec get_status(id()) ->
    {ok, status(), ext_status(), integer()}.

get_status(SessId) ->
    do_call(SessId, get_status).


%% @doc Hangups the session
-spec hangup(id()) ->
    ok | {error, term()}.

hangup(SessId) ->
    hangup(SessId, 16).


%% @doc Hangups the session
-spec hangup(id(), nkmedia:hangup_reason()) ->
    ok | {error, term()}.

hangup(SessId, Reason) ->
    do_cast(SessId, {hangup, Reason}).


%% @private Hangups all sessions
hangup_all() ->
    lists:foreach(fun({SessId, _Pid}) -> hangup(SessId) end, get_all()).


%% @doc Sets the session's offer, if not already set
%% You can not only set a raw offer(), but order the session to get the
%% offer from some other operation, like being a listener
-spec set_offer(id(), offer_op(), op_opts()) ->
    ok | {ok, op_result()} | {error, term()}.

set_offer(SessId, OfferOp, #{sync:=true}=Opts) ->
    do_call(SessId, {offer_op, OfferOp, Opts});

set_offer(SessId, OfferOp, Opts) ->
    do_cast(SessId, {offer_op, OfferOp, Opts}).


%% @doc Sets the session's answer, if not already set
%% You can raw answer(), or order the session to get the
%% answer from some other operation, like inviting or publishing
-spec set_answer(id(), answer_op(), op_opts()) ->
    ok | {ok, op_result()} | {error, term()}.

set_answer(SessId, AnswerOp, #{sync:=true}=Opts) ->
    do_call(SessId, {answer_op, AnswerOp, Opts});

set_answer(SessId, AnswerOp, Opts) ->
    do_cast(SessId, {answer_op, AnswerOp, Opts}).


%% @doc Sets the session's answer, if not already set
%% You can raw answer(), or order the session to get the
%% answer from some other operation, like inviting or publishing
-spec set_pbx(id(), pbx_op(), op_opts()) ->
    ok | {ok, op_result()} | {error, term()}.

set_pbx(SessId, PbxOp, #{sync:=true}=Opts) ->
    do_call(SessId, {answer_op, PbxOp, Opts});

set_pbx(SessId, PbxOp, Opts) ->
    do_cast(SessId, {answer_op, PbxOp, Opts}).


%% @doc Informs the session of a ringing or answered status for an invite
-spec invite_reply(id(), invite_reply()) ->
    ok | {error, term()}.

invite_reply(SessId, Reply) ->
    do_cast(SessId, {invite_reply, Reply}).


%% @private
-spec get_all() ->
    [{id(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).



%% ===================================================================
%% Internal
%% ===================================================================

%% @private Called from nkmedia_fs_engine and nkmedia_fs_verto
-spec pbx_event(id(), nkmedia_fs:id(), pbx_event()) ->
    ok.

pbx_event(SessId, FsId, Event) ->
    case do_cast(SessId, {pbx_event, FsId, Event}) of
        ok -> 
            ok;
        {error, _} when Event==stop ->
            ok;
        {error, _} -> 
            lager:warning("NkMEDIA Session: pbx event ~p for unknown session ~s", 
                          [Event, SessId])
    end.


%% @private Called from nkmedia_callbacks:nkmedia_call_event when a 
%% call has an event for us.
call_event(SessPid, CallId, Event) ->
    do_cast(SessPid, {call_event, CallId, Event}).



% ===================================================================
%% gen_server behaviour
%% ===================================================================

-type link_id() ::
    user | janus | invite | {call, nkmedia_call:id()}.

-type from_id() ::
    {call, nkmedia_call:id()} | invite.

-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    type :: type(),
    status :: status() | init,
    has_offer = false :: boolean(),
    has_answer = false :: boolean(),
    ms :: mediaserver(),
    links = [] :: [{link_id(), pid(), reference()}],
    froms = [] :: [{from_id(), {pid(), term()}, op_opts()}],
    timer :: reference(),
    session :: session()
}).


%% @private
-spec init(term()) ->
    {ok, #state{}} | {error, term()}.

init([#{id:=Id, srv_id:=SrvId}=Session]) ->
    true = nklib_proc:reg({?MODULE, Id}),
    nklib_proc:put(?MODULE, Id),
    State1 = #state{
        id = Id, 
        srv_id = SrvId, 
        status = init,
        ms = maps:get(mediaserver, Session, undefined),
        session = Session
    },
    lager:info("NkMEDIA Session ~s starting (~p)", [Id, self()]),
    UserPid = maps:get(monitor, Session, undefined),
    State2 = add_link(user, UserPid, State1),
    {ok, State3} = handle(nkmedia_session_init, [Id], State2),
    #state{session=Session2} = State3,
    % Process type, offer and answer. Send offer and answer status.
    case update_config(Session2, State3) of
        {ok, State4} ->
            {ok, State4};
        {error, Error} ->
            ?LLOG(warning, "session start error: ~p", [Error], State3),
            {stop, Error}
    end.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(get_session, _From, #state{session=Session}=State) ->
    {reply, {ok, Session}, State};

handle_call(get_status, _From, State) ->
    #state{status=Status, timer=Timer, session=Session} = State,
    #{ext_status:=Info} = Session,
    {reply, {ok, Status, Info, erlang:read_timer(Timer) div 1000}, State};

handle_call({offer_op, OfferOp, Opts}, From, #state{has_offer=false}=State) ->
    do_offer_op(OfferOp, Opts, From, State);

handle_call({offer_op, _OfferOp, _Opts}, _From, State) ->
    {reply, {error, offer_already_set}, State};

handle_call({answer_op, AnswerOp, Opts}, From, #state{has_answer=false}=State) ->
    do_answer_op(AnswerOp, Opts, From, State);

handle_call({answer_op, _AnswerOp, _Opts}, _From, State) ->
    {reply, {error, answer_already_set}, State};

handle_call({pbx_op, PbxOp, Opts}, From, 
            #state{type=pbx, has_offer=true, has_answer=true}=State) ->
    do_pbx_op(PbxOp, Opts, From, State);

handle_call({pbx_op, _PbxOp, _Opts}, _From, State) ->
    {reply, {error, invalid_type_or_state}, State};

handle_call(Msg, From, State) -> 
    handle(nkmedia_session_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({offer_op, OfferOp, Opts}, #state{has_offer=false}=State) ->
    do_offer_op(OfferOp, Opts, undefined, State);

handle_cast({offer_op, _OfferOp, _Opts}, State) ->
    ?LLOG(warning, "offer already set", [], State),
    {stop, normal, State};

handle_cast({answer_op, AnswerOp, Opts}, #state{has_answer=false}=State) ->
    do_answer_op(AnswerOp, Opts, undefined, State);

handle_cast({answer_op, _AnswerOp, _Opts}, State) ->
    ?LLOG(warning, "answer already set", [], State),
    {stop, normal, State};

handle_cast({pbx_op, PbxOp, Opts},  
            #state{type=pbx, has_offer=true, has_answer=true}=State) ->
    do_pbx_op(PbxOp, Opts, undefined, State);

handle_cast({pbx_op, _PbxOp, _Opts},  State) ->
    ?LLOG(warning, "invalid type or state", [], State),
    {stop, normal, State};

handle_cast({info, Info}, State) ->
    {noreply, event({info, Info}, State)};

handle_cast({call_event, CallId, Event}, #state{links=Links}=State) ->
    case lists:keyfind({call, CallId}, 1, Links) of
        {{call, CallId}, _Pid, _Ref} ->
            do_call_event(CallId, Event, State);
        false ->
            ?LLOG(notice, "received unexpected call event from ~s (~p)", 
                  [CallId, Event], State),
            {noreply, State}
    end;

handle_cast({pbx_event, FsId, Event}, #state{ms={fs, FsId}}=State) ->
   ?LLOG(info, "received pbx event: ~p", [Event], State),
    do_pbx_event(Event, State),
    {noreply, State};

handle_cast({pbx_event, FsId2, Event}, #state{ms=MS}=State) ->
    ?LLOG(warning, "received event ~s from unknown pbx ~p (~p)",
                  [Event, FsId2, MS], State),
    {noreply, State};

handle_cast({invite_reply, ringing}, State) ->
    ?LLOG(info, "receiving ringing", [], State),
    invite_ringing(#{}, State);

handle_cast({invite_reply, {ringing, Answer}}, State) ->
    ?LLOG(info, "receiving ringing", [], State),
    invite_ringing(Answer, State);

handle_cast({invite_reply, {answered, Answer}}, State) ->
    ?LLOG(info, "receiving answered", [], State),
    invite_answered(Answer, State);

handle_cast({hangup, Reason}, State) ->
    ?LLOG(info, "external hangup: ~p", [Reason], State),
    stop_hangup(Reason, State);

handle_cast(stop, State) ->
    ?LLOG(notice, "user stop", [], State),
    {stop, normal, State};

handle_cast(Msg, State) -> 
    handle(nkmedia_session_handle_cast, [Msg], State).


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({timeout, _, status_timeout}, State) ->
    ?LLOG(info, "status timeout", [], State),
    stop_hangup(607, State);

handle_info({'DOWN', _Ref, process, Pid, Reason}=Msg, State) ->
    case find_link_pid(Pid, State) of
        user when Reason==normal ->
            ?LLOG(info, "user monitor down (normal)", [], State),
            stop_hangup(<<"Offer Monitor Stop">>, State);
        user ->
            ?LLOG(notice, "user monitor down (~p)", [Reason], State),
            stop_hangup(<<"Offer Monitor Stop">>, State);
        {call, CallId} when Reason==normal ->
            ?LLOG(info, "call ~s down (normal)", [CallId], State),
            stop_hangup(<<"Call Down">>, State);
        {call, CallId} ->
            ?LLOG(warning, "call ~s down (~p)", [CallId, Reason], State),
            stop_hangup(<<"Call Down">>, State);
        invite when Reason==normal ->
            ?LLOG(notice, "called session invite down (normal)", [], State),
            stop_hangup(<<"Call Out Down">>, State);
        invite ->
            ?LLOG(notice, "called session invite down (~p)", [Reason], State),
            stop_hangup(<<"Call Out Down">>, State);
        {janus, Class} when Reason==normal ->
            ?LLOG(notice, "Janus ~p down (normal)", [Class], State),
            stop_hangup(<<"Janus Out Down">>, State);
        {janus, Class} ->
            ?LLOG(notice, "Janus ~p down (~p)", [Class, Reason], State),
            stop_hangup(<<"Janus Out Down">>, State);
        _ ->
            handle(nkmedia_session_handle_info, [Msg], State)
    end;
    
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

terminate(Reason, State) ->
    ?LLOG(info, "terminate: ~p", [Reason], State),
    catch handle(nkmedia_session_terminate, [Reason], State),
    _ = stop_hangup(<<"Session Stop">>, State).



%% ===================================================================
%% Internal - offer_op
%% ===================================================================

%% TODO: Check if we are ringing, calling or waiting to fs

%% @private
do_offer_op(OfferOp, Opts, From, #state{type=OldType}=State) ->
    Type = case maps:get(type, Opts, OldType) of
        undefined -> 
            get_default_offer_type(OfferOp);
        UserType -> 
            UserType
    end,
    case Type of
        unknown ->
            {error, unknown_offer_op};
        _ ->
            case update_type(Type, State) of
                {ok, State2} ->
                    do_offer(OfferOp, Opts, From, State2);
                {error, Error} ->
                    reply_error(Error, From, State)
            end
    end.


%% @private Process offer
do_offer(#{sdp:=_}=Offer, Opts, From, State) ->
    {ok, State2} = update_offer(Offer, State),
    op_reply(ok, Opts, From, State2),
    {noreply, State2};

do_offer({listener, Room, UserId}, Opts, From, #state{type=proxy}=State) ->
    case get_proxy(offer, State) of
        {ok, Pid, State2} ->
            case nkmedia_janus_session:listener(Pid, Room, UserId) of
                {ok, #{sdp:=_}=Offer} ->
                    Listener = {listener, Room, UserId, Pid},
                    State3 = update_session(offer_op, Listener, State2),
                    do_offer(Offer, Opts, From, State3);
                {error, Error} ->
                    reply_error(Error, From, State2)
            end;
        {error, Error} ->
            reply_error(Error, From, State)
    end;

do_offer(_Op, _Opts, From, State) ->
    reply_error(invalid_offer_op, From, State).



%% ===================================================================
%% Internal - answer_op
%% ===================================================================

%% @private
do_answer_op(AnswerOp, Opts, From, #state{type=OldType}=State) ->
    Type = case maps:get(type, Opts, OldType) of
        undefined -> 
            get_default_answer_type(AnswerOp);
        UserType -> 
            UserType
    end,
    case Type of
        unknown ->
            {error, unknown_answer_op};
        _ ->
            case update_type(Type, State) of
                {ok, #state{has_offer=true}=State2} ->
                    answer_op(AnswerOp, Opts, From, State2);
                {ok, #state{type=pbx, has_offer=false}=State2} ->
                    case get_pbx_offer(State2) of
                        {ok, State3} ->
                            answer_op(AnswerOp, Opts, From, State3);
                        {error, Error} ->
                            reply_error(Error, From, State)
                    end;
                {ok, State2} ->
                    reply_error(offer_not_set, From, State2);
                {error, Error} ->
                    reply_error(Error, From, State)
            end
    end.


%% RAW SDP
answer_op(#{sdp:=_}=Answer, Opts, From, State) ->
    {ok, State2} = update_answer(Answer, State),
    op_reply(ok, Opts, From, State2),
    {noreply, State2};


%% ECHO
answer_op(echo, Opts, From, #state{type=proxy}=State) ->
    #state{session=#{offer:=Offer}} = State,
    case get_proxy(answer, State) of
        {ok, Pid, State2} ->
            case nkmedia_janus_session:echo(Pid, Offer) of
                {ok, #{sdp:=_}=Answer} ->
                    {ok, State3} = update_answer(Answer, State2),
                    op_reply(ok, Opts, From, State3),
                    {noreply, status(echo, State2)};
                {error, Error} ->
                    reply_error(Error, From, State2)
            end;
        {error, Error} ->
            reply_error(Error, From, State)
    end;

answer_op(echo, Opts, From, #state{type=pbx}=State) ->
    case get_pbx_answer(State) of
        {ok, State2} ->
            do_pbx_op(echo, Opts, From, State2);
        {error, Error} ->
            reply_error(Error, From, State)
    end;


%% MCU
answer_op({mcu, Room}, Opts, From, #state{type=pbx}=State) ->
    case get_pbx_answer(State) of
        {ok, State2} ->
            do_pbx_op({mcu, Room}, Opts, From, State2);
        {error, Error} ->
            reply_error(Error, From, State)
    end;


%% PUBLISHER
answer_op({publisher, Room}, Opts, From, #state{type=proxy}=State) ->
    #state{session=#{offer:=Offer}} = State,
    case get_proxy(answer, State) of
        {ok, Pid, State2} ->
            case nkmedia_janus_session:publisher(Pid, Room, Offer) of
                {ok, UserId, #{sdp:=_}=Answer} ->
                    lager:notice("Publisher Id: ~p", [UserId]),
                    {ok, State3} = update_answer(Answer, State2),
                    op_reply({ok, #{id=>UserId}}, Opts, From, State3),
                    {noreply, status(publisher, #{id=>UserId}, State3)};
                {error, Error} ->
                    reply_error(Error, From, State2)
            end;
        {error, Error} ->
            reply_error(Error, From, State)
    end;


%% CALL
answer_op({call, Dest}, Opts, From, #state{type=p2p}=State) ->
    #state{session=#{offer:=Offer}} = State,
    do_send_call(Dest, Opts, Offer, From, State);

answer_op({call, Dest}, Opts, From, #state{type=proxy}=State) ->
    #state{session=#{offer:=Offer}} = State,
    case get_proxy(answer, State) of
        {ok, Pid, State2} ->
            case nkmedia_janus_session:videocall(Pid, Offer) of
                {ok, #{sdp:=SDP}} ->
                    State3 = update_session(answer_op, {call, Pid}, State2),
                    do_send_call(Dest, Opts, Offer#{sdp=>SDP}, From, State3);
                {error, Error} ->
                    reply_error(Error, From, State)
            end;
        {error, Error} ->
            reply_error(Error, From, State)
    end;

answer_op({call, Dest}, Opts, From, #state{type=pbx}=State) ->
    case get_pbx_answer(State) of
        {ok, State2} ->
            do_pbx_op({call, Dest}, Opts, From, State2);
        {error, Error} ->
            reply_error(Error, From, State)
    end;


%% INVITE
answer_op({invite, Dest}, Opts, From, #state{id=Id, session=Session}=State) ->
    #{offer:=Offer} = Session,
    State2 = status(calling, State),
    case handle(nkmedia_session_invite, [Id, Dest, Offer], State2) of
        {ringing, Answer, Pid, State3} ->
            State4 = add_link(invite, Pid, State3),
            State5 = add_from(invite, From, Opts, State4),
            invite_ringing(Answer, State5);
        {answer, Answer, Pid, State3} ->
            ?LLOG(info, "session answer", [], State3),
            State4 = add_link(invite, Pid, State3),
            State5 = add_from(invite, From, Opts, State4),
            invite_answered(Answer, State5);
        {async, Pid, State3} ->
            ?LLOG(info, "session delayed", [], State3),
            State4 = add_link(invite, Pid, State3),
            State5 = add_from(invite, From, Opts, State4),
            {noreply, State5};
        {hangup, Reason, State3} ->
            ?LLOG(info, "session hangup: ~p", [Reason], State3),
            op_reply({hangup, Reason}, Opts, From, State),
            stop_hangup(Reason, State3)
    end;


%% ERROR
answer_op(_AnswerOp, _Opts, From, State) ->
    reply_error(invalid_answer_op, From, State).




%% ===================================================================
%% Internal - pbx_op
%% ===================================================================

%% @private
do_pbx_op(PbxOp, Opts, From, #state{type=pbx, has_answer=true}=State) ->
    pbx_op(PbxOp, Opts, From, State).


%% @private
pbx_op(echo, Opts, From, State) ->
    case pbx_transfer("echo", State) of
        ok ->
            % FS will send event and status will be updated
            op_reply(ok, Opts, From, State),
            {noreply, status(echo, State)};
        {error, Error} ->
            reply_error({echo_transfer_error, Error}, From, State)
    end;


pbx_op({mcu, Room}, Opts, From, #state{type=pbx}=State) ->
    Type = maps:get(room_type, Opts, <<"video-mcu-stereo">>),
    Cmd = [<<"conference:">>, Room, <<"@">>, Type],
    case pbx_transfer(Cmd, State) of
        ok ->
            % FS will send event and status will be updated
            op_reply(ok, Opts, From, State),
            {noreply, State};
        {error, Error} ->
            reply_error({mcu_transfer_error, Error}, From, State)
    end;

pbx_op({call, Dest}, Opts, From, #state{type=pbx}=State) ->
    #state{session=#{offer:=Offer}} = State,
    Offer2 = maps:remove(sdp, Offer),
    do_send_call(Dest, Opts, Offer2, From, State);


%% INVITE
pbx_op({invite, Dest}, Opts, From, State) ->
    answer_op({invite, Dest}, Opts, From, State);


%% ERROR
pbx_op(_AnswerOp, _Opts, From, State) ->
    reply_error(unknown_pbx_op, From, State).



%% ===================================================================
%% answer - util
%% ===================================================================

%% @private
op_reply(ok, Opts, From, State) ->
    op_reply({ok, #{}}, Opts, From, State);

op_reply({ok, Reply}, Opts, From, #state{session=Session}) ->
    Reply2 = case Opts of
        #{get_offer:=true} -> 
            Reply#{offer=>maps:get(offer, Session, undefined)};
        #{get_answer:=true} -> 
            Reply#{answer=>maps:get(answer, Session, undefined)};
        _ -> 
            Reply
    end,
    nklib_util:reply(From, {ok, Reply2});

op_reply(Reply, _Opts, From, _State) ->
    nklib_util:reply(From, Reply).


%% @private
do_send_call(Dest, Opts, Offer, From, State) ->
    #state{id=Id, session=Session} = State,
    % answergen_server:reply(From, {ok, #{}}),
    Shared = [srv_id, type, mediaserver, wait_timeout, ring_timeout, call_timeout],
    Config1 = maps:with(Shared, Session),
    Offer2 = maps:without([module, pid], Offer),
    Config2 = Config1#{session_id=>Id, session_pid=>self(), offer=>Offer2}, 
    {ok, CallId, CallPid} = nkmedia_call:start(Dest, Config2),
    State2 = add_link({call, CallId}, CallPid, State),
    State3 = add_from({call, CallId}, From, Opts, State2),
    % Now we will receive notifications from the call
    {noreply, status(calling, #{dest=>Dest}, State3)}.


%% @private Called at the B-leg
invite_ringing(Answer, #state{status=calling}=State) ->
    case update_answer(Answer, State) of
        {ok, State2} ->
            {noreply, status(ringing, Answer, State2)};
        {error, Error} ->
            ?LLOG(warning, "invite_ringing error:", [Error], State),
            stop_hangup(<<"Answer Error">>, State)
    end;

invite_ringing(_Answer, State) ->
    {noreply, State}.


%% @private Called at the B-leg
invite_answered(_Answer, #state{status=Status}=State) 
        when Status/=calling, Status/=ringing ->
    ?LLOG(warning, "received unexpected answer", [], State),
    {noreply, State};

invite_answered(Answer, State) ->
    case update_answer(Answer, State) of
        {ok, #state{has_answer=true, type=Type, session=Session2}=State2} ->
            {From, Opts, State3} = get_from(invite, State2),
            op_reply(ok, Opts, From, State3),
            PeerId = maps:get(peer_id, Session2, undefined),
            case Type of
                p2p ->
                    {noreply, status(call, #{peer_id=>PeerId}, State3)};
                proxy ->
                    {noreply, status(call, #{peer_id=>PeerId}, State3)};
                _ ->
                    {noreply, State3}
            end;
        {ok, State2} ->
            ?LLOG(warning, "invite without SDP!", [], State),
            stop_hangup(<<"No SDP">>, State2);
        {error, Error} ->
            ?LLOG(warning, "invite_answered error:", [Error], State),
            stop_hangup(<<"Answer Error">>, State)
    end.



%% ===================================================================
%% Events
%% ===================================================================



%% @private
do_call_event(_CallId, {status, calling, _}, #state{status=calling}=State) ->
    {noreply, State};

do_call_event(_CallId, {status, ringing, Data}, #state{status=calling}=State) ->
    case Data of
        #{answer:=#{sdp:=_}=Answer} ->
            PeerId = maps:get(session_peer_id, Data, undefined),
            case update_remote_answer(Answer, PeerId, State) of
                {ok, State2} ->
                    {noreply, status(ringing, Data, State2)};
                {error, Error} ->
                    ?LLOG(warning, "remote answer error: ~p", [Error], State),
                    stop_hangup(<<"Answer Error">>, State)
            end;    
        _ ->
            {noreply, status(ringing, Data, State)}
    end;

do_call_event(_CallId, {status, ringing, _Data}, #state{status=ringing}=State) ->
    {noreply, State};

do_call_event(CallId, {status, answer, Data}, #state{status=Status}=State)
        when Status==calling; Status==ringing ->
    ?LLOG(info, "receiving call answer", [], State),
    #state{has_answer=HasAnswer} = State,
    case Data of
        #{answer:=#{sdp:=_}=Answer} ->
            PeerId = maps:get(session_peer_id, Data, undefined),
            case update_remote_answer(Answer, PeerId, State) of
                {ok, State2} ->
                    {From, Opts, State3} = get_from({call, CallId}, State2),
                    op_reply(ok, Opts, From, State3),
                    {noreply, status(call, Data, State2)};
                {error, Error} ->
                    ?LLOG(warning, "remote answer error: ~p", [Error], State),
                    stop_hangup(<<"Answer Error">>, State)
            end;    
        _ when HasAnswer ->
            {From, Opts, State2} = get_from({call, CallId}, State),
            op_reply(ok, Opts, From, State2),
            {noreply, status(call, Data, State2)};
        _ ->
            stop_hangup(<<"No SDP">>, State)
    end;

do_call_event(CallId, {status, hangup, Data}, #state{status=Status}=State) ->
    {From, Opts, State2} = get_from({call, CallId}, State),
    #{hangup_reason:=Reason} = Data,
    op_reply({hangup, Reason}, Opts, From, State),
    if 
        Status==calling; Status==ringing; Status==call ->
            stop_hangup(Reason, State2);
        true ->
            {noreply, remove_link({call, CallId}, State2)}
    end;

do_call_event(_CallId, Event, State) ->
    ?LLOG(warning, "unexpected call event: ~p", [Event], State),
    {noreply, State}.


%% @private
do_pbx_event(parked, #state{status=Status}=State)
        when Status==answer; Status==ringing; Status==echo ->
    {noreply, State};

do_pbx_event(parked, #state{status=Status}=State) ->
    ?LLOG(notice, "received parked in '~p'", [Status], State),
    {noreply, State};

do_pbx_event({bridge, Remote}, State) ->
    {noreply, status(call, #{peer=>Remote}, State)};

do_pbx_event({mcu, McuInfo}, State) ->
    {noreply, status(mcu, McuInfo, State)};

do_pbx_event({hangup, Reason}, State) ->
    stop_hangup(Reason, State);

do_pbx_event(stop, State) ->
    stop_hangup(<<"MediaServer Stop">>, State);

do_pbx_event(Event, State) ->
    ?LLOG(warning, "unexpected ms event: ~p", [Event], State),
    {noreply, State}.




%% ===================================================================
%% Internal - Shared
%% ===================================================================

%% @private
-spec update_config(config(), #state{}) ->
    {ok, #state{}} | {error, term()}.

update_config(Config, State) ->
    Type = maps:get(type, Config, undefined),
    case update_type(Type, State) of
        {ok, State2} ->
            Offer = maps:get(offer, Config, undefined),
            case update_offer(Offer, State2) of
                {ok, State3} ->
                    Answer = maps:get(answer, Config, undefined),
                    update_answer(Answer, State3);
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.
              

%% @private
-spec update_type(type()|undefined, #state{}) ->
    {ok, #state{}} | {error, term()}.

update_type(undefined, State) ->
    {ok, State};

update_type(Type, State) ->
    #state{type=OldType, ms=MS, session=Session} = State,
    case Type of
        OldType ->
            {ok, State};
        _ when OldType /= undefined ->
            {error, type_cannot_be_changed};
        _ ->
            case update_type_check(Type, MS) of
                ok ->
                    Session2 = Session#{type=>Type},
                    {ok, State#state{type=Type, session=Session2}};
                error ->
                    {error, incompatible_type}
            end
    end.


%% @private
update_type_check(p2p, undefined) -> ok;
update_type_check(pbx, undefined) -> ok;
update_type_check(pbx, {fs, _}) -> ok;
update_type_check(proxy, undefined) -> ok;
update_type_check(proxy, {janus, _}) -> ok;
update_type_check(_, _) -> error.


%% @private
-spec update_offer(nkmedia:offer()|undefined, #state{}) ->
    {ok, #state{}} | {error, term()}.

update_offer(undefined, State) ->
    {ok, State};

update_offer(Offer, State) ->
    #state{has_offer=HasOffer, session=Session} = State,
    case Offer of
        _ when HasOffer ->
            SDP1 = maps:get(sdp, Offer, <<>>),
            OldOffer = maps:get(offer, Session, #{}),
            SDP2 = maps:get(sdp, OldOffer, <<>>),
            case SDP1==SDP2 of
                true ->
                    {ok, update_session(offer, Offer, State)};
                false ->
                    {error, duplicated_offer}
            end;
        #{sdp:=_SDP} ->
            Session2 = Session#{offer=>Offer},
            State2 = State#state{has_offer=true, session=Session2},
            {ok, status(offer, #{offer=>Offer}, State2)};
        #{} ->
            {ok, update_session(offer, Offer, State)};
        _ ->
            {error, invalid_sdp}
    end.


%% @private
-spec update_answer(nkmedia:answer()|undefined, #state{}) ->
    {ok, #state{}} | {error, term()}.

update_answer(undefined, State) ->
    {ok, State};

update_answer(Answer, #state{has_answer=HasAnswer}=State) ->
    #state{has_answer=HasAnswer, session=Session} = State,
    case Answer of
        _ when HasAnswer ->
            SDP1 = maps:get(sdp, Answer, <<>>),
            OldAnswer = maps:get(answer, Session, #{}),
            SDP2 = maps:get(sdp, OldAnswer, <<>>),
            case SDP1==SDP2 of
                true ->
                    {ok, update_session(answer, Answer, State)};
                false ->
                    {error, duplicated_answer}
            end;
        #{sdp:=_SDP} ->
            case update_answer_ms(Answer, State) of
                ok ->
                    Session2 = Session#{answer=>Answer},
                    State2 = State#state{has_answer=true, session=Session2},
                    {ok, status(answer, #{answer=>Answer}, State2)};
                {error, Error} ->
                    {error, Error}
            end;
        #{} ->
            {ok, update_session(answer, Answer, State)};
        _ ->
            {error, invalid_sdp}
    end.


%% @private
update_answer_ms(Answer, #state{id=SessId, ms={fs, _}}=State) ->
    Mod = get_fs_mod(State),
    case Mod:answer_out(SessId, Answer) of
        ok ->
            ok;
        {error, Error} ->
            ?LLOG(warning, "mediaserver error in answer_out: ~p", [Error], State),
            {error, mediaserver_error}
    end;

update_answer_ms(_Answer, _State) ->
    ok.


%% @private
update_remote_answer(#{sdp:=_}=Answer, PeerId, #state{type=p2p}=State) ->
    update_answer(Answer, update_session(peer_id, PeerId, State));

update_remote_answer(#{sdp:=_}, PeerId, #state{type=pbx}=State) ->
    State2 = update_session(peer_id, PeerId, State),
    % In case we didn't generate it previously
    case get_pbx_answer(State2) of
        {ok, State3} ->
            case pbx_bridge(PeerId, State3) of
                ok ->
                    % Wait for FS event for status change
                    {ok, State3};
                error ->
                    {error, pbx_error}
            end;
        {error, Error} ->
            {error, Error}
    end;

update_remote_answer(#{sdp:=_}=Answer, PeerId, #state{type=proxy}=State) ->
    State2 = update_session(peer_id, PeerId, State),
    proxy_get_answer(Answer, State2);

update_remote_answer(_Answer, _PeerId, State) ->
    {ok, State}.



%% @private
-spec get_default_offer_type(offer_op()) ->
    type() | undefined | unknown.

get_default_offer_type(Map) when is_map(Map) -> undefined;
get_default_offer_type({listener, _, _}) -> proxy;
get_default_offer_type(_) -> unknown.


%% @private
-spec get_default_answer_type(answer_op()) ->
    type() | undefined | unknown.

get_default_answer_type(Map) when is_map(Map) -> undefined;
get_default_answer_type(echo) -> proxy;
get_default_answer_type({mcu, _}) -> pbx;
get_default_answer_type({call, _}) -> proxy;
get_default_answer_type({invite, _}) -> proxy;
get_default_answer_type({publisher, _}) -> proxy;
get_default_answer_type(_) -> unknown.


%% @private
update_session(Key, Val, #state{session=Session}=State) ->
    Session2 = maps:put(Key, Val, Session),
    State#state{session=Session2}.



%% @private
-spec get_proxy(offer|answer, #state{}) ->
    {ok, pid(), #state{}} | {error, term(), #state{}}.

get_proxy(Class, #state{id=Id, type=proxy}=State) ->
    Id2 = case Class of
        offer -> <<"O_", Id/binary>>;
        answer -> <<"A_", Id/binary>>
    end,
    case get_mediaserver(State) of
        {ok, #state{ms={janus, JanusId}}=State2} ->
            case nkmedia_janus_session:start(Id2, JanusId) of
                {ok, Pid} ->
                    {ok, Pid, add_link({janus, Class}, Pid, State2)};
                {error, Error} ->
                    {error, {proxy_connect_error, Error}}
            end;
        {error, Error} ->
            {error, {get_proxy_error, Error}}
    end.


%% @private
get_pbx_answer(#state{type=pbx, ms=undefined}=State) ->
    case get_mediaserver(State) of
        {ok, #state{ms={fs, _}}=State2} ->
            get_pbx_answer(State2);
        {error, Error} ->
            {error, Error}
    end;

get_pbx_answer(#state{type=pbx, ms={fs, _}, has_answer=true}=State) ->
    {ok, State};

get_pbx_answer(#state{type=pbx, ms={fs, FsId}, has_answer=false}=State) ->
    #state{id=SessId, session=#{offer:=Offer}} = State,
    case nkmedia_fs_verto:start_in(SessId, FsId, Offer) of
        {ok, SDP} ->
            % lager:warning("SDP to Verto: ~s", [maps:get(sdp, Offer)]),
            %% TODO Send and receive pings
            % lager:warning("SDP from Verto: ~s", [SDP]),
            update_answer(#{sdp=>SDP}, State);
        {error, Error} ->
            {error, Error}
    end.


%% @private
get_pbx_offer(#state{type=pbx, ms=undefined}=State) ->
        case get_mediaserver(State) of
            {ok, #state{ms={fs, _}}=State2} ->
                get_pbx_offer(State2);
            {error, Error} ->
                {error, {get_pbx_offer_error, Error}}
        end;

get_pbx_offer(#state{type=pbx, ms={fs, _}, has_offer=true}=State) ->
    {ok, State};

get_pbx_offer(#state{type=pbx, ms={fs, FsId}, has_offer=false}=State) ->
    #state{id=SessId, session=Session} = State,
    Mod = get_fs_mod(State),
    case Mod:start_out(SessId, FsId, #{}) of
        {ok, SDP} ->
            %% TODO Send and receive pings
            Offer = maps:get(offer, Session, #{}),
            update_offer(Offer#{sdp=>SDP}, State);
        {error, Error} ->
            {error, {backend_out_error, Error}}
    end.



%% @private
-spec get_mediaserver(#state{}) ->
    {ok, #state{}} | {error, term()}.

get_mediaserver(#state{ms=undefined}=State) ->
    #state{srv_id=SrvId, type=Type, session=Session} = State,
    case SrvId:nkmedia_session_get_mediaserver(Type, Session) of
        {ok, MS, Session2} ->
            Session3 = Session2#{mediaserver=>MS},
            {ok, State#state{ms=MS, session=Session3}};
        {error, Error} ->
            {error, Error}
    end;

get_mediaserver(State) ->
    {ok, State}.


%% @private
pbx_transfer(Dest, #state{id=SessId, ms={fs, FsId}}) ->
    nkmedia_fs_cmd:transfer_inline(FsId, SessId, Dest).


%% @private
pbx_bridge(SessIdB, #state{id=SessIdA, ms={fs, FsId}}=State) ->
    case nkmedia_fs_cmd:set_var(FsId, SessIdA, "park_after_bridge", "true") of
        ok ->
            nkmedia_fs_cmd:bridge(FsId, SessIdA, SessIdB);
        {error, Error} ->
            ?LLOG(warning, "pbx bridge error: ~p", [Error], State),
            error
    end.

proxy_get_answer(AnswerB, #state{ms={janus, _}, session=Session}=State) ->
    case Session of
        #{offer_op:={listener, _Room, _UserId, Pid}} ->
            case nkmedia_janus_session:listener_answer(Pid, AnswerB) of
                ok ->
                    update_answer(AnswerB, State);
                {error, Error} ->
                    {error, Error}
            end;
        #{answer_op:={call, Pid}} ->
            case nkmedia_janus_session:videocall_answer(Pid, AnswerB) of
                {ok, AnswerA} ->
                    update_answer(AnswerA, State);
                {error, Error} ->
                    {error, Error}
            end
    end.



%% @private
stop_hangup(_Reason, #state{status=hangup}=State) ->
    {stop, normal, State};

stop_hangup(Reason, #state{id=SessId, ms=MS, links=Links, froms=Froms}=State) ->
    lists:foreach(
        fun
            ({{call, CallId}, _, _Mon}) ->
                nkmedia_call:hangup(CallId, <<"Caller Stopped">>);
            ({janus, Pid, _Mon}) ->
                nkmedia_janus_client:stop(Pid);
            (_) ->
                ok
        end,
        Links),
     lists:foreach(
        fun({_Id, From, _Opts}) ->
            gen_server:reply(From, {hangup, Reason})
        end,
        Froms),
    case MS of
        {fs, FsId} ->
            nkmedia_fs_cmd:hangup(FsId, SessId);
        _ ->
            ok
    end,
    {stop, normal, status(hangup, #{hangup_reason=>Reason}, State)}.


%% @private
status(Status, State) ->
    status(Status, #{}, State).


%% @private
status(Status, _Info, #state{status=Status}=State) ->
    restart_timer(State);

%% @private
status(NewStatus, Info, #state{session=Session}=State) ->
    ?LLOG(info, "status changed to ~p", [NewStatus], State),
    State2 = restart_timer(State#state{status=NewStatus}),
    State3 = State2#state{session=Session#{status=>NewStatus, ext_status=>Info}},
    event({status, NewStatus, Info}, State3).


%% @private
event(Event, #state{id=Id}=State) ->
    {ok, State2} = handle(nkmedia_session_event, [Id, Event], State),
    State2.


%% @private
restart_timer(#state{status=hangup, timer=Timer}=State) ->
    nklib_util:cancel_timer(Timer),
    State;

restart_timer(#state{status=Status, timer=Timer, session=Session}=State) ->
    nklib_util:cancel_timer(Timer),
    Time = if
        Status==offer; Status==answer; Status==calling ->
            maps:get(wait_timeout, Session, ?DEF_WAIT_TIMEOUT);
        Status==ringing ->
            maps:get(ring_timeout, Session, ?DEF_RING_TIMEOUT);
        true ->
            maps:get(call_timeout, Session, ?DEF_CALL_TIMEOUT)
    end,
    NewTimer = erlang:start_timer(1000*Time, self(), status_timeout),
    State#state{timer=NewTimer}.


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
    do_call(SessId, Msg, 5000).


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


%% @private
get_fs_mod(#state{session=Session}) ->
    case maps:get(sdp_type, Session, webrtc) of
        webrtc -> nkmedia_fs_verto;
        sip -> nkmedia_fs_sip
    end.


%% @private
add_link(Id, Pid, #state{links=Links}=State) when is_pid(Pid) ->
    Link = {Id, Pid, monitor(process, Pid)},
    State#state{links=[Link|Links]};

add_link(_Id, _Pid, State) ->
    State.


%% @private
remove_link(Id, #state{links=Links}=State) ->
    case lists:keyfind(Id, 1, Links) of
        {Id, _Pid, Mon} ->
            nklib_util:demonitor(Mon),
            State#state{links=lists:keydelete(Id, 1, Links)};
        false ->
            State
    end.


%% @private
find_link_pid(Pid, #state{links=Links}) ->
    do_find_link_pid(Pid, Links).

do_find_link_pid(_Pid, []) -> not_found;
do_find_link_pid(Pid, [{Id, Pid, _}|_]) -> Id;
do_find_link_pid(Pid, [_|Rest]) -> do_find_link_pid(Pid, Rest).


%% @private
add_from(_Id, undefined, _Opts, State) ->
    State;

add_from(Id, From, Opts, #state{froms=Froms}=State) ->
    State#state{links=[{Id, From, Opts}|Froms]}.


%% @private
get_from(Id, #state{froms=Froms}=State) ->
    case lists:keytake(Id, 1, Froms) of
        {value, {Id, From, Opts}, Froms2} ->
            {From, Opts, State#state{froms=Froms2}};
        false ->
            {undefined, #{}, State}
    end.


reply_error(Error, undefined, State) ->
    ?LLOG(warning, "operation error: ~p", [Error], State),
    {stop, normal, State};

reply_error(Error, From, State) ->
    gen_server:reply(From, {error, Error}),
    {noreply, State}.

