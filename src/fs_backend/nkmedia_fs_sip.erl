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

%% @doc NkMEDIA FS SIP utilities
-module(nkmedia_fs_sip).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start_in/4, start_out/4, answer_out/2]).
-export([nkmedia_sip_invite/2, nkmedia_sip_bye/2]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).


% To debug, set debug => [nkmedia_fs_sip]

-define(DEBUG(Txt, Args, State),
    case erlang:get(nkmedia_fs_sip_debug) of
        true -> ?LLOG(debug, Txt, Args, State);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA FS SIP (~s) "++Txt, [State#state.session_id | Args])).

-define(TIMEOUT, 200000).

-include_lib("nklib/include/nklib.hrl").


%% ===================================================================
%% Types
%% ===================================================================


%% ===================================================================
%% Public
%% ===================================================================


%% @doc
%% We place a SIP-class SDP into FS and get an answer


-spec start_in(nkservice:id(), nkmedia_session:id(), nkmedia_fs:id(), nkmedia:offer()) ->
    {ok, UUID::binary(), SDP::binary()} | {error, term()}.

start_in(SrvId, SessId, FsId, #{sdp:=SDP}) ->
    {ok, Pid} = gen_server:start(?MODULE, [in, SrvId, FsId, SessId, SDP], []),
    case nkservice_util:call(Pid, get_uuid) of
        {ok, UUID} ->
            Reply = case nkservice_util:call(Pid, get_sdp) of
                {ok, SDP2} -> {ok, UUID, SDP2};
                {error, Error} -> {error, Error}
            end,
            gen_server:cast(Pid, stop),
            Reply;
        {error, Error} ->
            {error, Error}
    end.


%% @doc
%% Generates an SIP request from FS to us
%% FS will send an INVITE to us, using this module in the URI
%% It will be captured at nkmedia_core:sip_invite/3, and nkmedia_sip_invite/3
%% will be called, calling us with the SDP
%% We reply 'ringing' to FS. We return the SDP
%% Later on, nkmedia_fs_session will call answer_out/2
-spec start_out(nkservice:id(), nkmedia_session:id(), nkmedia_fs:id(), map()) ->
    {ok, UUID::binary(), SDP::binary()} | {error, term()}.

start_out(SrvId, SessId, FsId, #{}) ->
    {ok, Pid} = gen_server:start(?MODULE, [out, SrvId, FsId, SessId], []),
    case nkservice_util:call(Pid, get_sdp) of
        {ok, SDP} -> {ok, SessId, SDP};
        {error, Error} -> {error, Error}
    end.



%% @doc
-spec answer_out(nkmedia_session:id(), nkmedia:answer()) ->
    ok | {error, term()}.

answer_out(SessId, Answer) ->
    case find(SessId) of
        {ok, Pid} ->
            nkservice_util:call(Pid, {answer, Answer});
        [] ->
            {error, unknown_session}
    end.


%% @private Called from nkmedia_core
nkmedia_sip_invite(SessId, Req) ->
    case find(SessId) of
        {ok, Pid} ->
            {ok, Handle} = nksip_request:get_handle(Req),
            {ok, Dialog} = nksip_dialog:get_handle(Req),
            {ok, SDP} = nksip_request:body(Req),
            SDP2 = nksip_sdp:unparse(SDP),
            nkservice_util:call(Pid, {sip_invite, Handle, Dialog, SDP2});
        not_found ->
            lager:warning("Received unexpected INVITE from FS"),
            {reply, decline}
    end.


%% @private Called from nkmedia_core
nkmedia_sip_bye(SessId, _Req) ->
    case find(SessId) of
        {ok, Pid} -> gen_server:cast(Pid, sip_bye);
        not_found -> ok
    end,
    {reply, ok}.


%% @private
find(SessId) ->
    case nklib_proc:values({?MODULE, SessId}) of
        [{undefined, Pid}] -> {ok, Pid};
        [] -> not_found
    end.




% ===================================================================
%% gen_server behaviour
%% ===================================================================

-record(state, {
    fs_id :: nkmedia_fs_engine:id(),
    srv_id :: nkservice:id(),
    session_id :: nkmedia_session:id(),
    uuid :: binary(),
    handle :: binary(),
    dialog :: binary(),
    sdp :: nkmedia:sdp(),
    wait_sdp :: {pid(), term()},
    timer :: reference()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()} | {ok, tuple(), timeout()|hibernate} |
    {stop, term()} | ignore.

init([in, SrvId, FsId, SessId, SDP]) ->
    true = nklib_proc:reg({?MODULE, SessId}),
    State1 = #state{fs_id = FsId, srv_id=SrvId, session_id = SessId},
    set_log(State1),
    nkservice_util:register_for_changes(SrvId),
    ?DEBUG("process start (inbound)", [], State1),
    case nkmedia_fs_engine:get_config(FsId) of
        {ok, #{host:=Host, base:=Base}} ->
            Uri = #uri{
                scheme = sip,
                domain = Host,
                port = Base+2,
                user = <<"nkmedia_sip_in_", SessId/binary>>
            },
            SDP2 = nksip_sdp:parse(SDP),
            Opts = [{body, SDP2}, auto_2xx_ack, {meta, [body, {header, <<"x-uuid">>}]}],
            case nksip_uac:invite(nkmedia_core, Uri, Opts) of
                {ok, 200, [{dialog, Dialog}, {body, SDP_B}, {{header, _}, UUID}]} ->
                    State2 = State1#state{
                        uuid = UUID,
                        dialog = Dialog,
                        sdp = nksip_sdp:unparse(SDP_B)
                    },
                    erlang:send_after(5000, self(), in_timeout),
                    {ok, State2};
                Other ->
                    lager:error("invalid response from FS INVITE: ~p", [Other]),
                    {stop, fs_invite_error}
            end;
        {error, Error} ->
            {stop, Error}
    end;

init([out, SrvId, FsId, SessId]) ->
    true = nklib_proc:reg({?MODULE, SessId}),
    Host = nklib_util:to_host(nkmedia_app:get(erlang_ip)),
    Port = nkmedia_app:get(sip_port),
    Proxy = <<Host/binary, ":", (nklib_util:to_binary(Port))/binary, ";transport=tcp">>,
    Vars = [{<<"nkstatus">>, <<"outbound">>}, {<<"nkmedia_session_id">>, SessId}], 
    CallOpts = #{vars=>Vars, call_id=>SessId},
    Dest = <<"sofia/internal/nkmedia_fs_sip-", SessId/binary, "@", Proxy/binary>>,
    Self = self(),
    spawn_link(
        fun() ->
            Reply = nkmedia_fs_cmd:call(FsId, Dest, <<"&park">>, CallOpts),
            gen_server:cast(Self, {originate, Reply})
        end),
    State = #state{fs_id=FsId, session_id=SessId, uuid=SessId},
    set_log(State),
    nkservice_util:register_for_changes(SrvId),
    ?DEBUG("process start (outbound)", [], State),
    erlang:send_after(?TIMEOUT, self(), out_timeout),
    {ok, State}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(get_uuid, _From, #state{uuid=UUID}=State) ->
    {reply, {ok, UUID}, State};

handle_call(get_sdp, From, #state{sdp=undefined}=State) ->
    {noreply, State#state{wait_sdp=From}};

handle_call(get_sdp, _From, #state{sdp=SDP}=State) ->
    {reply, {ok, SDP}, State};

handle_call({sip_invite, Handle, Dialog, SDP}, _From, #state{wait_sdp=Wait}=State) ->
    nklib_util:reply(Wait, {ok, SDP}),
    ?DEBUG("received SDP from FS", [], State),
    State2 = State#state{
        handle = Handle,
        dialog = Dialog,
        sdp = SDP,
        wait_sdp = undefined
    },
    {reply, {reply, ringing}, State2};

handle_call({answer, Answer}, _From, #state{handle=Handle}=State) ->
    #{sdp:=SDP} = Answer,
    Reply = nksip_request:reply({ok, [{body, SDP}]}, Handle),
    {stop, normal, Reply, State};

handle_call(Msg, _From, State) ->
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({originate, {ok, UUID}}, #state{uuid=UUID}=State) ->
    ?DEBUG("originate OK", [], State),
    {noreply, ok, State};

handle_cast({originate, {error, Error}}, State) ->
    ?DEBUG("originate error: ~p", [Error], State),
    {stop, normal, State};

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info(in_timeout, State) -> 
    ?LLOG(notice, "inbound timeout", [], State),
    {stop, normal, State};

handle_info(out_timeout, State) -> 
    ?LLOG(notice, "outbound timeout", [], State),
    {stop, normal, State};

handle_info(nkservice_updated, State) ->
    {noreply, set_log(State)};

handle_info(Info, State) -> 
    lager:warning("Module ~p received unexpected info: ~p (~p)", [?MODULE, Info, State]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(Reason, State) ->
    ?DEBUG("process stop: ~p", [Reason], State).
    


% ===================================================================
%% Internal
%% ===================================================================

%% @private
set_log(#state{srv_id=SrvId}=State) ->
    Debug = case nkservice_util:get_debug_info(SrvId, ?MODULE) of
        {true, _} -> true;
        _ -> false
    end,
    put(nkmedia_fs_sip_debug, Debug),
    State.


