
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

-export([listener/2, listener2/1, play/2, play2/1, mcu2publish/0]).
-export([plugin_deps/0, plugin_start/2, plugin_stop/2,
         plugin_syntax/0, plugin_listen/2]).

-export([nkmedia_verto_login/3, nkmedia_verto_invite/4, nkmedia_verto_bye/2,
         verto_client_fun/2]).
% -export([nkmedia_call_resolve/2]).
-export([nkmedia_janus_call/3]).
-export([nkmedia_sip_call/2]).
% -export([nkmedia_call_event/3, nkmedia_session_event/3]).
-export([sip_route/5, sip_register/2]).

-include("nkmedia.hrl").

-define(LOG_SAMPLE(Type, Txt, Args, State),
    lager:Type("Sample (~s) "++Txt, [maps:get(user, State) | Args])).



%% ===================================================================
%% Public
%% ===================================================================


start() ->
    _CertDir = code:priv_dir(nkpacket),
    Spec = #{
        callback => ?MODULE,
        web_server => "https:all:8081",
        web_server_path => "./priv/www",
        verto_listen => "verto:all:8082",
        verto_proxy => "verto_proxy:all:8083",
        janus_listen => "janus:all:8989", 
        janus_proxy=> "janus_proxy:all:8990",
        kurento_proxy => "kms:all:8433",
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
    case nkmedia_session:get_status_opts(Sess) of
        {ok, _, {publish, #{room:=Room}}, _} ->
            {ok, SessId, _Pid} = nkmedia_session:start(sample, #{}),
            {ok, _} = nkmedia_session:offer(SessId, listen, 
                                            #{room=>Room, publisher=>Sess}),
            case Dest of
                {invite, User} ->
                    case find_user(User) of
                        {webrtc, Inv} ->
                            {ok, _} = nkmedia_session:answer(SessId, invite, 
                                                             #{dest=>Inv}),
                            {ok, SessId};
                        not_found ->
                            nkmedia_session:stop(SessId),
                            {error, user_not_found}
                    end;
                {room, Room2} ->
                    nkmedia_session:answer(SessId, publish, #{room=>Room2}),
                    {ok, SessId};
                {mcu, Room2} ->
                    nkmedia_session:answer(SessId, mcu, #{room=>Room2}),
                    {ok, SessId}
            end;
        _ ->
            {error, invalid_session}
    end.


mcu2publish() ->
    {ok, S, _} = nkmedia_session:start(sample, #{}),
    {ok, _} = nkmedia_session:offer(S, park, #{}),
    {ok, _} = nkmedia_session:answer(S, publish, #{}),
    S.



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
        nkmedia_sip,  nksip_registrar, nksip_trace,
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


nkmedia_verto_invite(SrvId, _CallId, Offer, Verto) ->
    case send_call(SrvId, Offer) of
        {ok, SessId} ->
            {ok, SessId, Verto};
        {answer, Answer, SessId} ->
            {answer, Answer, SessId, Verto};
        {rejected, Reason} ->
            {rejected, Reason, Verto}
    end.


nkmedia_verto_bye(SessId, Verto) ->
    lager:info("Verto BYE for ~s", [SessId]),
    nkmedia_session:stop(SessId, verto_bye),
    {ok, Verto}.



verto_client_fun({req, Class, <<"event">>, Data, _TId}, UserData) ->
    #{<<"type">>:=Type, <<"sub">>:=Sub, <<"obj_id">>:=ObjId} = Data,
    Body = maps:get(<<"body">>, Data, #{}),
    lager:notice("Api Verto event ~s:~s:~s:~p: ~p", [Class, Type, Sub, ObjId, Body]),
    {ok, #{}, UserData};

verto_client_fun(Msg, UserData) ->
    lager:notice("T1: ~p", [Msg]),
    {error, not_implemented, UserData}.



%% ===================================================================
%% nkmedia_janus_proto callbacks
%% ===================================================================


nkmedia_janus_call(SessId, Offer, Janus) ->
    case send_call(SessId, Offer) of
        ok ->
            {ok, Janus};
        {error, Error} ->
            {rejected, Error, Janus}
    end.



%% ===================================================================
%% nkmedia_sip callbacks
%% ===================================================================


nkmedia_sip_call(SessId, #{dest:=Dest}=Offer) ->
    [User, _Domain] = binary:split(Dest, <<"@">>),
    case send_call(SessId, Offer#{dest:=User}) of
        ok ->
            ok;
        {error, Error} ->
            {rejected, Error}
    end.




%% ===================================================================
%% nkmedia call callbacks
%% ===================================================================



% %% @private
% nkmedia_call_invite(_CallId, Offer, {verto, Pid}, #{srv_id:=SrvId}=Call) ->
%     case nkmedia_verto:invite()




%     case nksip_registrar:find(SrvId, sip, Dest, <<"nkmedia_sample">>) of
%         [] ->
%             lager:info("sip not found: ~s", [Dest]),
%             continue;
%         [Uri|_] ->
%             lager:info("sip found: ~s", [Dest]),
%             Spec = [#{dest=>{nkmedia_sip, Uri, #{}}, sdp_type=>rtp}],
%             {ok, Spec, Call}
%     end.
            


%% ===================================================================
%% sip_callbacks
%% ===================================================================


% sip_route(_Scheme, _User, <<"192.168.0.100">>, _Req, _Call) ->
%     proxy;

sip_route(_Scheme, _User, _Domain, _Req, _Call) ->
    lager:warning("User: ~p, Domain: ~p", [_User, _Domain]),
    process.


sip_register(Req, Call) ->
    Req2 = nksip_registrar_util:force_domain(Req, <<"nkmedia_sample">>),
    {continue, [Req2, Call]}.







%% ===================================================================
%% Internal
%% ===================================================================

send_call(SrvId, #{dest:=Dest}=Offer) ->
    case Dest of 
        <<"e">> ->
            Config = #{
                offer => Offer, 
                backend => janus, 
                record => true, 
                filename => "/tmp/echo"
            },
            {ok, SessId, #{answer:=Answer}} = nkmedia_session:start(SrvId, echo, Config),
            {answer, Answer, SessId};
        <<"fe">> ->
            Config = #{offer=>Offer, backend=>freeswitch},
            {ok, SessId, #{answer:=Answer}} = nkmedia_session:start(SrvId, echo, Config),
            {ok, Answer} = nkmedia_session:get_answer(SessId),
            {answer, Answer, SessId};
        <<"m1">> ->
            Config = #{offer=>Offer, room=>"mcu1"},
            {ok, SessId, #{answer:=Answer}} = nkmedia_session:start(SrvId, mcu, Config),
            {ok, Answer} = nkmedia_session:get_answer(SessId),
            {answer, Answer, SessId};
        <<"m2">> ->
            Config = #{offer=>Offer, room=>"mcu2"},
            {ok, SessId, #{answer:=Answer}} = nkmedia_session:start(SrvId, mcu, Config),
            {ok, Answer} = nkmedia_session:get_answer(SessId),
            {answer, Answer, SessId};
        <<"p1">> ->
            Config = #{
                offer => Offer, 
                room => "sfu1", 
                record => true
            },
            {ok, SessId} = nkmedia_session:start(SrvId, publish, Config),
            {ok, Answer} = nkmedia_session:get_answer(SessId),
            {answer, Answer, SessId};
        <<"d", Num/binary>> ->
            case find_user(Num) of
                {webrtc, Dest2} ->
                    Config = #{offer=>Offer},
                    {ok, SessId, #{}} = nkmedia_session:start(SrvId, p2p, Config),
                    {ok, _CallId} = nkmedia_call:start(SessId, Dest2, #{}),
                    {ok, SessId};
                not_found ->
                    {rejected, user_not_found}
            end;
        <<"j", Num/binary>> ->
            case find_user(Num) of
                {webrtc, Dest2} ->
                    Config = #{offer=>Offer},
                    {ok, SessId, #{}} = nkmedia_session:start(SrvId, proxy, Config),
                    {ok, _CallId} = nkmedia_call:start(SessId, Dest2, #{}),
                    {ok, SessId};
                {rtp, Dest2} ->
                    Config = #{offer=>Offer, proxy_type=>rtp},
                    {ok, SessId, #{}} = nkmedia_session:start(SrvId, proxy, Config),
                    {ok, _CallId} = nkmedia_call:start(SessId, Dest2, #{}),
                    {ok, SessId};
                not_found ->
                    {rejected, user_not_found}
            end;
        <<"f", Num/binary>> ->
            case find_user(Num) of
                {webrtc, Dest2} ->
                    {ok, SessIdA, #{answer:=Answer}} = 
                        nkmedia_session:start(SrvId, park, #{offer=>Offer}),
                    {ok, SessIdB, #{offer:=_}} = 
                        nkmedia_session:start(SrvId, park, #{bridge_to=>SessIdA}),
                    {ok, _CallId} = nkmedia_call:start(SessIdB, Dest2, #{}),
                    {answer, Answer, SessIdA};
                {rtp, Dest2} ->
                    {ok, SessIdA, #{answer:=Answer}} = 
                        nkmedia_session:start(SrvId, park, #{offer=>Offer}),
                    {ok, SessIdB, #{offer:=_}} = 
                        nkmedia_session:start(SrvId, park, 
                                              #{sdp_type=>rtp, bridge_to=>SessIdA}),
                    {ok, _CallId} = nkmedia_call:start(SessIdB, Dest2, #{}),
                    {answer, Answer, SessIdA};
                not_found ->
                    {rejected, user_not_found}
            end;
        _ ->
            {error, no_destination}
    end.


find_user(User) ->
    case nkmedia_verto:find_user(User) of
        [Pid|_] ->
            {webrtc, {nkmedia_verto, Pid}};
        [] ->
            case nkmedia_janus_proto:find_user(User) of
                [Pid|_] ->
                    {webrtc, {nkmedia_janus_proto, Pid}};
                [] ->
                    case 
                        nkmedia_sip:find_registered(sample, User, <<"nkmedia_sample">>) 
                    of
                        [Uri|_] -> 
                            {rtp, {nkmedia_sip, Uri, #{}}};
                            []  -> not_found
                    end
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
