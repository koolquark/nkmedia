
# NkMEDIA

NkMEDIA is an Erlang media server control project. It is capable of managing audio and video streams using WebRTC and SIP, in a ver flexible way. It is easy to build scalable powerful gateways, recorders, PBXs or any other application.

NkMEDIA uses [Freeswitch](https://freeswitch.org) and [Janus](https://janus.conf.meetecho.com/docs/) media servers. In the future, other media servers could be available. 

NkMEDIA allows to receive and make SIP and WebRTC calls, in the later case using a flexible plugin system to develop signalings. See [[NkSERVICE](https://github.com/NetComposer/nkservice) for a more detailed explanation. Since it uses [NkSIP](https://github.com/NetComposer/nksip), it is also a full, scalable SIP client and server. Depending on the media server, is capable of doing things like:

* Call switching (including SIP/WebRTC gateways)
* [MCU](https://webrtcglossary.com/mcu/)-based multi audio/video conferences
* [SFU](https://webrtcglossary.com/sfu/) (or mixed SFU+MCU) WebRTC distribution.
* Freeswitch native signaling ([Verto](http://evoluxbr.github.io/verto-docs/)) server and proxy (it can be used with any media server, not only Freeswitch)

In the near future it will be capable to:

* Recording
* Playing of media files
* [Matrix](https://matrix.org) signaling support

NkMEDIA is a piece of the [NetComposer](http://www.slideshare.net/carlosjgf/net-composer-v2) framework, but can be used on its own.


## Arquitecture

NkMEDIA starts any number of Freeswitch and Janus instances, inside [docker](https://www.docker.com) containers. All the tools to build and deploy the containers are included.


## Installation

```
git clone https://github.com/NetComposer/nkmedia
cd nkmedia
make
```

NkMEDIA is designed to connect to a docker daemon running on the host machine, and listening on `tcp://127.0.0.1`. Any other daemon, possibly on other node, can also be used instead, although it is not recommeded.


### Configuration

Option|Default|Description
---|---|---
no_docker|false|If true, no docker daemon will be contacted
docker_company|"netcomposer"|Company name to name docker images
fs_version|"v1.6.5"|Default Freeswitch version to use
fs_release|"r01|Default Freeswitch release (docker image tag) to use
fs_password|(see code)|Default Freeswitch password for everything
janus_version|"master"|Default Janus version to use
janus_release|"r01|Default Freeswitch release (docker image tag) to use
sip_port|0|Default port for SIP incoming





