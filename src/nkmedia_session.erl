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
-export([set_offer/3, set_answer/3, session_op/3]).
-export([invite_reply/2]).
-export([pbx_event/3, call_event/3, peer_event/3, set_call_peer/2]).
-export([get_all/0, find/1]).
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
        monitor => pid(),                       % Monitor this process
        peer => {id(), pid()},                  % If this session must be linked
        call => {nkmedia_call:id(), pid()}      % If is started by nkmedia_call
}.

-type type() :: p2p | proxy | pbx.

-type call_dest() :: term().

-type status() ::
    wait      |   % Waiting for an operation
    calling   |   % Launching a call to another session
    call      |   % Session is connected to another
    inviting  |   % Launching an invite from this session
    invite    |   % Connected to an external party
    echo      |   % We are sending echo
    mcu       | 
    publish   |
    listen.


%% Extended status 
-type ext_status() ::
    #{
        dest => binary(),                       % For 'calling' status
        call_id => nkmedia:call_id(),           % For 'calling' status
        peer => id(),                           % For 'call'
        room_name => binary(),                  % For 'mcu'
        room_member => binary()                 % For 'mcu'
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
    pbx             |                               % Get offer from pbx
    {listen, Room::integer(), User::integer()}.   % Get offer from listen


-type answer_op() ::
    nkmedia:answer()             |      % Set raw answer
    pbx                          |      % Put session into pbx (only pbx type)
    echo                         |      % Perform media echo (proxy and pbx)
    {mcu, Room::binary()}        |      % Connect offer to mcu (pbx)
    {publish, Room::integer()} |      % Connect offer to publish (proxy)
    {call, Dest::call_dest()}    |      % Get answer from complex call (all)
    {invite, Dest::call_dest()}.        % Get answer from invite (all)


-type session_op() ::
    echo                                |   % Perform media echo (only pbx)
    {mcu, Room::binary()}               |   % Connect offer to mcu (only pbx)
    {call, Dest::call_dest()}           |   % Get answer from complex call (pbx)
    {invite, Dest::call_dest()}         |   % Get answer from invite (pbx)
    {listen_switch, User::integer()}.     % (only proxy)


-type op_opts() ::  
    #{
        type => type(),                     % You can set the type
        sync => boolean(),                  % Wait for session reply
        get_offer => boolean(),             % Return the offer        
        get_answer => boolean(),            % Return the answer
        hangup_after_error => boolean()     % Only for async. Default 'true'

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
    {offer, nkmedia:offer()} | {answer, nkmedia:answer()} |
    {ringing, nkmedia:answer()} | {info, term()} |
    {hangup, nkmedia:hangup_reason()}.


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
%% offer from some other operation, like being a listen
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


%% @doc Perform an operation on the session
%% If it is already answered, a session_op() must be used
%% If not, answer_op() must be used (equivalent to set_answer/3)
-spec session_op(id(), answer_op()|session_op(), op_opts()) ->
    ok | {ok, op_result()} | {error, term()}.

session_op(SessId, PbxOp, #{sync:=true}=Opts) ->
    do_call(SessId, {session_op, PbxOp, Opts});

session_op(SessId, PbxOp, Opts) ->
    do_cast(SessId, {session_op, PbxOp, Opts}).


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
call_event(SessId, CallId, Event) ->
    do_cast(SessId, {call_event, CallId, Event}).


%% @private Called from nkmedia_callbacks:nkmedia_call_event when a 
%% call has an event for us.
peer_event(SessId, CallId, Event) ->
    do_cast(SessId, {peer_event, CallId, Event}).


%% @private Called from the caller session to the calee
set_call_peer(SessId, PeerSessId) ->
    do_call(SessId, {set_call_peer, PeerSessId, self()}).






% ===================================================================
%% gen_server behaviour
%% ===================================================================

-type link_id() ::
    caller | {janus, nkmedia_janus_session:id()} | invite | call_in | peer |
    {call_out, nkmedia_call:id()}.

-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    type :: type(),
    status :: status() | init,
    has_offer = false :: boolean(),
    has_answer = false :: boolean(),
    ms :: mediaserver(),
    pbx_type :: inbound | outbound,
    proxy_pid :: pid(),
    after_answer :: {janus_call, pid()} | {janus_listen, pid()},
    links :: nkmedia_links:links(link_id()),
    timer :: reference(),
    hangup_sent = false :: boolean(),
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
        links = nkmedia_links:new(),
        session = Session
    },
    lager:info("NkMEDIA Session ~s starting (~p)", [Id, self()]),
    State2 = case Session of
        #{monitor:=UserPid} -> 
            add_link(caller, none, UserPid, State1); 
        _ -> 
            State1
    end,
    State3 = case Session of
        #{call:={CallId, CallPid}} ->
            add_link(call_in, CallId, CallPid, State2);
        _ ->
            State2
    end,
    {ok, State4} = handle(nkmedia_session_init, [Id], State3),
    #state{session=Session5} = State4,
    % Process type, offer and answer. Send offer and answer status.
    case update_config(Session5, State4) of
        {ok, State5} ->
            {ok, status(wait, State5)};
        {error, Error} ->
            ?LLOG(warning, "session start error: ~p", [Error], State4),
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

handle_call({session_op, SessOp, Opts}, From, #state{has_answer=true}=State) ->
    do_session_op(SessOp, Opts, From, State);

handle_call({session_op, SessOp, Opts}, From, State) ->
    do_answer_op(SessOp, Opts, From, State);

handle_call({set_call_peer, PeerId, PeerPid}, _From, State) ->
    State2 = remove_link(call_in, State),
    State3 = add_link(peer, PeerId, PeerPid, State2),
    {reply, {ok, self()}, status(call, #{peer=>PeerId}, State3)};

handle_call(get_state, _From, State) -> 
    {reply, State, State};

handle_call(Msg, From, State) -> 
    handle(nkmedia_session_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({offer_op, OfferOp, Opts}, #state{has_offer=false}=State) ->
    do_offer_op(OfferOp, Opts, undefined, State);

handle_cast({offer_op, _OfferOp, _Opts}, State) ->
    ?LLOG(warning, "offer already set", [], State),
    noreply(State);

handle_cast({answer_op, AnswerOp, Opts}, #state{has_answer=false}=State) ->
    do_answer_op(AnswerOp, Opts, undefined, State);

handle_cast({answer_op, _AnswerOp, _Opts}, State) ->
    ?LLOG(warning, "answer already set", [], State),
    noreply(State);

handle_cast({session_op, SessOp, Opts}, #state{has_answer=true}=State) ->
    do_session_op(SessOp, Opts, undefined, State);

handle_cast({session_op, SessOp, Opts}, State) ->
    do_answer_op(SessOp, Opts, undefined, State);

handle_cast({info, Info}, State) ->
    noreply(event({info, Info}, State));

handle_cast({call_event, CallId, Event}, #state{status=Status}=State) ->
    case get_link({call_out, CallId}, State) of
        {ok, _} when Status==calling ->
            do_call_event(CallId, Event, State);
        _ ->
            case Event of
                {hangup, _Reason} ->
                    ok;
                _ ->
                    ?LLOG(notice, "received unexpected call event from ~s (~p)", 
                          [CallId, Event], State)
            end,
            noreply(State)
    end;

handle_cast({peer_event, PeerId, Event}, #state{status=Status}=State) ->
    case get_link(peer, State) of
        {ok, PeerId} when Status==call ->
            do_peer_event(PeerId, Event, State);
        not_found ->
            case Event of
                {hangup, _} ->
                    ok;
                _ ->
                    ?LLOG(notice, "received unexpected peer event from ~s (~p)", 
                          [PeerId, Event], State)
            end,
            noreply(State)
    end;

handle_cast({pbx_event, FsId, Event}, #state{ms={fs, FsId}}=State) ->
   ?LLOG(info, "received pbx event: ~p", [Event], State),
    do_pbx_event(Event, State),
    noreply(State);

handle_cast({pbx_event, FsId2, Event}, #state{ms=MS}=State) ->
    ?LLOG(warning, "received event ~s from unknown pbx ~p (~p)",
                  [Event, FsId2, MS], State),
    noreply(State);

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
    do_hangup(Reason, State);

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
    do_hangup(607, State);

handle_info({'DOWN', Ref, process, _Pid, Reason}=Msg, State) ->
    case extract_link_mon(Ref, State) of
        not_found ->
            handle(nkmedia_session_handle_info, [Msg], State);
        {ok, Id, _Data, State2} ->
            case Reason of
                normal ->
                    ?LLOG(info, "linked ~p down (normal)", [Id], State);
                _ ->
                    ?LLOG(notice, "linked ~p down (~p)", [Id, Reason], State)
            end,
            case Id of
                caller ->
                    do_hangup(<<"Caller Monitor Stop">>, State2);
                call_in ->
                    do_hangup(<<"Call In Monitor Down">>, State2);
                {call_out, _} ->
                    % do_hangup will send the reply
                    do_hangup(<<"Call Out Monitor Down">>, State2);
                peer ->
                    do_hangup(<<"Peer Monitor Down">>, State2);
                invite ->
                    % do_hangup will send the reply
                    do_hangup(<<"Invite Monitor Down">>, State2);
                {janus, _} ->
                    do_hangup(<<"Janus Monitor Down">>, State2)
            end
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
    _ = do_hangup(<<"Process Terminate">>, State).



%% ===================================================================
%% Internal - offer_op
%% ===================================================================

%% TODO: Check if we are ringing, calling or waiting to fs

%% @private
%% We know we don't have offer set yet
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
                    op_reply({error, Error}, Opts, From, State)
            end
    end.


%% @private Process offer
do_offer(#{sdp:=_}=Offer, Opts, From, State) ->
    {ok, State2} = update_offer(Offer, State),
    op_reply(ok, Opts, From, State2);

do_offer(pbx, Opts, From, #state{type=pbx}=State) ->
    case get_pbx_offer(State) of
        {ok, State2} ->
            op_reply(ok, Opts, From, State2);
        {error, Error} ->
            op_reply({error, Error}, Opts, From, State)
    end;

do_offer({listen, Room, UserId}, Opts, From, #state{type=proxy}=State) ->
    case get_proxy(State) of
        {ok, Pid, State2} ->
            case nkmedia_janus_session:listen(Pid, Room, UserId, Opts) of
                {ok, #{sdp:=_}=Offer} ->
                    State3 = State2#state{
                        proxy_pid = Pid,
                        after_answer = {janus_listen, Pid}
                    },
                    do_offer(Offer, Opts, From, State3);
                {error, Error} ->
                    op_reply({error, Error}, Opts, From, State2)
            end;
        {error, Error} ->
            op_reply({error, {proxy_error, Error}}, Opts,From, State)
    end;

do_offer(_Op, Opts, From, State) ->
    op_reply({error, invalid_offer_op}, Opts, From, State).



%% ===================================================================
%% Internal - answer_op
%% ===================================================================

%% @private
%% We now we have no answer yet
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
                            % pbx_type will be 'outbound'
                            % most operations are not available! 
                            % (only raw and invite)
                            answer_op(AnswerOp, Opts, From, State3);
                        {error, Error} ->
                            op_reply({error, Error}, Opts, From, State)
                    end;
                {ok, State2} ->
                    op_reply({error, offer_not_set}, Opts, From, State2);
                {error, Error} ->
                    op_reply({error, Error}, Opts, From, State)
            end
    end.


%% RAW SDP
answer_op(#{sdp:=_}=Answer, Opts, From, State) ->
    {ok, State2} = update_answer(Answer, State),
    op_reply(ok, Opts, From, State2);


%% RAW PBX
answer_op(pbx, Opts, From, #state{type=pbx}=State) ->
    case place_in_pbx(State) of
        {ok, State2} ->
            op_reply(ok, Opts, From, State2);
        {error, Error} ->
            op_reply({error, {pbx_error, Error}}, Opts, From, State)
    end;

answer_op(echo, Opts, From, #state{type=proxy}=State) ->
    #state{session=#{offer:=Offer}} = State,
    case get_proxy(State) of
        {ok, Pid, State2} ->
            case nkmedia_janus_session:echo(Pid, Offer, Opts) of
                {ok, #{sdp:=_}=Answer} ->
                    {ok, State3} = update_answer(Answer, State2),
                    op_reply(ok, Opts, From, status(echo, State3));
                {error, Error} ->
                    op_reply({error, Error}, Opts, From, State2)
            end;
        {error, Error} ->
            op_reply({error, {proxy_error, Error}}, Opts, From, State)
    end;

answer_op(echo, Opts, From, #state{type=pbx}=State) ->
    case place_in_pbx(State) of
        {ok, State2} ->
            do_session_op(echo, Opts, From, State2);
        {error, Error} ->
            op_reply({error, {pbx_error, Error}}, Opts, From, State)
    end;


%% MCU
answer_op({mcu, Room}, Opts, From, #state{type=pbx}=State) ->
    case place_in_pbx(State) of
        {ok, State2} ->
            do_session_op({mcu, Room}, Opts, From, State2);
        {error, Error} ->
            op_reply({error, {pbx_error, Error}}, Opts, From, State)
    end;


%% PUBLISHER
answer_op({publish, Room}, Opts, From, #state{type=proxy}=State) ->
    #state{session=#{offer:=Offer}} = State,
    case get_proxy(State) of
        {ok, Pid, State2} ->
            case nkmedia_janus_session:publish(Pid, Room, Offer, Opts) of
                {ok, UserId, #{sdp:=_}=Answer} ->
                    lager:notice("Publisher Id: ~p", [UserId]),
                    {ok, State3} = update_answer(Answer, State2),
                    State4 = status(publish, #{id=>UserId}, State3), 
                    op_reply({ok, #{id=>UserId}}, Opts, From, State4);
                {error, Error} ->
                    op_reply({error, Error}, Opts, From, State2)
            end;
        {error, Error} ->
            op_reply({error, {proxy_error, Error}}, Opts, From, State)
    end;


%% CALL
answer_op({call, Dest}, Opts, From, #state{type=p2p}=State) ->
    #state{session=#{offer:=Offer}} = State,
    do_send_call(Dest, Opts, Offer, From, State);

answer_op({call, Dest}, Opts, From, #state{type=proxy}=State) ->
    #state{session=#{offer:=Offer}} = State,
    case get_proxy(State) of
        {ok, Pid, State2} ->
            case nkmedia_janus_session:videocall(Pid, Offer, Opts) of
                {ok, #{sdp:=SDP}} ->
                    State3 = State2#state{after_answer={janus_call, Pid}},
                    do_send_call(Dest, Opts, Offer#{sdp=>SDP}, From, State3);
                {error, Error} ->
                    op_reply({error, Error}, Opts, From, State)
            end;
        {error, Error} ->
            op_reply({error, {proxy_error, Error}}, Opts, From, State)
    end;

answer_op({call, Dest}, Opts, From, #state{type=pbx}=State) ->
    case place_in_pbx(State) of
        {ok, State2} ->
            do_session_op({call, Dest}, Opts, From, State2);
        {error, Error} ->
            op_reply({error, {pbx_error, Error}}, Opts, From, State)
    end;


%% INVITE
answer_op({invite, Dest}, Opts, From, #state{id=Id, session=Session}=State) ->
    #{offer:=Offer} = Session,
    State2 = status(inviting, #{dest=>Dest}, State),
    case handle(nkmedia_session_invite, [Id, Dest, Offer], State2) of
        {ringing, Answer, Pid, State3} ->
            State4 = add_link(invite, {From, Dest, Opts}, Pid, State3),
            invite_ringing(Answer, State4);
        {answer, Answer, Pid, State3} ->
            ?LLOG(info, "session answer", [], State3),
            State4 = add_link(invite, {From, Dest, Opts}, Pid, State3),
            invite_answered(Answer, State4);
        {async, Pid, State3} ->
            ?LLOG(info, "session delayed", [], State3),
            State4 = add_link(invite, {From, Dest, Opts}, Pid, State3),
            noreply(State4);
        {hangup, Reason, State3} ->
            ?LLOG(info, "session hangup: ~p", [Reason], State3),
            op_reply({error, {hangup, Reason}}, Opts, From, State)
    end;


%% ERROR
answer_op(_AnswerOp, Opts, From, State) ->
    op_reply({error, invalid_answer_op}, Opts, From, State).




%% ===================================================================
%% Internal - session_op
%% ===================================================================

%% @private
do_session_op(PbxOp, Opts, From, #state{has_answer=true}=State) ->
    session_op(PbxOp, Opts, From, State).


%% @private
session_op(echo, Opts, From, #state{type=pbx}=State) ->
    case pbx_transfer("echo", State) of
        ok ->
            % FS will send event and status will be updated
            op_reply(ok, Opts, From, status(echo, State));
        {error, Error} ->
            op_reply({error, {echo_transfer_error, Error}}, Opts, From, State)
    end;


session_op({mcu, Room}, Opts, From, #state{type=pbx}=State) ->
    Type = maps:get(room_type, Opts, <<"video-mcu-stereo">>),
    Cmd = [<<"conference:">>, Room, <<"@">>, Type],
    case pbx_transfer(Cmd, State) of
        ok ->
            % FS will send event and status will be updated
            op_reply(ok, Opts, From, State);
        {error, Error} ->
            op_reply({error, {mcu_transfer_error, Error}}, Opts, From, State)
    end;

session_op({call, Dest}, Opts, From, #state{type=pbx}=State) ->
    #state{session=#{offer:=Offer}} = State,
    Offer2 = maps:remove(sdp, Offer),
    do_send_call(Dest, Opts, Offer2, From, State);


%% INVITE
session_op({invite, Dest}, Opts, From, State) ->
    answer_op({invite, Dest}, Opts, From, State);


%% ERROR
session_op(_AnswerOp, Opts, From, State) ->
    op_reply({error, unknown_session_op}, Opts, From, State).



%% ===================================================================
%% answer - util
%% ===================================================================

%% @private
op_reply(ok, Opts, From, State) ->
    op_reply({ok, #{}}, Opts, From, State);

op_reply({ok, Reply}, Opts, From, #state{session=Session}=State) ->
    Reply2 = case Opts of
        #{get_offer:=true} -> 
            Reply#{offer=>maps:get(offer, Session, undefined)};
        _ ->
            Reply
    end,
    Reply3 = case Opts of
        #{get_answer:=true} -> 
            Reply2#{answer=>maps:get(answer, Session, undefined)};
        _ -> 
            Reply2
    end,
    nklib_util:reply(From, {ok, Reply3}),
    noreply(State);

op_reply({error, Error}, Opts, From, State) ->
    Stop = case {From, Opts} of
        {undefined, #{hangup_after_error:=false}} -> false;
        {undefined, _} -> true;
        _ -> false
    end,
    nklib_util:reply(From, {error, Error}),
    case Stop of
        true ->
            ?LLOG(warning, "operation error: ~p", [Error], State),
            do_hangup(<<"Operation Error">>, State);
        false ->
            noreply(State)
    end.


%% @private
do_send_call(Dest, Opts, Offer, From, State) ->
    #state{session=Session} = State,
    Shared = [id, srv_id, type, mediaserver, wait_timeout, ring_timeout, call_timeout],
    Config1 = maps:with(Shared, Session),
    Config2 = Config1#{offer=>Offer}, 
    {ok, CallId, CallPid} = nkmedia_call:start(Dest, Config2),
    State2 = add_link({call_out, CallId}, {From, Opts}, CallPid, State),
    % Now we will receive notifications from the call
    noreply(status(calling, #{dest=>Dest, call_id=>CallId}, State2)).


%% @private Called at the B-leg
invite_ringing(Answer, #state{status=inviting}=State) ->
    case update_answer(Answer, State) of
        {ok, State2} ->
            noreply(event({ringing, Answer}, State2));
        {error, Error} ->
            ?LLOG(warning, "could not set answer in invite_ringing", [Error], State),
            do_hangup(<<"Answer Error">>, State)
    end;

invite_ringing(_Answer, State) ->
    noreply(State).


%% @private Called at the B-leg
invite_answered(Answer, #state{status=inviting}=State) ->
    case update_answer(Answer, State) of
        {ok, #state{has_answer=true}=State2} ->
            {ok, {From, Dest, Opts}} = get_link(invite, State2),
            {ok, State3} = update_link(invite, undefined, State2),
            State4 = status(invite, #{dest=>Dest}, State3),
            op_reply(ok, Opts, From, State4);
        {ok, State2} ->
            ?LLOG(warning, "invite without SDP!", [], State),
            do_hangup(<<"No SDP">>, State2);
        {error, Error} ->
            ?LLOG(warning, "could not set answer in invite_answered", [Error], State),
            do_hangup(<<"Answer Error">>, State)
    end;

invite_answered(_Answer,State) ->
    ?LLOG(warning, "received unexpected answer", [], State),
    noreply(State).


%% ===================================================================
%% Events
%% ===================================================================

%% @private
do_call_event(_CallId, {ringing, PeerId, Answer}, State) ->
    #state{has_answer=HasAnswer} = State,
    case Answer of
        #{sdp:=_} when not HasAnswer ->
            case update_call_answer(Answer, PeerId, State) of
                {ok, State2} ->
                    noreply(event({ringing, Answer}, State2));
                not_upated ->
                    noreply(event({ringing, Answer}, State));
                {error, Error} ->
                    ?LLOG(warning, "remote answer error: ~p", [Error], State),
                    do_hangup(<<"Answer Error">>, State)
            end;    
        _ ->
            noreply(event({ringing, Answer}, State))
    end;

do_call_event(CallId, {answer, PeerId, Answer}, State) ->
    ?LLOG(info, "receiving call answer", [], State),
    #state{id=Id, has_answer=HasAnswer} = State,
    {ok, {From, Opts}} = get_link({call_out, CallId}, State),
    State2 = remove_link({call_out, CallId}, State),
    case nkmedia_session:set_call_peer(PeerId, Id) of
        {ok, PeerPid} ->
            State3 = add_link(peer, PeerId, PeerPid, State2),
            case Answer of
                #{sdp:=_} when not HasAnswer ->
                    case update_call_answer(Answer, PeerId, State3) of
                        {ok, State4} ->
                            State5 = status(call, #{peer=>PeerId}, State4),
                            op_reply(ok, Opts, From, State5);
                        not_updated ->
                            ?LLOG(warning, "remote answer error: not_updated", 
                                  [], State),
                            do_hangup(<<"Answer Error">>, State);
                        {error, Error} ->
                            ?LLOG(warning, "remote answer error: ~p", [Error], State),
                            do_hangup(<<"Answer Error">>, State)
                    end;    
                _ when HasAnswer ->
                    State4 = status(call, #{peer=>PeerId}, State3), 
                    op_reply(ok, Opts, From, State4);
                _ ->
                    do_hangup(<<"No SDP">>, State3)
            end;
        {error, Error} ->
            ?LLOG(warning, "error calling set_call_peer: ~p", [Error], State2),
            do_hangup(<<"Answer Error">>, State2)
    end;

do_call_event(_CallId, {hangup, Reason}, State) ->
    ?LLOG(info, "call hangup: ~p", [Reason], State),
    do_hangup(Reason, State).


%% @private
do_peer_event(_PeerId, {hangup, Reason}, State) ->
    ?LLOG(info, "received peer hangup: ~p", [Reason], State),
    do_hangup(Reason, State);

do_peer_event(_PeerId, _Event, State) ->
    % ?LLOG(info, "unexpected peer event: ~p", [Event], State),
    noreply(State).


%% @private
do_pbx_event(parked, #state{status=Status}=State)
        when Status==answer; Status==ringing; Status==echo ->
    noreply(State);

do_pbx_event(parked, #state{status=Status}=State) ->
    ?LLOG(notice, "received parked in '~p'", [Status], State),
    noreply(State);

do_pbx_event({bridge, Remote}, State) ->
    noreply(status(call, #{peer=>Remote}, State));

do_pbx_event({mcu, McuInfo}, State) ->
    noreply(status(mcu, McuInfo, State));

do_pbx_event({hangup, Reason}, State) ->
    do_hangup(Reason, State);

do_pbx_event(stop, State) ->
    do_hangup(<<"MediaServer Stop">>, State);

do_pbx_event(Event, State) ->
    ?LLOG(warning, "unexpected ms event: ~p", [Event], State),
    noreply(State).




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
            {ok, event({offer, Offer}, State2)};
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
                {ok, State2} ->
                    Session2 = Session#{answer=>Answer},
                    State3 = State2#state{has_answer=true, session=Session2},
                    {ok, event({answer, Answer}, State3)};
                {error, Error} ->
                    {error, Error}
            end;
        #{} ->
            {ok, update_session(answer, Answer, State)};
        _ ->
            {error, invalid_sdp}
    end.


%% @private
%% If pbx generated the offer, we must use this answer
update_answer_ms(Answer, #state{id=SessId, ms={fs, _}, pbx_type=outbound}=State) ->
    Mod = get_fs_mod(State),
    case Mod:answer_out(SessId, Answer) of
        ok ->
            {ok, State};
        {error, Error} ->
            ?LLOG(warning, "mediaserver error in answer_out: ~p", [Error], State),
            {error, mediaserver_error}
    end;

%% For listens, we could get the response locally
update_answer_ms(Answer, #state{type=proxy}=State) ->
    update_proxy_answer(Answer, State);

update_answer_ms(_Answer, State) ->
    {ok, State}.


%% @private
%% For P2P, the remote answer is our answer also
update_call_answer(#{sdp:=_}=AnswerB, _PeerId, #state{type=p2p}=State) ->
    update_answer(AnswerB, State);


%% For pbx, the session should have been already placed at the pbx
%% We only need to bridge
update_call_answer(#{sdp:=_}, PeerId, #state{type=pbx, pbx_type=inbound}=State) ->
    case pbx_bridge(PeerId, State) of
        ok ->
            % Wait for FS event for status change
            {ok, State};
        error ->
            {error, pbx_error}
    end;

update_call_answer(#{sdp:=_}=AnswerB, _PeerId, #state{type=proxy}=State) ->
    lager:error("PROXY ANS1: ~p", State#state.after_answer),
    update_proxy_answer(AnswerB, State);

update_call_answer(_Answer, _PeerId, _State) ->
    not_updated.


%% @private
update_proxy_answer(#{sdp:=_}=AnswerB, #state{type=proxy}=State) ->
    #state{after_answer=AfterAnswer} = State,
    case AfterAnswer of
        undefined ->
            {ok, State};
        {janus_call, Pid} ->
            case nkmedia_janus_session:videocall_answer(Pid, AnswerB) of
                {ok, AnswerA} ->
                    update_answer(AnswerA, State#state{after_answer=undefined});
                {error, Error} ->
                    {error, Error}
            end;
        {janus_listen, Pid} ->
            case nkmedia_janus_session:listen_answer(Pid, AnswerB) of
                ok ->
                    update_answer(AnswerB, State#state{after_answer=undefined});
                {error, Error} ->
                    {error, Error}
            end
    end.


%% @private
-spec get_default_offer_type(offer_op()) ->
    type() | undefined | unknown.

get_default_offer_type(Map) when is_map(Map) -> undefined;
get_default_offer_type(pbx) -> pbx;
get_default_offer_type({listen, _, _}) -> proxy;
get_default_offer_type(_) -> unknown.


%% @private
-spec get_default_answer_type(answer_op()) ->
    type() | undefined | unknown.

get_default_answer_type(Map) when is_map(Map) -> undefined;
get_default_answer_type(pbx) -> pbx;
get_default_answer_type(echo) -> proxy;
get_default_answer_type({mcu, _}) -> pbx;
get_default_answer_type({call, _}) -> proxy;
get_default_answer_type({invite, _}) -> proxy;
get_default_answer_type({publish, _}) -> proxy;
get_default_answer_type(_) -> unknown.


%% @private
update_session(Key, Val, #state{session=Session}=State) ->
    Session2 = maps:put(Key, Val, Session),
    State#state{session=Session2}.



%% @private
-spec get_proxy(#state{}) ->
    {ok, pid(), #state{}} | {error, term()}.

get_proxy(#state{type=proxy, ms=undefined}=State) ->
    case get_mediaserver(State) of
        {ok, #state{ms={janus, _}}=State2} ->
            get_proxy(State2);
        {error, Error} ->
            {error, {Error}}
    end;

get_proxy(#state{type=proxy, ms={janus, JanusId}}=State) ->
    case nkmedia_janus_session:start(JanusId) of
        {ok, JanusSessId, Pid} ->
            {ok, Pid, add_link({janus, JanusSessId}, none, Pid, State)};
        {error, Error} ->
            {error, Error}
    end.


%% @private
place_in_pbx(#state{pbx_type=inbound}=State) ->
    {ok, State};

place_in_pbx(#state{pbx_type=outbound}) ->
    {error, incompatible_pbx_type};

place_in_pbx(#state{type=pbx, ms=undefined}=State) ->
    case get_mediaserver(State) of
        {ok, #state{ms={fs, _}}=State2} ->
            place_in_pbx(State2);
        {error, Error} ->
            {error, Error}
    end;

place_in_pbx(#state{type=pbx, ms={fs, FsId}, has_answer=false}=State) ->
    #state{id=SessId, session=#{offer:=Offer}} = State,
    case nkmedia_fs_verto:start_in(SessId, FsId, Offer) of
        {ok, SDP} ->
            % lager:warning("SDP to Verto: ~s", [maps:get(sdp, Offer)]),
            %% TODO Send and receive pings
            % lager:warning("SDP from Verto: ~s", [SDP]),
            State2 = update_answer(#{sdp=>SDP}, State#state{pbx_type=inbound}),
            receive
                {'$gen_cast', {pbx_event, _, parked}} -> State2
            after 
                2000 -> 
                    ?LLOG(warning, "parked not received", [], State),
                    State2
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @private
get_pbx_offer(#state{pbx_type=outbound}=State) ->
    {ok, State};

get_pbx_offer(#state{pbx_type=inbound}) ->
    {error, incompatible_pbx_type};

get_pbx_offer(#state{type=pbx, ms=undefined}=State) ->
    case get_mediaserver(State) of
        {ok, #state{ms={fs, _}}=State2} ->
            get_pbx_offer(State2);
        {error, Error} ->
            {error, {get_pbx_offer_error, Error}}
    end;

get_pbx_offer(#state{type=pbx, ms={fs, FsId}, has_offer=false}=State) ->
    #state{id=SessId, session=Session} = State,
    Mod = get_fs_mod(State),
    case Mod:start_out(SessId, FsId, #{}) of
        {ok, SDP} ->
            %% TODO Send and receive pings
            Offer = maps:get(offer, Session, #{}),
            update_offer(Offer#{sdp=>SDP}, State#state{pbx_type=outbound});
        {error, Error} ->
            {error, {backend_out_error, Error}}
    end.


% %% @private
% get_proxy_answer(AnswerB, #state{ms={janus, _}, after_answer=AfterAnswer}=State) ->


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


%% @private
do_hangup(_Reason, #state{hangup_sent=true}=State) ->
    {stop, normal, State};

do_hangup(Reason, #state{id=SessId, ms=MS}=State) ->
    iter_links(
        fun
            (invite, {From, _Opts, _Dest}) ->
                nklib_util:reply(From, {hangup, Reason});
            ({call_out, CallId}, {From, _Opts}) ->
                nklib_util:reply(From, {hangup, Reason}),
                nkmedia_call:hangup(CallId, <<"Caller Stopped">>);
            ({janus, JanusSessId}, none) ->
                nkmedia_janus_session:stop(JanusSessId);
            (_, _) ->
                ok
        end,
        State),
    case MS of
        {fs, FsId} ->
            nkmedia_fs_cmd:hangup(FsId, SessId);
        _ ->
            ok
    end,
    {stop, normal, event({hangup, Reason}, State#state{hangup_sent=true})}.


%% @private
status(Status, State) ->
    status(Status, #{}, State).


%% @private
status(Status, _Info, #state{status=Status}=State) ->
    restart_timer(State);

%% @private
status(NewStatus, Info, #state{session=Session}=State) ->
    ?LLOG(notice, "status changed to ~p", [NewStatus], State),
    State2 = restart_timer(State#state{status=NewStatus}),
    State3 = State2#state{session=Session#{status=>NewStatus, ext_status=>Info}},
    event({status, NewStatus, Info}, State3).


%% @private
event(Event, #state{id=Id}=State) ->
    case Event of
        {status, _, _} -> ok;
        {Key, _} -> ?LLOG(info, "sending event: ~p", [Key], State);
        _ -> ?LLOG(info, "sending event: ~p", [Event], State)
    end,
    iter_links(
        fun
            (peer, PeerId) ->
                nkmedia_session:peer_event(PeerId, Id, Event);
            (call_in, CallId) ->
                nkmedia_call:session_event(CallId, Id, Event);
            (_, _) ->
                ok
        end,
        State),
    {ok, State2} = handle(nkmedia_session_event, [Id, Event], State),
    State2.


%% @private
restart_timer(#state{status=Status, timer=Timer, session=Session}=State) ->
    nklib_util:cancel_timer(Timer),
    Time = if
        Status==wait; Status==calling; Status==inviting ->
            maps:get(wait_timeout, Session, ?DEF_WAIT_TIMEOUT);
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
noreply(State) ->
    {noreply, State, get_hibernate(State)}.


%% @private
get_hibernate(#state{status=Status})
    when Status==echo; Status==call; Status==mcu; 
         Status==publish; Status==listen ->
    hibernate;
get_hibernate(_) ->
    infinity.


%% @private
add_link(Id, Data, Pid, State) ->
    nkmedia_links:add(Id, Data, Pid, #state.links, State).


%% @private
get_link(Id, State) ->
    nkmedia_links:get(Id, #state.links, State).


%% @private
update_link(Id, Data, State) ->
    nkmedia_links:update(Id, Data, #state.links, State).


%% @private
remove_link(Id, State) ->
    nkmedia_links:remove(Id, #state.links, State).


%% @private
extract_link_mon(Mon, State) ->
    nkmedia_links:extract_mon(Mon, #state.links, State).


%% @private
iter_links(Fun, State) ->
    nkmedia_links:iter(Fun, #state.links, State).
