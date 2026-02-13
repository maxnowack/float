# AGENT_PLAN

## Goal & current phase
Build Float MVP incrementally. Milestones 1, 2, and 3 are complete. Current phase is Milestone 4 (true native macOS PiP via `AVPictureInPictureController`).

## Milestones
- [x] 1. Companion: WS server + menu bar UI that can display received state.
- [x] 2. Extension: detect videos and send `state` over WS.
- [x] 3. WebRTC minimal: extension sends track; companion renders it.
- [ ] 4. True native macOS PiP via `AVPictureInPictureController`.
- [ ] 5. Multi-tab / multi-video selection.
- [ ] 6. Allowlist + pairing.

## Working set
- Files touched in this phase:
  - `AGENT_PLAN.md`
  - `AGENT_STATUS.md`
  - `INSTRUCTIONS.md`
  - `chrome/src/content_script.ts`
  - `chrome/src/globals.d.ts`
  - `chrome/src/protocol.ts`
  - `chrome/src/service_worker.ts`
  - `chrome/dist/*`
  - `companion/Float/FloatApp.swift`
  - `companion/Float/Protocol.swift`
  - `companion/Float/SignalingServer.swift`
  - `companion/Float/WebRTCReceiver.swift`
  - `companion/Float/NativeWebRTCReceiver.swift`
  - `companion/Float.xcodeproj/project.pbxproj`
  - `companion/Float.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- Commands used to build/run/test:
  - `yarn build` (in `chrome/`)
  - `xcodebuild -project companion/Float.xcodeproj -scheme Float -configuration Debug -derivedDataPath /tmp/float-derived -clonedSourcePackagesDirPath /tmp/float-spm CODE_SIGNING_ALLOWED=NO build`

## Risks & unknowns
- Native PiP requirement depends on frame conversion path quality (`RTCVideoFrame -> CMSampleBuffer`).
  - How we'll validate: verify smooth native PiP playback and A/V sync on YouTube for >= 10 minutes.
- Extension currently injects on `<all_urls>`; allowlist is still not implemented.
  - How we'll validate: implement options allowlist and verify injection blocked on disallowed domains.

## Next actions
- Implement video frame bridge to `AVSampleBufferDisplayLayer` for native PiP integration.
- Implement native PiP controller lifecycle (`AVPictureInPictureController`) bound to stream lifecycle.
- Run end-to-end test: menu start action -> media appears in native PiP.

## Decision log
- 2026-02-13 11:55 CET: use fixed localhost WebSocket port `17891` for MVP to simplify extension-side connection.
- 2026-02-13 11:55 CET: use `Network.framework` native WebSocket listener in companion.
- 2026-02-13 12:00 CET: keep extension scripts in script-mode TypeScript (`module: none`) and share constants via `chrome/src/protocol.ts` loaded globally.
- 2026-02-13 12:39 CET: Milestone 4 requirement updated by user: no PiP-like window; true native macOS PiP only.
- 2026-02-13 13:14 CET: added conditional native receiver implementation (`#if canImport(WebRTC)`) and factory auto-selection.
- 2026-02-13 13:47 CET: linked `alexpiezo/WebRTC` Swift package to companion target; native receiver now compiles and Milestone 3 is complete.

## Validation
- Companion builds:
  - `xcodebuild -project companion/Float.xcodeproj -scheme Float -configuration Debug -derivedDataPath /tmp/float-derived -clonedSourcePackagesDirPath /tmp/float-spm CODE_SIGNING_ALLOWED=NO build`
  - Outcome: `BUILD SUCCEEDED`.
- Extension builds:
  - `yarn build` in `chrome/`
  - Outcome: TypeScript build succeeded and emitted `chrome/dist` scripts.

## Manual acceptance steps
- [ ] Open YouTube video and confirm companion icon shows available state.
- [ ] Select video and confirm WebRTC stream renders in companion (current debug render surface).
- [ ] Milestone 4: confirm native macOS PiP starts and plays.
- [ ] Milestone 4: enter fullscreen VS Code and confirm native PiP remains visible.
- [ ] Confirm app indicates waiting/connected/error states in menu.

## Known pitfalls regression checklist
- [ ] YouTube video element replacement.
- [ ] iframes/frameId issues.
- [ ] missing audio track.
- [ ] gesture requirements.
- [ ] DRM heuristics.
