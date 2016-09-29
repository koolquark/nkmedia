# Concepts

* [Services](#services)
* [Sessions](#sessions)
* [Offers and Answers](#offers-and-answers)
* [Calls](#calls)



## Services

TBD


## Sessions

Sessions are the key element in NkMEDIA. A session is multimedia communication between two parties. Each party can be an endpoint (like a browser or SIP phone) or a media processing facility (like a Proxy, SFU, MCU, etc.), that could itself be connected to other sessions.

All sessions have an _offer_ and an _answer_. The session starts without offer or answer, and enters in _ready_ state when both (offer and answer) are available and have a corresponding SDP.

To set the offer, you have several options:
* Set a _raw_, direct SDP
* Start a media processing that takes an SDP from you but generates another one for the session (like a proxy)
* Start a media processing that generates the offer (like a file player)

Once the offer is set, you must set the answer. Again, there are several options:
* Set a _raw_, direct SDP
* Start a media processing that generates the answer, based on the offer (like a MCU)
* Start a _invite_ to get the answer from other party.





## Offers and Answers

In NkMEDIA, _offer_ and _answer_ objects are related not only to _sdp_, but can include may other pieces of information. Offer and answers could exists without sdp, if it is not yet available. 

Offers and answers are described as a json object, with the following fields:

Field|Sample|Description
---|---|---
sdp|"v=0..."|SDP, if available
sdp_type|"webrtc"|Can be "webrtc" (the default) or "rtp". Informs to NkMEDIA if it is an SDP generated at a WebRTC endpoint or not.
trickle_ice|false|If the SDP has no candidates and Trickle ICE must be used, it must be indicated as `trickle_ice=true`

