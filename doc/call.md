# CALL Plugin

See the [API Introduction](intro.md) for an introduction to the interface.


The currently supported External API commands as described here. 

Class|Subclass|Cmd|Description
---|---|---|---
`media`|`call`|[`start`](#start-a-call)|Starts a new call
`media`|`call`|[`ringing`](#notify-call-ringing)|Notifies the call is ringing
`media`|`call`|[`answered`](#notify-call-answered)|Notifies the call is answered
`media`|`call`|[`rejected`](#notify-call-rejected)|Notifies the call is rejected
`media`|`call`|[`hangup`](#hangup-a-call)|Hangups a call





## Start a call

NkMEDIA includes, along with its media processing capabilities, a flexible signaling server that you can use for your own applications (you can of course use any other signalling protocol).

This mechanism is indepedent of any media sessions. You can use the call mechanism to send an offer and receive an answer, but it would be only a transport scheme. You must get the offer and, if neccessary, set the answer.

You can then use the create a new call using the _start_ command, with the following fields:

Field|Default|Description
---|---|---|---
callee|(mandatory)|Destination for the call (see bellow)
type|(undefined)|Call type (see bellow)
offer|{}|Offer for the call. If not included, it will not be used in the invite.
subscribe|true|Subscribe automatically to call events for this call
event_body|{}|Body to receive in the automatic events.
ring_time|30|Default ring time for the call

The offer can include metadata related for caller_id, etc. (See [concepts](concepts.md)]). It does not need to include an sdp (you can send it in a event or by any other mean).

If no _type_ is supplied, all registered plugins will try to locate the callee. You can limit the search to a single one using one of the supported types:

Type|Desc
---|---
user|The callee will be used as a registered user name
session|The callee will be used as a registered session
sip|Will be used as registered SIP user (only with [SIP plugin](sip.md))
verto|Will be used as registerd Verto user (only with [Verto plugin](sip.md))

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


NkMEDIA will locate all destinations (for example, por _user_ type, locating all sessions belongig to the user) and will an _invite_ each of them in a serial or parallel scheme (depending on the plugin), copying the offer if available, for example:

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

From all accepted calls, it is expected that the user calls either [answered](#notify-call-answered) or [rejected](#notify-call-rejected). It is also possible to notify [ringing](#notify-call-ringing).

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

You can optionally include an `answer` field.


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

The server can accept or deny the answer (for example because it no longer exists or it has been already answered).


## Notify call rejected

After receiving an invite, you can notify that you want to reject the call. Then only mandatory field is `call_id`:

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

You can hangup a call at any moment. Fields `code` and `error` are optional.

**Sample**

```js
{
	class: "media",
	subclass: "call"
	cmd: "hangup",
	data: {
		call_id: "8b35b132-375f-b3e5-a978-28f07603cda8",
		code: 0,							
		error: "User hangup"				
	}
	tid: 1
}
```





