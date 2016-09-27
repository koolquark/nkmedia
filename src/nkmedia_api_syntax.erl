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
-export([syntax/5, session_fields/0, offer/0, answer/0]).



%% ===================================================================
%% Syntax
%% ===================================================================


%% @private
session_fields() ->
	[
		session_id, 
		offer,
		answer,
		no_offer_trickle_ice,
		no_answer_trickle_ice,
		ice_timeout,
		sdp_type,
		backend,
		master_id,
		set_master_answer,
		stop_after_peer,
		wait_timeout,
		ready_timeout,
		user_id,
		user_session,
		backend_role,
		type,
		type_ext,
		master_peer,
		slave_peer,

		room_id,
		publisher_id,
		mute_audio,
        mute_video,
        mute_data,
        bitrate,
        record,
        record_uri,
        player_uri
    ].


%% @private
syntax(<<"session">>, <<"start">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			type => atom,							%% p2p, proxy...
			session_id => binary,
			offer => offer(),
        	no_offer_trickle_ice => atom,
        	no_answer_trickle_ice => atom,
        	ice_timeout => {integer, 100, 30000},
            sdp_type => {enum, [webrtc, rtp]},		%% For generated SDP only
			backend => atom,						%% nkmedia_janus, etc.
			master_id => binary,
			set_master_answer => boolean,
			stop_after_peer => boolean,
			subscribe => boolean,
			events_body => any,
			wait_timeout => {integer, 1, none},
			ready_timeout => {integer, 1, none},

	        room_id => binary,
	        publisher_id => binary,
			mute_audio => boolean,
        	mute_video => boolean,
        	mute_data => boolean,
        	bitrate => integer, 
        	record => boolean,
        	record_uri => binary,
        	player_uri => binary
		},
		Defaults,
		[type|Mandatory]
	};

syntax(<<"session">>, <<"stop">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{session_id => binary},
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
		Defaults#{sdpMid=><<>>},
		[session_id, sdpMLineIndex, candidate|Mandatory]
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

syntax(<<"session">>, <<"cmd">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			session_id => binary,
			cmd => atom,
			mute_audio => boolean,
			mute_video => boolean,
			mute_data => boolean,
			bitrate => integer,
			operation => atom,
			position => integer
		},
		Defaults,
		[session_id, cmd|Mandatory]
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






