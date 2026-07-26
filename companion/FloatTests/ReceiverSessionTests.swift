import XCTest
@testable import Float

final class ReceiverSessionTests: XCTestCase {
    func testReplacementSessionCannotReadOrAppendPreviousPendingICE() {
        var sessions = ReceiverSessionState<String>()
        let firstSession = sessions.begin()

        XCTAssertEqual(
            sessions.enqueue("first", for: firstSession, limit: 2),
            .enqueued
        )
        XCTAssertEqual(sessions.pendingCount(for: firstSession), 1)

        let replacementSession = sessions.begin()

        XCTAssertNotEqual(firstSession, replacementSession)
        XCTAssertFalse(sessions.matches(firstSession))
        XCTAssertNil(sessions.dequeue(for: firstSession))
        XCTAssertEqual(
            sessions.enqueue("stale", for: firstSession, limit: 2),
            .staleSession
        )
        XCTAssertEqual(sessions.pendingCount(for: replacementSession), 0)

        XCTAssertEqual(
            sessions.enqueue("replacement", for: replacementSession, limit: 2),
            .enqueued
        )
        XCTAssertEqual(
            sessions.dequeue(for: replacementSession),
            "replacement"
        )
    }

    func testCancellationInvalidatesAndClearsPendingICE() {
        var sessions = ReceiverSessionState<Int>()
        let session = sessions.begin()
        XCTAssertEqual(
            sessions.enqueue(1, for: session, limit: 1),
            .enqueued
        )
        XCTAssertEqual(
            sessions.enqueue(2, for: session, limit: 1),
            .limitReached
        )

        sessions.cancel()

        XCTAssertFalse(sessions.matches(session))
        XCTAssertNil(sessions.dequeue(for: session))
        XCTAssertEqual(sessions.pendingCount(for: session), 0)
    }

    func testStaleReceiverCallbackDoesNotMatchReplacementSource() {
        let previousSource = WebRTCMediaSource(
            tabId: 101,
            videoId: "previous-video",
            generation: 7
        )

        XCTAssertTrue(
            previousSource.matches(
                tabId: 101,
                videoId: "previous-video",
                generation: 7
            )
        )
        XCTAssertFalse(
            previousSource.matches(
                tabId: 202,
                videoId: "replacement-video",
                generation: 8
            )
        )
        XCTAssertFalse(
            previousSource.matches(
                tabId: 101,
                videoId: "previous-video",
                generation: 8
            )
        )
    }
}
