# AGENT_PLAN

## Goal & current phase
Build Float MVP incrementally. Milestones 1 and 2 are complete (companion WS/menu + extension detection/state bridge). Current phase is Milestone 3: minimal WebRTC sender/receiver path between extension and companion.

## Milestones
- [x] 1. Companion: WS server + menu bar UI that can display received state.
- [x] 2. Extension: detect videos and send `state` over WS.
- [ ] 3. WebRTC minimal: extension sends track; companion renders it.
- [ ] 4. True native macOS PiP via `AVPictureInPictureController`.
- [ ] 5. Multi-tab / multi-video selection.
- [ ] 6. Allowlist + pairing.

## Working set
- Files touched in this phase:
  - `AGENT_PLAN.md`
  - `AGENT_STATUS.md`
  - `chrome/manifest.json`
  - `chrome/package.json`
  - `chrome/yarn.lock`
  - `chrome/tsconfig.json`
  - `chrome/src/globals.d.ts`
  - `chrome/src/protocol.ts`
  - `chrome/src/content_script.ts`
  - `chrome/src/service_worker.ts`
  - `chrome/dist/*`
- Commands used to build/run/test:
  - `yarn install` (in `chrome/`)
  - `yarn build` (in `chrome/`)
  - `xcodebuild -project companion/Float.xcodeproj -scheme Float -configuration Debug -derivedDataPath /tmp/float-derived CODE_SIGNING_ALLOWED=NO build`

## Risks & unknowns
- Content script currently injects on `<all_urls>`; allowlist control is not implemented yet.
  - How we'll validate: implement options-based allowlist in Milestone 6 and verify skipped injection on blocked domains.
- WS reconnect behavior is implemented but not manually chaos-tested with frequent companion restarts.
  - How we'll validate: restart companion repeatedly while videos are playing and verify state reappears.
- Start/stop messages are routed but WebRTC capture path is not wired, so menu actions do not yet start playback.
  - How we'll validate: complete Milestone 3 and verify start initiates track flow.

## Next actions
- Add extension-side WebRTC offer flow in page context for selected `videoId`.
- Add companion-side `offer`/`answer`/`ice` handling in signaling server and receiver scaffolding.
- Implement frame bridge from WebRTC video output to `AVSampleBufferDisplayLayer` and drive `AVPictureInPictureController`.
- Introduce protocol-level parse validation for all signaling messages beyond `hello/state/start/stop`.
- Add debug logs for WS traffic on extension side behind a flag.
- Run manual integration check: companion running + extension loaded unpacked + YouTube state visible in menu.

## Decision log
- 2026-02-13 11:55 CET: use fixed localhost WebSocket port `17891` for MVP to simplify extension-side connection.
- 2026-02-13 11:55 CET: use a lightweight in-process WS server via `Network.framework` with explicit frame parsing for Milestone 1.
- 2026-02-13 11:55 CET: convert companion shell to `MenuBarExtra` to match menu-bar-first product UX.
- 2026-02-13 12:00 CET: keep extension scripts in script-mode TypeScript (`module: none`) and share constants via `chrome/src/protocol.ts` loaded globally.
- 2026-02-13 12:39 CET: Milestone 4 requirement updated by user: do not ship PiP-like custom window; ship true native macOS PiP only.

## Validation
- Milestone 1:
  - Ran `xcodebuild -project companion/Float.xcodeproj -scheme Float -configuration Debug -derivedDataPath /tmp/float-derived CODE_SIGNING_ALLOWED=NO build`.
  - Outcome: `BUILD SUCCEEDED`.
  - Note: `CODE_SIGNING_ALLOWED=NO` is required in this environment because signing assets are unavailable.
- Milestone 2:
  - Ran `yarn install` in `chrome/`.
  - Ran `yarn build` in `chrome/`.
  - Outcome: TypeScript build succeeded and emitted `chrome/dist` scripts for MV3.

## Manual acceptance steps
- [ ] Open YouTube video and confirm companion icon shows available state.
- [ ] Select video and confirm float action sends `start` request.
- [ ] Confirm app indicates waiting/connected/error states in menu.

## Known pitfalls regression checklist
- [ ] YouTube video element replacement.
- [ ] iframes/frameId issues.
- [ ] missing audio track.
- [ ] gesture requirements.
- [ ] DRM heuristics.
