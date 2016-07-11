# NkMEDIA External Interface

## Janus Options

When the nkmedia_janus backend is selected (either manually, using the `backend` option when creating the session or automatically, depending on the type), de following types are supported:

Type|Updates|Description
---|---|---
[echo](#echo)|[yes](#echo-update)|Echoes audio and/or video, managing bandwitch and recording
[proxy](#proxy)|[yes](#proxy-update)|Routes media through the server, optionally adapting SIP and WebRTC protocols

Most types allow modification of the media sytream, see documentation for each one.

When recording is available, a file with the same name of the session will be created in the recording directory.


### Echo

Allows to create an echo session. The caller must include the _offer_ in the `create_session` request, and NkMEDIA will include the _answer_ in the response.

 Aditional supported options are:


Field|Default|Description
---|---|---
use_audio|true|Include the audio or not
use_video|true|Include the video or not
bitrate|0|Maximum bitrate (kbps, 0:unlimited)
record|false|Perform recording of audio and video


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

It is possible to update the media session once started, using the `update_session` command. For the _echo_ type, the parameters `use_audio`, `use_video`, `bitrate` and `record` can be modified. If the recording is stopped and then started again, a new file will be generated.



### Proxy

Allows to create a proxy session. The caller must include the _offer_ in the `create_session` request, and NkMEDIA will include the _offer_ to send to the called party. Later on, when the called party returns its answer, you must use the `answer_session` command, and you will get back the answer for the caller session.


Field|Default|Description
---|---|---
use_audio|true|Include the audio or not
use_video|true|Include the video or not
bitrate|0|Maximum bitrate (kbps, 0:unlimited)
record|false|Perform recording of audio and video


**Sample**

```js
{
	class: "media",
	cmd: "start_session",
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
	cmd: "answer_session",
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

It is possible to update the media session once started, using the `update_session` command. For the _proxy_ type, the parameters `use_audio`, `use_video`, `bitrate` and `record` can be modified. If the recording is stopped and then started again, a new file will be generated.

