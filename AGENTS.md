# Float Repository Guide

## Overview
Float is a local browser-to-macOS Picture-in-Picture system:

- `chrome/`: Chromium MV3 extension that detects page videos, captures a selected source via `captureStream()`, and streams it over WebRTC.
- `companion/`: macOS menu bar app that runs local signaling and presents the stream in native PiP.

All signaling is local-only over `ws://127.0.0.1:17891`.

## Repository layout

### Extension (`/Users/maxnowack/code/float/chrome`)

- `/Users/maxnowack/code/float/chrome/manifest.json`: MV3 manifest, permissions, service worker, and content-script injection.
- `/Users/maxnowack/code/float/chrome/src/protocol.ts`: protocol constants + runtime type guards (`start`, `stop`, `offer`, `answer`, `ice`, `playback`, `error`, `debug`).
- `/Users/maxnowack/code/float/chrome/src/globals.d.ts`: global declarations for protocol helpers and `captureStream()`.
- `/Users/maxnowack/code/float/chrome/src/service_worker.ts`: background bridge between tabs and companion WebSocket, tab/frame state aggregation, tab mute/unmute lifecycle while streaming, signaling forwarding.
- `/Users/maxnowack/code/float/chrome/src/content_script.ts`: video discovery, candidate updates, WebRTC sender, debug probes, and playback control application (`float:playback`).

### Companion (`/Users/maxnowack/code/float/companion`)

- `/Users/maxnowack/code/float/companion/Float/FloatApp.swift`: menu bar app entry and status item interaction.
- `/Users/maxnowack/code/float/companion/Float/SignalingServer.swift`: localhost WebSocket server, protocol routing, active source tracking, playback command forwarding.
- `/Users/maxnowack/code/float/companion/Float/Protocol.swift`: Swift protocol models and message-type constants.
- `/Users/maxnowack/code/float/companion/Float/WebRTCReceiver.swift`: receiver interface, stub fallback, and factory.
- `/Users/maxnowack/code/float/companion/Float/NativeWebRTCReceiver.swift`: current receiver implementation backed by `WKWebView` bridge + private PiP integration.
- `/Users/maxnowack/code/float/companion/Float/receiver.html`: in-app WebRTC receiver page (RTCPeerConnection + hidden `<video>` + canvas surface + JS-to-Swift bridge).
- `/Users/maxnowack/code/float/companion/Float/Float.entitlements`: sandbox and network client/server permissions.

## Current architecture (important)

Companion receiving is currently WebKit-based:

1. Swift companion loads `receiver.html` into a `WKWebView`.
2. The page handles `RTCPeerConnection`, offer/answer, ICE, and remote track attachment.
3. JS posts events (`ready`, `localIce`, `videoSize`, `streaming`, `connectionState`, `error`) to Swift through `window.webkit.messageHandlers.floatReceiverBridge`.
4. Swift hosts that view controller inside private `PIP.framework` PiP (`PIPViewController`) and applies aspect ratio updates.
5. PiP playback controls trigger Swift callbacks, which are sent back to extension as protocol `playback` messages.

## End-to-end runtime flow

1. Content scripts scan each frame for eligible `<video>` elements and publish `float:videos:update`.
2. Service worker merges per-frame data into tab-level `state` and sends it to companion.
3. Companion status item reflects source availability; selecting a source sends `start {tabId, videoId}`.
4. Content script starts capture for that source, creates `RTCPeerConnection`, and sends `offer` + ICE.
5. Companion receiver returns `answer`; both sides exchange ICE until connected.
6. During active stream:
   - service worker mutes the source tab and restores mute state on stop/error.
   - companion can issue `playback {playing}` commands from PiP controls.
   - content script applies `play()` / `pause()` on the active source element.
7. On stop/disconnect/tab close, both sides tear down stream/signaling state and refresh availability.

## Build and run

Extension:

```bash
cd /Users/maxnowack/code/float/chrome
yarn install
yarn build
```

Companion:

```bash
xcodebuild -project /Users/maxnowack/code/float/companion/Float.xcodeproj -scheme Float -configuration Debug -sdk macosx build
```

Then load `/Users/maxnowack/code/float/chrome` as an unpacked extension and run the macOS app.

## Notes and caveats

- Protocol version is `1` on both sides.
- PiP uses private `PIP.framework` APIs; this is suitable for local/dev usage and may not be App Store-safe.
- `receiver.html` must be present in the app bundle at runtime for the WK receiver to initialize.
- Pairing/auth hardening is not implemented yet; signaling is trusted localhost.
