import AppKit
import Foundation

@MainActor
enum SensitivePasteboard {
    static let retentionSeconds: TimeInterval = 60

    private static var clearTask: Task<Void, Never>?
    private static var expectedValue: String?
    private static var expectedChangeCount: Int?

    @discardableResult
    static func copy(_ value: String) -> Bool {
        clearTask?.cancel()
        expectedValue = nil
        expectedChangeCount = nil

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(value, forType: .string) else {
            return false
        }
        expectedValue = value
        expectedChangeCount = pasteboard.changeCount
        clearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(retentionSeconds))
            guard !Task.isCancelled else { return }
            clearIfMatching(value)
        }
        return true
    }

    static func clearIfMatching(_ value: String) {
        let pasteboard = NSPasteboard.general
        guard let expectedValue,
              let expectedChangeCount,
              shouldClear(
                  requestedValue: value,
                  expectedValue: expectedValue,
                  expectedChangeCount: expectedChangeCount,
                  actualValue: pasteboard.string(forType: .string),
                  actualChangeCount: pasteboard.changeCount
              )
        else {
            return
        }
        pasteboard.clearContents()
        clearTask?.cancel()
        clearTask = nil
        self.expectedValue = nil
        self.expectedChangeCount = nil
    }

    nonisolated static func shouldClear(
        requestedValue: String,
        expectedValue: String,
        expectedChangeCount: Int,
        actualValue: String?,
        actualChangeCount: Int
    ) -> Bool {
        requestedValue == expectedValue
            && actualValue == expectedValue
            && actualChangeCount == expectedChangeCount
    }
}
