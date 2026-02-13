# AGENT_PLAN

## Goal & current phase
Build Float MVP incrementally. Milestones 1, 2, 3, and 4 are complete. Current phase is Milestone 5 (multi-tab / multi-video UX, status-item click behavior/icons) and Milestone 6 (allowlist + pairing hardening).

## Milestones
- [x] 1. Companion: WS server + menu bar UI that can display received state.
- [x] 2. Extension: detect videos and send `state` over WS.
- [x] 3. WebRTC minimal: extension sends track; companion renders it.
- [x] 4. True native macOS PiP.
- [ ] 5. Multi-tab / multi-video selection.
- [ ] 6. Allowlist + pairing.

## Working set
- Files touched in this phase:
  - `INSTRUCTIONS.md`
  - `AGENT_PLAN.md`
  - `AGENT_STATUS.md`
  - `chrome/src/content_script.ts`
  - `chrome/src/protocol.ts`
  - `chrome/src/service_worker.ts`
  - `chrome/src/globals.d.ts`
  - `companion/Float/NativeWebRTCReceiver.swift`
  - `companion/Float/SignalingServer.swift`
  - `companion/Float/Protocol.swift`
  - `companion/Float/WebRTCReceiver.swift`
  - `companion/Float/FloatApp.swift`
  - `companion/Float.xcodeproj/project.pbxproj`
  - `companion/Float.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- Commands used to build/run/test:
  - `yarn build` (in `chrome/`)
  - `xcodebuild -project /Users/maxnowack/code/float/companion/Float.xcodeproj -scheme Float -configuration Debug -sdk macosx build`

## Risks & unknowns
- Private `PIP.framework` API stability across macOS versions.
  - How we’ll validate: smoke-test start/stop/resize on each target macOS build before releases.
- Deprecated `AVSampleBufferDisplayLayer` APIs currently still used.
  - How we’ll validate: migrate to modern sample-buffer renderer APIs and compare latency/visual behavior.
- Non-`RTCCVPixelBuffer` frames are currently dropped.
  - How we’ll validate: implement fallback conversion path and test against sites/codecs that do not deliver CV-backed buffers.

## Next actions
- Manually validate new status-item UX:
  - left click stops PiP when already active
  - left click starts directly when exactly 1 source exists
  - left click shows source-only menu when 2+ sources exist
  - right click shows quit-only menu.
- Add selection persistence policy for multi-source sessions (last selected source per tab/domain).
- Implement Milestone 6 allowlist settings and enforce injection only on allowed domains.
- Implement Milestone 6 pairing token flow in extension options + companion Keychain lifecycle.
- Replace deprecated `AVSampleBufferDisplayLayer` queue/flush calls with modern APIs.
- Add fallback conversion for non-`RTCCVPixelBuffer` frames.

## Decision log
- 2026-02-13 11:55 CET: use fixed localhost WebSocket port `17891` for MVP.
- 2026-02-13 12:39 CET: requirement clarified: no PiP-like window; use true native macOS PiP only.
- 2026-02-13 13:47 CET: linked native WebRTC package (`alexpiezo/WebRTC`) and completed milestone 3 build path.
- 2026-02-13 18:30 CET: switched primary native PiP implementation to private `PIP.framework` (`PIPViewController.presentViewControllerAsPictureInPicture`) with AVKit fallback.
- 2026-02-13 18:58 CET: added private PiP aspect-ratio constraints (`setAspectRatio`, min/max size setters) so resize respects video ratio.
- 2026-02-13 19:06 CET: removed legacy CGWindow polling/render-size hint code and simplified `NativeWebRTCReceiver.swift`.
- 2026-02-13 19:21 CET: reduced lag via timebase synchronization, frame delivery coalescing/backpressure drop, and format-description caching.
- 2026-02-13 20:00 CET: switched companion UI from `MenuBarExtra` to explicit `NSStatusItem` controller with left-click direct start (1 source), source-only menu (2+), right-click quit menu, and count-based status icons.
- 2026-02-13 20:02 CET: updated primary click behavior to stop active PiP immediately (toggle semantics).

## Validation
- Companion build:
  - `xcodebuild -project /Users/maxnowack/code/float/companion/Float.xcodeproj -scheme Float -configuration Debug -sdk macosx build`
  - Outcome: `BUILD SUCCEEDED`.
- Extension build:
  - `yarn build` in `chrome/`
  - Outcome: TypeScript build succeeded.
- Runtime validation (manual):
  - Native PiP starts and displays streamed video.
  - Aspect-ratio lock during resize works.
  - Lag improved to near-realtime usability.
  - New status-item click UX pending manual validation.

## Manual acceptance steps
- [x] Open YouTube video and confirm companion icon shows available state.
- [x] Select video and confirm native PiP starts and plays.
- [x] Resize PiP and confirm aspect ratio remains locked.
- [x] Confirm lag is acceptable for near-realtime A/V sync.
- [ ] Left click with exactly one source starts PiP directly without opening a menu.
- [ ] Left click with multiple sources shows a source-only selection menu and starts PiP on selection.
- [ ] Left click while PiP is active stops floating immediately.
- [ ] Right click shows only `Quit Float`.
- [ ] Enter fullscreen VS Code and confirm PiP remains visible.
- [ ] Verify multi-tab/multi-video selection and switching behavior.
- [ ] Verify allowlist and pairing flows end-to-end.

## Known pitfalls regression checklist
- [ ] YouTube video element replacement during navigation.
- [ ] iframe / `frameId` routing correctness.
- [ ] missing audio track handling.
- [ ] gesture requirement regressions for capture start.
- [ ] DRM heuristics and graceful failure UX.
