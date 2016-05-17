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

% There are two types of sessions:

%  - inbound sessions: 
%     You MUST supply an offer. 
%     If you supply a backend, it wil be placed there, and enter the 'ready'
%     state. You can call pbx_get_answer/1 to get the answering SDP.
%     You can send them to an mcu, bridge, etc.
%     If you don't supply a mediaserver, will stay in 'wait' state
%
% - oubound sessions:
%     You MUST supply a 'call_dest' parameter
%     If you supply an sdp_offer, it will be used.
%     If you don't supply an sdp_offer. You MUST supply a backend.
%     The backend will make an sdp_offer, and send the call
%     The session will start in 'ready' state.
% 
%  Process for a typical call:
%  - user starts an inbound session. It should include an offer, and some
%    key to detect events later on (in nkmedia_session_event/3).
%  - The backend is identified in the config or, if not there, calling
%    nkmedia_session_get_backend/2, based on the offer.
%  - If it is not p2p, the mediaserver is selected calling
%    nkmedia_session_get_mediaserver/2. It fails if none is found.
%  - If mediaserver is 'none' (p2p backend) the session enters 'wait' state.
%    If there is a mediaserver, the call is placed there, and the call enters
%    'ready' state, including an 'answer' key that the caller must user.
%  - The user starts a call calling to_call/2 with a destination. The session starts
%    a new nkmedia_call process, sending the same config but removing the sdp from
%    the offer (unless it is a p2p call), and including session_id and session_pid.
%    The call enters 'calling' state.
%  - The call will call nkmedia_call_resolve/2 with the destination, to get a list of 
%    resolved destinations. Typically the technology to use is reflected in each
%    destionation (like {verto, pid()}).
%  - When the time comes for each launch, the call calls nkmedia_call_out/2, where
%    it can be decided to go ahead, to retry later or abort this branch
%  - For each branch, a new outbound session is started. 
%    If it is a p2p call, the offer would include the sdp, and the call is intiated
%    to the user calling nkmedia_session_out/3. 
%    If not, first an sdp is get from the mediaserver, and the offer is updated before
%    calling nkmedia_session_out/3.
%  - The called user can reply inmediately or later calling reply_ringing/2 and 
%    reply_answered/2. At least on them must carry an answer. 
%  - When the first ringing is received, the status of the outbound session 
%    changes to ringing. This is detected  by the call, that also changes to ringing. 
%    This is again detected by the inbound sessions, that changes to ringing state. 
%    The caller can detect this event and see if there is any early media.
%    Received early media is received only if the call is sent to a single destination.
%  - When the answers for an outbound sessions comes, the session enters 'ready'
%    state, including the answer. The call detects this and enters also 'ready' state,
%    including the answer and the session_peer_id. All other out sessions are hangup.
%  - The inbound session detects this and enters 'ready' state with the answer. 
%    (the caller can use it)
%  - If it is a p2p call, enters 'call' state. If not, the call is call at the 
%    mediaservers, and then enters 'call' state when the event is received


-module(nkmedia_session).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start/2, hangup_all/0]).
-export([get_status/1, get_session/1]).
-export([hangup/1, hangup/2, to_call/3, to_echo/2, to_mcu/3]).
-export([reply/2]).
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
        monitor => pid(),                       % Monitor this process
        b_dest => call_dest(),                  % 'call' to this destination (B-leg)
        mediaserver => mediaserver(),           % Sets mediaserver (B-leg)
        wait_timeout => integer(),              % Secs
        ring_timeout => integer(),          
        call_timeout => integer(),
        module() => term()                      % User data
}.

-type type() :: p2p | proxy | pbx.

-type call_dest() :: term().

-type status() ::
    wait    |   % Waiting for an operation, no media
    calling |   % Launching a call
    ringing |   % Received 'ringing'
    ready   |   % Waiting for operation, has media
    call    |   % Session is connected to another
    mcu     | 
    sfu     |
    record  |
    play    | 
    hangup.


%% Extended status
-type ext_status() ::
    #{
        dest => binary(),                       % For calling status
        answer => nkmedia:answer(),             % For ringing, ready
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


-type reply() :: 
    ringing | {ringing, nkmedia:answer()} | {answered, nkmedia:answer()}.


-type event() ::
    {status, status(), ext_status()} | {info, term()}.


-type pbx_event() ::
    parked | {hangup, term()} | {bridge, id()} | {mcu, map()}.


% -type proxy_event() ::
%     parked | {hangup, term()} | {bridge, id()} | {mcu, map()}.


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


%% @doc
-spec get_session(id()) ->
    {ok, session()} | {error, term()}.

get_session(SessId) ->
    do_call(SessId, get_session).


%% @doc
-spec get_status(id()) ->
    {ok, status(), ext_status(), integer()}.

get_status(SessId) ->
    do_call(SessId, get_status).


%% @doc
-spec hangup(id()) ->
    ok | {error, term()}.

hangup(SessId) ->
    hangup(SessId, 16).


%% @doc
-spec hangup(id(), nkmedia:hangup_reason()) ->
    ok | {error, term()}.

hangup(SessId, Reason) ->
    do_cast(SessId, {hangup, Reason}).


%% @private
hangup_all() ->
    lists:foreach(fun({SessId, _Pid}) -> hangup(SessId) end, get_all()).


%% @doc Starts a new call inside the session
-spec to_call(id(), nkmedia:call_dest(), config()) ->
    ok | {error, term()}.

to_call(SessId, Dest, Opts) ->
    do_cast(SessId, {to_call, Dest, Opts}).


%% @doc Sends the session to mirror
-spec to_echo(id(), map()) ->
    ok | {error, term()}.

to_echo(SessId, Opts) ->
    do_cast(SessId, {to_echo, Opts}).


%% @private
-spec to_mcu(id(), binary(), config()) ->
    ok | {error, term()}.

to_mcu(SessId, Room, Opts) ->
    do_call(SessId, {to_mcu, Room, Opts}).


%% @private Called when an outbound process delayed the response
-spec reply(id(), reply()) ->
    ok | {error, term()}.

reply(SessId, Reply) ->
    do_cast(SessId, {reply, Reply}).


%% @private
-spec get_all() ->
    [{id(), inbound|outbound, pid()}].

get_all() ->
    [{Id, Type, Pid} || {{Id, Type}, Pid} <- nklib_proc:values(?MODULE)].



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
    user | {call, nkmedia_call:id()} | janus | out.


-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    session :: session(),
    type :: type(),
    status :: status() | init,
    ms :: mediaserver(),
    links = [] :: [{link_id(), pid(), reference()}],
    has_offer = false :: boolean(),
    has_answer = false :: boolean(),
    timer :: reference()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()}.

init([#{id:=Id, srv_id:=SrvId}=Session]) ->
    true = nklib_proc:reg({?MODULE, Id}),
    nklib_proc:put(?MODULE, Id),
    State1 = #state{
        id = Id, 
        srv_id = SrvId, 
        session = #{},
        status = init,
        ms = maps:get(mediaserver, Session, undefined)
    },
    State2 = case Session of
        #{monitor:=Pid} -> add_link(user, Pid, State1);
        _ -> State1
    end,
    {ok, State3} = update_config(Session, State2),
    {ok, State4} = handle(nkmedia_session_init, [Id], State3),
    lager:info("NkMEDIA Session ~s starting (~p)", [Id, self()]),
    #state{has_offer=Offer, has_answer=Answer, session=Session3} = State4,
    case maps:find(b_dest, Session3) of
        {ok, Dest} -> 
            gen_server:cast(self(), {b_call, Dest});
        error ->
            ok
    end,
    case Offer andalso Answer of
        true -> 
            {ok, status(ready, State4)};
        false ->
            {ok, status(wait, State4)}
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

handle_call(Msg, From, State) -> 
    handle(nkmedia_session_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({b_call, Dest}, #state{type=undefined, has_offer=HasOffer}=State) ->
    case HasOffer of
        true ->
            {ok, State2} = update_config(#{type=>p2p}, State),
            handle_cast({b_call, Dest}, State2);
        false ->
            {ok, State2} = update_config(#{type=>pbx}, State),
            handle_cast({b_call, Dest}, State2)
    end;

handle_cast({b_call, Dest}, State) ->
    send_b_call(Dest, State);

handle_cast({to_call, Dest, Config}, State) ->
    case update_config(Config, State) of
        {ok, #state{type=undefined}} ->
            handle_cast({to_call, Dest, Config#{type=>p2p}}, State);
        {ok, State2} ->
            send_call(Dest, Config, State2);
        {error, Error} ->
            ?LLOG(warnng, "to_call error: ~p", [Error], State),
            stop_hangup(<<"Incompatible Type">>, State)
    end;

handle_cast({to_echo, Config}, State) ->
    case update_config(Config, State) of
        {ok, #state{type=undefined}} ->
            handle_cast({to_echo, Config#{type=>proxy}}, State);
        {ok, State2} ->
            send_echo(Config, State2);
        {error, Error} ->
            ?LLOG(warnng, "to_mirror error: ~p", [Error], State),
            stop_hangup(<<"Incompatible Type">>, State)
    end;

% handle_cast({to_mcu, Room, _Opts}, State) ->
%     lager:warning("TO MCU"),

%     case send_to_mcu(Room, State) of
%         {ok, State2} ->
%             {reply, ok, State2};
%         {error, Error} ->
%             {reply, {error, Error}, State}
%     end;

handle_cast({hangup, Reason}, State) ->
    ?LLOG(info, "external hangup: ~p", [Reason], State),
    stop_hangup(Reason, State);

handle_cast({info, Info}, State) ->
    {noreply, event({info, Info}, State)};

handle_cast({call_event, CallId, Event}, #state{links=Links}=State) ->
    case lists:keyfind({call, CallId}, 1, Links) of
        {_, _, _} ->
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

handle_cast({reply, ringing}, State) ->
    do_ringing(#{}, State);

handle_cast({reply, {ringing, Answer}}, State) ->
    do_ringing(Answer, State);

handle_cast({reply, {answered, Answer}}, State) ->
    do_answered(Answer, State);

handle_cast({reply, Reply}, State) ->
    ?LLOG(warning, "unrecognized reply: ~p", [Reply], State),
    stop_hangup(<<"Unrecognized Reply">>, State);

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
            stop_hangup(<<"Monitor Stop">>, State);
        user ->
            ?LLOG(notice, "user monitor down (~p)", [Reason], State),
            stop_hangup(<<"Monitor Stop">>, State);
        {call, CallId} when Reason==normal ->
            ?LLOG(info, "call ~s down (normal)", [CallId], State),
            stop_hangup(<<"Call Down">>, State);
        {call, CallId} ->
            ?LLOG(warning, "call ~s down (~p)", [CallId, Reason], State),
            stop_hangup(<<"Call Down">>, State);
        out when Reason==normal ->
            ?LLOG(notice, "called session out down (normal)", [], State),
            stop_hangup(<<"Call Out Down">>, State);
        out ->
            ?LLOG(notice, "called session out down (~p)", [Reason], State),
            stop_hangup(<<"Call Out Down">>, State);
        janus when Reason==normal ->
            ?LLOG(notice, "Janus down (normal)", [], State),
            stop_hangup(<<"Janus Out Down">>, State);
        janus ->
            ?LLOG(notice, "Janus down (~p)", [Reason], State),
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
    ?LLOG(info, "stopped: ~p", [Reason], State),
    catch handle(nkmedia_session_terminate, [Reason], State),
    _ = stop_hangup(<<"Session Stop">>, State).



%% ===================================================================
%% Internal - A-leg Specific
%% ===================================================================


%% @private A-leg
send_call(Dest, Config, #state{type=p2p, has_offer=true, session=Session}=State) ->
    #{offer:=Offer} = Session,
    do_send_call(Dest, Config, Offer, State);

send_call(Dest, Config, #state{type=pbx, has_offer=true}=State) ->
    #state{session=#{offer:=Offer}} = State,
    Offer2 = maps:remove(sdp, Offer),
    case get_mediaserver(State) of
        {ok, {fs, _}, State2} ->
            case maps:get(pre_answer, Config, false) of
                true ->
                    case pbx_get_answer(State2) of
                        {ok, State3} ->
                            do_send_call(Dest, Config, Offer2, State3);
                        error ->
                            stop_hangup(<<"Mediaserver Error">>, State)
                    end;
                false ->
                    lager:error("NO PRE ANSWER"),
                    do_send_call(Dest, Config, Offer2, State2)
            end;
        {error, Error} ->
            ?LLOG(warning, "could not get mediaserver: ~p", [Error], State),
            stop_hangup(<<"No Mediaserver Available">>, State)
    end;

send_call(Dest, Config, #state{id=Id, type=proxy, has_offer=true}=State) ->
    #state{session=#{offer:=Offer}} = State,
    case get_mediaserver(State) of
        {ok, {janus, JanusId}, State2} ->
            case nkmedia_janus_session:start(Id, JanusId) of
                {ok, Pid} ->
                    State3 = add_link(janus, Pid, State2),
                    case nkmedia_janus_session:videocall(Pid, Offer) of
                        {ok, #{sdp:=SDP}} ->
                            Offer2 = Offer#{sdp=>SDP},
                            do_send_call(Dest, Config, Offer2, State3);
                        {error, Error} ->
                            ?LLOG(warning, "could not get offer from proxy: ~p",
                                  [Error], State),
                            stop_hangup(<<"Proxy Error">>, State3)
                    end;
                {error, Error} ->
                    ?LLOG(warning, "could not connect to proxy: ~p", [Error], State),  
                    stop_hangup(<<"Proxy Error">>, State2)
            end;
        {error, Error} ->
            ?LLOG(warning, "could not get mediaserver: ~p", [Error], State),
            stop_hangup(<<"No Mediaserver Available">>, State)
    end;

send_call(_Dest, _Config, State) ->
    stop_hangup(<<"Incompatible Call">>, State).



%% @private
send_echo(_Config, #state{id=Id, type=proxy, has_offer=true}=State) ->
    #state{session=#{offer:=Offer}} = State,
    case get_mediaserver(State) of
        {ok, {janus, JanusId}, State2} ->
            case nkmedia_janus_session:start(Id, JanusId) of
                {ok, Pid} ->
                    State3 = add_link(janus, Pid, State2),
                    case nkmedia_janus_session:echo(Pid, Offer) of
                        {ok, #{sdp:=_}=Answer} ->
                            State4 = status(ready, #{answer=>Answer}, State3),
                            {noreply, status(echo, State4)};
                        {error, Error} ->
                            ?LLOG(warning, "could not get offer from proxy: ~p",
                                  [Error], State),
                            stop_hangup(<<"Proxy Error">>, State3)
                    end;
                {error, Error} ->
                    ?LLOG(warning, "could not connect to proxy: ~p", [Error], State),  
                    stop_hangup(<<"Proxy Error">>, State2)
            end;
        {error, Error} ->
            ?LLOG(warning, "could not get mediaserver: ~p", [Error], State),
            stop_hangup(<<"No Mediaserver Available">>, State)
    end;

send_echo(_Config, State) ->
    stop_hangup(<<"Incompatible Echo">>, State).


%% @private
do_send_call(Dest, _Config, Offer, State) ->
    #state{id=Id, session=Session} = State,
    NotShared = [id, answer, monitor, b_dest, status, ext_status],
    Config1 = maps:without(NotShared, Session),
    Config2 = Config1#{session_id=>Id, session_pid=>self(), offer=>Offer}, 
    {ok, CallId, CallPid} = nkmedia_call:start(Dest, Config2),
    State2 = add_link({call, CallId}, CallPid, State),
    {noreply, status(calling, #{dest=>Dest}, State2)}.


%% @private
get_mediaserver(#state{ms=undefined}=State) ->
    #state{srv_id=SrvId, type=Type, session=Session} = State,
    case SrvId:nkmedia_session_get_mediaserver(Type, Session) of
        {ok, MS, Session2} ->
            Session3 = Session2#{mediaserver=>MS},
            {ok, MS, State#state{ms=MS, session=Session3}};
        {error, Error} ->
            {error, Error}
    end;

get_mediaserver(#state{ms=MS}=State) ->
    {ok, MS, State}.


%% @private Called at A-leg
pbx_get_answer(#state{ms={fs, _}, session=#{answer:=_}}=State) ->
    {ok, State};

pbx_get_answer(#state{ms={fs, FsId}}=State) ->
    #state{id=SessId,session=#{offer:=Offer}=Session} = State,
    case nkmedia_fs_verto:start_in(SessId, FsId, Offer) of
        {ok, SDP} ->
            %% TODO Send and receive pings
            Answer = #{sdp=>SDP},
            Session2 = Session#{answer=>Answer},
            State2 = State#state{session=Session2},
            {ok, status(ready, #{answer=>Answer}, State2)};
        {error, Error} ->
            ?LLOG(warning, "could not get answer from pbx: ~p", [Error], State),
            error
    end.


%% @private
do_call_event(_CallId, {status, calling, _}, #state{status=calling}=State) ->
    {noreply, State};

do_call_event(_CallId, {status, ringing, Data}, #state{status=calling}=State) ->
    #state{type=Type} = State,
    HasMedia = case Data of
        #{answer := #{sdp:=_}}  -> true;
        _ -> false
    end,
    case HasMedia of
        true when Type==pbx ->
            case pbx_get_answer(State) of
                {ok, State2} ->
                    {noreply, status(ringing, Data, State2)};
                error ->
                    stop_hangup(<<"Mediaserver Error">>, State)
            end;
        true when Type==proxy ->
            case proxy_get_answer(maps:get(answer, Data), State) of
                {ok, State2} ->
                    {noreply, status(ringing, Data, State2)};
                error ->
                    stop_hangup(<<"Mediaserver Error">>, State)
            end;
        _ ->
            {noreply, status(ringing, Data, State)}
    end;

do_call_event(_CallId, {status, ringing, _Data}, #state{status=ringing}=State) ->
    {noreply, State};

do_call_event(_CallId, {status, ready, Data}, #state{status=Status}=State)
        when Status==calling; Status==ringing ->
    #state{session=Session, type=Type} = State,
    #{answer:=Answer, session_peer_id:=PeerId} = Data,
    State2 = status(ready, #{answer=>Answer}, State),
    case Type of
        p2p -> 
            State3 = State2#state{session=Session#{answer=>Answer}},
            {noreply, status(call, #{peer_id=>PeerId}, State3)};
        pbx -> 
            case pbx_get_answer(State2) of
                {ok, State3} ->
                    case pbx_bridge(PeerId, State3) of
                        ok ->
                            {noreply, State3};  % Wait for pbx event
                        error ->
                            stop_hangup(<<"Mediaserver Error">>, State3)
                    end;
                error ->
                    stop_hangup(<<"Mediaserver Error">>, State2)
            end;
        proxy ->
            case proxy_get_answer(Answer, State2) of
                {ok, State3} ->
                    {noreply, status(call, State3)};
                error ->
                    stop_hangup(<<"Mediaserver Error">>, State2)
            end
    end;

do_call_event(_CallId, {status, hangup, #{hangup_reason:=Reason}}, 
              #state{status=Status}=State)
        when Status==calling; Status==ringing; Status==call ->
    stop_hangup(Reason, State);

do_call_event(CallId, {status, hangup, _Data}, #state{status=wait}=State) ->
    {noreply, remove_link({call, CallId}, State)};    

do_call_event(_CallId, Event, State) ->
    ?LLOG(warning, "unexpected call event: ~p", [Event], State),
    {noreply, State}.


%% @private
pbx_bridge(SessIdB, #state{id=SessIdA, ms={fs, FsId}}=State) ->
    case nkmedia_fs_cmd:set_var(FsId, SessIdA, "park_after_bridge", "true") of
        ok ->
            nkmedia_fs_cmd:bridge(FsId, SessIdA, SessIdB);
        {error, Error} ->
            ?LLOG(warning, "pbx bridge error: ~p", [Error], State),
            error
    end.

proxy_get_answer(Answer, #state{id=Id, ms={janus, _}, session=Session}=State) ->
    case nkmedia_janus_session:answer(Id, Answer) of
        {ok, SDP} ->
            Answer2 = #{sdp=>SDP},
            Session2 = Session#{answer=>Answer2},
            State2 = State#state{session=Session2},
            {ok, status(ready, #{answer=>Answer2}, State2)};
        {error, Error} ->
            ?LLOG(warning, "could not get answer from proxy: ~p", [Error], State),
            error
    end.





%% ===================================================================
%% Internal - B-leg Specific
%% ===================================================================


%% @private
send_b_call(Dest, #state{has_offer=true}=State) ->
    do_send_b_call(Dest, State);

%% We could allow no ms and get one here
send_b_call(Dest, #state{type=pbx, has_offer=false, ms={fs, _}}=State) ->
    case pbx_get_offer(State) of
        {ok, State2} ->
            do_send_b_call(Dest, State2);
        {error, Error} ->
            ?LLOG(warning, "could not place outcoming call (pbx): ~p", [Error], State),
            stop_hangup(<<"PBX Error">>, State)
    end;

send_b_call(_Dest, State) ->
    ?LLOG(warning, "could not place outcoming call: incompatible config", [], State),
    stop_hangup(<<"Config Error">>, State).


%% @private Called at B-leg
pbx_get_offer(#state{ms={fs, FsId}}=State) ->
    #state{id=SessId, session=Session} = State,
    Mod = get_fs_mod(State),
    case Mod:start_out(SessId, FsId, #{}) of
        {ok, SDP} ->
            % io:format("SDP: ~s\n", [SDP]),
            %% TODO Send and receive pings
            Offer = maps:get(offer, Session, #{}),
            Session2 = Session#{offer=>Offer#{sdp=>SDP}},
            {ok, State#state{session=Session2}};
        {error, Error} ->
            {error, {backend_out_error, Error}}
    end.


%% @private Starts a B-leg call
do_send_b_call(Dest, #state{id=Id, session=Session}=State) ->
    #{offer:=Offer} = Session,
    State2 = status(calling, State),
    case handle(nkmedia_session_out, [Id, Dest, Offer], State2) of
        {ringing, Answer, Pid, State3} ->
            State4 = add_link(out, Pid, State3),
            do_ringing(Answer, State4);
        {answer, Answer, Pid, State3} ->
            ?LLOG(info, "session answer", [], State3),
            State4 = add_link(out, Pid, State3),
            do_answered(Answer, State4);
        {async, Pid, State3} ->
            ?LLOG(info, "session delayed", [], State3),
            {noreply, add_link(out, Pid, State3)};
        {hangup, Reason, State3} ->
            ?LLOG(info, "session hangup: ~p", [Reason], State3),
            stop_hangup(Reason, State3)
    end.


%% @private Called at the B-leg
do_ringing(Answer, #state{status=calling}=State) ->
    case Answer of
        #{sdp:=_} ->
            case set_answer(Answer, State) of
                {ok, State2} -> 
                    {noreply, status(ringing, Answer, State2)};
                {error, Error} ->
                    stop_hangup(Error, State)
            end;
        _ ->
            {noreply, status(ringing, Answer, State)}
    end;

do_ringing(_Answer, State) ->
    {noreply, State}.


%% @private Called at the B-leg
do_answered(_Answer, #state{status=Status}=State) when Status/=calling, Status/=ringing ->
    ?LLOG(warning, "received unexpected answer", [], State),
    {noreply, State};

do_answered(#{sdp:=SDP}, #state{session=#{answer:=Old}}=State) ->
    case Old of
        #{sdp:=SDP} ->
            do_ready(State);
        _ ->
            ?LLOG(warning, "ignoring updated SDP!: ~p", [Old], State),
            do_ready(State)
    end;

do_answered(#{sdp:=_}=Answer, State) ->
    case set_answer(Answer, State) of
        {ok, State2} ->
            do_ready(State2);
        {error, Error} ->
            stop_hangup(Error, State)
    end;

do_answered(_Answer, State) ->
    stop_hangup(<<"Missing SDP">>, State).


%% @private Called at the B-leg
set_answer(Answer, #state{type=p2p, session=Session}=State) ->
    Session2 = Session#{answer=>Answer},
    {ok, State#state{has_answer=true, session=Session2}};

set_answer(Answer, #state{type=pbx, ms={fs, _}}=State) ->
    #state{id=SessId, session=Session} = State,
    Mod = get_fs_mod(State),
    case Mod:answer_out(SessId, Answer) of
        ok ->
            Session2 = Session#{answer=>Answer},
            {ok, State#state{has_answer=true, session=Session2}};
        {error, Error} ->
            ?LLOG(warning, "mediaserver error in set_answer: ~p", [Error], State),
            {error, <<"Mediaserver Error">>}
    end;

set_answer(Answer, #state{type=proxy, session=Session}=State) ->
    Session2 = Session#{answer=>Answer},
    {ok, State#state{has_answer=true, session=Session2}}.


%% @private Called at the B-leg
do_ready(#state{type=Type, session=Session}=State) ->
    #{answer:=Answer} = Session,
    State2 = status(ready, #{answer=>Answer}, State),
    case Type of
        p2p ->
            #{session_id:=PeerId} = Session,
            {noreply, status(call, #{peer_id=>PeerId}, State2)};
        proxy ->
            #{session_id:=PeerId} = Session,
            {noreply, status(call, #{peer_id=>PeerId}, State2)};
        _ ->
            {noreply, State2}
    end.




%% ===================================================================
%% Internal - Shared
%% ===================================================================


%% @private
-spec update_config(config(), #state{}) ->
    {ok, #state{}} | {error, term()}.

update_config(Config, #state{session=Session, type=OldType, ms=MS}=State) ->
    try
        Session2 = maps:merge(Session, Config),
        HasOffer = case Session2 of
            #{offer := #{sdp:= _}} -> true;
            _ -> false
        end,
        HasAnswer = case Session2 of
            #{answer := #{sdp:= _}} -> true;
            _ -> false
        end,
        Type = case maps:find(type, Session2) of
            {ok, OldType} ->
                OldType;
            {ok, NewType} when OldType==undefined ->
                NewType;
            {ok, _} -> 
                throw(incompatible_type);
            error ->
                OldType
        end,
        case Type of
            undefined -> ok;
            p2p when MS==undefined -> ok;
            pbx when MS==undefined -> ok;
            pbx when element(1, MS)==fs -> ok;
            proxy when MS==undefined -> ok;
            proxy when element(1, MS)==janus -> ok;
            _ -> throw(incompatible_type)
        end,
        State2 = State#state{
            type = Type,
            session = Session2#{type=>Type},
            has_offer = HasOffer,
            has_answer = HasAnswer
        },
        {ok, State2}
    catch
        throw:Error -> {error, Error}
    end.



% %% @private
% send_to_mcu(_Room, #state{status=Status}=State) 
%         when Status==wait; Status==ringing ->
%     {error, {invalid_status, Status}, State};

% send_to_mcu(Room, #state{id=SessId, ms={fs, FsId}}=State) ->
%     ok = nkmedia_fs_cmd:set_var(FsId, SessId, "park_after_bridge", "true"),
%     Cmd = [<<"conference:">>, Room, <<"@video-mcu-stereo">>],
%     case nkmedia_fs_cmd:transfer_inline(FsId, SessId, Cmd) of
%         ok ->
%             {ok, status(wait, #{wait_op=>{mcu, Room}}, State)};
%         {error, Error} ->
%             {error, Error}
%     end;

% send_to_mcu(_Room, #state{ms=MS}) ->
%     {error, {invalid_backend, MS}}.






% %% @private
% send_to_echo(_Opts, #state{ms={janus, JanusId}, ms_conn_id=Conn}=State) ->
%     #state{session=#{offer:=Offer}=Session} = State,
%     case nkmedia_janus:mirror(JanusId, Conn, #{}) of
%         {ok, _} ->
%             case nkmedia_janus:mirror(JanusId, Conn, Offer) of
%                 {ok, Answer} ->
%                     Session2 = Session#{answer=>Answer},
%                     State2 = State#state{session=Session2},
%                     {noreply, status(ready, #{answer=>Answer}, State2)};
%                 {error, Error} ->
%                     ?LLOG(notice, "janus body: ~p", [Error], State),
%                     stop_hangup(<<"Janus Error">>, State)
%             end;
%         {error, Error} ->
%             ?LLOG(notice, "janus error: ~p", [Error], State),
%             stop_hangup(<<"Janus Error">>, State)
%     end.


% %% @private
% send_to_park(#state{status=Status}=State) 
%         when Status==wait; Status==ringing ->
%     {error, {invalid_status, Status}, State};

% send_to_park(#state{id=SessId, ms={fs, FsId}}) ->
%     ok = nkmedia_fs_cmd:set_var(FsId, SessId, "park_after_bridge", "true"),
%     nkmedia_fs_cmd:park(FsId, SessId);

% send_to_park(#state{ms=MS}) ->
%     {error, {invalid_backend, MS}}.




%% @private
do_pbx_event(parked, #state{status=Status}=State)
        when Status==ready; Status==ringing ->
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




%% @private
stop_hangup(_Reason, #state{status=hangup}=State) ->
    {stop, normal, State};

stop_hangup(Reason, #state{id=SessId, ms=MS, links=Links}=State) ->
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
        Status==wait; Status==calling; Status==ready ->
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


