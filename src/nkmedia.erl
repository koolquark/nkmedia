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
-export_type([backend/0, offer/0, answer/0, hangup_reason/0, fs_start_opts/0]).
-export_type([callee_id/0, notify/0]).

%% ===================================================================
%% Types
%% ===================================================================


-type backend() :: p2p | freeswitch | janus.


-type offer() ::
	#{
		sdp => binary(),
		sdp_type => sip | webrtc,
        caller_name => binary(),
        caller_id => binary(),
        callee_name => binary(),
        callee_id => callee_id(),
        use_audio => boolean(),
        use_stereo => boolean(),
        use_video => boolean(),
        use_screen => boolean(),
        use_data => boolean(),
        in_bw => integer(),
        out_bw => integer(),
		verto_params => map()
	}.

-type callee_id() :: binary().


-type answer() ::
	#{
		sdp => binary(),
		sdp_type => sip | webrtc,
		verto_params => map(),
        use_audio => boolean(),
        use_video => boolean(),
        use_data => boolean()
	}.


-type hangup_reason() :: nkmedia:hangup_reason().


-type notify() :: 
	{Tag::term(), pid()} | {Tag::term(), Info::term(), pid()} | term().


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