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
		trickle_ice_timeout,
		sdp_type,
		backend,
		master_id,
		slave_id,
		set_master_answer,
		stop_after_peer,
		wait_timeout,
		ready_timeout,
		user_id,
		user_session,
		backend_role,
		type,
		type_ext,

		peer_id,
		room_id,
		publisher_id,
		layout,
		loops,
		uri,
		mute_audio,
        mute_video,
        mute_data,
        bitrate
    ].


%% @private
syntax(<<"session">>, <<"create">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			type => atom,							%% p2p, proxy...
			wait_reply => boolean,

			session_id => binary,
			offer => offer(),
        	no_offer_trickle_ice => atom,
        	no_answer_trickle_ice => atom,
        	trickle_ice_timeout => {integer, 100, 30000},
            sdp_type => {enum, [webrtc, rtp]},		%% For generated SDP only
			backend => atom,						%% nkmedia_janus, etc.
			master_id => binary,
			set_master_answer => boolean,
			stop_after_peer => boolean,
			subscribe => boolean,
			events_body => any,
			wait_timeout => {integer, 1, none},
			ready_timeout => {integer, 1, none},

			% Type-specific
	        peer_id => binary,
	        room_id => binary,
	        publisher_id => binary,
	        layout => binary,
	        loops => {integer, 0, none},
        	uri => binary,
			mute_audio => boolean,
        	mute_video => boolean,
        	mute_data => boolean,
        	bitrate => integer
		},
		Defaults,
		[type|Mandatory]
	};

syntax(<<"session">>, <<"destroy">>, Syntax, Defaults, Mandatory) ->
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

syntax(<<"session">>, <<"get_offer">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{session_id => binary},
		Defaults,
		[session_id|Mandatory]
	};

syntax(<<"session">>, <<"get_answer">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{session_id => binary},
		Defaults,
		[session_id|Mandatory]
	};

syntax(<<"session">>, <<"update_media">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			session_id => binary,
			mute_audio => boolean,
			mute_video => boolean,
			mute_data => boolean,
			bitrate => integer
		},
		Defaults,
		[session_id|Mandatory]
	};

syntax(<<"session">>, <<"set_type">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			session_id => binary,
			type => atom,

			% Type specific
			room_id => binary,
			publisher_id => binary,
        	uri => binary,
        	layout => binary
		},
		Defaults,
		[session_id, type|Mandatory]
	};

syntax(<<"session">>, <<"recorder_action">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			session_id => binary,
			action => atom,
			uri => binary
		},
		Defaults,
		[session_id|Mandatory]
	};

syntax(<<"session">>, <<"player_action">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			session_id => binary,
			action => atom,
			uri => binary,
			loops => {integer, 0, none},
			position => integer
		},
		Defaults,
		[session_id|Mandatory]
	};

syntax(<<"session">>, <<"room_action">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			session_id => binary,
			action => atom,
			layout => binary
		},
		Defaults,
		[session_id|Mandatory]
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

syntax(<<"session">>, <<"get_info">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{session_id => binary},
		Defaults,
		[session_id|Mandatory]
	};

syntax(<<"session">>, <<"get_list">>, Syntax, Defaults, Mandatory) ->
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
		trickle_ice => boolean
     }.


%% @private
answer() ->
	#{
		sdp => binary,
		sdp_type => {enum, [rtp, webrtc]},
		trickle_ice => boolean
     }.






