# Float Repository Guide

## What this repo is
Float is a local two-part system for turning a browser video into a native macOS Picture-in-Picture stream that can stay visible across Spaces/fullscreen apps.

- `chrome/`: Chromium extension (Manifest V3, TypeScript) that detects candidate videos and captures a selected one with `captureStream()`.
- `companion/`: macOS menu bar app (Swift/SwiftUI + AppKit) that receives the WebRTC stream and renders it in native PiP.

## Top-level structure

- `chrome/manifest.json`: extension permissions, content script wiring, background service worker entry.
- `chrome/src/content_script.ts`: video discovery, candidate updates, WebRTC sender (`offer`/`ice`), stream lifecycle.
- `chrome/src/service_worker.ts`: localhost WebSocket client (`ws://127.0.0.1:17891`), tab/frame state aggregation, signaling bridge to companion.
- `chrome/src/protocol.ts`: shared protocol constants and runtime type guards for protocol messages.
- `companion/Float/FloatApp.swift`: app entry, status bar item behavior, source-selection/quit menus.
- `companion/Float/SignalingServer.swift`: localhost WebSocket server, protocol routing, source model for UI, start/stop commands.
- `companion/Float/Protocol.swift`: Swift protocol models (`hello`, `state`, `start`, `offer`, `answer`, `ice`, `stop`, `error`, `debug`).
- `companion/Float/WebRTCReceiver.swift`: receiver abstraction + stub fallback.
- `companion/Float/NativeWebRTCReceiver.swift`: native WebRTC peer connection, frame conversion to `CMSampleBuffer`, PiP controller integration.
- `INSTRUCTIONS.md`: product goals and implementation plan.
- `AGENT_PLAN.md` / `AGENT_STATUS.md`: progress log and milestone tracking.

## Runtime data flow

1. Content script scans each frame for eligible `<video>` elements and reports candidates to the service worker (`float:videos:update`).
2. Service worker merges per-frame state by tab and pushes `state` messages to the companion over WebSocket.
3. Companion status item reflects source availability and can request start/stop (`start` / `stop`) back to the extension.
4. On `start`, content script finds the selected video, captures media, creates `RTCPeerConnection`, sends `offer` and ICE candidates.
5. Companion `SignalingServer` forwards signaling to `NativeWebRTCReceiver`, returns `answer`, and relays local ICE.
6. Companion converts incoming WebRTC frames to sample buffers and renders them through native PiP.
7. On stop/disconnect/tab close, both sides tear down peer/media state and refresh source availability.

## Build and run

Extension:

```bash
cd chrome
yarn install
yarn build
```

Companion:

```bash
xcodebuild -project companion/Float.xcodeproj -scheme Float -configuration Debug -sdk macosx build
```

Then load `chrome/` as an unpacked extension in Chromium and run the macOS app from Xcode/build output.

## Important implementation notes

- Signaling is local-only via `127.0.0.1:17891`.
- Protocol version is currently `1` on both extension and companion.
- The companion uses private `PIP.framework` APIs when available, with AVKit sample-buffer PiP fallback.
- `NativeWebRTCReceiver.swift` contains extensive PiP/debug instrumentation; expect verbose logs when debug flags are enabled.
- Pairing/auth hardening and allowlist work are tracked in milestone docs but not fully implemented.
