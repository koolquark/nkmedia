# NkMEDIA API External Interface - Events

This documente describes the currently supported External API events for core NkMEDIA. 
See the [API Introduction](intro.md) for an introduction to the interface and [API Commands](api.md) for a detailed description of available commands.

Many NkMEDIA operations launch events of different types. All API connections subscribed to these events will receive them. See NkSERVICE documentation for a description of how to subscribe and receive events.

See also each backend and plugin documentation:

* [nkmedia_janus](janus.md)
* [nkmedia_fs](fs.md)
* [nkmedia_kms](kms.md)
* [nkmedia_room](room.md)
* [nkmedia_call](call.md)
* [nkmedia_sip](sip.md)
* [nkmedia_verto](verto.md)

Also, for Erlang developers, you can have a look at the [event dispatcher](../src/nkmedia_api_events.erl).


The session subsystem generate the following event types:

Type|Body|Description
---|---|---
answer|{answer: ...}|Fired when a session has an answer available
stop|{code: Code, reason: Reason}|A session has stopped
updated_type|{type:Type, ...}|A session has been updated

**Sample**

```js
{
	class: "core",
	cmd: "event",
	data: {
		class: "media",
		subclass: "session",
		type: "stop",
		obj_id: "39ce4076-391a-1260-75db-38c9862f00d9",
		body: {
			code: 0,
			reason: "User stop"
		}
	},
	tid: 1
}
```



## Room events

The room subsystem generate the following event types:

Type|Body|Description
---|---|---
started|{class: Class, backend: Backend}|Fired when a new room is created
destroyed|{code: Code, reason: Reason}|A room has been destroyed
started_publisher|{session_id: SessId, user: User}|Fired when a new publisher joins an _sfu_ room
stopped_publisher|{session_id: SessId, user: User}|An existing publisher is leaving an _sfu_ room
started_listener|{session_id: SessId, user: User, peer: Peer}|Fired when a new listener joins an _sfu_ room, connected to a _peer_ publisher.
stopped_listener|{session_id: SessId, user: User}|An existing listener is leaving an _sfu_ room


**Sample**

```js
{
	class: "core",
	cmd: "event",
	data: {
		class: "media",
		subclass: "room",
		type: "started",
		obj_id: "11c92417-6c97-6f35-971b-2954afab410b",
		body: {
			class: "sfu",
			backend: "nkmedia_janus"
		}
	},
	tid: 1
}
```


## Call events

The call subsystem generate the following event types:

Type|Body|Description
---|---|---
ringing|{}|The call is ringing
answer|{answer: Answer}|The call has an answer
hangup|{code: Code, reason: Reason}|The call has been hangup

**Sample**

```js
{
	class: "core",
	cmd: "event",
	data: {
		class: "media",
		subclass: "call",
		type: "ringing",
		obj_id: "90076c74-391a-153c-f6c7-38c9862f00d9": {
	},
	tid: 1
}
```

