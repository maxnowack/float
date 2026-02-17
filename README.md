# Float

<p align="center">
  <img src="./extension/icons/icon128.png" alt="Float icon" width="96" height="96" />
</p>

<p align="center">
  Native macOS Picture-in-Picture for browser video.
</p>

Float exists for one reason: browser PiP is not native macOS PiP.
Float brings browser video into real system PiP so it works better with Spaces and fullscreen apps.

## Download

Download the latest release from:

- [Latest Release](https://github.com/maxnowack/float/releases/latest)

## Usage

1. Install and open the Float companion app.
2. Install/load the Float browser extension (Chrome or Firefox).
3. Open a page with a video.
4. Click the Float menu bar icon and pick a source.

## Development

Float is split into:

- `extension/` (shared extension source + manifests)
- `companion/` (macOS receiver + native PiP)
- `scripts/` (build/pack/release helpers)

The extension code is shared with two explicit manifests: one for Chrome and one for Firefox.

Basic commands:

```bash
./scripts/build-all.sh Release
./scripts/pack-all.sh Release
./scripts/release.sh --tag v0.2.0
```

Extension-only commands:

```bash
./scripts/build-chrome.sh
./scripts/build-firefox.sh
./scripts/pack-chrome.sh
./scripts/pack-firefox.sh
```

From `extension/`, you can also run:

```bash
yarn build:chrome
yarn build:firefox
```

Notes:

- Signaling is local-only on `127.0.0.1:17891`.
- The companion uses private `PIP.framework` APIs.
