# sip\_fork

SIP client library for Flutter (Dart) — lightweight wrapper for WebSocket/SIP signaling, session management, and basic media control.

## Status

> **Warning:** Experimental — not production-ready.
>
> This library is currently in **alpha** and under active development. Expect bugs, incomplete features, and breaking changes. Use at your own risk.


## Key features

* Persistent SIP connection over WebSocket.
* Registration and reconnection state handling.
* Incoming/outgoing call sessions with lifecycle events.
* Session-level media controls: mic, video, hold, audio routing.
* ICE servers configuration (STUN/TURN).

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  sip_fork: 
    git:
        url: https://github.com/MARK-46/sip-ua-fork.git
```

## Quick example

```dart
import 'package:sip_fork/sip_fork.dart' show 
  SIP_Client, SIP_Session,
  SIP_Settings, SIP_StateEnum, SIP_MediaStream, SIP_SocketType, SIP_StatusLine, SIP_AudioEnum;

void example() async {
  // Create settings (async factory)
  SIP_Settings settings = await SIP_Settings.create(
    socket_type: SIP_SocketType.WS,
    socket_uri: 'ws://123.45.67.89:8080/ws',
    sip_uri: 'sip:mark-1@123.45.67.89:5060',
    display_name: 'MARK-46',
    password: 'your_password_here',
    ice_servers: [
      {'url': 'stun:stun.l.google.com:19302'},
      {'url': 'stun:stun4.l.google.com:19302'},
      {'url': 'stun:stun.sipnet.ru:3478'},
      {'url': 'stun:stun.pjsip.org:3478'},
      // TURN example:
      // {
      //   'url': 'turn:123.45.67.89:3478',
      //   'username': 'turn_user',
      //   'credential': 'turn_secret'
      // },
    ],
  );

  // Create client
  SIP_Client client = SIP_Client(settings);

  // Connection state events
  client.on('sip.state', (SIP_StateEnum state, SIP_StatusLine status) {
    // state values: CONNECTED, DISCONNECTED, RECONNECTING,
    // REGISTRATION_FAILED, REGISTERED, UNREGISTERED
  });

  // Session events
  client.on('sip.session.incoming', (SIP_Session session) {
    // session.answer();
    // session.hangup();
    // session.setMicEnabled(false);
    // session.setVideoEnabled(false);
    // session.setHoldEnabled(true);
    // session.setAudioState(SIP_AudioEnum.speakerphone);
  });
  client.on('sip.session.outgoing',    (SIP_Session session) { });
  client.on('sip.session.connecting',  (SIP_Session session) { });
  client.on('sip.session.progress',    (SIP_Session session) { });
  client.on('sip.session.confirmed',   (SIP_Session session) { });
  client.on('sip.session.hold',        (SIP_Session session) { });
  client.on('sip.session.unhold',      (SIP_Session session) { });
  client.on('sip.session.stream',      (SIP_Session session, SIP_MediaStream stream) {
    // handle local/remote media stream
  });
  client.on('sip.session.terminated',  (SIP_Session session, SIP_StatusLine status) { });

  // Connect to SIP server
  client.connect();

  // Example control methods (by session target)
  // client.call('mark-2');
  // client.answer('mark-2');
  // client.hangup('mark-2');

  // client.setMicEnabled('mark-2', false);
  // client.setVideoEnabled('mark-2', false);
  // client.setHoldEnabled('mark-2', true);

  // client.setAudioState('mark-2', SIP_AudioEnum.speakerphone);
  // client.setAudioState('mark-2', SIP_AudioEnum.bluetooth);
  // client.setAudioState('mark-2', SIP_AudioEnum.earpiece);
}
```

## Configuration (`SIP_Settings.create`)

* `socket_type` — connection transport (e.g., `SIP_SocketType.WS`).
* `socket_uri` — WebSocket URL for SIP signaling (`ws://` or `wss://`).
* `sip_uri` — user SIP URI (e.g., `sip:username@domain:port`).
* `display_name` — display name for SIP registration.
* `password` — authentication credential.
* `ice_servers` — list of ICE server maps for NAT traversal. Each entry:

  * `url` (required), and optional `username`, `credential` for TURN.

## Events

Register handlers with `client.on(eventName, callback)`.

Important event names and payloads:

* `sip.state` ⇒ `(SIP_StateEnum state, SIP_StatusLine status)`
* `sip.session.incoming` ⇒ `(SIP_Session session)`
* `sip.session.outgoing` ⇒ `(SIP_Session session)`
* `sip.session.connecting` ⇒ `(SIP_Session session)`
* `sip.session.progress` ⇒ `(SIP_Session session)`
* `sip.session.confirmed` ⇒ `(SIP_Session session)`
* `sip.session.hold` ⇒ `(SIP_Session session)`
* `sip.session.unhold` ⇒ `(SIP_Session session)`
* `sip.session.stream` ⇒ `(SIP_Session session, SIP_MediaStream stream)`
* `sip.session.terminated` ⇒ `(SIP_Session session, SIP_StatusLine status)`

## API overview

Top-level classes:

* `SIP_Client`

  * Properties:

    * `state` — current `SIP_StateEnum`.
    * `sessions` — active sessions collection.
  * Methods:

    * `connect()` — open connection and attempt registration.
    * `disconnect()` — close connection.
    * `call(target)` — place outgoing call.
    * `answer(sessionIdOrTarget)` — answer incoming call.
    * `hangup(sessionIdOrTarget)` — terminate call.
    * `setMicEnabled(sessionIdOrTarget, bool)`
    * `setVideoEnabled(sessionIdOrTarget, bool)`
    * `setHoldEnabled(sessionIdOrTarget, bool)`
    * `setAudioState(sessionIdOrTarget, SIP_AudioEnum)`

* `SIP_Session`

  * Methods:

    * `answer()`, `hangup()`
    * `setMicEnabled(bool)`, `setVideoEnabled(bool)`
    * `setHoldEnabled(bool)`
    * `setAudioState(SIP_AudioEnum)`

* Enums / Types:

  * `SIP_StateEnum` — `CONNECTED`, `DISCONNECTED`, `RECONNECTING`, `REGISTRATION_FAILED`, `REGISTERED`, `UNREGISTERED`.
  * `SIP_SocketType` — e.g., `WS`.
  * `SIP_AudioEnum` — audio routing modes: `speakerphone`, `bluetooth`, `earpiece`.
  * `SIP_MediaStream` — media stream object provided on `sip.session.stream`.
  * `SIP_StatusLine` — status information for state or termination callbacks.

## Media and audio routing

* Use `setMicEnabled` and `setVideoEnabled` on session instances to control local capture.
* Use `setAudioState(..., SIP_AudioEnum.speakerphone|bluetooth|earpiece)` to choose output routing.
* Handle `sip.session.stream` to attach remote/local media streams to your UI/audio pipeline.

## ICE / NAT traversal

* Provide STUN servers at minimum for basic connectivity.
* TURN servers require `username` and `credential`.
* Example ICE entry:

  ```dart
  {
    'url': 'turn:turn.example.com:3478',
    'username': 'turn_user',
    'credential': 'turn_secret'
  }
  ```

## Notes

* The library expects a SIP-over-WebSocket gateway that supports the signaling used by this client.
* Protect credentials. Use secure storage for passwords and TLS (`wss://`) when available.
* Session identifiers used in control methods should match what the library exposes in `client.sessions` or callbacks.

## Contributing

Pull requests and bug reports accepted. Include reproducible steps and example SIP server configuration when applicable.

## License
dart-sip-ua is released under the [MIT license](https://github.com/cloudwebrtc/dart-sip-ua/blob/master/LICENSE).
