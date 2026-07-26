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

protocol WebRTCReceiver {
    var onLocalIceCandidate: ((LocalIceCandidate) -> Void)? { get set }
    var onStreamingChanged: ((WebRTCMediaSource, Bool) -> Void)? { get set }
    var onPictureInPictureClosed: ((Int, String, Int) -> Void)? { get set }
    var onPlaybackCommand: ((WebRTCMediaSource, Bool) -> Void)? { get set }
    var onSeekCommand: ((WebRTCMediaSource, Double) -> Void)? { get set }
    var onPiPRenderSizeChanged: ((WebRTCMediaSource, CGSize) -> Void)? { get set }
    func handleOffer(_ offer: OfferMessage) async throws -> String
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
