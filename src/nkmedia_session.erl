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
%     You MUST supply an sdp_offer. Will start in 'wait' state.
%     If you supply a backend, it wil be placed there, and enter the 'ready'
%     state. You can call get_answer/1 to get the answering SDP.
%     You can send them to an mcu, bridge, etc.
%
% - oubound sessions:
%     You MUST supply a 'call_to' parameter
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
-export([ringing/2, answered/2]).
-export([event/3, call_event/3, get_all/0, find/1]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, config/0, status/0, session/0, event/0, notify/0]).
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
        notify => nkmedia:notify(),         % If supplied, call be monitorized
        backend => nkmedia:backend(),
        call_dest => call_dest(),
        calling_timeout => integer(),          % Secs
        ring_timeout => integer(),          
        ready_timeout => integer(),
        call_timeout => integer()
}.

-type call_dest() :: term().


%% Common: ready | mcu | bridged | play | hangup
%% Outcoming: calling | ringing

-type status() ::
    calling | ringing | ready | mcu | bridged | play | hangup | p2p.

-type status_info() ::
    #{
        peer => id(),

        room_name => binary(),
        room_member => binary(),

        hangup_code => nkmedia_util:q850(),
        hangup_reson => binary()
    }.


-type session() ::
    #{
        srv_id => nkservice:id(),
        type => inbound | outbound,
        status => status(),
        status_info => status_info(),
        answer => nkmedia:answer(),
        mediaserver => mediaserver(),
        out_notify => nkmedia:notify()
    }.

-type event() ::
    {status, status(), status_info()} | {info, term()} |
    {session_linked, id()}.


-type notify() :: {Tag::term(), pid()} | {Tag::term(), pid(), term()}.


-type mediaserver() :: 
    {freeswitch, binary()} | {janus, binary()} | none.


-type ext_event() ::
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


%% @private Inform to the session that the call is ringing, maybe with early media
-spec ringing(id(), nkmedia:answer()) ->
    ok | {error, term()}.

ringing(SessId, Answer) ->
    do_cast(SessId, {ringing, Answer}).


%% @private Inform to the session that the call is answered
-spec answered(id(), nkmedia:answer()) ->
    ok | {error, term()}.

answered(SessId, Answer) ->
    do_call(SessId, {answered, Answer}).


%% @private
-spec get_all() ->
    [{id(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).






%% ===================================================================
%% Internal
%% ===================================================================

%% @private Called from nkmedia_fs_engine and nkmedia_fs_verto

-spec event(id(), mediaserver(), ext_event()) ->
    ok.

event(SessId, MS, Event) ->
    case do_cast(SessId, {ext_event, MS, Event}) of
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
    in_notify_mon :: reference(),  
    out_notify_mon :: reference(),  
    call :: {nkmedia_call:id(), pid(), reference()},
    timer :: reference()
}).



%% @private
-spec init(term()) ->
    {ok, tuple()}.

init([#{id:=Id, type:=Type, srv_id:=SrvId, mediaserver:=MS}=Session]) ->
    true = nklib_proc:reg({?MODULE, Id}),
    nklib_proc:reg(?MODULE, Id),
    % InNotify = maps:get(notify, Session, undefined),
    State = #state{
        id = Id, 
        srv_id = SrvId, 
        status = init,
        session = Session,
        ms = MS
        % in_notify_mon = nkmedia_util:notify_mon(InNotify)
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

handle_call({answered, Answer}, _From, State) ->
    case do_answer(Answer, State) of
        {ok, State2} ->
            ?LLOG(notice, "call answered", [], State),
            {reply, ok, State2};
        {error, Error, State2} ->
            ?LLOG(notice, "call answer failed: ~p", [Error], State),
            {stop, normal, {error, call_failed}, State2}
    end;

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
    case send_call(status(calling, State)) of
        {ok, State2} ->
            {noreply, State2};
        {error, Error} ->
            {error, Error}
    end;

handle_cast({start, outbound}, State) ->
    case get_from_ms(State) of
        {ok, State2} ->
            case send_call(status(calling, State2)) of
                {ok, State3} ->
                    {noreply, State3};
                {error, Error} ->
                    {error, Error}
            end;
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
    Config3 = Config2#{session_id=>Id, session_pid=>self(), call_dest=>Dest}, 
    {ok, CallId, CallPid} = nkmedia_call:start(Config3),
    State2 = State#state{call={CallId, CallPid, monitor(process, CallPid)}},
    {noreply, status(calling, State2)};

handle_cast({ringing, Answer}, State) ->
    case do_ringing(Answer, State) of
        {ok, State2} ->
            {noreply, State2};
        {error, Error} ->
            ?LLOG(warning, "error processing ringing: ", [Error], State),
            {stop, normal, State}
    end;

handle_cast({hangup, Reason}, State) ->
    ?LLOG(notice, "ordered hangup: ~p", [Reason], State),
    process_event({hangup, Reason}, State);

handle_cast({info, Info}, State) ->
    {noreply, notify({info, Info}, State)};

handle_cast({call_event, CallId, Event}, #state{call={CallId, _, _}}=State) ->
    {noreply, call_event(Event, State)};

handle_cast({ext_event, MS, stop}, #state{ms=MS}=State) ->
    ?LLOG(notice, "received status: stop", [], State),
    {stop, normal, State};

handle_cast({ext_event, MS, Event}, #state{ms=MS}=State) ->
    ?LLOG(notice, "received event: ~p", [Event], State),
    process_event(Event, State);

handle_cast({ext_event, StatusMS, _Status}, #state{ms=MS}=State) ->
    ?LLOG(warning, "received status from ms ~p (current is ~p)", [StatusMS, MS], State),
    {noreply, State};

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
    hangup(self(), 607),
    {noreply, State};

handle_info({'DOWN', Ref, process, _Pid, Reason}, #state{call={CallId, _, Ref}}=State) ->
    ?LLOG(warning, "call ~s down: ~p", [CallId, Reason], State),
    %% Should enter into 'recovery' mode
    {stop, normal, State};

handle_info({'DOWN', Ref, process, _Pid, Reason}, #state{in_notify_mon=Ref}=State) ->
    ?LLOG(warning, "caller process stopped: ~p", [Reason], State),
    %% Should enter into 'recovery' mode
    {stop, normal, State};

handle_info({'DOWN', Ref, process, _Pid, Reason}, #state{out_notify_mon=Ref}=State) ->
    ?LLOG(warning, "outbound call process stopped: ~p", [Reason], State),
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
    catch handle(nkmedia_session_terminate, [Reason], State),
    State2 = do_hangup("Session Stop", State), % Probably it is already
    ?LLOG(info, "stopped (~p)", [Reason], State2).


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
            {ok, status(ready, State#state{session=Session2})};
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
send_call(#state{id=Id, status=calling, session=Session}=State) ->
    #{call_dest:=Dest, offer:=Offer} = Session,
    case handle(nkmedia_session_out, [Id, Dest, Offer], State) of
        {ringing, Answer, State2} ->
            ?LLOG(info, "session ringing", [], State),
            do_ringing(Answer, status(ringing, State2));
        {answer, Answer, State2} ->
            ?LLOG(info, "session answer", [], State),
            do_answer(Answer, status(ringing, State2));
        {ok, State2} ->
            ?LLOG(info, "session delayed", [], State),
            {ok, State2};
        {hangup, Reason, State2} ->
            ?LLOG(info, "session hangup: ~p", [Reason], State),
            hangup(self(), Reason),
            {ok, State2}
    end.


%% @private
do_ringing(_Answer, #state{status=Status}=State) 
        when Status/=calling, Status/=ringing ->
    {error, {invalid_status, Status}, State};

do_ringing(Answer, #state{session=Session}=State) ->
    case {maps:is_key(sdp, Answer), maps:is_key(answer, Session)} of
        {true, false} ->
            case set_answer(Answer, State) of
                {ok, State2} -> 
                    {ok, status(ringing, State2)};
                {p2p, State2} -> 
                    {ok, status(ringing, State2)};
                {error, Error} ->
                    {error, Error, State}
            end;
        {true, true} ->
            check_answer_sdp(Answer, Session),
            {ok, status(ringing, State)};
        {false, _} ->
            {ok, status(ringing, State)}
    end.


%% @private
do_answer(_Answer, #state{status=Status}=State) when Status/=calling, Status/=ringing ->
    {error, {invalid_status, Status}, State};

do_answer(Answer, #state{session=Session}=State) ->
    case {maps:is_key(sdp, Answer), maps:is_key(answer, Session)} of
        {true, false} ->
            case set_answer(Answer, State) of
                {ok, State2} ->
                    {ok, status(ready, State2)};
                {p2p, State2} ->
                    {ok, status(p2p, State2)};
                {error, Error, State2} ->
                    {error, Error, State2}
            end;
        {true, true} ->
            check_answer_sdp(Answer, Session),
            {ok, status(ready, State)};
        {false, true} ->
            {ok, status(ready, State)};
        {false, false} ->
            {error, missing_sdp, State}
    end.


%% @private
set_answer(Answer, #state{ms=none, session=Session}=State) ->
    {p2p, State#state{session=Session#{answer=>Answer}}};

set_answer(Answer, #state{ms={freeswitch, _}}=State) ->
    #state{id=SessId, session=Session} = State,
    Mod = get_fs_mod(State),
    case Mod:answer_out(SessId, Answer) of
        ok ->
            Session2 = Session#{answer:=Answer},
            {ok, State#state{session=Session2}};
        {error, Error} ->
            {error, Error, State}
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
process_event(parked, #state{status=ready}=State) ->
    {noreply, State};

process_event(parked, #state{status=Status}=State) ->
    ?LLOG(notice, "received parked in '~p'", [Status], State),
    {noreply, status(ready, State)};

process_event({hangup, Reason}, State) ->
    {stop, normal, do_hangup(Reason, State)};

process_event({bridge, Remote}, State) ->
    {noreply, status(bridged, #{peer=>Remote}, State)};

process_event({mcu, McuInfo}, State) ->
    {noreply, status(mcu, McuInfo, State)}.


%% @private
call_event({status, calling, _}, #state{status=calling}=State) ->
    State;

call_event({status, ringing, _}, #state{status=calling}=State) ->
    status(ringing, State);

call_event({status, p2p, #{peer:=SessId}}, #state{status=Status}=State)
        when Status==calling; Status==ringing ->
    status(p2p, #{peer=>SessId}, State);

call_event(Event, State) ->
    ?LLOG(warning, "call event: ~p", [Event], State),
    State.







%% @private
do_hangup(_Reason, #state{status=hangup}=State) ->
    State;

do_hangup(Reason, #state{id=SessId, ms=MS, call=Call}=State) ->
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
    Info = #{q850=>nkmedia_util:get_q850(Reason)},
    status(hangup, Info, State).


%% @private
status(Status, State) ->
    status(Status, #{}, State).


%% @private
status(Status, _Info, #state{status=Status}=State) ->
    restart_timer(State);

%% @private
status(NewStatus, Info, #state{status=OldStatus, session=Session}=State) ->
    State2 = restart_timer(State#state{status=NewStatus}),
    State3 = State2#state{session=Session#{status=>NewStatus, status_info=>Info}},
    ?LLOG(info, "status ~p -> ~p", [OldStatus, NewStatus], State3),
    notify({status, NewStatus, Info}, State3).


%% @private
notify(Event, #state{id=Id}=State) ->
    {ok, State2} = handle(nkmedia_session_notify, [Id, Event], State),
    State2.


%% @private
restart_timer(#state{status=hangup, timer=Timer}=State) ->
    nklib_util:cancel_timer(Timer),
    State;

restart_timer(#state{status=Status, timer=Timer, session=Session}=State) ->
    nklib_util:cancel_timer(Timer),
    Time = case Status of
        wait -> maps:get(ait_timeout, Session, ?DEF_WAIT_TIMEOUT);
        calling -> maps:get(calling_timeout, Session, ?DEF_RING_TIMEOUT);
        ringing -> maps:get(ring_timeout, Session, ?DEF_RING_TIMEOUT);
        ready -> maps:get(ready_timeout, Session, ?DEF_READY_TIMEOUT);
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
check_answer_sdp(#{sdp:=SDP1}, #state{session=#{answer:=#{sdp:=SDP2}}}=State) 
        when SDP1 /= SDP2 ->
    ?LLOG(warning, "ignoring updated SDP!", [], State);
check_answer_sdp(_Answer, _State) ->
    ok. 



%
%% @private
get_fs_mod(#state{session=Session}) ->
    case maps:get(sdp_type, Session, webrtc) of
        webrtc -> nkmedia_fs_verto;
        sip -> nkmedia_fs_sip
    end.






