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
%% Run inside nkmedia_session to extend its capabilities
%% For each operation, starts and monitors a new nkmedia_kms_op process

-module(nkmedia_kms_session).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([kms_event/3]).
-export([init/3, terminate/3, start/3, answer/4, candidate/3, update/5, stop/3]).
-export([nkmedia_session_handle_call/4, nkmedia_session_handle_cast/3]).

-export_type([config/0, type/0, opts/0, update/0]).

-define(LLOG(Type, Txt, Args, Session),
    lager:Type("NkMEDIA KMS Session ~s "++Txt, 
               [maps:get(session_id, Session) | Args])).

-define(LLOG2(Type, Txt, Args, SessId),
    lager:Type("NkMEDIA KMS Session ~s "++Txt, [SessId| Args])).

-include_lib("nksip/include/nksip.hrl").

-define(MAX_ICE_TIME, 100).


%% ===================================================================
%% Types
%% ===================================================================

-type session_id() :: nkmedia_session:id().
-type session() :: nkmedia_session:session().
-type endpoint() :: binary().
-type continue() :: continue | {continue, list()}.

% AUDIO, VIDEO, DATA
-type media_type() :: binary(). 


% KURENTO_SPLIT_RECORDER , MP4, MP4_AUDIO_ONLY, MP4_VIDEO_ONLY, 
% WEBM, WEBM_AUDIO_ONLY, WEBM_VIDEO_ONLY, JPEG_VIDEO_ONLY
-type media_profile() :: binary().


-type config() :: 
    nkmedia_session:config() |
    #{
    }.


-type type() ::
    nkmedia_session:type() |
    echo     |
    proxy    |
    publish  |
    listen   |
    play     |
    connect.

-type ext_opts() :: nkmedia_session:ext_opts().

-type opts() ::
    nkmedia_session:session() |
    #{
        record => boolean(),            %
        play_url => binary(),
        room_id => binary(),            % publish, listen
        publisher_id => binary(),       % listen
        proxy_type => webrtc | rtp      % proxy
    }.


-type update() ::
    nkmedia_session:update().
    


-type state() ::
    #{
        kms_id => nkmedia_kms_engine:id(),
        kms_client => pid(),
        pipeline => binary(),
        endpoint => endpoint(),
        record_pos => integer()
    }.


%% ===================================================================
%% External
%% ===================================================================

%% @private
-spec kms_event(session_id(), binary(), map()) ->
    ok.

kms_event(SessId, <<"OnIceCandidate">>, Data) ->
    #{
        <<"source">> := _SrcId,
        <<"candidate">> := #{
            <<"sdpMid">> := MId,
            <<"sdpMLineIndex">> := MIndex,
            <<"candidate">> := ALine
        }
    } = Data,
    Candidate = #candidate{m_id=MId, m_index=MIndex, a_line=ALine},
    nkmedia_session:server_candidate(SessId, Candidate);

kms_event(SessId, <<"OnIceGatheringDone">>, _Data) ->
    nkmedia_session:server_candidate(SessId, #candidate{last=true});

kms_event(SessId, <<"EndOfStream">>, Data) ->
    #{<<"source">>:=Player} = Data,
    nkmedia_session:do_cast(SessId, {nkmedia_kms, {end_of_stream, Player}});

kms_event(SessId, Type, Data) ->
    print_event(SessId, Type, Data).




%% ===================================================================
%% Callbacks
%% ===================================================================


-spec init(session_id(), session(), state()) ->
    {ok, state()}.

init(_Id, _Session, State) ->
    {ok, State}.


%% @doc Called when the session stops
-spec terminate(Reason::term(), session(), state()) ->
    {ok, state()}.

terminate(_Reason, _Session, State) ->
    {ok, State}.


%% @private
-spec start(type(), nkmedia:session(), state()) ->
    {ok, Reply::map(), ext_opts(), state()} |
    {error, nkservice:error(), state()} | continue().

start(Type,  #{offer:=#{sdp:=SDP}}=Session, State) when Type==park; Type==echo ->
    case create_webrtc(SDP, Session, State) of
        {ok, Answer, State2} ->
            case do_update(Type, Session, State2) of
                {ok, Reply, ExtOps, State3} ->
                    case start_record(Session, Session, State3) of
                        {ok, State4} ->
                            Reply2 = Reply#{answer=>Answer},
                            ExtOps2 = ExtOps#{answer=>Answer},
                            {ok, Reply2, ExtOps2, State4};
                        {error, Error, State4} ->
                            ?LLOG(error, "could not start recording: ~p", 
                                  [Error], State4),
                            {error, record_error, State4}
                    end;
                {error, Error, State3} ->
                    {error, Error, State3};
                continue ->
                    {error, invalid_parameters, State2}
            end;
        {error, Error, State2} ->
            {error, Error, State2}
    end;

start(_Type, _Session, _State) ->
    continue.


%% @private
-spec answer(type(), nkmedia:answer(), session(), state()) ->
    {ok, Reply::map(), ext_opts(), state()} |
    {error, nkservice:error(), state()} | continue().

% answer(Type, Answer, _Session, #{kms_op:=answer}=State)
%         when Type==proxy; Type==listen ->
%     #{kms_pid:=Pid} = State,
%     case nkmedia_kms_op:answer(Pid, Answer) of
%         ok ->
%             ExtOps = #{answer=>Answer},
%             {ok, #{}, ExtOps,  maps:remove(kms_op, State)};
%         {ok, Answer2} ->
%             Reply = ExtOps = #{answer=>Answer2},
%             {ok, Reply, ExtOps, maps:remove(kms_op, State)};
%         {error, Error} ->
%             {error, Error, State}
%     end;

answer(_Type, _Answer, _Session, _State) ->
    continue.


%% @private
-spec candidate(nkmedia:candidate(), session(), state()) ->
    ok | {error, nkservice:error()}.

candidate(#candidate{last=true}, Session, _State) ->
    ?LLOG(info, "sending last client candidate to Kurento", [], Session),
    ok;

candidate(Candidate, Session, State) ->
    #candidate{m_id=MId, m_index=MIndex, a_line=ALine} = Candidate,
    Data = #{
        sdpMid => MId,
        sdpMLineIndex => MIndex,
        candidate => ALine
    },
    ?LLOG(info, "sending client candidate to Kurento", [], Session),
    ok = invoke(addIceCandidate, #{candidate=>Data}, State).


%% @private
-spec update(update(), Opts::map(), type(), nkmedia:session(), state()) ->
    {ok, Reply::map(), ext_opts(), state()} |
    {error, nkservice:error(), state()} | continue().

update(session_type, #{session_type:=Type}=Opts, _OldTytpe, Session, State) ->
    do_update(Type, maps:merge(Session, Opts), State);

update(connect, Opts, _Type, Session, State) ->
    do_update(connect, maps:merge(Session, Opts), State);
   
update(media, Opts, _Type, Session, #{endpoint:=EP}=State) ->
    case get_update_medias(Opts) of
        {[], []} ->
            ok;
        {Add, Remove} ->
            lists:foreach(
                fun(PeerEP) ->
                    do_connect(PeerEP, EP, Add, State),
                    do_disconnect(PeerEP, EP, Remove, State)
                end,
                maps:keys(get_sources(State))),
            lists:foreach(
                fun(PeerEP) ->
                    do_connect(EP, PeerEP, Add, State),
                    do_disconnect(EP, PeerEP, Remove, State)
                end,
                maps:keys(get_sinks(State)))
    end,
    case start_record(Opts, Session, State) of
        {ok, State2} ->
            {ok, #{}, #{}, State2};
        {error, Error, State2} ->
            {error, Error, State2}
    end;

update(record, #{operation:=pause}, _Type, Session, #{recorder:=RecordEP}=State) ->
    ok = invoke(RecordEP, pause, #{}, State),
    {ok, #{}, #{}, State};

update(record, #{operation:=resume}, _Type, Session, #{recorder:=RecordEP}=State) ->
    ok = invoke(RecordEP, record, #{}, State),
    {ok, #{}, #{}, State};

update(record, #{operation:=stop}, _Type, Session, #{recorder:=RecordEP}=State) ->
    ok = invoke(RecordEP, stop, #{}, State),
    {ok, #{}, #{}, State};

update(record, _Opts, _Type, _Session, State) ->
    {error, invalid_parameters, State};

update(play, #{operation:=start}=Opts, _Type, Session, State) ->
    do_update(play, maps:merge(Session, Opts), State);

update(play, #{operation:=pause}, _Type, Session, #{player:=PlayerEP}=State) ->
    ok = invoke(PlayerEP, pause, #{}, State),
    {ok, #{}, #{}, State};

update(play, #{operation:=resume}, _Type, Session, #{player:=PlayerEP}=State) ->
    ok = invoke(PlayerEP, play, #{}, State),
    {ok, #{}, #{}, State};

update(play, #{operation:=stop}, _Type, Session, #{player:=PlayerEP}=State) ->
    ok = invoke(PlayerEP, stop, #{}, State),
    {ok, #{}, #{}, State};

update(play, #{operation:=get_info}, _Type, Session, #{player:=PlayerEP}=State) ->
    {ok, Data} = invoke(PlayerEP, getVideoInfo, #{}, State),
    #{
        <<"duration">> := Duration,
        <<"isSeekable">> := IsSeekable,
        <<"seekableInit">> := Start,
        <<"seekableEnd">> := Stop
    } = Data,
    Data2 = #{
        duration => Duration,
        is_seekable => IsSeekable,
        first_position => Start,
        last_position => Stop
    },
    {ok, #{video_info=>Data2}, #{}, State};

update(play, #{operation:=get_position}, _Type, Session, #{player:=PlayerEP}=State) ->
    case invoke(PlayerEP, getPosition, #{}, State) of
        {ok, Pos}  ->
            {ok, #{position=>Pos}, #{}, State};
        {error, Error} ->
            ?LLOG(notice, "play get_position error: ~p", [Error], Session),
            {error, kms_error}
    end;

update(play, #{operation:=set_position, position:=Pos}, _Type, Session, 
       #{player:=PlayerEP}=State) ->
    case invoke(PlayerEP, setPosition, #{position=>Pos}, State) of
        ok ->
            {ok, #{}, #{}, State};
        {error, Error} ->
            ?LLOG(notice, "play set_position error: ~p", [Error], Session),
            {error, kms_error}
    end;

update(play, _Opts, _Type, _Session, State) ->
    {error, invalid_parameters, State};

update(get_stats, Opts, _Type, Session, State) ->
    Type = maps:get(media_type, Opts, <<"VIDEO">>),
    case Type == <<"AUDIO">> orelse Type == <<"VIDEO">> orelse Type == <<"DATA">> of
        true ->
            {ok, Stats} = invoke(getStats, #{mediaType=>Type}, State),
            {ok, #{stats=>Stats}, #{}, State};
        false ->
            {error, invalid_parameters}
    end;

update(info, _Opts, _Type, Session, State) ->
    print_info(Session, State),
    {ok, #{}, #{}, State};

update(_Update, _Opts, _Type, _Session, _State) ->
    continue.


%% @private
-spec stop(nkservice:error(), session(), state()) ->
    {ok, state()}.

stop(_Reason, _Session, State) ->
    release(State),
    case State of
        #{recorder:=Recorder} -> 
            invoke(Recorder, stopAndWait, #{}, State),
            release(Recorder, State);
        _ -> ok
    end,
    case State of
        #{player:=Player} -> 
            invoke(Player, stop, #{}, State),
            release(Player, State);
        _ -> ok
    end,
    {ok, State}.


%% @private
% nkmedia_session_handle_call({connect, Peer, PeerEP}, _From, _Session, State) ->
%     case connect(Peer, PeerEP, State) of
%         {ok, #{endpoint:=EP}=State2} ->
%             {reply, {ok, EP}, State2};
%         {error, Error, State2} ->
%             {reply, {error, Error}, State2}
%     end;

nkmedia_session_handle_call(get_endpoint, _From, _Session, #{endpoint:=EP}=State) ->
    {reply, {ok, EP}, State}.

% nkmedia_session_handle_call({bridge, PeerEP}, _From, _Session, State) ->
%     case connect(PeerEP, State) of
%         {ok, #{endpoint:=EP}=State2} ->
%             {reply, {ok, EP}, State2};
%         {error, Error, State2} ->
%             {reply, {error, Error}, State2}
%     end.
 
nkmedia_session_handle_cast({end_of_stream, Player}, _Session, #{player:=Player}=State) ->
    invoke(Player, play, #{}, State),
    {noreply, State};

nkmedia_session_handle_cast({end_of_stream, Player}, _Session, State) ->
    lager:error("END: ~p, ~p", [Player, State]),
    {noreply, State}.



%% ===================================================================
%% Internal
%% ===================================================================


%% @private
-spec create_webrtc(SDP::binary(), session(), state()) ->
    {ok, nkmedia:answer(), state()} | {error, nkservice:error(), state()}.

create_webrtc(SDP, Session, State) ->
    case get_mediaserver(Session, State) of
        {ok, State2} ->
            case create_endpoint('WebRtcEndpoint', #{}, Session, State2) of
                {ok, EP} ->
                    State3 = State2#{endpoint=>EP},
                    subscribe('Error', State3),
                    subscribe('OnIceComponentStateChanged', State3),
                    subscribe('OnIceCandidate', State3),
                    subscribe('OnIceGatheringDone', State3),
                    subscribe('NewCandidatePairSelected', State3),
                    subscribe('MediaStateChanged', State3),
                    subscribe('MediaFlowInStateChange', State3),
                    subscribe('MediaFlowOutStateChange', State3),
                    subscribe('ConnectionStateChanged', State3),
                    subscribe('ElementConnected', State3),
                    subscribe('ElementDisconnected', State3),
                    subscribe('MediaSessionStarted', State3),
                    subscribe('MediaSessionTerminated', State3),
                    % subscribe('ObjectCreated', State3),
                    % subscribe('ObjectDestroyed', State3),
                    {ok, SDP2} = invoke(processOffer, #{offer=>SDP}, State3),
                    % timer:sleep(200),
                    % io:format("SDP1\n~s\n\n", [SDP]),
                    % io:format("SDP2\n~s\n\n", [SDP2]),
                    % Store endpoint and wait for candidates
                    ok = invoke(gatherCandidates, #{}, State3),
                    {ok, #{sdp=>SDP2, trickle_ice=>true}, State3};
                {error, Error, State3} ->
                   {error, Error, State3}
            end;
        {error, Error} ->
            {error, Error, State}
    end.


%% @private
-spec create_recorder(binary(), session(), state()) ->
    {ok, state()} | {error, nkservice:error(), state()}.

create_recorder(Url, Session, State) ->
    create_recorder(Url, <<"WEBM">>, Session, State).


%% @private
%% Recorder supports record, pause, stop, stopAndWait
-spec create_recorder(binary(), media_profile(), session(), state()) ->
    {ok, state()} | {error, nkservice:error(), state()}.

create_recorder(Url, Profile, Session, #{recorder:=Recorder}=State) ->
    invoke(Recorder, stopAndWait, #{}, State),
    release(Recorder, State),
    create_recorder(Url, Profile, Session, maps:remove(recorder, State));

create_recorder(Url, Profile, Session, State) ->
    Medias = lists:flatten([
        case maps:get(use_audio, Session, true) of
            true -> <<"AUDIO">>;
            _ -> []
        end,
        case maps:get(use_video, Session, true) of
            true -> <<"VIDEO">>;
            _ -> []
        end
    ]),
    case get_mediaserver(Session, State) of
        {ok, #{endpoint:=EP}=State2} ->
            Params = #{uri=>nklib_util:to_binary(Url), mediaProfile=>Profile},
            case create_endpoint('RecorderEndpoint', Params, Session, State2) of
                {ok, ObjId} ->
                    subscribe(ObjId, 'Error', State2),
                    subscribe(ObjId, 'Paused', State2),
                    subscribe(ObjId, 'Stopped', State2),
                    subscribe(ObjId, 'Recording', State2),
                    ok = do_connect(EP, ObjId, Medias, State),
                    ok = invoke(ObjId, record, #{}, State2),
                    {ok, State2#{recorder=>ObjId}};
                {error, Error} ->
                   {error, Error, State2}
            end;
        {error, Error} ->
            {error, Error, State}
    end.


%% @private
%% Player supports play, pause, stop, getPosition, getVideoInfo, setPosition (position)
-spec create_player(binary(), session(), state()) ->
    {ok, state()} | {error, nkservice:error(), state()}.

create_player(Url, Session, #{player:=Player}=State) ->
    invoke(Player, stop, #{}, State),
    release(Player, State),
    create_player(Url, Session, maps:remove(player, State));

create_player(Url, Session, State) ->
    case get_mediaserver(Session, State) of
        {ok, #{endpoint:=EP}=State2} ->
            Params = #{uri=>nklib_util:to_binary(Url)},
            case create_endpoint('PlayerEndpoint', Params, Session, State2) of
                {ok, ObjId} ->
                    subscribe(ObjId, 'Error', State2),
                    subscribe(ObjId, 'EndOfStream', State2),
                    ok = do_connect(ObjId, EP, [<<"AUDIO">>,<<"VIDEO">>], State2),
                    ok = invoke(ObjId, play, #{}, State2),
                    {ok, State2#{player=>ObjId}};
                {error, Error} ->
                   {error, Error, State2}
            end;
        {error, Error} ->
            {error, Error, State}
    end.


%% @private
-spec create_endpoint(atom(), map(), session(), state()) ->
    {ok, endpoint()} | {error, nkservice:error()}.

create_endpoint(Type, Params, Session, State) ->
    #{session_id:=SessId} = Session, 
    #{kms_client:=Pid, pipeline:=Pipeline} = State,
    Params2 = Params#{mediaPipeline=>Pipeline},
    Properties = #{pkey1 => pval1},
    case nkmedia_kms_client:create(Pid, Type, Params2, Properties) of
        {ok, ObjId} ->
            ok = invoke(ObjId, addTag, #{key=>nkmedia, value=>SessId}, State),
            ok = invoke(ObjId, setSendTagsInEvents, #{sendTagsInEvents=>true}, State),
            {ok, ObjId};
        {error, Error} ->
            {error, Error}
    end.


%% @private
-spec do_update(update(), nkmedia:session(), state()) ->
    {ok, Reply::map(), ext_opts(), state()} |
    {error, nkservice:error(), state()} | continue().

do_update(park, Session, State) ->
    disconnect_all(State),
    {ok, #{}, #{type=>park}, State};

do_update(echo, #{session_id:=SessId}=Session, State) ->
    % If we don't add any new media options to Session, it will take the original ones
    Medias = get_create_medias(Session),
    case connect_peer(SessId, Medias, Session, State) of
        ok ->
            {ok, #{}, #{type=>echo}, State};
        {error, Error} ->
            {error, Error, State}
    end;

do_update(connect, #{peer_id:=PeerId}=Session, State) ->
    Medias = get_create_medias(Session),
    case connect_peer(PeerId, Medias, Session, State) of
        ok ->
            {ok, #{}, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

do_update(play, #{play_url:=Url}=Session, State) ->
    case create_player(Url, Session, State) of
        {ok, State2} ->
            {ok, #{}, #{type=>play}, State2};
        {error, Error} ->
            {error, Error, State}
    end;

do_update(play, Session, State) ->
    Url = <<"file:///tmp/1.webm">>,
    % Url = <<"http://files.kurento.org/video/format/sintel.webm">>,
    do_update(play, Session#{play_url=>Url}, State);

do_update(_Op, _Session, _State) ->
    continue.


%% @private
-spec start_record(map(), session(), state()) ->
    {ok, state()} | {error, nkservice:error(), state()}.

start_record(#{record:=true}, #{sesion_id:=SessId}=Session, State) ->
    Pos = maps:get(record_pos, State, 0),
    Name = io_lib:format("~s_p~4..0w.webm", [SessId, Pos]),
    Url = filename:join(<<"file:///tmp/record">>, list_to_binary(Name)),
    case create_recorder(Url, Session, State) of
        {ok, State2} ->
            {ok, State2};
        {error, Error} ->
            {error, Error, State}
    end;

start_record(_Opts, _Session, State) ->
    {ok, State}.


%% @private
-spec connect_peer(session_id(), all|[media_type()], session(), state()) ->
    ok | {error, nkservice:error()}.

connect_peer(PeerId, Medias, Session, State) ->
    case get_peer_endpoint(PeerId, Session, State) of
        {ok, PeerEP} ->
            connect(PeerEP, Medias, State);
        {error, Error} ->
            {error, Error}
    end.


%% @private
-spec connect(endpoint(), all|[media_type()], state()) ->
    ok | {error, nkservice:error()}.

connect(PeerEP, [<<"AUDIO">>, <<"VIDEO">>, <<"DATA">>], #{endpoint:=EP}=State) ->
    invoke(PeerEP, connect, #{sink=>EP}, State);

connect(PeerEP, Medias, #{endpoint:=EP}=State) ->
    Res = do_connect(PeerEP, EP, Medias, State),
    Medias2 = [<<"AUDIO">>, <<"DATA">>, <<"VIDEO">>] -- lists:sort(Medias),
    do_disconnect(PeerEP, EP, Medias2, State),
    Res.


%% @private
do_connect(_PeerEP, _SinkEP, [], _State) ->
    ok;
do_connect(PeerEP, SinkEP, [Type|Rest], State) ->
    case invoke(PeerEP, connect, #{sink=>SinkEP, mediaType=>Type}, State) of
        ok ->
            lager:info("connecting ~s", [Type]),
            do_connect(PeerEP, SinkEP, Rest, State);
        {error, Error} ->
            {error, Error}
    end.

%% @private
do_disconnect(_PeerEP, _SinkEP, [], _State) ->
    ok;
do_disconnect(PeerEP, SinkEP, [Type|Rest], State) ->
    case invoke(PeerEP, disconnect, #{sink=>SinkEP, mediaType=>Type}, State) of
        ok ->
            lager:info("disconnecting ~s", [Type]),
            do_disconnect(PeerEP, SinkEP, Rest, State);
        {error, Error} ->
            {error, Error}
    end.


%% @private
disconnect_all(#{endpoint:=EP}=State) ->
    lists:foreach(
        fun(PeerEP) -> invoke(PeerEP, disconnect, #{sink=>EP}, State) end,
        maps:keys(get_sources(State))),
    lists:foreach(
        fun(PeerEP) -> invoke(EP, disconnect, #{sink=>PeerEP}, State) end,
        maps:keys(get_sinks(State))).




%% @private
-spec subscribe(atom(), state()) ->
    SubsId::binary().

subscribe(Type, #{endpoint:=EP}=State) ->
    subscribe(EP, Type, State).


%% @private
-spec subscribe(endpoint(), atom(), state()) ->
    SubsId::binary().

subscribe(ObjId, Type, #{kms_client:=Pid}) ->
    {ok, SubsId} = nkmedia_kms_client:subscribe(Pid, ObjId, Type),
    SubsId.


%% @private
-spec invoke(atom(), map(), state()) ->
    ok | {ok, term()} | {error, nkservice:error()}.

invoke(Op, Params, #{endpoint:=EP}=State) ->
    invoke(EP, Op, Params, State).


%% @private
-spec invoke(endpoint(), atom(), map(), state()) ->
    ok | {ok, term()} | {error, nkservice:error()}.

invoke(ObjId, Op, Params, #{kms_client:=Pid}) ->
    case nkmedia_kms_client:invoke(Pid, ObjId, Op, Params) of
        {ok, null} -> ok;
        {ok, Other} -> {ok, Other};
        {error, Error} -> {error, Error}
    end.


%% @private
-spec release(state()) ->
    ok | {error, nkservice:error()}.
 
release(#{endpoint:=EP}=State) ->
    release(EP, State);
release(_State) ->
    ok.


%% @private
-spec release(binary(), state()) ->
    ok | {error, nkservice:error()}.
 
release(ObjId, #{kms_client:=Pid}) ->
    nkmedia_kms_client:release(Pid, ObjId).


%% @private
-spec get_peer_endpoint(session_id(), session(), state()) ->
    {ok, endpoint()} | {error, nkservice:error()}.

get_peer_endpoint(SessId, #{session_id:=SessId}, #{endpoint:=EP}) ->
    {ok, EP};
get_peer_endpoint(SessId, _Session, _State) ->
    case nkmedia_session:do_call(SessId, {nkmedia_kms, get_endpoint}) of
        {ok, EP} -> {ok, EP};
        {error, Error} -> {error, Error}
    end.


%% @private
-spec get_sources(state()) ->
    #{endpoint() => [media_type()]}.

get_sources(#{endpoint:=EP}=State) ->
    {ok, Sources} = invoke(getSourceConnections, #{}, State),
    lists:foldl(
        fun(#{<<"type">>:=Type, <<"source">>:=Source, <<"sink">>:=Sink}, Acc) ->
            Sink = EP,
            Types = maps:get(Source, Acc, []),
            maps:put(Source, lists:sort([Type|Types]), Acc)
        end,
        #{},
        Sources).


%% @private
-spec get_sinks(state()) ->
    #{endpoint() => [media_type()]}.

get_sinks(#{endpoint:=EP}=State) ->
    {ok, Sinks} = invoke(getSinkConnections, #{}, State),
    lists:foldl(
        fun(#{<<"type">>:=Type, <<"source">>:=Source, <<"sink">>:=Sink}, Acc) ->
            Source = EP,
            Types = maps:get(Sink, Acc, []),
            maps:put(Sink, lists:sort([Type|Types]), Acc)
        end,
        #{},
        Sinks).


%% @private
-spec get_mediaserver(session(), state()) ->
    {ok, state()} | {error, nkservice:error()}.

get_mediaserver(_Session, #{kms_id:=_}=State) ->
    {ok, State};

get_mediaserver(#{srv_id:=SrvId}, State) ->
    case SrvId:nkmedia_kms_get_mediaserver(SrvId) of
        {ok, KmsId} ->
            case nkmedia_kms_engine:get_pipeline(KmsId) of
                {ok, Pipeline, Pid} ->
                    {ok, State#{kms_id=>KmsId, kms_client=>Pid, pipeline=>Pipeline}};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @private
-spec get_create_medias(map()) ->
    [media_type()].

get_create_medias(Opts) ->
    lists:flatten([
        case maps:get(use_audio, Opts, true) of
            true -> <<"AUDIO">>;
            _ -> []
        end,
        case maps:get(use_video, Opts, true) of
            true -> <<"VIDEO">>;
            _ -> []
        end,
        case maps:get(use_data, Opts, true) of
            true -> <<"DATA">>;
            _ -> []
        end
    ]).


-spec get_update_medias(map()) ->
    {[media_type()], [media_type()]}.

get_update_medias(Opts) ->
    Audio = maps:get(use_audio, Opts, none),
    Video = maps:get(use_video, Opts, none),
    Data = maps:get(use_data, Opts, none),
    Add = lists:flatten([
        case Audio of true -> <<"AUDIO">>; _ -> [] end,
        case Video of true -> <<"VIDEO">>; _ -> [] end,
        case Data of true -> <<"DATA">>; _ -> [] end
    ]),
    Rem = lists:flatten([
        case Audio of false -> <<"AUDIO">>; _ -> [] end,
        case Video of false -> <<"VIDEO">>; _ -> [] end,
        case Data of false -> <<"DATA">>; _ -> [] end
    ]),
    {Add, Rem}.




%% @private
get_id(List) when is_list(List) ->
    nklib_util:bjoin([get_id(Id) || Id <- lists:sort(List), is_binary(Id)]);

get_id(Ep) when is_binary(Ep) ->
    case binary:split(Ep, <<"/">>) of
        [_, Id] -> Id;
        _ -> Ep
    end.


%% @private
print_info(#{session_id:=SessId}, #{endpoint:=EP}=State) ->
    io:format("\nSessId: ~s\n", [SessId]),
    io:format("EP:     ~s\n", [get_id(EP)]),
    io:format("Uri:    ~s\n", [invoke(getUri, #{}, State)]),
    io:format("\nSources:\n"),
    lists:foreach(
        fun({Id, Types}) -> 
            io:format("~s: ~s\n", [get_id(Id), nklib_util:bjoin(Types)]) 
        end,
        maps:to_list(get_sources(State))),
    io:format("\nSinks:\n"),
    lists:foreach(
        fun({Id, Types}) -> 
            io:format("~s: ~s\n", [get_id(Id), nklib_util:bjoin(Types)]) 
        end,
        maps:to_list(get_sinks(State))),

    {ok, MediaState} = invoke(getMediaState, #{}, State),
    io:format("\nMediaState: ~p\n", [MediaState]),
    {ok, ConnectionState} = invoke(getConnectionState, #{}, State),
    io:format("Connectiontate: ~p\n", [ConnectionState]),

    {ok, IsMediaFlowingIn1} = invoke(isMediaFlowingIn, #{mediaType=>'AUDIO'}, State),
    io:format("\nIsMediaFlowingIn AUDIO: ~p\n", [IsMediaFlowingIn1]),
    {ok, IsMediaFlowingOut1} = invoke(isMediaFlowingOut, #{mediaType=>'AUDIO'}, State),
    io:format("IsMediaFlowingOut AUDIO: ~p\n", [IsMediaFlowingOut1]),
    {ok, IsMediaFlowingIn2} = invoke(isMediaFlowingIn, #{mediaType=>'VIDEO'}, State),
    io:format("\nIsMediaFlowingIn VIDEO: ~p\n", [IsMediaFlowingIn2]),
    {ok, IsMediaFlowingOut2} = invoke(isMediaFlowingOut, #{mediaType=>'VIDEO'}, State),
    io:format("IsMediaFlowingOut VIDEO: ~p\n", [IsMediaFlowingOut2]),

    {ok, MinVideoRecvBandwidth} = invoke(getMinVideoRecvBandwidth, #{}, State),
    io:format("\nMinVideoRecvBandwidth: ~p\n", [MinVideoRecvBandwidth]),
    {ok, MinVideoSendBandwidth} = invoke(getMinVideoSendBandwidth, #{}, State),
    io:format("MinVideoSendBandwidth: ~p\n", [MinVideoSendBandwidth]),
    {ok, MaxVideoRecvBandwidth} = invoke(getMaxVideoRecvBandwidth, #{}, State),
    io:format("\nMaxVideoRecvBandwidth: ~p\n", [MaxVideoRecvBandwidth]),
    {ok, MaxVideoSendBandwidth} = invoke(getMaxVideoSendBandwidth, #{}, State),
    io:format("MaxVideoSendBandwidth: ~p\n", [MaxVideoSendBandwidth]),
    
    {ok, MaxAudioRecvBandwidth} = invoke(getMaxAudioRecvBandwidth, #{}, State),
    io:format("\nMaxAudioRecvBandwidth: ~p\n", [MaxAudioRecvBandwidth]),
    
    {ok, MinOutputBitrate} = invoke(getMinOutputBitrate, #{}, State),
    io:format("\nMinOutputBitrate: ~p\n", [MinOutputBitrate]),
    {ok, MaxOutputBitrate} = invoke(getMaxOutputBitrate, #{}, State),
    io:format("MaxOutputBitrate: ~p\n", [MaxOutputBitrate]),

    {ok, RembParams} = invoke(getRembParams, #{}, State),
    io:format("\nRembParams: ~p\n", [RembParams]),
    
    % Convert with dot -Tpdf gstreamer.dot -o 1.pdf
    % {ok, GstreamerDot} = invoke(getGstreamerDot, #{}, State),
    % file:write_file("/tmp/gstreamer.dot", GstreamerDot),
    ok.



%% @private
-spec print_event(session_id(), binary(), map()) ->
    ok.

print_event(SessId, <<"OnIceComponentStateChanged">>, Data) ->
    #{
        <<"source">> := _SrcId,
        <<"state">> := IceState,
        <<"streamId">> := StreamId,
        <<"componentId">> := CompId
    } = Data,
    {Level, Msg} = case IceState of
        <<"GATHERING">> -> {info, gathering};
        <<"CONNECTING">> -> {info, connecting};
        <<"CONNECTED">> -> {notice, connected};
        <<"READY">> -> {notice, ready};
        <<"FAILED">> -> {warning, failed}
    end,
    Txt = io_lib:format("ICE State (~p:~p) ~s", [StreamId, CompId, Msg]),
    case Level of
        info ->    ?LLOG2(info, "~s", [Txt], SessId);
        notice ->  ?LLOG2(notice, "~s", [Txt], SessId);
        warning -> ?LLOG2(warning, "~s", [Txt], SessId)
    end;

print_event(SessId, <<"MediaSessionStarted">>, _Data) ->
    ?LLOG2(info, "event media session started: ~p", [_Data], SessId);

print_event(SessId, <<"ElementConnected">>, Data) ->
    #{
        <<"mediaType">> := Type, 
        <<"sink">> := Sink,
        <<"source">> := Source
    } = Data,
    ?LLOG2(info, "event element connected ~s: ~s -> ~s", 
           [Type, get_id(Source), get_id(Sink)], SessId);

print_event(SessId, <<"ElementDisconnected">>, Data) ->
    #{
        <<"mediaType">> := Type, 
        <<"sink">> := Sink,
        <<"source">> := Source
    } = Data,
    ?LLOG2(info, "event element disconnected ~s: ~s -> ~s", 
           [Type, get_id(Source), get_id(Sink)], SessId);

print_event(SessId, <<"NewCandidatePairSelected">>, Data) ->
    #{
        <<"candidatePair">> := #{
            <<"streamID">> := StreamId,
            <<"componentID">> := CompId,
            <<"localCandidate">> := Local,
            <<"remoteCandidate">> := Remote
        }
    } = Data,
    ?LLOG2(notice, "candidate selected (~p:~p) local: ~s remote: ~s", 
           [StreamId, CompId, Local, Remote], SessId);

print_event(SessId, <<"ConnectionStateChanged">>, Data) ->
    #{
        <<"newState">> := New,
        <<"oldState">> := Old
    } = Data,
    ?LLOG2(info, "event connection state changed (~s -> ~s)", [Old, New], SessId);

print_event(SessId, <<"MediaFlowOutStateChange">>, Data) ->
    #{
        <<"mediaType">> := Type, 
        <<"padName">> := _Pad,
        <<"state">> := State
    }  = Data,
    ?LLOG2(info, "event media flow out state change (~s: ~s)", [Type, State], SessId);

print_event(SessId, <<"MediaFlowInStateChange">>, Data) ->
    #{
        <<"mediaType">> := Type, 
        <<"padName">> := _Pad,
        <<"state">> := State
    }  = Data,
    ?LLOG2(info, "event media in out state change (~s: ~s)", [Type, State], SessId);    

print_event(SessId, <<"MediaStateChanged">>, Data) ->
    #{
        <<"newState">> := New,
        <<"oldState">> := Old
    } = Data,
    ?LLOG2(info, "event media state changed (~s -> ~s)", [Old, New], SessId);

print_event(SessId, <<"Recording">>, _Data) ->
    ?LLOG2(notice, "event recording", [], SessId);

print_event(SessId, <<"Paused">>, _Data) ->
    ?LLOG2(notice, "event recording", [], SessId);

print_event(SessId, <<"Stopped">>, _Data) ->
    ?LLOG2(notice, "event recording", [], SessId);

print_event(_SessId, Type, Data) ->
    lager:warning("NkMEDIA KMS Session: unknown event ~s: ~p", [Type, Data]).



% %% @private
% get_opts(#{session_id:=SessId}=Session, State) ->
%     Keys = [record, use_audio, use_video, use_data, bitrate, dtmf],
%     Opts1 = maps:with(Keys, Session),
%     Opts2 = case Session of
%         #{user_id:=UserId} -> Opts1#{user=>UserId};
%         _ -> Opts1
%     end,
%     case Session of
%         #{record:=true} ->
%             Pos = maps:get(record_pos, State, 0),
%             Name = io_lib:format("~s_p~4..0w", [SessId, Pos]),
%             File = filename:join(<<"/tmp/record">>, list_to_binary(Name)),
%             {Opts2#{filename => File}, State#{record_pos=>Pos+1}};
%         _ ->
%             {Opts2, State}
%     end.




