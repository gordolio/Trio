import Combine
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

private func samplePrompt(id: String) -> AIRequestPrompt {
    AIRequestPrompt(
        id: id,
        source: "ChatGPT",
        description: "slice of pizza",
        shown: AIRequestShown(carbs: 20, fat: 10, protein: 8, units: 1.2),
        title: "ChatGPT: slice of pizza",
        body: "20 g carbs · 1.2 U",
        expiresAt: coordinatorTestStart + 5 * 60,
        approvalStyle: .twoStep,
        answerRoute: .both,
        answerToken: nil,
        answerURL: nil
    )
}

private func samplePending(id: String, askedOn: AIRequestAskedOn = .phone) -> PendingAIRequest {
    PendingAIRequest(
        request: meal(id: id),
        channel: .service,
        prompt: samplePrompt(id: id),
        askedOn: askedOn,
        units: 1.2
    )
}

@Suite("AI request phone backup") struct AIRequestPhoneBackupTests {
    @Test func immediateHasNoTrigger() throws {
        let c = FakeNotificationCenter()
        AIRequestPhoneBackup(center: c).schedule(samplePrompt(id: "r1"), after: 0)
        let r = try #require(c.added.first)
        #expect(r.identifier == "ai-request-r1" && r.trigger == nil)
        #expect(r.content.categoryIdentifier == "trio.request.phone" && r.content.interruptionLevel == .timeSensitive)
    }

    @Test func delayedUsesTimeIntervalTrigger() throws {
        let c = FakeNotificationCenter()
        AIRequestPhoneBackup(center: c).schedule(samplePrompt(id: "r1"), after: 15)
        #expect((c.added.first?.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval == 15)
    }

    @Test func contentShowsTheRequestAndSaysHowToApprove() throws {
        let c = FakeNotificationCenter()
        AIRequestPhoneBackup(center: c).schedule(samplePrompt(id: "r1"), after: 0)
        let content = try #require(c.added.first?.content)
        #expect(content.title == "ChatGPT: slice of pizza")
        #expect(content.body == "20 g carbs · 1.2 U · Tap to approve with Face ID")
        #expect(content.userInfo["aiRequestId"] as? String == "r1")
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
        backup.schedule(samplePrompt(id: "r1"), after: 0)
        backup.schedule(samplePrompt(id: "r2"), after: 0)
        #expect(c.categories.map(\.identifier).sorted() == ["Trio.alert", "trio.request.phone"])
    }

    @Test func requestAskedOnTheIPhoneIsDue() async {
        let c = FakeNotificationCenter()
        #expect(await AIRequestPhoneBackup(center: c).isDue(samplePending(id: "r1", askedOn: .phone)))
    }

    @Test func requestAskedOnTheWatchIsDueOnceItsNotificationIsDelivered() async {
        let c = FakeNotificationCenter()
        let backup = AIRequestPhoneBackup(center: c)
        // The watch still has its time.
        #expect(await backup.isDue(samplePending(id: "r1", askedOn: .watch)) == false)
        c.delivered = ["ai-request-r2", "Trio.alert"]
        #expect(await backup.isDue(samplePending(id: "r1", askedOn: .watch)) == false)
        c.delivered = ["Trio.alert", "ai-request-r1"]
        #expect(await backup.isDue(samplePending(id: "r1", askedOn: .watch)))
    }

    @Test func schedulingReplacesAnOlderPhoneCategory() {
        let c = FakeNotificationCenter()
        c.categories = [UNNotificationCategory(
            identifier: "trio.request.phone",
            actions: [],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )]
        AIRequestPhoneBackup(center: c).schedule(samplePrompt(id: "r1"), after: 0)
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

@Suite("AI request phone approval") @MainActor struct AIRequestPhoneApprovalTests {
    /// Lets the presenter see what the subject sent, which it receives on the main queue.
    private func flushMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func tappedNotificationPresentsThePendingRequest() async {
        let current = CurrentValueSubject<PendingAIRequest?, Never>(samplePending(id: "r1"))
        let presenter = AIRequestPhoneApprovalPresenter()
        presenter.follow(current.eraseToAnyPublisher())
        await flushMainQueue()
        presenter.open(requestID: "r1")
        #expect(presenter.presented?.request.id == "r1")
    }

    @Test func tapBeforeTheCoordinatorHasTheRequestWaitsForIt() async {
        let current = CurrentValueSubject<PendingAIRequest?, Never>(nil)
        let presenter = AIRequestPhoneApprovalPresenter()
        presenter.open(requestID: "r1") // a cold launch from the notification, before anything is followed
        presenter.follow(current.eraseToAnyPublisher())
        await flushMainQueue()
        #expect(presenter.presented == nil)
        current.send(samplePending(id: "r1"))
        await flushMainQueue()
        #expect(presenter.presented?.request.id == "r1")
    }

    @Test func tapForAnotherRequestPresentsNothing() async {
        let current = CurrentValueSubject<PendingAIRequest?, Never>(samplePending(id: "r2"))
        let presenter = AIRequestPhoneApprovalPresenter()
        presenter.follow(current.eraseToAnyPublisher())
        await flushMainQueue()
        presenter.open(requestID: "r1")
        #expect(presenter.presented == nil)
    }

    @Test func answeredOrExpiredRequestDismissesTheSheet() async {
        let current = CurrentValueSubject<PendingAIRequest?, Never>(samplePending(id: "r1"))
        let presenter = AIRequestPhoneApprovalPresenter()
        presenter.follow(current.eraseToAnyPublisher())
        presenter.open(requestID: "r1")
        await flushMainQueue()
        #expect(presenter.presented?.request.id == "r1")
        current.send(nil)
        await flushMainQueue()
        #expect(presenter.presented == nil)
    }

    @Test func replacementRequestDismissesTheSheetWithoutPresentingItself() async {
        let current = CurrentValueSubject<PendingAIRequest?, Never>(samplePending(id: "r1"))
        let presenter = AIRequestPhoneApprovalPresenter()
        presenter.follow(current.eraseToAnyPublisher())
        presenter.open(requestID: "r1")
        await flushMainQueue()
        // The coordinator sends nil, then the new request.
        current.send(nil)
        current.send(samplePending(id: "r2"))
        await flushMainQueue()
        #expect(presenter.presented == nil)
    }

    @Test func requestStillPendingKeepsTheSheetOpen() async {
        let current = CurrentValueSubject<PendingAIRequest?, Never>(samplePending(id: "r1"))
        let presenter = AIRequestPhoneApprovalPresenter()
        presenter.follow(current.eraseToAnyPublisher())
        presenter.open(requestID: "r1")
        await flushMainQueue()
        current.send(samplePending(id: "r1"))
        await flushMainQueue()
        #expect(presenter.presented?.request.id == "r1")
    }

    // MARK: Opening Trio

    private func makePresenter(delivered: [String] = []) -> AIRequestPhoneApprovalPresenter {
        let center = FakeNotificationCenter()
        center.delivered = delivered
        return AIRequestPhoneApprovalPresenter(isBackupDue: { await AIRequestPhoneBackup(center: center).isDue($0) })
    }

    @Test func openingTrioPresentsARequestAskedOnTheIPhone() async {
        let current = CurrentValueSubject<PendingAIRequest?, Never>(samplePending(id: "r1", askedOn: .phone))
        let presenter = makePresenter()
        presenter.follow(current.eraseToAnyPublisher())
        await flushMainQueue()
        await presenter.presentIfDue(current.value)
        #expect(presenter.presented?.request.id == "r1")
    }

    @Test func openingTrioLeavesARequestTheWatchIsStillAskingFor() async {
        let current = CurrentValueSubject<PendingAIRequest?, Never>(samplePending(id: "r1", askedOn: .watch))
        let presenter = makePresenter()
        presenter.follow(current.eraseToAnyPublisher())
        await flushMainQueue()
        await presenter.presentIfDue(current.value)
        #expect(presenter.presented == nil)
    }

    @Test func openingTrioPresentsARequestWhoseBackupWasDelivered() async {
        let current = CurrentValueSubject<PendingAIRequest?, Never>(samplePending(id: "r1", askedOn: .watch))
        let presenter = makePresenter(delivered: ["ai-request-r1"])
        presenter.follow(current.eraseToAnyPublisher())
        await flushMainQueue()
        await presenter.presentIfDue(current.value)
        #expect(presenter.presented?.request.id == "r1")
    }

    @Test func openingTrioWithNothingPendingPresentsNothing() async {
        let current = CurrentValueSubject<PendingAIRequest?, Never>(nil)
        let presenter = makePresenter()
        presenter.follow(current.eraseToAnyPublisher())
        await flushMainQueue()
        await presenter.presentIfDue(nil)
        current.send(samplePending(id: "r1", askedOn: .watch))
        await flushMainQueue()
        #expect(presenter.presented == nil)
    }

    @Test func dueRequestFoundBeforeThePresenterHasItWaitsForIt() async {
        // A cold launch: the coordinator has read the request, and the presenter hasn't received it yet.
        let current = CurrentValueSubject<PendingAIRequest?, Never>(nil)
        let presenter = makePresenter()
        presenter.follow(current.eraseToAnyPublisher())
        await presenter.presentIfDue(samplePending(id: "r1", askedOn: .phone))
        #expect(presenter.presented == nil)
        current.send(samplePending(id: "r1", askedOn: .phone))
        await flushMainQueue()
        #expect(presenter.presented?.request.id == "r1")
    }

    // MARK: Face ID

    /// The answers the flow gave, and how often it asked for Face ID.
    private final class FlowLog {
        private let lock = NSLock()
        private var recordedAnswers: [AIRequestAnswerSource] = []
        private var recordedUnlocks = 0

        var answers: [AIRequestAnswerSource] { lock.withLock { recordedAnswers } }
        var unlocks: Int { lock.withLock { recordedUnlocks } }

        func flow(unlock: @escaping () throws -> Bool) -> AIRequestPhoneApprovalFlow {
            AIRequestPhoneApprovalFlow(
                requestID: "r1",
                unlock: { [self] in
                    lock.withLock { recordedUnlocks += 1 }
                    return try unlock()
                },
                answer: { [self] source in lock.withLock { recordedAnswers.append(source) } }
            )
        }
    }

    private struct FaceIDFailed: Error {}

    @Test func failedFaceIDAnswersNothing() async {
        let log = FlowLog()
        #expect(await log.flow(unlock: { false }).approve() == false)
        #expect(log.unlocks == 1 && log.answers.isEmpty)
    }

    @Test func faceIDErrorAnswersNothing() async {
        let log = FlowLog()
        #expect(await log.flow(unlock: { throw FaceIDFailed() }).approve() == false)
        #expect(log.unlocks == 1 && log.answers.isEmpty)
    }

    @Test func passedFaceIDApprovesTheShownRequestOnce() async {
        let log = FlowLog()
        #expect(await log.flow(unlock: { true }).approve())
        #expect(log.unlocks == 1)
        #expect(log.answers == [.phone(.approve, id: "r1")])
    }

    @Test func declineNeedsNoFaceID() async {
        let log = FlowLog()
        await log.flow(unlock: { true }).decline()
        #expect(log.unlocks == 0)
        #expect(log.answers == [.phone(.decline, id: "r1")])
    }

    @Test func countdownShowsMinutesAndSeconds() {
        let end = coordinatorTestStart + 5 * 60
        #expect(AIRequestPhoneApprovalView.countdown(until: end, now: coordinatorTestStart) == "5:00")
        #expect(AIRequestPhoneApprovalView.countdown(until: end, now: coordinatorTestStart + 1) == "4:59")
        #expect(AIRequestPhoneApprovalView.countdown(until: end, now: coordinatorTestStart + 0.4) == "5:00")
        #expect(AIRequestPhoneApprovalView.countdown(until: end, now: end - 9) == "0:09")
        #expect(AIRequestPhoneApprovalView.countdown(until: end, now: end + 30) == "0:00")
    }
}
