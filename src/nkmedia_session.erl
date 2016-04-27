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
%     state. You can call get_answer/1 to get the answering SDP.
%     You can send them to an mcu, bridge, etc.
%     If you don't supply a mediaserver, will stay in 'wait' state
%
% - oubound sessions:
%     You MUST supply a 'call_dest' parameter
%     If you supply an sdp_offer, it will be used.
%     If you don't supply an sdp_offer. You MUST supply a backend.
%     The backend will make an sdp_offer, and send the call
%     The session will start in 'ready' state.


-module(nkmedia_session).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start_inbound/2, start_outbound/2, hangup_all/0]).
-export([get_status/1, get_offer/1, get_answer/1]).
-export([hangup/1, hangup/2, to_call/2, to_mcu/2, to_park/1, to_join/2]).
-export([reply_ringing/2, reply_answered/2]).
-export([ms_event/3, call_event/3, get_all/0, find/1]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, config/0, status/0, session/0, event/0]).
-export_type([call_dest/0]).


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Session ~s (~p) "++Txt, 
               [State#state.id, State#state.status | Args])).

-include("nkmedia.hrl").

%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().

-type config() :: 
    #{
        id => id(),
        offer => nkmedia:offer(),
        monitor => pid(), 
        backend => nkmedia:backend(),
        call_dest => call_dest(),              % For outbound sessions 
        wait_timeout => integer(),             % Secs
        ready_timeout => integer(),
        calling_timeout => integer(),          
        ring_timeout => integer(),          
        call_timeout => integer(),
        term() => term()
}.

-type call_dest() :: term().


-type status() ::
    wait | calling | ringing | ready | bridged | mcu | play | hangup.


-type status_info() ::
    #{
        dest => binary(),                       % For calling
        answer => nkmedia:answer(),             % For ringing, ready, p2p
        peer => id(),                           % Bridged, p2p
        room_name => binary(),                  % For mcu
        room_member => binary(),
        hangup_reason => nkmedia_util:hangup_reason()
    }.


-type session() ::
    config () | 
    #{
        srv_id => nkservice:id(),
        type => inbound | outbound,
        status => status(),
        status_info => status_info(),
        answer => nkmedia:answer(),
        mediaserver => mediaserver()
    }.

-type event() ::
    {status, status(), status_info()} | {info, term()}.


-type mediaserver() :: 
    {freeswitch, binary()} | {janus, binary()} | none.


-type ms_event() ::
    parked | {hangup, term()} | {bridge, id()} | {mcu, map()}.


%% ===================================================================
%% Public
%% ===================================================================


%% @doc
%% Starts a new session, starts in 'wait' mode
%% It is recommended to include a 'monitor' option
-spec start_inbound(nkservice:id(), config()) ->
    {ok, id(), pid()}.

start_inbound(Service, #{offer:=#{sdp:=_}}=Config) ->
    start(Service, Config#{type=>inbound}).


%% @doc
%% Starts a new session, starts in 'wait' mode
%% It is recommended to include a 'monitor' option
-spec start_outbound(nkservice:id(), config()) ->
    {ok, id(), pid()}.

start_outbound(Service, #{call_dest:=_}=Config) ->
    start(Service, Config#{type=>outbound}).


%% @private
-spec start(nkservice:id(), config()) ->
    {ok, id(), pid()}.

start(Service, Config) ->
    case nkservice_srv:get_srv_id(Service) of
        {ok, SrvId} ->
            {SessId, Config2} = nkmedia_util:add_uuid(Config#{srv_id=>SrvId}),
            case get_mediaserver(Config2) of
                {ok, Config3} ->
                    {ok, SessPid} = gen_server:start(?MODULE, [Config3], []),
                    {ok, SessId, SessPid};
                {error, Error} ->
                    {error, Error}
            end;
        not_found ->
            {error, service_not_found}
    end.


%% @doc
-spec get_offer(id()) ->
    {ok, nkmedia:offer()|undefined} | {error, term()}.

get_offer(SessId) ->
    do_call(SessId, get_offer).


%% @doc
-spec get_answer(id()) ->
    {ok, nkmedia:answer()|undefined} | {error, term()}.

get_answer(SessId) ->
    do_call(SessId, get_answer).


%% @doc
-spec get_status(id()) ->
    {ok, status(), status_info(), integer()}.

get_status(SessId) ->
    do_call(SessId, get_status).


%% @private
hangup_all() ->
    lists:foreach(fun({SessId, _Pid}) -> hangup(SessId) end, get_all()).


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


%% @doc Starts a new call inside the session
-spec to_call(id(), binary()) ->
    ok | {error, term()}.

to_call(SessId, Dest) ->
    do_cast(SessId, {to_call, Dest}).


%% @private
-spec to_mcu(id(), binary()) ->
    ok | {error, term()}.

to_mcu(SessId, Room) ->
    do_call(SessId, {to_mcu, Room}).


%% @private
-spec to_park(id()) ->
    ok | {error, term()}.

to_park(SessId) ->
    do_call(SessId, to_park).


%% @private
-spec to_join(id(), id()) ->
    ok | {error, term()}.

to_join(SessId, OtherSessId) ->
    do_call(SessId, {to_join, OtherSessId}).


%% @private Called when an outbound process delayed the response
-spec reply_ringing(id(), nkmedia:answer()) ->
    ok | {error, term()}.

reply_ringing(SessId, Data) ->
    do_cast(SessId, {reply_ringing, Data}).


%% @private Called when an outbound process delayed the response
-spec reply_answered(id(), nkmedia:answer()) ->
    ok | {error, term()}.

reply_answered(SessId, Data) ->
    do_cast(SessId, {reply_answered, Data}).


%% @private
-spec get_all() ->
    [{id(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).






%% ===================================================================
%% Internal
%% ===================================================================

%% @private Called from nkmedia_fs_engine and nkmedia_fs_verto

-spec ms_event(id(), mediaserver(), ms_event()) ->
    ok.

ms_event(SessId, MS, Event) ->
    case do_cast(SessId, {ms_event, MS, Event}) of
        ok -> 
            ok;
        {error, _} when Event==stop ->
            ok;
        {error, _} -> 
            lager:warning("NkMEDIA Session: event ~p for unknown sesison ~s", 
                          [Event, SessId])
    end.


%% @private
call_event(SessPid, CallId, Event) ->
    do_cast(SessPid, {call_event, CallId, Event}).



% ===================================================================
%% gen_server behaviour
%% ===================================================================


-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    session :: session(),
    status :: status(),
    ms :: mediaserver(),
    call :: {nkmedia_call:id(), pid(), reference()},
    timer :: reference()
}).



%% @private
-spec init(term()) ->
    {ok, tuple()}.

init([#{id:=Id, type:=Type, srv_id:=SrvId, mediaserver:=MS}=Session]) ->
    true = nklib_proc:reg({?MODULE, Id}),
    nklib_proc:reg(?MODULE, Id),
    State = #state{
        id = Id, 
        srv_id = SrvId, 
        status = init,
        session = Session,
        ms = MS
    },
    case Session of
        #{monitor:=Pid} -> monitor(process, Pid);
        _ -> ok
    end,
    lager:info("NkMEDIA Session ~s starting (~p, ~p) (~p)", 
                [Id, Type, self(), MS]),
    gen_server:cast(self(), {start, Type}),
    {ok, State2} = handle(nkmedia_session_init, [Id], State),
    {ok, State2}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(get_status, _From, State) ->
    #state{status=Status, timer=Timer, session=Session} = State,
    #{status_info:=Info} = Session,
    {reply, {ok, Status, Info, erlang:read_timer(Timer) div 1000}, State};

handle_call(get_offer, _From, #state{session=Session}=State) ->
    {reply, {ok, maps:get(offer, Session, undefined)}, State};

handle_call(get_answer, _From, #state{session=Session}=State) ->
    {reply, {ok, maps:get(answer, Session, undefined)}, State};

handle_call(to_park, _From, #state{ms={freeswitch, _}}=State) ->
    Reply = send_to_park(State),
    {reply, Reply, State};

handle_call({to_join, SessIdB}, _From, #state{ms={freeswitch, _}}=State) ->
    Reply = send_to_bridge(SessIdB, State),
    {reply, Reply, State};

handle_call({to_mcu, Room}, _From, State) ->
    Reply = send_to_mcu(Room, State),
    {reply, Reply, State};

handle_call(Msg, From, State) -> 
    handle(nkmedia_session_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({start, inbound}, #state{ms=none}=State) ->
    {noreply, status(wait, State)};

handle_cast({start, inbound}, State) ->
    case send_to_ms(State) of
        {ok, State2} ->
            {noreply, State2};
        {error, Error, State2} ->
            ?LLOG(warning, "could not place incoming call in ms: ~p", [Error], State),
            {stop, normal, State2}
    end;

handle_cast({start, outbound}, #state{session=#{offer:=_Offer}}=State) ->
    send_call(State);

handle_cast({start, outbound}, State) ->
    case get_from_ms(State) of
        {ok, State2} ->
            send_call(State2);
        {error, Error, State2} ->
            ?LLOG(warning, "could not place outcoming call in ms: ~p", [Error], State),
            {stop, normal, State2}
    end;

handle_cast({to_call, Dest}, #state{id=Id, session=Session, ms=MS}=State) ->
    Config1 = maps:remove(id, Session),
    Config2 = case MS of
        none -> Config1;
        _ -> maps:remove(offer, Config1)
    end,
    Config3 = Config2#{session_id=>Id, session_pid=>self()}, 
    {ok, CallId, CallPid} = nkmedia_call:start(Dest, Config3),
    State2 = State#state{call={CallId, CallPid, monitor(process, CallPid)}},
    {noreply, status(calling, #{dest=>Dest}, State2)};

handle_cast({hangup, Reason}, State) ->
    ?LLOG(info, "external hangup: ~p", [Reason], State),
    stop_hangup(Reason, State);

handle_cast({info, Info}, State) ->
    {noreply, event({info, Info}, State)};

handle_cast({call_event, CallId, Event}, #state{call={CallId, _, _}}=State) ->
    do_call_event(Event, State);

handle_cast({call_event, CallId, Event}, State) ->
    ?LLOG(warning, "received unexpected call event from ~s (~p)", 
          [CallId, Event], State),
    {noreply, State};

handle_cast({ms_event, MS, stop}, #state{ms=MS}=State) ->
    ?LLOG(notice, "received status: stop", [], State),
    {stop, normal, State};

handle_cast({ms_event, MS, Event}, #state{ms=MS}=State) ->
    ?LLOG(notice, "received event: ~p", [Event], State),
    do_ms_event(Event, State);

handle_cast({ms_event, StatusMS, _Status}, #state{ms=MS}=State) ->
    ?LLOG(warning, "received status from ms ~p (current is ~p)", [StatusMS, MS], State),
    {noreply, State};

handle_cast({reply_ringing, Answer}, State) ->
    do_ringing(Answer, State);

handle_cast({reply_answered, Answer}, State) ->
    do_answer(Answer, State);

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

handle_info({'DOWN', _Ref, process, Pid, Reason}, 
            #state{session=#{monitor:=Pid}}=State) ->
    ?LLOG(warning, "monitor down!: ~p", [Reason], State),
    %% Should enter into 'recovery' mode
    {stop, normal, State};

handle_info({'DOWN', Ref, process, _Pid, Reason}, 
            #state{call={CallId, _, Ref}}=State) ->
    ?LLOG(warning, "call ~s down: ~p", [CallId, Reason], State),
    %% Should enter into 'recovery' mode
    {stop, normal, State};

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
    ?LLOG(info, "stopped (~p)", [Reason], State),
    catch handle(nkmedia_session_terminate, [Reason], State),
    _ = stop_hangup(<<"Session Stop">>, State).


% ===================================================================
%% Internal
%% ===================================================================


%% @private
get_mediaserver(#{srv_id:=SrvId, backend:=Backend}=Config) ->
    case SrvId:nkmedia_session_get_mediaserver(Backend) of
        {ok, Mediaserver} ->
            {ok, Config#{mediaserver=>Mediaserver}};
        {error, Error} ->
            {error, Error}
    end;

get_mediaserver(Config) ->
    {ok, Config#{mediaserver=>none}}.
    

%% @private
send_to_ms(#state{ms={freeswitch, FsId}}=State) ->
    #state{id=SessId,session=#{offer:=Offer}=Session} = State,
    case nkmedia_fs_verto:start_in(SessId, FsId, Offer) of
        {ok, Answer} ->
            %% TODO Send and receive pings
            Session2 = Session#{answer:=Answer},
            {ok, status(ready, Answer, State#state{session=Session2})};
        {error, Error} ->
            {error, {backend_start_error, Error}, State}
    end.


%% @private
get_from_ms(#state{ms={freeswitch, FsId}}=State) ->
    #state{id=SessId, session=Session} = State,
    Mod = get_fs_mod(State),
    case Mod:start_out(SessId, FsId, #{}) of
        {ok, Offer} ->
            % io:format("SDP: ~s\n", [SDP]),
            %% TODO Send and receive pings
            Session2 = Session#{offer:=Offer},
            {ok, State#state{session=Session2}};
        {error, Error} ->
            {error, {backend_start_error, Error}, State}
    end.


%% @private
send_call(#state{id=Id, session=Session}=State) ->
    #{call_dest:=Dest, offer:=Offer} = Session,
    State2 = status(calling, State),
    case handle(nkmedia_session_out, [Id, Dest, Offer], State) of
        {ringing, Answer, State2} ->
            do_ringing(Answer, State2);
        {answer, Answer, State2} ->
            ?LLOG(info, "session answer", [], State),
            do_answer(Answer, State2);
        {ok, State2} ->
            ?LLOG(info, "session delayed", [], State),
            {noreply, State2};
        {hangup, Reason, State2} ->
            ?LLOG(info, "session hangup: ~p", [Reason], State),
            stop_hangup(Reason, State2)
    end.


%% @private
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


%% @private
do_answer(_Answer, #state{status=Status}=State) when Status/=calling, Status/=ringing ->
    ?LLOG(warning, "received unexpected answer", [], State),
    {noreply, State};

do_answer(#{sdp:=SDP}=New, #state{session=#{answer:=Answer}}=State) ->
    case Answer of
        #{sdp:=SDP} ->
            {noreply, status(ready, #{answer=>New}, State)};
        _ ->
            ?LLOG(warning, "ignoring updated SDP!", [], State),
            {noreply, status(ready, #{answer=>Answer}, State)}
    end;

do_answer(#{sdp:=_}=Answer, State) ->
    case set_answer(Answer, State) of
        {ok, State2} ->
            {noreply, status(ready, Answer, State2)};
        {error, Error} ->
            stop_hangup(Error, State)
    end;

do_answer(_Answer, State) ->
    stop_hangup(<<"Missing SDP">>, State).


%% @private
set_answer(Answer, #state{ms=none, session=Session}=State) ->
    Session2 = Session#{answer:=Answer},
    {ok, State#state{session=Session2}};

set_answer(Answer, #state{ms={freeswitch, _}}=State) ->
    #state{id=SessId, session=Session} = State,
    Mod = get_fs_mod(State),
    case Mod:answer_out(SessId, Answer) of
        ok ->
            Session2 = Session#{answer=>Answer},
            {ok, State#state{session=Session2}};
        {error, Error} ->
            ?LLOG(warning, "mediaserver error in set_answer: ~p", [Error], State),
            {error, <<"Mediaserver Error">>}
    end.


%% @private
send_to_mcu(_Room, #state{status=Status}=State) 
        when Status==wait; Status==ringing ->
    {error, {invalid_status, Status}, State};

send_to_mcu(Room, #state{id=SessId, ms={freeswitch, FsId}}) ->
    ok = nkmedia_fs_cmd:set_var(FsId, SessId, "park_after_bridge", "true"),
    Cmd = [<<"conference:">>, Room, <<"@video-mcu-stereo">>],
    nkmedia_fs_cmd:transfer_inline(FsId, SessId, Cmd);

send_to_mcu(_Room, #state{ms=MS}) ->
    {error, {invalid_backend, MS}}.


%% @private
send_to_bridge(_SessIdB, #state{status=Status}=State) 
        when Status==wait; Status==ringing ->
    {error, {invalid_status, Status}, State};

send_to_bridge(SessIdB, #state{id=SessIdA, ms={freeswitch, FsId}}) ->
    case nkmedia_fs_cmd:set_var(FsId, SessIdA, "park_after_bridge", "true") of
        ok ->
            nkmedia_fs_cmd:bridge(FsId, SessIdA, SessIdB);
        {error, Error} ->
            {error, Error}
    end;

send_to_bridge(_SessIdB, #state{ms=MS}) ->
    {error, {invalid_backend, MS}}.


%% @private
send_to_park(#state{status=Status}=State) 
        when Status==wait; Status==ringing ->
    {error, {invalid_status, Status}, State};

send_to_park(#state{id=SessId, ms={freeswitch, FsId}}) ->
    ok = nkmedia_fs_cmd:set_var(FsId, SessId, "park_after_bridge", "true"),
    nkmedia_fs_cmd:park(FsId, SessId);

send_to_park(#state{ms=MS}) ->
    {error, {invalid_backend, MS}}.


%% @private
do_ms_event(parked, #state{status=ready}=State) ->
    {noreply, State};

do_ms_event(parked, #state{status=Status}=State) ->
    ?LLOG(notice, "received parked in '~p'", [Status], State),
    {noreply, status(ready, State)};

do_ms_event({hangup, Reason}, State) ->
    stop_hangup(Reason, State);

do_ms_event({bridge, Remote}, State) ->
    {noreply, status(bridged, #{peer=>Remote}, State)};

do_ms_event({mcu, McuInfo}, State) ->
    {noreply, status(mcu, McuInfo, State)};

do_ms_event(Event, State) ->
    ?LLOG(warning, "unexpected ms event: ~p", [Event], State),
    {noreply, State}.


%% @private
do_call_event({status, calling, _}, #state{status=calling}=State) ->
    {noreply, State};

do_call_event({status, ringing, Data}, #state{status=calling}=State) ->
    {noreply, status(ringing, Data, State)};

do_call_event({status, ringing, _Data}, #state{status=ringig}=State) ->
    {noreply, State};

do_call_event({status, ready, Data}, #state{status=Status}=State)
        when Status==calling; Status==ringing ->
    {noreply, status(ready, Data, State)};

do_call_event({status, hangup, #{hangup_reason:=Reason}}, #state{status=Status}=State)
        when Status==calling; Status==ringing; Status==p2p ->
    stop_hangup(Reason, State);

do_call_event(Event, State) ->
    ?LLOG(warning, "unexpected call event: ~p", [Event], State),
    {noreply, State}.


%% @private
stop_hangup(_Reason, #state{status=hangup}=State) ->
    {stop, normal, State};

stop_hangup(Reason, #state{id=SessId, ms=MS, call=Call}=State) ->
    case Call of
        {_CallId, CallPid, _} ->
            nkmedia_call:hangup(CallPid, <<"Caller Stopped">>);
        undefined ->
            ok
    end,
    case MS of
        {freeswitch, FsId} ->
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
    State2 = restart_timer(State#state{status=NewStatus}),
    State3 = State2#state{session=Session#{status=>NewStatus, status_info=>Info}},
    ?LLOG(info, "status changed to ~p", [NewStatus], State3),
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
    Time = case Status of
        wait -> maps:get(wait_timeout, Session, ?DEF_WAIT_TIMEOUT);
        ready -> maps:get(ready_timeout, Session, ?DEF_READY_TIMEOUT);
        calling -> maps:get(calling_timeout, Session, ?DEF_RING_TIMEOUT);
        ringing -> maps:get(ring_timeout, Session, ?DEF_RING_TIMEOUT);
        _ -> maps:get(call_timeout, Session, ?DEF_CALL_TIMEOUT)
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






