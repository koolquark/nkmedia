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

%% @doc NkMEDIA external API

-module(nkmedia_api_syntax).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([syntax/5]).



%% ===================================================================
%% Syntax
%% ===================================================================

%% @private
syntax(<<"session">>, <<"start">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			session_id => binary,
			type => atom,							%% p2p, proxy...
			offer => offer(),
			master_id => binary,
            sdp_type => {enum, [webrtc, rtp]},		%% For generated SDP only
			subscribe => boolean,
			events_body => any,
			wait_timeout => {integer, 1, none},
			ready_timeout => {integer, 1, none},
			backend => atom							%% nkmedia_janus, etc.
		},
		Defaults,
		[type|Mandatory]
	};

syntax(<<"session">>, <<"stop">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			session_id => binary,
			code => integer,
			reason => binary
		},
		Defaults,
		[session_id|Mandatory]
	};

syntax(<<"session">>, <<"set_answer">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			session_id => binary,
			answer => answer()
		},
		Defaults,
		[session_id, answer|Mandatory]
	};

syntax(<<"session">>, <<"set_candidate">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			session_id => binary,
			sdpMid => binary,
			sdpMLineIndex => integer,
			candidate => binary
		},
		Defaults,
		[session_id, sdpMid, sdpMLineIndex, candidate|Mandatory]
	};

syntax(<<"session">>, <<"set_candidate_end">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			session_id => binary,
			role => {enum, [caller, callee]}
		},
		Defaults#{role=>caller},
		[session_id|Mandatory]
	};

syntax(<<"session">>, <<"update">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			session_id => binary,
			update_type => atom
		},
		Defaults,
		[session_id, update_type|Mandatory]
	};

syntax(<<"session">>, <<"info">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{session_id => binary},
		Defaults,
		[session_id|Mandatory]
	};

syntax(<<"session">>, <<"list">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax,
		Defaults,
		Mandatory
	};

syntax(<<"call">>, <<"start">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			call_id => binary,
			callee => binary,
			type => atom,
			offer => offer(),
			meta => any,
			session_id => binary,
			ring_time => {integer, 1, none},
			events_body => any
		},
		Defaults,
		[callee|Mandatory]
	};

syntax(<<"call">>, <<"ringing">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			call_id => binary,
			answer => answer()
		},
		Defaults,
		[call_id|Mandatory]
	};


syntax(<<"call">>, <<"answered">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			call_id => binary,
			answer => answer(),
			subscribe => boolean,
			events_body => any
		},
		Defaults,
		[call_id|Mandatory]
	};

syntax(<<"call">>, <<"rejected">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{call_id => binary},
		Defaults,
		[call_id|Mandatory]
	};

syntax(<<"call">>, <<"hangup">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			call_id => binary,
			reason => binary
		},
		Defaults,
		[call_id|Mandatory]
	};


syntax(_Sub, _Cmd, Syntax, Defaults, Mandatory) ->
	{Syntax, Defaults, Mandatory}.


%% @private
offer() ->
	#{
		sdp => binary,
		sdp_type => {enum, [rtp, webrtc]},
		dest => binary,
        caller_name => binary,
        caller_id => binary,
        callee_name => binary,
        callee_id => binary
     }.


%% @private
answer() ->
	#{
		sdp => binary,
		sdp_type => {enum, [rtp, webrtc]}
     }.


