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

-module(nkmedia_session).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start/2, stop/1, stop_all/0]).
-export([to_mediaserver/1, from_mediaserver/2, from_mediaserver_answer/3]).
-export([hangup/2, to_call/3, to_mcu/2, to_park/1, to_join/2]).
-export([get_mediaserver/1]).
-export([event/3, get_all/0, find/1]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, config/0, status/0, session/0, event/0, mediaserver/0]).


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Session ~s (~p) "++Txt, 
               [State#state.id, State#state.status | Args])).

-define(DEF_WAIT_TIMEOUT, 30).
-define(DEF_PARK_TIMEOUT, 3000).
-define(DEF_RINGING_TIMEOUT, 30).
-define(DEF_CALL_TIMEOUT, 3000).


%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().

-type config() :: 
    #{
        srv_id => nkservice:id(),
        monitor => pid(),
        mediaserver => freeswitch | janus,
        sdp_a => binary(),
        sdp_b => binary(),
        verto_dialog => map(),
        wait_timeout => integer()                   % Secs
    }.


-type status() ::
    init | wait | parked | ringing | call | hangup | stop.


-type session() ::
    config() |
    #{
        id => id(),                     
        status => status(),
        peer => {sessid, id()} | room,
        room_name => binary(),
        room_member => binary(),
        hangup_code => integer()

    }.

-type event() ::
    {status, status()}.


-type mediaserver() :: 
    {freeswitch, binary()}.


-type call_dest() ::
    {room, binary()} | {sip, Url::binary(), Opts::list()}.

-type ext_event() ::
    parked | {hangup, integer()} | {bridge, id()} | {mcu, map()}.


%% ===================================================================
%% Public
%% ===================================================================



%% @doc
%% Starts a new session, starts in 'wait' mode
%% It is recommended to include a 'monitor' option
-spec start(nkservice:id(), config()) ->
    {ok, id(), pid()}.

start(Service, Config) ->
    case nkservice_srv:get_srv_id(Service) of
        {ok, SrvId} ->
            Config2 = Config#{srv_id=>SrvId},
            Config3 = case Config of
                #{id:=SessId} when is_binary(SessId) -> Config2;
                _ -> Config2#{id=>SessId=nklib_util:uuid_4122()}
            end,
            {ok, SessPid} = gen_server:start(?MODULE, [Config3], []),
            {ok, SessId, SessPid};
        not_found ->
            {error, service_not_found}
    end.



%% @private
stop(SessId) ->
    do_cast(SessId, stop).


%% @private
stop_all() ->
    lists:foreach(fun({SessId, _Pid}) -> stop(SessId) end, get_all()).


%% @doc
-spec hangup(id(), integer()) ->
    ok | {error, term()}.

hangup(SessId, Code) ->
    do_cast(SessId, {hangup, Code}).


%% @private
-spec to_mediaserver(id()) ->
    {ok, SDP::binary()} | {error, term()}.

to_mediaserver(SessId) ->
    do_call(SessId, to_mediaserver).


%% @private
-spec from_mediaserver(id(), #{sdp_type=>sip | webrtc}) ->
    {ok, SDP::binary()} | {error, term()}.

from_mediaserver(SessId, Opts) ->
    do_call(SessId, {from_mediaserver, Opts}).


%% @private
-spec from_mediaserver_answer(id(), SDP::binary(), Opts::map()) ->
    ok | {error, term()}.

from_mediaserver_answer(SessId, SDP, Opts) ->
    do_call(SessId, {from_mediaserver_answer, SDP, Opts}).


%% @private
-spec to_call(id(), call_dest(), map()) ->
    {ok, id()} | {error, term()}.

to_call(SessId, CallDest, Opts) ->
    do_call(SessId, {to_call, CallDest, Opts}, 30000).


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


%% @doc
-spec get_mediaserver(id()) ->
    {ok, mediaserver()} | {error, term()}.

get_mediaserver(SessId) ->
    do_call(SessId, get_mediaserver).


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


% ===================================================================
%% gen_server behaviour
%% ===================================================================


-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    user_mon :: reference(),
    status :: status(),
    session :: session(),
    timer :: reference(),
    ms :: mediaserver(),
    calls = [] :: [{id(), pid(), reference()}],
    user_reply :: {pid(), term()}
}).



%% @private
-spec init(term()) ->
    {ok, tuple()}.

init([#{id:=Id}=Config]) ->
    SrvId = maps:get(srv_id, Config, nkmedia_callbacks),
    Default = #{sdp_a=>undefined, sdp_b=>undefined},
    Session = maps:merge(Default, Config),
    Mon = case maps:find(monitor, Session) of
        {ok, Pid} -> monitor(process, Pid);
        error -> undefined
    end,
    State = #state{
        id = Id, 
        srv_id = SrvId, 
        user_mon = Mon,
        status = init,
        session = Session
    },
    true = nklib_proc:reg({?MODULE, Id}),
    nklib_proc:put(?MODULE, Id),
    lager:info("NkMEDIA Session ~s starting (~p)", [Id, self()]),
    {ok, State2} = handle(nkmedia_session_init, [Id], State),
    {ok, status(wait, State2)}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(to_mediaserver, _From, State) ->
    case send_to_ms(State) of
        {ok, #state{session=#{sdp_b:=SDP}}=State2} ->
            {reply, {ok, SDP}, State2};
        {error, Error, State2} ->
            {reply, {error, Error}, State2}
    end;

handle_call({from_mediaserver, Opts}, _From, State) ->
    case get_from_ms(Opts, State) of
        {ok, #state{session=#{sdp_b:=SDP}}=State2} ->
            {reply, {ok, SDP}, State2};
        {error, Error, State2} ->
            {reply, {error, Error}, State2}
    end;

handle_call({from_mediaserver_answer, SDP, Opts}, _From, State) ->
    case answer_ms(SDP, Opts, State) of
        {ok, State2} ->
            {reply, ok, State2};
        {error, Error, State2} ->
            {reply, {error, Error}, State2}
    end;

handle_call({to_call, Dest, Opts}, From, State) ->
    case send_to_call(Dest, Opts, State) of
        {ok, State2} ->
            {reply, ok, State2};
        {async, State2} ->
            {noreply, State2#state{user_reply=From}};
        {error, Error, State2} ->
            {reply, {error, Error}, State2}
    end;

handle_call(to_park, _From, #state{ms={freeswitch, _}}=State) ->
    Reply = send_to_park(State),
    {reply, Reply, State};

handle_call({to_join, SessIdB}, _From, #state{ms={freeswitch, FsId}}=State) ->
    Reply = case get_mediaserver(SessIdB) of
        {ok, {freeswitch, FsId}} ->
            send_to_bridge(SessIdB, State);
        _ ->
            {error, invalid_mediaserver}
    end,
    {reply, Reply, State};

handle_call({to_mcu, Room}, _From, #state{ms={freeswitch, _}}=State) ->
    Reply = send_to_mcu(Room, State),
    {reply, Reply, State};

handle_call({to_mcu, _}, _From, State) ->
    {reply, {error, not_at_mediaserver}, State};

handle_call(get_mediaserver, _From, #state{ms=Mediaserver}=State) ->
    {reply, {ok, Mediaserver}, State};

handle_call(Msg, From, State) -> 
    case handle(nkmedia_session_handle_call, [Msg, From], State) of
        {continue, [Msg2, _From2, State2]} ->
            lager:error("Module ~p received unexpected call ~p", [Msg2]),
            {noreply, State2};
        Other ->
            Other
    end.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({hangup, Code}, State) ->
    process_event({hangup, Code}, State),
    {noreply, State};

handle_cast({info, Info}, State) ->
    {noreply, event({user_info, Info}, State)};

handle_cast({ext_event, MS, stop}, #state{ms=MS}=State) ->
    ?LLOG(notice, "received status: stop", [], State),
    {stop, normal, State};

handle_cast({ext_event, MS, Event}, #state{ms=MS}=State) ->
    ?LLOG(notice, "received event: ~p", [Event], State),
    {noreply, process_event(Event, State)};

handle_cast({ext_event, StatusMS, _Status}, #state{ms=MS}=State) ->
    ?LLOG(warning, "received status from ms ~p (current is ~p)", [StatusMS, MS], State),
    {noreply, State};

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(Msg, State) -> 
    case handle(nkmedia_session_handle_cast, [Msg], State) of
        {continue, [Msg2, State2]} ->
            lager:error("Module ~p received unexpected casr ~p", [Msg2]),
            {noreply, State2};
        Other ->
            Other
    end.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({timeout, _, status_timeout}, State) ->
    ?LLOG(warning, "status timeout", [], State),
    {stop, normal, State};

handle_info({'DOWN', Ref, process, _Pid, Reason}, #state{user_mon=Ref}=State) ->
    ?LLOG(info, "caller process stopped: ~p", [Reason], State),
    {stop, Reason, State};

handle_info({'DOWN', Ref, process, CallPid, Reason}=Msg, #state{calls=Calls}=State) ->
    case lists:keyfind(Ref, 3, Calls) of
        {CallId, CallPid, Ref} ->
            ?LLOG(notice, "call ~s down! (~p)", [CallId, Reason], State),
            Calls2 = lists:keydelete(Ref, 3, Calls),
            {noreply, State#state{calls=Calls2}};
        error ->
            handle(nkmedia_session_handle_info, [Msg], State)
    end;

handle_info(Msg, State) -> 
    case handle(nkmedia_session_handle_info, [Msg], State) of
        {continue, [Msg2, State2]} ->
            lager:error("Module ~p received unexpected call ~p", [Msg2]),
            {noreply, State2};
        Other ->
            Other
    end.


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

terminate(Reason, #state{id=SessId, ms=MS}=State) ->
    case MS of
        {freeswitch, _} ->
            nkmedia_fs_verto:bye(SessId, SessId);
        _ ->
            ok
    end,
    ?LLOG(info, "stopped (~p)", [Reason], State),
    catch handle(nkmedia_session_terminate, [Reason], State).


% ===================================================================
%% Internal
%% ===================================================================

%% @private
send_to_ms(#state{status=Status}=State) when Status /= wait ->
    {error, {invalid_status, Status}, State};

send_to_ms(#state{session=#{sdp_a:=undefined}}=State) ->
    {error, {missing_sdp_a}, State};

send_to_ms(#state{ms=undefined, session=Session}=State) ->
    Class = maps:get(mediaserver, Session, freeswitch),
    send_to_ms(Class, State);

send_to_ms(State) ->
    {error, already_in_mediaserver, State}.


%% @private
send_to_ms(freeswitch, #state{id=SessId, session=#{sdp_a:=SDP_A}=Session}=State) ->
    case nkmedia_fs_engine:get_all() of
        [{FsId, _}|_] ->
            Dialog = maps:get(verto_dialog, Session, #{}),
            case nkmedia_fs_verto:start_in(SessId, FsId, SDP_A, Dialog) of
                {ok, SDP_B} ->
                    %% TODO Send and receive pings
                    State2 = State#state{
                        ms = {freeswitch, FsId},
                        session = Session#{sdp_b:=SDP_B}
                    },
                    {ok, status(parked, State2)};
                {error, Error} ->
                    {error, {mediaserver_start_error, Error}, State}
            end;
        [] ->
            {error, no_mediaserver, State}
    end;

send_to_ms(MS, State) ->
    {error, {invalid_mediaserver, MS}, State}.


%% @private
get_from_ms(_Opts, #state{status=Status}=State) when Status /= wait ->
    {error, {invalid_status, Status}, State};

get_from_ms(Opts, #state{ms=undefined, session=Session}=State) ->
    Class = maps:get(mediaserver, Session, freeswitch),
    get_from_ms(Class, Opts, State);

get_from_ms(_Opts, State) ->
    {error, already_in_mediaserver, State}.


%% @private
get_from_ms(freeswitch, Opts, #state{id=SessId, session=Session}=State) ->
    Mod = case maps:get(sip_type, Opts, webrtc) of
        webrtc -> nkmedia_fs_verto;
        sip -> nkmedia_fs_sip
    end,
    case nkmedia_fs_engine:get_all() of
        [{FsId, _}|_] ->
            case Mod:start_out(SessId, FsId, #{}) of
                {ok, SDP} ->
                    io:format("SDP: ~s\n", [SDP]),
                    %% TODO Send and receive pings
                    State2 = State#state{
                        ms = {freeswitch, FsId}, 
                        session = Session#{sdp_a:=SDP}
                    },
                    % We must call answer
                    {ok, status(ringing, State2)};
                {error, Error} ->
                    {error, {mediaserver_start_error, Error}, State}
            end;
        [] ->
            {error, no_mediaserver, State}
    end;

get_from_ms(MS, _Opts, State) ->
    {error, {invalid_mediaserver, MS}, State}.


%% @private
send_to_call(Dest, Opts, #state{session=#{sdp_a:=undefined}}=State) ->
    case get_from_ms(Opts, State) of
        {ok, #state{session=#{sdp_a:=SDP_A}}=State2} when is_binary(SDP_A) ->
            send_to_call(Dest, Opts, State2);
        {error, Error} ->
            {error, Error, State}
    end;

send_to_call(Dest, _Opts, State) ->
    case handle(nkmedia_session_send_call, [Dest], State) of
        {ok, SDP_B, Opts, State2} ->
            answer_ms(SDP_B, Opts, status(ringing, State2));
        {async, State2} ->
            {async, status(ringing, State2)};
        {error, Error, State2} ->
            {error, Error, State2}
    end.


%% @private
answer_ms(_SDP, _Opts, #state{status=Status}=State) when Status /= ringing ->
    {error, {invalid_status, Status}, State};

answer_ms(SDP, Opts, #state{ms={freeswitch, _}}=State) ->
    #state{id= SessId, session=Session} = State,
    Dialog = maps:get(verto_dialog, Opts, #{}),
    case nkmedia_fs_verto:answer(SessId, SessId, SDP, Dialog) of
        ok ->
            Session2 = Session#{sdp_b:=SDP},
            {ok, status(parked, State#state{session=Session2})};
        {error, Error} ->
            {error, Error, State}
    end;

answer_ms(_SDP, _Opts, #state{ms=MS}=State) ->
    {error, {invalid_mediaserver, MS}, State}.



%% @private
send_to_mcu(Room, #state{id=SessId, ms={freeswitch, FsId}}) ->
    ok = nkmedia_fs_cmd:set_var(FsId, SessId, "park_after_bridge", "true"),
    Cmd = [<<"conference:">>, Room, <<"@video-mcu-stereo">>],
    nkmedia_fs_cmd:transfer_inline(FsId, SessId, Cmd).


%% @private
send_to_bridge(SessIdB, #state{id=SessIdA, ms={freeswitch, FsId}}) ->
    case nkmedia_fs_cmd:set_var(FsId, SessIdA, "park_after_bridge", "true") of
        ok ->
            nkmedia_fs_cmd:bridge(FsId, SessIdA, SessIdB);
        {error, Error} ->
            {error, Error}
    end.


%% @private
send_to_park(#state{id=SessId, ms={freeswitch, FsId}}) ->
    ok = nkmedia_fs_cmd:set_var(FsId, SessId, "park_after_bridge", "true"),
    nkmedia_fs_cmd:park(FsId, SessId).



% %% @private
% make_call(Dest, CallConfig, #state{config=Config, calls=Calls}=State) ->
%     CallId = nklib_util:uuid_4122(),
%     CallConfig2 = CallConfig#{
%         id => CallId,
%         type => outbound,
%         call => Dest,
%         monitor => self()
%     },
%     {ok, CallPid} = start(CallConfig2),
%     Mon = monitor(process, CallPid),
%     Calls2 = [{CallId, CallPid, Mon}|Calls],
%     State2 = State#state{config=Config#{role=>caller}, calls=Calls2},
%     {CallId, status(calling, State2)}.



%% @private
process_event(parked, #state{status=parked}=State) ->
    State;

process_event(parked, #state{status=Status}=State) ->
    ?LLOG(warning, "received parked in '~p'", [Status], State),
    State;

process_event({hangup, Code}, #state{session=Session}=State) ->
    gen_server:cast(self(), stop),
    Session2 = Session#{hangup_code=>Code},
    status(hangup, State#state{session=Session2});

process_event({bridge, Remote}, #state{session=Session}=State) ->
    Session2 = Session#{peer=>{bridge, Remote}},
    status(call, State#state{session=Session2});

process_event({mcu, McuInfo}, #state{session=Session}=State) ->
    Session2 = Session#{peer=>{mcu, McuInfo}},
    status(call, State#state{session=Session2}).



%% @private
status(Status, #state{status=Status}=State) ->
    restart_timer(State);

status(NewStatus, #state{status=OldStatus, session=Session, user_reply=From}=State) ->
    case OldStatus of
        ringing when From/=undefined, NewStatus==parked ->
            gen_server:reply(From, ok);
        ringing when From/=undefined ->
            gen_server:reply(From, {error, call_failed});
        _ ->
            ok
    end,
    State2 = restart_timer(State#state{status=NewStatus, user_reply=undefined}),
    State3 = State2#state{session=Session#{status=>NewStatus}},
    ?LLOG(info, "status ~p -> ~p", [OldStatus, NewStatus], State3),
    event({status, NewStatus}, State3).


%% @private
event(Info, State) ->
    {ok, State2} = handle(nkmedia_session_event, [Info], State),
    State2.


%% @private
restart_timer(#state{status=hangup, timer=Timer}=State) ->
    nklib_util:cancel_timer(Timer),
    State;

restart_timer(#state{status=Status, timer=Timer, session=Session}=State) ->
    nklib_util:cancel_timer(Timer),
    Time = case Status of
        wait -> maps:get(wait_timeout, Session, ?DEF_WAIT_TIMEOUT);
        parked -> maps:get(park_timeout, Session, ?DEF_PARK_TIMEOUT);
        ringing -> maps:get(ring_timeout, Session, ?DEF_RINGING_TIMEOUT);
        call -> maps:get(call_timeout, Session, ?DEF_CALL_TIMEOUT)
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

