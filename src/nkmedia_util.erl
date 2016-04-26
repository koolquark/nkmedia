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

-module(nkmedia_util).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([get_q850/1, add_uuid/1, notify_mon/1]).
-export_type([q850/0, hangup_reason/0]).

-type q850() :: 0..609.
-type hangup_reason() :: q850() | string() | binary().

-include("nkmedia.hrl").


%% @private
add_uuid(#{id:=Id}=Config) when is_binary(Id) ->
    {Id, Config};

add_uuid(Config) ->
    Id = nklib_util:uuid_4122(),
    {Id, Config#{id=>Id}}.


%% @private
-spec nkmedia:notify() -> 
	reference() | undefined.

notify_mon({_, Pid}) -> monitor(process, Pid);
notify_mon({_, _, Pid}) -> monitor(process, Pid);
notify_mon(_) -> undefined.


%% @private
-spec get_q850(hangup_reason()) ->
	{q850(), binary()}.

get_q850(Code) when is_integer(Code) ->
	case maps:find(Code, q850_map()) of
		{ok, {_Sip, Msg}} -> {Code, Msg};
		error -> {Code, <<"UNKNOWN CODE">>}
	end;
get_q850(Msg) ->
	{0, nklib_util:to_binary(Msg)}.



%% @private
q850_map() ->
	#{
		0 => {none, <<"UNSPECIFIED">>},
		1 => {404, <<"UNALLOCATED_NUMBER">>},
		2 => {404, <<"NO_ROUTE_TRANSIT_NET">>},
		3 => {404, <<"NO_ROUTE_DESTINATION">>},
		6 => {none, <<"CHANNEL_UNACCEPTABLE">>},
		7 => {none, <<"CALL_AWARDED_DELIVERED">>},
		16 => {none, <<"NORMAL_CLEARING">>},
		17 => {486, <<"USER_BUSY">>},
		18 => {408, <<"NO_USER_RESPONSE">>},
		19 => {480, <<"NO_ANSWER">>},
		20 => {480, <<"SUBSCRIBER_ABSENT">>},
		21 => {603, <<"CALL_REJECTED">>},
		22 => {410, <<"NUMBER_CHANGED">>},
		23 => {410, <<"REDIRECTION_TO_NEW_DESTINATION">>},
		25 => {483, <<"EXCHANGE_ROUTING_ERROR">>},
		27 => {502, <<"DESTINATION_OUT_OF_ORDER">>},
		28 => {484, <<"INVALID_NUMBER_FORMAT">>},
		29 => {501, <<"FACILITY_REJECTED">>},
		30 => {none, <<"RESPONSE_TO_STATUS_ENQUIRY">>},
		31 => {480, <<"NORMAL_UNSPECIFIE">>},
		34 => {503, <<"NORMAL_CIRCUIT_CONGESTION">>},
		38 => {503, <<"NETWORK_OUT_OF_ORDER">>},
		41 => {503, <<"NORMAL_TEMPORARY_FAILURE">>},
		42 => {503, <<"SWITCH_CONGESTION">>},
		43 => {none, <<"ACCESS_INFO_DISCARDED">>},
		44 => {503, <<"REQUESTED_CHAN_UNAVAIL">>},
		45 => {none, <<"PRE_EMPTED">>},
		50 => {none, <<"FACILITY_NOT_SUBSCRIBED">>},
		52 => {403, <<"OUTGOING_CALL_BARRED">>},
		54 => {403, <<"INCOMING_CALL_BARRED">>},
		57 => {403, <<"BEARERCAPABILITY_NOTAUTH">>},
		58 => {503, <<"BEARERCAPABILITY_NOTAVAIL">>},
		63 => {none, <<"SERVICE_UNAVAILABLE">>},
		65 => {488, <<"BEARERCAPABILITY_NOTIMPL">>},
		66 => {none, <<"CHAN_NOT_IMPLEMENTED">>},
		69 => {501, <<"FACILITY_NOT_IMPLEMENTED">>},
		79 => {501, <<"SERVICE_NOT_IMPLEMENTED">>},
		81 => {none, <<"INVALID_CALL_REFERENCE">>},
		88 => {488, <<"INCOMPATIBLE_DESTINATION">>},
		95 => {none, <<"INVALID_MSG_UNSPECIFIED">>},
		96 => {none, <<"MANDATORY_IE_MISSING">>},
		97 => {none, <<"MESSAGE_TYPE_NONEXIST">>},
		98 => {none, <<"WRONG_MESSAGE">>},
		99 => {none, <<"IE_NONEXIST">>},
		100 => {none, <<"INVALID_IE_CONTENTS">>},
		101 => {none, <<"WRONG_CALL_STATE">>},
		102 => {504, <<"RECOVERY_ON_TIMER_EXPIRE">>},
		103 => {none, <<"MANDATORY_IE_LENGTH_ERROR">>},
		111 => {none, <<"PROTOCOL_ERROR">>},
		127 => {none, <<"INTERWORKING">>},
		487 => {487, <<"ORIGINATOR_CANCEL">>},	 	 
		500 => {none, <<"CRASH,">>},	 	
		501 => {none, <<"SYSTEM_SHUTDOWN,">>},	 	
		502 => {none, <<"LOSE_RACE,">>},	 	
		503 => {none, <<"MANAGER_REQUEST">>},
		600 => {none, <<"BLIND_TRANSFER,">>},	 	
		601 => {none, <<"ATTENDED_TRANSFER,">>},	 	
		602 => {none, <<"ALLOTTED_TIMEOUT">>},
		603 => {none, <<"USER_CHALLENGE,">>},	 	
		604 => {none, <<"MEDIA_TIMEOUT,">>},	 	
		605 => {none, <<"PICKED_OFF">>},
		606 => {none, <<"USER_NOT_REGISTERED">>},
		607 => {none, <<"PROGRESS_TIMEOUT">>},
		609 => {none, <<"GATEWAY_DOWN">>}
	}.




