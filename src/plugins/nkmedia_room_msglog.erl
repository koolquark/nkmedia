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

%% @doc Plugin implementing a Verto server
-module(nkmedia_room_msglog).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([send_msg/2, get_msgs/2]).
-export([plugin_deps/0, plugin_start/2, plugin_stop/2]).
-export([error_code/1]).
-export([nkmedia_room_init/2, nkmedia_room_handle_call/3]).
-export([api_cmd/2, api_syntax/4]).

-include_lib("nkservice/include/nkservice.hrl").


%% ===================================================================
%% Types
%% ===================================================================

-type filters() ::
    #{}.


-type msg_id() ::
    integer().


-type msg() ::
    #{
        msg_id => msg_id(),
        user => binary(),
        session_id => binary(),
        timestamp => nklib_util:l_timestamp()
    }.


-record(state, {
    pos = 1 :: integer(),
    msgs :: orddict:orddict()
}).




%% ===================================================================
%% Public
%% ===================================================================


%% @doc Sends a message to the room
-spec send_msg(nkmedia_room:id(), map()) ->
    {ok, msg()} | {error, term()}.

send_msg(RoomId, Msg) when is_map(Msg) ->
    Msg2 = Msg#{timestamp=>nklib_util:l_timestamp()},
    case nkmedia_room:do_call(RoomId, {?MODULE, send, Msg2}) of
        {ok, MsgId} ->
            {ok, Msg2#{msg_id=>MsgId}};
        {error, Error} ->
            {error, Error}
    end.


%% @doc Sends a message to the room
-spec get_msgs(nkmedia_room:id(), filters()) ->
    {ok, [msg()]} | {error, term()}.

get_msgs(RoomId, Filters) ->
    nkmedia_room:do_call(RoomId, {?MODULE, get, Filters}).



%% ===================================================================
%% Plugin callbacks
%% ===================================================================


%% @private
plugin_deps() ->
    [nkmedia].


%% @private
plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA RoomMsgLog (~s) starting", [Name]),
    {ok, Config}.


%% @private
plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA RoomMsgLog (~p) stopping", [Name]),
    {ok, Config}.


%% @private
error_code(_) -> continue.



%% ===================================================================
%% Room callbacks
%% ===================================================================

%% @private
nkmedia_room_init(_RoomId, Room) ->
    State = #state{msgs=orddict:new()},
    {ok, Room#{?MODULE=>State}}.


%% @private
nkmedia_room_handle_call({?MODULE, send, Msg}, _From, #{?MODULE:=State}=Room) ->
    nkmedia_room:restart_timer(Room),
    #state{pos=Pos, msgs=Msgs} = State,
    Msg2 = Msg#{msg_id => Pos},
    State2 = State#state{
        pos = Pos+1, 
        msgs = orddict:store(Pos, Msg2, Msgs)
    },
    {reply, {ok, Pos}, update(State2, Room)};

nkmedia_room_handle_call({?MODULE, get, _Filters}, _From, 
                         #{?MODULE:=State}=Room) ->
    nkmedia_room:restart_timer(Room),
    #state{msgs=Msgs} = State,
    Reply = [Msg || {_Id, Msg} <- orddict:to_list(Msgs)],
    {reply, {ok, Reply}, Room};

nkmedia_room_handle_call(_Msg, _From, _Room) ->
    lager:error("MSF1"),
    continue.


%% ===================================================================
%% API Callbacks
%% ===================================================================

%% @private
api_cmd(#api_req{class = <<"media">>, subclass = <<"room">>, cmd=Cmd}=Req, State)
        when Cmd == <<"msglog_send">>; Cmd == <<"msglog_get">> ->
    #api_req{cmd=Cmd} = Req,
    do_api_cmd(Cmd, Req, State);

api_cmd(_Req, _State) ->
    continue.


%% @private
api_syntax(#api_req{class = <<"media">>, subclass = <<"room">>, cmd=Cmd}=Req, 
           Syntax, Defaults, Mandatory) 
           when Cmd == <<"msglog_send">>; Cmd == <<"msglog_get">> ->
    #api_req{cmd=Cmd} = Req,
    {S2, D2, M2} = do_api_syntax(Cmd, Syntax, Defaults, Mandatory),
    {continue, [Req, S2, D2, M2]};

api_syntax(_Req, _Syntax, _Defaults, _Mandatory) ->
    continue.


%% ===================================================================
%% Internal
%% ===================================================================

%% @private
update(State, Room) ->
    Room#{?MODULE:=State}.


do_api_cmd(<<"msglog_send">>, ApiReq, State) ->
    #api_req{srv_id=SrvId, data=Data, user=User, session=SessId} = ApiReq,
    #{room_id:=RoomId, msg:=Msg} = Data,
    RoomMsg = Msg#{user=>User, session_id=>SessId},
    case send_msg(RoomId, RoomMsg) of
        {ok, #{msg_id:=MsgId}=SentMsg} ->
            nkmedia_api_events:send_event(SrvId, room, RoomId, msglog_send, SentMsg),
            {ok, #{msg_id=>MsgId}, State};
        {error, Error} ->
            {error, Error, State}
    end;

do_api_cmd(<<"msglog_get">>, #api_req{data=Data}, State) ->
    #{room_id:=RoomId} = Data,
    case get_msgs(RoomId, #{}) of
        {ok, List} ->
            {ok, List, State};
        {error, Error} ->
            {error, Error, State}
    end;

do_api_cmd(_Cmd, _ApiReq, State) ->
    {error, not_implemented, State}.


%% @private
do_api_syntax(<<"msglog_send">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            room_id => binary,
            msg => map
        },
        Defaults,
        [room_id, msg|Mandatory]
    };

do_api_syntax(<<"msglog_get">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            room_id => binary
        },
        Defaults,
        [room_id|Mandatory]
    };

do_api_syntax(_Cmd, Syntax, Defaults, Mandatory) ->
    {Syntax, Defaults, Mandatory}.






