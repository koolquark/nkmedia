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

-export([start_out/3, answer_out/2]).
-export([sip_invite/3, sip_reinvite/3, sip_bye/3]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).

-define(TIMEOUT, 60000).


%% ===================================================================
%% Types
%% ===================================================================


%% ===================================================================
%% Public
%% ===================================================================


%% @doc
%% nkmedia_sip will find any process registered under {nkmedia_sip, call, CallId}
%% and {nkmedia_sip_dialog, Dialog} and will send messages
-spec start_out(nkmedia_fs:id(), binary(), map()) ->
    {ok, pid()} | {error, term()}.

start_out(FsId, CallId, Opts) ->
    {ok, Pid} = gen_server:start(?MODULE, [FsId, CallId, Opts], []),
    nklib_util:call(Pid, get_sdp).


%% @doc
answer_out(CallId, SDP) ->
    case nklib_proc:values({?MODULE, CallId}) of
        [{undefined, Pid}|_] ->
            nklib_util:call(Pid, {answer, SDP});
        [] ->
            {error, unknown_call_id}
    end.



%% @private
sip_invite(Pid, Req, _Call) ->
    {ok, Handle} = nksip_request:get_handle(Req),
    {ok, Dialog} = nksip_dialog:get_handle(Req),
    {ok, SDP} = nksip_request:get_body(Req),
    case nksip_sdp:is_sdp(SDP) of
        true ->
            nklib_util:call(Pid, {sip_invite, Handle, Dialog, SDP});
        false ->
            {reply, decline}
    end.


%% @private
sip_reinvite(_Pid, _Req, _Call) ->
    {reply, decline}.


%% @private
sip_bye(Pid, _Req, _Call) ->
    gen_server:cast(Pid, sip_bye),
    {reply, ok}.



% ===================================================================
%% gen_server behaviour
%% ===================================================================

-record(state, {
    fs_id :: nkmedia_fs_engine:id(),
    call_id :: binary(),
    originate :: pid(),
    handle :: binary(),
    dialog :: binary(),
    sdp :: binary(),
    wait_sdp :: {pid(), term()}
}).


%% @private
-spec init(term()) ->
    {ok, tuple()} | {ok, tuple(), timeout()|hibernate} |
    {stop, term()} | ignore.

init([FsId, CallId, _Opts]) ->
    nkmedia_sip:register_call_id(?MODULE, CallId),
    nklib_proc:put({?MODULE, CallId}),
    Host = nklib_util:to_host(nkmedia_app:get(erlang_ip)),
    Port = nkmedia_app:get(sip_port),
    Sip = <<Host/binary, ":", (nklib_util:to_binary(Port))/binary, ";transport=tcp">>,
    Vars = [{<<"nkstatus">>, <<"outbound">>}], 
    CallOpts = #{vars=>Vars, call_id=>CallId},
    Dest = <<"sofia/internal/nkmedia-", CallId/binary, "@", Sip/binary>>,
    Self = self(),
    Caller = spawn_link(
        fun() ->
            Reply = nkmedia_fs_cmd:call(FsId, Dest, <<"nkmedia_out">>, CallOpts),
            gen_server:cast(Self, {originate, Reply})
        end),
    {ok, #state{fs_id=FsId, call_id=CallId, originate=Caller}, ?TIMEOUT}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(get_sdp, From, #state{sdp=undefined}=State) ->
    {noreply, State#state{wait_sdp=From}, ?TIMEOUT};

handle_call(get_sdp, _From, #state{sdp=SDP}=State) ->
    {reply, {ok, SDP}, State, ?TIMEOUT};


handle_call({sip_invite, Handle, Dialog, SDP}, _From, #state{wait_sdp=Wait}=State) ->
    nklib_util:reply(Wait, {ok, SDP}),
    State2 = State#state{
        handle = Handle,
        dialog = Dialog,
        sdp = SDP,
        wait_sdp = undefined
    },
    {reply, {reply, ringing}, State2, ?TIMEOUT};

handle_call({answer, SDP}, _From, #state{handle=Handle}=State) ->
    Reply = nksip_request:reply({ok, [{body, SDP}]}, Handle),
    {stop, Reply, normal, State};

handle_call(Msg, _From, State) ->
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State, ?TIMEOUT}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({originate, {ok, CallId}}, #state{call_id=CallId}=State) ->
    {noreply, ok, State, ?TIMEOUT};

handle_cast({originate, {error, Error}}, State) ->
    lager:notice("NkMEDIA FS SIP originate error: ~p", [Error]),
    {stop, normal, State};

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State, ?TIMEOUT}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info(timeout, State) ->
    lager:warning("NkMEDIA FS SIP timeout!"),
    {stop, normal, State};

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

terminate(_Reason, _State) ->
    ok.
    


% ===================================================================
%% Internal
%% ===================================================================



