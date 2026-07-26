import Foundation

nonisolated enum FloatProtocol {
    static let version = 2

    enum MessageType {
        static let authChallenge = "authChallenge"
        static let authResponse = "authResponse"
        static let authResult = "authResult"
        static let hello = "hello"
        static let state = "state"
        static let start = "start"
        static let offer = "offer"
        static let answer = "answer"
        static let ice = "ice"
        static let stop = "stop"
        static let playback = "playback"
        static let seek = "seek"
        static let qualityHint = "qualityHint"
        static let autoStartBackground = "autoStartBackground"
        static let autoStopForeground = "autoStopForeground"
        static let error = "error"
        static let debug = "debug"
    }
}

nonisolated enum ProtocolValidationError: LocalizedError, Equatable {
    case malformedJSON
    case unsupportedVersion
    case invalidMessage(String)
    case limitExceeded(String)
    case invalidState(String)
    case rateLimitExceeded

    var errorDescription: String? {
        switch self {
        case .malformedJSON:
            return "Malformed JSON."
        case .unsupportedVersion:
            return "Unsupported protocol version."
        case .invalidMessage(let field):
            return "Invalid protocol field: \(field)."
        case .limitExceeded(let field):
            return "Protocol limit exceeded: \(field)."
        case .invalidState(let message):
            return "Message is not valid in the current connection state: \(message)."
        case .rateLimitExceeded:
            return "State update rate limit exceeded."
        }
    }
}

nonisolated enum ProtocolMessageEncoder {
    static func encodeVersionedPayload(_ payload: [String: Any]) throws -> Data {
        var versionedPayload = payload
        versionedPayload["version"] = FloatProtocol.version
        let data = try JSONSerialization.data(
            withJSONObject: versionedPayload,
            options: []
        )
        guard data.count <= ProtocolLimits.maximumWebSocketMessageBytes else {
            throw ProtocolValidationError.limitExceeded("outbound message")
        }
        return data
    }
}

nonisolated struct ProtocolEnvelope: Decodable {
    let type: String
    let version: Int?
}

nonisolated struct AuthenticationResponseMessage: Decodable {
    let type: String
    let version: Int
    let proof: String
}

nonisolated struct AuthenticationChallengeMessage: Encodable {
    let type = FloatProtocol.MessageType.authChallenge
    let version = FloatProtocol.version
    let origin: String
    let nonce: String
}

nonisolated struct AuthenticationResultMessage: Encodable {
    let type = FloatProtocol.MessageType.authResult
    let version = FloatProtocol.version
    let authenticated: Bool
}

nonisolated struct StateMessage: Decodable {
    let type: String
    let version: Int
    let tabs: [TabState]

    func validate() throws {
        try ProtocolValidator.requireVersion(version)
        guard tabs.count <= ProtocolLimits.maximumTabs else {
            throw ProtocolValidationError.limitExceeded("tabs")
        }
        for tab in tabs {
            try tab.validate()
        }
    }
}

nonisolated struct OfferMessage: Decodable {
    let type: String
    let version: Int
    let tabId: Int
    let videoId: String
    let generation: Int
    let sdp: String

    func validate() throws {
        try ProtocolValidator.requireVersion(version)
        try ProtocolValidator.requireTabID(tabId)
        try ProtocolValidator.requireVideoID(videoId)
        try ProtocolValidator.requireMediaGeneration(generation)
        try ProtocolValidator.requireNonemptyUTF8(
            sdp,
            maximumBytes: ProtocolLimits.maximumSDPBytes,
            field: "sdp"
        )
    }
}

nonisolated struct AnswerMessage: Encodable {
    let type: String
    let version = FloatProtocol.version
    let tabId: Int
    let videoId: String
    let generation: Int
    let sdp: String
}

nonisolated struct IceMessage: Decodable {
    let type: String
    let version: Int
    let tabId: Int
    let videoId: String
    let generation: Int
    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int?

    func validate() throws {
        try ProtocolValidator.requireVersion(version)
        try ProtocolValidator.requireTabID(tabId)
        try ProtocolValidator.requireVideoID(videoId)
        try ProtocolValidator.requireMediaGeneration(generation)
        try ProtocolValidator.requireNonemptyUTF8(
            candidate,
            maximumBytes: ProtocolLimits.maximumICECandidateBytes,
            field: "candidate"
        )
        if let sdpMid {
            try ProtocolValidator.requireUTF8(
                sdpMid,
                maximumBytes: ProtocolLimits.maximumVideoIDBytes,
                field: "sdpMid"
            )
        }
        if let sdpMLineIndex, !(0...65_535).contains(sdpMLineIndex) {
            throw ProtocolValidationError.invalidMessage("sdpMLineIndex")
        }
    }
}

nonisolated struct OutgoingIceMessage: Encodable {
    let type: String
    let version = FloatProtocol.version
    let tabId: Int
    let videoId: String
    let generation: Int
    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int?
}

nonisolated struct QualityHintMessage: Encodable {
    let type: String
    let version = FloatProtocol.version
    let tabId: Int
    let videoId: String
    let profile: String
    let pipWidth: Int?
    let pipHeight: Int?
}

nonisolated struct ErrorMessage: Decodable {
    let type: String
    let version: Int
    let reason: String?
    let tabId: Int?
    let videoId: String?

    func validate() throws {
        try ProtocolValidator.requireVersion(version)
        if let reason {
            try ProtocolValidator.requireUTF8(
                reason,
                maximumBytes: ProtocolLimits.maximumDiagnosticPayloadBytes,
                field: "error.reason"
            )
        }
        if let tabId {
            try ProtocolValidator.requireTabID(tabId)
        }
        if let videoId {
            try ProtocolValidator.requireVideoID(videoId)
        }
    }
}

nonisolated struct DebugMessage: Decodable {
    let type: String
    let version: Int
    let source: String?
    let event: String?
    let tabId: Int?
    let frameId: Int?
    let url: String?
    let payload: BoundedJSONValue?

    func validate() throws {
        try ProtocolValidator.requireVersion(version)
        if let source {
            try ProtocolValidator.requireUTF8(
                source,
                maximumBytes: ProtocolLimits.maximumTitleBytes,
                field: "debug.source"
            )
        }
        if let event {
            try ProtocolValidator.requireUTF8(
                event,
                maximumBytes: ProtocolLimits.maximumTitleBytes,
                field: "debug.event"
            )
        }
        if let tabId {
            try ProtocolValidator.requireTabID(tabId)
        }
        if let frameId, frameId < 0 {
            throw ProtocolValidationError.invalidMessage("debug.frameId")
        }
        if let url {
            try ProtocolValidator.requireUTF8(
                url,
                maximumBytes: ProtocolLimits.maximumURLBytes,
                field: "debug.url"
            )
        }
        if let payload {
            guard payload.contentByteCount
                    <= ProtocolLimits.maximumDiagnosticPayloadBytes
            else {
                throw ProtocolValidationError.limitExceeded("debug.payload")
            }
        }
    }
}

nonisolated indirect enum BoundedJSONValue: Decodable {
    private static let maximumCollectionItems = 64

    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: BoundedJSONValue])
    case array([BoundedJSONValue])
    case null

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            guard keyed.allKeys.count <= Self.maximumCollectionItems else {
                throw ProtocolValidationError.limitExceeded("debug object")
            }
            var object: [String: BoundedJSONValue] = [:]
            for key in keyed.allKeys {
                object[key.stringValue] = try keyed.decode(BoundedJSONValue.self, forKey: key)
            }
            self = .object(object)
            return
        }

        if var unkeyed = try? decoder.unkeyedContainer() {
            if let count = unkeyed.count, count > Self.maximumCollectionItems {
                throw ProtocolValidationError.limitExceeded("debug array")
            }
            var values: [BoundedJSONValue] = []
            while !unkeyed.isAtEnd {
                guard values.count < Self.maximumCollectionItems else {
                    throw ProtocolValidationError.limitExceeded("debug array")
                }
                values.append(try unkeyed.decode(BoundedJSONValue.self))
            }
            self = .array(values)
            return
        }

        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(String.self) {
            self = .string(value)
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(Double.self), value.isFinite {
            self = .number(value)
        } else {
            throw ProtocolValidationError.invalidMessage("debug payload")
        }
    }

    var redactedDescription: String {
        switch self {
        case .string(let value):
            return "string(\(value.utf8.count) bytes)"
        case .number:
            return "number"
        case .bool:
            return "boolean"
        case .object(let object):
            return "object(keys: \(object.keys.sorted().joined(separator: ",")))"
        case .array(let values):
            return "array(count: \(values.count))"
        case .null:
            return "null"
        }
    }

    var contentByteCount: Int {
        switch self {
        case .string(let value):
            return value.utf8.count
        case .number:
            return 32
        case .bool:
            return 5
        case .object(let object):
            return object.reduce(2) { total, entry in
                total + entry.key.utf8.count + entry.value.contentByteCount + 4
            }
        case .array(let values):
            return values.reduce(2) { total, value in
                total + value.contentByteCount + 1
            }
        case .null:
            return 4
        }
    }
}

nonisolated private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

nonisolated struct TabState: Decodable, Identifiable {
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

    func validate() throws {
        try ProtocolValidator.requireTabID(tabId)
        try ProtocolValidator.requireUTF8(
            title,
            maximumBytes: ProtocolLimits.maximumTitleBytes,
            field: "tab.title"
        )
        try ProtocolValidator.requireUTF8(
            url,
            maximumBytes: ProtocolLimits.maximumURLBytes,
            field: "tab.url"
        )
        guard videos.count <= ProtocolLimits.maximumVideosPerTab else {
            throw ProtocolValidationError.limitExceeded("videos per tab")
        }
        for video in videos {
            try video.validate()
        }
    }
}

nonisolated struct VideoState: Decodable, Identifiable {
    let videoId: String
    let playing: Bool?
    let muted: Bool?
    let resolution: String?
    let currentTime: Double?
    let duration: Double?

    var id: String { videoId }

    func validate() throws {
        try ProtocolValidator.requireVideoID(videoId)
        if let resolution {
            try ProtocolValidator.requireUTF8(
                resolution,
                maximumBytes: 64,
                field: "video.resolution"
            )
        }
        if let currentTime,
           (!currentTime.isFinite || currentTime < 0)
        {
            throw ProtocolValidationError.invalidMessage("video.currentTime")
        }
        if let duration,
           (!duration.isFinite || duration <= 0)
        {
            throw ProtocolValidationError.invalidMessage("video.duration")
        }
    }
}

nonisolated enum ProtocolValidator {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= ProtocolLimits.maximumWebSocketMessageBytes else {
            throw ProtocolValidationError.limitExceeded("WebSocket message")
        }
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [])
            try validateJSONComplexity(object)
            return try JSONDecoder().decode(type, from: data)
        } catch let error as ProtocolValidationError {
            throw error
        } catch {
            throw ProtocolValidationError.malformedJSON
        }
    }

    static func requireVersion(_ version: Int?) throws {
        guard version == FloatProtocol.version else {
            throw ProtocolValidationError.unsupportedVersion
        }
    }

    private static func validateJSONComplexity(_ root: Any) throws {
        let maximumDepth = 16
        let maximumNodes = 4_096
        var stack: [(value: Any, depth: Int)] = [(root, 0)]
        var nodeCount = 0

        while let entry = stack.popLast() {
            nodeCount += 1
            guard nodeCount <= maximumNodes else {
                throw ProtocolValidationError.limitExceeded("JSON values")
            }
            guard entry.depth <= maximumDepth else {
                throw ProtocolValidationError.limitExceeded("JSON depth")
            }

            if let array = entry.value as? [Any] {
                guard array.count <= ProtocolLimits.maximumTabs else {
                    throw ProtocolValidationError.limitExceeded("JSON array")
                }
                stack.append(
                    contentsOf: array.map { ($0, entry.depth + 1) }
                )
            } else if let object = entry.value as? [String: Any] {
                guard object.count <= 64 else {
                    throw ProtocolValidationError.limitExceeded("JSON object")
                }
                stack.append(
                    contentsOf: object.values.map { ($0, entry.depth + 1) }
                )
            }
        }
    }

    static func requireTabID(_ tabID: Int) throws {
        guard tabID >= 0, tabID <= Int(Int32.max) else {
            throw ProtocolValidationError.invalidMessage("tabId")
        }
    }

    static func requireVideoID(_ videoID: String) throws {
        try requireNonemptyUTF8(
            videoID,
            maximumBytes: ProtocolLimits.maximumVideoIDBytes,
            field: "videoId"
        )
    }

    static func requireMediaGeneration(_ generation: Int) throws {
        guard generation > 0, generation <= Int(Int32.max) else {
            throw ProtocolValidationError.invalidMessage("generation")
        }
    }

    static func requireUTF8(
        _ value: String,
        maximumBytes: Int,
        field: String
    ) throws {
        guard value.utf8.count <= maximumBytes else {
            throw ProtocolValidationError.limitExceeded(field)
        }
    }

    static func requireNonemptyUTF8(
        _ value: String,
        maximumBytes: Int,
        field: String
    ) throws {
        guard !value.isEmpty else {
            throw ProtocolValidationError.invalidMessage(field)
        }
        try requireUTF8(value, maximumBytes: maximumBytes, field: field)
    }
}
