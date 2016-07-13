# NkMEDIA External Interface

## Janus Options

When the nkmedia_janus backend is selected (either manually, using the `backend` option when creating the session or automatically, depending on the type), de following types are supported:

Type|Updates|Description
---|---|---
[echo](#echo)|[yes](#echo-update)|Echoes audio and/or video, managing bandwitch and recording
[proxy](#proxy)|[yes](#proxy-update)|Routes media through the server, optionally adapting SIP and WebRTC protocols
[publish](#publish)|[yes](#publish-update)|Publishes audio and/or video to an SFU _room_
[listen](#listen)|[yes](#listen-update)|Listens to a publisher

Most types allow modification of the media sytream, see documentation for each one.

When recording is available, a file with the same name of the session will be created in the recording directory.


### Echo

Allows to create an echo session. The caller must include the _offer_ in the [session creation request](api_command.md#start-a-session), and NkMEDIA will include the _answer_ in the response.

Aditional supported options are:

Field|Default|Description
---|---|---
use_audio|true|Include or not the audio
use_video|true|Include or not the video
bitrate|0|Maximum bitrate (kbps, 0:unlimited)
record|false|Perform recording of audio and video


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
		use_video: false,
		record: true
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

### Echo Update

It is possible to update the media session once started, using the [update session request](api_commands.md#update-a-session). For the _echo_ type, the parameters `use_audio`, `use_video`, `bitrate` and `record` can be modified. If the recording is stopped and then started again, a new file will be generated.



### Proxy

Allows to create a proxy session. The caller must include the _offer_ in the [session creation request](api_command.md#start-a-session), and NkMEDIA will include the _offer_ to send to the called party. Later on, when the called party returns its answer, you must use the [set answer command](api_commands.md#set-an-answer), and you will get back the answer for the caller session.


Field|Default|Description
---|---|---
use_audio|true|Include or not the audio
use_video|true|Include or not the video
bitrate|0|Maximum bitrate (kbps, 0:unlimited)
record|false|Perform recording of audio and video


**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "start",
	data: {
		type: "proxy",
		offer: {
			sdp: "v=0.."
		},
		record: true
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

You must now call answer_session:

```js
{
	class: "media",
	class: "session",
	cmd: "set_answer",
	data: {
		session_id: "54c1b637-36fb-70c2-8080-28f07603cda8",
		answer: {
			sdp: "v=0..."
		}
	}
	tid: 2
}
```
-->
```js
{
	result: "ok",
	data: {
		answer: {
			sdp: "v=0..."
		}
	},
	tid: 2
}
```

### Proxy Update

It is possible to update the media session once started, using the [update session request](api_commands.md#update-a-session). For the _proxy_ type, the parameters `use_audio`, `use_video`, `bitrate` and `record` can be modified. If the recording is stopped and then started again, a new file will be generated.


## Publish

Allows to _publish_ a session with audio/video to a _room_, working as an _SFU_ (selective forwarding unit). Any number of listeners can then connect to this session.

If you don't include a room, a new one will be created automatically (using options `room_audiocodec`, `room_videocodec` and `room_bitrate`).


Field|Default|Description
---|---|---

room|(automatic)|Room to use
room_audio_codec|`"opus"`|Audio codec to force (`opus`, `isac32`, `isac16`, `pcmu`, `pcma`)
room_video_codec|`"vp8"`|Video codec to force (`vp8`, `vp9`, `h264`)
room_bitrate|`0`|Bitrate for the room (kbps, 0:unlimited)
use_audio|true|Include or not the audio
use_video|true|Include or not the video
bitrate|0|Maximum bitrate (kbps, 0:unlimited)
record|false|Perform recording of audio and video

**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "start",
	data: {
		type: "publish",
		offer: {
			sdp: "v=0.."
		},
		record: true,
		room_video_codec: "vp9"
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
		room: "bbd48487-3783-f511-ee41-28f07603cda8",
		answer: {
			sdp: "v=0..."
		}
	},
	tid: 1
}
```

### Publish update

It is possible to update the media session once started, using the [update session request](api_commands.md#update-a-session). Parameters `use_audio`, `use_video`, `bitrate` and `record` can be modified. 


## Listen

Allows to _listen_ to a previously started publisher, working as an _SFU_ (selective forwarding unit). You must tell the _publisher id_, and the room will be find automatically.

You must not include any offer in the [session creation request](api_command.md#start-a-session), and NkMEDIA will send you the _offer_ back. You must then supply an _answer_ calling tpo the [set answer command](api_commands.md#set-an-answer).



Field|Default|Description
---|---|---
publisher|(mandatory)|Publisher to listen to
use_audio|true|Include or not the audio
use_video|true|Include or not the video

**Sample**

```js
{
	class: "media",
	subclass: "session",
	cmd: "start",
	data: {
		type: "listen",
		publisher: "54c1b637-36fb-70c2-8080-28f07603cda8"
	}
	tid: 1
}
```
-->
```js
{
	result: "ok",
	data: {
		session_id: "2052a043-3785-de87-581b-28f07603cda8",
		offer: {
			sdp: "v=0..."
		}
	},
	tid: 1
}
```

You must now call answer_session:

```js
{
	class: "media",
	class: "session",
	cmd: "set_answer",
	data: {
		session_id: "2052a043-3785-de87-581b-28f07603cda8",
		answer: {
			sdp: "v=0..."
		}
	}
	tid: 2
}
```
-->
```js
{
	result: "ok",
	data: {
		answer: {
			sdp: "v=0..."
		}
	},
	tid: 2
}
```

### Listen update

Once started the session, you can _switch_ to listen to another publisher, but only if it is in the same room.

**Sample**

```js
{
	class: "media",
	class: "session",
	cmd: "update",
	data: {
		session_id: "2052a043-3785-de87-581b-28f07603cda8",
		type: "listen_switch"
		publisher: "29f394bf-3785-e5b1-bb56-28f07603cda8"
	}
	tid: 3
}
```