
# NkMEDIA

**IMPORTANT** NkMEDIA is still under development, and not yet ready for general use.

NkMEDIA is an scalable and flexible media server for WebRTC and SIP. Using NkMEDIA, it is easy to build scalable and powerful gateways, recorders, MCUs, SFUs, PBXs or any other media-based application. It is written in [Erlang](http://www.erlang.org).

NkMEDIA is made of a very simple and efficient core, and a set of plugins and backends that extend its capabilities. At its core, is only capable of controlling _peer to peer_ calls. However, installing backends like _nkmedia_janus_ (based on [Janus](https://janus.conf.meetecho.com/index.html)), _nkmedia_fs_ (based on [Freeswitch](https://freeswitch.org)) and _nkmedia_kms_ (based on [Kurento](https://www.kurento.org)), it can perform any complex media operation. Since each backend has different characteristics, you can use the very best tool for each situation. For example, Janus is very lightweight and a great choice to write proxies and SFUs. Freeswitch has full PBX capabilities (allowing you to _park_ and _transfer_ calls to multiple destinations without starting new WebRTC sessions, detect _dtmf_ tones, etc.) and has a very powerful video MCU. Kurento is the most flexible tool to design any media processing system.

NkMEDIA also offers three signaling APIs, again as plugins: a full SIP implementation (based on [NkSIP](https://github.com/NetComposer/nksip), so it can be a flexible, massively scalable SIP client and server), a full [Verto](http://evoluxbr.github.io/verto-docs/) implementation (that can be used with any backend, not only Freeswitch) and its own signaling system. It also possible to add new signaling APIs.

When using NkMEDIA, you start defining one or several _services_. Each service can use a different set of backends and plugins (a specific service can even use a diffent version of backend like Janus). Each service defines a websocket (WS or WSS) url where the management interface for the service is available. 

You can control NkMEDIA through the management interface, creating any number of _sessions_. It offers a clean, very easy to use API, independent of the selected backend. You don't need to know how to manage Janus, Freeswitch or Kurento. When you order a operation to be performed on the session (like starting a proxy, recording, starting an SFU, etc.), NkMEDIA selects the right backend that supports that operation automatically and in a transparent way. For operations supported by several backends (like `echo`) you can also force the selection.

See the [User Guide](doc/user_guide.md) for a more detailed explanation of the architecture. 


## Features
* Full support for WebRTC (with several signalings available) and SIP.
* Full support for complex SIP scenarios: stateful proxies with serial and parallel forking, stateless proxies, B2BUAs, application servers, registrars, SBCs, load generators, etc.
* WebRTC P2P calls.
* Proxied (server-through) calls (including SIP/WebRTC gateways, with or without transcoding).
* [MCU](https://webrtcglossary.com/mcu/) based multi audio/video conferences
* [SFU](https://webrtcglossary.com/sfu/) (or mixed SFU+MCU) WebRTC distribution.
* Recording (with or without transcoding).
* Downloads and installs automatically instances of Janus, Freeswitch and Kurento, using [Docker](https://www.docker.com) containers.
* Supports thousands of simultaneous connections, with WebRTC and SIP.
* Robust and highly scalable, using all available processor cores automatically.
* Sophisticated plugin mechanism, that adds very low overhead to the core.
* Hot, on-the-fly core and application configuration and code upgrades.
* Security-sensitive architecture. The backends do not expose management ports, only RTP traffic.


In the [future]((doc/roadmap.md), NkMEDIA will add support for:
* Multi-node configurations based on [NetComposer](http://www.slideshare.net/carlosjgf/net-composer-v2).
* Suport for multiple Janus, Freeswitch and Kurento boxes simultaneously.


# Documentation

[ 1. User Guide](doc/user_guide.md)<br/>
[ 2. API Guide](doc/api.md)<br/>
[ 3. Cookbook](doc/cookbook.md)<br/>
[ 4. Advanced Concepts](doc/advanced.md)<br/>
[ 5. Roadmap](doc/roadmap.md)<br/>


## Installation

NkMEDIA only has two dependencies:
* Erlang (>17).
* Docker (>1.6). The docker daemon must be confired to use TCP/TLS connections. The recommended configurations is at localhost.

```
git clone https://github.com/NetComposer/nkmedia
cd nkmedia
make
```







