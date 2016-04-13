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
-module(nkmedia_verto_util).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([parse_class/1, make_req/3, make_resp/2, make_error/3, make_error/4]).
-export([print/2]).


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Get message class
-spec parse_class(map()) ->
    event | 
    {{req, binary()}, integer()} | 
    {{resp, {ok, binary()}}, integer()} |
    {{resp, {error, integer(), binary()}}, integer()} |
    unknown.

parse_class(#{<<"method">>:=<<"verto.event">>, <<"jsonrpc">>:=<<"2.0">>}) ->
    event;

parse_class(#{<<"method">>:=Method, <<"id">>:=Id, <<"jsonrpc">>:=<<"2.0">>}) ->
    {{req, Method}, nklib_util:to_integer(Id)};

parse_class(#{<<"error">>:=Error, <<"id">>:=Id, <<"jsonrpc">>:=<<"2.0">>}) ->
    Code = maps:get(<<"code">>, Error, 0),
    Msg = maps:get(<<"message">>, Error, <<>>),
    {{resp, {error, Code, Msg}}, nklib_util:to_integer(Id)};

parse_class(#{<<"result">>:=Result, <<"id">>:=Id, <<"jsonrpc">>:=<<"2.0">>}) ->
    Msg1 = maps:get(<<"message">>, Result, <<>>),
    Msg2 = case Msg1 of
        <<>> -> maps:get(<<"method">>, Result, <<"none">>);
        _ -> Msg1
    end,
    {{resp, {ok, Msg2}}, nklib_util:to_integer(Id)};

parse_class(Msg) ->
    lager:warning("Unknown verto message: ~p", [Msg]),
    unknown.


%% @doc
make_req(Id, Method, Params) ->
    #{
        <<"id">> => Id,
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => Method,
        <<"params">> => Params
    }.
    

%% @private
make_resp(Method, Msg) when is_binary(Method) ->
    make_resp(#{<<"method">> => Method}, Msg);

make_resp(Result, #{<<"id">>:=Id}) when is_map(Result) ->
    #{
        <<"id">> => Id,
        <<"jsonrpc">> => <<"2.0">>,
        <<"result">> => Result
    }.


%% @private
make_error(Code, Txt, Msg) ->
    make_error(Code, Txt, <<>>, Msg).


%% @private
make_error(Code, Txt, Method, #{<<"id">>:=Id}) ->
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


% %% @private
% send([], _NkPort) ->
%     ok;

% send([Msg1|Rest], NkPort) ->
%     false = is_list(Msg1),
%     case send(Msg1, NkPort) of
%         ok -> send(Rest, NkPort);
%         error -> {error, <<"Network Error">>}
%     end;

% send(Msg, NkPort) ->
%     case nkpacket_connection:send(NkPort, Msg) of
%         ok ->
%             ok;
%         {error, Error} ->
%             {error, Error}
%     end.


%% @private
print(App, Msg) when is_list(Msg); is_binary(Msg) ->
    lager:info("~s ~s", [App, Msg]);
    
print(App, Msg) ->
    case parse_class(Msg) of
        {{req, Method}, _} ->
            lager:info("~s req ~s", [App, Method]),
            if 
                % Method == <<"login">>; Method == <<"verto.invite">>;
                % Method == <<"verto.answer">>; Method == <<"verto.bye">>;
                % Method == <<"verto.info">>; Method== <<"verto.display">> ->
                %     ok;
                true ->
                    lager:info("~s", [nklib_json:encode_pretty(Msg)])
            end;
        {{resp, {ok, Res}}, _} ->
            lager:info("~s resp ok ~s", [App, Res]),
            if 
                % Res == <<"logged in">>; Res == <<"CALL CREATED">>; 
                % Res == <<"verto.answer">>; Res == <<"verto.bye">>;
                % Res == <<"CALL ENDED">>; Res == <<"SENT">>;
                % Res == <<"verto.invite">> ->
                %     ok;
                true ->
                    lager:info("~s", [nklib_json:encode_pretty(Msg)])
            end;
        {{resp, {error, Code, Err}}, _} ->
            lager:info("~s error ~p (~s)", [App, Code, Err]),
            if 
                Code == -32000; Code == -32001 ->
                    ok;
                true ->
                    lager:info("~s", [nklib_json:encode_pretty(Msg)])
            end;
        event ->
            % lager:info("~s event ~p", [App, Msg]);
            ok;
        unknown ->
            ok
    end.




