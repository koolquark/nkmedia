# ROOM MSGLOG Plugin

MsgLog is a plugin for [NkMEDIA rooms](room.md). Once activated for a service, all started rooms will gain the capabilty of receiving _messages_, that are also stored and can be retrieved later.

Each received message will also generate an event for the room.

Like for nkmedia_room, all commands use class `media`, subclass `room`.

* [**Commands**](#commands)
  * [`msglog_send`](#msglog_send): Sends a new message to the room
  * [`msglog_get`](#msglog_get): Retrieves all messages
* [**Events**](#events)


# Commands

## msglog_send

Sends a message to the room. Any JSON object can be used as the message, using the field `msg`, and the following fields will be added:

Field|Value
---|---
msg_id|Server-generated message id (integer)
user_id|User that sent the message
session_id|User session id that sent the message
timestmap|Unix-time (microseconds)

The fields `room_id` and `msg` are mandatory.

**Sample**

```js
{
	class: "media",
	subclass: "room",
	cmd: "msglog_send",
	data: {
		room_id: "my_room_id",
		msg: {
			key1: "val1"
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
		msg_id: 1
	}
	tid: 1
}
```


## msglog_get

This command allows you to get the list of sent messages to the room. Only the field `room_id`is mandatory. 


**Sample**

```js
{
	class: "media",
	subclass: "room",
	cmd: "msglog_get",
	data: {
		room_id: "my_room_id"
	}
	tid: 2
}
```
-->
```js
{
	result: "ok",
	data: [
		{
			msg_id: 1,
			user_id: "user@domain",
			session_id: "c881cb76-3a2f-7353-a5fa-38c9862f00d9",
			timestmap: 1471359589983069,
			key1: "val1"
		}
	],
	tid: 2
}
```


# Events

All users registered to receive room events with type `msglog_new_msg` (or all events, what is the normal situation for room members) will receive the following event:

```js
{
	class: "core",
	cmd: "event",
	data: {
		class: "media",
		subclass: "room",
		type: "msglog_new_msg",
		obj_id: "my_room_id",
		body: #{
			msg_id: 1,
			user_id: "user@domain",
			session_id: "c881cb76-3a2f-7353-a5fa-38c9862f00d9",
			timestmap: 1471359589983069,
			key1: "val1"
		}
	}
	tid: 100
}
```
