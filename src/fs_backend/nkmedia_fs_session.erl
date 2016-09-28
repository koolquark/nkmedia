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

-export([start/3, offer/4, answer/4, cmd/3, stop/2]).
-export([handle_call/3, handle_cast/2, fs_event/3]).

-export_type([session/0, type/0, opts/0, cmd/0]).

-define(LLOG(Type, Txt, Args, Session),
    lager:Type("NkMEDIA FS Session ~s "++Txt, 
               [maps:get(session_id, Session) | Args])).

-define(LLOG2(Type, Txt, Args, SessId),
    lager:Type("NkMEDIA FS Session ~s "++Txt, 
               [SessId | Args])).


-include("../../include/nkmedia.hrl").



%% ========================= ==========================================
%% Types
%% ===================================================================

-type session_id() :: nkmedia_session:id().
-type continue() :: continue | {continue, list()}.


-type session() :: 
    nkmedia_session:session() |
    #{
        nkmedia_fs_id => nmedia_fs_engine:id(),
        nkmedia_fs_uuid => binary()
    }.
    

-type type() ::
    nkmedia_session:type() |
    park    |
    echo    |
    mcu     |
    bridge.


-type opts() ::  
    nkmedia_session:session() |
    #{
    }.


-type cmd() ::
    nkmedia_session:cmd().


-type fs_event() ::
    parked | {bridge, session_id()} | {mcu, map()} | destroy | hangup |
    verto_stop | verto_hangup.



%% ===================================================================
%% External
%% ===================================================================


%% @private Called from nkmedia_fs_engine and nkmedia_fs_verto
-spec fs_event(session_id(), nkmedia_fs:id(), fs_event()) ->
    ok.

fs_event(SessId, FsId, Event) ->
    % lager:error("Event: ~s: ~p", [SessId, Event]),
    case session_cast(SessId, {fs_event, FsId, Event}) of
        ok -> 
            ok;
        {error, _} when Event==stop ->
            ok;
        {error, _} -> 
            ?LLOG2(warning, "FS event ~p for unknown session", [Event], SessId) 
    end.





%% ===================================================================
%% Callbacks
%% ===================================================================


%% @private
-spec start(nkmedia_session:type(), nkmedia:role(), session()) ->
    {ok, session()} |
    {error, nkservice:error(), session()} | continue().

start(Type, Role, Session) ->
    case is_supported(Type) of
        true ->
            Update = #{
                backend => nkmedia_fs, 
                no_offer_trickle_ice => true,
                no_answer_trickle_ice => true
            },
            Session2 = ?SESSION(Update, Session),
            case get_engine(Session2) of
                {ok, Session3} when Role==offeree ->
                    % Wait for the offer (it could has been updated by a callback)
                    {ok, Session3};
                {ok, Session3} when Role==offerer ->
                    start_offerer(Type, Session3);
                {error, Error} ->
                    {error, Error, Session2}
            end;
        false ->
            continue
    end.


%% @private Someone set the offer
-spec offer(type(), nkmedia:role(), nkmedia:offer(), session()) ->
    {ok, session()} | {error, nkservice:error(), session()} | continue.

offer(_Type, offerer, _Offer, _Session) ->
    % We generated the offer
    continue;

offer(Type, offeree, Offer, Session) ->
    case start_offeree(Type, Offer, Session) of
        {ok, Session2} ->
            {ok, Offer, Session2};
        {error, Error, Session2} ->
            {error, Error, Session2}
    end.



%% @private We generated the offer, let's process the answer
-spec answer(type(), nkmedia:role(), nkmedia:answer(), session()) ->
    {ok, session()} | {error, nkservice:error(), session()}.

answer(_Type, offeree, _Answer, _Session) ->
    % We generated the answer
    continue;

answer(Type, offerer, Answer, #{nkmedia_fs_uuid:=UUID, offer:=Offer}=Session) ->
    SdpType = maps:get(sdp_type, Offer, webrtc),
    Mod = fs_mod(SdpType),
    case Mod:answer_out(UUID, Answer) of
        ok ->
            wait_park(Session),
            case do_start_type(Type, Session) of
                {ok, Session2} ->
                    {ok, Answer, Session2};
                {error, Error, Session2} ->
                    {error, Error, Session2}
            end;
        {error, Error} ->
            {error, Error, Session}
    end.


%% @private
-spec cmd(cmd(), Opts::map(), session()) ->
    {ok, Reply::term(), session()} | {error, term(), session()} | continue().

cmd(type, #{type:=Type}=Opts, Session) ->
    case do_type(Type, Opts, Session) of
        {ok, TypeExt, Session2} -> 
            update_type(Type, TypeExt),
            {ok, TypeExt, Session2};
        {error, Error, Session2} ->
            {error, Error, Session2}
    end;

cmd(start_record, _Opts, Session) ->
    {error, not_implemented, Session};

cmd(stop_record, _Opts, Session) ->
    {error, not_implemented, Session};

cmd(media, _Opts, Session) ->
    {error, not_implemented, Session};

cmd(layout, #{layout:=Layout}, #{type:=mcu}=Session) ->
    #{type_ext:=#{room_id:=Room}=Ext, nkmedia_fs_id:=FsId} = Session,
    case nkmedia_fs_cmd:conf_layout(FsId, Room, Layout) of
        ok  ->
            update_type(mcu, Ext#{layout=>Layout}),
            {ok, #{}, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

cmd(_Update, _Opts, _Session) ->
    continue.


%% @private
-spec stop(nkservice:error(), session()) ->
    {ok, session()}.

stop(_Reason, #{nkmedia_fs_uuid:=UUID, nkmedia_fs_id:=FsId}=Session) ->
    ?LLOG(info, "session stop: ~p", [_Reason], Session),
    Session2 = reset_type(Session),
    nkmedia_fs_cmd:hangup(FsId, UUID),
    {ok, Session2};

stop(_Reason, Session) ->
    {ok, Session}.


%% @private Called from nkmedia_fs_callbacks
handle_call({bridge, PeerId, PeerUUID}, _From, Session) ->
    ?LLOG(info, "sending bridge to ~s", [PeerId], Session),
    case fs_bridge(PeerUUID, Session) of
        ok ->
            update_type(bridge, #{peer_id=>PeerId}),
            ?LLOG(info, "received remote ~s bridge request", [PeerId], Session),
            {reply, ok, Session};
        {error, Error} ->
            ?LLOG(notice, "error when received remote ~s bridge: ~p", 
                  [PeerId, Error], Session),
            {reply, {error, Error}, Session}
    end.


%% @private Called from nkmedia_fs_callbacks
handle_cast({bridge_stop, PeerId}, 
            #{type:=bridge, type_ext:=#{peer_id:=PeerId}}=Session) ->
    ?LLOG(info, "received bridge stop from ~s", [PeerId], Session),
    case Session of
        #{stop_after_peer:=false} ->
            % In case we were linked
            nkmedia_session:unlink_session(self(), PeerId),
            update_type(park, #{}),
            {noreply, Session};
        _ ->
            nkmedia_session:stop(self(), bridge_stop),
            {noreply, Session}
    end;

handle_cast({bridge_stop, PeerId}, Session) ->
    ?LLOG(notice, "ignoring bridge stop from ~s", [PeerId], Session),
    {noreply, Session};

handle_cast({fs_event, FsId, Event}, #{nkmedia_fs_id:=FsId, type:=Type}=Session) ->
    Session2 = do_fs_event(Event, Type, Session),
    {noreply, Session2};

handle_cast({fs_event, _FsId, _Event}, Session) ->
    ?LLOG(warning, "received FS Event for unknown FsId!", [], Session),
    {noreply, Session}.



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
is_supported(park) -> true;
is_supported(echo) -> true;
is_supported(mcu) -> true;
is_supported(bridge) -> true;
is_supported(_) -> false.


%% @private
-spec start_offerer(type(), session()) ->
    {ok, session()} |
    {error, nkservice:error(), session()} | continue().

%% We must make the offer
start_offerer(_Type, Session) ->
    case get_fs_offer(Session) of
        {ok, Session2} ->
            {ok, Session2};
        {error, Error, Session} ->
            {error, Error, Session}
    end.
                    

%% @private
-spec start_offeree(type(), nkmedia:offer(), session()) ->
    {ok, session()} |
    {error, nkservice:error(), session()} | continue().

start_offeree(Type, Offer, Session) ->
    case get_fs_answer(Offer, Session) of
        {ok, Session2}  ->
            do_start_type(Type, Session2);
        {error, Error} ->
            {error, Error, Session}
    end.


%% @private
-spec do_start_type(type(), session()) ->
    {ok, session()} | {error, nkservice:error(), session()}.

do_start_type(Type, Session) ->
    case do_type(Type, Session, Session) of
        {ok, TypeExt, Session2} ->
            update_type(Type, TypeExt),
            {ok, Session2};
        {error, Error, Session2} ->
            {error, Error, Session2}
    end.


%% @private
-spec do_type(type(), map(), session()) ->
    {ok, nkmedia_session:type_ext(), session()} |
    {error, nkservice:error(), session()}.

do_type(park, _Opts, #{type:=park}=Session) ->
    {ok, #{}, Session};
    
do_type(park, _Opts, Session) ->
    Session2 = reset_type(Session),
    case fs_transfer("park", Session2) of
        ok ->
            {ok, #{}, Session2};
        {error, Error} ->
            {error, Error, Session2}
    end;

do_type(echo, _Opts, Session) ->
    Session2 = reset_type(Session),
    case fs_transfer("echo", Session2) of
        ok ->
            {ok, #{}, Session2};
        {error, Error} ->
            {error, Error, Session2}
    end;

do_type(mcu, Opts, Session) ->
    Session2 = reset_type(Session),
    Room = case maps:find(room_id, Opts) of
        {ok, Room0} -> nklib_util:to_binary(Room0);
        error -> nklib_util:uuid_4122()
    end,
    RoomType = maps:get(room_profile, Opts, <<"video-mcu-stereo">>),
    Cmd = [<<"conference:">>, Room, <<"@">>, RoomType],
    case fs_transfer(Cmd, Session2) of
        ok ->
            TypeExt = #{room_id=>Room, room_profile=>RoomType},
            {ok, TypeExt, Session2};
        {error, Error} ->
            {error, Error, Session2}
    end;

do_type(bridge, #{peer_id:=PeerId}, Session) ->
    #{session_id:=SessId, nkmedia_fs_uuid:=UUID} = Session,
    Session2 = reset_type(Session),
    case session_call(PeerId, {bridge, SessId, UUID}) of
        ok ->
            ?LLOG(info, "bridged accepted at ~s", [PeerId], Session),
            {ok, #{peer_id=>PeerId}, Session2};
        {error, Error} ->
            ?LLOG(notice, "bridged not accepted at ~s", [PeerId], Session),
            {error, Error, Session2}
    end;

do_type(bridge, #{master_peer:=PeerId}=Opts, Session) ->
    do_type(bridge, Opts#{peer_id=>PeerId}, Session);

do_type(_Type, _Opts, Session) ->
    {error, invalid_operation, Session}.


%% @private
get_fs_answer(Offer, #{nkmedia_fs_id:=FsId, session_id:=SessId}=Session) ->
    Type = maps:get(sdp_type, Offer, webrtc),
    Mod = fs_mod(Type),
    case Mod:start_in(SessId, FsId, Offer) of
        {ok, UUID, SDP} ->
            wait_park(Session),
            Answer = #{
                sdp => SDP,
                trickle_ice => false,
                sdp_type => Type,
                backend => nkmedia_fs
            },
            Session2 = ?SESSION(#{answer=>Answer, nkmedia_fs_uuid=>UUID}, Session),
            {ok, Session2};
        {error, Error} ->
            ?LLOG(warning, "error calling start_in: ~p", [Error], Session),
            {error, fs_get_answer_error}
    end.



%% @private
get_fs_offer(#{nkmedia_fs_id:=FsId, session_id:=SessId}=Session) ->
    Type = maps:get(sdp_type, Session, webrtc),
    Mod = fs_mod(Type),
    case Mod:start_out(SessId, FsId, #{}) of
        {ok, UUID, SDP} ->
            Offer = #{
                sdp => SDP,
                trickle_ice => false,
                sdp_type => Type,
                backend => nkmedia_fs
            },
            {ok, ?SESSION(#{offer=>Offer, nkmedia_fs_uuid=>UUID}, Session)};
        {error, Error} ->
            ?LLOG(warning, "error calling start_out: ~p", [Error], Session),
            {error, fs_get_offer_error}
    end.


%% @private
-spec get_engine(session()) ->
    {ok, session()} | {error, term()}.

get_engine(#{nkmedia_fs_id:=_}=Session) ->
    {ok, Session};

get_engine(#{srv_id:=SrvId}=Session) ->
    case SrvId:nkmedia_fs_get_mediaserver(SrvId) of
        {ok, Id} ->
            {ok, ?SESSION(#{nkmedia_fs_id=>Id}, Session)};
        {error, Error} ->
            {error, Error}
    end.


%% @private. The type must be fixed again after calling this function
-spec reset_type(session()) ->
    session().

reset_type(#{session_id:=SessId}=Session) ->
    % TODO: Check player
    case Session of
        #{type:=bridge, type_ext:=#{peer_id:=PeerId}} ->
            ?LLOG(info, "sending bridge stop to ~s", [PeerId], Session),
            % In case we were linked
            nkmedia_session:unlink_session(self(), PeerId),
            session_cast(PeerId, {bridge_stop, SessId}),
            ok;
        _ ->
            ok
    end,
    Session.


%% @private
fs_transfer(Dest, Session) ->
    #{nkmedia_fs_id:=FsId, nkmedia_fs_uuid:=UUID} = Session,
    ?LLOG(info, "sending transfer to ~s", [Dest], Session),
    case nkmedia_fs_cmd:transfer_inline(FsId, UUID, Dest) of
        ok ->
            ok;
        {error, Error} ->
            ?LLOG(warning, "transfer error: ~p", [Error], Session),
            {error, fs_transfer_error}
    end.


%% @private
fs_bridge(UUID_B, Session) ->
    #{nkmedia_fs_id:=FsId, nkmedia_fs_uuid:=UUID_A} = Session,
    case fs_set_park(FsId, UUID_A) of
        ok ->
            case fs_set_park(FsId, UUID_B) of
                ok ->
                    nkmedia_fs_cmd:bridge(FsId, UUID_A, UUID_B);
                {error, Error} ->
                    ?LLOG(warning, "FS bridge error: ~p", [Error], Session),
                    error
            end;
        {error, Error} ->
            ?LLOG(warning, "FS bridge error: ~p", [Error], Session),
            {error, fs_bridge_error}
    end.


%% @private
fs_set_park(FsId, UUID) ->
    nkmedia_fs_cmd:set_var(FsId, UUID, "park_after_bridge", "true").


%% @private
do_fs_event(parked, park, Session) ->
    Session;

do_fs_event(parked, bridge, Session) ->
    Session2 = reset_type(Session),
    case Session2 of
        #{stop_after_peer:=false} ->
            ?LLOG(notice, "received parked in bridge!1", [], Session),
            update_type(park, #{});
        _ ->
            ?LLOG(notice, "received parked in bridge!2", [], Session),
            nkmedia_session:stop(self(), bridge_stop)
    end,
    Session2;

do_fs_event(parked, _Type, Session) ->
    ?LLOG(notice, "received parked in ~p!", [_Type], Session),
    nkmedia_session:stop(self(), fs_channel_parked),
    Session;

do_fs_event({bridge, PeerId}, bridge, Session) ->
    case Session of
        #{type_ext:=#{peer_id:=PeerId}} ->
            ok;
        #{type_ext:=Ext} ->
            ?LLOG(warning, "received bridge for different peer ~s: ~p!", 
                  [PeerId, Ext], Session)
    end,
    update_type(bridge, #{peer_id=>PeerId}),
    Session;

do_fs_event({bridge, PeerId}, Type, Session) ->
    ?LLOG(warning, "received bridge in ~p state", [Type], Session),
    update_type(bridge, #{peer_id=>PeerId}),
    Session;

do_fs_event({mcu, Info}, mcu, #{type_ext:=Ext}=Session) ->
    ?LLOG(info, "FS MCU Info: ~p", [Info], Session),
    update_type(mcu, maps:merge(Ext, Info)),
    Session;

do_fs_event({mcu, Info}, Type, Session) ->
    ?LLOG(warning, "received mcu in ~p state", [Type], Session),
    update_type(mcu, Info),
    Session;

do_fs_event(Stop, _Type, Session)
        when Stop==hangup; Stop==destroy; Stop==verto_stop; Stop==verto_hangup ->
   ?LLOG(info, "received hangup from FS: ~p", [Stop], Session),
    nkmedia_session:stop(self(), fs_channel_stop),
    Session;
 
do_fs_event(Event, Type, Session) ->
    ?LLOG(warning, "received FS event ~p in type '~p'!", [Event, Type], Session).


%% @private
fs_mod(webrtc) ->nkmedia_fs_verto;
fs_mod(rtp) -> nkmedia_fs_sip.



%% @private
wait_park(Session) ->
    receive
        {'$gen_cast', {nkmedia_fs, {fs_event, _, parked}}} -> ok
    after 
        2000 -> 
            ?LLOG(warning, "parked not received", [], Session)
    end.


%% @private
update_type(Type, TypeExt) ->
    nkmedia_session:set_type(self(), Type, TypeExt).


%% @private
session_call(SessId, Msg) ->
    nkmedia_session:do_call(SessId, {nkmedia_fs, Msg}).


%% @private
session_cast(SessId, Msg) ->
    nkmedia_session:do_cast(SessId, {nkmedia_fs, Msg}).




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

