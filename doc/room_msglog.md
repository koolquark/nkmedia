# NkMEDIA Room Msglog plugin


## Commands


### Send a message

**Sample**

```js
{
	class: "media",
	subclass: "room_msglog",
	cmd: "send",
	data: {
		room_id: "my_room_id",
		msg: {
			...
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
		msg_id: "54c1b637-36fb-70c2-8080-28f07603cda8"
	}
	tid: 1
}
```

All users registered to receive room events with type 'msglog' will receive the following event:

```js
{
	class: "core",
	cmd: "event",
	data: {
		class: "media",
		subclass: "room",
		type: "msglog",
		obj_id: "my_room_id",
		body: #{
			type: "send",
			msg: {
				msg_id: "54c1b637-36fb-70c2-8080-28f07603cda8",
				user: "user@domain",
				session_id: "c881cb76-3a2f-7353-a5fa-38c9862f00d9",
				...
			}
		}
	}
	tid: 2
}
```



### Gets all messages

This session type echos any received audio or video.

**Sample**

```js
{
	class: "media",
	subclass: "room",
	cmd: "msglog_get",
	data: {
		room_id: "my_room_id"
	}
	tid: 1
}
```
-->
```js
{
	result: "ok",
	data: [
		{
			msg_id: ...
			user: ...
			session_id: ...
			timestmap: ...
			...
		}
	],
	tid: 1
}
```
