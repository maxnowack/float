# Audio/video sync in Picture in Picture

Status: implemented. For Chrome sources the companion turns off WebRTC's lip
sync (`LipSyncMode` in `companion/Float/WebRTCReceiver.swift`). Measured on
macOS 27 / Chrome, September 2026.

## Root cause

Chrome timestamps the two tracks of `HTMLMediaElement.captureStream()`
inconsistently:

- **Audio:** `HtmlAudioElementCapturerSource::OnAudioBus`
  (`third_party/blink/renderer/modules/mediacapturefromelement/html_audio_element_capturer_source.cc`)
  stamps each audio bus with `Now() - frames_delayed / sample_rate`.
  `frames_delayed` is the audio device output delay (`media/base/audio_renderer_sink.h`),
  so the audio is heard at `Now() + delay` but stamped `2 × delay` earlier than
  that.
- **Video:** `HtmlVideoElementCapturerSource` stamps each frame with `Now()` at
  the moment it is displayed, which is when its sound is audible.

WebRTC's lip sync on the receiver trusts these timestamps. It therefore delays
the picture until the stamps line up, and the picture ends up behind the sound
by about twice Chrome's audio output delay. The error sits inside Chrome's
capture, so it cannot be fixed in the extension without changing how the page
itself plays its audio.

## Measurements

These were taken with the development probe (see below). The sign convention
is picture time minus sound time, so a positive value means the picture lags.

| Setup | Offset | Behaviour over time |
| --- | --- | --- |
| WebRTC lip sync on (previous behaviour) | +110 … +140 ms | Starts near 0, then settles over 40–60 s at up to 80 ms/s (`kMaxChangeMs`) |
| WebRTC lip sync off (current) | −20 … −50 ms (16 min run: median −32, p10/p90 −47/−13) | Constant from the first frame, no drift (0.00 ms/min) |

- **Perception:** a sound lag of 20–50 ms is well inside the ITU-R BT.1359
  detectability range. Detection starts at about 125 ms for sound lagging and
  about 45 ms for sound leading.
- **Remaining jitter:** the residual moves by about ±15 ms between loops of the
  test clip. Chrome samples the element's current frame on a fixed timer, so
  the phase shifts with each loop.
- **Output device:** AirPods and the built-in speakers behaved the same.
  macOS reports only a few milliseconds of device latency for both, and Chrome
  uses the reported values.

## Rejected approaches

- **libwebrtc configuration.** `video/stream_synchronization.cc` has no field
  trials and no offset parameter. `SetTargetBufferingDelay` and the minimum
  playout delays shift audio and video together.
- **Fixed compensation or one-off calibration.** With lip sync on, the offset
  needs up to a minute to settle. A fixed audio delay therefore makes the first
  20–30 s worse, with the sound up to about 190 ms late.
- **Delaying audio in the companion after lip sync.** LiveKit's `AVAudioEngine`
  audio device module plays mono only. A custom stereo output fed from the
  track's PCM renderer, with the device module muted through `source.volume`,
  worked, but it added complexity and did nothing about the settling phase.
- **Capturing audio through Web Audio** (`createMediaElementSource` →
  `MediaStreamAudioDestinationNode`). This gives consistent timestamps, but it
  permanently reroutes the page's audio and leaves the page's own playback with
  the sound 10–40 ms behind the picture.

## Firefox

Firefox has its own `captureStream()` implementation and keeps WebRTC's lip
sync. Verify it with the probe before changing `LipSyncMode`.

## Measuring

1. Run `docs/av-sync/generate-clip.sh` (needs ffmpeg), then serve the folder:
   ```bash
   python3 -m http.server 8765 --bind 127.0.0.1 --directory docs/av-sync
   ```
2. Start a Debug build of the companion with the probe:
   ```bash
   OS_ACTIVITY_DT_MODE=YES <DerivedData>/Build/Products/Debug/Float.app/Contents/MacOS/Float -FloatAVSyncProbe YES
   ```
3. Open `http://127.0.0.1:8765`, play the clip with sound, start Picture in
   Picture from the menu bar item, and let it run for at least a minute.
4. Every second, `AVSyncProbe` logs a line such as
   `avsync.probe offsetMs=… medianMs=…`.
   - **Video side:** it takes the time a decoded frame reaches the renderers,
     plus one display refresh.
   - **Audio side:** it takes the time the device module pulls the samples,
     plus the playout delay from the `media-playout` stats, or else the
     latency CoreAudio reports for the default output device.

Repeat the measurement after Chrome updates that touch media capture. The
Chromium code referenced above still used `Now() - delay` in September 2026.
