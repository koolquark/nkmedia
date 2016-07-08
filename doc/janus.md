# NkMEDIA External Interface

## Janus Options

When the nkmedia_janus backend is selected (either manually, using the `backend` option when creating the session or automatically, depending on the type), de following types are supported:

Type|Description
---|---
[echo](#echo)|Echoes audio and/or video, managing bandwitch and recording

Most types allow modification of the media sytream, see documentation for each one.

When recording is available, a file with the same name of the session will be created in the recording directory.


### Echo

Allows to create an echo session. The caller must include the _offer_ in the `create_session` request, and NkMEDIA will include the _answer_ in the response.

 Aditional supported options are:


Field|Default|Description
---|---|---
use_audio|true|Include the audio or not
use_video|true|Include the video or not
bitrate|0|Maximum bitrate (kbps)
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

### Updates

It is possible to update the media session once started, using the `update_session` command. For the _echo_ type, the parameters `use_audio`, `use_video`, `bitrate` and `record` can be modified. If the recording is stopped and then started again, a new file will be generated.

