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
-module(nkmedia_fs_session).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([init/3, terminate/3, start/3, answer/4, update/5, stop/3]).
-export([handle_cast/3, fs_event/3, send_bridge/2]).

-export_type([config/0, type/0, opts/0, update/0]).

-define(LLOG(Type, Txt, Args, Session),
    lager:Type("NkMEDIA FS Session ~s "++Txt, 
               [maps:get(session_id, Session) | Args])).


-include("../../include/nkmedia.hrl").



%% ========================= ==========================================
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
    park    |
    echo    |
    mcu     |
    bridge  |
    call.

-type type_ext() :: {type(), map()}.


-type opts() ::  
    nkmedia_session:session() |
    #{
    }.


-type update() ::
    nkmedia_session:update().


-type fs_event() ::
    parked | {hangup, term()} | {bridge, id()} | {mcu, map()} | stop.


-type state() ::
    #{
        fs_id => nmedia_fs_engine:id(),
        fs_role => offer | answer
    }.


%% ===================================================================
%% External
%% ===================================================================


%% @private Called from nkmedia_fs_engine and nkmedia_fs_verto
-spec fs_event(id(), nkmedia_fs:id(), fs_event()) ->
    ok.

fs_event(SessId, FsId, Event) ->
    case send_cast(SessId, {fs_event, FsId, Event}) of
        ok -> 
            ok;
        {error, _} when Event==stop ->
            ok;
        {error, _} -> 
            lager:warning("NkMEDIA Session: FS event ~p for unknown session ~s", 
                          [Event, SessId])
    end.


%% @private
send_bridge(Remote, Local) ->
    nkmedia_session:do_cast(Remote, {nkmedia_fs_session, {bridge, Local}}).





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
    {ok, type_ext(), map(), none|nkmedia:offer(), none|nkmedia:answer(), state()} |
    {error, term(), state()} | continue().

start(Type, #{offer:=#{sdp:=_}=Offer}=Session, State) ->
    Trickle = maps:get(trickle_ice, Offer, false),
    case is_supported(Type) of
        true when Trickle == true ->
            wait_trickle_ice;
        true ->  
            case get_fs_answer(Session, State) of
                {ok, Answer, State2}  ->
                    case Type of
                        park ->
                            Reply = ExtOps = #{answer=>Answer},
                            {ok, Reply, ExtOps, State2};
                        _ ->
                            case do_update(Type, Session, State2) of
                                {ok, Reply, ExtOps, State3} ->
                                    Reply2 = Reply#{answer=>Answer},
                                    ExtOps2 = ExtOps#{answer=>Answer},
                                    {ok, Reply2, ExtOps2, State3};
                                {error, Error, State3} ->
                                    {error, Error, State3};
                                continue ->
                                    {error, invalid_parameters, State2}
                            end
                    end;
                {error, Error, State2} ->
                    {error, Error, State2}
            end;
        false ->
            continue
    end;

start(Type, Session, State) ->
    case 
        (Type==call andalso maps:is_key(master_peer, Session))
        orelse is_supported(Type) 
    of
        true ->  
            case get_fs_offer(Session, State) of
                {ok, Offer, State2} ->
                    Reply = ExtOps = #{offer=>Offer},
                    {ok, Reply, ExtOps, State2};
                {error, Error, State2} ->
                    {error, Error, State2}
            end;
        false ->
            continue
    end.


%% @private
-spec answer(type(), nkmedia:answer(), session(), state()) ->
    {ok, map(), nkmedia:answer(), state()} |
    {error, term(), state()} | continue().

answer(Type, Answer, Session, #{fs_role:=offer}=State) ->
    #{session_id:=SessId, offer:=#{sdp_type:=SdpType}} = Session,
    Mod = fs_mod(SdpType),
    case Mod:answer_out(SessId, Answer) of
        ok ->
            wait_park(Session),
            case Type of
                park ->     
                    {ok, #{}, #{answer=>Answer}, State};
                call ->
                    % When we set the answer event, it will be captured
                    % in nkmedia_fs_callbacks
                    #{master_peer:=Peer} = Session,
                    {ok, #{}, #{answer=>Answer, type_ext=>#{peer=>Peer}}, State};
                _ ->
                    case do_update(Type, Session, State) of
                        {ok, Reply, ExtOps, State2} ->
                            {ok, Reply, ExtOps#{answer=>Answer}, State2};
                        {error, Error, State2} ->
                            {error, Error, State2};
                        continue ->
                            {error, invalid_parameters, State}
                    end
            end;
        {error, Error} ->
            ?LLOG(warning, "error in answer_out: ~p", [Error], Session),
            {error, fs_error, State}
    end;

answer(_Type, _Answer, _Session, _State) ->
    continue.


%% @private
-spec update(update(), map(), type(), nkmedia:session(), state()) ->
    {ok, type_ext(), map(), state()} |
    {error, term(), state()} | continue().

update(session_type, #{session_type:=Type}=Opts, _OldTytpe, Session, #{fs_id:=_}=State) ->
    do_update(Type, maps:merge(Session, Opts), State);

update(mcu_layout, #{mcu_layout:=Layout}, mcu, 
       #{type_ext:=#{room_id:=Room}=Ext}, #{fs_id:=FsId}=State) ->
    case nkmedia_fs_cmd:conf_layout(FsId, Room, Layout) of
        ok  ->
            ExtOps = #{type_ext=>Ext#{mcu_layout=>Layout}},
            {ok, #{}, ExtOps, State};
        {error, Error} ->
            {error, Error, State}
    end;

update(_Update, _Opts, _Type, _Session, _State) ->
    continue.


%% @private
-spec stop(nkservice:error(), session(), state()) ->
    {ok, state()}.

stop(_Reason, #{session_id:=SessId}, #{fs_id:=FsId}=State) ->
    nkmedia_fs_cmd:hangup(FsId, SessId),
    {ok, State};

stop(_Reason, _Session, State) ->
    {ok, State}.



%% ===================================================================
%% Private
%% ===================================================================


%% @private Called from nkmedia_fs_callbacks
-spec handle_cast(term(), session(), state()) ->
    {ok, state()}.

handle_cast({fs_event, FsId, Event}, #{type:=Type}=Session, State) ->
    case State of
        #{fs_id:=FsId} ->
            do_fs_event(Event, Type, Session, State);
        _ ->
            ?LLOG(warning, "received FS Event for unknown FsId!", [], State)
    end,
    {ok, State};

handle_cast({bridge, PeerId}, Session, State) ->
    ?LLOG(notice, "received remote ~s bridge request", [PeerId], Session),
    case fs_bridge(PeerId, Session, State) of
        ok ->
            Ops = #{type=>bridge, type_ext=>#{peer=>PeerId}},
            nkmedia_session:ext_ops(self(), Ops),
            {ok, State};
        {error, Error} ->
            {error, Error, State}
    end.


%% ===================================================================
%% Internal
%% ===================================================================


%% @private
do_update(park, Session, State) ->
    nkmedia_session:unlink_session(self()),
    case fs_transfer("park", Session, State) of
        ok ->
            {ok, #{}, #{type=>park}, State};
        {error, Error} ->
            {error, Error, State}
    end;

do_update(echo, Session, State) ->
    nkmedia_session:unlink_session(self()),
    case fs_transfer("echo", Session, State) of
        ok ->
            {ok, #{}, #{type=>echo}, State};
        {error, Error} ->
            {error, Error, State}
    end;

do_update(mcu, Session, State) ->
    nkmedia_session:unlink_session(self()),
    Room = case maps:find(room_id, Session) of
        {ok, Room0} -> nklib_util:to_binary(Room0);
        error -> nklib_util:uuid_4122()
    end,
    RoomType = maps:get(room_type, Session, <<"video-mcu-stereo">>),
    Cmd = [<<"conference:">>, Room, <<"@">>, RoomType],
    case fs_transfer(Cmd, Session, State) of
        ok ->
            ExtOps = #{type=>mcu, type_ext=>#{room_id=>Room, room_type=>RoomType}},
            {ok, #{room_id=>Room}, ExtOps, State};
        {error, Error} ->
            {error, Error, State}
    end;

do_update(bridge, #{session_id:=Id}=Session, State) ->
    nkmedia_session:unlink_session(self()),
    case Session of
        #{peer:=PeerId} ->
            send_bridge(PeerId, Id),
            ExtOps = #{type=>bridge, type_ext=>#{peer=>PeerId}},
            {ok, #{}, ExtOps, State};
        _ ->
            continue
    end;

do_update(_Op, _Session, _State) ->
    continue.


 %% @private
is_supported(park) -> true;
is_supported(echo) -> true;
is_supported(mcu) -> true;
is_supported(bridge) -> true;
is_supported(_) -> false.


%% @private
get_fs_answer(_Session, #{fs_role:=answer}=State) ->
    {error, answer_already_set, State};

get_fs_answer(_Session, #{fs_role:=offer}=State) ->
    {error, incompatible_fs_role, State};

get_fs_answer(#{session_id:=SessId, offer:=Offer}=Session,  #{fs_id:=FsId}=State) ->
    case nkmedia_fs_verto:start_in(SessId, FsId, Offer) of
        {ok, SDP} ->
            wait_park(Session),
            {ok, #{sdp=>SDP}, State#{fs_role=>answer}};
        {error, Error} ->
            ?LLOG(warning, "error calling start_in: ~p", [Error], Session),
            {error, fs_error, State}
    end;

get_fs_answer(Session, State) ->
    case get_mediaserver(Session, State) of
        {ok, State2} ->
            get_fs_answer(Session, State2);
        {error, Error} ->
            {error, Error, State}
    end.


%% @private
get_fs_offer(_Session, #{fs_role:=offer}=State) ->
    {error, offer_already_set, State};

get_fs_offer(_Session, #{fs_role:=answer}=State) ->
    {error, incompatible_fs_role, State};

get_fs_offer(#{session_id:=SessId}=Session, #{fs_id:=FsId}=State) ->
    Type = maps:get(proxy_type, Session, webrtc),
    Mod = fs_mod(Type),
    case Mod:start_out(SessId, FsId, #{}) of
        {ok, SDP} ->
            Offer = maps:get(offer, Session, #{}),
            Offer2 = Offer#{sdp=>SDP, sdp_type=>Type},
            {ok, Offer2, State#{fs_role=>offer}};
        {error, Error} ->
            ?LLOG(warning, "error calling start_out: ~p", [Error], Session),
            {error, fs_error, State}
    end;

get_fs_offer(Session, State) ->
    case get_mediaserver(Session, State) of
        {ok, State2} ->
            get_fs_offer(Session, State2);
        {error, Error} ->
            {error, Error, State}
    end.


%% @private
-spec get_mediaserver(session(), state()) ->
    {ok, state()} | {error, term()}.

get_mediaserver(_Session, #{fs_id:=_}=State) ->
    {ok, State};

get_mediaserver(#{srv_id:=SrvId}, State) ->
    case SrvId:nkmedia_fs_get_mediaserver(SrvId) of
        {ok, Id} ->
            {ok, State#{fs_id=>Id}};
        {error, Error} ->
            {error, Error}
    end.


%% @private
fs_transfer(Dest, #{session_id:=SessId}=Session, #{fs_id:=FsId}) ->
    ?LLOG(info, "sending transfer to ~s", [Dest], Session),
    case nkmedia_fs_cmd:transfer_inline(FsId, SessId, Dest) of
        ok ->
            ok;
        {error, Error} ->
            ?LLOG(warning, "FS transfer error: ~p", [Error], Session),
            {error, fs_op_error}
    end.


%% @private
fs_bridge(SessIdB, #{session_id:=SessIdA}=Session, #{fs_id:=FsId}) ->
    case nkmedia_fs_cmd:set_var(FsId, SessIdA, "park_after_bridge", "true") of
        ok ->
            case nkmedia_fs_cmd:set_var(FsId, SessIdB, "park_after_bridge", "true") of
                ok ->
                    ?LLOG(info, "sending bridge to ~s", [SessIdB], Session),
                    nkmedia_fs_cmd:bridge(FsId, SessIdA, SessIdB);
                {error, Error} ->
                    ?LLOG(warning, "FS bridge error: ~p", [Error], Session),
                    error
            end;
        {error, Error} ->
            ?LLOG(warning, "FS bridge error: ~p", [Error], Session),
            {error, fs_op_error}
    end.



%% @private
do_fs_event(parked, park, _Session, _State) ->
    ok;

do_fs_event(parked, _Type, Session, _State) ->
    case Session of
        #{park_after_bridge:=true} ->
            nkmedia_session:unlink_session(self()),
            nkmedia_session:ext_ops(self(), #{type=>park});
        _ ->
            nkmedia_session:stop(self(), peer_hangup)
    end;

do_fs_event({bridge, PeerId}, Type, Session, _State) when Type==bridge; Type==call ->
    case Session of
        #{type_ext:=#{peer:=PeerId}} ->
            ok;
        #{type_ext:=Ext} ->
            ?LLOG(warning, "received bridge for different peer ~s: ~p!", 
                  [PeerId, Ext], Session)
    end,
    nkmedia_session:ext_ops(self(), #{type=>bridge, type_ext=>#{peer=>PeerId}});

do_fs_event({bridge, PeerId}, Type, Session, _State) ->
    ?LLOG(warning, "received bridge in ~p state", [Type], Session),
    nkmedia_session:ext_ops(self(), #{type=>bridge, type_ext=>#{peer=>PeerId}});

do_fs_event({mcu, McuInfo}, mcu, Session, State) ->
    ?LLOG(info, "FS MCU Info: ~p", [McuInfo], Session),
    {ok, State};

do_fs_event(mcu, Type, Session, _State) ->
    ?LLOG(warning, "received mcu in ~p state", [Type], Session),
    nkmedia_session:ext_ops(self(), #{type=>mcu, type_ext=>#{}});

do_fs_event({hangup, Reason}, _Type, Session, State) ->
    ?LLOG(warning, "received hangup from FS: ~p", [Reason], Session),
    nkmedia_session:stop(self(), Reason),
    {ok, State};

do_fs_event(stop, _Type, Session, State) ->
    ?LLOG(info, "received stop from FS", [], Session),
    nkmedia_session:stop(self(), fs_channel_stop),
    {ok, State};

do_fs_event(Event, Type, Session, _State) ->
    ?LLOG(warning, "received FS event ~p in type '~p'!", [Event, Type], Session).


%% @private
fs_mod(webrtc) ->nkmedia_fs_verto;
fs_mod(rtp) -> nkmedia_fs_sip.



%% @private
wait_park(Session) ->
    receive
        {'$gen_cast', {nkmedia_fs_session, {fs_event, _, parked}}} -> ok
    after 
        2000 -> 
            ?LLOG(warning, "parked not received", [], Session)
    end.

%% @private
send_cast(SessId, Msg) ->
    nkmedia_session:do_cast(SessId, {nkmedia_fs_session, Msg}).




% Layouts
% 1up_top_left+5
% 1up_top_left+7
% 1up_top_left+9
% 1x1
% 1x1+2x1
% 1x2
% 2up_bottom+8
% 2up_middle+8
% 2up_top+8
% 2x1
% 2x1-presenter-zoom
% 2x1-zoom
% 2x2
% 3up+4
% 3up+9
% 3x1-zoom
% 3x2-zoom
% 3x3
% 4x2-zoom
% 4x4, 
% 5-grid-zoom
% 5x5
% 6x6
% 7-grid-zoom
% 8x8
% overlaps
% presenter-dual-horizontal
% presenter-dual-vertical
% presenter-overlap-large-bot-right
% presenter-overlap-large-top-right
% presenter-overlap-small-bot-right
% presenter-overlap-small-top-right

