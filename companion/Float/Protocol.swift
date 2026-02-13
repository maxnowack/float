import Foundation

enum FloatProtocol {
    static let version = 1

    enum MessageType {
        static let hello = "hello"
        static let state = "state"
        static let start = "start"
        static let offer = "offer"
        static let answer = "answer"
        static let ice = "ice"
        static let stop = "stop"
        static let error = "error"
    }
}

struct ProtocolEnvelope: Decodable {
    let type: String
    let version: Int?
}

struct StateMessage: Decodable {
    let type: String
    let tabs: [TabState]
}

struct OfferMessage: Decodable {
    let type: String
    let tabId: Int
    let videoId: String
    let sdp: String
}

struct IceMessage: Decodable {
    let type: String
    let tabId: Int
    let videoId: String
    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int?
}

struct ErrorMessage: Decodable {
    let type: String
    let reason: String?
    let tabId: Int?
    let videoId: String?
}

struct TabState: Decodable, Identifiable {
    let tabId: Int
    let title: String
    let url: String
    let videos: [VideoState]

    var id: Int { tabId }
    var domain: String {
        guard let host = URL(string: url)?.host, !host.isEmpty else {
            return "unknown"
        }
        return host
    }
}

struct VideoState: Decodable, Identifiable {
    let videoId: String
    let playing: Bool?
    let muted: Bool?
    let resolution: String?

    var id: String { videoId }
}
