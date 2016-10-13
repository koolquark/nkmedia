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

%% @doc Conf Plugin Callbacks
-module(nkmedia_conf_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_start/2, plugin_stop/2]).
-export([nkmedia_conf_init/2, nkmedia_conf_terminate/2, 
         nkmedia_conf_event/3, nkmedia_conf_reg_event/4, nkmedia_conf_reg_down/4,
         nkmedia_conf_tick/2, 
         nkmedia_conf_handle_call/3, nkmedia_conf_handle_cast/2, 
         nkmedia_conf_handle_info/2]).
-export([error_code/1]).
-export([api_cmd/2, api_syntax/4]).


-include("../../include/nkmedia.hrl").
-include_lib("nkservice/include/nkservice.hrl").


-type continue() :: continue | {continue, list()}.




%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia].


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA CONF (~s) starting", [Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA CONF (~p) stopping", [Name]),
    {ok, Config}.



%% ===================================================================
%% Error Codes
%% ===================================================================

%% @doc See nkservice_callbacks
-spec error_code(term()) ->
    {integer(), binary()} | continue.

error_code(conf_not_found)          ->  {304001, "Conference not found"};
error_code(conf_already_exists)     ->  {304002, "Conference already exists"};
error_code(conf_destroyed)          ->  {304003, "Conference destroyed"};
error_code(no_conf_members)         ->  {304004, "No remaining conf members"};
error_code(invalid_publisher)       ->  {304005, "Invalid publisher"};
error_code(publisher_stop)          ->  {304006, "Publisher stopped"};

error_code(_) -> continue.



%% ===================================================================
%% Conf Callbacks - Generated from nkmedia_conf
%% ===================================================================

-type conf_id() :: nkmedia_conf:id().
-type conf() :: nkmedia_conf:conf().



%% @doc Called when a new conf starts
-spec nkmedia_conf_init(conf_id(), conf()) ->
    {ok, conf()} | {error, term()}.

nkmedia_conf_init(_ConfId, Conf) ->
    {ok, Conf}.


%% @doc Called when the conf stops
-spec nkmedia_conf_terminate(Reason::term(), conf()) ->
    {ok, conf()}.

nkmedia_conf_terminate(_Reason, Conf) ->
    {ok, Conf}.


%% @doc Called when the status of the conf changes
-spec nkmedia_conf_event(conf_id(), nkmedia_conf:event(), conf()) ->
    {ok, conf()} | continue().

nkmedia_conf_event(ConfId, Event, Conf) ->
    nkmedia_conf_api_events:event(ConfId, Event, Conf).


%% @doc Called when the status of the conf changes, for each registered
%% process to the conf
-spec nkmedia_conf_reg_event(conf_id(), nklib:link(), nkmedia_conf:event(), conf()) ->
    {ok, conf()} | continue().

nkmedia_conf_reg_event(_ConfId, _Link, _Event, Conf) ->
    {ok, Conf}.


%% @doc Called when a registered process fails
-spec nkmedia_conf_reg_down(conf_id(), nklib:link(), term(), conf()) ->
    {ok, conf()} | {stop, Reason::term(), conf()} | continue().

nkmedia_conf_reg_down(_ConfId, _Link, _Reason, Conf) ->
    {stop, registered_down, Conf}.


%% @doc Called when a registered process fails
-spec nkmedia_conf_tick(conf_id(), conf()) ->
    {ok, conf()} | {stop, nkservice:error(), conf()} | continue().

nkmedia_conf_tick(_ConfId, Conf) ->
    {stop, timeout, Conf}.


%% @doc
-spec nkmedia_conf_handle_call(term(), {pid(), term()}, conf()) ->
    {reply, term(), conf()} | {noreply, conf()} | continue().

nkmedia_conf_handle_call(Msg, _From, Conf) ->
    lager:error("Module nkmedia_conf received unexpected call: ~p", [Msg]),
    {noreply, Conf}.


%% @doc
-spec nkmedia_conf_handle_cast(term(), conf()) ->
    {noreply, conf()} | continue().

nkmedia_conf_handle_cast(Msg, Conf) ->
    lager:error("Module nkmedia_conf received unexpected cast: ~p", [Msg]),
    {noreply, Conf}.


%% @doc
-spec nkmedia_conf_handle_info(term(), conf()) ->
    {noreply, conf()} | continue().

nkmedia_conf_handle_info(Msg, Conf) ->
    lager:warning("Module nkmedia_conf received unexpected info: ~p", [Msg]),
    {noreply, Conf}.



%% ===================================================================
%% API CMD
%% ===================================================================

%% @private
api_cmd(#api_req{class = <<"media">>, subclass = <<"conf">>, cmd=Cmd}=Req, State) ->
    nkmedia_conf_api:cmd(Cmd, Req, State);

api_cmd(_Req, _State) ->
    continue.


%% @privat
api_syntax(#api_req{class = <<"media">>, subclass = <<"conf">>, cmd=Cmd}, 
           Syntax, Defaults, Mandatory) ->
    nkmedia_conf_api_syntax:syntax(Cmd, Syntax, Defaults, Mandatory);
    
api_syntax(_Req, _Syntax, _Defaults, _Mandatory) ->
    continue.


