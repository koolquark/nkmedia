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
-module(nkmedia_fs_util).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([verto_class/1, verto_req/3, verto_resp/2, verto_error/3, verto_error/4]).


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Get message class
-spec verto_class(map()) ->
    event | 
    {{req, binary()}, integer()} | 
    {{resp, {ok, binary()}}, integer()} |
    {{resp, {error, integer(), binary()}}, integer()} |
    unknown.

verto_class(#{<<"method">>:=<<"verto.event">>, <<"jsonrpc">>:=<<"2.0">>}) ->
    event;

verto_class(#{<<"method">>:=Method, <<"id">>:=Id, <<"jsonrpc">>:=<<"2.0">>}) ->
    {{req, Method}, nklib_util:to_integer(Id)};

verto_class(#{<<"error">>:=Error, <<"id">>:=Id, <<"jsonrpc">>:=<<"2.0">>}) ->
    Code = maps:get(<<"code">>, Error, 0),
    Msg = maps:get(<<"message">>, Error, <<>>),
    {{resp, {error, Code, Msg}}, nklib_util:to_integer(Id)};

verto_class(#{<<"result">>:=Result, <<"id">>:=Id, <<"jsonrpc">>:=<<"2.0">>}) ->
    Msg1 = maps:get(<<"message">>, Result, <<>>),
    Msg2 = case Msg1 of
        <<>> -> maps:get(<<"method">>, Result, <<"none">>);
        _ -> Msg1
    end,
    {{resp, {ok, Msg2}}, nklib_util:to_integer(Id)};

verto_class(Msg) ->
    lager:warning("Unknown verto message: ~p", [Msg]),
    unknown.


%% @doc
verto_req(Id, Method, Params) ->
    #{
        <<"id">> => Id,
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => Method,
        <<"params">> => Params
    }.
    

%% @private
verto_resp(Method, Msg) when is_binary(Method) ->
    verto_resp(#{<<"method">> => Method}, Msg);

verto_resp(Result, #{<<"id">>:=Id}) when is_map(Result) ->
    #{
        <<"id">> => Id,
        <<"jsonrpc">> => <<"2.0">>,
        <<"result">> => Result
    }.


%% @private
verto_error(Code, Txt, Msg) ->
    verto_error(Code, Txt, <<>>, Msg).


%% @private
verto_error(Code, Txt, Method, #{<<"id">>:=Id}) ->
    Error1 = #{
        <<"code">> => Code, 
        <<"message">> => nklib_util:to_binary(Txt)
    },
    Error2 = case Method of
        <<>> -> Error1;
        _ -> Error1#{<<"method">> => nklib_util:to_binary(Method)}
    end,
    #{
        <<"id">> => Id,
        <<"jsonrpc">> => <<"2.0">>,
        <<"error">> => Error2
    }.





