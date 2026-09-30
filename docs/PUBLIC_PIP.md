# Public AVKit Picture in Picture evaluation

Status: evaluated on macOS 27.0 (SDK `MacOSX27.0.sdk`, September 2026) and
rejected. The companion keeps using the private `PIP.framework`
(`NativePiPController`). This document records why, and how a public
implementation would look once AVKit behaves.

## Motivation

`NativePiPController` loads `/System/Library/PrivateFrameworks/PIP.framework`
with `dlopen`, drives `PIPViewController` through `NSSelectorFromString`, and
has to support both `PIPClientXPCProtocol` and the legacy
`PIPViewControllerDelegate` because the private surface already moved between
macOS releases. That is not App Store-safe and can break with any OS update.

## Public API surface

- macOS 27 adds no Picture in Picture API. AVKit headers in the 27.0 SDK
  contain nothing newer than macOS 26.4 (`AVLegibleMediaOptionsMenuController`).
- The only public path for non-`AVPlayer` content is
  `AVPictureInPictureController(contentSource:)` with
  `ContentSource(sampleBufferDisplayLayer:playbackDelegate:)` (macOS 12+).
- PiP shows only the `AVSampleBufferDisplayLayer` contents. Arbitrary views
  or sublayers are not mirrored.
- `canStartPictureInPictureAutomaticallyFromInline` is unavailable on macOS.
- `WKWebViewConfiguration.allowsPictureInPictureMediaPlayback` is iOS-only.

## Implementation sketch

This is the shape of the prototype that was built and tested, then removed.

### 1. Frame sink

Replace `LKRTCMTLVideoView` as the remote track's renderer with an
`LKRTCVideoRenderer` that feeds an `AVSampleBufferDisplayLayer`. WebRTC calls
it on its decoder thread, so the class is `nonisolated` and guards its state
with `OSAllocatedUnfairLock` (the project uses `SWIFT_DEFAULT_ACTOR_ISOLATION =
MainActor`).

```swift
nonisolated final class SampleBufferVideoRenderer: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    func setSize(_ size: CGSize) { /* hop to main, report video size */ }

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame,
              let pixelBuffer = pixelBuffer(for: frame.buffer),
              let sampleBuffer = makeSampleBuffer(for: pixelBuffer)
        else { return }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sampleBuffer)
        // First frame after a flush -> notify the controller (see step 4).
    }
}
```

- Pixel buffers: hardware-decoded frames arrive as `LKRTCCVPixelBuffer` and can
  be passed through when `requiresCropping()` is false. Software frames
  (VP8/VP9) come as I420 (`frame.buffer.toI420()`) and are converted to NV12
  from a `CVPixelBufferPool` (IOSurface-backed, Metal-compatible). Y rows are
  copied with `memcpy`, and U/V are interleaved with
  `vImageConvert_PlanarToChunky8`.
- Sample buffers: cache the `CMVideoFormatDescription` while
  `CMVideoFormatDescriptionMatchesImageBuffer` holds. Use the host clock as the
  presentation time, then `CMSampleBufferCreateReadyWithImageBuffer`, and set
  `kCMSampleAttachmentKey_DisplayImmediately` on the attachment.
- `frame.rotation` has to be applied or ignored. Tab capture delivers `_0`.
- macOS 27 deprecates `AVSampleBufferVideoRenderer.enqueue(_:)` in favour of
  attaching the renderer to a render synchronizer with
  `sampleBufferReceiver(adding:)` and calling `enqueue(_:)` /
  `enqueueImmediately(_:)` on the receiver (Swift-only API). A new
  implementation should use that.

### 2. Source host window

The display layer has to live in a window. The following was verified in the
probe on macOS 27.0:

- A borderless `.nonactivatingPanel` with `alphaValue = 0`,
  `ignoresMouseEvents = true`, `.floating` level and
  `[.canJoinAllSpaces, .stationary, .ignoresCycle]` is enough.
  `isPictureInPicturePossible` becomes true and PiP starts. An off-screen
  origin (-10000, -10000) and a visible window behave the same.
- It works from an `.accessory` app that is not active. No activation is
  needed before `startPictureInPicture()`.

### 3. Controller and delegate mapping

`AVPictureInPictureController(contentSource:)` plus
`AVPictureInPictureControllerDelegate` and
`AVPictureInPictureSampleBufferPlaybackDelegate`. Implement the delegate
methods as `nonisolated`. Getters that AVKit calls synchronously read a
lock-protected playback snapshot, and commands hop to the main actor.

| AVKit callback | Float behaviour |
| --- | --- |
| `setPlaying(_:)` | `onPlaybackCommand` → protocol `playback {playing}` |
| `skipByInterval(_:completion:)` | `onSeekCommand(seconds)`, then call completion |
| `timeRangeForPlayback` | live/unknown duration: `CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)`; otherwise start = host clock now − elapsed, duration = media duration |
| `isPlaybackPaused` | `!isPlaying` from the snapshot |
| `didTransitionToRenderSize` | `onPiPRenderSizeChanged` |
| `restoreUserInterfaceForPictureInPictureStop` | `completion(true)`. There is no inline player, so it behaves like close |
| `didStartPictureInPicture` | begin a `PiPPresentationEpochTracker` epoch, `onPictureInPictureStarted` |
| `didStopPictureInPicture` | end the epoch; call `onPictureInPictureClosed` only if the stop was user-initiated |

Call `invalidatePlaybackState()` whenever playback state or progress changes.

### 4. Start gating

Start PiP only after the first sample buffer has been enqueued. Reset the gate
when the renderer is flushed (stop, close, new offer).

### 5. Receiver integration

Extract the surface `NativeLibWebRTCReceiver` uses from `NativePiPController`
into a protocol (the callbacks, `requestStart`, `setPiPContentReady`, `stop`,
`updateExpectedVideoSize`, `updatePlaybackState`, `updatePlaybackProgress`,
`updateDiagnosticsOverlay`). The receiver then picks the backend and attaches
either the Metal view or the sample buffer renderer to the remote video track.

## Problems found

### Crash when starting before the first frame

When PiP starts while the layer has no frame yet (ICE not connected), AVKit
lays out its host view with a NaN frame and AppKit traps:

```
EXC_BREAKPOINT in _NSViewValidateGeometry
  -[NSView setFrame:]
  -[AVPictureInPictureSampleBufferDisplayLayerHostView _updateGeometryIfNeeded]
  -[AVPictureInPictureSampleBufferDisplayLayerHostView layout]
```

Start gating (step 4) avoids it.

### Video geometry in the PiP window (blocker)

AVKit builds the PiP window in-process (`PIPPanel`):

```
PIPPanel (e.g. 696x392)
  NSView (696x392)
    AVPictureInPictureSampleBufferDisplayLayerView      = source layer size
      AVPictureInPictureSampleBufferDisplayLayerHostView = source layer size
        AVPictureInPictureCALayerHostView               = 1600x900 at y=350
```

Observed with `docs/public-pip-probe.swift` (1280x720 frames with a white
border):

- The view inside the panel takes the source layer's size at start and is not
  constrained to the panel. It keeps that size afterwards.
- `didTransitionToRenderSize` reports the source layer size, not the window
  size.
- **Source 160x90:** the whole frame, border included, is drawn at 160x90 points
  in the bottom-left corner of the PiP window. There is no scaling.
- **Source equal to the PiP window size (696x392):** AVKit scales the
  1600x900 layer host (factor 0.4356) and keeps the y=350 offset. The frame is
  shifted to the top right and clipped, with a black band at the top.
- **Resizing the source while PiP is shown:** the view keeps its start size.
  AVKit rescales the layer host (0.1 for a 160-point view), and the video does
  not follow.
- **Pinning AVKit's view to the panel with Auto Layout:** the view fills the
  panel, but the video is still drawn at source size. The result is a black
  band and the correct video flickering in the bottom-left corner.
- In the Float companion, WebRTC ramps the resolution (320x180 → 1280x720).
  Sizing the source to the video made the picture grow in steps and drift out
  of place.

The behaviour did not change with `.regular` vs `.accessory` activation, a
titled `NSWindow` vs a borderless panel, visible vs transparent vs off-screen
hosting, or with the display layer as sublayer, layer-hosting layer, or
`makeBackingLayer()` backing layer.

Any fix would have to rearrange AVKit's undocumented view hierarchy inside the
PiP window, which is as fragile as the private framework it is meant to
replace.

### Functional losses even if geometry worked

- The diagnostics overlay cannot be shown in PiP. It would have to be drawn
  into the frames.
- No equivalent of `replacementRect`/`replacementWindow`,
  `performWindowDragWithEvent:`, or explicit `aspectRatio`. The aspect ratio
  comes from the frames.
- "Return to app" ends the stream, like close.

## Re-evaluating on a newer macOS

1. `swiftc -O docs/public-pip-probe.swift -o /tmp/public-pip-probe`
2. Run it with the default source (160x90) and with `LW`/`LH` set to the PiP
   window size it reports.
3. Pass criterion: in both runs the colour frame, including its white border,
   fills the PiP window and follows window resizes.
4. If it passes, reimplement following the sketch above, using the
   `sampleBufferReceiver` API. Test hardware and software decoded streams, the
   resolution ramp, play/pause and skip sync with the extension, and
   auto-start while the source tab is in the background.

The probe is also a self-contained reproduction for a Feedback Assistant
report against AVKit.
