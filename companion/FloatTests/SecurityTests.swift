import Foundation
import XCTest
@testable import Float

final class SecurityTests: XCTestCase {
    private struct HMACTestVector: Decodable {
        let version: Int
        let origin: String
        let secret: String
        let nonce: String
        let canonicalHex: String
        let proof: String
    }

    func testCredentialGenerationAndStorageAbstraction() throws {
        let store = InMemoryPairingCredentialStore()
        var generation = UInt8(0)
        let manager = PairingCredentialManager(
            store: store,
            randomBytes: { count in
                defer { generation &+= 1 }
                return Data(repeating: generation, count: count)
            }
        )

        let first = try manager.credential()
        XCTAssertEqual(first, Data(repeating: 0, count: 32))
        XCTAssertEqual(try manager.credential(), first)
        let rotated = try manager.rotate()
        XCTAssertEqual(rotated, Data(repeating: 1, count: 32))
        XCTAssertEqual(store.credential, rotated)
        try manager.reset()
        XCTAssertNil(store.credential)
    }

    func testSharedCanonicalHMACVector() throws {
        let vector = try loadVector()
        XCTAssertEqual(vector.version, FloatProtocol.version)
        let secret = try XCTUnwrap(Base64URL.decode(vector.secret))
        let canonical = FloatAuthentication.canonicalInput(
            origin: vector.origin,
            nonce: vector.nonce
        )
        XCTAssertEqual(canonical.hexString, vector.canonicalHex)
        XCTAssertEqual(
            Base64URL.encode(
                FloatAuthentication.proof(
                    secret: secret,
                    origin: vector.origin,
                    nonce: vector.nonce
                )
            ),
            vector.proof
        )
    }

    func testConstantTimeVerificationFunctionalBehavior() throws {
        let vector = try loadVector()
        let expected = try XCTUnwrap(Base64URL.decode(vector.proof))
        XCTAssertTrue(FloatAuthentication.constantTimeEqual(expected, expected))

        var changed = expected
        changed[changed.startIndex] ^= 1
        XCTAssertFalse(FloatAuthentication.constantTimeEqual(expected, changed))
        XCTAssertFalse(
            FloatAuthentication.constantTimeEqual(
                expected,
                Data(expected.dropLast())
            )
        )
        XCTAssertFalse(
            FloatAuthentication.constantTimeEqual(
                Data([0]),
                Data(repeating: 0, count: 257)
            )
        )
    }

    func testAuthenticationStateMachineRejectsInvalidReplayAndExpiry() throws {
        let vector = try loadVector()
        let secret = try XCTUnwrap(Base64URL.decode(vector.secret))
        let issuedAt = Date(timeIntervalSince1970: 1_000)

        let valid = AuthenticationSession(
            origin: vector.origin,
            nonce: vector.nonce,
            issuedAt: issuedAt
        )
        XCTAssertEqual(
            valid.authenticate(
                version: 2,
                encodedProof: vector.proof,
                secret: secret,
                now: issuedAt
            ),
            .authenticated
        )
        XCTAssertEqual(
            valid.authenticate(
                version: 2,
                encodedProof: vector.proof,
                secret: secret,
                now: issuedAt
            ),
            .replay
        )

        let wrong = AuthenticationSession(
            origin: vector.origin,
            nonce: vector.nonce,
            issuedAt: issuedAt
        )
        XCTAssertEqual(
            wrong.authenticate(
                version: 2,
                encodedProof: Base64URL.encode(Data(repeating: 0, count: 32)),
                secret: secret,
                now: issuedAt
            ),
            .reject
        )

        let expired = AuthenticationSession(
            origin: vector.origin,
            nonce: vector.nonce,
            issuedAt: issuedAt
        )
        XCTAssertEqual(
            expired.authenticate(
                version: 2,
                encodedProof: vector.proof,
                secret: secret,
                now: issuedAt.addingTimeInterval(
                    ProtocolLimits.authenticationTimeout + 1
                )
            ),
            .expired
        )

        let attempts = AuthenticationSession(
            origin: vector.origin,
            nonce: vector.nonce,
            issuedAt: issuedAt
        )
        XCTAssertEqual(
            attempts.authenticate(
                version: nil,
                encodedProof: nil,
                secret: secret,
                now: issuedAt
            ),
            .retry
        )
        XCTAssertEqual(
            attempts.authenticate(
                version: nil,
                encodedProof: nil,
                secret: secret,
                now: issuedAt
            ),
            .retry
        )
        XCTAssertEqual(
            attempts.authenticate(
                version: nil,
                encodedProof: nil,
                secret: secret,
                now: issuedAt
            ),
            .reject
        )
    }

    func testOriginValidation() {
        XCTAssertNotNil(
            ExtensionOrigin.validate(
                "chrome-extension://abcdefghijklmnopabcdefghijklmnop"
            )
        )
        XCTAssertNotNil(
            ExtensionOrigin.validate(
                "moz-extension://12345678-1234-1234-1234-123456789abc"
            )
        )

        for origin in [
            nil,
            "",
            "null",
            "http://example.com",
            "https://example.com",
            "file://",
            "chrome-extension://abcdefghijklmnopabcdefghijklmnop/path",
            "chrome-extension://abcdefghijklmnopabcdefghijklmnop?query",
            "chrome-extension://abcdefghijklmnopabcdefghijklmnop#fragment",
            "chrome-extension://abcdefghijklmnopabcdefghijklmnop:443",
            "chrome-extension://zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz",
            "moz-extension://not-a-uuid",
        ] {
            XCTAssertNil(ExtensionOrigin.validate(origin))
        }
    }

    func testHandshakeTokenAndConnectionAdmissionBoundaries() {
        XCTAssertTrue(
            WebSocketHandshakeToken.validate(
                "float-v2.ABCDEFGHIJKLMNOPQRSTUV"
            )
        )
        XCTAssertFalse(
            WebSocketHandshakeToken.validate(
                "float-v2.ABCDEFGHIJKLMNOPQRSTU"
            )
        )
        XCTAssertFalse(
            WebSocketHandshakeToken.validate(
                "float-v2.ABCDEFGHIJKLMNOPQRSTU!"
            )
        )

        XCTAssertTrue(
            ConnectionLimitPolicy.permits(
                totalConnections: ProtocolLimits.maximumConnections - 1,
                unauthenticatedConnections:
                    ProtocolLimits.maximumUnauthenticatedConnections - 1
            )
        )
        XCTAssertFalse(
            ConnectionLimitPolicy.permits(
                totalConnections: ProtocolLimits.maximumConnections,
                unauthenticatedConnections: 0
            )
        )
        XCTAssertFalse(
            ConnectionLimitPolicy.permits(
                totalConnections: 1,
                unauthenticatedConnections:
                    ProtocolLimits.maximumUnauthenticatedConnections
            )
        )
    }

    func testInboundMessageProcessingIsBackpressuredAndByteBounded() {
        var gate = InboundMessageGate(
            maximumBytes: ProtocolLimits.maximumWebSocketMessageBytes
        )

        XCTAssertTrue(
            gate.beginProcessing(
                byteCount: ProtocolLimits.maximumWebSocketMessageBytes
            )
        )
        XCTAssertEqual(gate.retainedMessageCount, 1)
        XCTAssertEqual(
            gate.retainedByteCount,
            ProtocolLimits.maximumWebSocketMessageBytes
        )

        for _ in 0..<1_000 {
            XCTAssertFalse(gate.beginProcessing(byteCount: 1))
            XCTAssertEqual(gate.retainedMessageCount, 1)
            XCTAssertEqual(
                gate.retainedByteCount,
                ProtocolLimits.maximumWebSocketMessageBytes
            )
        }

        gate.finishProcessing()
        XCTAssertEqual(gate.retainedMessageCount, 0)
        XCTAssertEqual(gate.retainedByteCount, 0)
        XCTAssertTrue(gate.beginProcessing(byteCount: 1))
        gate.finishProcessing()

        XCTAssertFalse(gate.beginProcessing(byteCount: -1))
        XCTAssertFalse(
            gate.beginProcessing(
                byteCount: ProtocolLimits.maximumWebSocketMessageBytes + 1
            )
        )
        XCTAssertEqual(gate.retainedMessageCount, 0)
        XCTAssertEqual(gate.retainedByteCount, 0)
    }

    func testSensitivePasteboardClearsOnlyItsUnchangedValue() {
        XCTAssertTrue(
            SensitivePasteboard.shouldClear(
                requestedValue: "secret",
                expectedValue: "secret",
                expectedChangeCount: 5,
                actualValue: "secret",
                actualChangeCount: 5
            )
        )
        XCTAssertFalse(
            SensitivePasteboard.shouldClear(
                requestedValue: "secret",
                expectedValue: "secret",
                expectedChangeCount: 5,
                actualValue: "replacement",
                actualChangeCount: 6
            )
        )
        XCTAssertFalse(
            SensitivePasteboard.shouldClear(
                requestedValue: "secret",
                expectedValue: "secret",
                expectedChangeCount: 5,
                actualValue: "secret",
                actualChangeCount: 7
            )
        )
    }

    func testMultipleAuthenticatedClientsAndProtocolStateTransitions() throws {
        var registry = AuthenticatedClientRegistry<String>()
        XCTAssertNil(registry.insert("first", origin: "chrome-extension://first"))
        XCTAssertNil(registry.insert("second", origin: "moz-extension://second"))
        XCTAssertEqual(registry.clients, ["first", "second"])
        XCTAssertTrue(registry.contains("first"))
        XCTAssertTrue(registry.contains("second"))
        XCTAssertEqual(
            registry.insert("replacement", origin: "chrome-extension://first"),
            "first"
        )
        XCTAssertEqual(registry.clients, ["replacement", "second"])
        XCTAssertFalse(registry.contains("first"))
        XCTAssertTrue(registry.contains("replacement"))
        XCTAssertTrue(registry.remove("replacement"))
        XCTAssertFalse(registry.remove("replacement"))
        XCTAssertEqual(registry.clients, ["second"])
        registry.clear()
        XCTAssertTrue(registry.isEmpty)

        var state = ClientProtocolStateMachine()
        XCTAssertThrowsError(
            try state.accept(messageType: FloatProtocol.MessageType.state)
        )
        try state.accept(messageType: FloatProtocol.MessageType.authResponse)
        try state.authenticationSucceeded()
        XCTAssertThrowsError(
            try state.accept(messageType: FloatProtocol.MessageType.offer)
        )
        try state.accept(messageType: FloatProtocol.MessageType.hello)
        XCTAssertEqual(state.state, .ready)
        XCTAssertThrowsError(
            try state.accept(messageType: FloatProtocol.MessageType.authResponse)
        )
        try state.accept(messageType: FloatProtocol.MessageType.state)
        state.close()
        XCTAssertEqual(state.state, .closed)
        XCTAssertThrowsError(
            try state.accept(messageType: FloatProtocol.MessageType.state)
        )
    }

    private func loadVector() throws -> HMACTestVector {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot
            .appendingPathComponent("protocol/test-vectors/hmac-v2.json")
        return try JSONDecoder().decode(
            HMACTestVector.self,
            from: Data(contentsOf: url)
        )
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
