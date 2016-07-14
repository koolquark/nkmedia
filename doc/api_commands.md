# NkMEDIA External Interface

See the [API Introduction](api_intro.md) for an introduction to the interface.


## Core Commands

The currently supported External API commands as described here. 

**Session Commands**

Class|Subclass|Cmd|Description
---|---|---|---
`media`|`session`|[`start`](#start-a-session)|Creates a new media session
`media`|`session`|[`stop`](#stop-a-session)|Destroys a new media session
`media`|`session`|[`set_answer`](#set-an-answer)|Sets the answer for a sessions
`media`|`session`|[`update`](#update-a-session)|Updates a current session
`media`|`call`|[`start`](#start-a-call)|Starts a new call
`media`|`call`|[`hangup`](#hangup-a-call)|Hangups a call


### Start a Session

Performs the creation of a new media session. The mandatory `type` field defines the type of session. Currently, the following types are supported, along with the necessary plugin or plugins that support it.

Type|Plugins
---|---|---
p2p|(none)
echo|[nkmedia_janus](janus.md#echo)
proxy|[nkmedia_janus](janus.md#proxy)
publish|[nkmedia_janus](janus.md#publish)
listen|[nkmedia_janus](janus.md#listen)
park|nkmedia_fs
mcu|nkmedia_fs

See each specific plugin documentation to learn about how to use it and supported options.

Common fields for the request are:

Field|Default|Description
---|---|---|---
type|(mandatory)|Session type
offer|{}|Offer for the session, if available
answer|{}|Answer for the session, if available
wait_timeout||Timeout for sessions in _wait_ state
ready_timeout||Timeout for sessions in _reay_ state
subscribe|true|Subscribe to session events
backend|(automatic)|Forces a specific plugin for the request

Depending on the type, you need to supply an _offer_, or an _offer_ and an _answer_. The response from the server may include the _answer_, or the _offer_ to the other party.



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



### Stop a Session

Destroys a started session.

Field|Default|Description
---|---|---|---
session_id|(mandatory)|Session Id
code||Integer code reason
reason||String error reason


### Set an Answer

When the started session's type means that you must supply an answer (like `proxy`), you must use this API to set the remote party's answer.

You will get your own answer in the response.



### Update a Session

Some session types allow to modify the session characteristics in real time. 

The `session_id` field is mandatory. See each specific plugin documentation to learn about how to use it and supported options. The field `type` is mandatory to set the _type_ of update.


**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "update",
	data: {
		type: "media",
		session_id: "54c1b637-36fb-70c2-8080-28f07603cda8",
		record: true,
		use_audio: false,
		bitrate: 100000
	}
	tid: 1
}
```
-->
```js
{
	result: "ok",
	tid: 1
}
```



### Start a call

NkMEDIA includes, along with its media processing capabilities, a flexible signaling server that you can use for your own applications. You can however use your own signaling protocol.

To use the signaling server, you must first create a session (typically of types _p2p_ or _proxy_). 

You can then use the _start_call_ command, with the following fields:

Field|Default|Description
---|---|---|---
session_id|(mandatory)|Session Id
type|(mandatory)|Call type (see bellow)
offer|{}|Offer for the call. If not included, it will not be used in the invite

The offer can include metadata related for caller_id, etc. (See [concepts](concepts.md)]). It does not need to include an sdp (you can send it in a event or by any other mean).

When the call is answered, the answer is automatically connected to the session. If the call is destroyed, the session is automatically stopped. The opposite is also true.

Depending on the _type_, other fields must be included. NkMEDIA supports currently the following types:

Type|Field|Desc
---|---|---
**user**||
user|user|Registered user to call to. All sessions will be ringed
**session**||
session|session|Registered session to call to
**sip**|(only with SIP plugin)
sip|url|SIP URL
**verto**|(only with Verto plugin)
verto|user_id|Registered verto user to call to

**Sample**

```js
{
	class: "media",
	subclass: "call"
	cmd: "start",
	data: {
		type: "user",
		session_id: "54c1b637-36fb-70c2-8080-28f07603cda8"
		offer: {
			sdp: "v=0..",
			caller_name: "My Name",
			caller_id: "myuser@domain.com"
		},
		user: "user@domain.com"
	}
	tid: 1
}
```
-->
```js
{
	result: "ok",
	data: {
		call_id: "8b35b132-375f-b3e5-a978-28f07603cda8",
		
	},
	tid: 1
}
```

If the remote party accepts the call, you will get a `call_id` and will be subscribed automatically to related events.


For `user` and `session` types, one or several (for `user`, if he has several sessions) requests will be sent over the connection, for example:

```js
{
	class: "media",
	subclass: "call",
	cmd: "invite",
	data: {
		call_id: "8b35b132-375f-b3e5-a978-28f07603cda8",
		type: "user",
		user: "user@domain.com",
		offer: {
			sdp: "v=0..",
			caller_name: "My Name",
			caller_id: "myuser@domain.com"
		}
	},
	tid: 1000
}
```

you must answer immediately with success or error:

```js
{
	result: "ok",
	tid: 1000
}
```

then you can send the following events: _ringing_, _accepted_ or _rejected_:

```js
{
	class: "core",
	cmd: "event",
	data: {
		class: "media",
		subclass: "call",
		type: "ringing",
		obj_id: "8b35b132-375f-b3e5-a978-28f07603cda8"
	},
	tid: 2000
}
```

or

```js
{
	class: "core",
	cmd: "event",
	data: {
		class: "media",
		subclass: "call",
		type: "accepted",
		obj_id: "8b35b132-375f-b3e5-a978-28f07603cda8",
		body: {
			answer: {
				sdp: "..."
			}
		}
	tid: 2000
}
```

or

```js
{
	class: "core",
	cmd: "event",
	data: {
		class: "media",
		subclass: "call",
		type: "rejected",
		obj_id: "8b35b132-375f-b3e5-a978-28f07603cda8",
		body: {							// Optional
			code: 0
			error: "User Rejected"
		}
	tid: 2000
}
```

Also, you must be prepared to receive a hangup event at any moment (even before accepting the call):

```js
{
	class: "core",
	cmd: "event",
	data: {
		class: "media",
		subclass: "call",
		type: "hangup",
		obj_id: "8b35b132-375f-b3e5-a978-28f07603cda8",
		body: {							
			code: 0
			error: "User Rejected"
		}
	tid: 1001
}
```

### Hangup a call

You can hangup a call using the `call_id`:

**Sample**

```js
{
	class: "media",
	subclass: "call"
	cmd: "hangup",
	data: {
		call_id: "8b35b132-375f-b3e5-a978-28f07603cda8",
		code: 0,							// Optional
		error: "User hangup"				// Optional
	}
	tid: 1
}
```


