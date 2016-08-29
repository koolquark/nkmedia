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
%% For each operation, starts and monitors a new nkmedia_janus_op process

-module(nkmedia_janus_session).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/2, answer/3, candidate/2, update/3, stop/2, handle_call/3]).

-export_type([session/0, type/0, opts/0, update/0]).

-define(LLOG(Type, Txt, Args, Session),
    lager:Type("NkMEDIA JANUS Session ~s "++Txt, 
               [maps:get(session_id, Session) | Args])).

-include("../../include/nkmedia.hrl").

%% ===================================================================
%% Types
%% ===================================================================

-type session_id() :: nkmedia_session:id().
-type continue() :: continue | {continue, list()}.


-type session() :: 
    nkmedia_session:session() |
    #{
        nkmedia_janus_id => nkmedia_janus_engine:id(),
        nkmedia_janus_pid => pid(),
        nkmedia_janus_mon => reference(),
        nkmedia_janus_op => answer,
        nkmedia_janus_record_pos => integer()
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
    }.


-type update() ::
    nkmedia_session:update() |
    {listener_switch, binary()}.




%% ===================================================================
%% Callbacks
%% ===================================================================



%% @private
-spec start(nkmedia_session:type(), session()) ->
    {ok, Reply::map(), nkmedia_session:ext_ops(), session()} |
    {wait_server_ice, session()} | {wait_client_ice, session()} |
    {error, nkservice:error(), session()} | continue().

start(echo, #{offer:=#{sdp:=_}=Offer}=Session) ->
    case get_janus_op(Session) of
        {ok, Pid, Session2} ->
            {Opts, Session3} = get_opts(Session2),
            case nkmedia_janus_op:echo(Pid, Offer, Opts) of
                {ok, #{sdp:=_}=Answer} ->
                    Reply = ExtOps = #{answer=>Answer},
                    {ok, Reply, ExtOps, Session3};
                {error, Error} ->
                    {error, Error, Session3}
            end;
        {error, Error} ->
            {error, Error, Session}
    end;

start(echo, Session) ->
    {error, missing_offer, Session};

start(proxy, #{offer:=#{sdp:=_}=Offer}=Session) ->
    case get_janus_op(Session) of
        {ok, Pid, Session2} ->
            OfferType = maps:get(sdp_type, Offer, webrtc),
            OutType = maps:get(sdp_type, Session, webrtc),
            Fun = case {OfferType, OutType} of
                {webrtc, webrtc} -> videocall;
                {webrtc, rtp} -> to_sip;
                {rtp, webrtc} -> from_sip;
                {rtp, rtp} -> error
            end,
            case Fun of
                error ->
                    {error, invalid_parameters, Session};
                _ ->
                    {Opts, Session3} = get_opts(Session2),
                    case nkmedia_janus_op:Fun(Pid, Offer, Opts) of
                        {ok, Offer2} ->
                            Session4 = ?SESSION(#{nkmedia_janus_op=>answer}, Session3),
                            Offer3 = maps:merge(Offer, Offer2),
                            Reply = ExtOps = #{offer=>Offer3},
                            {ok, Reply, ExtOps, Session4};
                        {error, Error} ->
                            {error, Error, Session3}
                    end
            end;
        {error, Error} ->
            {error, Error, Session}
    end;

start(proxy, Session) ->
    {error, missing_offer, Session};

start(publish, #{offer:=#{sdp:=_}=Offer}=Session) ->
    case get_janus_op(Session) of
        {ok, Pid, Session2} ->
            case get_room(publish, Session2) of
                {ok, RoomId} ->
                    {Opts, Session3} = get_opts(Session2),
                    case nkmedia_janus_op:publish(Pid, RoomId, Offer, Opts) of
                        {ok, #{sdp:=_}=Answer} ->
                            Reply = #{answer=>Answer, room_id=>RoomId},
                            ExtOps = #{answer=>Answer, type_ext=>#{room_id=>RoomId}},
                            {ok, Reply, ExtOps, Session3};
                        {error, Error} ->
                            {error, Error, Session3}
                    end;
                {error, Error} ->
                    {error, Error, Session}
            end;
        {error, Error} ->
            {error, Error, Session}
    end;

start(publish, Session) ->
    {error, missing_offer, Session};

start(listen, #{publisher_id:=Publisher}=Session) ->
    case get_janus_op(Session) of
        {ok, Pid, Session2} ->
            case get_room(listen, Session2) of
                {ok, RoomId} ->
                    {Opts, Session3} = get_opts(Session, Session2),
                    case nkmedia_janus_op:listen(Pid, RoomId, Publisher, Opts) of
                        {ok, Offer} ->
                            Session4 = Session3#{nkmedia_janus_op=>answer},
                            Reply = #{offer=>Offer, room_id=>RoomId},
                            ExtOps = #{
                                offer => Offer, 
                                type_ext => #{room_id=>RoomId, publisher_id=>Publisher}
                            },
                            {ok, Reply, ExtOps, Session4};
                        {error, Error} ->
                            {error, Error, Session3}
                    end;
                {error, Error} ->
                    {error, Error, Session}
            end;
        {error, Error} ->
            {error, Error, Session}
    end;


start(listen, Session) ->
    {error, {missing_field, publisher_id}, Session};

start(_Type, _Session) ->
    continue.


%% @private
-spec answer(type(), nkmedia:answer(), session()) ->
    {ok, Reply::map(), nkmedia_session:ext_ops(), session()} |
    {wait_server_ice, session()} | {wait_client_ice, session()} |
    {error, nkservice:error(), session()} | continue().

answer(Type, Answer, #{nkmedia_janus_op:=answer}=Session)
            when Type==proxy; Type==listen ->
    #{nkmedia_janus_pid:=Pid} = Session,
    case nkmedia_janus_op:answer(Pid, Answer) of
        ok ->
            ExtOps = #{answer=>Answer},
            {ok, #{}, ExtOps, ?SESSION_RM(nkmedia_janus_op, Session)};
        {ok, Answer2} ->
            Reply = ExtOps = #{answer=>Answer2},
            {ok, Reply, ExtOps, ?SESSION_RM(nkmedia_janus_op, Session)};
        {error, Error} ->
            {error, Error, Session}
    end;

answer(_Type, _Answer, _Session) ->
    continue.


%% @private
-spec candidate(nkmedia:candidate(), session()) ->
    {ok, session()} | {error, term()}.

candidate(Candidate, #{nkmedia_janus_pid:=Pid}=Session) ->
    ?LLOG(info, "Client candidate to server: ~p", [Candidate], Session),
    nkmedia_janus_op:candidate(Pid, Candidate),
    {ok, Session}.


%% @private
-spec update(update(), Opts::map(), session()) ->
    {ok, Reply::map(), nkmedia_session:ext_ops(), session()} |
    {error, term(), session()} | continue().

update(media, Opts, #{type:=Type}=Session) when Type==echo; Type==proxy; Type==publish ->
    #{session_id:=SessId, nkmedia_janus_pid:=Pid} = Session,
    {Opts2, Session2} = get_opts(Opts, Session),
    case nkmedia_janus_op:update(Pid, Opts2) of
        ok ->
            {ok, #{}, #{}, Session2};
        {error, Error} ->
            {error, Error, Session2}
    end;

update(listen_switch, #{publisher_id:=Publisher}, #{type:=listen}=Session) ->
    #{nkmedia_janus_pid:=Pid, type_ext:=Ext} = Session,
    case nkmedia_janus_op:listen_switch(Pid, Publisher, #{}) of
        ok ->
            ExtOps = #{type_ext=>Ext#{publisher_id:=Publisher}},
            {ok, #{}, ExtOps, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

update(_Update, _Opts, _Session) ->
    continue.


%% @private
-spec stop(nkservice:error(), session()) ->
    {ok, session()}.

stop(_Reason, Session) ->
    {ok, Session}.


%% @private
handle_call(get_publisher, _From, #{type:=publish}=Session) ->
    #{type_ext:=#{room_id:=RoomId}} = Session,
    {reply, {ok, RoomId}, Session};

handle_call(get_publisher, _From, Session) ->
    {reply, {error, invalid_publisher}, Session}.




%% ===================================================================
%% Internal
%% ===================================================================


%% @private
get_janus_op(#{nkmedia_janus_id:=JanusId, session_id:=SessId}=Session) ->
    case nkmedia_janus_op:start(JanusId, SessId) of
        {ok, Pid} ->
            Session2 = Session#{
                nkmedia_janus_pid => Pid,
                nkmedia_janus_mon => monitor(process, Pid)
            },
            {ok, Pid, Session2};
        {error, Error} ->
            ?LLOG(warning, "janus connection start error: ~p", [Error], Session),
            {error, janus_connection_error}
    end;

get_janus_op(Session) ->
    case get_mediaserver(Session) of
        {ok, Session2} ->
            get_janus_op(Session2);
        {error, Error} ->
            ?LLOG(warning, "get_mediaserver error: ~p", [Error], Session),
            {error, no_mediaserver}
    end.



%% @private
-spec get_mediaserver(session()) ->
    {ok, session()} | {error, term()}.

get_mediaserver(#{nkmedia_janus_id:=_}=Session) ->
    {ok, Session};

get_mediaserver(#{srv_id:=SrvId}=Session) ->
    case SrvId:nkmedia_janus_get_mediaserver(SrvId) of
        {ok, Id} ->
            {ok, Session#{nkmedia_janus_id=>Id}};
        {error, Error} ->
            {error, Error}
    end.


%% @private
-spec get_room(publish|listen, session()) ->
    {ok, nkmedia_room:id()} | {error, term()}.

get_room(Type, #{srv_id:=SrvId, nkmedia_janus_id:=JanusId}=Session) ->
    case get_room_id(Type, Session) of
        {ok, RoomId} ->
            lager:error("get_room ROOM ID IS: ~p", [RoomId]),
            case nkmedia_room:get_room(RoomId) of
                {ok, #{nkmedia_janus:=#{janus_id:=JanusId}}} ->
                    lager:error("Room exists in same MS"),
                    {ok, RoomId};
                {ok, _} ->
                    {error, different_mediaserver};
                {error, room_not_found} ->
                    Opts1 = [
                        {room_id, RoomId},
                        {backend, nkmedia_janus},
                        {nkmedia_janus, JanusId},
                        case maps:find(room_audio_codec, Session) of
                            {ok, AC} -> {audio_codec, AC};
                            error -> []
                        end,
                        case maps:find(room_video_codec, Session) of
                            {ok, VC} -> {video_codec, VC};
                            error -> []
                        end,
                        case maps:find(room_bitrate, Session) of
                            {ok, BR} -> {bitrate, BR};
                            error -> []
                        end
                    ],
                    Opts2 = maps:from_list(lists:flatten(Opts1)),
                    case nkmedia_room:start(SrvId, Opts2) of
                        {ok, RoomId, _} ->
                            {ok, RoomId};
                        {error, Error} ->
                            {error, Error}
                    end;
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @private
-spec get_room_id(publish|listen, session()) ->
    {ok, nkmedia_room:id()} | {error, term()}.

get_room_id(Type, Session) ->
    case maps:find(room_id, Session) of
        {ok, RoomId} -> 
            lager:error("Found room_id in Opts"),
            {ok, nklib_util:to_binary(RoomId)};
        error when Type==publish -> 
            {ok, nklib_util:uuid_4122()};
        error when Type==listen ->
            case Session of
                #{publisher_id:=Publisher} ->
                    case get_peer_publisher(Publisher) of
                        {ok, RoomId} -> {ok, RoomId};
                        {error, _Error} -> {error, invalid_publisher}
                    end;
                _ ->
                    {error, {missing_field, publisher_id}}
            end
    end.


%% @private
-spec get_peer_publisher(session_id()) ->
    {ok, nkmedia_room:id()} | {error, nkservice:error()}.

get_peer_publisher(SessId) ->
    nkmedia_session:do_call(SessId, {nkmedia_janus, get_publisher}).


%% @private
get_opts(Session) ->
    get_opts(Session, Session).


%% @private
get_opts(Opts, #{session_id:=SessId}=Session) ->
    Keys = [record, use_audio, use_video, use_data, bitrate, dtmf],
    Opts1 = maps:with(Keys, Opts),
    Opts2 = case Session of
        #{user_id:=UserId} -> Opts1#{user=>UserId};
        _ -> Opts1
    end,
    case Opts of
        #{record:=true} ->
            Pos = maps:get(nkmedia_janus_record_pos, Session, 0),
            Name = io_lib:format("~s_p~4..0w", [SessId, Pos]),
            File = filename:join(<<"/tmp/record">>, list_to_binary(Name)),
            Session2 = ?SESSION(#{nkmedia_janus_record_pos=>Pos+1}, Session),
            {Opts2#{filename => File}, Session2};
        _ ->
            {Opts2, Session}
    end.



