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
-module(nkmedia_conf_msglog).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([send_msg/2, get_msgs/2]).
-export([plugin_deps/0, plugin_start/2, plugin_stop/2]).
-export([error_code/1]).
-export([nkmedia_conf_init/2, nkmedia_conf_handle_call/3]).
-export([api_cmd/2, api_syntax/4]).

-include("../../include/nkmedia_conf.hrl").
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
        user_id => binary(),
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


%% @doc Sends a message to the conf
-spec send_msg(nkmedia_conf:id(), map()) ->
    {ok, msg()} | {error, term()}.

send_msg(ConfId, Msg) when is_map(Msg) ->
    Msg2 = Msg#{timestamp=>nklib_util:l_timestamp()},
    case nkmedia_conf:do_call(ConfId, {?MODULE, send, Msg2}) of
        {ok, MsgId} ->
            {ok, Msg2#{msg_id=>MsgId}};
        {error, Error} ->
            {error, Error}
    end.


%% @doc Get all msgs
-spec get_msgs(nkmedia_conf:id(), filters()) ->
    {ok, [msg()]} | {error, term()}.

get_msgs(ConfId, Filters) ->
    nkmedia_conf:do_call(ConfId, {?MODULE, get, Filters}).



%% ===================================================================
%% Plugin callbacks
%% ===================================================================


%% @private
plugin_deps() ->
    [nkmedia_conf].


%% @private
plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA CONF MsgLog (~s) starting", [Name]),
    {ok, Config}.


%% @private
plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA CONF MsgLog (~p) stopping", [Name]),
    {ok, Config}.


%% @private
error_code(_) -> continue.



%% ===================================================================
%% Conf callbacks
%% ===================================================================

%% @private
nkmedia_conf_init(_ConfId, Conf) ->
    State = #state{msgs=orddict:new()},
    {ok, Conf#{?MODULE=>State}}.


%% @private
nkmedia_conf_handle_call({?MODULE, send, Msg}, _From, #{?MODULE:=State}=Conf) ->
    nkmedia_conf:restart_timer(Conf),
    #state{pos=Pos, msgs=Msgs} = State,
    Msg2 = Msg#{msg_id => Pos},
    State2 = State#state{
        pos = Pos+1, 
        msgs = orddict:store(Pos, Msg2, Msgs)
    },
    {reply, {ok, Pos}, update(State2, Conf)};

nkmedia_conf_handle_call({?MODULE, get, _Filters}, _From, 
                         #{?MODULE:=State}=Conf) ->
    nkmedia_conf:restart_timer(Conf),
    #state{msgs=Msgs} = State,
    Reply = [Msg || {_Id, Msg} <- orddict:to_list(Msgs)],
    {reply, {ok, Reply}, Conf};

nkmedia_conf_handle_call(_Msg, _From, _Conf) ->
    continue.


%% ===================================================================
%% API Callbacks
%% ===================================================================

%% @private
api_cmd(#api_req{class = <<"media">>, subclass = <<"conf">>, cmd=Cmd}=Req, State)
        when Cmd == <<"msglog_send">>; Cmd == <<"msglog_get">> ->
    #api_req{cmd=Cmd} = Req,
    do_api_cmd(Cmd, Req, State);

api_cmd(_Req, _State) ->
    continue.


%% @private
api_syntax(#api_req{class = <<"media">>, subclass = <<"conf">>, cmd=Cmd}=Req, 
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
update(State, Conf) ->
    ?CONF(#{?MODULE=>State}, Conf).


do_api_cmd(<<"msglog_send">>, ApiReq, State) ->
    #api_req{srv_id=SrvId, data=Data, user=User, session=SessId} = ApiReq,
    #{conf_id:=ConfId, msg:=Msg} = Data,
    ConfMsg = Msg#{user_id=>User, session_id=>SessId},
    case send_msg(ConfId, ConfMsg) of
        {ok, #{msg_id:=MsgId}=SentMsg} ->
            nkmedia_api_events:send_event(SrvId, conf, ConfId, msglog_new_msg, SentMsg),
            {ok, #{msg_id=>MsgId}, State};
        {error, Error} ->
            {error, Error, State}
    end;

do_api_cmd(<<"msglog_get">>, #api_req{data=Data}, State) ->
    #{conf_id:=ConfId} = Data,
    case get_msgs(ConfId, #{}) of
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
            conf_id => binary,
            msg => map
        },
        Defaults,
        [conf_id, msg|Mandatory]
    };

do_api_syntax(<<"msglog_get">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            conf_id => binary
        },
        Defaults,
        [conf_id|Mandatory]
    };

do_api_syntax(_Cmd, Syntax, Defaults, Mandatory) ->
    {Syntax, Defaults, Mandatory}.






