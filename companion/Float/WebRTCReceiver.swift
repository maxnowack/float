import Foundation

struct LocalIceCandidate {
    let tabId: Int
    let videoId: String
    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int?
}

protocol WebRTCReceiver {
    var onLocalIceCandidate: ((LocalIceCandidate) -> Void)? { get set }
    var onStreamingChanged: ((Bool) -> Void)? { get set }
    var onPlaybackCommand: ((Bool) -> Void)? { get set }
    var onSeekCommand: ((Double) -> Void)? { get set }
    func handleOffer(_ offer: OfferMessage) async throws -> String
    func addRemoteIceCandidate(_ ice: IceMessage) async throws
    func stop()
    func updatePlaybackState(isPlaying: Bool)
    func updatePlaybackProgress(elapsedSeconds: Double?, durationSeconds: Double?)
}

enum WebRTCReceiverError: LocalizedError {
    case notConfigured
    case peerConnectionUnavailable
    case missingPeerConnection
    case bridgeNotReady

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "WebRTC receiver backend is not configured. Link a native WebRTC framework to continue."
        case .peerConnectionUnavailable:
            return "Failed to create WebRTC peer connection."
        case .missingPeerConnection:
            return "No active WebRTC peer connection."
        case .bridgeNotReady:
            return "Web receiver page did not initialize in time."
        }
    }
}

final class StubWebRTCReceiver: WebRTCReceiver {
    var onLocalIceCandidate: ((LocalIceCandidate) -> Void)?
    var onStreamingChanged: ((Bool) -> Void)?
    var onPlaybackCommand: ((Bool) -> Void)?
    var onSeekCommand: ((Double) -> Void)?

    func handleOffer(_ offer: OfferMessage) async throws -> String {
        _ = offer
        throw WebRTCReceiverError.notConfigured
    }

    func addRemoteIceCandidate(_ ice: IceMessage) async throws {
        _ = ice
        throw WebRTCReceiverError.notConfigured
    }

    func stop() {
        onStreamingChanged?(false)
    }

    func updatePlaybackState(isPlaying: Bool) {
        _ = isPlaying
    }

    func updatePlaybackProgress(elapsedSeconds: Double?, durationSeconds: Double?) {
        _ = elapsedSeconds
        _ = durationSeconds
    }
}

func makeWebRTCReceiver() -> WebRTCReceiver {
#if canImport(WebKit)
    NativeWebRTCReceiver()
#else
    StubWebRTCReceiver()
#endif
}
