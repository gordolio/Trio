import Foundation
import Testing

@testable import Trio

@Suite("AI request watch approvals") struct AIRequestWatchApprovalsTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let expiresAt = now.addingTimeInterval(300)

    private static func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: UUID().uuidString)!
    }

    @Test("An approval is kept with where it came from") func approvalIsKept() {
        var approvals = AIRequestWatchApprovals()
        #expect(!approvals.contains("r1"))

        approvals.add("r1", expiresAt: Self.expiresAt, fromNotification: false, at: Self.now)
        approvals.add("r2", expiresAt: Self.expiresAt, fromNotification: true, at: Self.now)

        #expect(approvals.contains("r1"))
        #expect(!approvals.isFromNotification("r1"))
        #expect(approvals.contains("r2"))
        #expect(approvals.isFromNotification("r2"))
        #expect(!approvals.contains("r3"))
        #expect(!approvals.isFromNotification("r3"))
    }

    @Test("An approval from a notification stays one if the request is approved again") func notificationApprovalSticks() {
        var approvals = AIRequestWatchApprovals()
        approvals.add("r1", expiresAt: Self.expiresAt, fromNotification: true, at: Self.now)
        approvals.add("r1", expiresAt: Self.expiresAt, fromNotification: false, at: Self.now)
        #expect(approvals.isFromNotification("r1"))
    }

    @Test("The approvals survive a relaunch") func approvalsSurviveARelaunch() {
        let defaults = Self.freshDefaults()
        var approvals = AIRequestWatchApprovals.load(from: defaults, at: Self.now)
        approvals.add("r1", expiresAt: Self.expiresAt, fromNotification: false, at: Self.now)
        approvals.add("r2", expiresAt: Self.expiresAt, fromNotification: true, at: Self.now)
        approvals.save(to: defaults)

        let relaunched = AIRequestWatchApprovals.load(from: defaults, at: Self.now.addingTimeInterval(60))
        #expect(relaunched == approvals)
        #expect(relaunched.contains("r1"))
        #expect(relaunched.isFromNotification("r2"))
    }

    @Test(
        "An approval is kept past its expiry, for the phone's result, and then dropped"
    ) func approvalsArePrunedAfterExpiry() {
        let defaults = Self.freshDefaults()
        var approvals = AIRequestWatchApprovals()
        approvals.add("r1", expiresAt: Self.expiresAt, fromNotification: false, at: Self.now)
        approvals.save(to: defaults)

        // The phone says a request expired at its expiry, and its result can take a while to reach the watch.
        let justAfter = Self.expiresAt.addingTimeInterval(5)
        #expect(AIRequestWatchApprovals.load(from: defaults, at: justAfter).contains("r1"))

        let lastMoment = Self.expiresAt.addingTimeInterval(AIRequestWatchApprovals.keptAfterExpiry - 1)
        #expect(AIRequestWatchApprovals.load(from: defaults, at: lastMoment).contains("r1"))

        let gone = Self.expiresAt.addingTimeInterval(AIRequestWatchApprovals.keptAfterExpiry)
        #expect(!AIRequestWatchApprovals.load(from: defaults, at: gone).contains("r1"))

        // Adding another drops the old ones too, so the list never grows.
        approvals.add("r2", expiresAt: gone.addingTimeInterval(300), fromNotification: false, at: gone)
        #expect(!approvals.contains("r1"))
        #expect(approvals.contains("r2"))
    }

    @Test("Nothing saved, or something unreadable, reads as no approvals") func unreadableReadsAsNone() {
        let defaults = Self.freshDefaults()
        #expect(AIRequestWatchApprovals.load(from: defaults, at: Self.now) == AIRequestWatchApprovals())

        defaults.set(Data("not json".utf8), forKey: AIRequestWatchApprovals.defaultsKey)
        #expect(AIRequestWatchApprovals.load(from: defaults, at: Self.now) == AIRequestWatchApprovals())
    }
}
