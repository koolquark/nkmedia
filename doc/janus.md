# Janus Backend

This document describes the characteristics of the Janus backend

* [**Session Types**](#session-types)
	* [echo](#echo)
	* [bridge](#bridge) and [sip](#sip) gateways
	* [publish](#publish)
	* [listen](#listen)
* [**Trickle ICE**](#trickle-ice)
* [**Media update**](#media-update)
* [**Type update**](#type-update)
* [**Recording**](#recording)
* [**Calls*](#calls)


## Session Types

When the `nkmedia_janus` backend is selected (either manually, using the `backend: "nkmedia_janus"` option when creating the session or automatically, depending on the type), the following session types can be created:

## echo

Allows to create an _echo_ session, sending the audio and video back to the caller. The caller must include the _offer_ in the [session creation request](api.md#create), and you must use [get_answer](api.md#get_answer) to get the answer (or use `wait_reply: true` in the request).

The available [media updates](#media-update) can also be included in the creation request.

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
		wait_reply: true,
		mute_audio: true
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

## **bridge**

Allows you to connect a pair of sessions throgh the server, managing medias, bandwidth and recording.

Because of the way Janus works, you must first creata a session with type _proxy_ with the _offer_ from the _caller_. You must then start a second session for the callee, now with type `bridge`, without any offer, but including the field `peer_id` pointing to the first session. 

You must then get the offer for the second session (calling [get_offer](api.md#get_offer)), and send it to the _callee_. When you have the callee answer (or hangup) you must send it to the slave session (calling [set_answer](api.md#set_answer)). The first session (type _proxy_) will then generate the answer for the caller, and will chnage itself to type _bridge_ also. You can now either wait for the answer event for the first session or call [get_answer](api.md#get_answer) on it.

The available [media updates](#media-update) can also be included in the creation request.

It is recommended to use the field `master_id` in the second (bridge) session, so that it becomes a _slave_ of the first, _master_ session. This way, if either sessions stops, the other will also stop automatically.


Samples TBD


### SIP

The proxy-bridge combo is also capable of connect SIP and WebRTC sessions together. 

You can make a SIP-to-WebRTC gateway using an offer with a _SIP-type_ SDP, and using `sdp_type: "rtp"` in it. The generated _master_ answer will also be SIP-like, ready to be sent to the calling SIP device.

To make a WebRTC-to-SIP gateway, you must use the option `sdp_type: "rtp"` in the session creation request. The _proxy offer_ you get will then be SIP-like. When the remote SIP party answers, you must call [set_answer](api.md#set_answer) as usual.

You cannot however use any media upates on a SIP proxy session.

See the [call plugin](call.md) to be able to use NkMEDIA's SIP signalling.


## publish

Allows you to _publish_ a session with audio/video/data to a _room_, working as an _SFU_ (_selective forwarding unit_). Any number of listeners can then be connected to this session.

If you don't include a room, a new one will be created automatically (using options `room_audiocodec`, `room_videocodec` and `room_bitrate`). If you include a room, it must already exist.

The available [media updates](#media-update) can also be included in the creation request.


Field|Default|Description
---|---|---
room_id|(automatic)|Room to use
room_audio_codec|`"opus"`|Forces audio codec (`opus`, `isac32`, `isac16`, `pcmu`, `pcma`)
room_video_codec|`"vp8"`|Forces video codec (`vp8`, `vp9`, `h264`)
room_bitrate|`0`|Bitrate for the room (kbps, 0:unlimited)

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
		wait_reply: true,
		room_video_codec: "vp9"
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

Allows you to _listen_ to a previously started publisher, working as an _SFU_ (selective forwarding unit). You must tell the `publisher id` and the room will be found automatically.

You must not include any offer in the [session creation request](api.md#create), because Janus will make one for you. You must then supply an _answer_ calling the [set answer](api.md#set_answer) command.


**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "create",
	data: {
		type: "listen",
		publisher_id: "54c1b637-36fb-70c2-8080-28f07603cda8",
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
			sdp: "v=0..."
		}
	},
	tid: 1
}
```

You must now set the answer:

```js
{
	class: "media",
	subclass: "session",
	cmd: "set_answer",
	data: {
		session_id: "2052a043-3785-de87-581b-28f07603cda8",
		answer: {
			sdp: "v=0..."
		}
	}
	tid: 2
}
```
-->
```js
{
	result: "ok",
	tid: 2
}
```

## Trickle ICE

When sending an offer or answer to the backend, it can include all candidates in the SDP or you can use _trickle ICE_. In this case, you must not include the candidates in the SDP, but use the field `trickle_ice: true`. You can now use the commands [set_candidate](api.md#set_candidate) and [set_candidate_end](api.md#set_candidate_end) to send candidates to the backend.

When Janus generates an offer or answer, it will never use _trickle ICE_.



## Media update

This backend allows to you perform, at any moment and in all session types (except SIP `proxy`) the following [media updates](api.md#update_media):

* `mute_audio`: Mute the outgoing audio.
* `mute_video`: Mute the outgoing video.
* `mute_data`: Mute the outgoing data channel.
* `bitrate`: Limit the incoming bandwidth

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

Then only [type update](api.md#set_type) that the Janus backend supports is changing a `listen` session type to another `listen` type, but pointing to a publisher on the same room.


**Sample**

```js
{
	class: "media",
	class: "session",
	cmd: "set_type",
	data: {
		session_id: "2052a043-3785-de87-581b-28f07603cda8",
		type: "listen"
		publisher: "29f394bf-3785-e5b1-bb56-28f07603cda8"
	}
	tid: 1
}
```


## Recording

At any moment, and in all session types (except SIP `proxy`) you can order to start or stop recording of the session, using the [recorder_action](api.md#recorder_action) command.

To start recording, use the `start` action.


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

To stop recording, use the `stop` action.

TBD: how to access the file


## Calls

When using the [call plugin](call.md) with this backend, the _caller_ session will be of type `proxy`, and the _callee_ session will have type `bridge`, connected to the first.

You can start several parallel destinations but, since all of them will share the same _offer_, you should only use the offer once your _acccept_ has been accepted.

You can receive and send calls to SIP endpoints.










