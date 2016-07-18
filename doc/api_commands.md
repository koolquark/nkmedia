# NkMEDIA External Interface

See the [API Introduction](api_intro.md) for an introduction to the interface.


The currently supported External API commands as described here. 

Class|Subclass|Cmd|Description
---|---|---|---
`media`|`session`|[`start`](#start-a-session)|Creates a new media session
`media`|`session`|[`stop`](#stop-a-session)|Destroys a new media session
`media`|`session`|[`set_answer`](#set-an-answer)|Sets the answer for a sessions
`media`|`session`|[`update`](#update-a-session)|Updates a current session
`media`|`call`|[`start`](#start-a-call)|Starts a new call
`media`|`call`|[`ringing`](#notify-call-ringing)|Notifies the call is ringing
`media`|`call`|[`answered`](#notify-call-answered)|Notifies the call is answered
`media`|`call`|[`answered`](#notify-call-rejected)|Notifies the call is rejected
`media`|`call`|[`hangup`](#hangup-a-call)|Hangups a call


## Start a Session

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
event_body|{}|Body to receive in the automatic events.
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



## Stop a Session

Destroys a started session.

Field|Default|Description
---|---|---|---
session_id|(mandatory)|Session Id
code||Integer code reason
reason||String error reason


## Set an Answer

When the started session's type means that you must supply an answer (like `proxy`), you must use this API to set the remote party's answer.

You will get your own answer in the response.



## Update a Session

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



## Start a call

NkMEDIA includes, along with its media processing capabilities, a flexible signaling server that you can use for your own applications (you can of course use any other signalling protocol).

This mechanism is indepedent of any media sessions. You can use the call mechanism to send an offer and receive an answer, but it would be only a transport scheme. You must get the offer and, if neccessary, set the answer.

You can then use the _start_call_ command, with the following fields:

Field|Default|Description
---|---|---|---
callee|(mandatory)|Destination for the call
type|(undefined)|Call type (see bellow)
offer|{}|Offer for the call. If not included, it will not be used in the invite.
subscribe|true|Subscribe automatically to call events for this call
event_body|{}|Body to receive in the automatic events.
ring_time|30|Default ring time for the call

The offer can include metadata related for caller_id, etc. (See [concepts](concepts.md)]). It does not need to include an sdp (you can send it in a event or by any other mean).

If no _type_ is supplied, all registered plugins will try to locate the callee. You can fix to a single one using one of the supported types:

Type|Desc
---|---
user|The callee will be used as registered user name
session|The callee will be used as registered session
sip|Will be used as registered SIP user (only with SIP plugin)
verto|Will be used as registerd Verto user (only with Verto plugin)

NkMEDIA will locate all destinations (for example, por _user_ type, locating all sessions belongig to the user) and will an _invite_ to each of them in parallel, copying the offer if available, for example:

```js
{
	class: "media",
	subclass: "call",
	cmd: "invite",
	data: {
		call_id: "8b35b132-375f-b3e5-a978-28f07603cda8",
		type: "user",
		offer: {
			sdp: "v=0..",
			caller_name: "My Name",
			caller_id: "myuser@domain.com"
		}
	},
	tid: 1000
}
```

you must reply inmediately (before prompting the user or ringing) either accepting the call (returning `result: "ok"` with no data) or rejecting it with `result: "error"`.

From all accepted calls, it is expected that the user calls either [answered](#notify-call-answered) or [rejected](#notify-call-rejected). It is also possible to notify [ringing](#notify-call-answered).

Also, you have to be prepared to receive a hangup event at any moment, even before accepting the call:


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

**Sample**

```js
{
	class: "media",
	subclass: "call"
	cmd: "start",
	data: {
		type: "user",
		user: "user@domain.com"
		offer: {
			sdp: "v=0..",
			caller_name: "My Name",
			caller_id: "myuser@domain.com"
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
		call_id: "8b35b132-375f-b3e5-a978-28f07603cda8",
		
	},
	tid: 1
}
```


## Notify call ringing

After receiving an invite, you can notify that the call is ringing:

```js
{
	class: "media",
	subclass: "call",
	cmd: "ringig",
	data: {
		call_id: "8b35b132-375f-b3e5-a978-28f07603cda8"
	},
	tid: 2000
}
```


## Notify call answered

After receiving an invite, you can notify that you want to answer the call:

Field|Default|Description
---|---|---|---
call_id|(mandatory)|Call ID
answer|{}|Optional answer for the caller
subscribe|true|Subscribe automatically to call events for this call
event_body|{}|Body to receive in the automatic events.


**Sample**

```js
{
	class: "media",
	subclass: "call",
	cmd: "answered",
	data: {
		call_id: "8b35b132-375f-b3e5-a978-28f07603cda8",
		answer: {
			sdp: "..."
		}
	},
	tid: 2000
}
```

The server can accept or deny the answer (mainly because it no longer exists or it has been already answered)



## Notify call rejected

After receiving an invite, you can notify that you want to reject the call. Then only mandatory field is `call_id`.

After receiving an invite, you can notify that you want to answer the call:

```js
{
	class: "media",
	subclass: "call",
	cmd: "rejected",
	data: {
		call_id: "8b35b132-375f-b3e5-a978-28f07603cda8"
	},
	tid: 2000
}
```



## Hangup a call

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


