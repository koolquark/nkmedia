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

-export([init/3, terminate/3, start/3, answer/4, candidate/4, update/5, stop/3]).

-export_type([config/0, type/0, opts/0, update/0]).

-define(LLOG(Type, Txt, Args, Session),
    lager:Type("NkMEDIA KMS Session ~s "++Txt, 
               [maps:get(session_id, Session) | Args])).

-include("../../include/nkmedia.hrl").

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
        kms_pid => pid(),
        kms_mon => reference(),
        kms_op => answer,
        record_pos => integer(),
        room_id => binary()
    }.




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

start(echo, #{offer:=#{sdp:=_}=Offer}=Session, State) ->
    case get_kms_op(Session, State) of
        {ok, Pid, State2} ->
            {Opts, State3} = get_opts(Session, State2),
            case nkmedia_kms_op:echo(Pid, Offer, Opts) of
                {ok, #{sdp:=_}=Answer} ->
                    Reply = ExtOps = #{answer=>Answer},
                    {ok, Reply, ExtOps, State3};
                {error, Error} ->
                    {error, Error, State3}
            end;
        {error, Error, State2} ->
            {error, Error, State2}
    end;

start(echo, _Session, State) ->
    {error, missing_offer, State};

% start(proxy, #{offer:=#{sdp:=_}=Offer}=Session, State) ->
%     case get_kms_op(Session, State) of
%         {ok, Pid, State2} ->
%             OfferType = maps:get(sdp_type, Offer, webrtc),
%             OutType = maps:get(proxy_type, Session, webrtc),
%             Fun = case {OfferType, OutType} of
%                 {webrtc, webrtc} -> videocall;
%                 {webrtc, rtp} -> to_sip;
%                 {rtp, webrtc} -> from_sip;
%                 {rtp, rtp} -> error
%             end,
%             case Fun of
%                 error ->
%                     {error, invalid_parameters, State};
%                 _ ->
%                     {Opts, State3} = get_opts(Session, State2),
%                     case nkmedia_kms_op:Fun(Pid, Offer, Opts) of
%                         {ok, Offer2} ->
%                             State4 = State3#{kms_op=>answer},
%                             Offer3 = maps:merge(Offer, Offer2),
%                             Reply = ExtOps = #{offer=>Offer3},
%                             {ok, Reply, ExtOps, State4};
%                         {error, Error} ->
%                             {error, Error, State3}
%                     end
%             end;
%         {error, Error, State2} ->
%             {error, Error, State2}
%     end;

% start(proxy, _Session, State) ->
%     {error, missing_offer, State};

% start(publish, #{srv_id:=SrvId, offer:=#{sdp:=_}=Offer}=Session, State) ->
%     try
%         RoomId = case maps:find(room_id, Session) of
%             {ok, RoomId0} -> 
%                 nklib_util:to_binary(RoomId0);
%             error -> 
%                 RoomOpts1 = [
%                     case maps:find(room_audio_codec, Session) of
%                         {ok, AC} -> {audio_codec, AC};
%                         error -> []
%                     end,
%                     case maps:find(room_video_codec, Session) of
%                         {ok, VC} -> {video_codec, VC};
%                         error -> []
%                     end,
%                     case maps:find(room_bitrate, Session) of
%                         {ok, BR} -> {bitrate, BR};
%                         error -> []
%                     end
%                 ],
%                 RoomOpts2 = maps:from_list(lists:flatten(RoomOpts1)),
%                 case nkmedia_room:start(SrvId, RoomOpts2) of
%                     {ok, Room0, _} -> Room0;
%                     {error, Error} -> throw(Error)
%                 end
%         end,
%         State2 = case nkmedia_room:get_room(RoomId) of
%             {ok, #{nkmedia_kms:=#{kms_id:=KmsId}}} ->
%                 State#{kms_id=>KmsId};
%             _ ->
%                 lager:error("NOT FOUND: ~p", [RoomId]),
%                 throw(room_not_found)
%         end,
%         case get_kms_op(Session, State2) of
%             {ok, Pid, State3} ->
%                 {Opts, State4} = get_opts(Session, State3),
%                 case nkmedia_kms_op:publish(Pid, RoomId, Offer, Opts) of
%                     {ok, #{sdp:=_}=Answer} ->
%                         Reply = #{answer=>Answer, room_id=>RoomId},
%                         ExtOps = #{answer=>Answer, type_ext=>#{room_id=>RoomId}},
%                         {ok, Reply, ExtOps, State4};
%                     {error, Error2} ->
%                         {error, Error2, State4}
%                 end;
%             {error, Error3, State3} ->
%                 {error, Error3, State3}
%         end
%     catch
%         throw:Throw -> {error, Throw, State}
%     end;

% start(publish, _Session, State) ->
%     {error, missing_offer, State};

% start(listen, #{publisher_id:=Publisher}=Session, State) ->
%     case nkmedia_session:do_call(Publisher, nkmedia_kms_get_room) of
%         {ok, _SrvId, Room} ->
%             case get_kms_op(Session, State) of
%                 {ok, Pid, State2} ->
%                     {Opts, State3} = get_opts(Session, State2),
%                     case nkmedia_kms_op:listen(Pid, Room, Publisher, Opts) of
%                         {ok, Offer} ->
%                             State4 = State3#{kms_op=>answer},
%                             Reply = #{offer=>Offer, room_id=>Room},
%                             ExtOps = #{
%                                 offer => Offer, 
%                                 type_ext => #{room_id=>Room, publisher_id=>Publisher}
%                             },
%                             {ok, Reply, ExtOps, State4};
%                         {error, Error} ->
%                             {error, Error, State3}
%                     end;
%                 {error, Error, State2} ->
%                     {error, Error, State2}
%             end;
%         _ ->
%             {error, unknown_publisher, State}
%     end;

% start(listen, _Session, State) ->
%     {error, missing_parameters, State};

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
-spec candidate(caller|callee, nkmedia:candidate(), session(), state()) ->
    ok | {error, term()}.

candidate(Role, Candidate, _Session, #{kms_pid:=Pid}) ->
    nkmedia_kms_op:candidate(Pid, Role, Candidate).


%% @private
-spec update(update(), map(), type(), nkmedia:session(), state()) ->
    {ok, type(), map(), state()} |
    {error, term(), state()} | continue().

% update(media, Opts, Type, #{session_id:=SessId}, #{kms_pid:=Pid}=State)
%         when Type==echo; Type==proxy; Type==publish ->
%     {Opts2, State2} = get_opts(Opts#{session_id=>SessId}, State),
%     case nkmedia_kms_op:update(Pid, Opts2) of
%         ok ->
%             {ok, #{}, #{}, State2};
%         {error, Error} ->
%             {error, Error, State2}
%     end;

% update(listen_switch, #{publisher_id:=Publisher}, listen, Session, 
%        #{kms_pid:=Pid}=State) ->
%     #{type_ext:=Ext} = Session,
%     case nkmedia_kms_op:listen_switch(Pid, Publisher, #{}) of
%         ok ->
%             ExtOps = #{type_ext=>Ext#{publisher_id:=Publisher}},
%             {ok, #{}, ExtOps, State};
%         {error, Error} ->
%             {error, Error, State}
%     end;

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
get_kms_op(#{session_id:=SessId}=Session, #{kms_id:=KmsId}=State) ->
    case nkmedia_kms_op:start(KmsId, SessId) of
        {ok, Pid} ->
            State2 = State#{kms_pid=>Pid, kms_mon=>monitor(process, Pid)},
            {ok, Pid, State2};
        {error, Error} ->
            ?LLOG(warning, "kms connection start error: ~p", [Error], Session),
            {error, kms_connection_error, State}
    end;

get_kms_op(Session, State) ->
    case get_mediaserver(Session, State) of
        {ok, State2} ->
            get_kms_op(Session, State2);
        {error, Error} ->
            ?LLOG(warning, "get_mediaserver error: ~p", [Error], Session),
            {error, no_mediaserver, State}
    end.



%% @private
-spec get_mediaserver(session(), state()) ->
    {ok, state()} | {error, term()}.

get_mediaserver(_Session, #{kms_id:=_}=State) ->
    {ok, State};

get_mediaserver(#{srv_id:=SrvId}, State) ->
    case SrvId:nkmedia_kms_get_mediaserver(SrvId) of
        {ok, Id} ->
            {ok, State#{kms_id=>Id}};
        {error, Error} ->
            {error, Error}
    end.


%% @private
get_opts(#{session_id:=SessId}=Session, State) ->
    Keys = [record, use_audio, use_video, use_data, bitrate, dtmf],
    Opts1 = maps:with(Keys, Session),
    Opts2 = case Session of
        #{user_id:=UserId} -> Opts1#{user=>UserId};
        _ -> Opts1
    end,
    case Session of
        #{record:=true} ->
            Pos = maps:get(record_pos, State, 0),
            Name = io_lib:format("~s_p~4..0w", [SessId, Pos]),
            File = filename:join(<<"/tmp/record">>, list_to_binary(Name)),
            {Opts2#{filename => File}, State#{record_pos=>Pos+1}};
        _ ->
            {Opts2, State}
    end.



