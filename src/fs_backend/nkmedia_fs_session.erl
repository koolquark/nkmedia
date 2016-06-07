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

-export([init/2, terminate/2, offer_op/4, answer_op/4, update/4]).
-export([fs_event/3, do_fs_event/2]).
-export([updated_answer/3, hangup/3, peer_event/3]).

-export_type([config/0, offer_op/0, answer_op/0, update/0, op_opts/0]).

-define(LLOG(Type, Txt, Args, Session),
    lager:Type("NkMEDIA FS Session ~s (~p) "++Txt, 
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
    pbx.


-type answer_op() ::
    nkmedia_session:answer_op() |
    pbx     |
    echo    |
    mcu     |
    join.


-type update() ::
    nkmedia_session:update() |
    echo    |
    mcu     |
    join.

-type op_opts() ::  
    nkmedia_session:op_opts() |
    #{
    }.


-type fs_event() ::
    parked | {hangup, term()} | {bridge, id()} | {mcu, map()}.


-type state() ::
    #{
        fs_id => nmedia_fs_engine:id(),
        dir => in | out,
        peer => {id(), reference()},
        invite => {id(), pid(), nkmedia_session:call_dest(), map()}
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
            lager:warning("NkMEDIA Session: pbx event ~p for unknown session ~s", 
                          [Event, SessId])
    end.




%% ===================================================================
%% Callbacks
%% ===================================================================


-spec init(id(), session()) ->
    {ok, session()}.

init(_Id, Session) ->
    {ok, maps:merge(#{nkmedia_fs=>#{}}, Session)}.


%% @doc Called when the session stops
-spec terminate(Reason::term(), session()) ->
    {ok, session()}.

terminate(_Reason, Session) ->
    {ok, Session}.


%% @private You must generte an offer() for this offer_op()
%% ReplyOpts will only we used for user notification
-spec offer_op(offer_op(), op_opts(), state(), session()) ->
    {ok, nkmedia:offer(), ReplyOpts::map(), session()} |
    {error, term(), session()} | continue().

offer_op(pbx, Opts, State, Session) ->
    case get_pbx_offer(Opts, State, Session) of
        {ok, Offer, Session2} ->
            {ok, {offer, Offer}, #{}, Session2};
        {error, Error} ->
            {error, Error, Session}
    end;

offer_op(_Op, _Opts, _State, _Session) ->
    continue.


%% @private
-spec answer_op(answer_op(), op_opts(), state(), session()) ->
    {ok, nkmedia:answer(), ReplyOpts::map(), session()} |
    {error, term(), session()} | continue().

answer_op(pbx, Opts, State, Session) ->
    case place_in_pbx(Opts, State, Session) of
        {ok, Answer, Session2} ->
            {ok, {answer, Answer}, #{}, Session2};
        {error, Error} ->
            {error, Error, Session}
    end;

answer_op(Op, Opts, State, Session) when Op==echo; Op==mcu ->
    case place_in_pbx(Opts, State, Session) of
        {ok, Answer, Session2} ->
            case update(Op, Opts, State, Session2) of
                {ok, Opts2, Session3} ->
                    {ok, {answer, Answer}, Opts2, Session3};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error, Session}
    end;

answer_op({invite, Dest}, Opts, State, #{srv_id:=SrvId, id:=Id}=Session) ->
    case maps:find(dir, State) of
        {ok, out} ->
            % Standard invite
            continue;
        {ok, in} ->
            {error, incompatible_operation, Session};
        error ->
            case place_in_pbx(Opts, State, Session) of
                {ok, Answer, Session2} ->
                    {ok, IdB, Pid} = nkmedia_session:start(SrvId, #{}),
                    ok = nkmedia_session:link_session(Pid, Id),
                    case nkmedia_session:offer_op(Pid, pbx, #{}) of
                        {ok, _} ->
                            ok = nkmedia_session:answer_op(Pid, {invite, Dest}, 
                                                           #{async=>true}),
                            Opts2 = Opts#{fs_peer=>IdB},
                            {ok, {answer, Answer}, Opts2, Session2};
                        {error, Error} ->
                            {error, Error, Session}
                    end;
                {error, Error} ->
                    {error, Error, Session}
            end
    end;

answer_op(_Op, _Opts, _From, _Session) ->
    continue.


%% @private
-spec update(update(), op_opts(), state(), session()) ->
    {ok, nkmedia:op_opts(), session()} |
    {error, term(), session()} | continue().

update(echo, _Opts, State, Session) ->
    case pbx_transfer("echo", State, Session) of
        ok ->
            {ok, #{}, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

update(mcu, Opts, State, Session) ->
    case maps:find(room, Opts) of
        {ok, Room} -> ok;
        error -> Room = nklib_util:uuid_4122()
    end,
    Type = maps:get(room_type, Opts, <<"video-mcu-stereo">>),
    Cmd = [<<"conference:">>, Room, <<"@">>, Type],
    case pbx_transfer(Cmd, State, Session) of
        ok ->
            {ok, #{room=>Room, room_type=>Type}, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

update(join, #{peer:=PeerId}, State, Session) ->
    case pbx_bridge(PeerId, State, Session) of
        ok ->
            {ok, #{peer_id=>PeerId}, Session};
        {error, Error} ->
            {error, Error, Session}
    end;

update({invite, Dest}, _Opts, #{dir:=in}, #{id:=SessId, srv_id:=SrvId}=Session) ->
    {ok, SessIdB, _Pid} = nkmedia_session:start(SrvId, #{}),
    case nkmedia_session:offer_op(SessIdB, pbx, #{}) of
        {ok, _} ->
            ok = nkmedia_session:update(SessIdB, {link, SessId, self()}, #{}),
            ok = nkmedia_session:answer_op(SessIdB, {invite, Dest}, #{async=>true}),
            {ok, #{peer_id=>SessIdB}, Session};
        {error, Error} ->
            {error, {could_not_start_peer, Error}, Session}
    end;

update(_Update, _Opts, _State, _Session) ->
    continue.


%% @private
-spec updated_answer(nkmedia:answer(), state(), session()) ->
    {ok, nkmedia:answer(), session()} |
    {error, term(), session()} | continue().

updated_answer(Answer, #{dir:=out}, #{id:=SessId, offer:=#{sdp_type:=Type}}=Session) ->
    Mod = fs_mod(Type),
    case Mod:answer_out(SessId, Answer) of
        ok ->
            wait_park(Session),
            {ok, Answer, Session};
        {error, Error} ->
            ?LLOG(warning, "error in answer_out: ~p", [Error], Session),
            {error, mediaserver_error}
    end;

updated_answer(_Answer, _State, _Session) ->
    continue.


%% @doc Called when the status of the session changes
-spec peer_event(nkmedia_session:event(), state(), session()) ->
    {ok, session()}.

peer_event(Event, _State, Session) ->
    ?LLOG(notice, "peer eventg: ~p", [Event], Session),
    {ok, Session}.


%% @private
-spec hangup(nkmedia:hangup_reason(), state(), session()) ->
    continue().

hangup(_Reason, #{fs_id:=FsId}, #{id:=SessId}) ->
    nkmedia_fs_cmd:hangup(FsId, SessId),
    continue;

hangup(_Reason, _State, _Session) ->
    continue.


%% @private Called from nkmedia_fs_engine and nkmedia_fs_verto
-spec do_fs_event(fs_event(), session()) ->
    {noreply, session()}.

do_fs_event(parked, #{status:=wait}=Session) ->
    {noreply, Session};

do_fs_event(parked, #{status:=Status}=Session) ->
    ?LLOG(warning, "received parked in ~p status!", [Status], Session),
    {noreply, Session};

do_fs_event({bridge, _Remote}, #{status:=Status}=Session) ->
    ?LLOG(warning, "received bridge in ~p status!", [Status], Session),
    {noreply, Session};

do_fs_event({mcu, _McuInfo}, #{status:=Status}=Session) ->
    ?LLOG(warning, "received mcu in ~p status!", [Status], Session),
    {noreply, Session};

do_fs_event({hangup, Reason}, Session) ->
    ?LLOG(warning, "received hangup from FS: ~p", [Reason], Session),
    nkmedia_session:hangup(self(), Reason),
    {noreply, Session};

do_fs_event(stop, Session) ->
    ?LLOG(warning, "received stop from FS", [], Session),
    nkmedia_session:hangup(self(), <<"FS Channel Stop">>),
    {noreply, Session};

do_fs_event(Event, Session) ->
    ?LLOG(warning, "unexpected ms event: ~p", [Event], Session),
    {noreply, Session}.



%% ===================================================================
%% Internal
%% ===================================================================



%% @private
place_in_pbx(_Opts, #{dir:=in}, _Session) ->
    {error, already_set};

place_in_pbx(_Opts, #{dir:=out}, _Session) ->
    {error, incompatible_direction};

place_in_pbx(_Opts, #{fs_id:=FsId}=State, #{id:=SessId, offer:=Offer}=Session) ->
    case nkmedia_fs_verto:start_in(SessId, FsId, Offer) of
        {ok, SDP} ->
            wait_park(Session),
            {ok, #{sdp=>SDP}, update(State#{dir=>in}, Session)};
        {error, Error} ->
            {error, Error, Session}
    end;

place_in_pbx(Opts, State, Session) ->
    case get_mediaserver(State, Session) of
        {ok, State2, Session2} ->
            place_in_pbx(Opts, State2, Session2);
        {error, Error} ->
            {error, Error, Session}
    end.



%% @private
get_pbx_offer(_Opts, #{dir:=out}, _Session) ->
    {error, already_set};

get_pbx_offer(_Opts, #{dir:=in}, _Session) ->
    {error, incompatible_direction};

get_pbx_offer(Opts, #{fs_id:=FsId}=State, #{id:=SessId}=Session) ->
    Type = maps:get(sdp_type, Opts, webrtc),
    Mod = fs_mod(Type),
    case Mod:start_out(SessId, FsId, #{}) of
        {ok, SDP} ->
            Session2 = update(State#{dir=>out}, Session),
            {ok, #{sdp=>SDP, sdp_type=>Type}, Session2};
        {error, Error} ->
            {error, {backend_out_error, Error}}
    end;

get_pbx_offer(Opts, State, Session) ->
    case get_mediaserver(State, Session) of
        {ok, State2, Session2} ->
            get_pbx_offer(Opts, State2, Session2);
        {error, Error} ->
            {error, {get_pbx_offer_error, Error}}
    end.


%% @private
-spec get_mediaserver(state(), session()) ->
    {ok, state(), session()} | {error, term()}.

get_mediaserver(#{fs_id:=_}, Session) ->
    {ok, Session};

get_mediaserver(State, #{srv_id:=SrvId}=Session) ->
    case SrvId:nkmedia_fs_get_mediaserver(Session) of
        {ok, Id, Session2} ->
            State2 = State#{fs_id=>Id},
            {ok, State2, update(State2, Session2)};
        {error, Error} ->
            {error, Error}
    end.



%% @private
pbx_transfer(Dest, #{fs_id:=FsId}, #{id:=SessId}=Session) ->
    ?LLOG(info, "sending transfer to ~s", [Dest], Session),
    case nkmedia_fs_cmd:transfer_inline(FsId, SessId, Dest) of
        ok ->
            ok;
        {error, Error} ->
            ?LLOG(warning, "pbx transfer error: ~p", [Error], Session),
            {error, transfer_error}
    end.


%% @private
pbx_bridge(SessIdB, #{fs_id:=FsId}, #{id:=SessIdA}=Session) ->
    case nkmedia_fs_cmd:set_var(FsId, SessIdA, "park_after_bridge", "true") of
        ok ->
            case nkmedia_fs_cmd:set_var(FsId, SessIdB, "park_after_bridge", "true") of
                ok ->
                    ?LLOG(info, "sending bridge to ~s", [SessIdB], Session),
                    nkmedia_fs_cmd:bridge(FsId, SessIdA, SessIdB);
                {error, Error} ->
                    ?LLOG(warning, "pbx bridge error: ~p", [Error], Session),
                    error
            end;
        {error, Error} ->
            ?LLOG(warning, "pbx bridge error: ~p", [Error], Session),
            {error, bridge_error}
    end.



%% @private
update(State, Session) ->
    Session#{nkmedia_fs:=State}.


%% @private
fs_mod(webrtc) ->nkmedia_fs_verto;
fs_mod(sip) -> nkmedia_fs_sip.


%% @private
wait_park(Session) ->
    receive
        {'$gen_cast', {fs_event, _, parked}} -> ok
    after 
        2000 -> 
            ?LLOG(warning, "parked not received", [], Session)
    end.
