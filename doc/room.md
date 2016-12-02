# Room Plugin

This documente describes the currently supported External API commands for the ROOM plugin
See the [API Introduction](intro.md) for an introduction to the interface, and [Core Events](events.md) for a description of available events.

* [**Commands**](#commands)
	* [`create`](#create): Creates a new media room
	* [`destroy`](#destroy): Destroys an existing room
	* [`get_status`](#get_status): Gets status about a session
	* [`get_info`](#get_info): Gets info about a room
	* [`get_list`](#get_list): Gets the current list of rooms
* [**Events**](#events)


All commands must have 

```js
{
	class: "media",
	subclass: "room"
}
```

See also each backend and plugin documentation:

* [nkmedia_janus](janus.md)
* [nkmedia_fs](fs.md)
* [nkmedia_kms](kms.md)

Also, for Erlang developers, you can have a look at the command [syntax specification](../src/nkmedia_room_api_syntax.erl) and [command implementation](../src/nkmedia_room_api.erl).

# Commands


## create

Performs the creation of a new room. The mandatory `class` field defines the class of the room. 

Common fields for the request are:

Field|Default|Description
---|---|---
class|(mandatory)|Room type (sfu or mcu)
backend|(automatic)|Backend to use
timeout|86400|Room timeout when it has no participants (secs)
audio_code|opus|opus, isac32, isac16, pcmu, pcma
video_codec|vp8|vp8, vp9, h264

See each specific plugin documentation to learn about how to use it and supported options.


## destroy

Destroys a started room. 

Field|Default|Description
---|---|---|---
room_id|(mandatory)|Room Id


## get_info

Gets extended information about a specific room


## get_status

Gets current status about a room (slow_link, etc.)


## get_list

Gets a list of all current rooms


## Events

All events have the following structure:

```js
{
	class: "core",
	cmd: "event",
	data: {
		class: "media",
		subclass: "room",
		type: "...",
		obj_id: "...",
		body: {
			...
		}
	},
	tid: 1
}
```

Then `obj_id` will be the _room id_ of the room generating the event. The following _types_ are supported:


Type|Body|Description
---|---|---
created|`{room_id:...}`|The room has been created
started_member|`{room_id:..., role:..., user_id:..., peer_id:..., session_id:...}`|A new member has started
stopped_member|`{...}`|A member have left the room
status|`{...}`|The room status has been updated (slow_link, etc.)
info|`{info:...}`|An user-info has been sent to the room
destroyed|`{code:..., reason:...}`|The room has been destroyed
