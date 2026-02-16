# Float

<p align="center">
  <img src="./chrome/icons/icon128.png" alt="Float icon" width="96" height="96" />
</p>

<p align="center">
  The missing native PiP for browser video on macOS.
</p>

---

Float exists for one core reason: **browser PiP should feel native on macOS**.

Chrome's built-in PiP is browser-level, not true system PiP, and you feel that most in real daily workflows: jumping between Spaces, running fullscreen apps, and keeping video visible while you work. Float bridges that gap with native macOS PiP, so your video behaves like a first-class system window instead of a browser feature.

Float is a two-part system:

- A **Chrome extension** that finds playable videos and streams a selected source via `captureStream()` + WebRTC.
- A **macOS companion app** that receives the stream locally and renders it in native Picture-in-Picture.

All signaling stays on localhost (`ws://127.0.0.1:17891`).

## Why Float

- Native PiP experience on macOS.
- Works properly across Spaces and fullscreen app workflows via native PiP.
- Local-only transport between browser and companion.
- Playback controls from PiP back to the source tab.
- PiP-size-aware quality hints to balance sharpness and high FPS.

## Repository Layout

```text
float/
├─ chrome/      # Chrome MV3 extension (sender)
├─ companion/   # macOS menu bar app (receiver + native PiP)
└─ scripts/     # Build, package, and release helpers
```

## Requirements

- macOS with Xcode + Command Line Tools
- Chrome/Chromium (MV3 extension support)
- Node.js + Yarn
- For release automation: GitHub CLI (`gh`)

## Quick Start

### 1. Build the extension

```bash
cd /Users/maxnowack/code/float/chrome
yarn install
yarn build
```

### 2. Build the companion

```bash
xcodebuild -project /Users/maxnowack/code/float/companion/Float.xcodeproj \
  -scheme Float \
  -configuration Debug \
  -sdk macosx build
```

### 3. Run it

1. Launch the companion app (`Float.app`).
2. Load `/Users/maxnowack/code/float/chrome` as an unpacked extension in Chrome.
3. Open a page with a playable video.
4. Click the Float menu bar icon and choose a source.
5. PiP opens and starts streaming.

## How To Use Float

### Primary controls

- **Left-click menu bar icon**
  - If one source is available, Float starts immediately.
  - If multiple sources are available, choose from the list.
- **While streaming**
  - Click again to stop.
- **PiP controls**
  - Play/Pause and seek commands are forwarded to the source tab.

### Menu bar options (right-click)

- `Auto-start PiP`
- `Auto-stop PiP`
- `Start at Login`
- `FPS Overlay`
- `Quit Float`

## Build, Pack, and Release Scripts

From repo root:

```bash
cd /Users/maxnowack/code/float
```

### Build

```bash
./scripts/build-chrome.sh
./scripts/build-companion.sh Release
./scripts/build-all.sh Release
```

### Pack artifacts

```bash
./scripts/pack-chrome.sh
./scripts/pack-companion.sh Release
./scripts/pack-all.sh Release
```

Artifacts are produced in:

- `./artifacts/chrome`
- `./artifacts/companion`

### Create a GitHub release

```bash
./scripts/release.sh --tag v0.2.0
```

This script:

1. Ensures the git working tree is clean.
2. Builds and packages extension + companion.
3. Creates and pushes an annotated tag.
4. Creates a GitHub release via `gh`.
5. Uploads generated artifacts.

## Architecture Summary

1. Content scripts detect video candidates per frame.
2. Service worker aggregates tab state and relays signaling.
3. Companion selects a source and sends `start`.
4. Extension captures selected video and sends WebRTC offer/ICE.
5. Companion receives video/audio and renders in private native PiP.
6. PiP playback actions are forwarded back to the source video.

## Privacy & Security

- Signaling is local-only on loopback (`127.0.0.1`).
- No remote signaling server is required.
- No account/login flow is required.

## Important Notes

- Float uses private macOS PiP framework APIs (`PIP.framework`) for the companion app.
- This is suitable for local/dev workflows, but may not be App Store-safe.

## Troubleshooting

- **No sources detected**
  - Confirm the video is actually playing and has loaded metadata.
- **Extension looks stale after updates**
  - Reload the unpacked extension in Chrome.
- **Companion doesn’t connect**
  - Ensure the companion app is running before starting from Chrome.
- **Packaging/release issues**
  - Verify `gh auth status` and that your working tree is clean.

## Contributing

Contributions are welcome. Prefer focused PRs with:

- a clear problem statement,
- minimal scope,
- and reproduction/verification steps.
