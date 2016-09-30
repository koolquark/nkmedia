# Freeswitch Backend

* [**Session Types**](#session-types)
	* [park](#park)
	* [echo](#echo)
	* [bridge](#bridge)
	* [mcu](#mcu)
* [**Trickle ICE**](#tricke-ice)
* [**SIP**](#sip)
* [**Media update**](#media-update)
* [**Type update**](#type-update)
* [**Recording**](#recording)
* [**Room Management**](#room-management)


## Session Types

When the `nkmedia_fs` backend is selected (either manually, using the `backend: "nkmedia_fs"` option when creating the session or automatically, depending on the type), the session types described bellow can be created. Freeswitch allows two modes for all types: as an _offerer_ or as an _offeree_. 

As an **offerer**, you create the session without an _offer_, and instruct Freeswith to make one either calling [get_offer](api.md#get_offer) or using `wait_reply: true` in the [session creation](api.md#create) request. Once you have the _answer_, you must call [set_answer](api.md#set_answer) to complete the session.

As an **offeree**, you create the session with an offer, and you get the answer from Freeswitch either calling [get_answer](api.md#get_offer) or using `wait_reply: true` in the session creation request.



## park

You can use this session type to _place_ the session at the Freeswitch mediaserver, without yet sending audio or video, and before updating it to any other type.

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

Allows to connect two different Freeswitch sessions together. If you use the `master_id: ...` parameter in the session creation request, this session will be set as _slave_ of the other session (see [Core API](api.md#create)). Otherwise, you must use the `peer_id: ...` parameter with the _session id_ of the peer to connect to.

**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "create",
	data: {
		type: "bridge",
		master_id: "54c1b637-36fb-70c2-8080-28f07603cda8",
		offer: {
			sdp: "v=0.."
		},
		wait_reply: true
	}
	tid: 1
}
```


## mcu

This session type connects the session to a new or existing MCU conference at a Freeswitch instance.
The optional field `room_id` can be used to connect to an existing room, or create a new one with this name.

**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "start",
	data: {
		type: "mcu",
		room_id: "41605362-3955-8f28-e371-38c9862f00d9",
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
		room_id: "41605362-3955-8f28-e371-38c9862f00d9",
		answer: {
			sdp: "v=0..."
		}
	},
	tid: 1
}
```

See [Room Management](#room-management) to learn about operations that can be performed on the room.


## Trickle ICE

Freeswitch has currenly no support for _trickle ICE_, however NkMEDIA is able to _emulate_ it. If you want to use it when sending offfers or answers to the backend, you must use the field `trickle_ice: true`. You can now use the commands [api.md#set_candidate] and [api.md#set_candidate_end] to send candidates to the backend. NkMEDIA will buffer the candidates and, when either you call `set_candidate_end` or the `trickle_ice_timeout` is fired, all of them will be incorporated in the SDP and sent to Freeswitch.

When Freesewitch generates an offer or answer, it will never use _trickle ICE_.



## SIP

The Freeswitch backend has full support for SIP.

If the offer you send in has a SIP-like SDP, you must also include the option `sdp_type: "rtp"` on it. The generated answer will also be SIP compatible. If you want Freeswitch to generate a SIP offer, use the `sdp_type: "rtp"` parameter in the session creation request. Your answer must also be then SIP compatible.



## Media update

TBD


## Type udpdate 

Freeswitch allows you to change the session to type to any other type at any moment, calling [set_type](api.md#set_type).
You can for example first `park` a call, then include it on a `bridge` or an `mcu`.


## Recording

TBD



## Room management

In the near future, you will be able to perform several updates over any MCU, calling [room_action](api.md#room_action). Currenly the only supported option is to change the layout of the mcu in real time:

**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "room_action",
	data: {
		action: "layout"
		room_id: "41605362-3955-8f28-e371-38c9862f00d9",
		layout: "2x2"
	}
	tid: 1
}
```
