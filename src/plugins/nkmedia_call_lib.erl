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

%% @doc Call Li
%%
%% Typical call process:
%% - A session is started
%% - A call is started, linking it with the session (using session_id)
%% - The call registers itself with the session
%% - When the call has an answer, it is captured in nkmedia_call_reg_event
%%   (nkmedia_callbacks) and sent to the session. Same with hangups
%% - If the session stops, it is captured in nkmedia_session_reg_event
%% - When the call stops, the called process must detect it in nkmedia_call_reg_event

-module(nkmedia_call_lib).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').


% -include("../../include/nkmedia.hrl").
% -include("../../include/nkmedia_call.hrl").
% -include_lib("nkservice/include/nkservice.hrl").



%% ===================================================================
%% Types
%% ===================================================================




