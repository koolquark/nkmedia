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

%% @doc Session Management Utilities
-module(nkmedia_kms_session_lib).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([kms_event/3]).
-export([get_mediaserver/2, get_pipeline/1, stop_endpoint/1]).
-export([create_webrtc/3, create_rtp/3]).
-export([add_ice_candidate/2, set_answer/2]).
-export([create_recorder/3, recorder_op/2]).
-export([create_player/4, player_op/2]).
-export([update_media/2, get_stats/2]).
-export([connect/3, disconnect_all/1, release/1]).
-export([get_create_medias/1]).
-export([invoke/3, invoke/4]).
-export([print_info/2]).

-define(LLOG(Type, Txt, Args, SessId),
    lager:Type("NkMEDIA KMS Session ~s "++Txt, [SessId| Args])).

-include_lib("nksip/include/nksip.hrl").

-define(MAX_ICE_TIME, 100).


%% ===================================================================
%% Types
%% ===================================================================

-type id() :: binary().
-type endpoint() :: nkmedia_kms_session:binary().

% AUDIO, VIDEO, DATA
-type media_type() :: nkmedia_kms_session:binary(). 

-type state() :: nkmedia_kms_session:state().



%% ===================================================================
%% External
%% ===================================================================

%% @private Called from nkmedia_kms_client when it founds a SessId in the event
-spec kms_event(nkmedia_session:id(), binary(), map()) ->
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

kms_event(SessId, <<"Error">>, Data) ->
    #{
        <<"description">> := Desc,
        <<"errorCode">> := Code, 
        <<"type">> := Type              % <<"INVALID_URI">>
    } = Data,
    nkmedia_session:do_cast(SessId, {nkmedia_kms, {kms_error, Type, Code, Desc}});

kms_event(SessId, Type, Data) ->
    print_event(SessId, Type, Data).




%% ===================================================================
%% Public
%% ===================================================================

%% @private
-spec get_mediaserver(nkservice:id(), state()) ->
    {ok, state()} | {error, nkservice:error()}.

get_mediaserver(_SrvId, #{kms_id:=_}=State) ->
    {ok, State};

get_mediaserver(SrvId, State) ->
    case SrvId:nkmedia_kms_get_mediaserver(SrvId) of
        {ok, KmsId} ->
            get_pipeline(State#{kms_id=>KmsId});
        {error, Error} ->
            {error, Error}
    end.


%% @private
-spec get_pipeline(state()) ->
    {ok, state()} | {error, nkservice:error()}.

get_pipeline(#{kms_id:=KmsId}=State) ->
    case nkmedia_kms_engine:get_pipeline(KmsId) of
        {ok, Pipeline} ->
            {ok, State#{pipeline=>Pipeline}};
        {error, Error} ->
            {error, Error}
    end.


%% @private
-spec stop_endpoint(state()) ->
    ok.

stop_endpoint(State) ->
    release(State).


%% @private
-spec create_webrtc(id(), nkmedia:offer()|#{}, state()) ->
    {ok, nkmedia:offer()|nkmedia:answer(), state()} | {error, nkservice:error()}.

create_webrtc(SessId, Offer, State) ->
    case create_endpoint(SessId, 'WebRtcEndpoint', #{}, State) of
        {ok, EP} ->
            State2 = State#{endpoint=>EP, endpoint_type=>webrtc},
            subscribe('Error', State2),
            subscribe('OnIceComponentStateChanged', State2),
            subscribe('OnIceCandidate', State2),
            subscribe('OnIceGatheringDone', State2),
            subscribe('NewCandidatePairSelected', State2),
            subscribe('MediaStateChanged', State2),
            subscribe('MediaFlowInStateChange', State2),
            subscribe('MediaFlowOutStateChange', State2),
            subscribe('ConnectionStateChanged', State2),
            subscribe('ElementConnected', State2),
            subscribe('ElementDisconnected', State2),
            subscribe('MediaSessionStarted', State2),
            subscribe('MediaSessionTerminated', State2),
            case Offer of
                #{sdp:=SDP} ->
                    {ok, SDP2} = invoke(processOffer, #{offer=>SDP}, State2);
                _ ->
                    {ok, SDP2} = invoke(generateOffer, #{}, State2)
            end,
            ok = invoke(gatherCandidates, #{}, State2),
            {ok, Offer#{sdp=>SDP2, trickle_ice=>true, sdp_type=>webrtc}, State2};
        {error, Error} ->
           {error, Error}
    end.


%% @private
-spec create_rtp(id(), nkmedia:offer()|#{}, state()) ->
    {ok, nkmedia:offer()|nkmedia:answer(), state()} | {error, nkservice:error()}.

create_rtp(SessId, Offer, State) ->
    case create_endpoint(SessId, 'RtpEndpoint', #{}, State) of
        {ok, EP} ->
            State2 = State#{endpoint=>EP, endpoint_type=>rtp},
            subscribe('Error', State2),
            subscribe('MediaStateChanged', State2),
            subscribe('MediaFlowInStateChange', State2),
            subscribe('MediaFlowOutStateChange', State2),
            subscribe('ConnectionStateChanged', State2),
            subscribe('ElementConnected', State2),
            subscribe('ElementDisconnected', State2),
            subscribe('MediaSessionStarted', State2),
            subscribe('MediaSessionTerminated', State2),
            % subscribe('ObjectCreated', State2),
            % subscribe('ObjectDestroyed', State2),
            case Offer of
                #{offer:=#{sdp:=SDP}} ->
                    {ok, SDP2} = invoke(processOffer, #{offer=>SDP}, State2);
                _ ->
                    {ok, SDP2} = invoke(generateOffer, #{}, State2)
            end,
            {ok, Offer#{sdp=>SDP2, sdp_type=>rtp}, State2};
        {error, Error} ->
           {error, Error}
    end.


%% @private
-spec set_answer(nkmedia:answer(), state()) ->
    ok | {error, nkservice:error()}.

set_answer(#{sdp:=SDP}, State) ->
    invoke(processAnswer, #{offer=>SDP}, State).


%% @private
-spec add_ice_candidate(nkmedia:candidate(), state()) ->
    ok | {error, nkservice:error()}.

add_ice_candidate(Candidate, State) ->
    #candidate{m_id=MId, m_index=MIndex, a_line=ALine} = Candidate,
    Data = #{
        sdpMid => MId,
        sdpMLineIndex => MIndex,
        candidate => ALine
    },
    ok = invoke(addIceCandidate, #{candidate=>Data}, State).




%% @private
%% Recorder supports record, pause, stop, stopAndWait
%% Profiles: KURENTO_SPLIT_RECORDER , MP4, MP4_AUDIO_ONLY, MP4_VIDEO_ONLY, 
%%           WEBM, WEBM_AUDIO_ONLY, WEBM_VIDEO_ONLY, JPEG_VIDEO_ONLY
-spec create_recorder(id(), map(), state()) ->
    {ok, state()} | {error, nkservice:error(), state()}.

create_recorder(Id, Opts, #{recorder:=_}=State) ->
    {ok, State2} = recorder_op(stop, State),
    create_recorder(Id, Opts, maps:remove(recorder, State2));

create_recorder(Id, Opts, #{endpoint:=EP}=State) ->
    Medias = lists:flatten([
        case maps:get(use_audio, Opts, true) of
            true -> <<"AUDIO">>;
            _ -> []
        end,
        case maps:get(use_video, Opts, true) of
            true -> <<"VIDEO">>;
            _ -> []
        end
    ]),
    {Uri, State2} = case maps:find(uri, Opts) of
        {ok, Uri0} -> {Uri0, State};
        error -> make_record_uri(Id, State)
    end,
    Profile = maps:get(mediaProfile, Opts, <<"WEBM">>),
    Params = #{uri=>nklib_util:to_binary(Uri), mediaProfile=>Profile},
    lager:notice("Started recording: ~p", [Params]),
    case create_endpoint(Id, 'RecorderEndpoint', Params, State2) of
        {ok, ObjId} ->
            subscribe(ObjId, 'Error', State2),
            subscribe(ObjId, 'Paused', State2),
            subscribe(ObjId, 'Stopped', State2),
            subscribe(ObjId, 'Recording', State2),
            ok = do_connect(EP, ObjId, Medias, State),
            ok = invoke(ObjId, record, #{}, State2),
            {ok, State2#{recorder=>ObjId}};
        {error, Error} ->
           {error, Error}
    end.


%% @private
-spec make_record_uri(id(), state()) ->
    {binary(), state()}.

make_record_uri(Id, State) ->
    Pos = maps:get(record_pos, State, 0),
    Name = io_lib:format("~s_p~4..0w.webm", [Id, Pos]),
    File = filename:join(<<"/tmp/record">>, list_to_binary(Name)),
    {<<"file://", File/binary>>, State#{record_pos=>Pos+1}}.


%% @private
-spec recorder_op(atom(), state()) ->
    {ok, state()} | {error, nkservice:error()}.

recorder_op(pause, #{recorder:=RecorderEP}=State) ->
    ok = invoke(RecorderEP, pause, #{}, State),
    {ok, State};

recorder_op(resume, #{recorder:=RecorderEP}=State) ->
    ok = invoke(RecorderEP, record, #{}, State),
    {ok, State};

recorder_op(stop, #{recorder:=RecorderEP}=State) ->
    invoke(RecorderEP, stop, #{}, State),
    release(RecorderEP, State),
    {ok, maps:remove(recorder, State)};

recorder_op(_, #{recorder:=_}) ->
    {error, invalid_operation};

recorder_op(_, _State) ->
    {error, no_active_recorder}.


%% @private
%% Player supports play, pause, stop, getPosition, getVideoInfo, setPosition (position)
-spec create_player(id(), binary(), map(), state()) ->
    {ok, state()} | {error, nkservice:error(), state()}.

create_player(Id, Uri, Opts, #{player:=_}=State) ->
    lager:error("P1"),
    {ok, State2} = player_op(stop, State),
    create_player(Id, Uri, Opts, maps:remove(player, State2));

create_player(Id, Uri, Opts, #{endpoint:=EP}=State) ->
    Medias = lists:flatten([
        case maps:get(use_audio, Opts, true) of
            true -> <<"AUDIO">>;
            _ -> []
        end,
        case maps:get(use_video, Opts, true) of
            true -> <<"VIDEO">>;
            _ -> []
        end
    ]),
    Params = #{uri=>nklib_util:to_binary(Uri)},
    case create_endpoint(Id, 'PlayerEndpoint', Params, State) of
        {ok, ObjId} ->
            subscribe(ObjId, 'Error', State),
            subscribe(ObjId, 'EndOfStream', State),
            ok = do_connect(ObjId, EP, Medias, State),
            ok = invoke(ObjId, play, #{}, State),
            {ok, State#{player=>ObjId}};
        {error, Error} ->
           {error, Error, State}
    end.


%% @private
-spec player_op(term(), state()) ->
    {ok, state()} | {ok, term(), state()} | {error, nkservice:error()}.

player_op(pause, #{player:=PlayerEP}=State) ->
    ok = invoke(PlayerEP, pause, #{}, State),
    {ok, State};

player_op(resume, #{player:=PlayerEP}=State) ->
    ok = invoke(PlayerEP, play, #{}, State),
    {ok, State};

player_op(stop, #{player:=PlayerEP}=State) ->
    invoke(PlayerEP, stop, #{}, State),
    release(PlayerEP, State),
    {ok, maps:remove(player, State)};

player_op(get_info, #{player:=PlayerEP}=State) ->
    {ok, Data} = invoke(PlayerEP, getVideoInfo, #{}, State),
    case Data of
        #{
            <<"duration">> := Duration,
            <<"isSeekable">> := IsSeekable,
            <<"seekableInit">> := Start,
            <<"seekableEnd">> := Stop
        } ->
            Data2 = #{
                duration => Duration,
                is_seekable => IsSeekable,
                first_position => Start,
                last_position => Stop
            },
            {ok, #{player_info=>Data2}, State};
        _ ->
            lager:error("Unknown player info: ~p", [Data]),
            {ok, #{}, State}
    end;

player_op(get_position, #{player:=PlayerEP}=State) ->
    case invoke(PlayerEP, getPosition, #{}, State) of
        {ok, Pos}  ->
            {ok, #{position=>Pos}, State};
        {error, Error} ->
            {error, Error}
    end;

player_op({set_position, Pos}, #{player:=PlayerEP}=State) ->
    case invoke(PlayerEP, setPosition, #{position=>Pos}, State) of
        ok ->
            {ok, State};
        {error, Error} ->
            {error, Error}
    end;

player_op(_, #{player:=_}) ->
    {error, invalid_operation};

player_op(_, _State) ->
    {error, no_active_player}.


%% @private
-spec get_stats(binary(), state()) ->
    {ok, map()}.

get_stats(Type, State) 
        when Type == <<"AUDIO">>; Type == <<"VIDEO">>; Type == <<"DATA">> ->
    {ok, _Stats} = invoke(getStats, #{mediaType=>Type}, State);

get_stats(Type, _State) ->
    {error, {invalid_value, Type}}.


%% @private
-spec create_endpoint(id(), atom(), map(), state()) ->
    {ok, endpoint()} | {error, nkservice:error()}.

create_endpoint(Id, Type, Params, State) ->
    #{kms_id:=KmsId, pipeline:=Pipeline} = State,
    Params2 = Params#{mediaPipeline=>Pipeline},
    Properties = #{pkey1 => pval1},
    case nkmedia_kms_client:create(KmsId, Type, Params2, Properties) of
        {ok, ObjId} ->
            ok = invoke(ObjId, addTag, #{key=>nkmedia, value=>Id}, State),
            ok = invoke(ObjId, setSendTagsInEvents, #{sendTagsInEvents=>true}, State),
            {ok, ObjId};
        {error, Error} ->
            {error, Error}
    end.



%% @private
%% If you remove all medias, you can not connect again any media
%% (the hole connection is d)
-spec update_media(map(), state()) ->
    ok.

update_media(Opts, #{endpoint:=EP}=State) ->
    case get_update_medias(Opts) of
        {[], []} ->
            ok;
        {Add, Remove} ->
            lists:foreach(
                fun(PeerEP) ->
                    % lager:error("Source ~s: A: ~p, R: ~p", [PeerEP, Add, Remove]),
                    do_connect(PeerEP, EP, Add, State),
                    do_disconnect(PeerEP, EP, Remove, State)
                end,
                maps:keys(get_sources(State))),
            lists:foreach(
                fun(PeerEP) ->
                    % lager:error("Sink ~s: A: ~p, R: ~p", [PeerEP, Add, Remove]),
                    do_connect(EP, PeerEP, Add, State),
                    do_disconnect(EP, PeerEP, Remove, State)
                end,
                maps:keys(get_sinks(State)))
    end.


%% @private
%% Connects a remote Endpoint to us as sink
%% We can select the medias to use, or use a map() with options, and all medias
%% will be include except the ones that have 'use' false.
-spec connect(endpoint(), [media_type()], state()) ->
    ok | {error, nkservice:error()}.

connect(PeerEP, Opts, State) when is_map(Opts) ->
    Medias = get_create_medias(Opts),
    connect(PeerEP, Medias, State);

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
-spec disconnect_all(state()) ->
    ok.

disconnect_all(#{endpoint:=EP}=State) ->
    lists:foreach(
        fun(PeerEP) -> invoke(PeerEP, disconnect, #{sink=>EP}, State) end,
        maps:keys(get_sources(State))),
    lists:foreach(
        fun(PeerEP) -> invoke(EP, disconnect, #{sink=>PeerEP}, State) end,
        maps:keys(get_sinks(State)));

disconnect_all(_State) ->
    ok.


%% @private
-spec subscribe(atom(), state()) ->
    SubsId::binary().

subscribe(Type, #{endpoint:=EP}=State) ->
    subscribe(EP, Type, State).


%% @private
-spec subscribe(endpoint(), atom(), state()) ->
    SubsId::binary().

subscribe(ObjId, Type, #{kms_id:=KmsId}) ->
    {ok, SubsId} = nkmedia_kms_client:subscribe(KmsId, ObjId, Type),
    SubsId.


%% @private
-spec invoke(atom(), map(), state()) ->
    ok | {ok, term()} | {error, nkservice:error()}.

invoke(Op, Params, #{endpoint:=EP}=State) ->
    invoke(EP, Op, Params, State).


%% @private
-spec invoke(endpoint(), atom(), map(), state()) ->
    ok | {ok, term()} | {error, nkservice:error()}.

invoke(ObjId, Op, Params, #{kms_id:=KmsId}) ->
    case nkmedia_kms_client:invoke(KmsId, ObjId, Op, Params) of
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
 
release(ObjId, #{kms_id:=KmsId}) ->
    nkmedia_kms_client:release(KmsId, ObjId).


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
%% All medias will be included, except if "use_XXX=false"
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
print_info(SessId, #{endpoint:=EP}=State) ->
    io:format("Id: ~s\n", [SessId]),
    io:format("EP: ~s\n", [get_id(EP)]),
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
    io:format("\nMediaState: ~s\n", [MediaState]),
    {ok, ConnectionState} = invoke(getConnectionState, #{}, State),
    io:format("ConnectionState: ~s\n", [ConnectionState]),

    {ok, IsMediaFlowingIn1} = invoke(isMediaFlowingIn, #{mediaType=>'AUDIO'}, State),
    io:format("IsMediaFlowingIn AUDIO: ~p\n", [IsMediaFlowingIn1]),
    {ok, IsMediaFlowingOut1} = invoke(isMediaFlowingOut, #{mediaType=>'AUDIO'}, State),
    io:format("IsMediaFlowingOut AUDIO: ~p\n", [IsMediaFlowingOut1]),
    {ok, IsMediaFlowingIn2} = invoke(isMediaFlowingIn, #{mediaType=>'VIDEO'}, State),
    io:format("IsMediaFlowingIn VIDEO: ~p\n", [IsMediaFlowingIn2]),
    {ok, IsMediaFlowingOut2} = invoke(isMediaFlowingOut, #{mediaType=>'VIDEO'}, State),
    io:format("IsMediaFlowingOut VIDEO: ~p\n", [IsMediaFlowingOut2]),

    {ok, MinVideoRecvBandwidth} = invoke(getMinVideoRecvBandwidth, #{}, State),
    io:format("MinVideoRecvBandwidth: ~p\n", [MinVideoRecvBandwidth]),
    {ok, MinVideoSendBandwidth} = invoke(getMinVideoSendBandwidth, #{}, State),
    io:format("MinVideoSendBandwidth: ~p\n", [MinVideoSendBandwidth]),
    {ok, MaxVideoRecvBandwidth} = invoke(getMaxVideoRecvBandwidth, #{}, State),
    io:format("MaxVideoRecvBandwidth: ~p\n", [MaxVideoRecvBandwidth]),
    {ok, MaxVideoSendBandwidth} = invoke(getMaxVideoSendBandwidth, #{}, State),
    io:format("MaxVideoSendBandwidth: ~p\n", [MaxVideoSendBandwidth]),
    
    {ok, MaxAudioRecvBandwidth} = invoke(getMaxAudioRecvBandwidth, #{}, State),
    io:format("MaxAudioRecvBandwidth: ~p\n", [MaxAudioRecvBandwidth]),
    
    {ok, MinOutputBitrate} = invoke(getMinOutputBitrate, #{}, State),
    io:format("MinOutputBitrate: ~p\n", [MinOutputBitrate]),
    {ok, MaxOutputBitrate} = invoke(getMaxOutputBitrate, #{}, State),
    io:format("MaxOutputBitrate: ~p\n", [MaxOutputBitrate]),

    % {ok, RembParams} = invoke(getRembParams, #{}, State),
    % io:format("\nRembParams: ~p\n", [RembParams]),
    
    % Convert with dot -Tpdf gstreamer.dot -o 1.pdf
    % {ok, GstreamerDot} = invoke(getGstreamerDot, #{}, State),
    % file:write_file("/tmp/gstreamer.dot", GstreamerDot),
    ok.



%% @private
-spec print_event(id(), binary(), map()) ->
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
        info ->    ?LLOG(info, "~s", [Txt], SessId);
        notice ->  ?LLOG(notice, "~s", [Txt], SessId);
        warning -> ?LLOG(warning, "~s", [Txt], SessId)
    end;

print_event(SessId, <<"MediaSessionStarted">>, _Data) ->
    ?LLOG(info, "event media session started: ~p", [_Data], SessId);

print_event(SessId, <<"ElementConnected">>, Data) ->
    #{
        <<"mediaType">> := Type, 
        <<"sink">> := Sink,
        <<"source">> := Source
    } = Data,
    ?LLOG(info, "event element connected ~s: ~s -> ~s", 
           [Type, get_id(Source), get_id(Sink)], SessId);

print_event(SessId, <<"ElementDisconnected">>, Data) ->
    #{
        <<"mediaType">> := Type, 
        <<"sink">> := Sink,
        <<"source">> := Source
    } = Data,
    ?LLOG(info, "event element disconnected ~s: ~s -> ~s", 
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
    ?LLOG(notice, "candidate selected (~p:~p) local: ~s remote: ~s", 
           [StreamId, CompId, Local, Remote], SessId);

print_event(SessId, <<"ConnectionStateChanged">>, Data) ->
    #{
        <<"newState">> := New,
        <<"oldState">> := Old
    } = Data,
    ?LLOG(info, "event connection state changed (~s -> ~s)", [Old, New], SessId);

print_event(SessId, <<"MediaFlowOutStateChange">>, Data) ->
    #{
        <<"mediaType">> := Type, 
        <<"padName">> := _Pad,
        <<"state">> := State
    }  = Data,
    ?LLOG(info, "event media flow out state change (~s: ~s)", [Type, State], SessId);

print_event(SessId, <<"MediaFlowInStateChange">>, Data) ->
    #{
        <<"mediaType">> := Type, 
        <<"padName">> := _Pad,
        <<"state">> := State
    }  = Data,
    ?LLOG(info, "event media in out state change (~s: ~s)", [Type, State], SessId);    

print_event(SessId, <<"MediaStateChanged">>, Data) ->
    #{
        <<"newState">> := New,
        <<"oldState">> := Old
    } = Data,
    ?LLOG(info, "event media state changed (~s -> ~s)", [Old, New], SessId);

print_event(SessId, <<"Recording">>, _Data) ->
    ?LLOG(info, "event 'recording'", [], SessId);

print_event(SessId, <<"Paused">>, _Data) ->
    ?LLOG(info, "event 'paused recording'", [], SessId);

print_event(SessId, <<"Stopped">>, _Data) ->
    ?LLOG(info, "event 'stopped recording'", [], SessId);

print_event(_SessId, Type, Data) ->
    lager:warning("NkMEDIA KMS Session: unknown event ~s: ~p", [Type, Data]).
