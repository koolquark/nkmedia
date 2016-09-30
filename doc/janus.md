# Janus Backend

This document describes the characteristics of the Janus backend

* [**Session Types**](#session-types)
	* [echo](#echo)
	* [proxy](#proxy) and SIP gateways
	* [publish](#publish)
	* [listen](#listen)
* [**Media update**](#media-update)
* [**Type update**]()
* [**Recording**]()


## Sessison Types

When the `nkmedia_janus` backend is selected (either manually, using the `backend: "nkmedia_janus"` option when creating the session or automatically, depending on the type), de following session types can be created:

### echo

Allows to create an echo session. The caller must include the _offer_ in the [session creation request](api.md#create), and NkMEDIA you must use [get_answer](api.md#get_answer) to get the answer (or use `wait_reply: true` in the request).

The [media updates](#media-update) can also be included in the creation request.

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

### proxy

Allows you to create a proxy session, a media session where all traffic goes through the server, allowing media updates and recording. You must create a _master_ session with an _offer_, call [get_proxy_offer](api.md#get_proxy_offer) to get the _proxy offer_, and use it to start a _slave_ session and call the remote party.

Once you have an answer from the remote party, you must use [set_answer](api.md#set_answer) to set the answer on the _slave_ session, and it will automatically connect to the _master_ session. You can now either wait for the answer event for the _master_ session of call [get_answer](api.md#get_answer) on it.

If any of the session stops, the other will also be destroyed automatically.

The [media updates](#media-update) can also be included in the creation request.

Samples TBD


**SIP Proxy**

You can make a SIP-to-WebRTC gateway using an offer with a _SIP-type_ SDP, and using `sdp_type: "rtp"` in it. The generate _master_ answer will also be SIP-like, ready to be sent to the calling SIP device.

To make a WebRTC-to-SIP gateway, you must use the option `sdp_type: "rtp"` in the session creation request. The _proxy offer_ you get will then be SIP-like. When the remote SIP party answers, you must call [set_answer](api.md#set_answer) as usual.

You cannot however use any media upates on a SIP proxy session.



## Publish

Allows you to _publish_ a session with audio/video to a _room_, working as an _SFU_ (selective forwarding unit). Any number of listeners can then connect to this session.

If you don't include a room, a new one will be created automatically (using options `room_audiocodec`, `room_videocodec` and `room_bitrate`). If you include a room, it must already exist.

The [media updates](#media-update) can also be included in the creation request.


Field|Default|Description
---|---|---
room_id|(automatic)|Room to use
room_audio_codec|`"opus"`|Audio codec to force (`opus`, `isac32`, `isac16`, `pcmu`, `pcma`)
room_video_codec|`"vp8"`|Video codec to force (`vp8`, `vp9`, `h264`)
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


## Listen

Allows you to _listen_ to a previously started publisher, working as an _SFU_ (selective forwarding unit). You must tell the _publisher id_, and the room will be found automatically.

You must not include any offer in the [session creation request](api.md#create), because Janus will make one for you. You must then supply an _answer_ calling the [set answer command](api.md#set_answer).


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



## Media update

This backend allows to you perform, at any moment and in all session types (except the SIP-related) the following [media updates](api.doc#update_media);

* mute_audio: Mute the outgoing audio.
* mute_video: Mute the outgoing video.
* mute_data: Mute the outgoing data channel.
* bitrate: Limit the incoming bandwidth

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

Then only [type update](api.md#update_type) that the Janus backend supports is changing a `listen` session type to another `listen` type pointing to a publisher on the same room.


**Sample**

```js
{
	class: "media",
	class: "session",
	cmd: "update_type",
	data: {
		session_id: "2052a043-3785-de87-581b-28f07603cda8",
		type: "listen"
		publisher: "29f394bf-3785-e5b1-bb56-28f07603cda8"
	}
	tid: 3
}
```







