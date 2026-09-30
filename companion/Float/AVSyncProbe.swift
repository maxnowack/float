#if canImport(LiveKitWebRTC)
import AVFoundation
import CoreAudio
import CoreVideo
import Foundation
import LiveKitWebRTC
import os
import OSLog
import QuartzCore

/// Development probe that measures the perceived audio/video offset of a
/// stream playing the A/V sync test clip from docs/av-sync (every second: a
/// white flash and a sample-aligned 1 kHz beep). See docs/AV_SYNC.md.
///
/// Flash times are taken when a decoded frame reaches the renderers plus one
/// display refresh. Beep times are taken when the audio device module pulls
/// the samples plus the audio playout delay. A positive offset means the
/// picture lags the sound.
///
/// Enable with the launch argument `-FloatAVSyncProbe YES`.
nonisolated final class AVSyncProbe: NSObject, LKRTCVideoRenderer, LKRTCAudioRenderer, @unchecked Sendable {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "FloatAVSyncProbe")
    }

    private enum Constants {
        static let flashLumaThreshold = 150.0
        static let beepAmplitudeThreshold: Float = 0.05
        static let minimumSilenceBeforeBeep = 0.3
        static let maximumPairingDistance = 0.5
        static let recentOffsetCount = 7
    }

    private struct State {
        var displayLatency: Double
        var audioPlayoutDelay: Double?
        var audioPlayoutDelaySource = "none"
        var videoIsBright = false
        var lastLoudAudioTime: Double?
        var pendingFlashes: [Double] = []
        var pendingBeeps: [Double] = []
        var recentOffsetsMs: [Double] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(displayLatency: Double) {
        state = OSAllocatedUnfairLock(initialState: State(displayLatency: displayLatency))
        super.init()
    }

    func reset() {
        state.withLock { state in
            state = State(displayLatency: state.displayLatency)
        }
    }

    /// Mean playout delay reported by the audio device module, in seconds.
    func updateAudioPlayoutDelay(_ seconds: Double, source: String) {
        guard seconds.isFinite, seconds >= 0 else { return }
        state.withLock { state in
            state.audioPlayoutDelay = seconds
            state.audioPlayoutDelaySource = source
        }
    }

    // MARK: - Video

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        let now = CACurrentMediaTime()
        guard let frame, let luma = Self.meanLuma(of: frame.buffer) else { return }

        let flashTime: Double? = state.withLock { state in
            let isBright = luma >= Constants.flashLumaThreshold
            defer { state.videoIsBright = isBright }
            guard isBright, !state.videoIsBright else { return nil }
            return now + state.displayLatency
        }
        guard let flashTime else { return }
        state.withLock { $0.pendingFlashes.append(flashTime) }
        matchPairs()
    }

    // MARK: - Audio

    func render(pcmBuffer: AVAudioPCMBuffer) {
        let now = CACurrentMediaTime()
        let sampleRate = pcmBuffer.format.sampleRate
        let frameCount = Int(pcmBuffer.frameLength)
        guard sampleRate > 0, frameCount > 0,
              let firstLoudIndex = Self.firstLoudSampleIndex(in: pcmBuffer, frameCount: frameCount)
        else {
            return
        }

        let pullTime = now + Double(firstLoudIndex) / sampleRate
        let beepTime: Double? = state.withLock { state in
            defer { state.lastLoudAudioTime = pullTime }
            if let lastLoud = state.lastLoudAudioTime,
               pullTime - lastLoud < Constants.minimumSilenceBeforeBeep {
                return nil
            }
            guard let playoutDelay = state.audioPlayoutDelay else { return nil }
            return pullTime + playoutDelay
        }
        guard let beepTime else { return }
        state.withLock { $0.pendingBeeps.append(beepTime) }
        matchPairs()
    }

    // MARK: - Pairing

    private func matchPairs() {
        let results: [(offsetMs: Double, medianMs: Double, playoutDelayMs: Double, source: String)] =
            state.withLock { state in
                var results: [(Double, Double, Double, String)] = []
                while let flash = state.pendingFlashes.first, let beep = state.pendingBeeps.first {
                    let distance = flash - beep
                    if abs(distance) <= Constants.maximumPairingDistance {
                        state.pendingFlashes.removeFirst()
                        state.pendingBeeps.removeFirst()
                        let offsetMs = distance * 1000
                        state.recentOffsetsMs.append(offsetMs)
                        if state.recentOffsetsMs.count > Constants.recentOffsetCount {
                            state.recentOffsetsMs.removeFirst()
                        }
                        let sorted = state.recentOffsetsMs.sorted()
                        results.append((
                            offsetMs,
                            sorted[sorted.count / 2],
                            (state.audioPlayoutDelay ?? 0) * 1000,
                            state.audioPlayoutDelaySource
                        ))
                    } else if distance < 0 {
                        state.pendingFlashes.removeFirst()
                    } else {
                        state.pendingBeeps.removeFirst()
                    }
                }
                return results
            }

        for result in results {
            FloatLog.media.info(
                "avsync.probe offsetMs=\(String(format: "%+.1f", result.offsetMs), privacy: .public) medianMs=\(String(format: "%+.1f", result.medianMs), privacy: .public) audioPlayoutDelayMs=\(String(format: "%.1f", result.playoutDelayMs), privacy: .public) delaySource=\(result.source, privacy: .public)"
            )
        }
    }

    // MARK: - CoreAudio

    /// Output latency of the default output device: device and stream latency,
    /// safety offset and one IO buffer, in seconds.
    static func defaultOutputDeviceLatency() -> Double? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        guard readProperty(
            AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal,
            into: &deviceID
        ), deviceID != kAudioObjectUnknown else {
            return nil
        }

        var sampleRate = Float64(0)
        guard readProperty(deviceID, selector: kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeGlobal, into: &sampleRate),
              sampleRate > 0
        else {
            return nil
        }

        var deviceLatency = UInt32(0)
        var safetyOffset = UInt32(0)
        var bufferFrames = UInt32(0)
        _ = readProperty(deviceID, selector: kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeOutput, into: &deviceLatency)
        _ = readProperty(deviceID, selector: kAudioDevicePropertySafetyOffset, scope: kAudioObjectPropertyScopeOutput, into: &safetyOffset)
        _ = readProperty(deviceID, selector: kAudioDevicePropertyBufferFrameSize, scope: kAudioObjectPropertyScopeOutput, into: &bufferFrames)

        var streamLatency = UInt32(0)
        var streamsSize = UInt32(0)
        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &streamsSize) == noErr,
           streamsSize >= UInt32(MemoryLayout<AudioStreamID>.size) {
            var streams = [AudioStreamID](repeating: 0, count: Int(streamsSize) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(deviceID, &streamsAddress, 0, nil, &streamsSize, &streams) == noErr,
               let firstStream = streams.first {
                _ = readProperty(firstStream, selector: kAudioStreamPropertyLatency, scope: kAudioObjectPropertyScopeGlobal, into: &streamLatency)
            }
        }

        let totalFrames = Double(deviceLatency) + Double(safetyOffset) + Double(bufferFrames) + Double(streamLatency)
        return totalFrames / sampleRate
    }

    private static func readProperty<Value>(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        into value: inout Value
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Value>.size)
        return AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr
    }

    // MARK: - Signal analysis

    private static func firstLoudSampleIndex(in buffer: AVAudioPCMBuffer, frameCount: Int) -> Int? {
        // Interleaved buffers keep all channels in the first pointer.
        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        if let channel = buffer.floatChannelData?[0] {
            for frame in 0..<frameCount where abs(channel[frame * stride]) >= Constants.beepAmplitudeThreshold {
                return frame
            }
            return nil
        }
        if let channel = buffer.int16ChannelData?[0] {
            let threshold = Int32(Constants.beepAmplitudeThreshold * Float(Int16.max))
            for frame in 0..<frameCount where abs(Int32(channel[frame * stride])) >= threshold {
                return frame
            }
        }
        return nil
    }

    /// Mean luma (0-255) over a coarse sample grid.
    private static func meanLuma(of buffer: LKRTCVideoFrameBuffer) -> Double? {
        if let cvBuffer = buffer as? LKRTCCVPixelBuffer {
            return meanLuma(of: cvBuffer.pixelBuffer)
        }
        let i420 = buffer.toI420()
        return sampleGrid(
            base: UnsafeRawPointer(i420.dataY),
            width: Int(i420.width),
            height: Int(i420.height),
            bytesPerRow: Int(i420.strideY),
            bytesPerPixel: 1
        )
    }

    private static func meanLuma(of pixelBuffer: CVPixelBuffer) -> Double? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8Planar,
             kCVPixelFormatType_420YpCbCr8PlanarFullRange:
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
            return sampleGrid(
                base: UnsafeRawPointer(base),
                width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
                bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
                bytesPerPixel: 1
            )
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB:
            // Green dominates luma; good enough to tell white from black.
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            return sampleGrid(
                base: UnsafeRawPointer(base).advanced(by: 1),
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer),
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                bytesPerPixel: 4
            )
        default:
            return nil
        }
    }

    private static func sampleGrid(
        base: UnsafeRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bytesPerPixel: Int
    ) -> Double? {
        guard width > 0, height > 0 else { return nil }
        let steps = 8
        var sum = 0
        for row in 0..<steps {
            let y = (height * (2 * row + 1)) / (2 * steps)
            for column in 0..<steps {
                let x = (width * (2 * column + 1)) / (2 * steps)
                sum += Int(base.load(fromByteOffset: y * bytesPerRow + x * bytesPerPixel, as: UInt8.self))
            }
        }
        return Double(sum) / Double(steps * steps)
    }
}
#endif
