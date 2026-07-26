# Float security

## Reporting a vulnerability

Please do not open a public issue for an unpatched vulnerability. Use GitHub's
private vulnerability reporting for this repository, when available, or contact
the maintainer through the address published on their GitHub profile. Include
the affected Float version, macOS and browser versions, reproduction steps, and
whether the issue requires another local process or a remote website.

## Local threat model

Float accepts control and WebRTC signaling from a browser extension over a
local WebSocket. Loopback is a network-routing boundary, not an authentication
boundary: websites, other extensions, and local processes may attempt to reach
local ports.

Float therefore applies all of these controls:

- The companion binds only IPv4 `127.0.0.1:17891` and checks accepted peers
  again for an IPv4 loopback endpoint.
- The HTTP upgrade accepts one exact Chrome- or Firefox-extension `Origin` and
  one fresh, syntactically valid Float v2 WebSocket subprotocol.
- A 256-bit per-install secret is generated with `SecRandomCopyBytes`, kept in
  the macOS Keychain, and deliberately enrolled into each extension
  installation.
- Each connection must answer a fresh, expiring nonce with HMAC-SHA256 before
  Float processes state, media, playback, diagnostics, or error messages.
- Paired browser origins may remain authenticated concurrently, but a newer
  socket atomically replaces an older socket from the same exact origin. Their
  state is isolated, while media control is routed only to the client that owns
  the single active source.
- Protocol versions, connection state, message sizes, collections, rates,
  numbers, SDP, and ICE are validated against centralized limits.

The extension persists the pairing secret in background-owned IndexedDB. The
popup may save, remove, and query pairing status through trusted background
messages; its code never requests or receives the stored value. The manifests
grant no extension storage permission, the credential module is not loaded
into content scripts, and no credential-read message exists.

Enrollment temporarily places the long-lived secret on the macOS general
pasteboard. This is a residual local exposure, including to pasteboard monitors
and Universal Clipboard when enabled. Float labels the action as sensitive and
clears the value after successful authentication or 60 seconds, but only if the
pasteboard change count and value still match what Float wrote. A future
enrollment protocol should replace this interim shared-secret transfer with a
short-lived, single-use code and per-origin credentials.

Secrets, HMAC proofs, full SDP, full ICE candidates, page URLs, titles, and
identifiers are not emitted in Release logs.

The exact protocol and limits are documented in
[`docs/PROTOCOL_V2.md`](docs/PROTOCOL_V2.md).

## Platform boundary

The companion keeps App Sandbox and Hardened Runtime enabled. It has only the
existing client/server network and read-only user-selected-file capabilities.
It does not request camera, microphone, screen-recording, Accessibility, or
automation access, and it does not weaken library validation or executable
memory protections.

Float deliberately uses Apple's private `PIP.framework` to provide genuine
system Picture-in-Picture. Private APIs can change without compatibility
notice; this is a reliability and distribution risk, not an authentication
mechanism.

The WebRTC peer connection remains local and configures no STUN or TURN
servers. Browser `captureStream()` still exposes the source video's media to
the explicitly paired companion on the same Mac.

## Pairing recovery

Right-click the Float menu-bar icon:

- **Copy Sensitive Pairing Secret** copies the current secret for entry in the
  extension popup. Treat it like a password; Float clears an unchanged copy
  after successful authentication or 60 seconds.
- **Rotate Pairing Secret…** generates and stores a replacement, disconnects
  and synchronously revokes current clients, stops active media, and copies the
  replacement with the same clearing behavior. The prior secret stops working
  immediately.

Use **Remove pairing** in an extension popup before pairing that installation
again. Rotate the companion secret if it may have been disclosed.
