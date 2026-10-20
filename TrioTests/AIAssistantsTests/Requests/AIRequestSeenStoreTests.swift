import Foundation
import Testing

@testable import Trio

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("seen-requests-\(UUID().uuidString).json")
}

@Suite("AI request seen store") struct AIRequestSeenStoreTests {
    @Test func firstSightingIsNewAndSecondIsSeen() throws {
        let store = AIRequestSeenStore(fileURL: tempFile())
        #expect(try store.observe("a") == .new)
        #expect(try store.observe("a") == .seen(outcome: nil))
    }

    @Test func outcomeIsRememberedForRepeats() throws {
        let store = AIRequestSeenStore(fileURL: tempFile())
        _ = try store.observe("a")
        store.setOutcome(.delivering, for: "a")
        #expect(try store.observe("a") == .seen(outcome: .delivering))
    }

    @Test func survivesRelaunch() throws {
        let url = tempFile()
        _ = try AIRequestSeenStore(fileURL: url).observe("a")
        #expect(try AIRequestSeenStore(fileURL: url).observe("a") == .seen(outcome: nil))
    }

    @Test func missingIDIsRejected() {
        let store = AIRequestSeenStore(fileURL: tempFile())
        #expect(throws: AIRequestSeenStore.SeenError.missingID) { try store.observe(nil) }
        #expect(throws: AIRequestSeenStore.SeenError.missingID) { try store.observe("") }
    }

    @Test func failedWriteThrowsAndStaysSeen() throws {
        let missingFolder = tempFile().deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        let store = AIRequestSeenStore(fileURL: missingFolder.appendingPathComponent("seen-requests.json"))
        #expect(throws: AIRequestSeenStore.SeenError.persistenceFailed) { try store.observe("a") }
        #expect(try store.observe("a") == .seen(outcome: nil))
    }

    @Test func entriesOlderThanRetentionArePruned() throws {
        var clock = Date(timeIntervalSince1970: 0)
        let url = tempFile()
        _ = try AIRequestSeenStore(fileURL: url, now: { clock }).observe("a")
        clock += 24 * 60 * 60 + 1
        #expect(try AIRequestSeenStore(fileURL: url, now: { clock }).observe("a") == .new)
    }

    @Test func finalStates() {
        #expect(
            AIRequestState.allCases
                .filter(\.isFinal) == [.delivering, .logged, .declined, .expired, .withdrawn, .replaced, .failed]
        )
    }
}
