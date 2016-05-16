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

-module(nkmedia_janus).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/0, start/1, stop/1, stop_all/0]).
-export([create/3, destroy/2, mirror/3]).
-export_type([config/0]).


%% ===================================================================
%% Types
%% ===================================================================

-type id() :: nkmedia_janus_engine:id().

-type client_id() :: nkmedia_janus_client:id().


-type config() ::
    #{
        comp => binary(),
        vsn => binary(),
        rel => binary(),
        base => inet:port_number(),
        pass => binary(),
        name => binary()
    }.




%% ===================================================================
%% Public functions
%% ===================================================================

%% @doc Starts a JANUS instance
-spec start() ->
    {ok, id()} | {error, term()}.

start() ->
    start(#{}).


%% @doc Starts a JANUS instance
-spec start(config()) ->
    {ok, id()} | {error, term()}.

start(Config) ->
	nkmedia_janus_docker:start(Config).


%% @doc Stops a JANUS instance
-spec stop(id()) ->
    ok | {error, term()}.

stop(Id) ->    
	nkmedia_fs_docker:stop(Id).


%% @doc
stop_all() ->
	nkmedia_janus_docker:stop_all().


%% @doc Creates a new session
-spec create(id(), nkmedia_session:id(), binary()) ->
    {ok, client_id()} | {error, term()}.

create(JanusId, SessId, Plugin) ->
	case nkmedia_janus_engine:get_conn(JanusId) of
		{ok, ConnPid} -> 
			nkmedia_janus_client:create(ConnPid, SessId, Plugin);
		{error, Error} ->
			{error, Error}
	end.



%% @doc Destroys a session
-spec destroy(id(), client_id()) ->
    ok.

destroy(JanusId, ClientId) ->
	case nkmedia_janus_engine:get_conn(JanusId) of
		{ok, ConnPid} -> 
			nkmedia_janus_client:destroy(ConnPid, ClientId);
		{error, Error} ->
			{error, Error}
	end.


mirror(JanusId, ClientId, Offer) ->
	Body = #{
		audio => maps:get(use_audio, Offer, true),
		vide => maps:get(use_video, Offer, true)
	},
	Jsep = case Offer of
        #{sdp:=SDP} ->
            #{sdp=>SDP, type=>offer};
        _ ->
        	#{}
    end,
    case message(JanusId, ClientId, Body, Jsep) of
    	{ok, Res, Jsep2} ->
    		case Res of
    			#{<<"data">>:=#{<<"result">>:=<<"ok">>}} ->
    				case Jsep2 of
    					#{<<"sdp">>:=SDP2} ->
    						{ok, #{sdp=>SDP2}};
    					_ ->
    						{ok, #{}}
    				end;
    			_ ->
    				{error, janus_error}
    		end;
    	{error, Error} ->
    		{error, Error}
    end.


play(JanusId, ClientId, FileId) ->
	Body = #{id=>FileId, request=>play},
	case message(JanusId, ClientId, Body) of
		{ok, _, #{<<"sdp">>:=SDP}} ->
			{ok, SDP};
		{ok, Body, _} ->
			{error, Body};
		{error, Error} ->
			{error, Error}
	end.








%% ===================================================================
%% Internal
%% ===================================================================

%% @private
message(JanusId, ClientId, Body) ->
	message(JanusId, ClientId, #{}).


%% @private
message(JanusId, ClientId, Body, Jsep) ->
	case nkmedia_janus_engine:get_conn(JanusId) of
		{ok, ConnPid} -> 
			nkmedia_janus_client:message(ConnPid, ClientId, Body, Jsep);
		{error, Error} ->
			{error, Error}
	end.



