%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Carlos Gonzalez Florido.  All Rights Reserved.
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

-module(basic_test).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-compile([export_all]).
-include_lib("eunit/include/eunit.hrl").

basic_test_() ->
  	{setup, spawn, 
    	fun() -> 
    		ok = nkmedia_app:start()
		end,
		fun(_) -> 
			ok 
		end,
	    fun(_) ->
		    [
				fun() -> connect() end,
				fun() -> regs() end,
				fun() -> transports() end
			]
		end
  	}.


connect() ->
	?debugMsg("Starting CONNECT test"),
	{error, invalid_uri} = nkmedia_worker:start_link("http://localhost", #{}),
	{ok, P1} = nkmedia_worker:start_link("nkmedia://localhost:9999", #{}),
	timer:sleep(200),
	{ok, error, []} = nkmedia_worker:get_status(P1),
	nkmedia_worker:stop(P1),
	timer:sleep(100),
	false = is_process_alive(P1),

	{ok, Listen, UUID} = nkmedia_agent:get_listen(),
	{ok, P2} = nkmedia_worker:start_link(Listen, #{password=>"invalid"}),
	timer:sleep(200),
	{ok, error, []}= nkmedia_worker:get_status(P2),
	{error, not_connected} = nkmedia_worker:send_rpc(P2, core, get_meta, #{}),
	nkmedia_worker:stop(P2),
	
	{ok, P3} = nkmedia_worker:start_link(Listen, #{password=>"123"}),
	timer:sleep(200),
	{ok, ok, _} = nkmedia_worker:get_status(P3),
	[{Listen, UUID, P3, ok}] = nkmedia_worker:get_all(),
	{ok, P3} = nkmedia_worker:find_pid(UUID),
	{ok, P3} = nkmedia_worker:find_pid(Listen),
	nkmedia_worker:stop(P3).


regs() ->
	?debugMsg("Starting REGS test"),
	{ok, Listen, _UUID} = nkmedia_agent:get_listen(),
	{ok, P1} = nkmedia_worker:start_link(Listen),
	timer:sleep(100),
	{ok, Conn} = nkmedia_worker:get_conn(P1, #{}),
	[{{job, stats}, [_]}] = gen_server:call(Conn, get_regs),

	{ok, Conn} = nkmedia_worker:reg_job(P1, job1),
	{ok, Conn} = nkmedia_worker:reg_job(P1, job1),
	{ok, Conn} = nkmedia_worker:reg_job(P1, job2),
	{ok, Conn} = nkmedia_worker:reg_class(P1, class1),
	{ok, Conn} = nkmedia_worker:reg_class(P1, class1),
	{ok, Conn} = nkmedia_worker:reg_class(P1, class2),
	Self = self(),
	[
		{{class,class1}, [Self]},
 		{{class,class2}, [Self]},
 		{{job,job1}, [Self]},
 		{{job,job2}, [Self]},
 		{{job,stats}, [_]}
 	] = Regs1 = lists:sort(gen_server:call(Conn, get_regs)),
 	Ref = make_ref(),
 	Pid2 = spawn_link(
 		fun() ->
			{ok, Conn} = nkmedia_worker:reg_job(P1, job1),
			{ok, Conn} = nkmedia_worker:reg_class(P1, class2),
			Self ! {Ref, lists:sort(gen_server:call(Conn, get_regs))}
		end),
 	receive
 		{Ref, 
 			[
	           {{class,class1}, [Self]},
	           {{class,class2}, [Pid2, Self]},
	           {{job,job1}, [Pid2, Self]},
	           {{job,job2}, [Self]},
	           {{job,stats}, [_]}
	        ]} ->
           ok
    after 1000 -> 
    	error(?LINE)
    end,
    timer:sleep(100),
	Regs1 = lists:sort(gen_server:call(Conn, get_regs)),
 	ok = nkmedia_worker:unreg_job(P1, job3),
	Regs1 = lists:sort(gen_server:call(Conn, get_regs)),
 	ok = nkmedia_worker:unreg_job(P1, job1),
 	ok = nkmedia_worker:unreg_class(P1, class1),
	[
 		{{class,class2}, [Self]},
 		{{job,job2}, [Self]},
 	    {{job,stats}, [_]}
 	] = lists:sort(gen_server:call(Conn, get_regs)),
 	ok = nkmedia_worker:unreg_job(P1, job2),
 	ok = nkmedia_worker:unreg_class(P1, class2),
	[{{job, stats}, [_]}] = gen_server:call(Conn, get_regs),
 	nkmedia_worker:stop(P1).
	

transports() ->
	?debugMsg("Starting TRANSPORTS test"),
	Opts = #{
        tcp_packet => 4,
        ws_proto => <<"nkmedia">>,
        user => #{class=>{agent, <<"test1">>, #{}}, password=><<"123">>}
    },

    Conn1 = "nkmedia:all;transport=tls",
    {ok, Listen1} = nkpacket:start_listener(nkmedia_agent, Conn1, Opts),
    {ok, {tls, _, Port1}} = nkpacket:get_local(Listen1),
    Conn1B = "nkmedia:all:" ++ integer_to_list(Port1) ++ ";transport=tls", 
	{ok, Worker1} = nkmedia_worker:start_link(Conn1B),
	timer:sleep(100),
	{ok, ok, _} = nkmedia_worker:get_status(Worker1),
	nkmedia_worker:stop(Worker1),
	nkpacket:stop_listener(Listen1),

    Conn2 = "nkmedia:all;transport=ws",
    {ok, Listen2} = nkpacket:start_listener(nkmedia_agent, Conn2, Opts),
    {ok, {ws, _, Port2}} = nkpacket:get_local(Listen2),
    Conn2B = "nkmedia:all:" ++ integer_to_list(Port2) ++ ";transport=ws", 
	{ok, Worker2} = nkmedia_worker:start_link(Conn2B),
	timer:sleep(100),
	{ok, ok, _} = nkmedia_worker:get_status(Worker2),
	nkmedia_worker:stop(Worker2),
	nkpacket:stop_listener(Listen2),

    Conn3 = "nkmedia:all;transport=wss",
    {ok, Listen3} = nkpacket:start_listener(nkmedia_agent, Conn3, Opts),
    {ok, {wss, _, Port3}} = nkpacket:get_local(Listen3),
    Conn3B = "nkmedia:all:" ++ integer_to_list(Port3) ++ ";transport=wss", 
	{ok, Worker3} = nkmedia_worker:start_link(Conn3B),
	timer:sleep(100),
	{ok, ok, _} = nkmedia_worker:get_status(Worker3),
	nkmedia_worker:stop(Worker3),
	nkpacket:stop_listener(Listen3).






