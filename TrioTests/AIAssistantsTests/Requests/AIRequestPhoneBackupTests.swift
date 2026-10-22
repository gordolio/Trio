import Foundation
import Testing
import UserNotifications

@testable import Trio

/// Records what the backup asks the notification center, in place of the system's.
final class FakeNotificationCenter: AIRequestNotificationScheduling {
    private let lock = NSLock()
    private var addedRequests: [UNNotificationRequest] = []
    private var pendingRemovals: [String] = []
    private var deliveredRemovals: [String] = []
    private var registeredCategories: Set<UNNotificationCategory> = []
    private var deliveredIdentifiers: [String] = []

    var added: [UNNotificationRequest] { lock.withLock { addedRequests } }
    var removedPending: [String] { lock.withLock { pendingRemovals } }
    var removedDelivered: [String] { lock.withLock { deliveredRemovals } }
    /// The categories the center holds. Set it to start with some, and read what the backup left.
    var categories: Set<UNNotificationCategory> {
        get { lock.withLock { registeredCategories } }
        set { lock.withLock { registeredCategories = newValue } }
    }

    /// The identifiers of the notifications in Notification Center.
    var delivered: [String] {
        get { lock.withLock { deliveredIdentifiers } }
        set { lock.withLock { deliveredIdentifiers = newValue } }
    }

    func add(_ request: UNNotificationRequest) {
        lock.withLock { addedRequests.append(request) }
    }

    func removePending(_ ids: [String]) {
        lock.withLock { pendingRemovals.append(contentsOf: ids) }
    }

    func removeDelivered(_ ids: [String]) {
        lock.withLock { deliveredRemovals.append(contentsOf: ids) }
    }

    func getNotificationCategories(completionHandler: @escaping @Sendable(Set<UNNotificationCategory>) -> Void) {
        completionHandler(categories)
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        self.categories = categories
    }

    func deliveredIDs() async -> [String] {
        delivered
    }
}

func samplePrompt(id: String) -> AIRequestPrompt {
    AIRequestPrompt(
        id: id,
        source: "ChatGPT",
        description: "slice of pizza",
        shown: AIRequestShown(carbs: 20, fat: 10, protein: 8, units: 1.2),
        title: "ChatGPT: slice of pizza",
        body: "20 g carbs · 1.2 U",
        expiresAt: coordinatorTestStart + 5 * 60
    )
}

func samplePending(
    id: String,
    askedOn: AIRequestAskedOn = .phone,
    phoneAskAt: Date? = nil
) -> PendingAIRequest {
    PendingAIRequest(
        request: meal(id: id),
        channel: .service,
        prompt: samplePrompt(id: id),
        askedOn: askedOn,
        units: 1.2,
        phoneAskAt: phoneAskAt
    )
}

@Suite("AI request phone backup") struct AIRequestPhoneBackupTests {
    @Test func immediateHasNoTrigger() throws {
        let c = FakeNotificationCenter()
        AIRequestPhoneBackup(center: c).schedule(samplePrompt(id: "r1"), after: 0, askedOn: .phone)
        let r = try #require(c.added.first)
        #expect(r.identifier == "ai-request-r1" && r.trigger == nil)
        #expect(r.content.categoryIdentifier == "trio.request.phone" && r.content.interruptionLevel == .timeSensitive)
    }

    @Test func delayedUsesTimeIntervalTrigger() throws {
        let c = FakeNotificationCenter()
        AIRequestPhoneBackup(center: c).schedule(samplePrompt(id: "r1"), after: 15, askedOn: .watch)
        #expect((c.added.first?.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval == 15)
    }

    @Test func contentShowsTheRequestAndSaysToReviewIt() throws {
        let c = FakeNotificationCenter()
        AIRequestPhoneBackup(center: c).schedule(samplePrompt(id: "r1"), after: 0, askedOn: .phone)
        let content = try #require(c.added.first?.content)
        #expect(content.title == "ChatGPT: slice of pizza")
        #expect(content.body == "20 g carbs · 1.2 U\nTap to review.")
        #expect(content.userInfo["aiRequestId"] as? String == "r1")
    }

    /// The watch opens the request when the backup is forwarded to it, by the ID under the shared key.
    @Test func backupHoldsTheRequestIDWhereTheWatchReadsIt() throws {
        let c = FakeNotificationCenter()
        AIRequestPhoneBackup(center: c).schedule(samplePrompt(id: "r1"), after: 15, askedOn: .watch)
        let content = try #require(c.added.first?.content)
        #expect(AIRequestPhoneBackup.requestIDKey == AIRequestIdentifiers.backupRequestIDKey)
        #expect(content.userInfo[AIRequestIdentifiers.backupRequestIDKey] as? String == "r1")
        #expect(content.categoryIdentifier == AIRequestIdentifiers.categoryPhone)
    }

    @Test func watchFirstBodySaysNotAnsweredOnTheWatch() throws {
        let c = FakeNotificationCenter()
        AIRequestPhoneBackup(center: c).schedule(samplePrompt(id: "r1"), after: 15, askedOn: .watch)
        let content = try #require(c.added.first?.content)
        #expect(content.body == "20 g carbs · 1.2 U\nNot answered on your watch yet. Tap to review.")
    }

    @Test func backupUsesTheRequestThread() throws {
        let c = FakeNotificationCenter()
        let backup = AIRequestPhoneBackup(center: c)
        backup.schedule(samplePrompt(id: "r1"), after: 15, askedOn: .watch)
        backup.schedule(samplePrompt(id: "r2"), after: 0, askedOn: .phone)
        #expect(c.added.map(\.content.threadIdentifier) == ["trio.ai-request", "trio.ai-request"])
    }

    @Test func cancelRemovesPendingAndDelivered() {
        let c = FakeNotificationCenter()
        AIRequestPhoneBackup(center: c).cancel(id: "r1")
        #expect(c.removedPending == ["ai-request-r1"] && c.removedDelivered == ["ai-request-r1"])
    }

    @Test func schedulingKeepsTheCategoriesTrioAlreadyHas() {
        let c = FakeNotificationCenter()
        c.categories = [UNNotificationCategory(identifier: "Trio.alert", actions: [], intentIdentifiers: [], options: [])]
        let backup = AIRequestPhoneBackup(center: c)
        backup.schedule(samplePrompt(id: "r1"), after: 0, askedOn: .phone)
        backup.schedule(samplePrompt(id: "r2"), after: 0, askedOn: .phone)
        #expect(c.categories.map(\.identifier).sorted() == ["Trio.alert", "trio.request.phone"])
    }

    @Test func requestAskedOnTheIPhoneIsDue() async {
        let c = FakeNotificationCenter()
        let pending = samplePending(id: "r1", askedOn: .phone)
        #expect(await AIRequestPhoneBackup(center: c).isDue(pending, now: coordinatorTestStart))
    }

    @Test func requestAskedOnTheWatchIsDueOnceItsNotificationIsDelivered() async {
        let c = FakeNotificationCenter()
        let backup = AIRequestPhoneBackup(center: c)
        let pending = samplePending(id: "r1", askedOn: .watch)
        // The watch still has its time.
        #expect(await backup.isDue(pending, now: coordinatorTestStart) == false)
        c.delivered = ["ai-request-r2", "Trio.alert"]
        #expect(await backup.isDue(pending, now: coordinatorTestStart) == false)
        c.delivered = ["Trio.alert", "ai-request-r1"]
        #expect(await backup.isDue(pending, now: coordinatorTestStart))
    }

    @Test func dueAfterPhoneAskAtWithoutANotification() async {
        let c = FakeNotificationCenter()
        let backup = AIRequestPhoneBackup(center: c)
        let pending = samplePending(id: "r1", askedOn: .watch, phoneAskAt: coordinatorTestStart + 15)
        #expect(await backup.isDue(pending, now: coordinatorTestStart + 15))
        #expect(await backup.isDue(pending, now: coordinatorTestStart + 16))
    }

    @Test func notDueBeforePhoneAskAt() async {
        let c = FakeNotificationCenter()
        let backup = AIRequestPhoneBackup(center: c)
        let pending = samplePending(id: "r1", askedOn: .watch, phoneAskAt: coordinatorTestStart + 15)
        #expect(await backup.isDue(pending, now: coordinatorTestStart) == false)
        #expect(await backup.isDue(pending, now: coordinatorTestStart + 14.9) == false)
    }

    @Test func deliveredNotificationMakesItDueBeforePhoneAskAt() async {
        let c = FakeNotificationCenter()
        c.delivered = ["ai-request-r1"]
        let pending = samplePending(id: "r1", askedOn: .watch, phoneAskAt: coordinatorTestStart + 60)
        #expect(await AIRequestPhoneBackup(center: c).isDue(pending, now: coordinatorTestStart))
    }

    @Test func schedulingReplacesAnOlderPhoneCategory() {
        let c = FakeNotificationCenter()
        c.categories = [UNNotificationCategory(
            identifier: "trio.request.phone",
            actions: [],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )]
        AIRequestPhoneBackup(center: c).schedule(samplePrompt(id: "r1"), after: 0, askedOn: .phone)
        #expect(c.categories.count == 1)
        #expect(c.categories.first?.options == [])
    }
}

@Suite("AI request hooks – phone backup") struct AIRequestPhoneHooksTests {
    private let phoneInfo: [AnyHashable: Any] = ["aiRequestId": "r1"]
    private let checkInInfo: [AnyHashable: Any] = ["trio-rc": ["type": "check-in"]]

    @Test func checkInPushIsRecognised() {
        #expect(AIRequestHooks.isCheckIn(checkInInfo))
        #expect(AIRequestHooks.isCheckIn(["aps": ["content-available": 1], "trio-rc": ["type": "check-in", "extra": 1]]))
    }

    @Test func otherPayloadsAreNotCheckIns() {
        #expect(!AIRequestHooks.isCheckIn([:]))
        #expect(!AIRequestHooks.isCheckIn(["trio-rc": ["type": "request"]]))
        #expect(!AIRequestHooks.isCheckIn(["trio-rc": ["kind": "check-in"]]))
        #expect(!AIRequestHooks.isCheckIn(["trio-rc": "check-in"]))
        #expect(!AIRequestHooks.isCheckIn(["type": "check-in"]))
    }

    @Test func phoneNotificationShowsInTheForeground() {
        let options = AIRequestHooks.presentationOptions(category: "trio.request.phone", userInfo: phoneInfo)
        #expect(options == [.banner, .sound, .list])
    }

    @Test func checkInPushIsSilent() {
        #expect(AIRequestHooks.presentationOptions(category: "", userInfo: checkInInfo) == [])
    }

    @Test func otherNotificationsAreLeftToTrio() {
        #expect(AIRequestHooks.presentationOptions(category: "", userInfo: [:]) == nil)
        #expect(AIRequestHooks.presentationOptions(category: "Trio.alert", userInfo: ["aiRequestId": "r1"]) == nil)
        #expect(AIRequestHooks.presentationOptions(category: "trio.request.review", userInfo: [:]) == nil)
    }
}
