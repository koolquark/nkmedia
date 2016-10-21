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
-export([get_mediaserver/1, get_pipeline/1, release_all/1]).
-export([create_proxy/1, create_webrtc/2, create_rtp/2]).
-export([add_ice_candidate/2, set_answer/2]).
-export([recorder_op/3, player_op/3]).
-export([update_media/2, get_stats/2]).
-export([connect_from/3, connect_to_proxy/2, park/1]).
-export([print_info/2]).

-define(LLOG(Type, Txt, Args, Session),
    lager:Type("NkMEDIA KMS Session ~s "++Txt, 
                [
                    case is_map(Session) of 
                        true -> maps:get(session_id, Session); 
                        false -> Session 
                    end
                    | Args
                ])).

-include_lib("nksip/include/nksip.hrl").
-include("../../include/nkmedia.hrl").

-define(MAX_ICE_TIME, 100).

-define(ALL_MEDIAS, [<<"AUDIO">>, <<"VIDEO">>, <<"DATA">>]).


%% ===================================================================
%% Types
%% ===================================================================

-type session_id() :: nkmedia_session:id().
-type session() :: nkmedia_kms_session:session().
-type endpoint() :: binary().

% AUDIO, VIDEO, DATA
-type media_type() :: binary(). 



%% ===================================================================
%% External
%% ===================================================================

%% @private Called from nkmedia_kms_client when it founds a SessId in the event
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
    % nkmedia_session:do_cast(SessId, {nkmedia_kms, Candidate});
    nkmedia_session:backend_candidate(SessId, Candidate);

kms_event(SessId, <<"OnIceGatheringDone">>, _Data) ->
    Candidate = #candidate{last=true},
    % nkmedia_session:do_cast(SessId, {nkmedia_kms, Candidate});
    nkmedia_session:backend_candidate(SessId, Candidate);

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
-spec get_mediaserver(session()) ->
    {ok, session()} | {error, nkservice:error()}.

get_mediaserver(#{nkmedia_kms_id:=_}=Session) ->
    {ok, Session};

get_mediaserver(#{srv_id:=SrvId}=Session) ->
    case SrvId:nkmedia_kms_get_mediaserver(SrvId) of
        {ok, KmsId} ->
            get_pipeline(?SESSION(#{nkmedia_kms_id=>KmsId}, Session));
        {error, Error} ->
            {error, Error}
    end.


%% @private
-spec get_pipeline(session()) ->
    {ok, session()} | {error, nkservice:error()}.

get_pipeline(#{nkmedia_kms_id:=KmsId}=Session) ->
    case nkmedia_kms_engine:get_pipeline(KmsId) of
        {ok, Pipeline} ->
            {ok, ?SESSION(#{nkmedia_kms_pipeline=>Pipeline}, Session)};
        {error, Error} ->
            {error, Error}
    end.


%% @private
-spec release_all(session()) ->
    ok.

release_all(Session) ->
    case Session of
        #{nkmedia_kms_recorder:=Recorder} -> 
            release(Recorder, Session);
        _ -> 
            ok
    end,
    case Session of
        #{nkmedia_kms_player:=Player} -> 
            release(Player, Session);
        _ -> 
            ok
    end,
    case Session of
        #{nkmedia_kms_proxy:=Proxy} -> 
            release(Proxy, Session);
        _ -> 
            ok
    end,
    case Session of
        #{nkmedia_kms_endpoint:=EP} -> 
            release(EP, Session);
        _ -> 
            ok
    end,
    ok.


%% @private
%% The proxy is used for outbound media, to be able to "mute" audio and video,
%% important for "publisher"
%% Also, the recorder always follows what I am sending to the proxy
-spec create_proxy(session()) ->
    {ok, session()} | {error, nkservice:error()}.

create_proxy(#{nkmedia_kms_id:=KmsId, nkmedia_kms_pipeline:=Pipeline}=Session) ->
    Params = #{mediaPipeline=>Pipeline},
    case nkmedia_kms_client:create(KmsId, 'PassThrough', Params, #{}) of
        {ok, ObjId} ->
            {ok, ?SESSION(#{nkmedia_kms_proxy=>ObjId}, Session)};
        {error, Error} ->
            {error, Error}
    end.


%% @private
-spec create_webrtc(nkmedia:offer()|#{}, session()) ->
    {ok, session()} | {error, nkservice:error()}.

create_webrtc(Offer, Session) ->
    case create_endpoint('WebRtcEndpoint', #{}, Session) of
        {ok, EP} ->
            Update1 = #{nkmedia_kms_endpoint=>EP, nkmedia_kms_endpoint_type=>webrtc},
            Session2 = ?SESSION(Update1, Session),
            subscribe(EP, 'Error', Session2),
            subscribe(EP, 'OnIceComponentStateChanged', Session2),
            subscribe(EP, 'OnIceCandidate', Session2),
            subscribe(EP, 'OnIceGatheringDone', Session2),
            subscribe(EP, 'NewCandidatePairSelected', Session2),
            subscribe(EP, 'MediaStateChanged', Session2),
            subscribe(EP, 'MediaFlowInStateChange', Session2),
            subscribe(EP, 'MediaFlowOutStateChange', Session2),
            subscribe(EP, 'ConnectionStateChanged', Session2),
            subscribe(EP, 'ElementConnected', Session2),
            subscribe(EP, 'ElementDisconnected', Session2),
            subscribe(EP, 'MediaSessionStarted', Session2),
            subscribe(EP, 'MediaSessionTerminated', Session2),
            Base = Offer#{
                sdp_type => webrtc, 
                trickle_ice => true,
                backend => nkmedia_kms
            },
            Update2 = case Offer of
                #{sdp:=SDP} ->
                    {ok, SDP2} = invoke(EP, processOffer, #{offer=>SDP}, Session2),
                    #{
                        answer => Base#{sdp=>SDP2},
                        nkmedia_kms_role => offeree
                    };
                _ ->
                    {ok, SDP2} = invoke(EP, generateOffer, #{}, Session2),
                    #{
                        offer => Base#{sdp=>SDP2},
                        nkmedia_kms_role => offerer
                    }
            end,
            ok = invoke(EP, gatherCandidates, #{}, Session2),
            {ok, ?SESSION(Update2, Session2)};
        {error, Error} ->
           {error, Error}
    end.


%% @private
-spec create_rtp(nkmedia:offer()|#{}, session()) ->
    {ok, session()} | {error, nkservice:error()}.

create_rtp(Offer, Session) ->
    case create_endpoint('RtpEndpoint', #{}, Session) of
        {ok, EP} ->
            Update = #{nkmedia_kms_endpoint=>EP, nkmedia_kms_endpoint_type=>rtp},
            Session2 = ?SESSION(Update, Session),
            subscribe(EP, 'Error', Session2),
            subscribe(EP, 'MediaStateChanged', Session2),
            subscribe(EP, 'MediaFlowInStateChange', Session2),
            subscribe(EP, 'MediaFlowOutStateChange', Session2),
            subscribe(EP, 'ConnectionStateChanged', Session2),
            subscribe(EP, 'ElementConnected', Session2),
            subscribe(EP, 'ElementDisconnected', Session2),
            subscribe(EP, 'MediaSessionStarted', Session2),
            subscribe(EP, 'MediaSessionTerminated', Session2),
            Base = Offer#{
                sdp_type => rtp, 
                trickle_ice => false,
                backend => nkmedia_kms
            },
            Session3 = case Offer of
                #{sdp:=SDP} ->
                    {ok, SDP2} = invoke(EP, processOffer, #{offer=>SDP}, Session2),
                    ?SESSION(#{answer=>Base#{sdp=>SDP2}}, Session2);
                _ ->
                    {ok, SDP2} = invoke(EP, generateOffer, #{}, Session2),
                    ?SESSION(#{offer=>Base#{sdp=>SDP2}}, Session2)
            end,
            {ok, Session3};
        {error, Error} ->
           {error, Error}
    end.


%% @private
-spec set_answer(nkmedia:answer(), session()) ->
    ok | {error, nkservice:error()}.

set_answer(#{sdp:=SDP}, #{nkmedia_kms_endpoint:=EP}=Session) ->
    case invoke(EP, processAnswer, #{answer=>SDP}, Session) of
        {ok, _SDP2} -> 
            ok;
        {error, Error} ->
            {error, Error}
    end.


%% @private
-spec add_ice_candidate(nkmedia:candidate(), session()) ->
    ok | {error, nkservice:error()}.

add_ice_candidate(Candidate, #{nkmedia_kms_endpoint:=EP}=Session) ->
    #candidate{m_id=MId, m_index=MIndex, a_line=ALine} = Candidate,
    Data = #{
        sdpMid => MId,
        sdpMLineIndex => MIndex,
        candidate => ALine
    },
    ok = invoke(EP, addIceCandidate, #{candidate=>Data}, Session).


%% @private
%% Recorder supports record, pause, stop, stopAndWait
%% Profiles: KURENTO_SPLIT_RECORDER , MP4, MP4_AUDIO_ONLY, MP4_VIDEO_ONLY, 
%%           WEBM, WEBM_AUDIO_ONLY, WEBM_VIDEO_ONLY, JPEG_VIDEO_ONLY
-spec recorder_op(atom(), map(), session()) ->
    {ok, map(), session()} | {error, nkservice:error(), session()}.

recorder_op(start, Opts, #{nkmedia_kms_recorder:=_}=Session) ->
    {ok, _, Session2} = recorder_op(stop, Opts, Session),
    recorder_op(start, Opts, ?SESSION_RM(nkmedia_kms_recorder, Session2));

recorder_op(start, #{uri:=Uri}=Opts, #{nkmedia_kms_proxy:=Proxy}=Session) ->
    Profile = maps:get(mediaProfile, Opts, <<"WEBM">>),
    Params = #{uri=>nklib_util:to_binary(Uri), mediaProfile=>Profile},
    ?LLOG(notice, "started recording: ~p", [Params], Session),
    case create_endpoint('RecorderEndpoint', Params, Session) of
        {ok, ObjId} ->
            subscribe(ObjId, 'Error', Session),
            subscribe(ObjId, 'Paused', Session),
            subscribe(ObjId, 'Stopped', Session),
            subscribe(ObjId, 'Recording', Session),
            ok = do_connect(Proxy, ObjId, all, Session),
            ok = invoke(ObjId, record, #{}, Session),
            {ok, Params, ?SESSION(#{nkmedia_kms_recorder=>ObjId}, Session)};
        {error, Error} ->
           {error, Error, Session}
    end;

recorder_op(start, Opts, Session) ->
    {Uri, Session2} = make_record_uri(Session),
    recorder_op(start, Opts#{uri=>Uri}, Session2);

recorder_op(pause, _Opts, #{nkmedia_kms_recorder:=RecorderEP}=Session) ->
    ok = invoke(RecorderEP, pause, #{}, Session),
    {ok, #{}, Session};

recorder_op(resume, _Opts, #{nkmedia_kms_recorder:=RecorderEP}=Session) ->
    ok = invoke(RecorderEP, record, #{}, Session),
    {ok, #{}, Session};

recorder_op(stop, _Opts, #{nkmedia_kms_recorder:=RecorderEP}=Session) ->
    invoke(RecorderEP, stop, #{}, Session),
    release(RecorderEP, Session),
    {ok, #{}, ?SESSION_RM(nkmedia_kms_recorder, Session)};

recorder_op(get_actions, _Opts, Session) ->
    {ok, #{actions=>[start, stop, pause, resume, get_actions]}, Session};

recorder_op(Action, _Opts, #{nkmedia_kms_recorder:=_}=Session) ->
    {error, {invalid_action, Action}, Session};

recorder_op(_, _Opts, Session) ->
    {error, no_active_recorder, Session}.


%% @private
-spec make_record_uri(session()) ->
    {binary(), session()}.

make_record_uri(Session) ->
    {Name, Session2} = nkmedia_session:get_session_file(Session),
    File = filename:join(<<"/tmp/record">>, Name),
    {<<"file://", File/binary>>, Session2}.


%% @private
%% Player supports play, pause, stop, getPosition, getVideoInfo, setPosition (position)
-spec player_op(term(), map(), session()) ->
    {ok, term(), session()} | {error, nkservice:error(), session()}.

player_op(start, Opts, #{nkmedia_kms_player:=_}=Session) ->
    {ok, _, Session2} = player_op(stop, Opts, Session),
    player_op(start, Opts, ?SESSION_RM(nkmedia_kms_player, Session2));

player_op(start, #{uri:=Uri}=Opts, Session) ->
    Medias = lists:flatten([
        case maps:get(mute_audio, Opts, false) of
            false -> <<"AUDIO">>;
            _ -> []
        end,
        case maps:get(mute_video, Opts, false) of
            false -> <<"VIDEO">>;
            _ -> []
        end
    ]),
    Params = #{uri=>nklib_util:to_binary(Uri)},
    case create_endpoint('PlayerEndpoint', Params, Session) of
        {ok, ObjId} ->
            subscribe(ObjId, 'Error', Session),
            subscribe(ObjId, 'EndOfStream', Session),
            case connect_from(ObjId, Medias, Session) of
                {ok, Session2} ->
                    ok = invoke(ObjId, play, #{}, Session2),
                    Session3 = ?SESSION(#{nkmedia_kms_player=>ObjId}, Session2),
                    {ok, #{uri=>Uri}, Session3};
                {error, Error} ->
                    {error, Error, Session}
            end;
        {error, Error} ->
           {error, Error, Session}
    end;

player_op(start, Opts, Session) ->
    Uri = <<"http://files.kurento.org/video/format/sintel.webm">>,
    player_op(start, Opts#{uri=>Uri, loops=>2}, Session);

% player_op(start, _Opts, _Session) ->
%     {error, {missing_field, uri}, Session};

player_op(pause, _Opts, #{nkmedia_kms_player:=PlayerEP}=Session) ->
    ok = invoke(PlayerEP, pause, #{}, Session),
    {ok, #{}, Session};

player_op(resume, _Opts, #{nkmedia_kms_player:=PlayerEP}=Session) ->
    ok = invoke(PlayerEP, play, #{}, Session),
    {ok, #{}, Session};

player_op(stop, _Opts, #{nkmedia_kms_player:=PlayerEP}=Session) ->
    invoke(PlayerEP, stop, #{}, Session),
    release(PlayerEP, Session),
    {ok, #{}, ?SESSION_RM(nkmedia_kms_player, Session)};

player_op(get_info, _Opts, #{nkmedia_kms_player:=PlayerEP}=Session) ->
    {ok, Data} = invoke(PlayerEP, getVideoInfo, #{}, Session),
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
            {ok, Data2, Session};
        _ ->
            ?LLOG(warning, "unknown player info: ~p", [Data], Session),
            {ok, #{}, Session}
    end;

player_op(get_position, _Opts, #{nkmedia_kms_player:=PlayerEP}=Session) ->
    case invoke(PlayerEP, getPosition, #{}, Session) of
        {ok, Pos}  ->
            {ok, #{position=>Pos}, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

player_op(set_position, #{position:=Pos}, #{nkmedia_kms_player:=PlayerEP}=Session) ->
    case invoke(PlayerEP, setPosition, #{position=>Pos}, Session) of
        ok ->
            {ok, #{}, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

player_op(set_position, _Ops, Session) ->
    {error, {missing_field, position}, Session};

player_op(get_actions, _Opts, Session) ->
    Ac = [start, stop, pause, resume, get_info, get_position, set_position, get_actions], 
    {ok, #{actions=>Ac}, Session};

player_op(Action, _Opts, #{nkmedia_kms_player:=_}=Session) ->
    {error, {invalid_action, Action}, Session};

player_op(_, _Opts, Session) ->
    {error, no_active_player, Session}.


%% @private
-spec get_stats(binary(), session()) ->
    {ok, map()}.

get_stats(Type, #{nkmedia_kms_endpoint:=EP}=Session) 
        when Type == <<"AUDIO">>; Type == <<"VIDEO">>; Type == <<"DATA">> ->
    {ok, _Stats} = invoke(EP, getStats, #{mediaType=>Type}, Session);

get_stats(Type, _Session) ->
    {error, {invalid_value, Type}}.


%% @private
-spec create_endpoint(atom(), map(), session()) ->
    {ok, endpoint()} | {error, nkservice:error()}.

create_endpoint(Type, Params, Session) ->
    #{
        session_id := SessId,
        nkmedia_kms_id := KmsId, 
        nkmedia_kms_pipeline := Pipeline
    } = Session,
    Params2 = Params#{mediaPipeline=>Pipeline},
    Properties = #{pkey1 => pval1},
    case nkmedia_kms_client:create(KmsId, Type, Params2, Properties) of
        {ok, ObjId} ->
            ok = invoke(ObjId, addTag, #{key=>nkmedia, value=>SessId}, Session),
            ok = invoke(ObjId, setSendTagsInEvents, #{sendTagsInEvents=>true}, Session),
            {ok, ObjId};
        {error, Error} ->
            {error, Error}
    end.


%% @private
%% Adds or remove medias in the EP -> Proxy path
-spec update_media(map(), session()) ->
    ok.

update_media(Opts, #{nkmedia_kms_endpoint:=EP, nkmedia_kms_proxy:=Proxy}=Session) ->
    case get_update_medias(Opts) of
        {[], []} ->
            ok;
        {Add, Remove} ->
            ?LLOG(info, "updated media: +~p, -~p", [Add, Remove], Session),
            do_connect(EP, Proxy, Add, Session),
            do_disconnect(EP, Proxy, Remove, Session)
    end.


%% @private
%% Connects Remote -> EP (some medias). It first disconnect from previous source.
%% We can select the medias to use, or use a map() with options, and all medias
%% will be included except the ones that have 'mute' true
-spec connect_from(endpoint(), map()|all|[media_type()], session()) ->
    {ok, session()} | {error, nkservice:error()}.

connect_from(Remote, Opts, Session) when is_map(Opts) ->
    Medias = get_create_medias(Opts),
    connect_from(Remote, Medias, Session);

connect_from(Remote, Medias, #{nkmedia_kms_endpoint:=EP}=Session) ->
    case Session of
        #{nkmedia_kms_source:=Source} ->
            do_disconnect(Source, EP, all, Session);
        _ -> 
            ok
    end,
    case do_connect(Remote, EP, Medias, Session) of
        ok ->
            {ok, ?SESSION(#{nkmedia_kms_source=>Remote}, Session)};
        {error, Error} ->
            {error, Error}
    end.



%% @private
%% Connects EP -> Proxy with medias
-spec connect_to_proxy(map(), session()) ->
    ok | {error, nkservice:error()}.

connect_to_proxy(Opts, Session) ->
    #{nkmedia_kms_endpoint:=EP, nkmedia_kms_proxy:=Proxy} = Session,
    Medias = get_create_medias(Opts),
    ok = do_connect(EP, Proxy, Medias, Session).


%% @private Connects an Element to a Sink
do_connect(Elem, SinkEP, all, Session) ->
    ?LLOG(info, "connecting ~s -> ~s (all)", 
          [print_id(Elem, Session), print_id(SinkEP, Session)], Session),
    invoke(Elem, connect, #{sink=>SinkEP}, Session);
do_connect(_Elem, _SinkEP, [], _Session) ->
    ok;
do_connect(Elem, SinkEP, [Type|Rest], Session) ->
    ?LLOG(info, "connecting ~s -> ~s (~s)", 
          [print_id(Elem, Session), print_id(SinkEP, Session), Type], Session),
    case invoke(Elem, connect, #{sink=>SinkEP, mediaType=>Type}, Session) of
        ok ->
            do_connect(Elem, SinkEP, Rest, Session);
        {error, Error} ->
            {error, Error}
    end.

%% @private Disconnect a Sink from an Element
do_disconnect(Elem, SinkEP, all, Session) ->
    ?LLOG(info, "disconnecting ~s -> ~s (all)", 
          [print_id(Elem, Session), print_id(SinkEP, Session)], Session),
    invoke(Elem, disconnect, #{sink=>SinkEP}, Session);
do_disconnect(_Elem, _SinkEP, [], _Session) ->
    ok;
do_disconnect(Elem, SinkEP, [Type|Rest], Session) ->
    ?LLOG(info, "disconnecting ~s -> ~s (~s)", 
          [print_id(Elem, Session), print_id(SinkEP, Session), Type], Session),
    case invoke(Elem, disconnect, #{sink=>SinkEP, mediaType=>Type}, Session) of
        ok ->
            do_disconnect(Elem, SinkEP, Rest, Session);
        {error, Error} ->
            {error, Error}
    end.


%% @private Disconnect EP -> Proxy and External -> EP
-spec park(session()) ->
    ok.

park(#{nkmedia_kms_proxy:=Proxy, nkmedia_kms_endpoint:=EP}=Session) ->
    ok = do_disconnect(EP, Proxy, all, Session),
    case Session of
        #{nkmedia_kms_source:=Source} ->
            do_disconnect(Source, EP, all, Session);
        _ ->
            ok
    end,
    {ok, ?SESSION_RM(nkmedia_kms_source, Session)};

park(Session) ->
    {ok, Session}.


%% @private
-spec subscribe(endpoint(), atom(), session()) ->
    SubsId::binary().

subscribe(ObjId, Type, #{nkmedia_kms_id:=KmsId}) ->
    {ok, SubsId} = nkmedia_kms_client:subscribe(KmsId, ObjId, Type),
    SubsId.


%% @private
-spec invoke(endpoint(), atom(), map(), session()) ->
    ok | {ok, term()} | {error, nkservice:error()}.

invoke(ObjId, Op, Params, #{nkmedia_kms_id:=KmsId}) ->
    case nkmedia_kms_client:invoke(KmsId, ObjId, Op, Params) of
        {ok, null} -> ok;
        {ok, Other} -> {ok, Other};
        {error, Error} -> {error, Error}
    end.


%% @private
-spec release(binary(), session()) ->
    ok | {error, nkservice:error()}.
 
release(ObjId, #{nkmedia_kms_id:=KmsId}=Session) ->
    ?LLOG(info, "releasing ~s", [print_id(ObjId, Session)], Session),
    nkmedia_kms_client:release(KmsId, ObjId).


%% @private
-spec get_sources(endpoint(), session()) ->
    #{endpoint() => [media_type()]}.

get_sources(EP, Session) ->
    {ok, Sources} = invoke(EP, getSourceConnections, #{}, Session),
    lists:foldl(
        fun(#{<<"type">>:=Type, <<"source">>:=Source, <<"sink">>:=Sink}, Acc) ->
            Sink = EP,
            Types = maps:get(Source, Acc, []),
            maps:put(Source, lists:sort([Type|Types]), Acc)
        end,
        #{},
        Sources).


%% @private
-spec get_sinks(endpoint(), session()) ->
    #{endpoint() => [media_type()]}.

get_sinks(EP, Session) ->
    {ok, Sinks} = invoke(EP, getSinkConnections, #{}, Session),
    lists:foldl(
        fun(#{<<"type">>:=Type, <<"source">>:=Source, <<"sink">>:=Sink}, Acc) ->
            Source = EP,
            Types = maps:get(Sink, Acc, []),
            maps:put(Sink, lists:sort([Type|Types]), Acc)
        end,
        #{},
        Sinks).


%% @private
%% All medias will be included, except if "mute_XXX=false"
-spec get_create_medias(map()) ->
    all|[media_type()].

get_create_medias(Opts) ->
    Medias = lists:flatten([
        case maps:get(mute_audio, Opts, false) of
            false -> <<"AUDIO">>;
            _ -> []
        end,
        case maps:get(mute_video, Opts, false) of
            false -> <<"VIDEO">>;
            _ -> []
        end,
        case maps:get(mute_data, Opts, false) of
            false -> <<"DATA">>;
            _ -> []
        end
    ]),
    case Medias of
        [<<"AUDIO">>, <<"VIDEO">>, <<"DATA">>] -> all;
        _ -> Medias
    end.


%% @private
%% Will generate medias to ADD and REMOVE based on opts
-spec get_update_medias(map()) ->
    {[media_type()], [media_type()]}.

get_update_medias(Opts) ->
    MuteAudio = maps:get(mute_audio, Opts, none),
    MuteVideo = maps:get(mute_video, Opts, none),
    MuteData = maps:get(mute_data, Opts, none),
    Add = lists:flatten([
        case MuteAudio of false -> <<"AUDIO">>; _ -> [] end,
        case MuteVideo of false -> <<"VIDEO">>; _ -> [] end,
        case MuteData of false -> <<"DATA">>; _ -> [] end
    ]),
    Rem = lists:flatten([
        case MuteAudio of true -> <<"AUDIO">>; _ -> [] end,
        case MuteVideo of true -> <<"VIDEO">>; _ -> [] end,
        case MuteData of true -> <<"DATA">>; _ -> [] end
    ]),
    {Add, Rem}.




%% @private
print_id(Ep) ->
    print_id(Ep, #{}).
   

%% @private
print_id(EP, #{nkmedia_kms_endpoint:=EP}) ->
    <<"(endpoint)">>;
print_id(EP, #{nkmedia_kms_proxy:=EP}) ->
    <<"(proxy)">>;
print_id(EP, #{nkmedia_kms_player:=EP}) ->
    <<"(player)">>;
print_id(EP, #{nkmedia_kms_recorder:=EP}) ->
    <<"(recorder)">>;
print_id(Ep, _Session) ->
    case binary:split(Ep, <<"/">>) of
        [_, Id] -> Id;
        _ -> Ep
    end.


%% @private
print_info(SessId, #{nkmedia_kms_endpoint:=EP, nkmedia_kms_proxy:=Proxy}=Session) ->
    io:format("SessId:   ~s\n", [SessId]),
    io:format("Endpoint: ~s\n", [print_id(EP)]),
    Source = maps:get(nkmedia_kms_player, Session, <<>>),
    io:format("Source:   ~s\n", [print_id(Source)]),
    io:format("Proxy:    ~s\n", [print_id(Proxy)]),
    Player = maps:get(nkmedia_kms_player, Session, <<>>),
    io:format("Player:   ~s\n", [print_id(Player)]),
    Recorder = maps:get(nkmedia_kms_recorder, Session, <<>>),
    io:format("Recorder: ~s\n", [print_id(Recorder)]),
    io:format("\nEndpoint Source: "),
    lists:foreach(
        fun({Id, Types}) -> 
            io:format("~s: ~s\n", [print_id(Id, Session), nklib_util:bjoin(Types)]) 
        end,
        maps:to_list(get_sources(EP, Session))),
    io:format("\nEndpoint Sinks:\n"),
    lists:foreach(
        fun({Id, Types}) -> 
            io:format("~s: ~s\n", [print_id(Id, Session), nklib_util:bjoin(Types)]) 
        end,
        maps:to_list(get_sinks(EP, Session))),
    io:format("\nProxy Source: "),
    lists:foreach(
        fun({Id, Types}) -> 
            io:format("~s: ~s\n", [print_id(Id, Session), nklib_util:bjoin(Types)]) 
        end,
        maps:to_list(get_sources(Proxy, Session))),
    io:format("\nProxy Sinks:\n"),
    lists:foreach(
        fun({Id, Types}) -> 
            io:format("~s: ~s\n", [print_id(Id, Session), nklib_util:bjoin(Types)]) 
        end,
        maps:to_list(get_sinks(Proxy, Session))),

    case Player of
        <<>> ->
            ok;
        _ ->
            io:format("\nPlayer Sinks:\n"),
            lists:foreach(
                fun({Id, Types}) -> 
                    io:format("~s: ~s\n", [print_id(Id, Session), nklib_util:bjoin(Types)]) 
                end,
                maps:to_list(get_sinks(Player, Session)))
    end,
    case Recorder of
        <<>> ->
            ok;
        _ ->
            io:format("\nRecorder Source: "),
            lists:foreach(
                fun({Id, Types}) -> 
                    io:format("~s: ~s\n", [print_id(Id, Session), nklib_util:bjoin(Types)]) 
                end,
                maps:to_list(get_sources(Recorder, Session)))
    end,
    {ok, MediaSession} = invoke(EP, getMediaState, #{}, Session),
    io:format("\nMediaSession: ~s\n", [MediaSession]),
    {ok, ConnectionState} = invoke(EP, getConnectionState, #{}, Session),
    io:format("ConnectionState: ~s\n", [ConnectionState]),

    {ok, IsMediaFlowingIn1} = 
        invoke(EP, isMediaFlowingIn, #{mediaType=>'AUDIO'}, Session),
    io:format("IsMediaFlowingIn AUDIO: ~p\n", [IsMediaFlowingIn1]),
    {ok, IsMediaFlowingOut1} = invoke(EP, isMediaFlowingOut, #{mediaType=>'AUDIO'}, Session),
    io:format("IsMediaFlowingOut AUDIO: ~p\n", [IsMediaFlowingOut1]),
    {ok, IsMediaFlowingIn2} = 
        invoke(EP, isMediaFlowingIn, #{mediaType=>'VIDEO'}, Session),
    io:format("IsMediaFlowingIn VIDEO: ~p\n", [IsMediaFlowingIn2]),
    {ok, IsMediaFlowingOut2} = 
        invoke(EP, isMediaFlowingOut, #{mediaType=>'VIDEO'}, Session),
    io:format("IsMediaFlowingOut VIDEO: ~p\n", [IsMediaFlowingOut2]),

    {ok, MinVideoRecvBandwidth} = invoke(EP, getMinVideoRecvBandwidth, #{}, Session),
    io:format("MinVideoRecvBandwidth: ~p\n", [MinVideoRecvBandwidth]),
    {ok, MinVideoSendBandwidth} = invoke(EP, getMinVideoSendBandwidth, #{}, Session),
    io:format("MinVideoSendBandwidth: ~p\n", [MinVideoSendBandwidth]),
    {ok, MaxVideoRecvBandwidth} = invoke(EP, getMaxVideoRecvBandwidth, #{}, Session),
    io:format("MaxVideoRecvBandwidth: ~p\n", [MaxVideoRecvBandwidth]),
    {ok, MaxVideoSendBandwidth} = invoke(EP, getMaxVideoSendBandwidth, #{}, Session),
    io:format("MaxVideoSendBandwidth: ~p\n", [MaxVideoSendBandwidth]),
    
    {ok, MaxAudioRecvBandwidth} = invoke(EP, getMaxAudioRecvBandwidth, #{}, Session),
    io:format("MaxAudioRecvBandwidth: ~p\n", [MaxAudioRecvBandwidth]),
    
    {ok, MinOutputBitrate} = invoke(EP, getMinOutputBitrate, #{}, Session),
    io:format("MinOutputBitrate: ~p\n", [MinOutputBitrate]),
    {ok, MaxOutputBitrate} = invoke(EP, getMaxOutputBitrate, #{}, Session),
    io:format("MaxOutputBitrate: ~p\n", [MaxOutputBitrate]),

    % {ok, RembParams} = invoke(getRembParams, #{}, Session),
    % io:format("\nRembParams: ~p\n", [RembParams]),
    
    % Convert with dot -Tpdf gstreamer.dot -o 1.pdf
    % {ok, GstreamerDot} = invoke(getGstreamerDot, #{}, Session),
    % file:write_file("/tmp/gstreamer.dot", GstreamerDot),
    ok.



%% @private
-spec print_event(session_id(), binary(), map()) ->
    ok.

print_event(SessId, <<"OnIceComponentStateChanged">>, Data) ->
    #{
        <<"source">> := _SrcId,
        <<"state">> := IceSession,
        <<"streamId">> := StreamId,
        <<"componentId">> := CompId
    } = Data,
    {Level, Msg} = case IceSession of
        <<"GATHERING">> -> {info, gathering};
        <<"CONNECTING">> -> {info, connecting};
        <<"CONNECTED">> -> {info, connected};
        <<"READY">> -> {info, ready};
        <<"FAILED">> -> {warning, failed}
    end,
    Txt = io_lib:format("ICE State (~p:~p) ~s", [StreamId, CompId, Msg]),
    case Level of
        info ->    ?LLOG(info, "~s", [Txt], SessId);
        notice ->  ?LLOG(notice, "~s", [Txt], SessId);
        warning -> ?LLOG(warning, "~s", [Txt], SessId)
    end;

print_event(SessId, <<"OnIceComponentSessionChanged">>, Data) ->
    #{
        <<"source">> := _SrcId,
        <<"state">> := IceSession,
        <<"streamId">> := StreamId,
        <<"componentId">> := CompId
    } = Data,
    {Level, Msg} = case IceSession of
        <<"GATHERING">> -> {info, gathering};
        <<"CONNECTING">> -> {info, connecting};
        <<"CONNECTED">> -> {notice, connected};
        <<"READY">> -> {notice, ready};
        <<"FAILED">> -> {warning, failed}
    end,
    Txt = io_lib:format("ICE Session (~p:~p) ~s", [StreamId, CompId, Msg]),
    case Level of
        info ->    ?LLOG(info, "~s", [Txt], SessId);
        notice ->  ?LLOG(notice, "~s", [Txt], SessId);
        warning -> ?LLOG(warning, "~s", [Txt], SessId)
    end;

print_event(SessId, <<"MediaSessionStarted">>, _Data) ->
    ?LLOG(info, "event media session started", [], SessId);

print_event(SessId, <<"ElementConnected">>, Data) ->
    #{
        <<"mediaType">> := Type, 
        <<"sink">> := Sink,
        <<"source">> := Source
    } = Data,
    ?LLOG(info, "event element connected ~s: ~s -> ~s", 
           [Type, print_id(Source), print_id(Sink)], SessId);

print_event(SessId, <<"ElementDisconnected">>, Data) ->
    #{
        <<"mediaType">> := Type, 
        <<"sink">> := Sink,
        <<"source">> := Source
    } = Data,
    ?LLOG(info, "event element disconnected ~s: ~s -> ~s", 
           [Type, print_id(Source), print_id(Sink)], SessId);

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
        <<"oldState">> := _Old,
        <<"newState">> := New
    } = Data,
    % ?LLOG(info, "event connection state changed (~s -> ~s)", [Old, New], SessId),
    Status = case New of
        <<"CONNECTED">> -> up;
        <<"DISCONNECTED">> -> down
    end,
    nkmedia_session:send_info(SessId, webrtc, #{status=>Status});

print_event(SessId, <<"MediaFlowOutStateChange">>, Data) ->
    #{
        <<"mediaType">> := Type, 
        <<"padName">> := _Pad,
        <<"state">> := State
    }  = Data,
    % ?LLOG(info, "event media flow out state change (~s: ~s)", [Type, State], SessId),
    Media = case Type of
        <<"AUDIO">> -> audio;
        <<"VIDEO">> -> video;
        <<"DATA">> -> data
    end,
    Flowing = case State of
        <<"FLOWING">> -> up;
        <<"NOT FLOWING">> -> down
    end,
    nkmedia_session:send_info(SessId, media, #{media=>Media, status=>Flowing});

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

print_event(SessId, Type, Data) ->
    ?LLOG(warning, "unknown event ~s: ~p", [Type, Data], SessId).
