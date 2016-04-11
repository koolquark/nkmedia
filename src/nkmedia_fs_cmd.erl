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

%% @doc NkMEDIA FS Commands
-module(nkmedia_fs_cmd).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([status/1, call/4, hangup/2, call_exists/2, unsched_api/2]).
-export([set_var/4, set_vars/3, unset_var/3, get_var/3, dump/2]).
-export([transfer/3, bridge/3, park/2, break/2, break_all/2]).
-export([mute/2, silence/2, clean/2, dtmf/3]).
-export([conference_relate/5, get_conference_data/2]).
-export([reloadxml/1, shutdown/1]).
-export([profile_restart/2]).


-type call_id() :: iolist().


%% @doc
-spec status(pid()) ->
	{ok, binary()} | {error, term()}.

status(Pid) ->
	bgapi(Pid, "status").


%% @doc
-spec call(pid(), string(), string(), 
	#{
		cid_name => string() | binary(),
		cid_number => integer() | string() | binary(),
		timeout => integer(),
		vars => [{iolist(), iolist()}], 
		proxy => string() | binary(),		%% "sip:..."
		call_id => string() | binary()
	}) ->
	{ok, binary()} | {error, term()}.

call(Pid, LegA, LegB, Opts) ->
	CIDName = maps:get(cid_name, Opts, "NkMEDIA"),
	CIDNumber= case maps:get(cid_number, Opts, undefined) of
		undefined -> undefined;
		CID0 -> nklib_util:to_binary(CID0)
	end, 
	Timeout = nklib_util:to_binary(maps:get(timeout, Opts, 30)),
	Vars = vars_to_list(maps:get(vars, Opts, [])),
	Append = [
		case maps:get(proxy, Opts, undefined) of
			undefined -> [];
			Proxy -> [";fs_path=", Proxy]
		end
	],
 	Cmd = [
		"originate {origination_caller_id_name='", CIDName, "'",
		case CIDNumber of
			undefined -> [];
			_ -> [",origination_caller_id_number='", CIDNumber, "'"]
		end,
		case maps:get(call_id, Opts, undefined) of
			undefined -> [];
			CallId -> [",origination_uuid=", CallId]
		end,
		",originate_timeout=", Timeout, 
		case Vars of [] -> []; _ -> [",", Vars] end, 
		"}", LegA, Append, " ", LegB
	],
	lager:info("ORIGINATE CMD ~s", [list_to_binary(Cmd)]),
	case bgapi(Pid, Cmd) of
		{ok, <<"+OK ", UUID/binary>>} ->
			Size = byte_size(UUID) -1 ,
		 	{ok, <<UUID:Size/binary>>};
		{ok, <<"-ERR USER_BUSY\n">>} -> {error, busy};
		{ok, <<"-ERR CALL_REJECTED\n">>} -> {error, rejected};
		{ok, <<"-ERR NO_USER_RESPONSE\n">>} -> {error, no_answer};
		{ok, <<"-ERR NO_ANSWER\n">>} -> {error, no_answer};
		{ok, <<"-ERR USER_NOT_REGISTERED\n">>}  -> {error, not_registered};
		{ok, <<"-ERR INVALID_NUMBER_FORMAT\n">>} -> {error, invalid_number};
		{ok, <<"-ERR DESTINATION_OUT_OF_ORDER\n">>} -> {error, out_or_order};
		{ok, <<"-ERR NO_ROUTE_DESTINATION\n">>} -> {error, no_route};
		{ok, <<"-ERR NORMAL_TEMPORARY_FAILURE\n">>} -> {error, temporary};
		{ok, <<"-ERR RECOVERY_ON_TIMER_EXPIRE\n">>} -> {error, recovery};
		{ok, <<"-ERR NORMAL_CLEARING\n">>}-> {error, normal_clearing};
		{ok, <<"-ERR MANDATORY_IE_MISSING\n">>}-> {error, missing_ie};
		{ok, <<"-ERR ", Other/binary>>}-> {error, Other};
		{error, Error} -> {error, {fs_error, Error}}
	end.


%% @doc
-spec hangup(pid(), call_id()) ->
	term().

hangup(Pid, CallId) ->
	process(api(Pid, ["uuid_kill ", CallId])).


%% @doc
-spec call_exists(pid(), call_id()) ->
	boolean().

call_exists(Pid, CallId) ->
	case api(Pid, ["uuid_exists ", CallId]) of
		{ok, <<"true">>} -> {ok, true};
		{ok, <<"false">>} -> {ok, false};
		{error, Error} -> {error, Error}
	end.


%% @doc
-spec unsched_api(pid(), binary()) ->
	term().

unsched_api(Pid, Id) ->
	process(bgapi(Pid, ["usched_api ", Id])).


%% @doc
-spec set_var(pid(), call_id(), string()|binary(), string()|binary()) ->
	term().

set_var(Pid, CallId, Key, Val) ->
	api(Pid, ["uuid_setvar ", CallId, " ", Key, " ", Val]).


%% @doc
-spec set_vars(pid(), call_id(), [{string()|binary(), string()|binary()}]) ->
	term().

set_vars(_Pid, _CallId, []) ->
	ok;
set_vars(Pid, CallId, [{Key, Val}|Rest]) ->
	case set_var(Pid, CallId, Key, Val) of
		ok -> set_vars(Pid, CallId, Rest);
		Other -> Other
	end.


%% @doc
-spec unset_var(pid(), call_id(), string()|binary()) ->
	term().

unset_var(Pid, CallId, Key) ->
	api(Pid, ["uuid_setvar ", CallId, " ", Key]).


%% @doc
-spec get_var(pid(), call_id(), string()|binary()) ->
	term().

get_var(Pid, CallId, Key) ->
	case api(Pid, ["uuid_getvar ", CallId, " ", Key]) of
		{error, _Error} -> error;
		<<"_undef_">> -> undefined;
		Value -> Value
	end.
		

%% @doc
-spec dump(pid(), call_id()) ->
	term().

dump(Pid, CallId) ->
	bgapi(Pid, ["uuid_dump ", CallId]).


%% @doc
-spec transfer(pid(), call_id(), string()|binary()) ->
	term().

transfer(Pid, CallId, Extension) ->
	bgapi(Pid, ["uuid_transfer ", CallId, " ", Extension, " XML default"]).


%% @doc
-spec dtmf(pid(), call_id(), string()|binary()) ->
	term().

dtmf(Pid, CallId, Dtmf) ->
	bgapi(Pid, ["uuid_send_dtmf ", CallId, " ", Dtmf]).



%% @doc
-spec bridge(pid(), call_id(), call_id()) ->
	term().

bridge(Pid, CallId1, CallId2) ->
	case bgapi(Pid, ["uuid_bridge ", CallId1, " ", CallId2]) of
		{ok, CallId2} -> ok;
		{error, Error} -> {error, Error}
	end.
		

%% @doc
-spec park(pid(), call_id()) ->
	term().

park(Pid, CallId) ->
	api(Pid, ["uuid_park ", CallId]).


%% @doc
-spec break(pid(), call_id()) ->
	term().

break(Pid, CallId) ->
	api(Pid, ["uuid_break ", CallId]).


%% @doc
-spec break_all(pid(), call_id()) ->
	term().

break_all(Pid, CallId) ->
	api(Pid, ["uuid_break ", CallId, " all"]).


%% @doc
-spec mute(pid(), call_id()) ->
	term().

mute(Pid, CallId) ->
	case api(Pid, ["uuid_audio ", CallId, " start read mute -4"]) of
		ok -> set_var(Pid, CallId, "nkmedia_muted", "true"), ok;
		{error, Error} -> {error, Error}
	end.
	

%% @doc
-spec silence(pid(), call_id()) ->
	term().

silence(Pid, CallId) ->
	case api(Pid, ["uuid_audio ", CallId, " start write mute -4"]) of
		ok -> set_var(Pid, CallId, "nkmedia_silenced", "true"), ok;
		{error, Error} -> {error, Error}
	end.


%% @doc
-spec clean(pid(), call_id()) ->
	term().

clean(Pid, CallId) ->
	case api(Pid, ["uuid_audio ", CallId, " stop"]) of
		ok -> 
			set_var(Pid, CallId, "nkmedia_muted", "false"), 
			set_var(Pid, CallId, "nkmedia_silenced", "false"), 
			ok;
		{error, Error} ->
			{error, Error}
	end.
	

%% @doc
-spec conference_relate(pid(), binary(), binary(), term(), binary()) ->
	term().

conference_relate(Pid, ConfName, User1, Opt, User2) ->
	api(Pid, ["conference ", ConfName, " relate ", User1, " ", User2, " ", Opt]).


%% @doc
-spec reloadxml(pid()) ->
	term().

reloadxml(Pid) ->
	bgapi(Pid, "reloadxml").


%% @doc
-spec profile_restart(pid(), binary()) ->
	term().

profile_restart(Pid, Profile) ->
	bgapi(Pid, ["sofia profile ", Profile, " restart"]).
		

%% @doc
-spec shutdown(pid()) ->
	term().

shutdown(Pid) ->
	nkmedia_fs_event_protocol:shutdown(Pid, "shutdown asap").	


%% @doc
-spec get_conference_data(pid(), iolist()) ->
	term().

get_conference_data(Pid, ConfName) ->
	{ok, Data} = bgapi(Pid, ["conference ", ConfName, " list"]),
	case lists:foldl(
		fun(Line, Acc) ->
			MemberData = binary:split(Line, <<";">>, [global]),
			case length(MemberData) of
				9 ->
					[Member, _ChannelNmae, Id, _Class, _Ext, FlagsStr, _N1, _N2, _N3] = MemberData,
					Flags = [F || F <- binary:split(FlagsStr, <<"|">>, [global])],
					[{Id, Member, Flags} | Acc];
				_ ->
					Acc
			end
		end, [], binary:split(Data, <<"\n">>, [global]))
	of
		[] -> undefined;
		ConfData -> ConfData
	end.


%%%%%%%%%%%%%%%%%%%%%%%%%% Low Level %%%%%%%%%%%%%%%%%%%%%%%%%%


api(Pid, Cmd) ->
	nkmedia_fs_server:api(Pid, Cmd).


bgapi(Pid, Cmd) ->
	nkmedia_fs_server:bgapi(Pid, Cmd).


process(Msg) ->
	case Msg of
		{ok, <<"+OK ", Ok/binary>>} -> {ok, Ok};
		{ok, <<"-ERR ", Error/binary>>} -> {error, Error};
		Other -> {error, Other}
	end.


vars_to_list(Vars) -> 
	vars_to_list(Vars, []).

vars_to_list([], Acc) -> 
	string:join(Acc, ",");

vars_to_list([{K,V}|Rest], Acc) -> 
	NewAcc = [nklib_util:to_list(K) ++ "=" ++ nklib_util:to_list(V) | Acc],
	vars_to_list(Rest, NewAcc).



