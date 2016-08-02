# NkMEDIA External Interface

## Freeswitch Options

When the nkmedia_janus backend is selected (either manually, using the `backend: nkmedia_fs` option when creating the session or automatically, depending on the type), de following types are supported:

Type|Description
---|---|---
[park](#park)|_Parks_ the session (see bellow)
[echo](#echo)|Echoes audio and/or video, managing bandwitch and recording
[mcu](#mcu)|Starts a mixing MCU for audio and video
[bridge](#bridge)|Connects two sessions

An unique characteristic of this backend is that any session, once started, can be updated to any other session type without starting a new SDP negotiation. This means that you can start a `park` session, and later on, _connect_ the caller to an _mcu_ or to another session.



### Park

You can use this session type to _place_ the session at the Freeswitch mediaserver, without sending audio or video, and before connecting it to any other operation.

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



### Echo

This session type echos any audio or video received.


**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "start",
	data: {
		type: "echo",
		backend: "nkmedia_fs",
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
		offer: {
			sdp: "v=0..."
		}
	},
	tid: 1
}
```

### MCU

This session 


**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "start",
	data: {
		type: "echo",
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
		offer: {
			sdp: "v=0..."
		}
	},
	tid: 1
}
```
