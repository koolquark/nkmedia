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

%% @doc 
-module(nkmedia_janus_demo).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Janus Demo Plugin (~s) "++Txt, [State#state.user | Args])).

-define(PRINT(Txt, Args, State), 
        print(Txt, Args, State),    % Uncomment this for detailed logs
        ok).


-define(OP_TIME, 15000).            % Maximum operation time
-define(CALL_TIMEOUT, 30000).       % 


%% ===================================================================
%% Public
%% ===================================================================



%% ===================================================================
%% Public
%% ===================================================================


