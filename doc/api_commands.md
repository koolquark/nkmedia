# NkMEDIA External Interface

See the [API Introduction](api_intro.md) for an introduction to the interface.


## Core Commands

The currently supported External API commands as described here. 

Cmd|Description
---|---
[`start_session`](#start-a-session)|Creates a new media session
[`stop_session`](#stop-a-session)|Destroys a new media session
[`set-answer`](#set-an-answer)|Sets the answer for a sessions
[`update_session`](#update-a-session)|Updates a current session


### Start a Session

Performs the creation of a new media session. The mandatory `type` field defines the type of session. Currently, the following types are supported, along with the necessary plugin or plugins that support it.

Type|Plugins
---|---|---
p2p|(none)
echo|[nkmedia_janus](janus.md#echo)
proxy|nkmedia_janus
publish|nkmedia_janus
listen|nkmedia_janus
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
	cmd: "start_session",
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

Some session types allow to modify the session characteristics in real time. For example, the `listener` type allows to switch to listen to a different publisher, and the the types provided the the _nkmedia_fs_ plugin allow even to change the session type.

See each specific plugin documentation to learn about how to use it and supported options.


