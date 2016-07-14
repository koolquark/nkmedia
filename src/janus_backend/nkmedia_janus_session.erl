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

-export([init/3, terminate/3, start/3, answer/4, update/5, stop/3]).

-export_type([config/0, type/0, opts/0, update/0]).

-define(LLOG(Type, Txt, Args, Session),
    lager:Type("NkMEDIA JANUS Session ~s "++Txt, 
               [maps:get(id, Session) | Args])).

-include("nkmedia.hrl").

%% ===================================================================
%% Types
%% ===================================================================

-type id() :: nkmedia_session:id().
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
        room => binary(),               % publish, listen
        publisher => binary(),          % listen
        proxy_type => webrtc | rtp      % proxy
    }.


-type update() ::
    nkmedia_session:update() |
    {listener_switch, binary()}.


-type state() ::
    #{
        janus_id => nkmedia_janus_engine:id(),
        janus_pid => pid(),
        janus_mon => reference(),
        janus_op => answer,
        record_pos => integer(),
        room => binary()
    }.




%% ===================================================================
%% Callbacks
%% ===================================================================


-spec init(id(), session(), state()) ->
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

start(echo, #{offer:=#{sdp:=_}=Offer}=Session, State) ->
    case get_janus_op(Session, State) of
        {ok, Pid, State2} ->
            {Opts, State3} = get_opts(Session, State2),
            case nkmedia_janus_op:echo(Pid, Offer, Opts) of
                {ok, #{sdp:=_}=Answer} ->
                    Reply = #{answer=>Answer},
                    {ok, echo, Reply, none, Answer, State3};
                {error, Error} ->
                    {error, Error, State3}
            end;
        {error, Error, State2} ->
            {error, Error, State2}
    end;

start(echo, _Session, State) ->
    {error, missing_offer, State};

start(proxy, #{offer:=#{sdp:=_}=Offer}=Session, State) ->
    case get_janus_op(Session, State) of
        {ok, Pid, State2} ->
            OfferType = maps:get(sdp_type, Offer, webrtc),
            OutType = maps:get(proxy_type, Session, webrtc),
            Fun = case {OfferType, OutType} of
                {webrtc, webrtc} -> videocall;
                {webrtc, rtp} -> to_sip;
                {rtp, webrtc} -> from_sip;
                {rtp, rtp} -> error
            end,
            case Fun of
                error ->
                    {error, invalid_parameters, State};
                _ ->
                    {Opts, State3} = get_opts(Session, State2),
                    case nkmedia_janus_op:Fun(Pid, Offer, Opts) of
                        {ok, Offer2} ->
                            State4 = State3#{janus_op=>answer},
                            Offer3 = maps:merge(Offer, Offer2),
                            Reply = #{offer=>Offer3},
                            {ok, proxy, Reply, Offer3, none, State4};
                        {error, Error} ->
                            {error, Error, State3}
                    end
            end;
        {error, Error, State2} ->
            {error, Error, State2}
    end;

start(proxy, _Session, State) ->
    {error, missing_offer, State};

start(publish, #{srv_id:=SrvId, offer:=#{sdp:=_}=Offer}=Session, State) ->
    try
        Room = case maps:find(room, Session) of
            {ok, Room0} -> 
                nklib_util:to_binary(Room0);
            error -> 
                RoomOpts = maps:with(
                    [room_audio_codec, room_video_codec, room_bitrate], Session),
                case nkmedia_janus_room:create(SrvId, RoomOpts) of
                    {ok, Room0, _} -> Room0;
                    {error, Error} -> throw(Error)
                end
        end,
        State2 = case nkmedia_janus_room:get_room(Room) of
            {ok, #{janus_id:=JanusId}} ->
                State#{janus_id=>JanusId, room=>Room};
            _ ->
                throw(room_not_found)
        end,
        case get_janus_op(Session, State2) of
            {ok, Pid, State3} ->
                {Opts, State4} = get_opts(Session, State3),
                case nkmedia_janus_op:publish(Pid, Room, Offer, Opts) of
                    {ok, #{sdp:=_}=Answer} ->
                        Reply = #{answer=>Answer, room=>Room},
                        {ok, publish, Reply, none, Answer, State4};
                    {error, Error2} ->
                        {error, Error2, State4}
                end;
            {error, Error3, State3} ->
                {error, Error3, State3}
        end
    catch
        throw:Throw -> {error, Throw, State}
    end;

start(publish, _Session, State) ->
    {error, missing_offer, State};

start(listen, #{publisher:=Publisher}=Session, State) ->
    case nkmedia_session:do_call(Publisher, nkmedia_janus_get_room) of
        {ok, _SrvId, Room} ->
            case get_janus_op(Session, State) of
                {ok, Pid, State2} ->
                    {Opts, State3} = get_opts(Session, State2),
                    case nkmedia_janus_op:listen(Pid, Room, Publisher, Opts) of
                        {ok, Offer} ->
                            State4 = State3#{janus_op=>answer},
                            Reply = #{room=>Room, offer=>Offer},
                            {ok, listen, Reply, Offer, none, State4};
                        {error, Error} ->
                            {error, Error, State3}
                    end;
                {error, Error, State2} ->
                    {error, Error, State2}
            end;
        _ ->
            {error, unknown_publisher, State}
    end;

start(listen, _Session, State) ->
    {error, missing_parameters, State};

start(_Type, _Session, _State) ->
    continue.


%% @private
-spec answer(type(), nkmedia:answer(), session(), state()) ->
    {ok, map(), nkmedia:answer(), state()} |
    {error, term(), state()} | continue().

answer(Op, Answer, _Session, #{janus_op:=answer}=State)
        when Op==proxy; Op==listen ->
    #{janus_pid:=Pid} = State,
    case nkmedia_janus_op:answer(Pid, Answer) of
        ok ->
            {ok, #{}, Answer, maps:remove(janus_op, State)};
        {ok, Answer2} ->
            {ok, #{answer=>Answer2}, Answer2, maps:remove(janus_op, State)};
        {error, Error} ->
            {error, Error, State}
    end;

answer(_Type, _Answer, _Session, _State) ->
    continue.


%% @private
-spec update(update(), map(), type(), nkmedia:session(), state()) ->
    {ok, type(), map(), state()} |
    {error, term(), state()} | continue().

update(media, Opts, Type, #{id:=SessId}, #{janus_pid:=Pid}=State)
        when Type==echo; Type==proxy; Type==publish ->
    {Opts2, State2} = get_opts(Opts#{id=>SessId}, State),
    case nkmedia_janus_op:update(Pid, Opts2) of
        ok ->
            {ok, Type, #{}, State2};
        {error, Error} ->
            {error, Error, State2}
    end;

update(listen_switch, #{publisher:=Publisher}, listen, _Session, 
       #{janus_pid:=Pid}=State) ->
    case nkmedia_janus_op:listen_switch(Pid, Publisher, #{}) of
        ok ->
            {ok, listen, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

update(_Update, _Opts, _Type, _Session, _State) ->
    lager:error("UPDATE: ~p, ~p, ~p", [_Update, _Opts, _Type]),
    continue.


%% @private
-spec stop(nkservice:error(), session(), state()) ->
    {ok, state()}.

stop(_Reason, _Session, State) ->
    {ok, State}.




%% ===================================================================
%% Internal
%% ===================================================================


%% @private
get_janus_op(#{id:=SessId}=Session, #{janus_id:=JanusId}=State) ->
    case nkmedia_janus_op:start(JanusId, SessId) of
        {ok, Pid} ->
            State2 = State#{janus_pid=>Pid, janus_mon=>monitor(process, Pid)},
            {ok, Pid, State2};
        {error, Error} ->
            ?LLOG(warning, "janus connection start error: ~p", [Error], Session),
            {error, janus_connection_error, State}
    end;

get_janus_op(Session, State) ->
    case get_mediaserver(Session, State) of
        {ok, State2} ->
            get_janus_op(Session, State2);
        {error, Error} ->
            ?LLOG(warning, "get_mediaserver error: ~p", [Error], Session),
            {error, no_mediaserver, State}
    end.



%% @private
-spec get_mediaserver(session(), state()) ->
    {ok, state()} | {error, term()}.

get_mediaserver(_Session, #{janus_id:=_}=State) ->
    {ok, State};

get_mediaserver(#{srv_id:=SrvId}, State) ->
    case SrvId:nkmedia_janus_get_mediaserver(SrvId) of
        {ok, Id} ->
            {ok, State#{janus_id=>Id}};
        {error, Error} ->
            {error, Error}
    end.


%% @private
get_opts(#{id:=SessId}=Session, State) ->
    Opts = maps:with([record, use_audio, use_video, use_data, bitrate], Session),
    case Session of
        #{record:=true} ->
            Pos = maps:get(record_pos, State, 0),
            Name = io_lib:format("~s_p~4..0w", [SessId, Pos]),
            File = filename:join(<<"/tmp/record">>, list_to_binary(Name)),
            {Opts#{filename => File}, State#{record_pos=>Pos+1}};
        _ ->
            {Opts, State}
    end.



