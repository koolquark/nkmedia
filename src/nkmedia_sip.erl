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

%% @doc NkMEDIA SIP utilities

-module(nkmedia_sip).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/0, stop/0]).


%% ===================================================================
%% Types
%% ===================================================================



%% ===================================================================
%% Public functions
%% ===================================================================


start() ->
	Host = nkmedia_app:get(local_host),
	{ok, Ip} = nklib_util:to_ip(Host),
	%% Avoid openning 5060 but open a random port
	Dummy = case gen_udp:open(5060, [{ip, Ip}]) of
		{ok, Socket} -> Socket;
		{error, _} -> none
	end,
	Sip = <<"sip:", Host/binary>>,
    Opts = #{
        class => nkmedia_sip,
        plugins => [nkmedia_sip, nksip],
        sip_listen => Sip
    },
    {ok, bnulhwa} = nkservice:start(nkmedia_sip, Opts),
    case Dummy of
    	error -> ok;
    	DummySocket -> gen_udp:close(DummySocket)
    end,
    [Listener] = nkservice:get_listeners(bnulhwa, nksip),
    {ok, {nksip_protocol, udp, Ip, Port}} = nkpacket:get_local(Listener),
    nkmedia_app:put(sip_port, Port).


stop() ->
	nkservice:stop(nkmedia_sip).
