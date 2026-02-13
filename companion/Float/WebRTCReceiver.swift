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
    func handleOffer(_ offer: OfferMessage) async throws -> String
    func addRemoteIceCandidate(_ ice: IceMessage) async throws
    func stop()
}

enum WebRTCReceiverError: LocalizedError {
    case notConfigured
    case peerConnectionUnavailable
    case missingPeerConnection

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "WebRTC receiver backend is not configured. Link a native WebRTC framework to continue."
        case .peerConnectionUnavailable:
            return "Failed to create WebRTC peer connection."
        case .missingPeerConnection:
            return "No active WebRTC peer connection."
        }
    }
}

final class StubWebRTCReceiver: WebRTCReceiver {
    var onLocalIceCandidate: ((LocalIceCandidate) -> Void)?

    func handleOffer(_ offer: OfferMessage) async throws -> String {
        _ = offer
        throw WebRTCReceiverError.notConfigured
    }

    func addRemoteIceCandidate(_ ice: IceMessage) async throws {
        _ = ice
        throw WebRTCReceiverError.notConfigured
    }

    func stop() {}
}

func makeWebRTCReceiver() -> WebRTCReceiver {
#if canImport(WebRTC)
    NativeWebRTCReceiver()
#else
    StubWebRTCReceiver()
#endif
}
