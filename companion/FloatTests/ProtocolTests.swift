import Foundation
import XCTest
@testable import Float

final class ProtocolTests: XCTestCase {
    func testVersionedPayloadEncoderAlwaysIncludesProtocolVersion() throws {
        let data = try ProtocolMessageEncoder.encodeVersionedPayload([
            "type": FloatProtocol.MessageType.hello,
            "source": "companion",
        ])
        let envelope = try ProtocolValidator.decode(
            ProtocolEnvelope.self,
            from: data
        )

        XCTAssertEqual(envelope.type, FloatProtocol.MessageType.hello)
        XCTAssertEqual(envelope.version, FloatProtocol.version)
    }

    func testMalformedAndOversizedJSONAreRejected() {
        XCTAssertThrowsError(
            try ProtocolValidator.decode(
                ProtocolEnvelope.self,
                from: Data("{".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? ProtocolValidationError, .malformedJSON)
        }

        let oversized = Data(
            repeating: 0x20,
            count: ProtocolLimits.maximumWebSocketMessageBytes + 1
        )
        XCTAssertThrowsError(
            try ProtocolValidator.decode(ProtocolEnvelope.self, from: oversized)
        ) { error in
            XCTAssertEqual(
                error as? ProtocolValidationError,
                .limitExceeded("WebSocket message")
            )
        }
    }

    func testStringAndCollectionLimitBoundaries() throws {
        try ProtocolValidator.requireUTF8(
            String(repeating: "a", count: ProtocolLimits.maximumTitleBytes),
            maximumBytes: ProtocolLimits.maximumTitleBytes,
            field: "title"
        )
        XCTAssertThrowsError(
            try ProtocolValidator.requireUTF8(
                String(repeating: "a", count: ProtocolLimits.maximumTitleBytes + 1),
                maximumBytes: ProtocolLimits.maximumTitleBytes,
                field: "title"
            )
        )

        let validTabs = Array(
            repeating: validTabObject,
            count: ProtocolLimits.maximumTabs
        )
        let valid = try makeStateData(tabs: validTabs)
        let validMessage = try ProtocolValidator.decode(
            StateMessage.self,
            from: valid
        )
        try validMessage.validate()

        let excessive = try makeStateData(
            tabs: validTabs + [validTabObject]
        )
        XCTAssertThrowsError(
            try ProtocolValidator.decode(StateMessage.self, from: excessive)
        )

        let maximumURL = String(
            repeating: "u",
            count: ProtocolLimits.maximumURLBytes
        )
        try ProtocolValidator.requireUTF8(
            maximumURL,
            maximumBytes: ProtocolLimits.maximumURLBytes,
            field: "url"
        )
        XCTAssertThrowsError(
            try ProtocolValidator.requireUTF8(
                maximumURL + "u",
                maximumBytes: ProtocolLimits.maximumURLBytes,
                field: "url"
            )
        )

        let maximumVideoID = String(
            repeating: "v",
            count: ProtocolLimits.maximumVideoIDBytes
        )
        try ProtocolValidator.requireVideoID(maximumVideoID)
        XCTAssertThrowsError(try ProtocolValidator.requireVideoID(""))
        XCTAssertThrowsError(
            try ProtocolValidator.requireVideoID(maximumVideoID + "v")
        )

        let video = VideoState(
            videoId: "video",
            playing: true,
            muted: false,
            resolution: "1920x1080",
            currentTime: 1,
            duration: 2
        )
        try TabState(
            tabId: 1,
            title: "Title",
            url: "https://example.com",
            videos: Array(
                repeating: video,
                count: ProtocolLimits.maximumVideosPerTab
            )
        ).validate()
        XCTAssertThrowsError(
            try TabState(
                tabId: 1,
                title: "Title",
                url: "https://example.com",
                videos: Array(
                    repeating: video,
                    count: ProtocolLimits.maximumVideosPerTab + 1
                )
            ).validate()
        )
    }

    func testInvalidNumbersAndDimensionsAreRejected() throws {
        XCTAssertThrowsError(
            try VideoState(
                videoId: "video",
                playing: true,
                muted: false,
                resolution: "1920x1080",
                currentTime: -.infinity,
                duration: 10
            ).validate()
        )
        XCTAssertThrowsError(
            try VideoState(
                videoId: "video",
                playing: true,
                muted: false,
                resolution: "1920x1080",
                currentTime: 1,
                duration: 0
            ).validate()
        )
        XCTAssertThrowsError(
            try IceMessage(
                type: FloatProtocol.MessageType.ice,
                version: 2,
                tabId: 1,
                videoId: "video",
                generation: 1,
                candidate: "candidate",
                sdpMid: "0",
                sdpMLineIndex: -1
            ).validate()
        )
    }

    func testUnsupportedVersionsAreRejected() throws {
        XCTAssertThrowsError(try ProtocolValidator.requireVersion(1)) { error in
            XCTAssertEqual(
                error as? ProtocolValidationError,
                .unsupportedVersion
            )
        }
        try ProtocolValidator.requireVersion(2)
    }

    func testICEQueueAndStateUpdateRatesAreBounded() {
        var counter = BoundedCounter(
            limit: ProtocolLimits.maximumPendingICECandidates
        )
        for _ in 0..<ProtocolLimits.maximumPendingICECandidates {
            XCTAssertTrue(counter.increment())
        }
        XCTAssertFalse(counter.increment())
        counter.reset()
        XCTAssertEqual(counter.value, 0)

        let now = Date(timeIntervalSince1970: 1_000)
        var limiter = StateUpdateRateLimiter(now: now)
        for _ in 0..<ProtocolLimits.stateUpdateBurst {
            XCTAssertTrue(limiter.allow(now: now))
        }
        XCTAssertFalse(limiter.allow(now: now))
        XCTAssertTrue(
            limiter.allow(
                now: now.addingTimeInterval(
                    1.01 / Double(ProtocolLimits.maximumStateUpdatesPerSecond)
                )
            )
        )
    }

    func testSDPAndICEBoundaryBehavior() throws {
        let validOffer = OfferMessage(
            type: FloatProtocol.MessageType.offer,
            version: 2,
            tabId: 1,
            videoId: String(
                repeating: "v",
                count: ProtocolLimits.maximumVideoIDBytes
            ),
            generation: Int(Int32.max),
            sdp: String(
                repeating: "s",
                count: ProtocolLimits.maximumSDPBytes
            )
        )
        try validOffer.validate()

        XCTAssertThrowsError(
            try OfferMessage(
                type: FloatProtocol.MessageType.offer,
                version: 2,
                tabId: 1,
                videoId: "video",
                generation: 1,
                sdp: String(
                    repeating: "s",
                    count: ProtocolLimits.maximumSDPBytes + 1
                )
            ).validate()
        )
        XCTAssertThrowsError(
            try IceMessage(
                type: FloatProtocol.MessageType.ice,
                version: 2,
                tabId: 1,
                videoId: "video",
                generation: 1,
                candidate: String(
                    repeating: "c",
                    count: ProtocolLimits.maximumICECandidateBytes + 1
                ),
                sdpMid: nil,
                sdpMLineIndex: nil
            ).validate()
        )

        try IceMessage(
            type: FloatProtocol.MessageType.ice,
            version: 2,
            tabId: 1,
            videoId: "video",
            generation: 1,
            candidate: String(
                repeating: "c",
                count: ProtocolLimits.maximumICECandidateBytes
            ),
            sdpMid: "0",
            sdpMLineIndex: 65_535
        ).validate()

        for invalidGeneration in [0, -1, Int(Int32.max) + 1] {
            XCTAssertThrowsError(
                try OfferMessage(
                    type: FloatProtocol.MessageType.offer,
                    version: 2,
                    tabId: 1,
                    videoId: "video",
                    generation: invalidGeneration,
                    sdp: "offer"
                ).validate()
            )
        }
    }

    func testDiagnosticAndJSONComplexityLimits() throws {
        try ErrorMessage(
            type: FloatProtocol.MessageType.error,
            version: 2,
            reason: String(
                repeating: "e",
                count: ProtocolLimits.maximumDiagnosticPayloadBytes
            ),
            tabId: nil,
            videoId: nil
        ).validate()
        XCTAssertThrowsError(
            try ErrorMessage(
                type: FloatProtocol.MessageType.error,
                version: 2,
                reason: String(
                    repeating: "e",
                    count: ProtocolLimits.maximumDiagnosticPayloadBytes + 1
                ),
                tabId: nil,
                videoId: nil
            ).validate()
        )

        try DebugMessage(
            type: FloatProtocol.MessageType.debug,
            version: 2,
            source: "test",
            event: "boundary",
            tabId: nil,
            frameId: nil,
            url: nil,
            payload: .string(
                String(
                    repeating: "d",
                    count: ProtocolLimits.maximumDiagnosticPayloadBytes
                )
            )
        ).validate()
        XCTAssertThrowsError(
            try DebugMessage(
                type: FloatProtocol.MessageType.debug,
                version: 2,
                source: "test",
                event: "oversized",
                tabId: nil,
                frameId: nil,
                url: nil,
                payload: .string(
                    String(
                        repeating: "d",
                        count: ProtocolLimits.maximumDiagnosticPayloadBytes + 1
                    )
                )
            ).validate()
        )

        var nested: Any = "leaf"
        for _ in 0..<18 {
            nested = [nested]
        }
        let excessiveDepth = try JSONSerialization.data(
            withJSONObject: [
                "type": FloatProtocol.MessageType.debug,
                "version": FloatProtocol.version,
                "payload": nested,
            ]
        )
        XCTAssertThrowsError(
            try ProtocolValidator.decode(
                ProtocolEnvelope.self,
                from: excessiveDepth
            )
        ) { error in
            XCTAssertEqual(
                error as? ProtocolValidationError,
                .limitExceeded("JSON depth")
            )
        }
    }

    private var validTabObject: [String: Any] {
        [
            "tabId": 1,
            "title": "Title",
            "url": "https://example.com/video",
            "videos": [],
        ]
    }

    private func makeStateData(tabs: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "type": FloatProtocol.MessageType.state,
                "version": FloatProtocol.version,
                "tabs": tabs,
            ]
        )
    }
}
