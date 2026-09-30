import Foundation

struct LocalIceCandidate {
    let tabId: Int
    let videoId: String
    let generation: Int
    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int?
}

struct WebRTCMediaSource: Equatable {
    let tabId: Int
    let videoId: String
    let generation: Int

    func matches(
        tabId: Int?,
        videoId: String?,
        generation: Int?
    ) -> Bool {
        self.tabId == tabId &&
            self.videoId == videoId &&
            self.generation == generation
    }
}

/// Whether WebRTC aligns the remote audio and video tracks by their capture
/// timestamps.
///
/// Chrome stamps `HTMLMediaElement.captureStream()` audio with
/// `Now() - outputDelay` although it becomes audible at `Now() + outputDelay`,
/// while video frames are stamped when they are displayed. WebRTC's lip sync
/// trusts those stamps and ends up delaying the picture by roughly twice
/// Chrome's audio output delay (~120 ms), after settling for up to a minute.
/// Playing both tracks without WebRTC's alignment leaves the sound ~20-50 ms
/// behind the picture from the first frame on, below the perception threshold.
/// See docs/AV_SYNC.md.
enum LipSyncMode: CustomStringConvertible {
    case webRTC
    case disabled

    init(extensionOrigin origin: String) {
        self = origin.hasPrefix("chrome-extension://") ? .disabled : .webRTC
    }

    var description: String {
        switch self {
        case .webRTC: "webrtc"
        case .disabled: "disabled"
        }
    }
}

enum LipSyncSDP {
    private static let audioStreamSuffix = "-float-audio"

    /// Moves the audio track into its own MediaStream by rewriting its msid.
    /// WebRTC only lip-syncs tracks that share a stream.
    static func separatingAudioSyncGroup(in sdp: String) -> String {
        var inAudioSection = false
        let lines = sdp.components(separatedBy: "\r\n").map { line -> String in
            if line.hasPrefix("m=") {
                inAudioSection = line.hasPrefix("m=audio")
                return line
            }
            guard inAudioSection else { return line }
            if line.hasPrefix("a=msid:") {
                let parts = line.dropFirst("a=msid:".count).split(separator: " ", maxSplits: 1)
                guard let streamId = parts.first, streamId != "-" else { return line }
                return "a=msid:\(streamId)\(audioStreamSuffix)" + (parts.count > 1 ? " \(parts[1])" : "")
            }
            if line.hasPrefix("a=ssrc:"), let range = line.range(of: " msid:") {
                let value = line[range.upperBound...].split(separator: " ", maxSplits: 1)
                guard let streamId = value.first else { return line }
                return String(line[..<range.upperBound]) + "\(streamId)\(audioStreamSuffix)"
                    + (value.count > 1 ? " \(value[1])" : "")
            }
            return line
        }
        return lines.joined(separator: "\r\n")
    }
}

protocol WebRTCReceiver {
    var onLocalIceCandidate: ((LocalIceCandidate) -> Void)? { get set }
    var onStreamingChanged: ((WebRTCMediaSource, Bool) -> Void)? { get set }
    var onPictureInPictureClosed: ((Int, String, Int) -> Void)? { get set }
    var onPlaybackCommand: ((WebRTCMediaSource, Bool) -> Void)? { get set }
    var onSeekCommand: ((WebRTCMediaSource, Double) -> Void)? { get set }
    var onPiPRenderSizeChanged: ((WebRTCMediaSource, CGSize) -> Void)? { get set }
    func handleOffer(_ offer: OfferMessage, lipSync: LipSyncMode) async throws -> String
    func addRemoteIceCandidate(_ ice: IceMessage) async throws
    func stop()
    func updatePlaybackState(isPlaying: Bool)
    func updatePlaybackProgress(elapsedSeconds: Double?, durationSeconds: Double?)
    func setDebugLoggingEnabled(_ enabled: Bool)
    func setDiagnosticsOverlayEnabled(_ enabled: Bool)
}

extension WebRTCReceiver {
    func setDebugLoggingEnabled(_ enabled: Bool) {
        _ = enabled
    }

    func setDiagnosticsOverlayEnabled(_ enabled: Bool) {
        _ = enabled
    }
}

enum WebRTCReceiverError: LocalizedError {
    case peerConnectionUnavailable
    case missingPeerConnection

    var errorDescription: String? {
        switch self {
        case .peerConnectionUnavailable:
            return "Failed to create WebRTC peer connection."
        case .missingPeerConnection:
            return "No active WebRTC peer connection."
        }
    }
}

func makeWebRTCReceiver() -> WebRTCReceiver {
#if canImport(LiveKitWebRTC)
    guard NativeLibWebRTCReceiver.isSupported else {
        fatalError("Native WebRTC receiver is not supported on this system.")
    }
    return NativeLibWebRTCReceiver()
#else
    fatalError("Native WebRTC receiver requires linking the LiveKitWebRTC framework.")
#endif
}
