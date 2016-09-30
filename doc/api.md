# NkMEDIA API External Interface

This documente describes the currently supported External API commands for core NkMEDIA. 
See the [API Introduction](intro.md) for an introduction to the interface, and [Core Events](events.md) for a description of available events.

* [**`create`**](#create): Creates a new media session
* [**`destroy`**](#destroy): Destroys an existing media session
* [**`set_answer`**](#set_answer): Sets the answer for a session
* [**`get_info`**](#get_info): Gets info about a session
* [**`get_list`**](#get_list): Gets the current list of sessions
* [**`get_offer`**](#get_offer): Gets the offer for a session
* [**`get_answer`**](#get_answer): Gets the answer for a session
* [**`get_proxy_offer`**](#get_proxy_offer): Gets the offer for a proxy session
* [**`update_media`**](#update_media): Updates media processing in a current session
* [**`set_type`**](#set_type): Updates the type of a current session
* [**`recorder_action`**](#recorder_action): Performs an action over the recorder
* [**`player_action`**](#player_action): Performs an action over the player
* [**`room_action`**](#room_action): Performs an action over the current room
* [**`set_candidate`**](#set_candidate): Sends a Trickle ICE candidate
* [**`set_candidate_end`**](#set_candidate_end): Signals that no more candidates are available


All commands must have 

```js
{
	class: "media",
	subclass: "session"
}
```

See also each backend and plugin documentation:

* [nkmedia_janus](janus.md)
* [nkmedia_fs](fs.md)
* [nkmedia_kms](kms.md)
* [nkmedia_room](room.md)
* [nkmedia_call](call.md)
* [nkmedia_sip](sip.md)
* [nkmedia_verto](verto.md)

Also, for Erlang developers, you can have a look at the command [syntax specification](../src/nkmedia_api_syntax.erl) and [command implementation](../src/nkmedia_api.erl).


## create

Performs the creation of a new media session. The mandatory `type` field defines the type of the session. Currently, the following types are supported, along with the necessary plugin or plugins that support them.

Type|Plugins
---|---|---
p2p|-
echo|[nkmedia_janus](janus.md#echo, fs.md#echo), [nkmedia_fs](fs.md#echo), [nkmedia_kms](kms.md#echo)
proxy|[nkmedia_janus](janus.md#proxy)
publish|[nkmedia_janus](janus.md#publish), [nkmedia_kms](kms.md#publish)
listen|[nkmedia_janus](janus.md#listen), [nkmedia_kms](kms.md#listen)
park|[nkmedia_fs](fs.md#park), [nkmedia_kms](kms.md#park)
mcu|[nkmedia_fs](fs.md#mcu)
bridge|[nkmedia_fs](fs.md#bridge), [nkmedia_kms](kms.md#bridge)

See each specific plugin documentation to learn about how to use it and supported options.

Common fields for the request are:

Field|Default|Description
---|---|---
type|(mandatory)|Session type
wait_reply|false|Wait for the offer or answer
offer|{}|Offer for the session, if available
no_offer_trickle_ice|false|Forces consolidation of offer candidates in SDP
no_answer_trickle_ice|false|Forces consolidation of answer candidates in SDP
trickle_ice_timeout|5000|Timeout for Trickle ICE before consolidating candidates
sdp_type|"webrtc"|Type of offer or answer SDP to generate (`webrtc` or `rtp`)
backend|(automatic)|Forces a specific backend for the request (`nkmedia_janus`, `nkmedia_fs` or `nkmedia_kms`)
master_id|(none)|Makes this session a _slave_ of this _master_ session (see bellow)
set_master_answer|false|If `true`, this _slave_ session will set its _answer_ to _master_
stop_after_peer|true|For _master_ or _slave_ sessions, stop if peer stops
wait_timeout|60|Timeout for sessions in _wait_ state
ready_timeout|86400|Timeout for sessions in _ready_ (_answer_ is already set) state
subscribe|true|Subscribe to session events. Use `false` to avoid automatic subscription.
event_body|{}|Body to receive in all automatic events.

If you use `wait_reply=true`, the backend will supply the _answer_ (in case you supplied an _offer_), or the _offer_ (if you don't supply one, you must then send the _answer_ to the backend). Otherwhise, you must use the `get_offer` or `get_answer` commands.

**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "create",
	data: {
		type: "echo",
		backend: "nkmedia_janus",
		wait_reply: true
		offer: {
			sdp: "v=0.."
		}
	}
	tid: 1
}
```
-->
```js
{
	result: "ok",
	data: {
		session_id: "54c1b637-36fb-70c2-8080-28f07603cda8",
		answer: {
			sdp: "v=0..."
		}
	},
	tid: 1
}
```

Depending on the session type and backend, other fields can be used. Please refer to each backend documentation, for example:


Field|Description
---|---
room_id|Room to use
publisher_id|Publisher to connect to
layout|MCU layout to use
loops|Loops to repeat in the player
uri|URI to use for the player
mute_audio|Mute the audio
mute_video|Mute the video
mute_data|Mute the data channel
bitrate|Bitrate to set

<br>

**Events**

When creating a session, the user connection is automatically subscribed to receive all events related to the session (unless `subscribe=false` is used).

**Master/Slave sessions**

When you start a session using a `master_id` key poiting to another existing session, this session will become a _slave_ of that _master_ session. This means:

* When any of the session stops, the other stops also (unless `stop_after_peer=false` is used).
* When the slave session gets an _answer_ it will be automatically set at the _master_ (if `set_master_answer=true`).
* ICE candidates are routed among sessions as needed automatically.


**Tricle ICE**

All _webrtc SDPs_ are supposed to have _ICE candidates_ inside by default. If the candidates are not included and _trickle ICE_ must be used, the `trickle_ice` parameter of the _offer_ or _answer_ must be set to `true`. Some backends will not use _trickle ICE_ (Freeswitch does not support it, and Janus only for the client side), others they will always use _tricle ICE_ (like Kurento). You can use the `no_offer_trickle_ice` and `no_answer_trickle_ice` parameters to force the consolidation of candidates in the server-generated SDP. NkMEDIA will then receive the candidates and insert them in the SDP before offering it to the client or the backend.


## destroy

Destroys a started session. 

Field|Default|Description
---|---|---|---
session_id|(mandatory)|Session Id


## set_answer

When the started session's type requires you to supply an _answer_ (because the backend already generated the _offer_), you must use this API to set the session's _answer_. 

Field|Default|Description
---|---|---
session_id|(mandatory)|Session Id
answer|(mandatory)|Answer for the session


**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "set_answer",
	data: {
		answer: {
			"sdp": "..."
		}
	}
	tid: 1
}
```
-->
```js
{
	result: "ok",
	tid: 1
}
```


## get_offer

Waits for the session _offer_ to be generated

**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "get_offer",
	tid: 1
}
```
-->
```js
{
	result: "ok",
	data: {
		offer: {
			"sdp": "..."
		}
	}
	tid: 1
}
```


## get_answer

Waits for the session _answer_ to be generated


## get_proxy_offer

For some `proxy` type sessions, this command allows you to get the _offer_ to be sent to the remote party. (See backend documentation).


## get_info

Gets extended information about a specific session

**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "get_info",
	data: {
		session_id: "54c1b637-36fb-70c2-8080-28f07603cda8"
	}
	tid: 1
}
```
-->
```js
{
	result: "ok",
	data: {
		backend: "nkmedia_fs",
	    type: "echo",
	    type_ext: {},
	    user_id: "user@domain.com",
	    user_session: "1f0fbffa-3919-6d40-03f5-38c9862f00d9",
	    ...
	},
	tid: 1
}
```




## get_list

Gets a list of all current sessions

**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "get_list",
	tid: 1
}
```
-->
```js
{
	result: "ok",
	data: [
		"54c1b637-36fb-70c2-8080-28f07603cda8"
	],
	tid: 1
}
```



## update_media

Some backends allow you to modify the media session characteristics in real time. 
See each backend documentation. Typical fields are:

Field|Sample|Description
---|---|---
mute_audio|false|Mute the audio
mute_video|false|Mute the video
mute_data|false|Mute the data channel
bitrate|0|Bitrate to use (kbps, 0 for unlimited)


**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "update_media",
	data: {
		session_id: "54c1b637-36fb-70c2-8080-28f07603cda8",
		mute_audio: true,
		bitrate: 100000
	}
	tid: 1
}
```


## set_type

Some backends allow to change the session type once started.
See each backend documentation. Fields `session_id` and `type` are mandatory.

**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "set_type",
	data: {
		session_id: "54c1b637-36fb-70c2-8080-28f07603cda8",
		type: "listen",
		publisher_id: "9dedf3cf-3da7-883c-6790-38c9862f00d9"
	}
	tid: 1
}
```



## recorder_action

Some backends allow to record the session. See each backend documentation. 

**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "recorder_action",
	data: {
		session_id: "54c1b637-36fb-70c2-8080-28f07603cda8",
		action: "start"
	}
	tid: 1
}
```


## player_action

Some backends allow to control a `play` session. See each backend documentation. 

**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "player_action",
	data: {
		session_id: "54c1b637-36fb-70c2-8080-28f07603cda8",
		action: "get_position"
	}
	tid: 1
}
```
-->
```js
{
	result: "ok",
	data: {
		position: 50000
	},
	tid: 1
}
```


## room_action

Some backends allow to control the room this session belongs to. See each backend documentation. 

**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "room_action",
	data: {
		session_id: "54c1b637-36fb-70c2-8080-28f07603cda8",
		action: "layout"
		data: {
			layout: "2x2"
		}
	}
	tid: 1
}
```


## set_candidate

When the client sends an SDP _offer_ or _answer_ without candidates (and with the field `trickle_ice=true`), it must use this command to send candidates to the backend. The following fields are mandatory:

Field|Sample|Description
---|---|---
session_id|-|Session id this candidate refers to
sdpMid|"audio"|Media id
sdpMLineIndex|0|Line index
candidate|"candidate..."|Current candidate


## set_candidate_end

When the client has no more candidates to send, it should use this command to inform the server.


