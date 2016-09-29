
# NkMEDIA

**IMPORTANT** NkMEDIA is still under development, and not yet ready for general use.

NkMEDIA is an scalable and flexible signaling and media server for WebRTC and SIP. Using NkMEDIA, it is easy to build powerful gateways, recorders, MCUs, SFUs, PBXs or any other media-based application. It is written in [Erlang](http://www.erlang.org).

NkMEDIA is made of a very simple and efficient core, and a set of plugins and backends that extend its capabilities. At its core, it is only capable of controlling _peer to peer_ calls. However, activating plugins like _nkmedia_janus_ (based on [Janus](https://janus.conf.meetecho.com/index.html)), _nkmedia_fs_ (based on [Freeswitch](https://freeswitch.org)) and _nkmedia_kms_ (based on [Kurento](https://www.kurento.org)), it can perform complex media operations in an very simple way. Since each backend has very different characteristics, you can use the very best tool for each situation. For example, Janus is very lightweight and a great choice to write proxies and SFUs. Freeswitch has full PBX capabilities (allowing you to _park_ and _transfer_ calls to multiple destinations without starting new WebRTC sessions, detect _dtmf_ tones, etc.) and has a very powerful video MCU. Kurento is the most flexible tool to design any media processing system.

NkMEDIA also offers out of the box three signaling APIs (again as plugins): a full SIP implementation (based on [NkSIP](https://github.com/NetComposer/nksip), so it can be a flexible, massively scalable SIP client and server), a [Verto](http://evoluxbr.github.io/verto-docs/) server implementation (that can be used with any backend, not only Freeswitch) and its own signaling system, [NetComposer API](https://github.com/NetComposer/nkservice/blob/luerl/doc/api_intro.md). It also possible to add new signaling APIs, or use your own signalling solution out of NkMEDIA.

NkMEDIA has full support for Trickle ICE and non Trickle ICE clients and servers. You can connect clients that does not support trickle at all to all-trickle backends like Kurento, and trickle clients to non-trickle servers like Freeswitch, automatically.

When using NkMEDIA, you start defining one or several _services_. Each service can use a different set of plugins (a specific service can even use a different version of a backend like Janus than another started service). Each service can define a TCP, TLS or websocket (WS or WSS) url, that can used simultaneously as the management interface for the service and as a signaling sever for clients. Each service starts and uses a fresh copy of the selected backends, so a failure in one of the backends doesn't affect other started services. 

You can control NkMEDIA through the management interface, creating any number of _sessions_. It offers a clean, very easy to use API, independent of any supported backend. You don't need to know how to install or manage Janus, Freeswitch or Kurento instances. When you order an operation to be performed on the session (like starting a proxy, recording, starting an SFU, etc.), NkMEDIA selects the right backend that supports that operation automatically and in a complete transparent way. For operations supported by several active backends (like `echo`) you can also force the selection.

In real-life deployments, you will typically connect a server-side application to the management interface. However, being a websocket connection, you can also use a browser to manage sessions (its own or any other's session, if it is authorized).


See the [User Guide](doc/index.md#user-guide) for a more detailed explanation of the architecture. 

## Features
* Full support for WebRTC and SIP.
* Full support for complex SIP scenarios: stateful proxies with serial and parallel forking, stateless proxies, B2BUAs, application servers, registrars, SBCs, load generators, etc.
* WebRTC P2P calls.
* Proxied (server-through) calls (including SIP/WebRTC gateways, with or without transcoding).
* Full Trickle ICE support. Connect trickle and non-trickle clients and backends automatically.
* [MCU](https://webrtcglossary.com/mcu/) based multi audio/video conferences
* [SFU](https://webrtcglossary.com/sfu/) (or mixed SFU+MCU) WebRTC distribution.
* Recording (with or without transcoding).
* Downloads, installs and monitors automatically instances of Janus, Freeswitch and Kurento, using [Docker](https://www.docker.com) containers.
* Supports thousands of simultaneous connections, with WebRTC and SIP.
* Robust and highly scalable, using all available processor cores automatically.
* Sophisticated plugin mechanism, that adds very low overhead to the core.
* Hot, on-the-fly core and application configuration and code upgrades.
* Security-sensitive architecture. The backends do not expose any management port, only RTP traffic.

## Current Plugins
* **nkmedia_janus**: Janus backend with support for webrtc echo, calls through the server, SFUs and SIP (in and out) gateways. Also dyamic muting of audio and video, bandwith control and recording.
* **nkmedia_fs**: Freeswitch backend with support for echo, calls through the server, MCUs and and SIP (in and out) gateways. SIP calls can participate in MCU sessions or be connected to webrtc endpoints.
* **nkmedia_kms**: Kurento backend with support for echo, calls through the server, SFUs and and SIP (in and out) gateways. SIP calls can participate in SFU sessions or be connected to webrtc endpoints. State of the art recording support, inmediately playable and seekable.
* **nkmedia_room**: Support for SFU and MCU rooms, with event generation for members in and out, member list and in-room user messaging.
* **nkmedia_call**: Provides an optional signaling server to be used over WS, WSS, TCP or TLS. Support for calling, accepting, rejecting, multiple parallel calls, etc.
** nkmedia_sip** : Provides full SIP support.
** nkmedia_verto**: Provides Verto protocol emulation for clients

In the [future](doc/roadmap.md), NkMEDIA will add support for:
* Multi-node configurations based on [NetComposer](http://www.slideshare.net/carlosjgf/net-composer-v2).
* Support for multiple Janus, Freeswitch and Kurento boxes simultaneously.


# Documentation

[ 1. User Guide](doc/index.md#user-guide)<br/>
[ 2. API Guide](doc/index.md#management-interface)<br/>
[ 3. Cookbook](doc/index.md#cookbook)<br/>
[ 4. Advanced Concepts](doc/index.md#advanced)<br/>
[ 5. Roadmap](doc/roadmap.md)<br/>


## Installation

Currently, NkMEDIA is only available in source form. To build it, you only need Erlang (> r17). 
To run NkMEDIA, you also need also Docker (>1.6). The docker daemon must be configured to use TCP/TLS connections.

```
git clone https://github.com/NetComposer/nkmedia
cd nkmedia
make
```







