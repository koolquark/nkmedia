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

%% @doc Conf Plugin
-module(nkmedia_conf).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start/2, stop/1, stop/2, get_conf/1, get_info/1]).
-export([started_member/3, started_member/4, stopped_member/2]).
-export([send_event/2, restart_timer/1, register/2, unregister/2, get_all/0]).
-export([stop_all/0, get_all_with_role/2]).
-export([find/1, do_call/2, do_call/3, do_cast/2]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, conf/0, event/0]).


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Conference ~s (~p) "++Txt, 
               [State#state.id, State#state.backend | Args])).

-include("../../include/nkmedia_conf.hrl").
-include_lib("nkservice/include/nkservice.hrl").


-define(CHECK_TIME, 5*60).  


%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().

-type session_id() :: nkmedia_session:id().

-type config() ::
    #{
        class => atom(),                    % sfu | mcu
        backend => nkmedia:backend(),
        audio_codec => opus | isac32 | isac16 | pcmu | pcma,    % info only
        video_codec => vp8 | vp9 | h264,                        % "
        bitrate => integer()                                    % "
    }.

-type conf() ::
    config() |
    #{
        conf_id => id(),
        srv_id => nkservice:id(),
        members => #{session_id() => member_info()}
    }.

-type member_info() ::
    #{
        role => publisher | listener,
        user_id => binary(),
        peer_id => session_id()
    }.

-type event() :: 
    started |
    {stopped, nkservice:error()} |
    {started_member, session_id(), member_info()} |
    {stopped_member, session_id(), member_info()}.


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Creates a new conf
-spec start(nkservice:id(), config()) ->
    {ok, id(), pid()} | {error, term()}.

start(Srv, Config) ->
    {ConfId, Config2} = nkmedia_util:add_id(conf_id, Config, conf),
    case find(ConfId) of
        {ok, _} ->
            {error, conf_already_exists};
        not_found ->
            case nkservice_srv:get_srv_id(Srv) of
                {ok, SrvId} ->
                    Config3 = Config2#{conf_id=>ConfId, srv_id=>SrvId},
                    case SrvId:nkmedia_conf_init(ConfId, Config3) of
                        {ok, #{backend:=_}=Config4} ->
                            {ok, Pid} = gen_server:start(?MODULE, [Config4], []),
                            {ok, ConfId, Pid};
                        {ok, _} ->
                            {error, not_implemented};
                        {error, Error} ->
                            {error, Error}
                    end;
                not_found ->
                    {error, service_not_found}
            end
    end.


%% @doc
-spec stop(id()) ->
    ok | {error, term()}.

stop(Id) ->
    stop(Id, normal).


%% @doc
-spec stop(id(), nkservice:error()) ->
    ok | {error, term()}.

stop(Id, Reason) ->
    do_cast(Id, {stop, Reason}).


%% @doc
-spec stop_all() ->
    ok.

stop_all() ->
    lists:foreach(fun({Id, _Bk, _Pid}) -> stop(Id, user_stop) end, get_all()).



%% @doc
-spec get_conf(id()) ->
    {ok, conf()} | {error, term()}.

get_conf(Id) ->
    do_call(Id, get_conf).


%% @doc
-spec get_info(id()) ->
    {ok, conf()} | {error, term()}.

get_info(Id) ->
    case get_conf(Id) of
        {ok, Conf} ->
            Keys = [
                class, 
                backend,
                members, 
                audio_codec, 
                video_codec, 
                bitrate
            ],
            {ok, maps:with(Keys, Conf)};
        {error, Error} ->
            {error, Error}
    end.


%% @doc
-spec started_member(id(), session_id(), member_info()) ->
    ok | {error, term()}.

started_member(ConfId, SessId, MemberInfo) ->
    started_member(ConfId, SessId, MemberInfo, undefined).


%% @doc
-spec started_member(id(), session_id(), member_info(), pid()|undefined) ->
    ok | {error, term()}.

started_member(ConfId, SessId, MemberInfo, Pid) ->
    do_cast(ConfId, {started_member, SessId, MemberInfo, Pid}).


%% @doc
-spec stopped_member(id(), session_id()) ->
    ok | {error, term()}.

stopped_member(ConfId, SessId) ->
    do_cast(ConfId, {stopped_member, SessId}).


%% @private
-spec send_event(id(), map()) ->
    ok | {error, term()}.

send_event(Id, Event) ->
    do_cast(Id, {send_event, Event}).


%% @private
-spec restart_timer(id()) ->
    ok | {error, term()}.

restart_timer(Id) ->
    do_cast(Id, restart_timer).


%% @doc Registers a process with the conf
-spec register(id(), nklib:link()) ->     
    {ok, pid()} | {error, nkservice:error()}.

register(ConfId, Link) ->
    case find(ConfId) of
        {ok, Pid} -> 
            do_cast(ConfId, {register, Link}),
            {ok, Pid};
        not_found ->
            {error, conf_not_found}
    end.


%% @doc Registers a process with the call
-spec unregister(id(), nklib:link()) ->
    ok | {error, nkservice:error()}.

unregister(ConfId, Link) ->
    do_call(ConfId, {unregister, Link}).


%% @doc Gets all started confs
-spec get_all() ->
    [{id(), nkmedia:backend(), pid()}].

get_all() ->
    [{Id, Backend, Pid} || 
        {{Id, Backend}, Pid}<- nklib_proc:values(?MODULE)].


% ===================================================================
%% gen_server behaviour
%% ===================================================================


-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    backend :: nkmedia:backend(),
    timer :: reference(),
    stop_sent = false :: boolean(),
    links :: nklib_links:links(),
    conf :: conf()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()}.

init([#{srv_id:=SrvId, conf_id:=ConfId}=Conf]) ->
    Backend = maps:get(backend, Conf, undefined),
    nklib_proc:put(?MODULE, {ConfId, Backend}),
    nklib_proc:put({?MODULE, ConfId}),
    State = #state{
        id = ConfId, 
        srv_id = SrvId, 
        backend = Backend,
        links = nklib_links:new(),
        conf = Conf#{members=>#{}}
    },
    ?LLOG(notice, "started", [], State),
    State2 = do_event(started, State),
    {ok, do_restart_timer(State2)}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(get_conf, _From, #state{conf=Conf}=State) -> 
    {reply, {ok, Conf}, State};

handle_call(get_state, _From, State) ->
    {reply, State, State};

handle_call(Msg, From, State) -> 
    handle(nkmedia_conf_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

%% @private
handle_cast({started_member, SessId, Info, Pid}, State) ->
    {noreply, do_started_member(SessId, Info, Pid, State)};

handle_cast({stopped_member, SessId}, State) ->
    {noreply, do_stopped_member(SessId, State)};

handle_cast(restart_timer, State) ->
    {noreply, do_restart_timer(State)};

handle_cast({send_event, Event}, State) ->
    {noreply, do_event(Event, State)};

handle_cast({register, Link}, State) ->
    ?LLOG(info, "proc registered (~p)", [Link], State),
    Pid = nklib_links:get_pid(Link),
    State2 = links_add(Link, reg, Pid, State),
    {noreply, State2};

handle_cast({unregister, Link}, State) ->
    ?LLOG(info, "proc unregistered (~p)", [Link], State),
    {noreply, links_remove(Link, State)};

handle_cast({stop, Reason}, State) ->
    ?LLOG(info, "external stop: ~p", [Reason], State),
    do_stop(Reason, State);

handle_cast(Msg, State) -> 
    handle(nkmedia_conf_handle_cast, [Msg], State).


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info(conf_tick, #state{id=ConfId}=State) ->
    case handle(nkmedia_conf_tick, [ConfId], State) of
        {ok, State2} ->
            {noreply, do_restart_timer(State2)};
        {stop, Reason, State2} ->
            do_stop(Reason, State2)
    end;

handle_info({'DOWN', Ref, process, _Pid, Reason}=Msg, State) ->
    case links_down(Ref, State) of
        {ok, SessId, member, State2} ->
            ?LLOG(notice, "member ~s down", [SessId], State2),
            {noreply, do_stopped_member(SessId, State2)};
        {ok, Link, reg, State2} ->
            ?LLOG(notice, "stopping beacuse of reg '~p' down (~p)",
                  [Link, Reason], State2),
            do_stop(registered_down, State2);
        not_found ->
            handle(nkmedia_conf_handle_info, [Msg], State)
    end;

handle_info(Msg, #state{}=State) -> 
    handle(nkmedia_conf_handle_info, [Msg], State).


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(Reason, State) ->
    {ok, State2} = handle(nkmedia_conf_terminate, [Reason], State),
    case Reason of
        normal ->
            ?LLOG(info, "terminate: ~p", [Reason], State2),
            _ = do_stop(normal_termination, State2);
        _ ->
            Ref = nkmedia_lib:uid(),
            ?LLOG(notice, "terminate error ~s: ~p", [Ref, Reason], State2),
            _ = do_stop({internal_error, Ref}, State2)
    end,    
    timer:sleep(100),
    ok.

% ===================================================================
%% Internal
%% ===================================================================


%% @private
get_all_with_role(Role, #{members:=Members}) ->
    [Id ||  
        {Id, Info} <- maps:to_list(Members), {ok, Role}==maps:find(role, Info)].

%% @private
do_started_member(SessId, Info, Pid, #state{conf=#{members:=Members}=Conf}=State) ->
    State2 = links_remove(SessId, State),
    State3 = case is_pid(Pid) of
        true ->
            links_add(SessId, member, Pid, State2);
        _ ->
            State2
    end,
    Conf2 = ?CONF(#{members=>maps:put(SessId, Info, Members)}, Conf),
    State4 = State3#state{conf=Conf2},
    do_event({started_member, SessId, Info}, State4).


%% @private
do_stopped_member(SessId, #state{conf=#{members:=Members}=Conf}=State) ->
    case maps:find(SessId, Members) of
        {ok, Info} ->
            State2 = links_remove(SessId, State),
            case Info of
                #{role:=publisher} ->
                    stop_listeners(SessId, maps:to_list(Members));
                _ ->
                    ok
            end,
            Members2 = maps:remove(SessId, Members),
            Conf2 = ?CONF(#{members=>Members2}, Conf),
            State3 = State2#state{conf=Conf2},
            do_event({stopped_member, SessId, Info}, State3);
        error ->
            State
    end.


%% @private
stop_listeners(_PubId, []) ->
    ok;

stop_listeners(PubId, [{ListenId, Info}|Rest]) ->
    case Info of
        #{role:=listener, peer_id:=PubId} ->
            nkmedia_session:stop(ListenId, publisher_stop);
        _ ->
            ok            
    end,
    stop_listeners(PubId, Rest).



%% @private
find(Pid) when is_pid(Pid) ->
    {ok, Pid};

find(#{conf_id:=ConfId}) ->
    find(ConfId);

find(Id) ->
    Id2 = nklib_util:to_binary(Id),
    case nklib_proc:values({?MODULE, Id2}) of
        [{_, Pid}] -> {ok, Pid};
        [] -> not_found
    end.


%% @private
do_call(Id, Msg) ->
    do_call(Id, Msg, 5000).


%% @private
do_call(Id, Msg, Timeout) ->
    case find(Id) of
        {ok, Pid} -> 
            nkservice_util:call(Pid, Msg, Timeout);
        not_found -> 
            {error, conf_not_found}
    end.


%% @private
do_cast(Id, Msg) ->
    case find(Id) of
        {ok, Pid} -> 
            gen_server:cast(Pid, Msg);
        not_found -> 
            {error, conf_not_found}
    end.


%% @private
do_stop(_Reason, #state{stop_sent=true}=State) ->
    {stop, normal, State};

do_stop(Reason, #state{conf=#{members:=Members}}=State) ->
    lists:foreach(
        fun({SessId, _}) -> nkmedia_session:stop(SessId, conf_destroyed) end,
        maps:to_list(Members)),
    State2 = do_event({stopped, Reason}, State#state{stop_sent=true}),
    % Allow events to be processed
    timer:sleep(100),
    {stop, normal, State2}.


%% @private
do_event(Event, #state{id=Id}=State) ->
    ?LLOG(info, "sending 'event': ~p", [Event], State),
    State2 = links_fold(
        fun
            (Link, reg, AccState) ->
                {ok, AccState2} = 
                    handle(nkmedia_conf_reg_event, [Id, Link, Event], AccState),
                    AccState2;
            (_SessId, member, AccState) ->
                AccState
        end,
        State,
        State),
    {ok, State3} = handle(nkmedia_conf_event, [Id, Event], State2),
    State3.


%% @private
handle(Fun, Args, State) ->
    nklib_gen_server:handle_any(Fun, Args, State, #state.srv_id, #state.conf).


%% @private
links_add(Id, Data, Pid, #state{links=Links}=State) ->
    State#state{links=nklib_links:add(Id, Data, Pid, Links)}.


%% @private
links_remove(Id, #state{links=Links}=State) ->
    State#state{links=nklib_links:remove(Id, Links)}.


%% @private
links_down(Ref, #state{links=Links}=State) ->
    case nklib_links:down(Ref, Links) of
        {ok, Link, Data, Links2} -> 
            {ok, Link, Data, State#state{links=Links2}};
        not_found -> 
            not_found
    end.

%% @private
links_fold(Fun, Acc, #state{links=Links}) ->
    nklib_links:fold_values(Fun, Acc, Links).


%% @private
do_restart_timer(#state{timer=Timer}=State) ->
    nklib_util:cancel_timer(Timer),
    Time = 1000 * ?CHECK_TIME,
    State#state{timer=erlang:send_after(Time, self(), conf_tick)}.

