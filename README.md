
# NkMEDIA

NkMEDIA is an Erlang media server control project. It is currently capable of managing [Freeswitch](https://freeswitch.org) media servers. In the future, [Kurento](http://www.kurento.org), [Jitsi Videobridge](https://jitsi.org/Projects/JitsiVideobridge) or [Spreed.me](https://github.com/strukturag/spreed-webrtc) media servers could be added. NkMEDIA uses [Docker](https://www.docker.com) containers to start and monitor these mediaservers.

NkMEDIA allows to receive and make SIP and WebRTC calls, in the later case using a flexible plugin system to develop signalings. See [[NkSERVICE](https://github.com/NetComposer/nkservice) for a more detailed explanation. Since it uses [NkSIP](https://github.com/NetComposer/nksip), it is also a full, scalable SIP client and server. Depending on the media server, is capable of doing things like:

* Call switching (include SIP/WebRTC gateways)
* [MCU](https://webrtcglossary.com/mcu/)-based multi audio/video conferences
* Freeswitch native signaling ([Verto](http://evoluxbr.github.io/verto-docs/)) server and proxy (it can be used with any media server, not only Freeswitch)

In the near future it will be capable to:

* Recording
* Playing of media files
* [SFU](https://webrtcglossary.com/sfu/) (or mixed SFU+MCU) WebRTC distribution.
* [Matrix](https://matrix.org) signaling support


NkMEDIA is a piece of the [NetComposer](http://www.slideshare.net/carlosjgf/net-composer-v2) framework, but can be used on its own.


## Arquitecture

NkMEDIA is designed to run in the same node as freeswitch, starting it inside a docker container. Freeswitch only needs to listen on localhost for all services (event_socket, Verto and SIP). However, a development mode (maninly for OSX) allows to control an external Freeswitch docker.


## Installation

```
git clone https://github.com/NetComposer/nkmedia
cd nkmedia
make
```

NkMEDIA needs a docker daemon running on the host machine, and listening on `tcp://127.0.0.1`. If another docker daemon, possibly on other node, should be used instead, standard docker machine environment variables can be used. First thing is installing the specific nkmedia configured Freeswitch, from the Docker repository or by manual installtion. NkMEDIA includes all the tools to generate the image and push it to the repository.

```
make shell
1> 
```



### Configuration

Option|Default|Description
---|---|---
no_docker|false|If true, no docker daemon will be contacted
docker_company|"netcomposer"|Company name to name docker images
fs_version|"v1.6.5"|Default Freeswitch version to use
fs_release|"r01|Default Freeswitch release (docker image tag) to use
fs_password|(see code)|Default Freeswitch password for everything




