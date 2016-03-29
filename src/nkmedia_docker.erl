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

-module(nkmedia_docker).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([get_docker/0, start_link/0]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).



%% ===================================================================
%% Types
%% ===================================================================


%% ===================================================================
%% Public
%% ===================================================================



%% @doc Runs a nkdocker command using configured docker options
-spec get_docker() ->
    term() | {error, term()}.

get_docker() ->
    gen_server:call(?MODULE, get_pid).



%% ===================================================================
%% Private
%% ===================================================================



%% @private
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).



% ===================================================================
%% gen_server behaviour
%% ===================================================================

-record(state, {
    server :: pid(),
    events_ref :: reference()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()} | {ok, tuple(), timeout()|hibernate} |
    {stop, term()} | ignore.

init([]) ->
    DockerOpts = nkmedia_app:get(docker_opts),
    % Avoid start_link/1 to be able to print errors
    case nkdocker:start(DockerOpts) of
        {ok, Pid} ->
            link(Pid),
            case nkdocker:events(Pid) of
                {async, Ref} ->
                    Company = nkmedia_app:get(docker_company),
                    Images = find_images(Company, Pid),
                    lager:info("Installed docker images for '~s': ~s", 
                                [Company, nklib_util:bjoin(Images, <<", ">>)]),
                    monitor(process, Pid),
                    {ok, #state{server=Pid, events_ref=Ref}};
                {error, Error} ->
                    {stop, Error}
            end;
        {error, Error} ->
            lager:error("Could not connect to docker!"),
            {stop, Error}
    end.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(get_pid, _From, #state{server=Pid}=State) ->
    {reply, {ok, Pid}, State};

handle_call(state, _From, State) ->
    {reply, State, State};

handle_call(Msg, _From, State) ->
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.


handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({nkdocker, Ref, {data, Map}}, #state{events_ref=Ref}=State) ->
    {noreply, event(Map, State)};

handle_info({'DOWN', _Ref, process, Pid, Reason}, #state{server=Pid}=State) ->
    lager:warning("NkMEDIA Docker server failed! (~p)", [Reason]),
    {stop, docker_error, State};

handle_info(Info, State) -> 
    lager:warning("Module ~p received unexpected info: ~p (~p)", [?MODULE, Info, State]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(_Reason, _State) ->
    ok.
    


% ===================================================================
%% Internal
%% ===================================================================

event(#{<<"status">>:=Status, <<"id">>:=Id, <<"time">>:=Time}=Msg, State) ->
    From = maps:get(<<"from">>, Msg, <<>>),
    Event = {binary_to_atom(Status, latin1), Id, From, Time},
    lager:debug("Event: ~p", [Event]),
    State;

event(#{<<"Action">>:=Action}, State) ->
    lager:notice("Action event: ~s", [Action]),
    State;

event(Event, State) ->
    lager:notice("Unrecognized event: ~p", [Event]),
    State.


%% @private
find_images(Company, Pid) ->
    case nkdocker:images(Pid) of
        {ok, Images} ->
            List = lists:foldl(
                fun(#{<<"RepoTags">>:=Tags}, Acc) ->
                    Acc++Tags
                end,
                [],
                Images),
            Size = byte_size(Company),
            lists:filtermap(
                fun(Tag) ->
                    case Tag of
                        <<Company:Size/binary, $/, Rest/binary>> -> {true, Rest};
                        _ -> false
                    end
                end,
                List);
        {error, Error} ->
            {error, Error}
    end.





