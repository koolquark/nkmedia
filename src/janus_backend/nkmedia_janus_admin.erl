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
-module(nkmedia_janus_admin).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([list_sessions/1, list_handles/2, handle_info/3, set_log_level/2]).
-export([print_handle_info/3]).


%% ===================================================================
%% Types
%% ===================================================================



%% ===================================================================
%% Public
%% ===================================================================


%% @doc Gets active sessions
-spec list_sessions(nkmedia_janus:id()|nkmedia_janus:config()) ->
    {ok, [integer()]} | error. 

list_sessions(Id) ->
    case admin_req(Id, list_sessions, <<>>, #{}) of
        {ok, #{<<"sessions">>:=Sessions}} ->
            {ok, Sessions};
        {error, Error} ->
            {error, Error}
    end.


%% @doc Gets handles for a session
-spec list_handles(nkmedia_janus:id()|nkmedia_janus:config(), integer()) ->
    {ok, [integer()]} | error. 

list_handles(Id, Session) ->
    Url = <<"/", (nklib_util:to_binary(Session))/binary>>,
    case admin_req(Id, list_handles, Url, #{}) of
        {ok, #{<<"handles">>:=Handles}} ->
            {ok, Handles};
        {error, Error} ->
            {error, Error}
    end.


%% @doc Gets info on a handle for a session
-spec handle_info(nkmedia_janus:id()|nkmedia_janus:config(), integer(), integer()) ->
    {ok, map()} | error. 

handle_info(Id, Session, Handle) ->
    Url = <<"/", (nklib_util:to_binary(Session))/binary,
            "/", (nklib_util:to_binary(Handle))/binary>>,
    case admin_req(Id, handle_info, Url, #{}) of
        {ok, #{<<"info">>:=Info}} ->
            {ok, Info};
        {error, Error} ->
            {error, Error}
    end.


%% @doc Gets info on a handle for a session
-spec print_handle_info(nkmedia_janus:id()|nkmedia_janus:config(), 
                        integer(), integer()) ->
    ok.

print_handle_info(Id, Session, Handle) ->
    {ok, Info} = handle_info(Id, Session, Handle),
    io:format("~s", [nklib_json:encode_pretty(Info)]).



%% @doc Gets info on a handle for a session
-spec set_log_level(nkmedia_janus:id()|nkmedia_janus:config(), integer()) ->
    {ok, [integer()]} | error. 

set_log_level(Id, Level) when Level>=0, Level=<7 ->
    case admin_req(Id, set_log_level, <<>>, #{level=>Level}) of
        {ok, #{<<"level">>:=Level}} ->
            ok;
        {error, Error} ->
            {error, Error}
    end.



%% ===================================================================
%% Private
%% ===================================================================

%% @private Launches an admin command
-spec admin_req(nkmedia_janus:config()|nkmedia_janus:id(), 
                atom()|binary(), binary(), map()) ->
    {ok, atom()|binary(), map()} | {error, term()}.

admin_req(#{base:=Base, host:=Host, pass:=Pass}, Cmd, Url, Data) ->
    Msg = Data#{
        janus => Cmd, 
        transaction => nklib_util:uid(),
        admin_secret => Pass
    },
    Url1 = <<"http://", Host/binary, 
             ":", (nklib_util:to_binary(Base+1))/binary, 
             "/admin", Url/binary>>,
    Url2 = binary_to_list(Url1),
    Body = nklib_json:encode(Msg),
    Opts = [{full_result, false}, {body_format, binary}],
    case httpc:request(post, {Url2, [], "", Body}, [], Opts) of
        {ok, {200, Body2}} ->
            case catch nklib_json:decode(Body2) of
                #{<<"janus">> := <<"success">>} = Msg2 ->
                    {ok, Msg2};
                #{
                    <<"janus">> := <<"error">>,
                    <<"error">> := #{<<"reason">>:=ErrReason}
                } ->
                    {error, ErrReason};
                _ ->
                    {error, json_error}
            end;
        _ ->
            {error, no_response}
    end;

admin_req(Id, Cmd, Url, Data) ->
    case nkmedia_janus_engine:get_config(Id) of
        {ok, Config} -> 
            admin_req(Config, Cmd, Url, Data);
        {error, Error} -> 
            {error, Error}
    end.



