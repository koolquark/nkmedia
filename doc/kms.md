# Kurento Backend

* [**Session Types**](#session-types)
	* [park](#park)
	* [echo](#echo)
	* [bridge](#bridge)
	* [publish](#publish)
	* [listen](#listen)
	* [play](#play)
* [**Trickle ICE**](#trickle-ice)
* [**SIP**](#sip)
* [**Media update**](#media-update)
* [**Type update**](#type-update)
* [**Recording**](#recording)
* [**Calls**](#calls)


## Session Types

When the `nkmedia_kms` backend is selected (either manually, using the `backend: "nkmedia_kms"` option when creating the session or automatically, depending on the type), the session types described bellow can be created. Kurento allows two modes for all types: as an _offerer_ or as an _offeree_. 

As an **offerer**, you create the session without an _offer_, and instruct Kurento to make one either calling [get_offer](api.md#get_offer) or using `wait_reply: true` in the [session creation](api.md#create) request. Once you have the _answer_, you must call [set_answer](api.md#set_answer) to complete the session.

As an **offeree**, you create the session with an offer, and you get the answer from Kurento either calling [get_answer](api.md#get_offer) or using `wait_reply: true` in the session creation request.



## park

You can use this session type to _place_ the session at the Kurento mediaserver, without yet sending audio or video, and before updating it to any other type.

The available [media updates](#media-update) can also be included in the creation request.

**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "start",
	data: {
		type: "park",
		offer: {
			sdp: "v=0.."
		},
		wait_reply: true
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


## echo

Allows to create an _echo_ session, sending the audio and video back to the caller. 

**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "create",
	data: {
		type: "echo",
		offer: {
			sdp: "v=0.."
		},
		wait_reply: true
	}
	tid: 1
}
```


## bridge

Allows to connect two different Kurento sessions together. 

Once you have a session of any type, you can start (or switch) any other session and bridge it to the first one through the server. You need to use type _bridge_ and include the field `peer_id` pointing to the first one.

It is recommended to use the field `master_id` in the new second session, so that it becomes a _slave_ of the first, _master_ session. This way, if either sessions stops, the other will also stop automatically.

The available [media updates](#media-update) can also be included in the creation request.

**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "create",
	data: {
		type: "bridge",
		peer_id: "54c1b637-36fb-70c2-8080-28f07603cda8",
		master_id: "54c1b637-36fb-70c2-8080-28f07603cda8",
		offer: {
			sdp: "v=0.."
		},
		wait_reply: true
	}
	tid: 1
}
```


## publish

Allows you to _publish_ a session with audio/video/data to a _room_, working as an _SFU_ (_selective forwarding unit_). Any number of listeners can then be connected to this session.

If you don't include a room, a new one will be created automatically. If you include a room, it must already exist.

The available [media updates](#media-update) can also be included in the creation request.


**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "create",
	data: {
		type: "publish",
		offer: {
			sdp: "v=0.."
		},
		wait_reply: true
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
		room: "bbd48487-3783-f511-ee41-28f07603cda8",
		answer: {
			sdp: "v=0..."
		}
	},
	tid: 1
}
```


## listen

Allows you to _listen_ to a previously started publisher, working as an _SFU_ (selective forwarding unit). You must tell the `publisher_id`, and the room will be found automatically.


**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "create",
	data: {
		type: "listen",
		publisher_id: "54c1b637-36fb-70c2-8080-28f07603cda8",
		offer: {
			sdp: "v=0..."
		},
		wait_reply: true
	}
	tid: 1
}
```
-->
```js
{
	result: "ok",
	data: {
		session_id: "2052a043-3785-de87-581b-28f07603cda8",
		offer: {
			answer: "v=0..."
		}
	},
	tid: 1
}
```


## play

Allows you to reproduce any audio/video file over the session. The file must be encoded using _WEBM_ or _MP4_.
The _uri_ must point to a local or remote file, using _http_.

The available [media updates](#media-update) can also be included in the creation request.

**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "create",
	data: {
		type: "play",
		uri: "http://files.kurento.org/video/format/sintel.webm",
		offer: {
			sdp: "v=0.."
		},
		wait_reply: true
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

You can now manage the player using the [player_action](api.md#player_action) command. The available actions are:

Action|Description
---|---
pause|Pauses the reproduction
resume|Resumes the reproduction
get_info|Gets info about the file, length and if seekable.
get_position|Gets current position
set_position|Jumps to a specific position (use `position: ...`)



## Trickle ICE

When sending an offer or answer to the backend, it can include all candidates in the SDP or you can use _trickle ICE_. In this case, you must not include the candidates in the SDP, but use the field `trickle_ice: true`. You can now use the commands [set_candidate](api.md#set_candidate) and [set_candidate_end](api.md#set_candidate_end) to send candidates to the backend.

When Kurento generates and offer or an answer, it will always use _trickle ICE_ by default. You can get the offered candidates listening to the [candidate](events.md) and [candidate_end](events.md) events.

If you do not want to support _trickle ICE_ you can use the options `no_offer_trickle_ice` and `no_answer_trickle_ice` in the session creation request. NkMEDIA will then buffer all candidates from Kurento, an when either Kurento sends the last candidate event or the `trickle_ice_timeout` is fired, all of them will be incorporated in the SDP and offered to you, as if it were generated from Kurento without trickle.


## SIP

The Kurento backend has full support for SIP.

If the offer you send in has a SIP-like SDP, you must also include the option `sdp_type: "rtp"` on it. The generated answer will also be SIP compatible. If you want Kurento to generate a SIP offer, use the `sdp_type: "rtp"` parameter in the session creation request. Your answer must also be then SIP compatible.



## Media update

This backend allows to you perform, at any moment and in all session types, the following [media updates](api.md#update_media):

* `mute_audio`: Mute the outgoing audio.
* `mute_video`: Mute the outgoing video.
* `mute_data`: Mute the outgoing data channel.
* `bitrate`: Limit the incoming bandwidth (TBD)

**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "update_media",
	data: {
		mute_audio: true,
		bitrate: 100000
	}
	tid: 1
}
```


## Type udpdate 

Kurento allows you to change the session to type to any other type at any moment, calling [set_type](api.md#set_type).
You can for example first `park` a call, then include it on a `bridge`, then perform a `play`.


## Recording

Kurento offers a very sophisticated session recording mechanism.

At any moment, and in all session types, you can order to start or stop recording of the session, using the [recorder_action](api.md#recorder_action) command.

To start recording, use the `start` action. You can also use `stop`, `pause` and `resume` actions.


**Sample**

```js
{
	class: "media",
	class: "session",
	cmd: "recorder_action",
	data: {
		session_id: "2052a043-3785-de87-581b-28f07603cda8",
		action: start
	}
	tid: 1
}
```

TBD: how to access the file

## Calls

When using the [call plugin](call.md) with this backend, the _caller_ session will be of type `park`, and the _callee_ session will have type `bridge`, connected to the first. You will get the answer for the callee inmediately.

You can start several parallel destinations, and each of them is a fully independent session. 

You can receive and send calls to SIP endpoints.




