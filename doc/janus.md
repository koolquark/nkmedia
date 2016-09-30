# Janus Backend

This document describes the characteristics of the Janus backend

* [**Session Types**](#session-types)
	* [echo](#echo)
	* [proxy](#proxy) and [sip](#sip) gateways
	* [publish](#publish)
	* [listen](#listen)
* [**Trickle ICE**](#tricke-ice)
* [**Media update**](#media-update)
* [**Type update**](#type-update)
* [**Recording**](#recording)


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

## **proxy**

Allows you to create a _proxy_ session, a media session where all traffic goes through the server, allowing media updates and recording. 

You must create a _master_ session with an _offer_, call [get_proxy_offer](api.md#get_proxy_offer) to get the _proxy offer_, and use it to start a _slave_ session and call the remote party.

Once you have an answer from the remote party, you must use [set_answer](api.md#set_answer) to set the answer on the _slave_ session, and it will automatically connect to the _master_ session. You can now either wait for the answer event for the _master_ session or call [get_answer](api.md#get_answer) on it.

If any of the session stops, the other will also be destroyed automatically.

The available [media updates](#media-update) can also be included in the creation request.

Samples TBD


### SIP

You can make a SIP-to-WebRTC gateway using an offer with a _SIP-type_ SDP, and using `sdp_type: "rtp"` in it. The generated _master_ answer will also be SIP-like, ready to be sent to the calling SIP device.

To make a WebRTC-to-SIP gateway, you must use the option `sdp_type: "rtp"` in the session creation request. The _proxy offer_ you get will then be SIP-like. When the remote SIP party answers, you must call [set_answer](api.md#set_answer) as usual.

You cannot however use any media upates on a SIP proxy session.



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

Allows you to _listen_ to a previously started publisher, working as an _SFU_ (selective forwarding unit). You must tell the _publisher id_, and the room will be found automatically.

You must not include any offer in the [session creation request](api.md#create), because Janus will make one for you. You must then supply an _answer_ calling the [set answer](api.md#set_answer) command.


Field|Default|Description
---|---|---
publisher_id|(mandatory)|Publisher to listen to


**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "crate",
	data: {
		type: "listen",
		publisher: "54c1b637-36fb-70c2-8080-28f07603cda8",
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

When sending an offer or answer to the backend, it can include all candidates in the SDP or you can use _trickle ICE_. In this case, you must not include the candidates in the SDP, but use the field `trickle_ice: true`. You can now use the commands [api.md#set_candidate] and [api.md#set_candidate_end] to send candidates to the backend.

When Janus generates an offer or answer, it will never use _trickle ICE_.



## Media update

This backend allows to you perform, at any moment and in all session types (except SIP `proxy`) the following [media updates](api.doc#update_media):

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








