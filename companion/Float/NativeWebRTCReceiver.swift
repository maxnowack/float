#if canImport(WebRTC)
import AppKit
import Foundation
import WebRTC

final class NativeWebRTCReceiver: NSObject, WebRTCReceiver {
    var onLocalIceCandidate: ((LocalIceCandidate) -> Void)?

    private let peerFactory = RTCPeerConnectionFactory()
    private var peerConnection: RTCPeerConnection?
    private var currentTabId: Int?
    private var currentVideoId: String?
    private var currentVideoTrack: RTCVideoTrack?
    private var previewWindow: NSWindow?
    private var previewView: RTCMTLNSVideoView?

    func handleOffer(_ offer: OfferMessage) async throws -> String {
        let connection = try getOrCreatePeerConnection()
        currentTabId = offer.tabId
        currentVideoId = offer.videoId

        let remote = RTCSessionDescription(type: .offer, sdp: offer.sdp)
        try await setRemoteDescription(remote, on: connection)
        let answer = try await createAnswer(on: connection)
        try await setLocalDescription(answer, on: connection)
        return answer.sdp
    }

    func addRemoteIceCandidate(_ ice: IceMessage) async throws {
        guard let connection = peerConnection else {
            throw WebRTCReceiverError.missingPeerConnection
        }

        let candidate = RTCIceCandidate(
            sdp: ice.candidate,
            sdpMLineIndex: Int32(ice.sdpMLineIndex ?? 0),
            sdpMid: ice.sdpMid
        )
        try await connection.add(candidate)
    }

    func stop() {
        if let track = currentVideoTrack, let previewView {
            track.remove(previewView)
        }
        currentVideoTrack = nil
        previewView = nil
        previewWindow?.close()
        previewWindow = nil
        peerConnection?.close()
        peerConnection = nil
        currentTabId = nil
        currentVideoId = nil
    }

    private func getOrCreatePeerConnection() throws -> RTCPeerConnection {
        if let existing = peerConnection {
            return existing
        }

        let config = RTCConfiguration()
        config.iceServers = []
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = peerFactory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw WebRTCReceiverError.peerConnectionUnavailable
        }

        peerConnection = connection
        return connection
    }

    private func setRemoteDescription(_ description: RTCSessionDescription, on connection: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func createAnswer(on connection: RTCPeerConnection) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            connection.answer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let description else {
                    continuation.resume(throwing: WebRTCReceiverError.peerConnectionUnavailable)
                    return
                }

                continuation.resume(returning: description)
            }
        }
    }

    private func setLocalDescription(_ description: RTCSessionDescription, on connection: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

extension NativeWebRTCReceiver: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard let tabId = currentTabId, let videoId = currentVideoId else { return }
        onLocalIceCandidate?(
            LocalIceCandidate(
                tabId: tabId,
                videoId: videoId,
                candidate: candidate.sdp,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: Int(candidate.sdpMLineIndex)
            )
        )
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        if let track = transceiver.receiver.track as? RTCVideoTrack {
            attachVideoTrack(track)
        }
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams: [RTCMediaStream]
    ) {
        if let track = rtpReceiver.track as? RTCVideoTrack {
            attachVideoTrack(track)
        }
    }
}

private extension NativeWebRTCReceiver {
    func ensurePreviewSurface() -> RTCMTLNSVideoView {
        if let existing = previewView {
            return existing
        }

        let view = RTCMTLNSVideoView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 640, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Float Receiver (Debug)"
        window.contentView = view
        window.makeKeyAndOrderFront(nil)

        previewView = view
        previewWindow = window
        return view
    }

    func attachVideoTrack(_ track: RTCVideoTrack) {
        let view = ensurePreviewSurface()
        if let previous = currentVideoTrack, previous.trackId != track.trackId {
            previous.remove(view)
        }
        currentVideoTrack = track
        track.add(view)
    }
}
#endif
