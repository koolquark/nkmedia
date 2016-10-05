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

%% @doc Call Plugin API Syntax
-module(nkmedia_call_api_syntax).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([syntax/5]).

-include_lib("nkservice/include/nkservice.hrl").


%% ===================================================================
%% Syntax
%% ===================================================================

syntax(<<"call">>, <<"start">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            call_id => binary,
            type => atom,
            callee => binary,
            caller => map,
            backend => atom,
            sdp_type => {enum, [webrtc, rtp]},
            events_body => any
        },
        Defaults,
        [callee|Mandatory]
    };

syntax(<<"call">>, <<"ringing">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            call_id => binary,
            session_id =>  binary,
            callee => map
        },
        Defaults,
        [call_id, session_id|Mandatory]
    };


syntax(<<"call">>, <<"answered">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            call_id => binary,
            session_id =>  binary,
            callee => map,
            answer => nkmedia_api_syntax:answer(),
            subscribe => boolean,
            events_body => any
        },
        Defaults,
        [call_id, session_id, answer|Mandatory]
    };

syntax(<<"call">>, <<"rejected">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            call_id => binary,
            session_id =>  binary
        },
        Defaults,
        [call_id, session_id|Mandatory]
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

