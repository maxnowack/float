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

Float uses WebRTC for streaming with local-only signaling on `127.0.0.1:17891`. All communication between the browser extension and companion app happens over localhost—no external servers are involved.

### Why Private PIP.framework?

The companion app uses private `PIP.framework` APIs instead of the public AVKit Picture-in-Picture API. The public API was tested but proved unstable and unsuitable for this use case.

**Important**: The codebase was developed quickly and may contain errors. The author is not an experienced Swift/macOS developer, so there may be better approaches using public APIs that haven't been discovered yet. Contributions and improvements are welcome.

## Development

Float is split into:

- `extension/` (shared extension source + manifests)
- `companion/` (macOS receiver + native PiP)
- `scripts/` (build/pack/release helpers)

The extension code is shared with two explicit manifests: one for Chrome and one for Firefox.

Basic commands:

```bash
./scripts/build-all.sh
./scripts/pack-all.sh
```

Extension-only commands:

```bash
./scripts/build-chrome.sh
./scripts/build-firefox.sh
./scripts/pack-chrome.sh
./scripts/pack-firefox.sh
```
