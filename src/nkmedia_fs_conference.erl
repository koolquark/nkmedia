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

-module(nkmedia_fs_conference).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([modify/2]).
-export([fs_event/1, get_all/0, get_all_data/0, stop_all/0]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).

-define(CALL_TIMEOUT, 10000).
-define(CONF_EV, <<"conference::maintenance">>).

%% ===================================================================
%% Types
%% ===================================================================

-type member() ::
    #{
        call_id => binary(),
        type => binary()
    }.

-type op() ::
    {layout, binary()}.


%% ===================================================================
%% Public
%% ===================================================================


-spec modify(pid(), op()) ->
    ok | {error, term()}.

modify(Pid, Op) ->
    nklib_util:call(Pid, {op, Op}).
    



%% ===================================================================
%% Internal
%% ===================================================================


%% @private
fs_event(#{<<"Action">>:=<<"conference-destroy">>}=Event) ->
    #{<<"Conference-Unique-ID">>:=ConfId} = Event,
    case get_pid(ConfId) of
        {ok, Pid} ->
            gen_server:cast(Pid, stop);
        not_found ->
            ok
    end;

fs_event(Event) ->
    {ok, Pid} = get_pid(Event),
    event(Pid, Event).


%% @doc
get_all() ->
    nklib_proc:values(?MODULE).


%% @doc
get_all_data() ->
    lists:foldl(
        fun({{Id, _Name}, Pid}, Acc) ->
            Data = gen_server:call(Pid, get_data),
            maps:put(Id, Data, Acc)
        end,
        #{},
        get_all()).

%% @doc
stop_all() ->
    lists:foreach(fun({_, Pid}) -> gen_server:cast(Pid, stop) end, get_all()).


% ===================================================================
%% gen_server behaviour
%% ===================================================================


-record(state, {
    server_pid :: pid(),
    name :: binary(),
    id :: binary(),
    profile :: binary(),
    size :: integer(),
    members = #{} :: #{integer() => member()},
    floor = 0 :: integer(),
    video_floor = 0 :: integer()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()} | {ok, tuple(), timeout()|hibernate} |
    {stop, term()} | ignore.

init(Data) ->
    #{server:=Server, name:=Name, id:=Id, profile:=Profile, size:=Size} = Data,
    nklib_proc:put(?MODULE, {Id, Name}),
    nklib_proc:put({?MODULE, Name}, Id),
    nklib_proc:put({?MODULE, Id}, Name),
    State = #state{
        server_pid = Server,
        name = Name,
        id = Id,
        profile = Profile,
        size = Size
    },
    {ok, State}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(get_data, _From, State) ->
    #state{
        name = Name, 
        profile = Profile, 
        members = Members,
        video_floor = VideoFloor,
        floor = Floor
    } = State,
    Data = #{
        name => Name,
        profile => Profile,
        members => Members,
        video_floor => VideoFloor,
        floor => Floor,
        pid => self()
    },
    {reply, Data, State};


handle_call({op, Op}, _From, State) ->
    Reply = do_op(Op, State),
    {reply, Reply, State};

handle_call(Msg, _From, State) ->
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({add_member, Id, Data}, #state{members=Members}=State) ->
    Members2 = maps:put(Id, Data, Members),
    {noreply, State#state{members=Members2}};

handle_cast({del_member, Id}, #state{members=Members}=State) ->
    Members2 = maps:remove(Id, Members),
    case map_size(Members2) of
        0 ->
            lager:warning("Conference stopped (0 members)"),
            {stop, normal, State};
        _ ->
            {noreply, State#state{members=Members2}}
    end;

handle_cast({video_floor, Id}, State) ->
    {noreply, State#state{video_floor=Id}};

handle_cast({floor, Id}, State) ->
    {noreply, State#state{floor=Id}};

handle_cast({start_talking, _Id}, State) ->
    {noreply, State};

handle_cast({stop_talking, _Id}, State) ->
    {noreply, State};

handle_cast(stop, State) ->
    lager:warning("CONF DESTROY"),
    {stop, normal, State};

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

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

%% @private
do_op({layout, Layout}, #state{server_pid=Pid, name=Name}) ->
    Api = <<
        "conference ", Name/binary, " vid-layout ",
        (nklib_util:to_binary(Layout))/binary
    >>,
    case nkmedia_fs_server:bgapi(Pid, Api) of
        {ok, <<"Change ", _/binary>>} -> ok;
        {ok, Other} -> {error, Other};
        {error, Error} -> {error, Error}
    end;

do_op(_Op, _State) ->
    {error, invalid_op}.


%% @doc
get_pid(#{<<"Conference-Unique-ID">>:=ConfId} = Event) ->
    case nklib_proc:values({?MODULE, ConfId}) of
        [{_, Pid}|_] -> 
            {ok, Pid};
        [] -> 
            #{
                <<"Conference-Name">> := Name,
                <<"Conference-Profile-Name">> := Profile,
                <<"Conference-Size">> := SizeStr,
                <<"Conference-Unique-ID">> := Id
            } = Event,
            Data = #{
                server => self(),
                name => Name, 
                id => Id, 
                profile => Profile, 
                size => nklib_util:to_integer(SizeStr)
            },
            gen_server:start_link(?MODULE, Data, [])
    end;

get_pid(ConfId) when is_binary(ConfId) ->
    case nklib_proc:values({?MODULE, ConfId}) of
        [{_, Pid}|_] -> {ok, Pid};
        [] -> not_found
    end.


%% @private
event(_Pid, #{<<"Action">>:=<<"conference-create">>}) ->
    ok;

event(Pid, #{<<"Action">>:=<<"add-member">>}=Event) ->
    #{
        <<"Caller-Unique-ID">> := CallId,
        <<"Member-ID">> := MemberId,
        <<"Member-Type">> := MemberType
    } = Event,
    Id = nklib_util:to_integer(MemberId), 
    Data = #{type => MemberType, call_id => CallId},
    gen_server:cast(Pid, {add_member, Id, Data});

event(Pid, #{<<"Action">>:=<<"del-member">>}=Event) ->
    #{<<"Member-ID">> := MemberId} = Event,
    Id = nklib_util:to_integer(MemberId), 
    gen_server:cast(Pid, {del_member, Id});

event(Pid, #{<<"Action">>:=<<"video-floor-change">>}=Event) ->
    #{<<"New-ID">> := Id} = Event,
    gen_server:cast(Pid, {video_floor, nklib_util:to_integer(Id)});

event(Pid, #{<<"Action">>:=<<"floor-change">>}=Event) ->
    #{<<"New-ID">> := Id} = Event,
    gen_server:cast(Pid, {floor, nklib_util:to_integer(Id)});

event(Pid, #{<<"Action">>:=<<"start-talking">>}=Event) ->
    #{<<"Member-ID">> := Id} = Event,
    gen_server:cast(Pid, {start_talking, nklib_util:to_integer(Id)});

event(Pid, #{<<"Action">>:=<<"stop-talking">>}=Event) ->
    #{<<"Member-ID">> := Id} = Event,
    gen_server:cast(Pid, {stop_talking, nklib_util:to_integer(Id)});

event(_Pid, #{<<"Action">>:=<<"mute-member">>}=Event) ->
    #{<<"Member-ID">> := _Id} = Event,
    ok;

event(_Pid, #{<<"Action">>:=<<"unmute-member">>}=Event) ->
    #{<<"Member-ID">> := _Id} = Event,
    ok;

event(_Pid, #{<<"Action">>:=<<"deaf-member">>}=Event) ->
    #{<<"Member-ID">> := _Id} = Event,
    ok;

event(_Pid, #{<<"Action">>:=<<"undeaf-member">>}=Event) ->
    #{<<"Member-ID">> := _Id} = Event,
    ok;

event(_Pid, #{<<"Action">>:=<<"play-file-member-done">>}) ->
    ok;

event(_Pid, #{<<"Action">>:=<<"position_member">>}=Event) ->
    #{<<"Member-ID">> := _Id, <<"Position">> := _Position} = Event,
    ok;

event(_Pid, #{<<"Action">>:=<<"set-position-member">>}) ->
    ok;

event(_Pid, #{<<"Action">>:=<<"play-file-done">>}) ->
    ok;

event(_Pid, Event) ->
    lager:warning("Unknown event at ~p: ~p", [?MODULE, Event]).




% Layouts
% 1up_top_left+5
% 1up_top_left+7
% 1up_top_left+9
% 1x1
% 1x1+2x1
% 1x2
% 2up_bottom+8
% 2up_middle+8
% 2up_top+8
% 2x1
% 2x1-presenter-zoom
% 2x1-zoom
% 2x2
% 3up+4
% 3up+9
% 3x1-zoom
% 3x2-zoom
% 3x3
% 4x2-zoom
% 4x4, 
% 5-grid-zoom
% 5x5
% 6x6
% 7-grid-zoom
% 8x8
% overlaps
% presenter-dual-horizontal
% presenter-dual-vertical
% presenter-overlap-large-bot-right
% presenter-overlap-large-top-right
% presenter-overlap-small-bot-right
% presenter-overlap-small-top-right



% <conf name> list [delim <string>]|[count]
% <conf name> xml_list 
% <conf name> energy <member_id|all|last|non_moderator> [<newval>]
% <conf name> vid-canvas <member_id|all|last|non_moderator> [<newval>]
% <conf name> vid-watching-canvas <member_id|all|last|non_moderator> [<newval>]
% <conf name> vid-layer <member_id|all|last|non_moderator> [<newval>]
% <conf name> volume_in <member_id|all|last|non_moderator> [<newval>]
% <conf name> volume_out <member_id|all|last|non_moderator> [<newval>]
% <conf name> position <member_id> <x>:<y>:<z>
% <conf name> auto-3d-position [on|off]
% <conf name> play <file_path> [async|<member_id> [nomux]]
% <conf name> pause [<member_id>]
% <conf name> file_seek [+-]<val> [<member_id>]
% <conf name> say <text>
% <conf name> saymember <member_id> <text>
% <conf name> stop <[current|all|async|last]> [<member_id>]
% <conf name> dtmf <[member_id|all|last|non_moderator]> <digits>
% <conf name> kick <[member_id|all|last|non_moderator]> [<optional sound file>]
% <conf name> hup <[member_id|all|last|non_moderator]>
% <conf name> mute <[member_id|all]|last|non_moderator> [<quiet>]
% <conf name> tmute <[member_id|all]|last|non_moderator> [<quiet>]
% <conf name> unmute <[member_id|all]|last|non_moderator> [<quiet>]
% <conf name> vmute <[member_id|all]|last|non_moderator> [<quiet>]
% <conf name> tvmute <[member_id|all]|last|non_moderator> [<quiet>]
% <conf name> vmute-snap <[member_id|all]|last|non_moderator>
% <conf name> unvmute <[member_id|all]|last|non_moderator> [<quiet>]
% <conf name> deaf <[member_id|all]|last|non_moderator>
% <conf name> undeaf <[member_id|all]|last|non_moderator>
% <conf name> relate <member_id> <other_member_id> [nospeak|nohear|clear]
% <conf name> lock 
% <conf name> unlock 
% <conf name> agc 
% <conf name> dial <endpoint_module_name>/<destination> <callerid number> <callerid name>
% <conf name> bgdial <endpoint_module_name>/<destination> <callerid number> <callerid name>
% <conf name> transfer <conference_name> <member id> [...<member id>]
% <conf name> record <filename>
% <conf name> chkrecord <confname>
% <conf name> norecord <[filename|all]>
% <conf name> pause <filename>
% <conf name> resume <filename>
% <conf name> recording [start|stop|check|pause|resume] [<filename>|all]
% <conf name> exit_sound on|off|none|file <filename>
% <conf name> enter_sound on|off|none|file <filename>
% <conf name> pin <pin#>
% <conf name> nopin 
% <conf name> get <parameter-name>
% <conf name> set <max_members|sound_prefix|caller_id_name|caller_id_number|endconference_grace_time> <value>
% <conf name> file-vol <vol#>
% <conf name> floor <member_id|last>
% <conf name> vid-floor <member_id|last> [force]
% <conf name> vid-banner <member_id|last> <text>
% <conf name> vid-mute-img <member_id|last> [<path>|clear]
% <conf name> vid-logo-img <member_id|last> [<path>|clear]
% <conf name> vid-res-id <member_id|last> <val>|clear
% <conf name> get-uuid <member_id|last>
% <conf name> clear-vid-floor 
% <conf name> vid-layout <layout name>|group <group name> [<canvas id>]
% <conf name> vid-write-png <path>
% <conf name> vid-fps <fps>
% <conf name> vid-bgimg <file> | clear [<canvas-id>]
% <conf name> vid-bandwidth <BW>
