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
