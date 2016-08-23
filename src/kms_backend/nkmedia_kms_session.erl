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
-export([nkmedia_session_handle_call/4]).

-export_type([config/0, type/0, opts/0, update/0]).

-define(LLOG(Type, Txt, Args, Session),
    lager:Type("NkMEDIA KMS Session ~s "++Txt, 
               [maps:get(session_id, Session) | Args])).

-include_lib("nksip/include/nksip.hrl").

-define(MAX_ICE_TIME, 100).


%% ===================================================================
%% Types
%% ===================================================================

-type session() :: nkmedia_session:session().
-type continue() :: continue | {continue, list()}.


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
    play.


-type opts() ::
    nkmedia_session:session() |
    #{
        record => boolean(),            %
        room_id => binary(),            % publish, listen
        publisher_id => binary(),       % listen
        proxy_type => webrtc | rtp      % proxy
    }.


-type update() ::
    nkmedia_session:update() |
    {listener_switch, binary()}.


-type state() ::
    #{
        kms_id => nkmedia_kms_engine:id(),
        kms_client => pid(),
        endpoint => binary(),
        source => self|{SessId::nkmedia_session:id(), EP::binary()},
        sinks => [self|{SessId::nkmedia_session:id(), EP::binary()}],
        record_pos => integer()
    }.


%% ===================================================================
%% External
%% ===================================================================

kms_event(_SessId, <<"OnIceComponentStateChanged">>, Data) ->
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
    Txt = io_lib:format("ICE State (~p:~p): ~s", [StreamId, CompId, Msg]),
    case Level of
        info ->    lager:info("~s", [Txt]);
        notice ->  lager:notice("~s", [Txt]);
        warning -> lager:warning("~s", [Txt])
    end;

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

kms_event(_SessId, Type, Data) ->
    lager:warning("NkMEDIA KMS Session: unexpected event ~s: ~p", [Type, Data]).




%% ===================================================================
%% Callbacks
%% ===================================================================


-spec init(nkmedia_session:id(), session(), state()) ->
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
    {ok, type(), map(), none|nkmedia:offer(), none|nkmedia:answer(), state()} |
    {error, term(), state()} | continue().

start(park, #{offer:=#{sdp:=SDP}}=Session, State) ->
    case create_webrtc(SDP, Session, State) of
        {ok, Answer, State2} ->
            Reply = ExtOps = #{answer=>Answer},
            {ok, Reply, ExtOps, State2};
        {error, Error} ->
            {error, Error, State}
    end;

start(echo, #{offer:=#{sdp:=SDP}}=Session, State) ->
    case create_webrtc(SDP, Session, State) of
        {ok, Answer, State2} ->
            {ok, State3} = echo(State2),
            Reply = ExtOps = #{answer=>Answer},
            {ok, Reply, ExtOps, State3};
        {error, Error} ->
            {error, Error, State}
    end;

start(echo, _Session, State) ->
    {error, missing_offer, State};

start(_Type, _Session, _State) ->
    continue.


%% @private
-spec answer(type(), nkmedia:answer(), session(), state()) ->
    {ok, map(), nkmedia:answer(), state()} |
    {error, term(), state()} | continue().

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
    ok | {error, term()}.

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
-spec update(update(), map(), type(), nkmedia:session(), state()) ->
    {ok, type(), map(), state()} |
    {error, term(), state()} | continue().

update(park, #{}, _Type, _Session, State) ->
    State2 = disconnect_all(State),
    {ok, #{}, #{}, State2};

update(echo, #{}, _Type, _Session, State) ->
    {ok, State2} = echo(State),
    {ok, #{}, #{}, State2};

update(connect, #{peer_id:=Peer}, Type, #{session_id:=Peer}=Session, State) ->
    update(echo, #{}, Type, Session, State);

update(connect, #{peer_id:=Peer}, _Type, Session, #{endpoint:=EP}=State) ->
    #{session_id:=SessId} = Session,
    case nkmedia_session:do_call(Peer, {nkmedia_kms, {connect, SessId, EP}}) of
        {ok, PeerEP} ->
            {ok, #{}, #{}, updated_source(Peer, PeerEP, State)};
        {error, Error} ->
            {error, Error, State}
    end;

% update(bridge, #{peer_id:=Peer}, Type, #{session_id:=Peer}=Session, State) ->
%     update(echo, #{}, Type, Session, State);

% update(bridge, #{peer_id:=Peer}, _Type, Session, #{endpoint:=EP}=State) ->
%     case nkmedia_session:do_call(Peer, {nkmedia_kms, {bridge, EP}}) of
%         {ok, PeerEP} ->
%             case connect(PeerEP, State) of
%                 {ok, State2} ->
%                     {ok, #{}, #{}, State2};
%                 {error, Error, State2} ->
%                     {error, Error, State2}
%             end;
%         {error, Error} ->
%             {error, Error, State}
%     end;

update(get, _Opts, _Type, _Session, State) ->
    print_info(State),
    {ok, #{}, #{}, State};


update(_Update, _Opts, _Type, _Session, _State) ->
    continue.


%% @private
-spec stop(nkservice:error(), session(), state()) ->
    {ok, state()}.

stop(_Reason, _Session, State) ->
    {ok, State}.


%% @private
nkmedia_session_handle_call({connect, Peer, PeerEP}, _From, _Session, State) ->
    case connect(Peer, PeerEP, State) of
        {ok, #{endpoint:=EP}=State2} ->
            {reply, {ok, EP}, State2};
        {error, Error, State2} ->
            {reply, {error, Error}, State2}
    end;

nkmedia_session_handle_call(get_endpoint, _From, _Session, #{endpoint:=EP}=State) ->
    {reply, {ok, EP}, State}.

% nkmedia_session_handle_call({bridge, PeerEP}, _From, _Session, State) ->
%     case connect(PeerEP, State) of
%         {ok, #{endpoint:=EP}=State2} ->
%             {reply, {ok, EP}, State2};
%         {error, Error, State2} ->
%             {reply, {error, Error}, State2}
%     end.
 




%% ===================================================================
%% Internal
%% ===================================================================


%% @private
create_webrtc(SDP, #{session_id:=SessId}=Session, State) ->
    case get_mediaserver(Session, State) of
        {ok, #{kms_id:=KmsId}=State2} ->
            {ok, EP} = nkmedia_kms_engine:create(KmsId, 'WebRtcEndpoint', SessId),
            subscribe(EP, 'OnIceComponentStateChanged', State2),
            subscribe(EP, 'OnIceCandidate', State2),
            subscribe(EP, 'OnIceGatheringDone', State2),
            {ok, SDP2} = invoke(EP, processOffer, #{offer=>SDP}, State2),
            % timer:sleep(200),
            % io:format("SDP1\n~s\n\n", [SDP]),
            % io:format("SDP2\n~s\n\n", [SDP2]),
            % Store endpoint and wait for candidates
            ok = invoke(EP, gatherCandidates, #{}, State2),
            {ok, #{sdp=>SDP2, trickle_ice=>true}, State2#{endpoint=>EP}};
        {error, Error} ->
            {error, Error}
    end.


%% @private
echo(#{endpoint:=EP}=State) ->
    case invoke(connect, #{sink=>EP}, State) of
        ok ->
            Sinks = maps:get(sinks, State, []),
            {ok, State#{source=>self, sinks=>lists:usort([self|Sinks])}};
        {error, Error, State2} ->
            {error, Error, State2}
    end.


%% @private
connect(Peer, PeerEP, State) ->
    case invoke(connect, #{sink=>PeerEP}, State) of
        ok -> 
            Sinks = maps:get(sinks, State, []),
            {ok, State#{sinks=>lists:usort([{Peer, PeerEP}|Sinks])}};
        {error, Error} -> 
            {error, Error, State}
    end.


%% @private
disconnect(PeerEP, State) ->
    case invoke(disconnect, #{sink=>PeerEP}, State) of
        ok -> 
            Sinks1 = maps:get(sinks, State, []),
            Sinks2 = lists:keydelete(PeerEP, 2, Sinks1),
            {ok, State#{sinks=>Sinks2}};
        {error, Error} -> 
            {error, Error, State}
    end.


%% @private
disconnect_all(#{endpoint:=EP}=State) ->
    case maps:get(source, State, undefined) of
        self ->
            invoke(disconnect, #{sink=>EP}, State);
        {Peer, PeerEP} ->
            nkmedia_session:do_call(Peer, {nkmedia, {disconnect, PeerEP}});
        undefined ->
            ok
    end,
    lists:foldl(
        fun
            (self, Acc) -> 
                Acc;
            ({_, PeerEP}, Acc) -> 
                case disconnect(PeerEP, Acc) of
                    {ok, Acc2} -> Acc2;
                    {error, _, Acc2} -> Acc2
                end
        end,
        State,
        maps:get(sinks, State, [])),
    State#{source=>undefined, sinks=>[]}.



%% @private
subscribe(ObjId, Type, #{kms_client:=Pid}) ->
    {ok, SubsId} = nkmedia_kms_client:subscribe(Pid, ObjId, Type),
    SubsId.


%% @private
invoke(Op, Params, #{endpoint:=EP}=State) ->
    invoke(EP, Op, Params, State).


%% @private
invoke(ObjId, Op, Params, #{kms_client:=Pid}) ->
    case nkmedia_kms_client:invoke(Pid, ObjId, Op, Params) of
        {ok, null} -> ok;
        {ok, Other} -> {ok, Other};
        {error, Error} -> {error, Error}
    end.


%% @private Called when we now our source changed
%% If we were connected to ourselves, that sink must be deleted
updated_source(Peer, SourceEP, State) ->
    Sinks1 = maps:get(sinks, State, []),
    Sinks2 = Sinks1 -- [self],
    State#{source=>{Peer, SourceEP}, sinks=>Sinks2}.




%% @private
print_info(#{endpoint:=EP}=State) ->
    io:format("\nEP: ~s\n", [get_id(EP)]),
    io:format("\nMy source: ~p\n", [maps:get(source, State, undefined)]),
    io:format("My sinks: ~p\n\n", [maps:get(sinks, State, [])]),
    io:format("Sources:\n"),
    {ok, Sources} = invoke(getSourceConnections, #{}, State),
    lists:foreach(
        fun(#{<<"type">>:=Type, <<"source">>:=Source, <<"sink">>:=Sink}) ->
            io:format("~s: ~s -> ~s\n", [Type, get_id(Source), get_id(Sink)])
        end,
        Sources),
    io:format("\nSinks:\n"),
    {ok, Sinks} = invoke(getSinkConnections, #{}, State),
    lists:foreach(
        fun(#{<<"type">>:=Type, <<"source">>:=Source, <<"sink">>:=Sink}) ->
            io:format("~s: ~s -> ~s\n", [Type, get_id(Source), get_id(Sink)])
        end,
        Sinks),

    {ok, MediaState} = invoke(getMediaState, #{}, State),
    io:format("\nMediaState: ~p\n", [MediaState]),
    {ok, ConnectionState} = invoke(getConnectionState, #{}, State),
    io:format("Connectiontate: ~p\n", [ConnectionState]),

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


    



    {ok, IsMediaFlowingIn1} = invoke(isMediaFlowingIn, #{mediaType=>'AUDIO'}, State),
    io:format("\nIsMediaFlowingIn AUDIO: ~p\n", [IsMediaFlowingIn1]),
    {ok, IsMediaFlowingOut1} = invoke(isMediaFlowingOut, #{mediaType=>'AUDIO'}, State),
    io:format("IsMediaFlowingOut AUDIO: ~p\n", [IsMediaFlowingOut1]),
    {ok, IsMediaFlowingIn2} = invoke(isMediaFlowingIn, #{mediaType=>'VIDEO'}, State),
    io:format("\nIsMediaFlowingIn VIDEO: ~p\n", [IsMediaFlowingIn2]),
    {ok, IsMediaFlowingOut2} = invoke(isMediaFlowingOut, #{mediaType=>'VIDEO'}, State),
    io:format("IsMediaFlowingOut VIDEO: ~p\n", [IsMediaFlowingOut2]),
    
    % Convert with dot -Tpdf gstreamer.dot -o 1.pdf
    % {ok, GstreamerDot} = invoke(getGstreamerDot, #{}, State),
    % file:write_file("/tmp/gstreamer.dot", GstreamerDot),


    ok.








%% @private
-spec get_mediaserver(session(), state()) ->
    {ok, state()} | {error, term()}.

get_mediaserver(_Session, #{kms_id:=_}=State) ->
    {ok, State};

get_mediaserver(#{srv_id:=SrvId}, State) ->
    case SrvId:nkmedia_kms_get_mediaserver(SrvId) of
        {ok, KmsId} ->
            {ok, Pid} = nkmedia_kms_engine:get_client(KmsId),
            {ok, State#{kms_id=>KmsId, kms_client=>Pid}};
        {error, Error} ->
            {error, Error}
    end.


%% @private
get_id(Ep) ->
    case binary:split(Ep, <<"/">>) of
        [_, Id] -> Id;
        _ -> Ep
    end.



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




