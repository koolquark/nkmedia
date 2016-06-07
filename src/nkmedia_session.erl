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
-export([set_offer/3, set_answer/3, update/3]).
-export([invite_reply/2, link_session/2]).
-export([get_all/0, find/1, peer_event/3]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, config/0, status/0, session/0, event/0]).
-export_type([invite/0]).


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Session2 ~s (~p) "++Txt, 
               [State#state.id, State#state.status | Args])).

-include("nkmedia.hrl").

%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().

-type config() :: 
    #{
        id => id(),                             % Generated if not included
        hangup_after_error => boolean(),        % Default true
        wait_timeout => integer(),              % Secs
        ring_timeout => integer(),          
        ready_timeout => integer(),
        peer => id()
        % call => {nkmedia_call:id(), pid()}      % If is started by nkmedia_call
}.

-type invite() :: term().

-type status() ::
    wait      |   % Waiting for an operation
    offer     |   % We have an offer, waiting answer
    invite    |   % Launching an invite
    ready.        % We han a answer


 
-type session() ::
    config () | 
    #{
        srv_id => nkservice:id(),
        status => status()
    }.

-type offer_op() ::
    {offer, nkmedia:offer()}   |  % Set raw WebRTC or SIP SDP offer (use sdp_type)
    atom() | tuple().             % See backends and plugins for options

    % proxy               |  % Use a proxy (WebRTC or SIP) to generate a new offer
    % pbx                 |  % Use PBX to generate offer
    % mcu,                |  % Generate an offer from MCU
    % play                |
    % listen              |  % Get offer to be a listener


-type answer_op() ::
    {answer, nkmedia:answer()}  |  % Set raw answer (use sdp_type)
    {invite, invite()}          |  % Perfom and INVITE and get answer
    atom() | tuple().              % See backends and plugins for options

    % echo                |  % Perform media echo (several backends)
    % pbx                 |  % Put session into pbx (see options)
    % mcu                 |  % Connect offer to mcu (pbx)
    % publish             |  % Connect offer to publish (proxy)

-type update() ::
    term().                 % See backends and plugins for options


-type op_opts() ::  
    #{
        async => boolean(),  
        invite_rejected_hangup => boolean(),
        term() => term()       % See backends and plugins for options         
    }.


-type invite_reply() :: 
    ringing |                           % Informs invite is ringing
    {ringing, nkmedia:answer()}  |      % The same, with answer
    {answered, nkmedia:answer()} |      % Invite is answered
    {rejected, nkmedia:hangup_reason()}.


-type event() ::
    {status, status()} | 
    {offer, nkmedia:offer()} | {answer, nkmedia:answer()} |
    {offer_op, offer_op(), map()} | {answer_op, answer_op(), map()} |
    {ringing, nkmedia:answer()} | {info, term()} |
    {hangup, nkmedia:hangup_reason()}.



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
    {ok, status(), integer()}.

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
%% You can not only set a raw offer(), but order the session to generate the
%% offer from some other operation, like being a proxy
-spec set_offer(id(), offer_op(), op_opts()) ->
    ok | {ok, #{offer=>nkmedia:offer()}} | {error, term()}.

set_offer(SessId, OfferOp, #{async:=true}=Opts) ->
    do_cast(SessId, {offer_op, OfferOp, Opts});

set_offer(SessId, OfferOp, Opts) ->
    do_call(SessId, {offer_op, OfferOp, Opts}).


%% @doc Sets the session's answer, if not already set
%% You can raw answer(), or order the session to get the
%% answer from some other operation, like inviting or publishing
-spec set_answer(id(), answer_op(), op_opts()) ->
    ok | {ok, #{answer=>nkmedia:answer()}} | {error, term()}.

set_answer(SessId, AnswerOp, #{async:=true}=Opts) ->
    do_cast(SessId, {answer_op, AnswerOp, Opts});

set_answer(SessId, AnswerOp, Opts) ->
    do_call(SessId, {answer_op, AnswerOp, Opts}).


%% @doc Update session's
%% Only some specific operations allow to be updated
-spec update(id(), update(), op_opts()) ->
    ok | {ok, map()} | {error, term()}.

update(SessId, OfferOp, #{async:=true}=Opts) ->
    do_cast(SessId, {update, OfferOp, Opts});

update(SessId, OfferOp, Opts) ->
    do_call(SessId, {update, OfferOp, Opts}).


%% @doc Informs the session of a ringing or answered status for an invite
-spec invite_reply(id(), invite_reply()) ->
    ok | {error, term()}.

invite_reply(SessId, Reply) ->
    do_cast(SessId, {invite_reply, Reply}).


%% @doc Links this session to another
%% If the other session fails, an event will be generated
-spec link_session(id(), id()) ->
    ok | {error, term()}.

link_session(SessId, SessIdB) ->
    do_cast(SessId, {link_session_a, SessIdB}).


%% @private
-spec get_all() ->
    [{id(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec peer_event(id(), id(), event()) ->
    ok | {error, term()}.

peer_event(Id, IdB, Event) ->
    do_cast(Id, {peer_event, IdB, Event}).


% ===================================================================
%% gen_server behaviour
%% ===================================================================

-type link_id() ::
    offer | answer | invite | peer_a | peer_b | term().

-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    status :: status() | init,
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
    State = #state{
        id = Id, 
        srv_id = SrvId, 
        status = init,
        links = nkmedia_links:new(),
        session = Session
    },
    lager:info("NkMEDIA Session ~s starting (~p)", [Id, self()]),
    handle(nkmedia_session_init, [Id], status(wait, State)).
        

%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(get_session, _From, #state{session=Session}=State) ->
    {reply, {ok, Session}, State};

handle_call(get_status, _From, State) ->
    #state{status=Status, timer=Timer} = State,
    {reply, {ok, Status, erlang:read_timer(Timer) div 1000}, State};

handle_call({offer_op, OfferOp, Opts}, From, #state{status=wait}=State) ->
    do_offer_op(OfferOp, Opts, From, State);

handle_call({offer_op, _OfferOp, _Opts}, _From, State) ->
    {reply, {error, invalid_status}, State};

handle_call({answer_op, AnswerOp, Opts}, From, #state{status=offer}=State) ->
    do_answer_op(AnswerOp, Opts, From, State);

handle_call({answer_op, _AnswerOp, _Opts}, _From, State) ->
    {reply, {error, invalid_status}, State};

handle_call({update, Update, Opts}, From, State) ->
    do_update_op(Update, Opts, From, State);

handle_call(get_state, _From, State) -> 
    {reply, State, State};

handle_call(Msg, From, State) -> 
    handle(nkmedia_session_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({offer_op, OfferOp, Opts}, #state{status=wait}=State) ->
    do_offer_op(OfferOp, Opts, undefined, State);

handle_cast({offer_op, _OfferOp, _Opts}, State) ->
    ?LLOG(warning, "invalid status for offer_op", [], State),
    noreply(State);

handle_cast({answer_op, AnswerOp, Opts}, #state{status=offer}=State) ->
    do_answer_op(AnswerOp, Opts, undefined, State);

handle_cast({answer_op, _AnswerOp, _Opts}, State) ->
    ?LLOG(warning, "invalid status for answer_op", [], State),
    noreply(State);

handle_cast({update, Update, Opts}, State) ->
    do_answer_op(Update, Opts, undefined, State);

handle_cast({info, Info}, State) ->
    noreply(event({info, Info}, State));

handle_cast({invite_reply, Reply}, #state{status=invite}=State) ->
    do_invite_reply(Reply, State);

handle_cast({invite_reply, Reply}, State) ->
    ?LLOG(notice, "received unexpected invite_reply: ~p", [Reply], State),
    noreply(State);

handle_cast({link_session_a, IdB}, #state{id=IdA}=State) ->
    case find(IdB) of
        {ok, Pid} ->
            gen_server:cast(Pid, {link_session_b, IdA, self()}),
            State2 = add_link({peer, IdB}, a, Pid, State),
            noreply(State2);
        not_found ->
            ?LLOG(warning, "trying to link unknown session ~s", [IdB], State),
            {stop, normal, State}
    end;

handle_cast({link_session_b, IdB, Pid}, State) ->
    State2 = add_link({peer, IdB}, b, Pid, State),
    noreply(State2);

handle_cast({peer_event, PeerId, Event}, State) ->
    case get_link({peer, PeerId}, State) of
        {ok, Type} ->
            do_peer_event(PeerId, Type, Event, State);
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
        {ok, Id, Data, State2} ->
            case Reason of
                normal ->
                    ?LLOG(info, "linked ~p down (normal)", [Id], State);
                _ ->
                    ?LLOG(notice, "linked ~p down (~p)", [Id, Reason], State)
            end,
            case Id of
                offer ->
                    do_hangup(<<"Offer Monitor Stop">>, State2);
                answer ->
                    do_hangup(<<"Answer Monitor Stop">>, State2);
                invite ->
                    do_hangup(<<"Invite Monitor Stop">>, State2);
                {peer, IdB} ->
                    event({peer_down, {IdB, Data}, Reason}, State),
                    noreply(State2)
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
    {ok, State2} = handle(nkmedia_session_terminate, [Reason], State),
    _ = do_hangup(<<"Process Terminate">>, State2).




%% ===================================================================
%% Internal
%% ===================================================================


%% @private
do_offer_op(OfferOp, Opts, From, State) ->
    case handle(nkmedia_session_offer_op, [OfferOp, Opts], State) of
        {ok, {offer, Offer}, Opts2, State2} ->
            case update_offer(Offer, State2) of
                {ok, State3} ->
                    case OfferOp of
                        {offer, _} ->
                           State4 = update_offer_op(offer, Opts2, State3),
                           reply_ok({ok, Opts2}, From, State4);
                        _ ->
                            State4 = update_offer_op(OfferOp, Opts2, State3),
                            reply_ok({ok, Opts2#{offer=>Offer}}, From, State4)
                    end;
                {error, Error, State3} ->
                    reply_error(Error, From, State3)
            end;
        {error, Error, State2} ->
            reply_error(Error, From, State2)
    end.


%% @private
do_answer_op(AnswerOp, Opts, From, State) ->
    case handle(nkmedia_session_answer_op, [AnswerOp, Opts], State) of
        {ok, {invite, Dest}, Opts2, State2} ->
            State3 = update_answer_op(invite, Opts2#{dest=>Dest}, State2),
            do_invite(Dest, Opts2, From, State3);
        {ok, {answer, Answer}, Opts2, State2} ->
            case update_answer(Answer, State2) of
                {ok, State3} ->
                    case AnswerOp of
                        {answer, _} -> 
                            State4 = update_answer_op(answer, Opts2, State3),
                            reply_ok({ok, Opts2}, From, State4);
                        _ -> 
                            State4 = update_answer_op(AnswerOp, Opts2, State3),
                            reply_ok({ok, Opts2#{answer=>Answer}}, From, State4)
                    end;
                {error, Error, State3} ->
                    reply_error(Error, From, State3)
            end;
        {error, Error, State2} ->
            reply_error(Error, From, State2)
    end.


%% @private
do_update_op(Update, Opts, From, State) ->
    case handle(nkmedia_session_update, [Update, Opts], State) of
        {ok, Opts2, State2} ->
            State3 = update_op(Update, Opts2, State2),
            reply_ok({ok, Opts2}, From, State3);
        {error, Error, State2} ->
            reply_error(Error, From, State2)
    end.



%% @private
do_invite(Dest, Opts, From, #state{id=Id, session=Session}=State) ->
    State2 = event(invite, status(invite, State)),
    #{offer:=Offer} = Session,
    case handle(nkmedia_session_invite, [Id, Dest, Offer], State2) of
        {ringing, Answer, State3} ->
            State4 = answer_op_link(Answer, Dest, Opts, From, State3),
            do_invite_reply({ringing, Answer}, State4);
        {answer, Answer, State3} ->
            State4 = answer_op_link(Answer, Dest, Opts, From, State3),
            do_invite_reply({answer, Answer}, State4);
        {rejected, Reason, State3} ->
            do_invite_reply({rejected, Reason}, State3);
        {async, Answer, State3} ->
            ?LLOG(info, "invite delayed", [], State3),
            State4 = answer_op_link(Answer, Dest, Opts, From, State3),
            noreply(State4)
            % case update_answer(Answer, State5) of
            %     {ok, State6} ->
            %         noreply(State6);
            %     {error, Error, State6} ->
            %         ?LLOG(warning, "could not set answer in invite_ringing", 
            %               [Error], State6),
            %         do_hangup(<<"Answer Error">>, State6)
            % end;
    end.


%% @private
do_invite_reply(ringing, State) ->
    do_invite_reply({ringing, #{}}, State);

do_invite_reply({ringing, Answer}, State) ->
    case update_answer(Answer, State) of
        {ok, State2} ->
            noreply(event({ringing, Answer}, State2));
        {error, Error, State2} ->
            ?LLOG(warning, "could not set answer in invite_ringing", [Error], State),
            do_hangup(<<"Answer Error">>, State2)
    end;

do_invite_reply({answered, Answer}, State) ->
    case update_answer(Answer, State) of
        {ok, #state{status=ready}=State2} ->
            {ok, #{from:=From, opts:=Opts}} = get_link(invite, State2),
            {ok, State3} = update_link(invite, undefined, State2),
            reply_ok({ok, Opts}, From, State3);
        {ok, State2} ->
            ?LLOG(warning, "invite without SDP!", [], State),
            do_hangup(<<"No SDP">>, State2);
        {error, Error, State2} ->
            ?LLOG(warning, "could not set answer in invite: ~p", [Error], State),
            do_hangup(<<"Answer Error">>, State2)
    end;

do_invite_reply({rejected, Reason}, State) ->
    {ok, #{from:=From, opts:=Opts}} = get_link(invite, State),
    State2 = remove_link(invite, State),
    nklib_util:reply(From, {rejected, Reason}),
    case maps:get(invite_rejected_hangup, Opts, true) of
        true ->
            do_hangup(<<"Call Rejected">>, State2);
        false ->
            status(offer, State2)
    end.




%% @private
answer_op_link(Answer, Dest, Opts, From, State) ->
    Pid = maps:get(pid, Answer, undefined),
    add_link(invite, #{dest=>Dest, opts=>Opts, from=>From}, Pid, State).



%% ===================================================================
%% Events
%% ===================================================================

do_peer_event(PeerId, Type, Event, State) ->
    case handle(nkmedia_session_peer_event, [PeerId, Type, Event], State) of
        {ok, ignore, State2} ->
            noreply(State2);
        {ok, {hangup, Reason}, State2} ->
            do_hangup(Reason, State2);
        {ok, _, State2} ->
            ?LLOG(warning, "unexpected peer event from ~s (~p): ~p", 
                  [PeerId, Type, Event], State2),
            noreply(State2)
    end.



%% ===================================================================
%% Util
%% ===================================================================


%% @private
-spec update_offer(nkmedia:offer(), #state{}) ->
    {ok, #state{}} | {error, term(), #state{}}.

update_offer(Offer, State) when is_map(Offer) ->
    #state{status=Status, session=Session} = State,
    State2 = case Offer of
        #{pid:=Pid} ->
            add_link(offer, none, Pid, State);
        _ ->
            State
    end,
    OldOffer = maps:get(offer, Session, #{}),
    Offer2 = maps:merge(OldOffer, Offer),
    case Status==wait of
        true ->
            set_updated_offer(Offer, State2);
        false ->
            SDP = maps:get(sdp, OldOffer),
            case Offer2 of
                #{sdp:=SDP2} when SDP2 /= SDP ->
                    {error, duplicated_offer, State2};
                _ ->
                    set_updated_offer(Offer2, State2)
            end
    end;

update_offer(_Offer, State) ->
    {error, invalid_offer, State}.


%% @private
set_updated_offer(Offer, #state{status=Status}=State) ->
    case handle(nkmedia_session_updated_offer, [Offer], State) of
        {ok, Offer2, State2} ->
            State3 = update_session(offer, Offer2, State2),
            case Offer2 of
                #{sdp:=_} when Status == wait ->
                    State4 = event({offer, Offer2}, State3),
                    {ok, status(offer, State4)};
                _ ->
                    {ok, State3}
            end;
        {error, Error} ->
            {error, Error, State}
    end.


%% @private
update_offer_op(OfferOp, Data, State) ->
    State2 = update_session(offer_op, {OfferOp, Data}, State),
    event({offer_op, OfferOp, Data}, State2).


%% @private
-spec update_answer(nkmedia:answer(), #state{}) ->
    {ok, #state{}} | {error, term(), #state{}}.

update_answer(Answer, State) when is_map(Answer) ->
    #state{status=Status, session=Session} = State,
    State2 = case Answer of
        #{pid:=Pid} ->
            add_link(answer, none, Pid, State);
        _ ->
            State
    end,
    OldAnswer = maps:get(answer, Session, #{}),
    Answer2 = maps:merge(OldAnswer, Answer),
    if 
        Status==offer; Status==invite ->
            set_updated_answer(Answer2, State2);
        Status==ready ->
            SDP = maps:get(sdp, OldAnswer),
            case Answer2 of
                #{sdp:=SDP2} when SDP2 /= SDP ->
                    {error, duplicated_answer, State};
                _ ->
                    set_updated_answer(Answer, State2)
            end;
        true ->
            {error, offer_not_set, State2}
    end;

update_answer(_Answer, State) ->
    {error, invalid_answer, State}.


%% @private
set_updated_answer(Answer, #state{status=Status}=State) ->
    case handle(nkmedia_session_updated_answer, [Answer], State) of
        {ok, Answer2, State2} ->
            State3 = update_session(answer, Answer2, State2),
            case Answer2 of
                #{sdp:=_} when Status /= ready ->
                    State4 = event({answer, Answer2}, State3),
                    {ok, status(ready, State4)};
                _ ->
                    {ok, State3}
            end;
        {error, Error} ->
            {error, Error, State}
    end.


%% @private
update_answer_op(AnswerOp, Data, State) ->
    State2 = update_session(answer_op, {AnswerOp, Data}, State),
    event({answer_op, AnswerOp, Data}, State2).


%% @private
update_op(Op, Data, State) ->
    State2 = update_session(op, {Op, Data}, State),
    event({op, Op, Data}, State2).


%% @private
update_session(Key, Val, #state{session=Session}=State) ->
    Session2 = maps:put(Key, Val, Session),
    State#state{session=Session2}.



%% @private
reply_ok(Reply, From, State) ->
    nklib_util:reply(From, Reply),
    noreply(State).


reply_error(Error, From, #state{session=Session}=State) ->
    nklib_util:reply(From, {error, Error}),
    case maps:get(hangup_after_error, Session, true) of
        true ->
            ?LLOG(warning, "operation error: ~p", [Error], State),
            do_hangup(<<"Operation Error">>, status(wait, State));
        false ->
            noreply(State)
    end.


%% @private
do_hangup(_Reason, #state{hangup_sent=true}=State) ->
    {stop, normal, State};

do_hangup(Reason, State) ->
    {ok, State2} = handle(nkmedia_session_hangup, [Reason], State),
    iter_links(
        fun
            (invite, #{from:=From}) ->
                nklib_util:reply(From, {hangup, Reason});
            (_, _) ->
                ok
        end,
        State2),
    {stop, normal, event({hangup, Reason}, State2#state{hangup_sent=true})}.


%% @private
status(Status, #state{status=Status}=State) ->
    restart_timer(State);

%% @private
status(NewStatus, State) ->
    ?LLOG(info, "status changed to ~p", [NewStatus], State),
    State2 = restart_timer(State#state{status=NewStatus}),
    State3 = update_session(status, NewStatus, State2),
    event({status, NewStatus}, State3).


%% @private
event(Event, #state{id=Id}=State) ->
    case Event of
        {status, _} -> 
            ok;
        {offer, _} ->
            ?LLOG(info, "sending offer", [], State);
        {answer, _} ->
            ?LLOG(info, "sending answer", [], State);
        _ -> 
            ?LLOG(info, "sending event: ~p", [Event], State)
    end,
    iter_links(
        fun
            (peer_a, PeerId) -> peer_event(PeerId, Id, Event);
            (peer_b, PeerId) -> peer_event(PeerId, Id, Event);
            (_, _) -> ok
        end,
        State),
    {ok, State2} = handle(nkmedia_session_event, [Id, Event], State),
    State2.


%% @private
restart_timer(#state{status=Status, timer=Timer, session=Session}=State) ->
    nklib_util:cancel_timer(Timer),
    Time = case Status of
        ready -> 
            maps:get(ready_timeout, Session, ?DEF_READY_TIMEOUT);
        _ ->
            maps:get(wait_timeout, Session, ?DEF_WAIT_TIMEOUT)
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
    do_call(SessId, Msg, 1000*?DEF_RING_TIMEOUT).


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
noreply(#state{status=ready}=State) ->
    {noreply, State, hibernate};
noreply(State) ->
    {noreply, State}.


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
