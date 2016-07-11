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
        record_file => binary(),        % echo
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
        janus_record_pos => integer()
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
    case get_janus(Session, State) of
        {ok, Pid, State2} ->
            Opts1 = maps:with(
                [record, use_audio, use_video, use_data, bitrate], Session),
            {Opts2, State3} = add_record_opts(Session, Opts1, State2),
            case nkmedia_janus_op:echo(Pid, Offer, Opts2) of
                {ok, #{sdp:=_}=Answer} ->
                    Reply = #{answer=>Answer},
                    {ok, echo, Reply, none, Answer, State3};
                {error, {janus_error, Error}} ->
                    {error, {janus_error, Error}, State3};
                {error, Error} ->
                    ?LLOG(warning, "janus echo error: ~p", [Error], Session),
                    {error, janus_error, State3}
            end;
        {error, Error, State2} ->
            {error, Error, State2}
    end;

start(echo, _Session, State) ->
    {error, missing_offer, State};

start(proxy, #{offer:=#{sdp:=_}=Offer}=Session, State) ->
    case get_janus(Session, State) of
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
                    Opts1 = maps:with(
                        [record, use_audio, use_video, use_data, bitrate], Session),
                    {Opts2, State3} = add_record_opts(Session, Opts1, State2),
                    case nkmedia_janus_op:Fun(Pid, Offer, Opts2) of
                        {ok, Offer2} ->
                            State4 = State3#{janus_op=>answer},
                            Offer3 = maps:merge(Offer, Offer2),
                            Reply = #{offer=>Offer3},
                            {ok, proxy, Reply, Offer3, none, State4};
                        {error, {janus_error, Error}} ->
                            {error, {janus_error, Error}, State2};
                        {error, Error} ->
                            ?LLOG(warning, "janus proxy error: ~p", [Error], Session),
                            {error, janus_error, State2}
                    end
            end;
        {error, Error, State2} ->
            {error, Error, State2}
    end;

start(proxy, _Session, State) ->
    {error, missing_offer, State};

start(publish, #{offer:=#{sdp:=_}=Offer}=Session, State) ->
    try
        Room = case maps:find(room, Session) of
            {ok, Room0} -> nklib_util:to_binary(Room0);
            error -> nklib_util:uuid_4122()
        end,
        case get_janus(Session, State) of
            {ok, Pid, State2} ->
                case nkmedia_janus_room:get_info(Room) of
                    {error, not_found} ->
                        #{janus_id:=JanusId} = State2,
                        case nkmedia_janus_room:create(JanusId, Room, #{}) of
                            {ok, _} -> 
                                ok;
                            {error, Error} ->
                                ?LLOG(warning, "room creation error: ~p", 
                                      [Error], Session),
                                throw(janus_room_creation)
                        end;
                    {ok, _} ->
                        ok
                end,
                Opts = #{room=>Room},
                case nkmedia_janus_op:publish(Pid, Room, Offer, Opts) of
                    {ok, #{sdp:=_}=Answer} ->
                        Reply = Opts#{answer=>Answer},
                        {ok, publish, Reply, none, Answer, State2};
                    {error, Error2} ->
                        ?LLOG(warning, "janus publish error: ~p", [Error2], Session),
                        {error, janus_error, State2}
                end;
            {error, Error3, State3} ->
                {error, Error3, State3}
        end
    catch
        throw:Throw -> {error, Throw, State}
    end;

start(publish, _Session, State) ->
    {error, missing_offer, State};

start(listen, #{room:=Room, publisher:=Publisher}=Session, State) ->
    case get_janus(Session, State) of
        {ok, Pid, State2} ->
            case nkmedia_janus_op:listen(Pid, Room, Publisher, #{}) of
                {ok, Offer} ->
                    State3 = State2#{janus_op=>answer},
                    Reply = #{room=>Room, publisher=>Publisher, offer=>Offer},
                    {ok, listen, Reply, Offer, none, State3};
                {error, Error} ->
                    ?LLOG(warning, "janus listen error: ~p", [Error], Session),
                    {error, janus_error, State2}
            end;
        {error, Error, State2} ->
            {error, Error, State2}
    end;

start(listen, _Session, State) ->
    {error, missing_parameters, State};

start(_Type, _Session, _State) ->
    continue.


%% @private
-spec answer(type(), nkmedia:answer(), session(), state()) ->
    {ok, map(), nkmedia:answer(), state()} |
    {error, term(), state()} | continue().

answer(Op, Answer, Session, #{janus_op:=answer}=State)
        when Op==proxy; Op==listen ->
    #{janus_pid:=Pid} = State,
    case nkmedia_janus_op:answer(Pid, Answer) of
        ok ->
            {ok, #{}, Answer, maps:remove(janus_op, State)};
        {ok, Answer2} ->
            {ok, #{answer=>Answer2}, Answer2, maps:remove(janus_op, State)};
        {error, {janus_error, Error}} ->
            {error, {janus_error, Error}, State};
        {error, Error} ->
            ?LLOG(warning, "janus answer error: ~p", [Error], Session),
            {error, janus_error, State}
    end;

answer(_Type, _Answer, _Session, _State) ->
    continue.


%% @private
-spec update(update(), map(), type(), nkmedia:session(), state()) ->
    {ok, type(), map(), state()} |
    {error, term(), state()} | continue().

update(media, Opts, Type, Session, #{janus_pid:=Pid}=State)
        when Type==echo; Type==proxy ->
    Opts2 = maps:with([use_audio, use_video, bitrate, record], Opts),
    {Opts3, State3} = add_record_opts(Session, Opts2, State),
    case nkmedia_janus_op:update(Pid, Opts3) of
        ok ->
            {ok, Type, #{}, State3};
        {error, {janus_error, Error}} ->
            {error, {janus_error, Error}, State3};
        {error, Error} ->
            ?LLOG(warning, "janus update error: ~p", [Error], Session),
            {error, janus_error, State3}
    end;

update(listen_switch, #{publisher:=Publisher}, listen, Session, #{janus_pid:=Pid}=State) ->
    case nkmedia_janus_op:listen_switch(Pid, Publisher, #{}) of
        ok ->
            {ok, listen, #{publisher=>Publisher}, State};
        {error, Error} ->
            ?LLOG(warning, "janus listen switch error: ~p", [Error], Session),
            {error, janus_error, State}
    end;

update(_Update, _Opts, _Type, _Session, _State) ->
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
get_janus(#{id:=SessId}=Session, #{janus_id:=JanusId}=State) ->
    case nkmedia_janus_op:start(JanusId, SessId) of
        {ok, Pid} ->
            State2 = State#{janus_pid=>Pid, janus_mon=>monitor(process, Pid)},
            {ok, Pid, State2};
        {error, Error} ->
            ?LLOG(warning, "janus connection start error: ~p", [Error], Session),
            {error, janus_connection_error, State}
    end;

get_janus(Session, State) ->
    case get_mediaserver(Session, State) of
        {ok, State2} ->
            get_janus(Session, State2);
        {error, Error} ->
            ?LLOG(warning, "get_mediaserver error: ~p", [Error], Session),
            {error, no_mediaserver, State}
    end.



%% @private
-spec get_mediaserver(session(), state()) ->
    {ok, state()} | {error, term()}.

get_mediaserver(_Session, #{janus_id:=_}=State) ->
    {ok, State};

get_mediaserver(#{srv_id:=SrvId}=Session, State) ->
    case SrvId:nkmedia_janus_get_mediaserver(Session) of
        {ok, Id} ->
            {ok, State#{janus_id=>Id}};
        {error, Error} ->
            {error, Error}
    end.


%% @private
add_record_opts(#{id:=SessId}, #{record:=true}=Opts, State) ->
    Pos = maps:get(janus_record_pos, State, 0),
    Name = io_lib:format("~s_p~4..0w", [SessId, Pos]),
    File = filename:join(<<"/tmp/record">>, list_to_binary(Name)),
    {Opts#{filename => File}, State#{janus_record_pos=>Pos+1}};

add_record_opts(_Session, Opts, State) ->
    {Opts, State}.




