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

%% @doc 
-module(nkmedia_janus_proto).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([invite/3, answer/3, hangup/2, hangup/3]).
-export([find_user/1, find_call_id/1, get_all/0]).
-export([transports/1, default_port/1]).
-export([conn_init/1, conn_encode/2, conn_parse/3, conn_stop/3,
         conn_handle_call/4, conn_handle_cast/3, conn_handle_info/3]).

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Janus Plugin (~s) "++Txt, [State#state.user | Args])).

-define(PRINT(Txt, Args, State), 
        print(Txt, Args, State),    % Uncomment this for detailed logs
        ok).


-define(OP_TIME, 15000).            % Maximum operation time
-define(CALL_TIMEOUT, 30000).       % 


%% ===================================================================
%% Types
%% ===================================================================

% Recognized: sdp, callee_name, callee_id, caller_name, caller
-type offer() :: nkmedia:offer() | #{async => boolean(), monitor=>pid()}.      

% Included: sdp, sdp_type, verto_params
-type answer() :: nkmedia:answer() | #{monitor=>pid()}.

-type janus() ::
	#{
        remote => binary(),
        srv_id => nkservice:id(),
        sess_id => binary(),
        user => binary()
	}.

-type call_id() :: binary().


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Sends an INVITE. 
%% If async=true, the pid() of the process and a reference() will be returned,
%% and a message {?MODULE, Ref, {ok, answer()}} or {?MODULE, Ref, {error, Error}}
%% will be sent to the calling process
%% A new call will be added (see find_call_id/1)
%% If 'monitor' is used, this process will be monitorized 
%% and the call will be hangup if it fails before a hangup is sent or received
-spec invite(pid(), call_id(), offer()) ->
    {answer, answer()} | rejected | {async, pid(), reference()} |
    {error, term()}.
    
invite(Pid, CallId, Offer) ->
    call(Pid, {invite, CallId, Offer}).


%% @doc Sends an ANSWER (only sdp is used in answer())
-spec answer(pid(), call_id(), answer()) ->
    ok | {error, term()}.

answer(Pid, CallId, Answer) ->
    call(Pid, {answer, CallId, Answer}).


%% @doc Equivalent to hangup(Pid, CallId, 16)
-spec hangup(pid(), binary()) ->
    ok.

hangup(Pid, CallId) ->
    hangup(Pid, CallId, 16).


%% @doc Sends a BYE (non-blocking)
%% The call will be removed and demonitorized
-spec hangup(pid(), binary(), nkmedia:hangup_reason()) ->
    ok | {error, term()}.

hangup(Pid, CallId, Reason) ->
    gen_server:cast(Pid, {hangup, CallId, Reason}).


%% @doc Gets the pids() for currently logged user
-spec find_user(binary()) ->
    [pid()].

find_user(Login) ->
    Login2 = nklib_util:to_binary(Login),
    [Pid || {undefined, Pid} <- nklib_proc:values({?MODULE, user, Login2})].


%% @doc Gets the pids() for currently logged user
-spec find_call_id(binary()) ->
    [pid()].

find_call_id(CallId) ->
    CallId2 = nklib_util:to_binary(CallId),
    [Pid || {undefined, Pid} <- nklib_proc:values({?MODULE, call, CallId2})].


get_all() ->
    [{Local, Remote} || {Remote, Local} <- nklib_proc:values(?MODULE)].




%% ===================================================================
%% Protocol callbacks
%% ===================================================================


-type op_id() :: {trans, integer()}.

-record(trans, {
    req :: term(),
    timer :: reference(),
    from :: {pid(), term()}
}).

-record(state, {
    srv_id ::  nkservice:id(),
    trans = #{} :: #{op_id() => #trans{}},
    session_id :: integer(),
    plugin :: binary(),
    handle :: integer(),
    user :: binary(),
    janus :: janus(),
    pos :: integer()

}).


%% @private
-spec transports(nklib:scheme()) ->
    [nkpacket:transport()].

transports(_) -> [wss, ws].

-spec default_port(nkpacket:transport()) ->
    inet:port_number() | invalid.

default_port(ws) -> 8188;
default_port(wss) -> 8989.


-spec conn_init(nkpacket:nkport()) ->
    {ok, #state{}}.

conn_init(NkPort) ->
    {ok, {nkmedia_janus_proto, SrvId}, _} = nkpacket:get_user(NkPort),
    {ok, Remote} = nkpacket:get_remote_bin(NkPort),
    Janus = #{remote=>Remote, srv_id=>SrvId},
    State1 = #state{
        srv_id = SrvId, 
        janus = Janus,
        pos = erlang:phash2(make_ref())
    },
    nklib_proc:put(?MODULE, <<>>),
    lager:info("NkMEDIA Janus new connection (~s, ~p)", [Remote, self()]),
    {ok, State2} = handle(nkmedia_janus_init, [NkPort], State1),
    {ok, State2}.


%% @private
-spec conn_parse(term()|close, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_parse(close, _NkPort, State) ->
    {ok, State};

conn_parse({text, Data}, NkPort, State) ->
    Msg = case nklib_json:decode(Data) of
        error ->
            ?LLOG(warning, "JSON decode error: ~p", [Data], State),
            error(json_decode);
        Json ->
            Json
    end,
    ?PRINT("receiving ~s", [Msg], State),
    case Msg of
        #{<<"janus">>:=BinCmd, <<"transaction">>:=Trans} ->
            OpId = {trans, Trans},
            Cmd = case catch binary_to_existing_atom(BinCmd, latin1) of
                {'EXIT', _} -> BinCmd;
                Cmd2 -> Cmd2
            end,
            case extract_op(OpId, State) of
                {#trans{req=Req, from=From}, State2} ->
                    process_client_resp(Cmd, OpId, Req, From, Msg, NkPort, State2);
                not_found ->
                    process_client_req(Cmd, Msg, NkPort, State)
            end;
        % #{<<"janus">>:=<<"event">>, <<"session_id">>:=Id, <<"sender">>:=Handle} ->
        %     case get_client(Id, State) of
        %         {ok, CallBack, ClientId} ->
        %             event(CallBack, ClientId, Id, Handle, Msg, State),
        %             {ok, State};
        %         not_found ->
        %             ?LLOG(notice, "unexpected server event: ~p", [Msg], State),
        %             {ok, State}
        %     end;
        #{<<"janus">>:=Cmd} ->
            ?LLOG(notice, "unknown msg: ~s: ~p", [Cmd, Msg], State),
            {ok, State}
    end.


%% @private
-spec conn_encode(term(), nkpacket:nkport()) ->
    {ok, nkpacket:outcoming()} | continue | {error, term()}.

conn_encode(Msg, _NkPort) when is_map(Msg) ->
    Json = nklib_json:encode(Msg),
    {ok, {text, Json}};

conn_encode(Msg, _NkPort) when is_binary(Msg) ->
    {ok, {text, Msg}}.


%% @doc Called when the connection received an erlang message
-spec conn_handle_call(term(), term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_call(Msg, From, NkPort, State) ->
    case send_req(Msg, From, NkPort, State) of
        unknown_op ->
            handle(nkmedia_janus_handle_call, [Msg, From], State);
        Other ->
            Other
    end.


-spec conn_handle_cast(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_cast(Msg, NkPort, State) ->
    case send_req(Msg, undefined, NkPort, State) of
        unknown_op ->
            handle(nkmedia_janus_handle_cast, [Msg], State);
        Other ->
            Other
    end.


%% @doc Called when the connection received an erlang message
-spec conn_handle_info(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_info({timeout, _, {op_timeout, OpId}}, _NkPort, State) ->
    case extract_op(OpId, State) of
        {Op, State2} ->
            user_reply(Op, {error, timeout}),
            ?LLOG(warning, "operation ~p timeout!", [OpId], State),
            {stop, normal, State2};
        not_found ->
            {ok, State}
    end;

conn_handle_info(Info, _NkPort, State) ->
    handle(nkmedia_janus_handle_info, [Info], State).


%% @doc Called when the connection stops
-spec conn_stop(Reason::term(), nkpacket:nkport(), #state{}) ->
    ok.

conn_stop(Reason, _NkPort, State) ->
    catch handle(nkmedia_janus_terminate, [Reason], State).


%% ===================================================================
%% Requests
%% ===================================================================

send_req({answer, _CallId, Answer}, From, NkPort, State) ->
    Result = #{
        event => accepted, 
        username => unknown
    },
    Jsep = Answer#{type=>answer, trickle=>false},
    Req = make_videocall_req(Result, Jsep, State),
    nklib_util:reply(From, ok),
    send(Req, NkPort, State);

send_req({hangup, _CallId, Reason}, From, NkPort, State) ->
    Result = #{
        event => hangup, 
        reason => nklib_util:to_binary(Reason), 
        username => unknown
    },
    Req = make_videocall_req(Result, #{}, State),
    nklib_util:reply(From, ok),
    send(Req, NkPort, State);

send_req(_Op, _From, _NkPort, _State) ->
    unknown_op.



%% @private
process_client_req(create, Msg, NkPort, State) ->
	Id = erlang:phash2(make_ref()),
	Resp = make_resp(#{janus=>success, data=>#{id=>Id}}, Msg),
	send(Resp, NkPort, State#state{session_id=Id});

process_client_req(attach, Msg, NkPort, #state{session_id=SessionId}=State) ->
    #{<<"plugin">>:=Plugin, <<"session_id">>:=SessionId} = Msg,
    Handle = erlang:phash2(make_ref()),
    Resp = make_resp(#{janus=>success, data=>#{id=>Handle}}, Msg),
    send(Resp, NkPort, State#state{handle=Handle, plugin=Plugin});

process_client_req(message, Msg, NkPort, State) ->
    #state{session_id=SessionId, handle=Handle} = State,
    #{<<"body">>:=Body, <<"session_id">>:=SessionId, <<"handle_id">>:=Handle} = Msg,
    #{<<"request">> := BinReq} = Body,
    Req = case catch binary_to_existing_atom(BinReq, latin1) of
        {'EXIT', _} -> BinReq;
        Req2 -> Req2
    end,
    Ack = make_resp(#{janus=>ack, session_id=>SessionId}, Msg),
    case send(Ack, NkPort, State) of
        {ok, State2} ->
           process_client_msg(Req, Body, Msg, NkPort, State2);
        Other ->
            Other
    end;

process_client_req(detach, Msg, NkPort, State) ->
    #state{session_id=SessionId, handle=Handle} = State,
    #{<<"session_id">>:=SessionId, <<"handle_id">>:=Handle} = Msg,
    Resp = make_resp(#{janus=>success, session_id=>SessionId}, Msg),
    send(Resp, NkPort, State#state{handle=undefined});

process_client_req(destroy, Msg, NkPort, #state{session_id=SessionId}=State) ->
    #{<<"session_id">>:=SessionId} = Msg,
    Resp = make_resp(#{janus=>success, session_id=>SessionId}, Msg),
    send(Resp, NkPort, State#state{session_id=undefined});

process_client_req(keepalive, Msg, NkPort, #state{session_id=SessionId}=State) ->
    Resp = make_resp(#{janus=>ack, session_id=>SessionId}, Msg),
    send(Resp, NkPort, State);

process_client_req(Cmd, _Msg, _NkPort, State) ->
    ?LLOG(warning, "Client REQ: ~s", [Cmd], State),
    {ok, State}.


%% @private
process_client_msg(register, Body, Msg, NkPort, State) ->
    #{<<"username">>:=User} = Body,
    nklib_proc:put(?MODULE, User),
    nklib_proc:put({?MODULE, user, User}),
    Result = #{event=>registered, username=>User},
    Resp = make_videocall_resp(Result, Msg, State),
    send(Resp, NkPort, State#state{user=User});

process_client_msg(call, Body, Msg, NkPort, State) ->
    #state{session_id=Session, handle=Handle} = State,
    CallId = <<
        (integer_to_binary(Session))/binary, $-, 
        (integer_to_binary(Handle))/binary
    >>,
    #{<<"username">>:=Dest} = Body,
    #{<<"jsep">>:=#{<<"sdp">>:=SDP}} = Msg,
    case handle(nkmedia_janus_invite, [CallId, #{dest=>Dest, sdp=>SDP}], State) of
        {ok, _Pid, State2} ->
            ok;
        {answer, Answer, _Pid, State2} ->
            gen_server:cast(self(), {answer, CallId, Answer});
        {hangup, Reason, State2} ->
            _Pid = undefined,
            hangup(self(), CallId, Reason)
    end,
    % State3 = add_call(CallId, Pid, State2),
    Resp = make_videocall_resp(#{event=>calling}, Msg, State2),
    send(Resp, NkPort, State2);

process_client_msg(list, _Body, Msg, NkPort, State) ->
    Resp = make_videocall_resp(#{list=>[]}, Msg, State),
    send(Resp, NkPort, State);

process_client_msg(Cmd, _Body, _Msg, _NkPort, State) ->
    ?LLOG(warning, "Client MESSAGE: ~s", [Cmd], State),
    {ok, State}.


%% @private
process_client_resp(Cmd, _OpId, _Req, _From, _Msg, _NkPort, State) ->
    ?LLOG(warning, "Server REQ: ~s", [Cmd], State),
    {ok, State}.









%% ===================================================================
%% Util
%% ===================================================================


% %% @private
% make_msg(Body, Msg, From, State) ->
%     #state{session_id=SessionId, handle=Handle, pos=Pos} = State,
%     TransId = nklib_util:to_binary(Pos),
%     State2 = insert_op({trans, TransId}, Msg, From, State),
%     Req = #{
%         janus => message,
%         body => Body,
%         session_id => SessionId,
%         handle_id => Handle,
%         transaction => TransId
%     },
%     {Req, State2#state{pos=Pos+1}}.



%% @private
make_videocall_req(Result, Jsep, State) ->
    #state{session_id=SessionId, handle=Handle} = State,
    Req = #{
        janus => event,
        plugindata => #{
            data => #{
                result => Result,
                videocall => event
            },
            plugin => <<"janus.plugin.videocall">>
        },
        sender => Handle,
        session_id => SessionId
    },
    case maps:size(Jsep) of
        0 -> Req;
        _ -> Req#{jsep=>Jsep}
    end.


%% @private
make_videocall_resp(Result, Msg, State) ->
    Req = make_videocall_req(Result, #{}, State),
    make_resp(Req, Msg).


%% @private
make_resp(Data, Msg) ->
    #{<<"transaction">>:=Trans} = Msg,
    Data#{transaction => Trans}.
    %% @private


%% @private
call(JanusPid, Msg) ->
    nklib_util:call(JanusPid, Msg, 1000*?CALL_TIMEOUT).


% %% @private
% insert_op(OpId, Req, From, #state{trans=AllOps}=State) ->
%     NewOp = #trans{
%         req = Req, 
%         timer = erlang:start_timer(?OP_TIME, self(), {op_timeout, OpId}),
%         from = From
%     },
%     State#state{trans=maps:put(OpId, NewOp, AllOps)}.



extract_op(OpId, #state{trans=AllOps}=State) ->
    case maps:find(OpId, AllOps) of
        {ok, #trans{timer=Timer}=OldOp} ->
            nklib_util:cancel_timer(Timer),
            State2 = State#state{trans=maps:remove(OpId, AllOps)},
            {OldOp, State2};
        error ->
            not_found
    end.


%% @private
send(Msg, NkPort, State) ->
    ?PRINT("sending ~s", [Msg], State),
    case send(Msg, NkPort) of
        ok -> 
            {ok, State};
        error -> 
            ?LLOG(notice, "error sending reply:", [], State),
            {stop, normal, State}
    end.


%% @private
send(Msg, NkPort) ->
    nkpacket_connection:send(NkPort, Msg).


%% @private
handle(Fun, Args, State) ->
    nklib_gen_server:handle_any(Fun, Args, State, #state.srv_id, #state.janus).


%% @private
print(Txt, [#{}=Map], State) ->
    print(Txt, [nklib_json:encode_pretty(Map)], State);
print(Txt, Args, State) ->
    ?LLOG(info, Txt, Args, State).


%% @private
user_reply(#trans{from={async, Pid, Ref}}, Msg) ->
    Pid ! {?MODULE, Ref, Msg};
user_reply(#trans{from=From}, Msg) ->
    nklib_util:reply(From, Msg).





% {
%   "janus": "event",
%   "plugindata": {
%     "data": {
%       "error": "You can't call yourself... use the EchoTest for that",
%       "error_code": 479,
%       "videocall": "event"
%     },
%     "plugin": "janus.plugin.videocall"
%   },
%   "sender": 2256035211,
%   "session_id": 1837249640,
%   "transaction": "YFTMkOeSwwAo"
% }
