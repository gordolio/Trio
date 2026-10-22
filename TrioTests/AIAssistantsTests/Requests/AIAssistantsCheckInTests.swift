import Combine
import Foundation
import Testing
import UIKit

@testable import Trio

/// A meal request in the service's inbox. It expires 5 minutes after `createdAt`.
func inboxMeal(
    id: String,
    carbs: Decimal = 20,
    withdrawn: Bool = false,
    createdAt: Date = coordinatorTestStart
) -> AIInbox.Request {
    AIInbox.Request(
        id: id,
        kind: "meal",
        source: "ChatGPT",
        createdAt: createdAt,
        expiresAt: createdAt + 5 * 60,
        withdrawn: withdrawn,
        meal: AIInbox.Meal(description: "slice of pizza", carbs: carbs, fat: 10, protein: 8)
    )
}

func inbox(requests: [AIInbox.Request]) -> AIInbox {
    AIInbox(requests: requests)
}

/// Counts calls from any thread.
final class CallCounter {
    private let lock = NSLock()
    private var recorded = 0

    var calls: Int { lock.withLock { recorded } }

    func record() {
        lock.withLock { recorded += 1 }
    }
}

/// The results a push's completion handler was called with.
final class FetchResults {
    private let lock = NSLock()
    private var recorded: [UIBackgroundFetchResult] = []

    var values: [UIBackgroundFetchResult] { lock.withLock { recorded } }

    func complete(_ result: UIBackgroundFetchResult) {
        lock.withLock { recorded.append(result) }
    }
}

/// A check-in over a coordinator harness whose service reports go to the fake API.
final class CheckInHarness {
    let checkIn: AIAssistantsCheckIn
    let requests: CoordinatorHarness
    let loopRuns: PassthroughSubject<Date, Never>
    let activity: FakeBackgroundActivity
    /// Calls of `removeDeliveredCheckIns`.
    let removals: CallCounter

    init(api: FakeAIAssistantsAPI, isLinked: Bool) {
        let requests = makeCoordinator(serviceReporter: ServiceRequestReporter(api: api))
        let loopRuns = PassthroughSubject<Date, Never>()
        let activity = FakeBackgroundActivity()
        let removals = CallCounter()
        checkIn = AIAssistantsCheckIn(
            api: api,
            coordinator: requests.coordinator,
            isLinked: { isLinked },
            loopRuns: loopRuns.eraseToAnyPublisher(),
            beginBackgroundActivity: activity.begin,
            removeDeliveredCheckIns: removals.record
        )
        self.requests = requests
        self.loopRuns = loopRuns
        self.activity = activity
        self.removals = removals
    }
}

func makeCheckIn(api: FakeAIAssistantsAPI, isLinked: Bool = true) -> CheckInHarness {
    CheckInHarness(api: api, isLinked: isLinked)
}

@Suite("AI Assistants check-in") struct AIAssistantsCheckInTests {
    let checkInActivity = ["begin AI Assistants check-in", "end AI Assistants check-in"]
    let checkInPush: [AnyHashable: Any] = ["trio-rc": ["v": 1, "type": "check-in"]]

    @Test func inboxRequestReachesTheCoordinatorAndIsReported() async {
        let api = FakeAIAssistantsAPI()
        api.inbox = inbox(requests: [inboxMeal(id: "r1", carbs: 20)])
        let h = makeCheckIn(api: api)
        await h.checkIn.checkIn(reason: .push)
        #expect(api.reportedStates == ["r1:pending"])
        #expect(h.requests.coordinator.current.value?.request.id == "r1")
        #expect(h.removals.calls == 1)
        #expect(h.activity.events == checkInActivity)
    }

    /// Review Focus 3. The second run finds r1 pending, so the coordinator only sends its pending report
    /// again, which the service answers with 204.
    @Test func pushAndLoopAtOnceActOnce() async {
        let api = FakeAIAssistantsAPI()
        api.inbox = inbox(requests: [inboxMeal(id: "r1")])
        let gate = UploadGate()
        api.inboxGate = gate
        let h = makeCheckIn(api: api)
        let push = Task { await h.checkIn.checkIn(reason: .push) }
        #expect(await eventuallyTrue { api.calls == ["getInbox"] })
        // The loop's check-ins only ask for one more after the push's.
        await h.checkIn.checkIn(reason: .loop)
        await h.checkIn.checkIn(reason: .loop)
        #expect(api.calls == ["getInbox"])
        #expect(h.activity.events == ["begin AI Assistants check-in"])
        gate.open()
        await push.value
        #expect(api.calls.filter { $0 == "getInbox" }.count == 2)
        #expect(h.requests.backup.scheduled.map(\.id) == ["r1"])
        #expect(api.reportedStates == ["r1:pending", "r1:pending"])
        let bodies = api.requestStates.map(\.body)
        #expect(bodies.count == 2 && bodies.first == bodies.last)
        #expect(h.activity.events == checkInActivity)
    }

    @Test func relayedAnswersAreIgnored() async {
        // An older service lists the answers a watch relayed. Nothing is carried out for them.
        let api = FakeAIAssistantsAPI()
        let h = makeCheckIn(api: api)
        api.inboxBody = Data(
            #"{"requests":[],"answers":[{"v":1,"requestId":"r1","decision":"approve","mac":"x"}]}"#.utf8
        )
        await h.checkIn.checkIn(reason: .push)
        #expect(api.calls == ["getInbox"])
        #expect(h.requests.treatments.stored.isEmpty && h.requests.treatments.enacted.isEmpty)
        #expect(api.reportedStates.isEmpty)
    }

    @Test func withdrawnRequestIsWithdrawn() async {
        let api = FakeAIAssistantsAPI()
        api.inbox = inbox(requests: [inboxMeal(id: "r1")])
        let h = makeCheckIn(api: api)
        await h.checkIn.checkIn(reason: .push)
        api.inbox = inbox(requests: [inboxMeal(id: "r1", withdrawn: true)])
        await h.checkIn.checkIn(reason: .push)
        #expect(api.reportedStates == ["r1:pending", "r1:withdrawn"])
        #expect(h.requests.coordinator.current.value == nil)
    }

    @Test func requestsAreTakenOldestFirst() async {
        let api = FakeAIAssistantsAPI()
        api.inbox = inbox(requests: [
            inboxMeal(id: "r2", createdAt: coordinatorTestStart + 30),
            inboxMeal(id: "r1")
        ])
        let h = makeCheckIn(api: api)
        await h.checkIn.checkIn(reason: .push)
        #expect(api.reportedStates == ["r1:pending", "r1:replaced", "r2:pending"])
    }

    @Test func overdueRequestIsExpired() async {
        let api = FakeAIAssistantsAPI()
        api.inbox = inbox(requests: [inboxMeal(id: "r1")])
        let h = makeCheckIn(api: api)
        await h.checkIn.checkIn(reason: .push)
        h.requests.now = coordinatorTestStart + 5 * 60
        api.inbox = inbox(requests: [])
        await h.checkIn.checkIn(reason: .loop)
        #expect(api.reportedStates == ["r1:pending", "r1:expired"])
    }

    /// Signed out, the phone may still be registered, and the service's check-in alerts would pile up.
    @Test func notLinkedOnlyRemovesTheDeliveredCheckIns() async {
        let api = FakeAIAssistantsAPI()
        api.inbox = inbox(requests: [inboxMeal(id: "r1")])
        let h = makeCheckIn(api: api, isLinked: false)
        await h.checkIn.checkIn(reason: .push)
        h.loopRuns.send(coordinatorTestStart)
        await letDebouncePass()
        #expect(api.calls.isEmpty)
        #expect(h.activity.events.isEmpty)
        #expect(h.removals.calls == 2)
    }

    @Test func inboxNetworkErrorWaitsForTheNextCheckIn() async {
        let api = FakeAIAssistantsAPI()
        api.inbox = inbox(requests: [inboxMeal(id: "r1")])
        api.errors["getInbox"] = .network
        let h = makeCheckIn(api: api)
        await h.checkIn.checkIn(reason: .push)
        #expect(api.calls == ["getInbox"])
        #expect(h.activity.events == checkInActivity)
        #expect(h.removals.calls == 1)
        api.errors = [:]
        await h.checkIn.checkIn(reason: .loop)
        #expect(api.reportedStates == ["r1:pending"])
    }

    @Test func malformedInboxWaitsForTheNextCheckIn() async {
        let api = FakeAIAssistantsAPI()
        api.inbox = inbox(requests: [inboxMeal(id: "r1")])
        api.inboxBody = Data(#"{"requests":[{"id":"r1"}],"answers":[]}"#.utf8)
        let h = makeCheckIn(api: api)
        await h.checkIn.checkIn(reason: .push)
        #expect(api.calls == ["getInbox"])
        api.inboxBody = nil
        await h.checkIn.checkIn(reason: .loop)
        #expect(api.reportedStates == ["r1:pending"])
    }

    @Test func signedOutEndsTheCheckIn() async {
        let api = FakeAIAssistantsAPI()
        api.inbox = inbox(requests: [inboxMeal(id: "r1")])
        api.errors["getInbox"] = .signedOut
        let gate = UploadGate()
        api.inboxGate = gate
        let h = makeCheckIn(api: api)
        let push = Task { await h.checkIn.checkIn(reason: .push) }
        #expect(await eventuallyTrue { api.calls == ["getInbox"] })
        await h.checkIn.checkIn(reason: .loop)
        gate.open()
        await push.value
        // The run the loop asked for ends with it.
        #expect(api.calls == ["getInbox"])
        #expect(h.activity.events == checkInActivity)
        #expect(h.removals.calls == 1)
        // A later check-in runs.
        api.errors = [:]
        await h.checkIn.checkIn(reason: .loop)
        #expect(api.reportedStates == ["r1:pending"])
    }

    @Test func pausedCheckInWaitsForTheOneInFlightAndStartsNoneUntilResumed() async {
        let api = FakeAIAssistantsAPI()
        let gate = UploadGate()
        api.inboxGate = gate
        let h = makeCheckIn(api: api)
        let push = Task { await h.checkIn.checkIn(reason: .push) }
        #expect(await eventuallyTrue { api.calls == ["getInbox"] })
        let paused = TestBox(false)
        let pause = Task {
            await h.checkIn.pause()
            paused.value = true
        }
        await letDebouncePass()
        #expect(!paused.value)
        // Neither asked for after the one in flight, nor started.
        await h.checkIn.checkIn(reason: .loop)
        gate.open()
        await pause.value
        await push.value
        #expect(api.calls == ["getInbox"])
        await h.checkIn.checkIn(reason: .loop)
        #expect(api.calls == ["getInbox"])
        h.checkIn.resume()
        await h.checkIn.checkIn(reason: .loop)
        #expect(api.calls == ["getInbox", "getInbox"])
    }

    @Test func checkInPushIsRecognisedOthersAreNot() {
        #expect(AIRequestHooks.isCheckIn(["trio-rc": ["v": 1, "type": "check-in"]]))
        #expect(!AIRequestHooks.isCheckIn(["encrypted_data": "x"]))
    }

    @Test func loopRunTriggersACheckIn() async {
        let api = FakeAIAssistantsAPI()
        let h = makeCheckIn(api: api)
        h.loopRuns.send(coordinatorTestStart)
        #expect(await eventuallyTrue { api.calls.contains("getInbox") })
    }

    // MARK: - Push hook

    @Test func otherPushIsLeftToTheAppDelegate() {
        let results = FetchResults()
        let checkIn = makeCheckIn(api: FakeAIAssistantsAPI()).checkIn
        #expect(!AIRequestHooks.handleRemoteNotification(["encrypted_data": "x"], checkIn: checkIn, results.complete))
        #expect(results.values.isEmpty)
    }

    @Test func checkInPushChecksInThenCompletesOnce() async {
        let api = FakeAIAssistantsAPI()
        api.inbox = inbox(requests: [inboxMeal(id: "r1")])
        let gate = UploadGate()
        api.inboxGate = gate
        let h = makeCheckIn(api: api)
        let results = FetchResults()
        #expect(AIRequestHooks.handleRemoteNotification(checkInPush, checkIn: h.checkIn, results.complete))
        #expect(await eventuallyTrue { api.calls == ["getInbox"] })
        #expect(results.values.isEmpty)
        gate.open()
        #expect(await eventuallyTrue { results.values == [.newData] })
        #expect(api.reportedStates == ["r1:pending"])
        await letDebouncePass()
        #expect(results.values == [.newData])
    }

    @Test func checkInPushWithoutARuntimeCompletesWithNoData() {
        let results = FetchResults()
        #expect(AIRequestHooks.handleRemoteNotification(checkInPush, checkIn: nil, results.complete))
        #expect(results.values == [.noData])
    }
}

@Suite("AI Assistants service request reporter") struct ServiceRequestReporterTests {
    /// The waits the reporter asked for, in place of sleeping.
    final class Waits {
        private let lock = NSLock()
        private var recorded: [Duration] = []
        var durations: [Duration] { lock.withLock { recorded } }
        var whenWaiting: (() -> Void)?

        func wait(_ duration: Duration) async {
            lock.withLock { recorded.append(duration) }
            whenWaiting?()
        }
    }

    @Test func reportIsSentAsTheContractsStateBody() async {
        let api = FakeAIAssistantsAPI()
        let waits = Waits()
        await ServiceRequestReporter(api: api, sleep: waits.wait).report(.declined(on: .dismissed), for: "r1")
        #expect(api.requestStates.map(\.id) == ["r1"])
        #expect(api.requestStates.map(\.body) == [AIRequestStateBody(.declined(on: .dismissed))])
        #expect(waits.durations.isEmpty)
    }

    @Test func networkErrorIsRetriedOnceAfterFiveSeconds() async {
        let api = FakeAIAssistantsAPI()
        api.errors["putRequestState"] = .network
        let waits = Waits()
        await ServiceRequestReporter(api: api, sleep: waits.wait).report(.expired, for: "r1")
        #expect(api.reportedStates == ["r1:expired", "r1:expired"])
        #expect(waits.durations == [.seconds(5)])
    }

    @Test func retryAfterTheWaitIsSent() async {
        let api = FakeAIAssistantsAPI()
        api.errors["putRequestState"] = .network
        let waits = Waits()
        waits.whenWaiting = { api.errors = [:] }
        await ServiceRequestReporter(api: api, sleep: waits.wait).report(.withdrawn, for: "r1")
        #expect(api.calls == ["putRequestState", "putRequestState"])
        #expect(waits.durations == [.seconds(5)])
    }

    @Test(arguments: [
        AIAssistantsAPIError.http(409, "conflict"),
        .http(500, nil),
        .signedOut,
        .notLinked
    ]) func otherErrorsAreDroppedWithoutARetry(error: AIAssistantsAPIError) async {
        let api = FakeAIAssistantsAPI()
        api.errors["putRequestState"] = error
        let waits = Waits()
        await ServiceRequestReporter(api: api, sleep: waits.wait).report(.expired, for: "r1")
        #expect(api.reportedStates == ["r1:expired"])
        #expect(waits.durations.isEmpty)
    }
}
