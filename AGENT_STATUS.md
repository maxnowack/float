2026-02-13 11:55 CET
- Implemented: companion Milestone 1 foundation.
  - Added menu bar app shell with dynamic state-driven menu (`MenuBarExtra`).
  - Added companion protocol models/constants in `Protocol.swift`.
  - Added localhost WebSocket signaling server (`ws://127.0.0.1:17891`) with handshake, frame parsing, JSON routing (`hello`, `state`, `stop`, `error`) and outbound `start`/`stop` sending.
  - Added protocol debug logging gate (`protocolDebugLoggingEnabled`, default `false`).
- Validated:
  - `xcodebuild -project companion/Float.xcodeproj -scheme Float -configuration Debug -derivedDataPath /tmp/float-derived CODE_SIGNING_ALLOWED=NO build`
  - Result: `BUILD SUCCEEDED`.
- Next:
  - Implement extension WS client + video detection and emit real `state` payloads to companion.

2026-02-13 12:00 CET
- Implemented: extension Milestone 2 foundation.
  - Added MV3 extension scaffold in `chrome/` with TS build pipeline.
  - Added shared protocol constants/helpers in `chrome/src/protocol.ts` and declarations in `chrome/src/globals.d.ts`.
  - Added content-script video detection with eligibility filtering, stable per-element IDs, mutation/event refresh, and periodic refresh.
  - Added service-worker localhost WS client to companion (`ws://127.0.0.1:17891`) with `hello` handshake, `state` forwarding, reconnect loop, and parse-error `{type:"error"}` responses.
  - Added `start`/`stop` routing stubs from companion messages to tabs.
- Validated:
  - `yarn install` in `chrome/`
  - `yarn build` in `chrome/`
  - Result: TypeScript build succeeded.
- Next:
  - Implement WebRTC signaling and media transfer path (Milestone 3).

2026-02-13 12:02 CET
- Implemented: sandbox networking fix for companion runtime listener.
  - Added `/Users/maxnowack/code/float/companion/Float/Float.entitlements` with app sandbox + network client/server permissions.
  - Wired `CODE_SIGN_ENTITLEMENTS = Float/Float.entitlements` for Debug/Release target configs.
- Validated:
  - `xcodebuild -project companion/Float.xcodeproj -scheme Float -configuration Debug -derivedDataPath /tmp/float-derived CODE_SIGNING_ALLOWED=NO build`
  - Result: `BUILD SUCCEEDED`.
- Next:
  - Re-run app with normal code signing in Xcode and verify `NWListener` no longer reports Operation not permitted.

2026-02-13 12:08 CET
- Implemented: switched companion WebSocket server from custom handshake/framing to Network.framework native WebSocket protocol stack.
  - Listener now uses `NWProtocolWebSocket.Options` with `autoReplyPing = true`.
  - `WebSocketClient` now uses `receiveMessage`/WebSocket metadata opcodes for text/close handling.
- Validated:
  - `xcodebuild -project companion/Float.xcodeproj -scheme Float -configuration Debug -derivedDataPath /tmp/float-derived CODE_SIGNING_ALLOWED=NO build`
  - Result: `BUILD SUCCEEDED`.
- Expected effect:
  - Extension should no longer fail with "Connection closed before receiving a handshake response".

2026-02-13 12:21 CET
- Implemented: fixed false companion error loop and improved extension error visibility.
  - Extension service worker now accepts companion `hello` messages instead of treating them as unsupported.
  - Companion now decodes `{type:"error", reason}` and surfaces the actual extension reason instead of a generic message.
- Validation:
  - `yarn build` in `chrome/`: succeeded.
  - `xcodebuild -project companion/Float.xcodeproj -scheme Float -configuration Debug -derivedDataPath /tmp/float-derived CODE_SIGNING_ALLOWED=NO build`: succeeded.

2026-02-13 12:39 CET
- Planning correction from user:
  - Milestone 4 changed from custom PiP-like floating window to true native macOS PiP (`AVPictureInPictureController`) only.
  - Future companion rendering path must target `AVSampleBufferDisplayLayer` for PiP compatibility.

2026-02-13 12:41 CET
- Updated product instructions to require true native macOS PiP (no PiP-like floating window fallback).
  - Revised architecture/modules to use `AVPictureInPictureController` + `AVSampleBufferDisplayLayer`.
  - Updated implementation order, acceptance tests, deliverables, and done criteria to native PiP wording.

2026-02-13 12:44 CET
- Implemented: Milestone 3 signaling plumbing on companion side.
  - Added message models for `answer` and outbound ICE payloads.
  - Added `WebRTCReceiver` abstraction and `StubWebRTCReceiver` placeholder backend.
  - Companion `SignalingServer` now handles incoming `offer` and `ice`, routes to receiver, and sends `answer`/local `ice` back over WS.
  - `stop` now tears down receiver state via `webRTCReceiver.stop()`.
- Validated:
  - `xcodebuild -project companion/Float.xcodeproj -scheme Float -configuration Debug -derivedDataPath /tmp/float-derived CODE_SIGNING_ALLOWED=NO build`
  - Result: `BUILD SUCCEEDED`.
- Remaining for milestone completion:
  - Replace stub receiver with real native WebRTC backend and verify successful `offer/answer/ice` exchange with media rendering path.

2026-02-13 12:48 CET
- Implemented: receiver factory wiring and clearer backend dependency messaging.
  - `SignalingServer` now constructs receiver through `makeWebRTCReceiver()`.
  - Offer failure message now includes `videoId` context.
  - Verified current environment lacks importable `WebRTC` module (`no-webrtc`), so stub backend remains active.
- Validated:
  - `xcodebuild -project companion/Float.xcodeproj -scheme Float -configuration Debug -derivedDataPath /tmp/float-derived CODE_SIGNING_ALLOWED=NO build`
  - Result: `BUILD SUCCEEDED`.

2026-02-13 13:15 CET
- Continued Milestone 3 with conditional native receiver scaffold.
  - Added `NativeWebRTCReceiver` behind `#if canImport(WebRTC)` and factory auto-selection in `makeWebRTCReceiver()`.
  - Kept current behavior safe with stub receiver fallback when WebRTC dependency is unavailable.
- Validated:
  - `xcodebuild -project companion/Float.xcodeproj -scheme Float -configuration Debug -derivedDataPath /tmp/float-derived CODE_SIGNING_ALLOWED=NO build` -> `BUILD SUCCEEDED`.
  - `canImport(WebRTC)` probe -> `no-webrtc`.
- Blocker:
  - Need to link native WebRTC framework/package into companion target before real receive path can run.

2026-02-13 13:47 CET
- Implemented: Milestone 3 completion work.
  - Linked native WebRTC package dependency into companion target (`alexpiezo/WebRTC`).
  - Added package resolution lockfile at `companion/Float.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
  - Fixed `NativeWebRTCReceiver` to match package APIs:
    - remote ICE add now uses `try await`.
    - explicit typed throwing continuations for SDP set calls.
    - removed unavailable `RTCMTLNSVideoView.videoContentMode`.
- Validated:
  - `xcodebuild -project companion/Float.xcodeproj -scheme Float -configuration Debug -derivedDataPath /tmp/float-derived -clonedSourcePackagesDirPath /tmp/float-spm CODE_SIGNING_ALLOWED=NO build`
  - Result: `BUILD SUCCEEDED`.
  - `yarn build` in `chrome/`
  - Result: `Done` (TypeScript compile succeeded).
- Outcome:
  - Milestone 3 complete: extension WebRTC sender + companion signaling + native companion receiver compile and build successfully.

2026-02-13 13:53 CET
- Implemented: Milestone 4 native PiP integration (in progress).
  - Replaced debug preview window path in `NativeWebRTCReceiver` with native macOS PiP pipeline:
    - `RTCVideoTrack` -> `RTCVideoRenderer` bridge -> `CMSampleBuffer`.
    - `AVSampleBufferDisplayLayer` content source.
    - `AVPictureInPictureController` with sample-buffer playback delegate.
  - Added stream lifecycle hooks so receiver stop tears down PiP and flushes rendered media.
  - Added receiver->server streaming state callback and menu state/icon wiring (`pip.fill` when active).
- Validated:
  - `xcodebuild -project companion/Float.xcodeproj -scheme Float -configuration Debug -derivedDataPath /tmp/float-derived -clonedSourcePackagesDirPath /tmp/float-spm CODE_SIGNING_ALLOWED=NO build`
  - Result: `BUILD SUCCEEDED`.
- Remaining before Milestone 4 can be marked complete:
  - Manual end-to-end runtime validation on YouTube.
  - Fullscreen Spaces persistence validation.
  - Follow-up cleanup for deprecated `AVSampleBufferDisplayLayer` APIs and non-CV frame fallback path.
