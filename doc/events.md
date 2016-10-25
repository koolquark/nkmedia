# NkMEDIA API External Interface - Events

This documente describes the currently supported External API events for core NkMEDIA. 
See the [API Introduction](intro.md) for an introduction to the interface and [API Commands](api.md) for a detailed description of available commands.

Many NkMEDIA operations launch events of different types. All API connections subscribed to these events will receive them. See NkSERVICE documentation for a description of how to subscribe and receive events.

See also each backend and plugin documentation:

* [nkmedia_janus](janus.md)
* [nkmedia_fs](fs.md)
* [nkmedia_kms](kms.md)
* [nkmedia_room](room.md)
* [nkcollab_call](call.md)
* [nkmedia_sip](sip.md)
* [nkmedia_verto](verto.md)

Also, for Erlang developers, you can have a look at the [event dispatcher](../src/nkmedia_api_events.erl).

All events have the following structure:

```js
{
	class: "core",
	cmd: "event",
	data: {
		class: "media",
		subclass: "session",
		type: "...",
		obj_id: "...",
		body: {
			...
		}
	},
	tid: 1
}
```
Then `obj_id` will be the _session id_ of the session generating the event. The following _types_ are supported:


Type|Body|Description
---|---|---
answer|`{answer: ...}`|Fired when a session has an answer available
type|{`type: ..., ...}`|The session type has been updated
candidate|`{sdpMid: .., sdpMLineIndex: ..., candidate: ...}`|A new _trickle ICE_ candidate is available
candidate_end|`{}`|No more _trickle ICE_ candidates arte available
status|`{...}`|Some session-specific status is fired
info|`{...}`|Some user-specific event is fired
destroyed|`{code: Code, reason: Reason}`|The session has been stopped


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
