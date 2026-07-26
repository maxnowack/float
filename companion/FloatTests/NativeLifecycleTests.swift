import XCTest
@testable import Float

final class NativeLifecycleTests: XCTestCase {
    func testPresentationEpochRejectsDelayedCloseFromPreviousPiP() throws {
        var epochs = PiPPresentationEpochTracker()

        let firstPresentation = try XCTUnwrap(epochs.begin())
        XCTAssertTrue(epochs.matches(firstPresentation))
        XCTAssertNil(epochs.begin())

        XCTAssertTrue(epochs.end(firstPresentation))
        let secondPresentation = try XCTUnwrap(epochs.begin())
        XCTAssertNotEqual(firstPresentation, secondPresentation)
        XCTAssertFalse(epochs.end(firstPresentation))
        XCTAssertTrue(epochs.matches(secondPresentation))
        XCTAssertTrue(epochs.end(secondPresentation))
        XCTAssertNil(epochs.current)
    }

    func testProgrammaticCancellationInvalidatesQueuedClose() throws {
        var epochs = PiPPresentationEpochTracker()
        let presentation = try XCTUnwrap(epochs.begin())

        epochs.cancel()

        XCTAssertFalse(epochs.matches(presentation))
        XCTAssertFalse(epochs.end(presentation))
    }

    func testReplacementWaitsForProgrammaticDismissalToFinish() throws {
        var epochs = PiPPresentationEpochTracker()
        let firstPresentation = try XCTUnwrap(epochs.begin())

        XCTAssertTrue(epochs.beginDismissal(firstPresentation))
        XCTAssertTrue(epochs.end(firstPresentation))
        XCTAssertFalse(epochs.canBeginPresentation)
        XCTAssertNil(epochs.begin())

        XCTAssertTrue(epochs.completeDismissal(firstPresentation))
        XCTAssertTrue(epochs.canBeginPresentation)
        XCTAssertNotNil(epochs.begin())
    }

    func testStaleDismissalCompletionCannotReleaseCurrentGate() throws {
        var epochs = PiPPresentationEpochTracker()
        let firstPresentation = try XCTUnwrap(epochs.begin())

        XCTAssertTrue(epochs.beginDismissal(firstPresentation))
        XCTAssertTrue(epochs.end(firstPresentation))
        XCTAssertFalse(epochs.completeDismissal(firstPresentation + 1))
        XCTAssertFalse(epochs.canBeginPresentation)
        XCTAssertTrue(epochs.completeDismissal(firstPresentation))
    }
}
