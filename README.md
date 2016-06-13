
# NkMEDIA

**IMPORTANT** NkMEDIA is still under development, and not ready for general use.

NkMEDIA is an massively scalable and flexible media server for WebRTC and SIP. Using NkMEDIA, it is easy to build scalable and powerful gateways, recorders, MCUs, SFUs, PBXs or any other application. It is written in Erlang.

NkMEDIA uses a pluggable backend architecture. [Freeswitch](https://freeswitch.org) and [Janus](https://janus.conf.meetecho.com/docs/) are already supported, and [Kurento](https://www.kurento.org) is in the works. In the future, other media servers could be available. 

NkMEDIA allows to receive and make SIP and WebRTC calls. It uses a powerful plugin system that allows you to extend its functionality (like adding backend media services or own signaling protocols). See [NkSERVICE](https://github.com/NetComposer/nkservice) for a more detailed explanation. Since it uses [NkSIP](https://github.com/NetComposer/nksip), it is also a full, scalable SIP client and server. Depending on the media server, is capable of doing things like:

* Call switching (including SIP/WebRTC gateways)
* [MCU](https://webrtcglossary.com/mcu/)-based multi audio/video conferences
* [SFU](https://webrtcglossary.com/sfu/) (or mixed SFU+MCU) WebRTC distribution.
* Recording
* Freeswitch native signaling ([Verto](http://evoluxbr.github.io/verto-docs/)) server and proxy (it can be used with any media server, not only Freeswitch)
* Kurento proxy.

In the near future it will be capable to be a full [Matrix](https://matrix.org) server.

NkMEDIA is a piece of the [NetComposer](http://www.slideshare.net/carlosjgf/net-composer-v2) framework, but can be used on its own.


## Arquitecture

NkMEDIA starts any number of Freeswitch, Janus and/or Kurento instances, inside [docker](https://www.docker.com) containers. All the tools to build and deploy the containers are included.


## Installation

```
git clone https://github.com/NetComposer/nkmedia
cd nkmedia
make
```

NkMEDIA is designed to connect to a docker daemon running on the host machine, and listening on `tcp://127.0.0.1`. Any other daemon, possibly on other node, can also be used instead.






