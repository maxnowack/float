import CryptoKit
import Foundation
import Security

nonisolated enum ProtocolLimits {
    static let maximumWebSocketMessageBytes = 512 * 1024
    static let maximumTitleBytes = 512
    static let maximumURLBytes = 8 * 1024
    static let maximumVideoIDBytes = 256
    static let maximumTabs = 256
    static let maximumVideosPerTab = 64
    static let maximumSDPBytes = 256 * 1024
    static let maximumICECandidateBytes = 8 * 1024
    static let maximumPendingICECandidates = 256
    static let maximumDiagnosticPayloadBytes = 16 * 1024
    static let maximumConnections = 8
    static let maximumUnauthenticatedConnections = 4
    static let maximumAuthenticationAttempts = 3
    static let maximumStateUpdatesPerSecond = 20
    static let stateUpdateBurst = 40
    static let connectionTimeout: TimeInterval = 5
    static let authenticationTimeout: TimeInterval = 10
    static let handshakeRecordTimeout: TimeInterval = 10
}

nonisolated enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        guard !string.isEmpty else { return nil }
        guard string.unicodeScalars.allSatisfy({
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
                .contains($0)
        }) else {
            return nil
        }

        let remainder = string.utf8.count % 4
        guard remainder != 1 else { return nil }
        let padding = remainder == 0 ? "" : String(repeating: "=", count: 4 - remainder)
        let base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + padding
        return Data(base64Encoded: base64, options: [])
    }
}

nonisolated enum SecureRandom {
    enum Error: Swift.Error {
        case generationFailed(OSStatus)
    }

    static func bytes(count: Int) throws -> Data {
        precondition(count > 0)
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return errSecAllocate
            }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw Error.generationFailed(status)
        }
        return data
    }
}

nonisolated protocol PairingCredentialStore {
    func load() throws -> Data?
    func save(_ credential: Data) throws
    func delete() throws
}

nonisolated enum PairingCredentialStoreError: LocalizedError {
    case keychain(OSStatus)
    case invalidCredentialLength

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain error \(status)"
        case .invalidCredentialLength:
            return "The pairing credential must contain exactly 32 bytes."
        }
    }
}

nonisolated final class KeychainPairingCredentialStore: PairingCredentialStore {
    private let service: String
    private let account: String

    init(
        service: String = "de.unsou.Float.pairing",
        account: String = "protocol-v2"
    ) {
        self.service = service
        self.account = account
    }

    func load() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw PairingCredentialStoreError.keychain(status)
        }
        guard let credential = item as? Data, credential.count == FloatAuthentication.secretByteCount else {
            throw PairingCredentialStoreError.invalidCredentialLength
        }
        return credential
    }

    func save(_ credential: Data) throws {
        guard credential.count == FloatAuthentication.secretByteCount else {
            throw PairingCredentialStoreError.invalidCredentialLength
        }

        let attributes: [String: Any] = [
            kSecValueData as String: credential,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw PairingCredentialStoreError.keychain(updateStatus)
        }

        var item = baseQuery
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw PairingCredentialStoreError.keychain(addStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PairingCredentialStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

nonisolated final class InMemoryPairingCredentialStore: PairingCredentialStore {
    var credential: Data?

    init(credential: Data? = nil) {
        self.credential = credential
    }

    func load() throws -> Data? {
        credential
    }

    func save(_ credential: Data) throws {
        self.credential = credential
    }

    func delete() throws {
        credential = nil
    }
}

nonisolated final class PairingCredentialManager {
    private let store: PairingCredentialStore
    private let randomBytes: (Int) throws -> Data

    init(
        store: PairingCredentialStore,
        randomBytes: @escaping (Int) throws -> Data = SecureRandom.bytes
    ) {
        self.store = store
        self.randomBytes = randomBytes
    }

    func credential() throws -> Data {
        if let existing = try store.load() {
            guard existing.count == FloatAuthentication.secretByteCount else {
                throw PairingCredentialStoreError.invalidCredentialLength
            }
            return existing
        }
        return try rotate()
    }

    func displayCredential() throws -> String {
        Base64URL.encode(try credential())
    }

    @discardableResult
    func rotate() throws -> Data {
        let next = try randomBytes(FloatAuthentication.secretByteCount)
        guard next.count == FloatAuthentication.secretByteCount else {
            throw PairingCredentialStoreError.invalidCredentialLength
        }
        try store.save(next)
        return next
    }

    func reset() throws {
        try store.delete()
    }
}

nonisolated enum ExtensionOrigin {
    enum Kind: Equatable {
        case chrome
        case firefox
    }

    struct Validated: Equatable {
        let value: String
        let kind: Kind
    }

    static func validate(_ rawValue: String?) -> Validated? {
        guard let rawValue, !rawValue.isEmpty, rawValue != "null" else {
            return nil
        }
        guard rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        guard let components = URLComponents(string: rawValue),
              let scheme = components.scheme,
              let host = components.host,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty
        else {
            return nil
        }

        switch scheme.lowercased() {
        case "chrome-extension":
            guard rawValue.hasPrefix("chrome-extension://"),
                  host.range(of: "^[a-p]{32}$", options: .regularExpression) != nil
            else {
                return nil
            }
            return Validated(value: rawValue, kind: .chrome)
        case "moz-extension":
            guard rawValue.hasPrefix("moz-extension://"),
                  host.range(
                      of: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$",
                      options: .regularExpression
                  ) != nil
            else {
                return nil
            }
            return Validated(value: rawValue, kind: .firefox)
        default:
            return nil
        }
    }
}

nonisolated enum WebSocketHandshakeToken {
    static let prefix = "float-v2."
    private static let tokenCharacterSet = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )

    static func validate(_ value: String) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        let token = String(value.dropFirst(prefix.count))
        guard token.utf8.count == 22 else { return false }
        return token.unicodeScalars.allSatisfy { tokenCharacterSet.contains($0) }
    }
}

nonisolated enum FloatAuthentication {
    static let secretByteCount = 32
    static let nonceByteCount = 32
    static let proofByteCount = 32

    static func canonicalInput(origin: String, nonce: String) -> Data {
        Data(
            """
            Float-Pairing-V2
            version=2
            origin=\(origin)
            nonce=\(nonce)

            """.utf8
        )
    }

    static func proof(secret: Data, origin: String, nonce: String) -> Data {
        let key = SymmetricKey(data: secret)
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: canonicalInput(origin: origin, nonce: nonce),
            using: key
        )
        return Data(authenticationCode)
    }

    static func verify(
        encodedProof: String,
        secret: Data,
        origin: String,
        nonce: String
    ) -> Bool {
        guard let supplied = Base64URL.decode(encodedProof) else { return false }
        let expected = proof(secret: secret, origin: origin, nonce: nonce)
        return constantTimeEqual(expected, supplied)
    }

    static func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
        let maximumCount = max(left.count, right.count)
        var difference = UInt(left.count ^ right.count)
        for index in 0..<maximumCount {
            let leftByte = index < left.count ? left[index] : 0
            let rightByte = index < right.count ? right[index] : 0
            difference |= UInt(leftByte ^ rightByte)
        }
        return difference == 0
    }
}

nonisolated final class AuthenticationSession {
    enum State: Equatable {
        case challenged
        case authenticated
        case failed
    }

    enum Decision: Equatable {
        case authenticated
        case retry
        case reject
        case expired
        case replay
    }

    let origin: String
    let nonce: String
    let expiresAt: Date

    private(set) var state: State = .challenged
    private(set) var attempts = 0
    private var nonceConsumed = false

    init(origin: String, nonce: String, issuedAt: Date) {
        self.origin = origin
        self.nonce = nonce
        self.expiresAt = issuedAt.addingTimeInterval(ProtocolLimits.authenticationTimeout)
    }

    func authenticate(
        version: Int?,
        encodedProof: String?,
        secret: Data,
        now: Date
    ) -> Decision {
        guard state == .challenged else {
            return nonceConsumed ? .replay : .reject
        }
        guard now <= expiresAt else {
            state = .failed
            nonceConsumed = true
            return .expired
        }

        attempts += 1
        guard attempts <= ProtocolLimits.maximumAuthenticationAttempts else {
            state = .failed
            nonceConsumed = true
            return .reject
        }
        guard version == FloatProtocol.version,
              let encodedProof,
              let decodedProof = Base64URL.decode(encodedProof),
              decodedProof.count == FloatAuthentication.proofByteCount
        else {
            if attempts == ProtocolLimits.maximumAuthenticationAttempts {
                state = .failed
                nonceConsumed = true
                return .reject
            }
            return .retry
        }

        nonceConsumed = true
        let expected = FloatAuthentication.proof(
            secret: secret,
            origin: origin,
            nonce: nonce
        )
        guard FloatAuthentication.constantTimeEqual(expected, decodedProof) else {
            state = .failed
            return .reject
        }

        state = .authenticated
        return .authenticated
    }
}

nonisolated struct StateUpdateRateLimiter {
    private(set) var tokens: Double
    private(set) var lastRefill: Date

    init(now: Date) {
        tokens = Double(ProtocolLimits.stateUpdateBurst)
        lastRefill = now
    }

    mutating func allow(now: Date) -> Bool {
        let elapsed = max(0, now.timeIntervalSince(lastRefill))
        tokens = min(
            Double(ProtocolLimits.stateUpdateBurst),
            tokens + elapsed * Double(ProtocolLimits.maximumStateUpdatesPerSecond)
        )
        lastRefill = now
        guard tokens >= 1 else {
            return false
        }
        tokens -= 1
        return true
    }
}

nonisolated struct BoundedCounter {
    let limit: Int
    private(set) var value = 0

    mutating func increment() -> Bool {
        guard value < limit else { return false }
        value += 1
        return true
    }

    mutating func reset() {
        value = 0
    }
}

nonisolated struct InboundMessageGate {
    let maximumBytes: Int
    private(set) var retainedMessageCount = 0
    private(set) var retainedByteCount = 0

    mutating func beginProcessing(byteCount: Int) -> Bool {
        guard retainedMessageCount == 0,
              byteCount >= 0,
              byteCount <= maximumBytes
        else {
            return false
        }
        retainedMessageCount = 1
        retainedByteCount = byteCount
        return true
    }

    mutating func finishProcessing() {
        retainedMessageCount = 0
        retainedByteCount = 0
    }
}

nonisolated enum ConnectionLimitPolicy {
    static func permits(
        totalConnections: Int,
        unauthenticatedConnections: Int
    ) -> Bool {
        totalConnections >= 0
            && unauthenticatedConnections >= 0
            && totalConnections < ProtocolLimits.maximumConnections
            && unauthenticatedConnections
                < ProtocolLimits.maximumUnauthenticatedConnections
    }
}

nonisolated struct AuthenticatedClientRegistry<ClientID: Equatable> {
    private var entries: [(origin: String, clientID: ClientID)] = []

    var clients: [ClientID] {
        entries.map(\.clientID)
    }

    var isEmpty: Bool {
        entries.isEmpty
    }

    @discardableResult
    mutating func insert(_ clientID: ClientID, origin: String) -> ClientID? {
        if let existingIndex = entries.firstIndex(
            where: { $0.origin == origin }
        ) {
            let replacedClientID = entries[existingIndex].clientID
            entries[existingIndex].clientID = clientID
            return replacedClientID == clientID ? nil : replacedClientID
        }
        entries.append((origin: origin, clientID: clientID))
        return nil
    }

    @discardableResult
    mutating func remove(_ clientID: ClientID) -> Bool {
        guard let index = entries.firstIndex(
            where: { $0.clientID == clientID }
        ) else {
            return false
        }
        entries.remove(at: index)
        return true
    }

    func contains(_ clientID: ClientID) -> Bool {
        entries.contains(where: { $0.clientID == clientID })
    }

    mutating func clear() {
        entries.removeAll()
    }
}

nonisolated struct ClientProtocolStateMachine {
    enum State: Equatable {
        case challenged
        case awaitingHello
        case ready
        case closed
    }

    private(set) var state: State = .challenged

    mutating func authenticationSucceeded() throws {
        guard state == .challenged else {
            throw ProtocolValidationError.invalidState("authentication result")
        }
        state = .awaitingHello
    }

    mutating func accept(messageType: String) throws {
        switch state {
        case .challenged:
            guard messageType == FloatProtocol.MessageType.authResponse else {
                throw ProtocolValidationError.invalidState("authentication required")
            }
        case .awaitingHello:
            guard messageType == FloatProtocol.MessageType.hello else {
                throw ProtocolValidationError.invalidState("hello required")
            }
            state = .ready
        case .ready:
            guard messageType != FloatProtocol.MessageType.authResponse,
                  messageType != FloatProtocol.MessageType.hello
            else {
                throw ProtocolValidationError.invalidState("message replay")
            }
        case .closed:
            throw ProtocolValidationError.invalidState("closed")
        }
    }

    mutating func close() {
        state = .closed
    }
}
