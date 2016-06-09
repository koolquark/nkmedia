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

-export([init/3, terminate/3, offer_op/5, answer_op/5, peer_event/5]).
-export([fs_event/3, do_fs_event/3]).
-export([updated_answer/3, hangup/3]).

-export_type([config/0, offer_op/0, answer_op/0, update/0, op_opts/0]).

-define(LLOG(Type, Txt, Args, Session),
    lager:Type("NkMEDIA FS Session ~s "++Txt, 
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

-type offer_op() ::
    nkmedia_session:offer_op() |
    park.


-type answer_op() ::
    nkmedia_session:answer_op() |
    park    |
    echo    |
    mcu     |
    join    |
    call.


-type update() ::
    nkmedia_session:update() |
    echo    |
    mcu     |
    join    |
    call.

-type op_opts() ::  
    nkmedia_session:op_opts() |
    #{
    }.


-type fs_event() ::
    parked | {hangup, term()} | {bridge, id()} | {mcu, map()}.


-type state() ::
    #{
        fs_id => nmedia_fs_engine:id(),
        fs_role => offer | answer,
        answer_op => {offer_op(), map()}
    }.


%% ===================================================================
%% Events
%% ===================================================================


%% @private Called from nkmedia_fs_engine and nkmedia_fs_verto
-spec fs_event(id(), nkmedia_fs:id(), fs_event()) ->
    ok.

fs_event(SessId, FsId, Event) ->
    case nkmedia_session:do_cast(SessId, {fs_event, FsId, Event}) of
        ok -> 
            ok;
        {error, _} when Event==stop ->
            ok;
        {error, _} -> 
            lager:warning("NkMEDIA Session: FS event ~p for unknown session ~s", 
                          [Event, SessId])
    end.



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


%% @private You must generte an offer() for this offer_op()
%% ReplyOpts will only we used for user notification
-spec offer_op(offer_op(), op_opts(), boolean(), session(), state()) ->
    {ok, nkmedia:offer(), offer_op(), map(), session()} |
    {error, term(), state()} | continue().

offer_op(Op, Opts, false, Session, State) ->
    case is_supported(Op, Opts) of
        true ->
            case get_fs_offer(Opts, Session, State) of
                {ok, Offer, State2} when Op==park ->
                    {ok, Offer, park, #{}, State2};
                {ok, Offer, State2} ->
                    State3 = State2#{answer_op=>{Op, Opts}},
                    {ok, Offer, Op, #{}, State3};
                {error, Error, State2} ->
                    {error, Error, State2}
            end;
        false ->
            continue
    end;

offer_op(Op, Opts, true, Session, #{fs_role:=Role}=State) ->
    case is_supported(Op, Opts) of
        true when Role==offer ->
            update_op(Op, Opts, #{}, Session, State);
        true when Role==answer ->
            {error, incompatible_operation, State};
        false ->
            continue
    end;

offer_op(_Op, _Opts, _HasOffer, _Session, _State) ->
    continue.


%% @private
-spec answer_op(answer_op(), op_opts(), boolean(), session(), state()) ->
    {ok, nkmedia:answer(), ReplyOpts::map(), session()} |
    {error, term(), state()} | continue().

answer_op(Op, Opts, false, Session, State) ->
    case is_supported(Op, Opts) of
        true ->
            case get_fs_answer(Opts, Session, State) of
                {ok, Answer, State2} ->
                    update_op(Op, Opts, Answer, Session, State2);
                {error, Error, State2} ->
                    {error, Error, State2}
            end;
        false ->
            continue
    end;

answer_op(Op, Opts, true, Session, #{fs_role:=Role}=State) ->
    case is_supported(Op, Opts) of
        true when Role==answer ->
            update_op(Op, Opts, #{}, Session, State);
        true when Role==offer ->
            {error, incompatible_operation, State};
        false ->
            continue
    end;

answer_op(_Op, _Opts, _HasAnswer, _Session, _State) ->
    continue.


%% @private
-spec update_op(offer_op()|answer_op(), op_opts(), map(), session(), state()) ->
    {ok, map(), nkmedia:op(), nkmedia:op_opts(), state()} |
    {error, term(), state()} | continue().

update_op(park, _Opts, OffAns, Session, State) ->
    case fs_transfer("park", Session, State) of
        ok ->
            {ok, OffAns, park, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

update_op(echo, _Opts, OffAns, Session, State) ->
    case fs_transfer("echo", Session, State) of
        ok ->
            {ok, OffAns, echo, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

update_op(mcu, Opts, OffAns, Session, State) ->
    case maps:find(room, Opts) of
        {ok, Room} -> ok;
        error -> Room = nklib_util:uuid_4122()
    end,
    Type = maps:get(room_type, Opts, <<"video-mcu-stereo">>),
    Cmd = [<<"conference:">>, Room, <<"@">>, Type],
    case fs_transfer(Cmd, Session, State) of
        ok ->
            {ok, OffAns, mcu, #{room=>Room, room_type=>Type}, State};
        {error, Error} ->
            {error, Error, State}
    end;

update_op(bridge, #{peer:=PeerId, set_only:=true}, OffAns, _Session, State) ->
    {ok, OffAns, bridge, #{peer_id=>PeerId}, State};

update_op(bridge, #{peer:=PeerId}, OffAns, Session, State) ->
    case fs_bridge(PeerId, Session, State) of
        ok ->
            {ok, OffAns, bridge, #{peer_id=>PeerId}, State};
        {error, Error} ->
            {error, Error, State}
    end;

update_op(call, Opts, OffAns, Session, State) ->
    #{id:=Id, srv_id:=SrvId} = Session,
    #{dest:=Dest} = Opts,
    {ok, IdB, Pid} = nkmedia_session:start(SrvId, #{}),
    ok = nkmedia_session:link_session(Pid, Id, #{send_events=>true}),
    #{offer:=Offer} = Session,
    Offer2 = maps:remove(sdp, Offer),
    case nkmedia_session:offer(Pid, park, #{offer=>Offer2}) of
        {ok, _} ->
            ok = nkmedia_session:answer_async(Pid, invite, #{dest=>Dest}),
            % we switch the calling session to 'fake' invite
            % we will send it ringing, etc.
            {ok, OffAns, invite, Opts#{fs_peer=>IdB, fake=>true}, State};
        {error, Error} ->
            {error, Error, State}
    end.


%% @private
-spec updated_answer(nkmedia:answer(), session(), state()) ->
    {ok, nkmedia:answer(), state()} |
    {error, term(), state()} | continue().

updated_answer(Answer, Session, #{fs_role:=offer}=State) -> 
    #{id:=SessId, offer:=#{sdp_type:=Type}} = Session,
    Mod = fs_mod(Type),
    case Mod:answer_out(SessId, Answer) of
        ok ->
            wait_park(Session),
            case State of
                #{answer_op:={Op, Opts}} ->
                    nkmedia_session:offer_op_async(self(), Op, Opts),
                    {ok, Answer, maps:remove(answer_op, State)};
                _ ->
                    {ok, Answer, State}
            end;
        {error, Error} ->
            ?LLOG(warning, "error in answer_out: ~p", [Error], Session),
            {error, mediaserver_error, State}
    end;

updated_answer(_Answer, _Session, _State) ->
    continue.


%% @doc Called when a linked peer sends an event
-spec peer_event(id(), caller|callee, nkmedia_session:event(), session(), state()) ->
    any().

peer_event(IdB, callee, {answer_op, invite, Opts}, Session, State) ->
    case Opts of
        #{status:=ringing, answer:=Answer} ->
            nkmedia_session:invite_reply(self(), {ringing, Answer});
        #{status:=answered, answer:=Answer} ->
            nkmedia_session:invite_reply(self(), {answered, Answer}),
            case fs_bridge(IdB, Session, State) of
                ok ->
                    ok;
               {error, Error} ->
                    ?LLOG(warning, "bridge error: ~p", [Error], Session),
                    nkmedia_session:hangup(IdB(), <<"Bridge Error">>),
                    nkmedia_session:hangup(self(), <<"Bridge Error">>)
            end;
        #{status:=rejected, reason:=Reason} ->
            nkmedia_session:invite_reply(self(), {rejected, Reason});
        _ ->
            ok
    end;

peer_event(_Id, callee, {answer_op, _, _Opts}, _Session, _State) ->
    ok;

peer_event(_Id, caller, {answer_op, _, _Opts}, _Session, _State) ->
    ok;

peer_event(_Id, callee, {hangup, _Reason}, _Session, _State) ->
    %% Check if we must hangup
    ok;

peer_event(_Id, caller, {hangup, Reason}, _Session, _State) ->
    nkmedia_session:hangup(self(), Reason),
    ok;

peer_event(Id, Type, Event, Session, _State) ->
    ?LLOG(notice, "Peer ~s (~p) event: ~p", [Id, Type, Event], Session),
    ok.


%% @private
-spec hangup(nkmedia:hangup_reason(), session(), state()) ->
    {ok, state()}.

hangup(_Reason, #{id:=SessId}, #{fs_id:=FsId}=State) ->
    nkmedia_fs_cmd:hangup(FsId, SessId),
    {ok, State};

hangup(_Reason, _Session, State) ->
    {ok, State}.




%% ===================================================================
%% Internal
%% ===================================================================

%% @private
is_supported(park, _) -> true;
is_supported(echo, _) -> true;
is_supported(mcu, _) -> true;
is_supported(join, _) -> true;
is_supported(call, _) -> true;
is_supported(_, _) -> false.


%% @private
get_fs_answer(_Opts, _Session, #{fs_role:=answer}=State) ->
    {error, already_set, State};

get_fs_answer(_Opts, _Session, #{fs_role:=offer}=State) ->
    {error, incompatible_fs_role, State};

get_fs_answer(_Opts, #{id:=SessId, offer:=Offer}=Session,  #{fs_id:=FsId}=State) ->
    case nkmedia_fs_verto:start_in(SessId, FsId, Offer) of
        {ok, SDP} ->
            wait_park(Session),
            {ok, #{sdp=>SDP}, State#{fs_role=>answer}};
        {error, Error} ->
            {error, Error, State}
    end;

get_fs_answer(Opts, Session, State) ->
    case get_mediaserver(Session, State) of
        {ok, State2} ->
            get_fs_answer(Opts, Session, State2);
        {error, Error} ->
            {error, {get_fs_answer_error, Error}, State}
    end.



%% @private
get_fs_offer(_Opts, _Session, #{fs_role:=offer}=State) ->
    {error, already_set, State};

get_fs_offer(_Opts, _Session, #{fs_role:=answer}=State) ->
    {error, incompatible_fs_role, State};

get_fs_offer(Opts, #{id:=SessId}, #{fs_id:=FsId}=State) ->
    Offer = maps:get(offer, Opts, #{}),
    Type = maps:get(sdp_type, Offer, webrtc),
    Mod = fs_mod(Type),
    case Mod:start_out(SessId, FsId, #{}) of
        {ok, SDP} ->
            Offer2 = Offer#{sdp=>SDP, sdp_type=>Type},
            {ok, Offer2, State#{fs_role=>offer}};
        {error, Error} ->
            {error, {backend_out_error, Error}, State}
    end;

get_fs_offer(Opts, Session, State) ->
    case get_mediaserver(Session, State) of
        {ok, State2} ->
            get_fs_offer(Opts, Session, State2);
        {error, Error} ->
            {error, {get_fs_offer_error, Error}, State}
    end.


%% @private
-spec get_mediaserver(session(), state()) ->
    {ok, state()} | {error, term()}.

get_mediaserver(_Session, #{fs_id:=_}=State) ->
    {ok, State};

get_mediaserver(#{srv_id:=SrvId}=Session, State) ->
    case SrvId:nkmedia_fs_get_mediaserver(Session) of
        {ok, Id} ->
            {ok, State#{fs_id=>Id}};
        {error, Error} ->
            {error, Error}
    end.


%% @private
fs_transfer(Dest, #{id:=SessId}=Session, #{fs_id:=FsId}) ->
    ?LLOG(info, "sending transfer to ~s", [Dest], Session),
    case nkmedia_fs_cmd:transfer_inline(FsId, SessId, Dest) of
        ok ->
            ok;
        {error, Error} ->
            ?LLOG(warning, "FS transfer error: ~p", [Error], Session),
            {error, transfer_error}
    end.


%% @private
fs_bridge(SessIdB, #{id:=SessIdA}=Session, #{fs_id:=FsId}) ->
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
            {error, bridge_error}
    end.


%% @private Called from nkmedia_fs_engine and nkmedia_fs_verto
-spec do_fs_event(fs_event(), session(), state()) ->
    state().

do_fs_event(parked, Session, State) ->
    case get_op(Session, State) of
        {_, park, _} ->
            ok; 
        {offer_op, _, _} -> 
            nkmedia_session:offer_async(self(), park, #{});
        {answer_op, _, _} ->
            nkmedia_session:answer_async(self(), park, #{});
        unknown_op ->
            ?LLOG(warning, "received parked in unknown_op!", [], Session)
    end,
    {ok, State};

do_fs_event({bridge, IdB}, Session, State) ->
    Opts = #{peer=>IdB, set_only=>true},
    case get_op(Session, State) of
        {offer_op, _, _} -> 
            nkmedia_session:offer_async(self(), bridge, Opts);
        {answer_op, _, _} ->
            nkmedia_session:answer_async(self(), bridge, Opts);
        unknown_op ->
            ?LLOG(warning, "received bridge in unknown_op!", [], Session)
    end,
    {ok, State};

do_fs_event({mcu, McuInfo}, Session, State) ->
    ?LLOG(info, "FS MCU Info: ~p", [McuInfo], Session),
    {ok, State};

do_fs_event({hangup, Reason}, Session, State) ->
    ?LLOG(warning, "received hangup from FS: ~p", [Reason], Session),
    nkmedia_session:hangup(self(), Reason),
    {ok, State};

do_fs_event(stop, Session, State) ->
    ?LLOG(info, "received stop from FS", [], Session),
    nkmedia_session:hangup(self(), <<"FS Channel Stop">>),
    {ok, State};

do_fs_event(Event, Session, State) ->
    ?LLOG(warning, "unexpected ms event: ~p in ~p", 
          [Event, get_op(Session, State)], Session), 
    {ok, State}.


%% @private
fs_mod(webrtc) ->nkmedia_fs_verto;
fs_mod(rtp) -> nkmedia_fs_sip.


%% @private
get_op(#{offer_op:={Op, Data}}, #{fs_role:=offer}) -> {offer_op, Op, Data};
get_op(#{answer_op:={Op, Data}}, #{fs_role:=answer}) -> {answer_op, Op, Data};
get_op(_, _) -> unknown_op.



%% @private
wait_park(Session) ->
    receive
        {'$gen_cast', {fs_event, _, parked}} -> ok
    after 
        2000 -> 
            ?LLOG(warning, "parked not received", [], Session)
    end.
