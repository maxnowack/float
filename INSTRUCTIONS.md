# Float — AI Agent Build Instructions

> Goal: Build **Float**, a Chromium extension + macOS companion app that lets users pop out any playing web video into a **native macOS Picture‑in‑Picture**-style always-visible mini player that stays visible while switching into fullscreen apps/Spaces (e.g., VS Code fullscreen).

This repository has:

* `chrome/` — Chrome/Chromium extension (Manifest V3)
* `companion/` — macOS companion app (Xcode project already scaffolded)

This document tells an AI agent how to implement the product end-to-end.

---

## 0) Product requirements

### Must-have

* Works with Chromium-based browsers (tested with Helium Chromium).
* User can pop out a currently playing video from a tab into the macOS companion.
* Pop-out window stays visible while user is in fullscreen Spaces (VS Code / Terminal fullscreen).
* Works at least on **YouTube**, and should be generalizable to other sites.
* Preserves in-browser behavior such as SponsorBlock skips (i.e., the popped-out playback must reflect seeks/skips performed by the webpage).
* Menu bar app UX:

  * Menu bar icon indicates whether at least one eligible video is detected.
  * Clicking icon shows a list of candidate videos (tab title + domain + maybe video title) and allows selecting one to pop out.

### Nice-to-have

* Per-site allowlist from extension settings.
* Multiple video sources per page (e.g., picture-in-picture for a specific `<video>` element).
* Keyboard shortcut for “Pop out current tab video”.
* Resizable player, aspect-ratio locked.

### Non-goals (initially)

* DRM-protected streams (may fail; handle gracefully).
* Full remote-control of YouTube UI from the PiP window.

---

## 1) High-level architecture

Float consists of 3 cooperating pieces:

1. **Extension UI + background** (MV3 service worker)
2. **Content script + page script** (runs on allowed sites to detect and capture the playing `<video>`)
3. **Companion macOS app** (menu bar + native PiP window + WebRTC receiver)

### Core technical approach

* Capture the **actual playing video element** in the page using `HTMLMediaElement.captureStream()`.
* Send the resulting `MediaStream` to the companion app via **WebRTC**.

  * WebRTC provides A/V sync, low latency, and hardware acceleration.
* Use a local **signaling channel** between extension and companion:

  * `ws://127.0.0.1:<port>` WebSocket server hosted by the companion app.
  * The extension connects to that WS and exchanges SDP offers/answers + ICE candidates.

Rationale:

* An extension cannot make Chromium’s PiP window float above fullscreen Spaces. A native window can.
* Streaming the already-playing element means any skips/seeks (SponsorBlock, user seeking) are reflected.

---

## 2) Security & privacy constraints

* Everything stays **local** (localhost only). No remote servers.
* Companion WS server binds to `127.0.0.1` only.
* Use a per-install random token to authenticate the extension ↔ companion connection.

  * Token stored in companion Keychain.
  * Extension stores token in `chrome.storage.local` after pairing.
* The extension should require an explicit user gesture to start capture.
* If no pairing token exists, companion app shows a one-time pairing code.

---

## 3) Repository layout & conventions

### Chrome extension (`chrome/`)

Implement the Chromium extension in TypeScript (not plain JS). Keep it lightweight: minimal build tooling, typed end-to-end.

* `manifest.json` (MV3)
* `service_worker.js`
* `content_script.js`
* `page_injected.js` (injected into page context to access `<video>` and call `captureStream()` reliably)
* `ui/` (optional) for popup/options page

### Companion app (`companion/`)

* Swift / SwiftUI recommended
* Menu bar app (NSStatusItem)
* Modules:

  * `SignalingServer` (WebSocket)
  * `WebRTCReceiver` (receives track, renders)
  * `PiPWindowController` (native always-on-top window)
  * `Pairing` (token)

---

## 4) Companion app implementation plan (macOS)

### 4.1 Menu bar UX

Float is primarily a **menu bar app**.

Status item behavior

* Create an `NSStatusItem` with a template icon.
* The icon must communicate state at a glance (your requirement: icon changes when a video is detected):

  * **Idle**: no eligible videos detected anywhere → neutral/monochrome.
  * **Detected**: at least one eligible video detected → visually distinct (e.g., filled variant or badge dot).
  * **Streaming**: actively receiving a stream → distinct active state (badge/alternate symbol).
  * **Error**: pairing missing / extension disconnected / stream failure → warning badge and an explanatory menu item.

> Prefer swapping the icon asset (idle/detected/streaming) rather than relying on tinting, which can be inconsistent for status items across appearances.

Click / menu contents

Clicking the menu bar icon opens a menu that:

1. **Available videos**

* If **one** video is detected, show a primary action:

  * `Float “<Tab Title>”` (or best-effort video title)
* If **multiple** videos are detected, show a selectable list. Each item must include:

  * **Tab title** (required)
  * **Domain** (required)
  * Optional: best-effort **video title/channel**
  * Optional: state markers (Playing/Paused, Muted, Resolution)
* Selecting an item immediately starts floating that specific `videoId`.

2. **When streaming**

* `Stop Floating`
* Optional: `Mute/Unmute`
* Optional: size presets (Small/Medium/Large)

3. **Site allow/deny controls** (your requirement: user decides which sites to allow)

* `Allowed Sites…` (opens settings UI / extension options)
* Optional quick actions for the currently selected tab’s domain:

  * `Allow <domain>` / `Block <domain>`

4. **Pairing / status**

* If not paired: `Pair Extension…` (shows pairing code/QR)
* If paired but extension not connected: show `Waiting for extension…`

5. **Help / debug (optional)**

* `Copy diagnostics` (local-only)

Menu data source

* The extension pushes a `state` payload over WebSocket describing all detected candidates.
* The companion keeps an in-memory model of candidates and rebuilds the menu on updates.

4.2 WebSocket signaling server

* Use `Network.framework` or a lightweight WS library (e.g., SwiftNIO WebSocket).
* Bind to `127.0.0.1` and a fixed port (e.g., 17891) OR dynamic port with discovery.
* Protocol: JSON messages.

#### Message types

* `hello` — extension → companion (includes auth token)
* `state` — extension → companion (available videos list)
* `start` — companion → extension (request start streaming for a selected video id)
* `offer` / `answer` — SDP exchange
* `ice` — ICE candidates
* `stop` — either direction
* `error` — either direction

### 4.3 WebRTC receiver

* Use Google WebRTC native framework for macOS.

  * Add via Swift Package Manager if available, or via prebuilt framework.
* Create `RTCPeerConnection` configured for localhost.
* On receiving a video track:

  * Render into a view using `RTCMTLVideoView` (Metal) for performance.
* On receiving audio:

  * play via WebRTC audio engine.

### 4.4 “Native PiP” requirement

Be precise: Apple’s **system PiP** (`AVPictureInPictureController`) is designed around `AVPlayerLayer` / `AVSampleBufferDisplayLayer`. WebRTC renderers don’t automatically fit.

For an MVP that satisfies the user’s requirement (“visible across fullscreen Spaces”), implement a **native always-on-top panel** that behaves like PiP:

* Use `NSPanel` or borderless `NSWindow`.
* Set:

  * `level = .floating` (or `.statusBar` if needed)
  * `collectionBehavior` includes:

    * `.canJoinAllSpaces`
    * `.fullScreenAuxiliary`
    * `.stationary`
  * `isMovableByWindowBackground = true`
  * rounded corners, shadow

This yields the *behavioral* PiP requirement (stays visible across fullscreen apps).

Optional later: true system PiP

* To integrate `AVPictureInPictureController`, convert WebRTC frames into `CMSampleBuffer` and enqueue into `AVSampleBufferDisplayLayer`, then wrap with PiP controller. This is significantly more work; postpone until MVP is stable.

### 4.5 Video selection UI

* The status item menu lists candidates:

  * `Tab Title — Domain`
  * optional: `Video Title`
* Selecting an item sends `start` with `videoId`.
* Provide `Stop` action.

### 4.6 Pairing flow

* On first run, generate token and store in Keychain.
* Show “Pair extension” menu item.
* Display token as QR code or short code.
* Extension options page asks for pairing code.

---

## 5) Extension implementation plan (Chrome/Chromium)

### 5.1 Manifest (MV3)

* Permissions:

  * `storage`
  * `scripting`
  * `activeTab`
  * `tabs`
  * `alarms` (optional)
* Host permissions:

  * default minimal, plus allowlist patterns configured by user

### 5.2 Site allowlist

* Options page where user can add domains/patterns.
* Only inject content scripts on allowlisted sites.

### 5.3 Detecting eligible video(s)

In `content_script.js`:

* Enumerate `<video>` elements.
* Determine eligibility:

  * readyState >= 2
  * currentTime > 0 OR not paused
  * videoWidth/Height > 0
* Create stable identifiers per element:

  * `videoId = hash(tabId + frameId + nthVideo + creationTimestamp)`

Send availability updates to the service worker, which forwards via WS to companion.

### 5.4 Starting a stream

When companion requests `start(videoId)`:

* content script injects `page_injected.js` into the page context.
* page script finds the target `<video>`.
* call `captureStream()`
* create `RTCPeerConnection` and add tracks.
* create offer, send via service worker to companion.

Important:

* This must happen in response to a user gesture if required. Because the user clicks in the companion menu bar, bridge that event into the extension as a user gesture by:

  * also exposing a browser action / command that the user triggers, OR
  * keep a small extension popup that the user clicks.

MVP workaround:

* Use a keyboard shortcut `Cmd+Shift+P` bound to “Pop out current tab video” (user gesture within browser).
* The menu bar app can still show state, but “start” requires the user to hit the shortcut.

(After MVP, attempt to initiate capture without gesture and see if it works on target setups; document behavior.)

### 5.5 Signaling transport

* The service worker maintains a single WS connection to the companion.
* Routes messages between:

  * companion ↔ tab content scripts
  * companion ↔ active peer connection

---

## 6) Protocol details (JSON)

### 6.1 State message

```json
{
  "type": "state",
  "tabs": [
    {
      "tabId": 123,
      "title": "YouTube — Video Title",
      "url": "https://www.youtube.com/watch?v=...",
      "videos": [
        {
          "videoId": "abc",
          "playing": true,
          "muted": false,
          "resolution": "1920x1080"
        }
      ]
    }
  ]
}
```

### 6.2 Start

```json
{ "type": "start", "tabId": 123, "videoId": "abc" }
```

### 6.3 WebRTC

* `offer`, `answer` contain SDP strings
* `ice` contains candidate + sdpMid + sdpMLineIndex

---

## 7) Testing plan

### Environments

* macOS Tahoe
* Helium Chromium (primary)
* Optional: Chrome stable

### Acceptance tests

1. Open YouTube video, confirm companion icon shows “available”.
2. Select video; PiP window appears and plays.
3. Enter fullscreen VS Code; PiP stays visible and keeps playing.
4. SponsorBlock causes a skip; PiP playback reflects the jump.
5. Switch to another video in same tab; state updates.
6. Stop streaming; resources released.

### Performance tests

* CPU usage < 15% for 1080p on Apple Silicon (rough target).
* No audio/video drift > 100ms after 10 minutes.

---

## 8) Implementation order (do in this sequence)

1. Companion: WS server + menu bar UI that can display received state.
2. Extension: detect videos and send `state` over WS.
3. WebRTC minimal: extension creates peer connection and sends a test video track; companion renders it.
4. Wrap in PiP-like always-on-top panel with proper Spaces behavior.
5. Multi-tab / multi-video selection.
6. Allowlist + pairing.

---

## 9) Known pitfalls & mitigations

* **YouTube replaces the `<video>` element** during navigation.

  * Re-detect periodically; treat element references as ephemeral.
* **User gesture requirement** for `captureStream()` / autoplay.

  * Implement keyboard shortcut in extension as reliable trigger.
* **Audio not included** sometimes.

  * Validate tracks; if missing, fall back to tab capture (later).
* **Multiple frames/iframes**.

  * Ensure you handle `all_frames` if needed; store `frameId`.

### DRM content (smart fallback)

Some sites use DRM (e.g., Widevine via EME). In those cases, attempting to stream/capture the video output (e.g., via `captureStream()` or any form of tab/video capture) may produce black frames or fail entirely by design.

**Policy:** Float does **not** attempt to bypass DRM. Instead, it detects likely DRM playback and provides a clear UX fallback.

#### 1) Detection heuristics (best-effort)

Implement a lightweight DRM suspicion score in `page_injected.js` / content script:

* Listen for `encrypted` events on the target `<video>` element(s).
* Detect use of EME APIs:

  * wrapping/observing calls to `navigator.requestMediaKeySystemAccess` (page context only)
  * observing `HTMLMediaElement.prototype.setMediaKeys`
* If the element has `mediaKeys` set (`video.mediaKeys != null`), treat as likely DRM.

Because not all sites expose the same signals reliably, treat this as **heuristic** and always handle capture failures gracefully.

#### 2) UX behavior

When DRM is detected **or** when capture/stream fails with a DRM-like symptom (e.g., constant black frames / no video frames received within N seconds):

* Show the candidate in the menu, but mark it as **DRM-protected** (disabled) or **Not floatable (DRM)**.
* If a user tries anyway, fail fast and show an explanation:

  * “This video appears DRM-protected and can’t be popped out.”
* Offer explicit, user-respecting fallback actions:

  * “Open in Safari for native PiP” (opens URL in Safari)
  * “Use windowed ‘fake fullscreen’ to keep Chromium PiP visible” (help link / short guidance)

#### 3) Telemetry/logging (local only)

* Log DRM detection signals and failure modes to a local log file (or Console) to improve heuristics.
* Do not upload data; keep everything local.

#### 4) Test cases

* Confirm normal YouTube works.
* For a known DRM site (e.g., subscription streaming), confirm:

  * Float shows “Not floatable (DRM)” and does not attempt streaming by default.
  * Fallback actions work.

---

## 10) Deliverables checklist

* [ ] `Chrome/manifest.json` complete
* [ ] Options page for allowlist + pairing
* [ ] Service worker WS connection + routing
* [ ] Content script detection + reporting
* [ ] WebRTC sender in page context
* [ ] macOS WS server + pairing
* [ ] macOS WebRTC receiver + renderer
* [ ] PiP-like window across Spaces
* [ ] Basic QA script / manual test steps

---

## 11) Naming

Project name: **Float**

* Extension name: Float
* Companion name: Float
* Bundle ID suggestion: `com.<yourorg>.float`

---

## 12) Notes for future improvements

* True system PiP via `AVPictureInPictureController` + `AVSampleBufferDisplayLayer` fed from WebRTC frames.
* Per-site profiles (size, position, volume).
* Hotkey to toggle PiP and cycle videos.
* Remember last selected tab/video.


# Operating principles

A1. Keep the repo recoverable (but don’t sweat perfection)
	•	Prefer small, incremental changes that are easy to understand and revert.
	•	It’s okay if the repo is temporarily not runnable mid-milestone, but:
	•	avoid breaking both the extension and companion at the same time,
	•	document any temporary breakage in AGENT_PLAN.md,
	•	and restore a working build before completing the milestone.
	•	If a change is risky, isolate it in a short-lived branch/commit sequence and merge once it’s coherent.

A2. Default to boring reliability
	•	Choose the simplest path that satisfies MVP acceptance tests.
	•	Avoid clever abstractions unless they demonstrably reduce risk.
	•	Prefer explicit JSON schemas and message routing over “magic” dynamic handling.

A3. Be aggressively explicit about assumptions
	•	When relying on platform behavior (e.g., MV3 gesture requirements, WebRTC APIs on macOS), document:
	•	what you observed,
	•	what you’re assuming,
	•	and how to detect breakage.

A4. Make failure graceful
	•	Any stream failure should:
	•	end cleanly,
	•	release resources,
	•	and surface a human-readable error in the menu.

⸻

B) The work plan must live in the repo

B1. Create a persistent plan file

Create (or maintain) this file at the repo root:
	•	AGENT_PLAN.md

This is the agent’s single source of truth for current plan + current state.

B2. Required structure of AGENT_PLAN.md

Keep it short, brutally concrete, and easy to scan.
	1.	Goal & current phase

	•	One paragraph: what we’re building right now.

	2.	Milestones (checkbox list)

	•	Use the same ordering as the spec’s “Implementation order”.

	3.	Working set

	•	Files touched in this phase.
	•	Commands used to build/run/test.

	4.	Risks & unknowns

	•	Only the top 3.
	•	Each risk must have a “how we’ll validate” line.

	5.	Next actions

	•	3–7 bullet items.
	•	Each item must be a single action you can complete without hidden steps.

	6.	Decision log

	•	Timestamped bullets for decisions that would be annoying to rediscover.

B3. Update cadence

Update AGENT_PLAN.md:
	•	at the start of work,
	•	after each milestone completion,
	•	and whenever a major assumption changes.

If execution stops unexpectedly, the agent must be able to resume using only AGENT_PLAN.md.

⸻

C) Execution workflow

C1. Plan-first loop (every session)
	1.	Read AGENT_PLAN.md.
	2.	Identify what’s next.
	3.	Make the smallest change that moves one checkbox forward.
	4.	Run the relevant local checks.
	5.	Update AGENT_PLAN.md with what changed and what’s next.

C2. Scope control
	•	Only work on one milestone at a time.
	•	Avoid mixing extension changes and macOS app changes in one sweep unless it’s needed for integration.

C3. File hygiene
	•	Keep the WS protocol messages defined in one place per side:
	•	chrome/protocol.js (or protocol.ts) for the extension
	•	companion/Float/Protocol.swift for the macOS app
	•	Never duplicate message type strings across multiple files without a shared constant.

⸻

D) “Explain what you’re doing” requirements

D1. Maintain a short status trail

Add a repo-root file:
	•	AGENT_STATUS.md

Rules:
	•	Append-only.
	•	Each entry:
	•	date/time
	•	what was implemented
	•	how it was validated
	•	what’s next

This file is not a plan; it’s a changelog for humans.

D2. Make the protocol inspectable
	•	Include a debug mode (off by default) that logs WS messages:
	•	extension: console.log gated behind a boolean
	•	companion: os_log or print gated behind a boolean

⸻

E) Quality gates (do not skip)

E1. Per-milestone validation

For each milestone, add a short “Validation” section to AGENT_PLAN.md describing:
	•	the exact steps run
	•	and the observed outcome.

E2. Minimum automated checks
	•	Extension (TypeScript): ensure the TS build succeeds (e.g., tsc -p chrome/tsconfig.json) and any lint step passes if present.
	•	Companion: ensure Xcode project builds (Debug) without errors.
	•	Companion: ensure Xcode project builds (Debug) without errors.

E3. Manual acceptance checks

Keep a running list of “manual acceptance steps” in AGENT_PLAN.md and mark which were last run.

⸻

F) Test strategy (lightweight but real)

F1. Protocol tests (cheap wins)
	•	Add a tiny schema validator for messages on both sides.
	•	On decode/parse failure:
	•	log the raw message
	•	send back {type:"error"} with a reason

F2. “Known pitfalls” regression checklist

Maintain AGENT_PLAN.md section:
	•	YouTube video element replacement
	•	iframes/frameId issues
	•	missing audio track
	•	gesture requirements
	•	DRM heuristics

⸻

G) Red-team pass before calling something “done”

Before marking a milestone complete, perform a quick adversarial check:
	•	What happens if the companion restarts mid-stream?
	•	What if the WS connection drops and reconnects?
	•	What if there are 2 candidate videos and one disappears?
	•	What if captureStream returns a stream with no video track?

Document any failures and either:
	•	fix them, or
	•	explicitly record them as known limitations with user-visible behavior.

⸻

H) Extra guidance to improve final outcomes

H1. Keep UX honest
	•	If starting capture requires a browser gesture, the UI must say so and provide the shortcut.

H2. Favor “observable correctness”
	•	Add a simple on-screen overlay in the PiP window (debug-only):
	•	connected / receiving frames / fps

H3. Don’t paint into corners
	•	Keep the signaling protocol versioned:
	•	include { "version": 1 } in hello

H4. Avoid zombie resources
	•	Ensure stop/disconnect paths:
	•	close peer connection
	•	stop tracks
	•	remove renderers
	•	reset UI state

⸻

I) Startup checklist for a brand-new run

When starting from scratch:
	1.	Create AGENT_PLAN.md and fill the structure.
	2.	Create AGENT_STATUS.md and write a first entry.
	3.	Identify ports, token behavior, and protocol version.
	4.	Implement milestone 1: companion WS server + menu that shows dummy state.

⸻

J) Done criteria for MVP

MVP is considered complete only when:
	•	All acceptance tests in the main spec pass,
	•	The PiP-like window stays visible across fullscreen Spaces,
	•	State updates reflect YouTube navigation changes,
	•	Stop/cleanup is reliable,
	•	AGENT_PLAN.md and AGENT_STATUS.md are up to date and readable.
