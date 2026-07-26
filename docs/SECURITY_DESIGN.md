# Float protocol v2 security design

Status: implemented design for protocol v2.

## Trust boundaries

- A web page and its content script are untrusted. Page data may describe video
  candidates, but the pairing secret must never enter a content script or page
  execution context.
- The extension background context is trusted only after the user deliberately
  copies the companion's per-install secret into that extension. The secret is
  persisted in background-owned IndexedDB and is used only by the background
  context. The popup code may save, remove, and query status but never requests
  or receives the persisted value. Content scripts receive no storage
  permission, credential module, or credential-read message.
- The loopback network is not an authentication boundary. Other local
  processes, browser pages, and extensions can reach loopback ports.
- The macOS companion is the authorization authority. It owns the secret in
  the Keychain, validates the WebSocket Origin, authenticates the connection,
  enforces protocol state and limits, isolates authenticated extension
  connections, and permits only one active media source.
- WebRTC media stays peer-to-peer on the host with no STUN or TURN servers.
  SDP and ICE are sensitive operational data and must not appear in Release
  logs.

## Listener and WebSocket handshake

The listener uses `NWParameters.requiredLocalEndpoint` with the exact endpoint
`127.0.0.1:17891`. Endpoint reuse and Bonjour advertisement are disabled. An
accepted TCP peer is also checked to have an IPv4 loopback remote endpoint.

The WebSocket request handler accepts only a syntactically exact
`chrome-extension://<extension-id>` or `moz-extension://<extension-uuid>`
Origin. Missing, opaque (`null`), web, file, malformed, and path-bearing origins
are rejected during the HTTP upgrade.

Each extension connection offers a fresh `float-v2.<128-bit-random-token>`
WebSocket subprotocol. The request handler records the exact validated Origin
against that bounded, short-lived token and selects it in the response. Once
the connection becomes ready, the companion retrieves the selected subprotocol
and consumes the matching Origin record. This associates concurrent
handshakes with connections without an unsafe FIFO assumption.

## Pairing and authentication

The companion generates 32 random bytes with `SecRandomCopyBytes`, encodes them
as unpadded base64url for display, and stores the raw value as a generic
password in the macOS Keychain. Credential storage is abstracted so tests use
an in-memory store.

The user deliberately chooses **Copy Sensitive Pairing Secret** and pastes that
value into the extension popup. Unpacked Chrome builds and Firefox follow the
same explicit flow; no wildcard origin exception and no silent trust-on-first-
use path exists. This interim enrollment exposes the long-lived secret through
the general pasteboard. Float clears it after successful authentication or 60
seconds only when both the pasteboard change count and value still match.
Pasteboard monitors and Universal Clipboard remain a documented risk; a
short-lived, single-use enrollment code with per-origin credentials is the
preferred future design.

After the WebSocket upgrade:

1. The companion sends `authChallenge` with version `2`, the exact validated
   Origin, and a fresh 32-byte random nonce encoded as unpadded base64url.
2. The extension verifies that the Origin matches its own background origin.
3. The extension returns `authResponse` with version `2` and
   `HMAC-SHA256(secret, canonicalInput)`.
4. The companion performs a constant-time comparison, consumes the nonce even
   on failure, and sends `authResult` only on success.

The canonical UTF-8 byte string is exactly:

```text
Float-Pairing-V2
version=2
origin=<exact Origin>
nonce=<unpadded base64url nonce>
```

It ends with one LF byte. A shared fixed test vector is exercised by Swift and
TypeScript tests.

No state, media signaling, playback, quality, debug, or error message is
processed before authentication. Challenges expire after 10 seconds. One
connection per exact extension Origin remains authenticated; a newer socket
atomically replaces the stale socket for that Origin, while Chrome and Firefox
origins may coexist. Connections retain independent tabs, protocol state,
counters, and pending ICE. Only one client owns the active media source, and
media commands are routed to that client. Rotating the secret first advances a
credential generation, closes protocol state, cancels authentication work, and
removes every client context before closing network connections.

## Protocol state and limits

Every protocol v2 message carries `version: 2`. The connection state is:

```text
handshake -> challenged -> authenticated -> closed
```

Only `authResponse` is valid while challenged. After authentication, `hello`
must precede normal extension messages. The companion rejects messages for a
different active tab/video and clears tabs, active media, queued ICE, rate
state, and authentication material on disconnect.

Each network connection retains at most one inbound message. The receive loop
does not request another frame until the MainActor finishes authenticating,
validating, and processing the current frame, bounding retained data to one
524,288-byte message per connection.

Offer, answer, and ICE messages carry a positive media-session `generation`.
Browser starts and stops advance the generation and check it after every
suspension point. The companion cancels the previous offer task and confirms
the owning client, tab, video, credential generation, and media generation
before accepting asynchronous results. Negotiation failure or a ten-second
answer timeout stops local media, restores the source mute state, and clears
ownership.

Central limits are intentionally generous for normal Float use:

| Resource | Limit |
| --- | ---: |
| WebSocket message | 524,288 bytes |
| title | 512 UTF-8 bytes |
| URL | 8,192 UTF-8 bytes |
| video ID | 256 UTF-8 bytes |
| tabs | 256 |
| videos per tab | 64 |
| SDP | 262,144 UTF-8 bytes |
| ICE candidate | 8,192 UTF-8 bytes |
| pending ICE candidates | 256 |
| debug/error payload | 16,384 UTF-8 bytes |
| total connections | 8 |
| unauthenticated connections | 4 |
| authentication attempts | 3 |
| state updates | 20/second, burst 40 |

Non-finite numbers, invalid dimensions/timestamps, oversized arrays or
strings, malformed JSON, unsupported versions, and invalid state transitions
close or reject the connection without recursive error generation.

## Dependency and runtime hardening

The abandoned WebRTC 95 package is replaced by the exact stable
`livekit/webrtc-xcframework` release `144.7559.11`, commit
`46f2af86f06b9a8a9158d37cadda5cb5a214e4c4`, SwiftPM checksum
`07c5caf718058af3c528dcabd257298c40e5a8527e4fb9f47c48336ba5899853`.
Its universal macOS slice exports the required raw `LKRTC` peer-connection,
audio/video track, and `LKRTCMTLVideoView` APIs for arm64 and x86_64.

Hardened Runtime is enabled without exception entitlements. App Sandbox and
the existing client/server networking entitlements remain. The WebRTC
framework must be embedded and signed as normal build content; library
validation is not weakened.
