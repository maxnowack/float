# Float local protocol v2

Float v2 is JSON over a WebSocket at `ws://127.0.0.1:17891`. Every JSON message
contains `"version": 2`.

## Upgrade and Origin binding

The extension offers exactly one subprotocol:

```text
float-v2.<22-character unpadded base64url token>
```

The token represents 128 random bits and is new for every connection. The
companion accepts the upgrade only when:

- there is exactly one `Origin` header;
- the Origin is exactly `chrome-extension://` plus a 32-character Chrome ID, or
  `moz-extension://` plus a UUID;
- it has no credentials, port, path, query, or fragment; and
- the offered subprotocol is the one valid Float v2 token.

The companion records the exact Origin against that short-lived token and
consumes the record when Network.framework reports the selected subprotocol on
the accepted connection. Missing, `null`, `http`, `https`, `file`, malformed,
and path-bearing origins receive a rejected HTTP upgrade.

## Authentication

The companion sends:

```json
{
  "type": "authChallenge",
  "version": 2,
  "origin": "chrome-extension://…",
  "nonce": "<32 random bytes as unpadded base64url>"
}
```

The extension verifies the Origin equals its own background origin, then sends:

```json
{
  "type": "authResponse",
  "version": 2,
  "proof": "<HMAC-SHA256 as unpadded base64url>"
}
```

The HMAC key is the raw 32-byte pairing secret. Its canonical input is UTF-8:

```text
Float-Pairing-V2
version=2
origin=<exact Origin>
nonce=<unpadded base64url nonce>
```

There is exactly one LF after the nonce line. The companion compares the
32-byte proof in constant time. A nonce expires after 10 seconds and is
single-use, including after an invalid proof. Malformed responses get at most
three attempts. On success the companion sends:

```json
{"type":"authResult","version":2,"authenticated":true}
```

The shared fixture is
[`protocol/test-vectors/hmac-v2.json`](../protocol/test-vectors/hmac-v2.json).

## Connection state

```text
HTTP upgrade -> challenged -> awaiting hello -> ready -> closed
```

- Only `authResponse` is accepted while challenged.
- Only `hello` is accepted immediately after authentication.
- Normal application messages are accepted only when ready.
- A second `hello`, replayed `authResponse`, wrong active media target, or
  unsupported message closes the connection.
- Authenticated connections with different exact Origins may coexist up to the
  total connection limit. A successful connection atomically replaces and
  closes an older connection from the same Origin. Each retained connection
  has independent tabs, protocol state, counters, and pending ICE.
- Only one connection may own the active media source. Media signaling and
  playback commands are routed to that connection.
- Disconnect clears that connection's state and stops media if it owned the
  active source. Credential rotation synchronously revokes every context and
  credential generation before closing sockets and clearing media state.
- The companion receives only one frame per connection at a time and requests
  the next frame only after processing completes.

## Application messages

Extension to companion:

- `hello`
- `state { tabs[] }`
- `offer { tabId, videoId, generation, sdp }`
- `ice { tabId, videoId, generation, candidate, sdpMid?, sdpMLineIndex? }`
- `stop`
- `error { reason?, tabId?, videoId? }`
- `debug { source?, event?, tabId?, frameId?, url?, payload? }` in Debug use

Companion to extension:

- `hello`
- `start { tabId, videoId }`
- `answer { tabId, videoId, generation, sdp }`
- `ice { tabId, videoId, generation, candidate, sdpMid?, sdpMLineIndex? }`
- `stop`
- `playback { tabId, videoId, playing }`
- `seek { tabId, videoId, intervalSeconds }`
- `qualityHint { tabId, videoId, profile, pipWidth?, pipHeight? }`
- `autoStartBackground { enabled }`
- `autoStopForeground { enabled }`

## Limits

| Resource | Limit |
| --- | ---: |
| WebSocket message | 524,288 bytes |
| Title | 512 UTF-8 bytes |
| URL | 8,192 UTF-8 bytes |
| Video ID | 256 UTF-8 bytes |
| Tabs | 256 |
| Videos per tab | 64 |
| SDP | 262,144 UTF-8 bytes |
| ICE candidate | 8,192 UTF-8 bytes |
| Pending/received ICE candidates | 256 |
| Debug/error content | 16,384 UTF-8 bytes |
| Total connections | 8 |
| Unauthenticated connections | 4 |
| Authentication attempts | 3 |
| State updates | 20/second, burst 40 |
| JSON nesting | 16 levels |
| JSON values | 4,096 |
| Connection establishment | 5 seconds |
| Authentication | 10 seconds |

Messages with invalid versions, types, state, bounds, non-finite numbers, or
invalid timestamps are rejected. WebSocket close code `1008` denotes policy or
authentication failure, `1009` denotes an oversized message, and `1011`
denotes an unavailable companion credential.

`generation` is a positive integer no greater than 2,147,483,647. Each browser
start and stop invalidates older media work. Answers, candidates, errors, and
stop acknowledgements for a stale client/tab/video/generation tuple are
discarded. Pending pre-authentication application messages are bounded by both
256 entries and 524,288 serialized bytes; state is coalesced, only the current
offer and its ICE survive, and debug messages are not queued.
