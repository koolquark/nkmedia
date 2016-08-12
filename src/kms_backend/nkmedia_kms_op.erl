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

%% @doc Kurento Operations
-module(nkmedia_kms_op).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start/2, stop/1, echo/3]).
-export([get_all/0, stop_all/0, kms_event/2, candidate/4]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA KMS OP ~s (~s ~s) "++Txt, 
               [State#state.nkmedia_id, State#state.kms_sess_id, State#state.status 
                | Args])).

-include("../../include/nkmedia.hrl").


-define(WAIT_TIMEOUT, 60).      % Secs
-define(OP_TIMEOUT, 4*60*60).   


%% ===================================================================
%% Types
%% ===================================================================


-type kms_id() :: nkmedia_kms_engine:id().

-type status() ::
    wait | echo.



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Starts a new session
%% Starts a new Janus client
%% Monitors calling process
-spec start(kms_id(), nkmedia_session:id()) ->
    {ok, pid()}.

start(KmsId, SessionId) ->
    gen_server:start_link(?MODULE, {KmsId, SessionId, self()}, []).


%% @doc Stops a session
-spec stop(pid()) ->
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
-spec echo(pid()|kms_id(), nkmedia:offer(), map()) ->
    {ok, nkmedia:answer()} | {error, nkservice:error()}.

echo(Id, Offer, Opts) ->
    OfferOpts = maps:with([use_audio, use_video, use_data], Offer),
    do_call(Id, {echo, Offer, maps:merge(OfferOpts, Opts)}).


%% @private
-spec get_all() ->
    [{KmsSessId::term(), nkmedia:session_id(), pid()}].

get_all() ->
    [{KmsId, SId, Pid} || {{KmsId, SId}, Pid}<- nklib_proc:values(?MODULE)].



%% ===================================================================
%% Internal
%% ===================================================================

kms_event(Pid, Event) ->
    % lager:error("Event: ~p", [Event]),
    gen_server:cast(Pid, {event, Event}).


%% @private
candidate(Pid, App, Index, Candidate) ->
    do_cast(Pid, {candidate, App, Index, Candidate}).




%% ===================================================================
%% gen_server behaviour
%% ===================================================================


-record(state, {
    kms_id :: nkmedia_kms:id(),
    nkmedia_id ::nkmedia_session:id(),
    kms_sess_id :: binary(),
    pipeline :: binary(),
    conn ::  pid(),
    conn_mon :: reference(),
    user_mon :: reference(),
    status = init :: status() | init,
    wait :: term(),
    from :: {pid(), term()},
    opts :: map(),
    endpoint :: binary() | undefined,
    timer :: reference(),

    pid


}).


%% @private
-spec init(term()) ->
    {ok, tuple()}.

init({KmsId, MediaSessId, CallerPid}) ->
    case nkmedia_kms_client:start(KmsId) of
        {ok, Pid} ->
            ok = nkmedia_kms_client:register(Pid, ?MODULE, kms_event, [self()]),
            {ok, Pipe, KmsSessId} = 
                nkmedia_kms_client:create(Pid, <<"MediaPipeline">>, #{}, #{}),
            State = #state{
                kms_id = KmsId, 
                nkmedia_id = MediaSessId,
                kms_sess_id = KmsSessId,
                pipeline = Pipe,
                conn = Pid,
                conn_mon = monitor(process, Pid),
                user_mon = monitor(process, CallerPid),

                pid = CallerPid
            },
            true = nklib_proc:reg({?MODULE, KmsSessId}),
            nklib_proc:put(?MODULE, {KmsSessId, MediaSessId}),
            ?LLOG(notice, "started (~p)", [self()], State),
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

handle_call(_Msg, _From, State) -> 
    reply({error, invalid_state}, State).
    

%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({candidate, _App, _Index, <<>>}, State) ->
    lager:notice("Last client candidate"),
    noreply(State);

handle_cast({candidate, App, Index, Candidate}, #state{endpoint=ObjId}=State)
        when is_binary(ObjId) ->
    Data = #{
        sdpMid => App,
        sdpMLineIndex => Index,
        candidate => Candidate
    },
    lager:notice("Sending client candidate"),
    invoke(ObjId, addIceCandidate, #{candidate=>Data}, State),
    noreply(State);

handle_cast({candidate, _App, _Index, _Candidate}, State) ->
    ?LLOG(warning, "ignoring client candidate", [], State),
    noreply(State);

handle_cast({event, Event}, State) ->
    do_event(Event, State);

handle_cast(stop, State) ->
    ?LLOG(info, "user stop", [], State),
    {stop, normal, State};

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {stop, unexpected_call, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

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

terminate(Reason, #state{from=From}=State) ->
    io:format("\n\nSTOP\n"),
    ?LLOG(notice, "process stop: ~p", [Reason], State),
    destroy(State),
    nklib_util:reply(From, {error, process_down}),
    ok.


%% ===================================================================
%% Echo
%% ===================================================================

%% @doc
do_echo(#{sdp:=SDP}, State) ->
    try
        EndPoint = create_webrtc(State),
        invoke(EndPoint, connect, #{sink=>EndPoint}, State),
        SDP2 = invoke(EndPoint, processOffer, #{offer=>SDP}, State),
        subscribe(EndPoint, 'OnIceCandidate', State),
        invoke(EndPoint, gatherCandidates, #{}, State),
        % io:format("SDP1\n~s\n\n", [SDP]),
        % io:format("SDP2\n~s\n\n", [SDP2]),
        % Store endpoint and wait for candidates
        reply({ok, #{sdp=>SDP2}}, State#state{endpoint=EndPoint})
    catch
        throw:Throw -> reply_stop(Throw, State)
    end.


%% ===================================================================
%% Echo
%% ===================================================================


%% @private
do_event({candidate, ObjId, App, Index, Candidate}, #state{endpoint=ObjId}=State) ->
    #state{pid=Pid} = State,
    lager:notice("Candidate from Kurento2"),
    nkmedia_janus_proto:trickle(Pid, App, Index, Candidate),
    noreply(State);

do_event({candidate, _EndPoint, _App, _Index, _Candidate}, State) ->
    ?LLOG(warning, "ignoring Kurento candidate", [], State),
    noreply(State);

do_event(Event, State) ->
    ?LLOG(warning, "unrecognized event: ~p", [Event], State),
    noreply(State).




%% ===================================================================
%% Internal
%% ===================================================================

%% @private
create_webrtc(#state{pipeline=Pipe}=State) ->
    create(<<"WebRtcEndpoint">>, #{mediaPipeline=>Pipe}, #{}, State).


%% @private
subscribe(ObjId, Type, #state{conn=Pid}) ->
    case nkmedia_kms_client:subscribe(Pid, ObjId, Type) of
        {ok, SubsId} -> SubsId;
        {error, Error} -> throw(Error)
    end.


%% @private
create(Type, Params, Prop, #state{conn=Pid}) ->
    case nkmedia_kms_client:create(Pid, Type, Params, Prop) of
        {ok, ObjId, _SessId} -> ObjId;
        {error, Error} -> throw(Error)
    end.


%% @private
invoke(ObjId, Operation, Params, #state{conn=Pid}=State) ->
    case nkmedia_kms_client:invoke(Pid, ObjId, Operation, Params) of
        {ok, Res} -> 
            Res;
        {error, Error} ->
            ?LLOG(warning, "error calling invoke ~p: ~p", [Operation, Error], State),
            throw(Error)
    end.


%% @private
destroy(#state{pipeline=Pipe, conn=Pid}) ->
    nkmedia_kms_client:release(Pid, Pipe).


%% @private
% wait(Reason, State) ->
%     State2 = status(wait, State),
%     State2#state{wait=Reason}.


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
    {reply, Reply, State}.


%% @private
reply_stop(Reply, State) ->
    lager:error("REPLY STOP"),
    {stop, normal, Reply, State}.


%% @private
noreply(State) ->
    {noreply, State}.


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
