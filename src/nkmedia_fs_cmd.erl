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

-export([status/1, call/4, hangup/2, call_exists/2]).
-export([set_var/4, set_vars/3, unset_var/3, get_var/3, dump/2]).
-export([transfer/3, transfer_inline/3, bridge/3, park/2, break/2, break_all/2]).
-export([mute/2, silence/2, clean/2, dtmf/3, reloadxml/1]).
-export([conference_users/2]).

-type fs_id() :: nkmedia_fs_engine:id().


%% @doc
-spec status(fs_id()) ->
	{ok, binary()} | {error, term()}.

status(FsId) ->
	api(FsId, "status").


%% @doc
-spec call(fs_id(), string(), string(), 
	#{
		cid_name => string() | binary(),
		cid_number => integer() | string() | binary(),
		timeout => integer(),
		codec_string => binary() | [binary()],			% Priority over default
		absolute_code_string => binary() | [binary()],	% A does not matter
		vars => [{iolist(), iolist()}], 
		proxy => string() | binary(),		%% "sip:..."
		call_id => string() | binary()
	}) ->
	{ok, binary()} | {error, term()}.

call(FsId, LegA, LegB, Opts) ->
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
		case maps:get(codec_string, Opts, undefined) of
			undefined -> [];
			Codecs -> [",codec_string='", nklib_util:bjoin(Codecs), "'"]
		end,
		case maps:get(absolute_codec_string, Opts, undefined) of
			undefined -> [];
			AbsCodecs -> [",absolute_codec_string='", nklib_util:bjoin(AbsCodecs), "'"]
		end,
		",originate_timeout=", Timeout, 
		case Vars of [] -> []; _ -> [",", Vars] end, 
		"}", LegA, Append, " ", LegB
	],
	lager:notice("ORIGINATE CMD ~s", [list_to_binary(Cmd)]),
	case api(FsId, Cmd) of
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
-spec hangup(fs_id(), binary()) ->
	term().

hangup(FsId, CallId) ->
	api_ok(FsId, ["uuid_kill ", CallId]).


%% @doc
-spec call_exists(fs_id(), binary()) ->
	{ok, boolean()} | {error, term()}.

call_exists(FsId, CallId) ->
	case api(FsId, ["uuid_exists ", CallId]) of
		{ok, <<"true">>} -> {ok, true};
		{ok, <<"false">>} -> {ok, false};
		{error, Error} -> {error, Error}
	end.


%% @doc
-spec get_var(fs_id(), binary(), string()|binary()) ->
	{ok, undefined|binary()} | {error, term()}.

get_var(FsId, CallId, Key) ->
	case api_msg(FsId, ["uuid_getvar ", CallId, " ", Key]) of
		{ok, <<"_undef_">>} -> {ok, undefined};
		Other -> Other
	end.


%% @doc
-spec set_var(fs_id(), binary(), string()|binary(), string()|binary()) ->
	ok | {error, term()}.

set_var(FsId, CallId, Key, Val) ->
	api_ok(FsId, ["uuid_setvar ", CallId, " ", Key, " ", Val]).


%% @doc
-spec set_vars(fs_id(), binary(), [{string()|binary(), string()|binary()}]) ->
	ok | {error, term()}.

set_vars(_FsId, _CallId, []) ->
	ok;
set_vars(FsId, CallId, [{Key, Val}|Rest]) ->
	case set_var(FsId, CallId, Key, Val) of
		ok -> set_vars(FsId, CallId, Rest);
		Other -> Other
	end.


%% @doc
-spec unset_var(fs_id(), binary(), string()|binary()) ->
	ok | {error, term()}.

unset_var(FsId, CallId, Key) ->
	api_ok(FsId, ["uuid_setvar ", CallId, " ", Key]).


%% @doc
-spec dump(fs_id(), binary()) ->
	{ok, #{binary() => binary()}} | {errror, term()}.

dump(FsId, CallId) ->
	case api_msg(FsId, ["uuid_dump ", CallId]) of
		{ok, Data} ->
			List = binary:split(Data, <<"\n">>, [global]),
			Lines = [list_to_tuple(binary:split(Line, <<": ">>)) 
				|| Line <- List, Line /= <<>>],
			{ok, maps:from_list(Lines)};
		{error, Error} ->
			{error, Error}
	end.


%% @doc
-spec transfer(fs_id(), binary(), string()|binary()) ->
	ok | {error, term()}.

transfer(FsId, CallId, Extension) ->
	api_ok(FsId, ["uuid_transfer ", CallId, " ", Extension, " XML default"]).


%% @doc For example "conference:1"
-spec transfer_inline(fs_id(), binary(), string()|binary()) ->
	ok | {error, term()}.

transfer_inline(FsId, CallId, App) ->
	api_ok(FsId, ["uuid_transfer ", CallId, " '", App, "' inline"]).


%% @doc
-spec dtmf(fs_id(), binary(), string()|binary()) ->
	ok | {error, term()}.

dtmf(FsId, CallId, Dtmf) ->
	api_ok(FsId, ["uuid_send_dtmf ", CallId, " ", Dtmf]).


%% @doc
-spec bridge(fs_id(), binary(), binary()) ->
	term().

bridge(FsId, CallId1, CallId2) ->
	api_ok(FsId, ["uuid_bridge ", CallId1, " ", CallId2]).
		

%% @doc
-spec park(fs_id(), binary()) ->
	term().

park(FsId, CallId) ->
	api_ok(FsId, ["uuid_park ", CallId]).


%% @doc
-spec break(fs_id(), binary()) ->
	ok | {error, term()}.

break(FsId, CallId) ->
	api_ok(FsId, ["uuid_break ", CallId]).


%% @doc
-spec break_all(fs_id(), binary()) ->
	ok | {error, term()}.

break_all(FsId, CallId) ->
	api_ok(FsId, ["uuid_break ", CallId, " all"]).


%% @doc
-spec mute(fs_id(), binary()) ->
	term().

mute(FsId, CallId) ->
	api_ok(FsId, ["uuid_audio ", CallId, " start read mute -4"]).

%% @doc
-spec silence(fs_id(), binary()) ->
	ok | {error, term()}.

silence(FsId, CallId) ->
	api_ok(FsId, ["uuid_audio ", CallId, " start write mute -4"]).


%% @doc
-spec clean(fs_id(), binary()) ->
	ok | {error, term()}.

clean(FsId, CallId) ->
	api_ok(FsId, ["uuid_audio ", CallId, " stop"]).
	

%% @doc
-spec reloadxml(fs_id()) ->
	ok | {error, term()}.

reloadxml(FsId) ->
	api_ok(FsId, "reloadxml").


%% @doc
-spec conference_users(fs_id(), iolist()) ->
	{ok, map()} | {error, term()}.

conference_users(FsId, ConfName) ->
	case api_msg(FsId, ["conference ", ConfName, " list"]) of
		{ok, <<"Conference", _/binary>>=Msg} ->
			{error, Msg};
		{ok, Data} ->
			Lines = binary:split(Data, <<"\n">>, [global]),
			Res = lists:foldl(
				fun(Line, Map) ->
					case binary:split(Line, <<";">>, [global]) of
						[
							Member, _ChannelName, Id, _User, _Email,
							Flags, _N1, _N2, _N3, _N4
						] ->
							FlagList = [
								binary_to_atom(F, latin1) ||
								F <- binary:split(Flags, <<"|">>, [global])
							],
							Single = #{
								id => Id,
								flags => FlagList
							},
							maps:put(nklib_util:to_integer(Member), Single, Map);
						_  ->
							Map
					end
				end,
				#{},
				Lines),
			{ok, Res};
		{error, Error} ->
			{error, Error}
	end.




%%%%%%%%%%%%%%%%%%%%%%%%%% Utilities %%%%%%%%%%%%%%%%%%%%%%%%%%


%% @private
api(FsId, Cmd) ->
	nkmedia_fs_engine:api(FsId, Cmd).


%% @private
api_msg(FsId, Cmd) ->
	case api(FsId, Cmd) of
		{ok, <<"+OK\n">>} -> {ok, <<>>};
		{ok, <<"+OK ", Ok/binary>>} -> {ok, Ok};
		{ok, <<"-ERR ", Error/binary>>} -> {error, Error};
		Other -> Other
	end.

%% @private
api_ok(FsId, Cmd) ->
	case api_msg(FsId, Cmd) of
		{ok, _} -> ok;
		{error, Error} -> {error, Error}
	end.
	

%% @private
vars_to_list(Vars) -> 
	vars_to_list(Vars, []).

vars_to_list([], Acc) -> 
	string:join(Acc, ",");

vars_to_list([{K,V}|Rest], Acc) -> 
	NewAcc = [nklib_util:to_list(K) ++ "=" ++ nklib_util:to_list(V) | Acc],
	vars_to_list(Rest, NewAcc).



