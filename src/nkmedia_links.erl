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

%% @doc Session link utilities

-module(nkmedia_links).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([new/0, add/4, get/2, update/3, remove/2, extract_mon/2, iter/2, fold/3]).
-export([add/5, get/3, update/4, remove/3, extract_mon/3, iter/3, fold/4]).
-export_type([links/0, links/1, id/0, data/0]).


%% ===================================================================
%% Types
%% ===================================================================

-type id() :: term().
-type data() :: term().
-type links() :: [{id(), data(), pid(), reference()}].
-type links(Type) :: [{Type, data(), pid(), reference()}].



%% ===================================================================
%% Public
%% ===================================================================


%% @doc Add a link
-spec new() ->
    links().

new() ->
    [].



%% @doc Add a link
-spec add(id(), data(), pid(), links()) ->
    links().

add(Id, Data, Pid, Links) ->
    case lists:keymember(Id, 1, Links) of
        true -> 
            add(Id, Data, Pid, remove(Id, Links));
        false ->
            Mon = case is_pid(Pid) of
                true -> monitor(process, Pid);
                false -> undefined
            end,
            [{Id, Data, Pid, Mon}|Links]
    end.


%% @doc Gets a link
-spec get(id(), links()) ->
    {ok, data()} | not_found.

get(Id, Links) ->
    case lists:keyfind(Id, 1, Links) of
        {Id, Data, _Pid, _Mon} -> {ok, Data};
        false -> not_found
    end.


%% @doc Add a link
-spec update(id(), data(), links()) ->
    {ok, links()} | not_found.

update(Id, Data, Links) ->
    case lists:keytake(Id, 1, Links) of
        {value, {Id, _OldData, Pid, Mon}, Links2} -> 
            {ok, [{Id, Data, Pid, Mon}|Links2]};
        false ->
            not_found
    end.


%% @doc Removes a link
-spec remove(id(), links()) ->
    links().

remove(Id, Links) ->
    case lists:keyfind(Id, 1, Links) of
        {Id, _Data, _Pid, Mon} ->
            nklib_util:demonitor(Mon),
            lists:keydelete(Id, 1, Links);
        false ->
            Links
    end.


%% @doc Extracts a link with this monitor
-spec extract_mon(reference(), links()) ->
    {ok, id(), data(), links()} | not_found.

extract_mon(Mon, Links) ->
    case lists:keytake(Mon, 4, Links) of
        {value, {Id, Data, _Pid, Mon}, Links2} ->
            nklib_util:demonitor(Mon),
            {ok, Id, Data, Links2};
        false ->
            not_found
    end.


%% @doc Iterates over links
-spec iter(fun((id(), data()) -> ok), links()) ->
    ok.

iter(Fun, Links) ->
    lists:foreach(
        fun({Id, Data, _Pid, _Mon}) -> Fun(Id, Data) end, Links).


%% @doc Folds over links
-spec fold(fun((id(), data(), term()) -> term()), term(), links()) ->
    ok.

fold(Fun, Acc0, Links) ->
    lists:foldl(
        fun({Id, Data, _Pid, _Mon}, Acc) -> Fun(Id, Data, Acc) end, 
        Acc0,
        Links).



%% ===================================================================
%% In-tuple functions
%% ===================================================================



%% @doc Add a link
-spec add(id(), data(), pid(), integer(), tuple()) ->
    links().

add(Id, Data, Pid, Pos, Tuple) when is_integer(Pos), is_tuple(Tuple) ->
    Links = add(Id, Data, Pid, element(Pos, Tuple)),
    setelement(Pos, Tuple, Links).


%% @doc Gets a link
-spec get(id(), integer(), tuple()) ->
    {ok, data()} | not_found.

get(Id, Pos, Tuple) when is_integer(Pos), is_tuple(Tuple) ->
    get(Id, element(Pos, Tuple)).


%% @doc Add a link
-spec update(id(), data(), integer(), tuple()) ->
    {ok, tuple()} | not_found.

update(Id, Data, Pos, Tuple) when is_integer(Pos), is_tuple(Tuple) ->
    case update(Id, Data, element(Pos, Tuple)) of
        {ok, Links} -> {ok, setelement(Pos, Tuple, Links)};
        not_found -> not_found
    end.


%% @doc Removes a link
-spec remove(id(), integer(), tuple()) ->
    tuple().

remove(Id, Pos, Tuple) when is_integer(Pos), is_tuple(Tuple) ->
    Links = remove(Id, element(Pos, Tuple)),
    setelement(Pos, Tuple, Links).


%% @doc Extracts a link with this monitor
-spec extract_mon(reference(), integer(), tuple()) ->
    {ok, id(), data(), tuple()} | not_found.

extract_mon(Mon, Pos, Tuple) when is_integer(Pos), is_tuple(Tuple) ->
    case extract_mon(Mon, element(Pos, Tuple)) of
        {ok, Id, Data, Links} -> 
            {ok, Id, Data, setelement(Pos, Tuple, Links)};
        not_found -> 
            not_found
    end.


%% @doc Iterates over links
-spec iter(fun((id(), data()) -> ok), integer(), tuple()) ->
    ok.

iter(Fun, Pos, Tuple) when is_integer(Pos), is_tuple(Tuple) ->
    iter(Fun, element(Pos, Tuple)).


%% @doc Folds over links
-spec fold(fun((id(), data(), term()) -> term()), term(), integer(), tuple()) ->
    ok.

fold(Fun, Acc, Pos, Tuple) when is_integer(Pos), is_tuple(Tuple) ->
    fold(Fun, Acc, element(Pos, Tuple)).

