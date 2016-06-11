
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

%% @doc Plugins implementing a Verto-compatible server
-module(nkmedia_sample).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/0, stop/0, restart/0]).
-export([listener/2, listener2/1, play/2, play2/1]).
-export([plugin_deps/0, plugin_start/2, plugin_stop/2,
         plugin_syntax/0, plugin_listen/2]).
-export([nkmedia_verto_login/3, nkmedia_verto_call/3]).
-export([nkmedia_call_resolve/2]).
-export([nkmedia_janus_call/3]).
-export([nkmedia_sip_call/2]).
% -export([nkmedia_call_event/3, nkmedia_session_event/3]).
-export([sip_register/2]).

-include("nkmedia.hrl").

-define(LOG_SAMPLE(Type, Txt, Args, State),
    lager:Type("Sample (~s) "++Txt, [maps:get(user, State) | Args])).



%% ===================================================================
%% Public
%% ===================================================================


start() ->
    _CertDir = code:priv_dir(nkpacket),
    Spec = #{
        plugins => [?MODULE],
        webserver => "https:all:8081",
        verto_listen => "verto:all:8082",
        verto_proxy => "verto_proxy:all:8083",
        janus_listen => "janus:all:8989", 
        janus_proxy=> "janus_proxy:all:8990",
        kurento_proxy => "kms:all:8433",
        log_level => debug,
        nksip_trace => {console, all},
        sip_listen => <<"sip:all:5060">>,
        log_level => debug
    },
    nkservice:start(sample, Spec).


stop() ->
    nkservice:stop(sample).

restart() ->
    stop(),
    timer:sleep(100),
    start().



listener2(Id) ->
    {ok, SessId, Pid} = nkmedia_session:start(sample, #{}),
    {ok, Meta} = nkmedia_session:offer(SessId, {listen, "room2", Id}, #{}),
    #{offer:=Offer} = Meta,
    nkmedia_janus_proto:register_play(SessId, Pid, Offer).


listener(Sess, Dest) ->
    case nkmedia_session:get_status(Sess) of
        {ok, publish, #{room:=Room}, _} ->
            {ok, SessId, _Pid} = nkmedia_session:start(sample, #{}),
            {ok, _} = nkmedia_session:offer(SessId, {listen, Room, Sess}, #{}),
            case Dest of
                {call, Call} ->
                    {ok, _} = nkmedia_session:answer(SessId, {call, Call}, #{});
                {room, Room2} ->
                    nkmedia_session:answer(SessId, {publish, Room2}, #{})
            end;
        _ ->
            {error, invalid_session}
    end.


play(Id, Dest) ->
    {ok, SessId, _Pid} = nkmedia_session:start(sample, #{}),
    {ok, _} = nkmedia_session:offer(SessId, {play, Id}, #{}),
    case Dest of
        {call, Call} ->
            {ok, _} = nkmedia_session:answer(SessId, {call, Call}, #{});
        {room, Room2} ->
            nkmedia_session:answer(SessId, {publish, Room2}, #{})
    end,
    listener(SessId, {call, "c"}).


play2(Id) ->
    {ok, SessId, Pid} = nkmedia_session:start(sample, #{}),
    {ok, Meta} = nkmedia_session:offer(SessId, {play, Id}, #{}),
    #{offer:=Offer} = Meta,
    nkmedia_janus_proto:register_play(SessId, Pid, Offer).





%% ===================================================================
%% Config callbacks
%% ===================================================================


plugin_deps() ->
    [
        nkmedia_sip, 
        nkmedia_verto, nkmedia_fs, nkmedia_fs_verto_proxy,
        nkmedia_janus_proto, nkmedia_janus_proxy, nkmedia_janus,
        nkmedia_kms, nkmedia_kms_proxy
    ].


plugin_syntax() ->
    #{
        webserver => fun parse_listen/3
    }.


plugin_listen(Config, #{id:=SrvId}) ->
    Web1 = maps:get(webserver, Config, []),
    Path1 = list_to_binary(code:priv_dir(nkmedia)),
    Path2 = <<Path1/binary, "/www">>,
    Opts2 = #{
        class => {sample_webserver, SrvId},
        http_proto => {static, #{path=>Path2, index_file=><<"index.html">>}}
    },
    [{Conns, maps:merge(ConnOpts, Opts2)} || {Conns, ConnOpts} <- Web1].


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin ~p (~s) starting", [?MODULE, Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin ~p (~p) stopping", [?MODULE, Name]),
    {ok, Config}.




%% ===================================================================
%% nkmedia_verto callbacks
%% ===================================================================


nkmedia_verto_login(Login, Pass, Verto) ->
    case binary:split(Login, <<"@">>) of
        [User, _] ->
            Verto2 = Verto#{user=>User},
            ?LOG_SAMPLE(info, "login: ~s (pass ~s)", [User, Pass], Verto2),
            {true, User, Verto2};
        _ ->
            {false, Verto}
    end.


nkmedia_verto_call(SessId, Dest, Verto) ->
    case send_call(SessId, Dest) of
        ok ->
            {ok, Verto};
        {error, Error} ->
            {rejected, Error, Verto}
    end.



%% ===================================================================
%% nkmedia_janus_proto callbacks
%% ===================================================================


nkmedia_janus_call(SessId, Dest, Janus) ->
    case send_call(SessId, Dest) of
        ok ->
            {ok, Janus};
        {error, Error} ->
            {rejected, Error, Janus}
    end.



%% ===================================================================
%% nkmedia_sip callbacks
%% ===================================================================


nkmedia_sip_call(SessId, Dest) ->
    case send_call(SessId, Dest) of
        ok ->
            ok;
        {error, _} ->
            hangup
    end.




%% ===================================================================
%% nkmedia callbacks
%% ===================================================================



%% @private
nkmedia_call_resolve(Dest, #{srv_id:=SrvId}=Call) ->
    case nksip_registrar:find(SrvId, sip, Dest, <<"nkmedia_sample">>) of
        [] ->
            lager:info("sip not found: ~s", [Dest]),
            continue;
        [Uri|_] ->
            lager:info("sip found: ~s", [Dest]),
            Spec = [#{dest=>{nkmedia_sip, Uri, #{}}, sdp_type=>rtp}],
            {ok, Spec, Call}
    end.
            


%% ===================================================================
%% sip_callbacks
%% ===================================================================


sip_register(Req, Call) ->
    Req2 = nksip_registrar_util:force_domain(Req, <<"nkmedia_sample">>),
    {continue, [Req2, Call]}.




%% ===================================================================
%% Internal
%% ===================================================================

send_call(SessId, #{dest:=Dest}=Offer) ->
    case Dest of 
        <<"e">> ->
            Opts2 = #{backend=>janus, record=>true, filename=>"/tmp/echo"},
            ok = nkmedia_session:answer_async(SessId, echo, Opts2);
        <<"fe">> ->
            {ok, _} = nkmedia_session:offer(SessId, sdp, #{offer=>Offer}),
            Opts2 = #{backend=>freeswitch},
            ok = nkmedia_session:answer_async(SessId, echo, Opts2);
        <<"m1">> ->
            {ok, _} = nkmedia_session:offer(SessId, sdp, #{offer=>Offer}),
            Opts2 = #{room=>"mcu1"},
            ok = nkmedia_session:answer_async(SessId, mcu, Opts2);
        <<"m2">> ->
            {ok, _} = nkmedia_session:offer(SessId, sdp, #{offer=>Offer}),
            Opts2 = #{room=>"mcu2"},
            ok = nkmedia_session:answer_async(SessId, mcu, Opts2);
        <<"p">> ->
            {ok, _} = nkmedia_session:offer(SessId, sdp, #{offer=>Offer}),
            ok = nkmedia_session:answer_async(SessId, publish, #{});
        <<"p2">> ->
            {ok, _} = nkmedia_session:offer(SessId, sdp, #{offer=>Offer}),
            Opts2 = #{room=>"room2"},
            ok = nkmedia_session:answer_async(SessId, publish, Opts2);
        <<"p2r">> ->
            {ok, _} = nkmedia_session:offer(SessId, sdp, #{offer=>Offer}),
            Opts2 = #{room=>"room2", record=>true, filename=>"p2", info=>p2},
            ok = nkmedia_session:answer_async(SessId, publish, Opts2);
        <<"d", Num/binary>> ->
            case find_user(Num) of
                {ok, Dest2} ->
                    {ok, _} = nkmedia_session:offer(SessId, sdp, #{offer=>Offer}),
                    Opts2 = #{backend=>p2p, dest=>Dest2},
                    ok = nkmedia_session:answer_async(SessId, invite, Opts2);
                not_found ->
                    {error, <<"User Not Found">>}
            end;
        <<"f", Num/binary>> ->
            case find_user(Num) of
                {ok, Dest2} ->
                    {ok, _} = nkmedia_session:offer(SessId, sdp, #{offer=>Offer}),
                    ok = nkmedia_session:answer_async(SessId, call, #{dest=>Dest2});
                not_found ->
                    {error, <<"User Not Found">>}
            end;
        <<"j", Num/binary>> ->
            case find_user(Num) of
                {ok, Dest2} ->
                    {ok, _} = nkmedia_session:offer(SessId, proxy, #{offer=>Offer}),
                    ok = nkmedia_session:answer_async(SessId, invite, #{dest=>Dest2});
                not_found ->
                    {error, <<"User Not Found">>}
            end;
        _ ->
            {error, <<"Unknown Destination">>}
    end.


find_user(User) ->
    case nkmedia_verto:find_user(User) of
        [Pid|_] ->
            {ok, {nkmedia_verto, Pid}};
        [] ->
            case nkmedia_janus_proto:find_user(User) of
                [Pid|_] ->
                    {ok, {nkmedia_janus_proto, Pid}};
                [] ->
                    not_found
            end
    end.


parse_listen(_Key, [{[{_, _, _, _}|_], Opts}|_]=Multi, _Ctx) when is_map(Opts) ->
    {ok, Multi};

parse_listen(webserver, Url, _Ctx) ->
    Opts = #{valid_schemes=>[http, https], resolve_type=>listen},
    case nkpacket:multi_resolve(Url, Opts) of
        {ok, List} -> {ok, List};
        _ -> error
    end.
