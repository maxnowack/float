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
        static let debug = "debug"
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

struct AnswerMessage: Encodable {
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

struct OutgoingIceMessage: Encodable {
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

struct DebugMessage: Decodable {
    let type: String
    let source: String?
    let event: String?
    let tabId: Int?
    let frameId: Int?
    let url: String?
    let payload: StringOrAnyCodable?
}

struct StringOrAnyCodable: Decodable {
    let rawDescription: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let string = try? container.decode(String.self) {
            rawDescription = string
            return
        }

        if let intValue = try? container.decode(Int.self) {
            rawDescription = String(intValue)
            return
        }

        if let boolValue = try? container.decode(Bool.self) {
            rawDescription = String(boolValue)
            return
        }

        if let doubleValue = try? container.decode(Double.self) {
            rawDescription = String(doubleValue)
            return
        }

        if let dictionary = try? container.decode([String: StringOrAnyCodable].self) {
            rawDescription = dictionary
                .map { "\($0.key): \($0.value.rawDescription)" }
                .sorted()
                .joined(separator: ", ")
            return
        }

        if let array = try? container.decode([StringOrAnyCodable].self) {
            rawDescription = array.map(\.rawDescription).joined(separator: ", ")
            return
        }

        rawDescription = "unserializable"
    }
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
