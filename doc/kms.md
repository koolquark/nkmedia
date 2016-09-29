# NkMEDIA External Interface

## Freeswitch Options

When the nkmedia_janus backend is selected (either manually, using the `backend: nkmedia_fs` option when creating the session or automatically, depending on the type), following session types are supported:

Type|Description
---|---|---
[park](#park)|_Parks_ the session (see bellow)
[echo](#echo)|Echoes audio and/or video
[mcu](#mcu)|Starts a mixing MCU for audio and video
[bridge](#bridge)|Connects two sessions

An unique characteristic of this backend is that any session, once started, can be updated to any other session type without starting a new SDP negotiation. This means that you can start a `park` session, and later on, _connect_ the same session to an _mcu_ or to another user's session (both must belong to the same Freeswitch instance).

### Park

You can use this session type to _place_ the session at the Freeswitch mediaserver, without yet sending audio or video, and before updating it to any other operation.

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

This session type echos any received audio or video.

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
		answer: {
			sdp: "v=0..."
		}
	},
	tid: 1
}
```


### MCU

This session type connects the session to a new or existing MCU conference at a Freeswitch instance.
The optional field `room_id` can be used to connect to an existing room, or creare a new one with this name.

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
		room_id: "41605362-3955-8f28-e371-38c9862f00d9",
		answer: {
			sdp: "v=0..."
		}
	},
	tid: 1
}
```

### Room updates

In the near future, you will be able to perform large number of updates over a session of type room. Currenly the only supported option is to change the layout of the mcu in real time:

**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "update",
	data: {
		update_type: "mcu_layout",
		room_id: "41605362-3955-8f28-e371-38c9862f00d9",
		mcu_layout: "2x2"
	}
	tid: 1
}
```


## Bridge

Allows to connect two sessions at the same Freeswitch instance. You typically start a first sesison and park it, an later on you start a second session and bridge them together.

The following options are supported:

Field|Description
---|---|---
peer|Mandatory, session id of the peer to bridge to.
park_after_bridge|See bellow (default false)

If the option `park_after_bridge` is set to _true_, the session will no be stopped if the bridged session stops. 

**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "start",
	data: {
		type: "bridge",
		peer: "5ff9d334-398c-108e-7e0d-38c9862f00d9"
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
		session_id: "343b5809-398c-12e2-21e2-38c9862f00d9",
		peer: "5ff9d334-398c-108e-7e0d-38c9862f00d9"
		answer: {
			sdp: "v=0..."
		}
	},
	tid: 1
}
```


# Session updates

Freeswitch backend allows existing sessions to be _updated_ to any other session type.
For example, a session started as _park_ or _echo_ could be updated into a _mcu room_:

**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "update",
	data: {
		type: "session_type",
		session_type: "mcu"
		room_id: "41605362-3955-8f28-e371-38c9862f00d9"
	}
	tid: 1
}
```
-->
```js
{
	result: "ok",
	data: {
		room_id: "41605362-3955-8f28-e371-38c9862f00d9",
		room_type: "video-mcu-stereo"
	},
	tid: 1
}
```





