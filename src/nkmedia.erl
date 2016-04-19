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

%% @doc NkMEDIA application

-module(nkmedia).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([start_fs/0, start_fs/1, stop_fs/0, stop_fs/1]).
-export([nkdocker_event/2]).

-export([t1/0, t2/0, t3/0]).
t1() ->
	{ok, _} = enm:start_link(),
	Url = "ipc:///var/run/docker.sock",
	{ok, S} = enm:req([{active, false}]),
	{ok, _A} = enm:connect(S, Url),	
	ok = enm:send(S, <<"GET /containers/json HTTP/1.1\r\ncontent-length: 0\r\nconnection: keep-alive\r\n\r\n">>),
	{ok, _} = enm:recv(S, 4000),
	receive
        {nnrep, S, Data} ->
        	lager:error("RECV ~p", [Data]);
        Other ->
        	lager:error("RECV O ~p", [Other])
       	after 2000 ->
       		lager:error("NOTHING")
    end,
    enm:close(S),
    enm:stop().


t2() ->
    {ok, _} = enm:start_link(),
    Url = "ipc:///tmp/a.ipc",
    {ok,Rep} = enm:rep([{bind,Url}, raw]),
    {ok,Req} = enm:req([{connect,Url}, raw]),

    DateReq = <<"DATE">>,
    io:format("sending date request~n"),
    ok = enm:send(Req, DateReq),
    receive
        {nnrep,Rep,DateReq} ->
            io:format("received date request~n"),
            Now = httpd_util:rfc1123_date(),
            io:format("sending date ~s~n", [Now]),
            ok = enm:send(Rep, Now);
        Other ->
        	lager:error("RECV O ~p", [Other])
       	after 2000 ->
       		error("NOTHING")
    end,
    receive
        {nnreq,Req,Date} ->
            io:format("received date ~s~n", [Date])
    end,
    enm:close(Req),
    enm:close(Rep),
    enm:stop().


t3() ->
    {ok, _} = enm:start_link(),
    Url = "ipc:///tmp/a.ipc",
    {ok, S} = enm:pair([{active, false}]),
    {ok, _N1} = enm:bind(S, Url),
    {ok, _N2} = enm:connect(S, Url),

    DateReq = <<"DATEDATEDATEDATEDATEDATEDATEDATEDATE">>,
    io:format("sending date request~n"),
    ok = enm:send(S, DateReq),
    ok = enm:recv(S, 4000),
    receive
        % {nnrep,Rep,DateReq} ->
        %     io:format("received date request~n"),
        %     Now = httpd_util:rfc1123_date(),
        %     io:format("sending date ~s~n", [Now]),
        %     ok = enm:send(Rep, Now);
        Other ->
        	lager:error("RECV O ~p", [Other])
       	after 2000 ->
       		error("NOTHING")
    end,
    % receive
    %     {nnreq,Req,Date} ->
    %         io:format("received date ~s~n", [Date])
    % end,
    enm:close(S),
    % enm:close(Rep),
    enm:stop().

%% ===================================================================
%% Types
%% ===================================================================


-type fs_start_opts() ::
	#{
		index => pos_integer(),
		version => binary(),
		release => binary(),
		password => binary(),
		docker_company => binary()
	}.




%% ===================================================================
%% Public functions
%% ===================================================================


%% @doc equivalent to start_fs(#{})
-spec start_fs() ->
	ok | {error, term()}.

start_fs() ->
	start_fs(#{}).


%% @doc Manually starts a local freeswitch
-spec start_fs(fs_start_opts()) ->
	ok | {error, term()}.

start_fs(Spec) ->
	nkmedia_fs:start(Spec).


%% @doc equivalent to stop_fs(#{})
-spec stop_fs() ->
	ok | {error, term()}.

stop_fs() ->
	stop_fs(#{}).


%% @doc Manually starts a local freeswitch
-spec stop_fs(fs_start_opts()) ->
	ok | {error, term()}.

stop_fs(Spec) ->
	nkmedia_fs:stop_fs(Spec).










%% ===================================================================
%% Private
%% ===================================================================


nkdocker_event(Id, Event) ->
	lager:warning("EVENT: ~p, ~p", [Id, Event]).