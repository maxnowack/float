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
3. Right-click the Float menu-bar icon and choose
   **Copy Sensitive Pairing Secret**.
4. Open the Float extension popup, paste the secret, and choose
   **Pair with Float**.
5. Open a page with a video.
6. Click the Float menu-bar icon and pick a source.

The pairing is per extension installation. It persists across browser and
companion restarts. To recover or revoke pairing, choose **Remove pairing** in
the extension popup or **Rotate Pairing Secret…** in the companion menu. A
rotation disconnects the current browser and invalidates the previous value.
The copied value is a long-lived credential: Float clears an unchanged
clipboard after successful pairing or 60 seconds, but you should still treat it
like a password.

## Known Issues & Limitations

### Video Quality

Float optimizes for audio quality. When a stream starts, video bitrate and resolution begin lower and improve over time as the connection adapts.

### Browser Differences

- **Chrome**: Provides higher video resolution and overall better quality.
- **Firefox**: Video resolution is lower but generally adequate for PiP viewing.

### Firefox Audio Bug

Due to a [bug in Firefox](https://developer.mozilla.org/en-US/docs/Web/API/HTMLMediaElement/captureStream#firefox-specific-notes), audio does not return to the page after ending Picture-in-Picture. **Workaround**: Reload the page to restore audio. This is a Firefox browser issue, not a Float issue.

## Technical Notes

### Architecture

The browser content script discovers `<video>` elements and uses
`captureStream()` to create the media source. Its extension background context
handles authenticated signaling. The sandboxed macOS companion receives the
local WebRTC stream, renders video through Metal, plays its audio, and presents
the existing private `PIP.framework` controller.

Signaling binds only IPv4 `127.0.0.1:17891`; Float does not advertise the
service or configure WebRTC STUN/TURN servers. Loopback alone is not trusted.
The companion validates the browser-extension Origin and requires protocol v2
HMAC authentication with a 256-bit per-install secret stored in the macOS
Keychain and background-owned extension IndexedDB.

See [`SECURITY.md`](SECURITY.md) for the threat model and
[`docs/PROTOCOL_V2.md`](docs/PROTOCOL_V2.md) for the wire protocol and limits.

### Why Private PIP.framework?

The companion app uses private `PIP.framework` APIs instead of the public AVKit Picture-in-Picture API. The public API was tested but proved unstable and unsuitable for this use case.

**Important**: The codebase was developed quickly and may contain errors. The author is not an experienced Swift/macOS developer, so there may be better approaches using public APIs that haven't been discovered yet. Contributions and improvements are welcome.

## Development

Float is split into:

- `extension/` (shared extension source + manifests)
- `companion/` (macOS receiver + native PiP)
- `scripts/` (build/pack/release helpers)

The extension code is shared with two explicit manifests: one for Chrome and one for Firefox.
The companion uses the exact pinned LiveKit WebRTC binary described in
[`docs/DEPENDENCIES.md`](docs/DEPENDENCIES.md). Its macOS framework and the
Float app support both `arm64` and `x86_64`.

Basic commands:

```bash
corepack enable
yarn --cwd extension install --frozen-lockfile
yarn --cwd extension test
./scripts/build-all.sh
./scripts/pack-all.sh
./scripts/hash-artifacts.sh
```

These are development artifacts. The public release command is fail-closed and
requires both a Developer ID Application identity and a `notarytool` Keychain
profile; see the release checklist.

Extension-only commands:

```bash
./scripts/build-chrome.sh
./scripts/build-firefox.sh
./scripts/pack-chrome.sh
./scripts/pack-firefox.sh
```

Companion tests and an unsigned local build:

```bash
FLOAT_UNSIGNED=1 ./scripts/build-companion.sh Debug arm64

xcodebuild test \
  -project companion/Float.xcodeproj \
  -scheme Float \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO

xcodebuild build \
  -project companion/Float.xcodeproj \
  -scheme Float \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO
```

Distribution builds require an Apple-issued Developer ID identity so the
Hardened Runtime app and embedded WebRTC framework share a Team Identifier.
Follow [`docs/RELEASE_CHECKLIST.md`](docs/RELEASE_CHECKLIST.md); do not weaken
library validation for local or CI builds.
