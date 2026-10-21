import Combine
import Foundation
import Testing

@testable import Trio

/// The amounts `samplePending` asks for, as the outcomes show them.
private let sampleShown = AIRequestShown(carbs: "20.00", fat: "10.00", protein: "8.00", units: "1.20")

/// How a request ended, with the title and amounts of the sample request.
private func sampleOutcome(
    _ report: AIRequestReport,
    id: String = "r1",
    askedOn: AIRequestAskedOn? = .phone,
    approvedOn: AIRequestAnswerSide? = nil,
    declinedOn: AIRequestDeclinedOn? = nil
) -> AIRequestOutcome {
    AIRequestOutcome(
        id: id,
        title: "ChatGPT: slice of pizza",
        source: "ChatGPT",
        shown: sampleShown,
        report: report,
        askedOn: askedOn,
        approvedOn: approvedOn,
        declinedOn: declinedOn
    )
}

@Suite("AI request phone approval presenter") @MainActor struct AIRequestPhoneApprovalPresenterTests {
    /// Lets the presenter see what the subjects sent, which it receives on the main queue.
    private func flushMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// A presenter that follows the subjects a test sends on. No coordinator or runtime is behind it.
    private struct Harness {
        let presenter: AIRequestPhoneApprovalPresenter
        let current: CurrentValueSubject<PendingAIRequest?, Never>
        let outcomes = PassthroughSubject<AIRequestOutcome, Never>()
    }

    /// `delivered` holds the identifiers of the notifications in Notification Center.
    private func harness(pending: PendingAIRequest? = nil, delivered: [String] = []) async -> Harness {
        let center = FakeNotificationCenter()
        center.delivered = delivered
        let harness = Harness(
            presenter: AIRequestPhoneApprovalPresenter(
                isBackupDue: { await AIRequestPhoneBackup(center: center).isDue($0, now: Date()) },
                coordinator: { nil }
            ),
            current: CurrentValueSubject(pending)
        )
        harness.presenter.follow(harness.current.eraseToAnyPublisher(), outcomes: harness.outcomes.eraseToAnyPublisher())
        await flushMainQueue()
        return harness
    }

    // MARK: Presenting

    @Test func tappedNotificationPresentsThePendingRequest() async {
        let h = await harness(pending: samplePending(id: "r1"))
        h.presenter.open(requestID: "r1")
        #expect(h.presenter.presented?.request.id == "r1")
        #expect(h.presenter.result == nil)
    }

    @Test func tapBeforeTheCoordinatorHasTheRequestWaitsForIt() async {
        let current = CurrentValueSubject<PendingAIRequest?, Never>(nil)
        let presenter = AIRequestPhoneApprovalPresenter(coordinator: { nil })
        presenter.open(requestID: "r1") // a cold launch from the notification, before anything is followed
        presenter.follow(current.eraseToAnyPublisher(), outcomes: Empty().eraseToAnyPublisher())
        await flushMainQueue()
        #expect(presenter.presented == nil)
        current.send(samplePending(id: "r1"))
        await flushMainQueue()
        #expect(presenter.presented?.request.id == "r1")
    }

    @Test func tapForAnotherRequestPresentsNothing() async {
        let h = await harness(pending: samplePending(id: "r2"))
        h.presenter.open(requestID: "r1")
        #expect(h.presenter.presented == nil)
    }

    // MARK: The request leaves pending

    @Test func requestStillPendingKeepsTheSheetOpen() async {
        let h = await harness(pending: samplePending(id: "r1"))
        h.presenter.open(requestID: "r1")
        h.current.send(samplePending(id: "r1"))
        await flushMainQueue()
        #expect(h.presenter.presented?.request.id == "r1")
        #expect(h.presenter.result == nil)
    }

    @Test func leavingPendingNeverTakesTheSheetAway() async {
        let h = await harness(pending: samplePending(id: "r1"))
        h.presenter.open(requestID: "r1")
        h.current.send(nil)
        await flushMainQueue()
        #expect(h.presenter.presented?.request.id == "r1")
        #expect(h.presenter.result == nil)
    }

    @Test func replacementRequestDoesNotTakeTheSheetOrPresentItself() async {
        let h = await harness(pending: samplePending(id: "r1"))
        h.presenter.open(requestID: "r1")
        // The coordinator sends nil, then the new request.
        h.current.send(nil)
        h.current.send(samplePending(id: "r2"))
        await flushMainQueue()
        #expect(h.presenter.presented?.request.id == "r1")
    }

    // MARK: Results

    @Test func resultArrivesForThePresentedRequest() async throws {
        let pending = samplePending(id: "r1")
        let h = await harness(pending: pending)
        h.presenter.open(requestID: "r1")
        let outcome = sampleOutcome(.delivering(shown: sampleShown), approvedOn: .phone)

        h.current.send(nil)
        h.outcomes.send(outcome)
        await flushMainQueue()

        let result = try #require(h.presenter.result)
        #expect(result == AIRequestResultText.message(for: outcome))
        #expect(result.id == "r1")
        #expect(result.tone == .success)
        #expect(result.answeredOn == .phone)
        #expect(h.presenter.presented?.request.id == "r1")
    }

    @Test func answeredOnTheWatchShowsTheWatchResult() async throws {
        let h = await harness(pending: samplePending(id: "r1", askedOn: .watch))
        h.presenter.open(requestID: "r1")

        // The wearer approved on the watch while the sheet was open.
        h.current.send(nil)
        h.outcomes.send(sampleOutcome(.delivering(shown: sampleShown), askedOn: .watch, approvedOn: .watch))
        await flushMainQueue()

        let result = try #require(h.presenter.result)
        #expect(result.answeredOn == .watch)
        #expect(result.tone == .success)
        #expect(h.presenter.presented?.request.id == "r1")
    }

    @Test func declinedOnTheWatchShowsTheWatchResult() async throws {
        let h = await harness(pending: samplePending(id: "r1", askedOn: .watch))
        h.presenter.open(requestID: "r1")

        h.current.send(nil)
        h.outcomes.send(sampleOutcome(.declined(on: .watch), askedOn: .watch, declinedOn: .watch))
        await flushMainQueue()

        let result = try #require(h.presenter.result)
        #expect(result.answeredOn == .watch)
        #expect(result.tone == .neutral)
        #expect(h.presenter.presented?.request.id == "r1")
    }

    @Test func requestThatExpiresWithTheSheetOpenShowsTheExpiredResult() async throws {
        let h = await harness(pending: samplePending(id: "r1"))
        h.presenter.open(requestID: "r1")

        h.current.send(nil)
        h.outcomes.send(sampleOutcome(.expired))
        await flushMainQueue()

        let result = try #require(h.presenter.result)
        #expect(result.headline == "Expired")
        #expect(result.answeredOn == nil)
        #expect(h.presenter.presented?.request.id == "r1")
    }

    @Test func outcomeForAnotherRequestIsIgnored() async {
        let h = await harness(pending: samplePending(id: "r1"))
        h.presenter.open(requestID: "r1")

        h.outcomes.send(sampleOutcome(.expired, id: "r2"))
        await flushMainQueue()

        #expect(h.presenter.result == nil)
        #expect(h.presenter.presented?.request.id == "r1")
    }

    @Test func outcomeWithNothingPresentedIsNotKept() async {
        let h = await harness(pending: samplePending(id: "r1"))

        // The sheet isn't showing r1 yet, so this one has nobody to show it to.
        h.outcomes.send(sampleOutcome(.expired))
        await flushMainQueue()
        #expect(h.presenter.result == nil)

        h.presenter.open(requestID: "r1")
        #expect(h.presenter.result == nil)
    }

    // MARK: Closing

    @Test func replacedRequestKeepsResultUntilClosed() async throws {
        let first = samplePending(id: "r1")
        let h = await harness(pending: first)
        h.presenter.open(requestID: "r1")

        // A newer request replaces the one the sheet shows: nil, the new request, then the old one's outcome.
        h.current.send(nil)
        h.current.send(samplePending(id: "r2"))
        h.outcomes.send(AIRequestOutcome(.replaced, pending: first))
        await flushMainQueue()

        #expect(h.presenter.presented?.request.id == "r1")
        #expect(try #require(h.presenter.result).headline == "Replaced")

        // Done: the result goes, and the request that replaced it is shown.
        await h.presenter.close().value

        #expect(h.presenter.presented?.request.id == "r2")
        #expect(h.presenter.result == nil)
    }

    @Test func closeShowsNothingWhenNothingIsWaiting() async {
        let h = await harness(pending: samplePending(id: "r1"))
        h.presenter.open(requestID: "r1")
        h.current.send(nil)
        h.outcomes.send(sampleOutcome(.declined(on: .phone), declinedOn: .phone))
        await flushMainQueue()
        #expect(h.presenter.result != nil)

        await h.presenter.close().value

        #expect(h.presenter.presented == nil)
        #expect(h.presenter.result == nil)
    }

    @Test func closeLeavesAWaitingRequestTheWatchIsStillAskingFor() async {
        let first = samplePending(id: "r1")
        let h = await harness(pending: first)
        h.presenter.open(requestID: "r1")
        h.current.send(nil)
        h.current.send(samplePending(id: "r2", askedOn: .watch, phoneAskAt: Date().addingTimeInterval(60)))
        h.outcomes.send(AIRequestOutcome(.replaced, pending: first))
        await flushMainQueue()

        await h.presenter.close().value

        #expect(h.presenter.presented == nil)
    }

    @Test func tapForAnotherRequestWaitsForTheResultToBeClosed() async {
        let first = samplePending(id: "r1")
        let h = await harness(pending: first)
        h.presenter.open(requestID: "r1")
        h.current.send(nil)
        h.current.send(samplePending(id: "r2", askedOn: .watch, phoneAskAt: Date().addingTimeInterval(60)))
        h.outcomes.send(AIRequestOutcome(.replaced, pending: first))
        await flushMainQueue()

        // The wearer taps r2's notification while r1's result is on screen. The result isn't taken away.
        h.presenter.open(requestID: "r2")
        #expect(h.presenter.presented?.request.id == "r1")
        #expect(h.presenter.result != nil)

        // They tapped it, so Done shows it, even though the watch is still asking for it.
        await h.presenter.close().value
        #expect(h.presenter.presented?.request.id == "r2")
        #expect(h.presenter.result == nil)
    }

    // MARK: Opening Trio

    @Test func openingTrioPresentsARequestAskedOnTheIPhone() async {
        let h = await harness(pending: samplePending(id: "r1", askedOn: .phone))
        await h.presenter.presentIfDue(h.current.value)
        #expect(h.presenter.presented?.request.id == "r1")
    }

    @Test func openingTrioLeavesARequestTheWatchIsStillAskingFor() async {
        let h = await harness(pending: samplePending(id: "r1", askedOn: .watch))
        await h.presenter.presentIfDue(h.current.value)
        #expect(h.presenter.presented == nil)
    }

    @Test func openingTrioPresentsARequestWhoseBackupWasDelivered() async {
        let h = await harness(pending: samplePending(id: "r1", askedOn: .watch), delivered: ["ai-request-r1"])
        await h.presenter.presentIfDue(h.current.value)
        #expect(h.presenter.presented?.request.id == "r1")
    }

    @Test func dueByPhoneAskAtEvenWithoutANotification() async {
        // The notification is gone, or never came: only the time says the iPhone is asking.
        let due = samplePending(id: "r1", askedOn: .watch, phoneAskAt: Date().addingTimeInterval(-1))
        let h = await harness(pending: due, delivered: [])
        await h.presenter.presentIfDue(h.current.value)
        #expect(h.presenter.presented?.request.id == "r1")
    }

    @Test func notDueBeforePhoneAskAtWithoutANotification() async {
        let early = samplePending(id: "r1", askedOn: .watch, phoneAskAt: Date().addingTimeInterval(60))
        let h = await harness(pending: early, delivered: [])
        await h.presenter.presentIfDue(h.current.value)
        #expect(h.presenter.presented == nil)
    }

    @Test func openingTrioWithNothingPendingPresentsNothing() async {
        let h = await harness()
        await h.presenter.presentIfDue(nil)
        h.current.send(samplePending(id: "r1", askedOn: .watch))
        await flushMainQueue()
        #expect(h.presenter.presented == nil)
    }

    @Test func dueRequestFoundBeforeThePresenterHasItWaitsForIt() async {
        // A cold launch: the coordinator has read the request, and the presenter hasn't received it yet.
        let h = await harness()
        await h.presenter.presentIfDue(samplePending(id: "r1", askedOn: .phone))
        #expect(h.presenter.presented == nil)
        h.current.send(samplePending(id: "r1", askedOn: .phone))
        await flushMainQueue()
        #expect(h.presenter.presented?.request.id == "r1")
    }

    @Test func openingTrioLeavesAResultOnScreen() async {
        let first = samplePending(id: "r1")
        let h = await harness(pending: first)
        h.presenter.open(requestID: "r1")
        h.current.send(nil)
        h.current.send(samplePending(id: "r2", askedOn: .phone))
        h.outcomes.send(AIRequestOutcome(.replaced, pending: first))
        await flushMainQueue()

        await h.presenter.presentDueRequest()

        #expect(h.presenter.presented?.request.id == "r1")
        #expect(h.presenter.result != nil)
    }

    // MARK: The sheet's phases

    @Test func phaseIsAskingUntilTheWearerAnswers() {
        #expect(AIRequestPhoneApprovalPhase(result: nil, requestID: "r1", isWorking: false) == .asking)
        #expect(AIRequestPhoneApprovalPhase(result: nil, requestID: "r1", isWorking: true) == .checking)
    }

    @Test func aResultTakesOverFromChecking() {
        // The watch answered while Face ID was up.
        let message = AIRequestResultText.message(for: sampleOutcome(.expired))
        #expect(AIRequestPhoneApprovalPhase(result: message, requestID: "r1", isWorking: true) == .result(message))
        #expect(AIRequestPhoneApprovalPhase(result: message, requestID: "r1", isWorking: false) == .result(message))
    }

    @Test func theSheetCanBeSwipedAwayOnlyOnceItShowsAResult() {
        let message = AIRequestResultText.message(for: sampleOutcome(.expired))
        #expect(AIRequestPhoneApprovalPhase.asking.allowsSwipeToDismiss == false)
        #expect(AIRequestPhoneApprovalPhase.checking.allowsSwipeToDismiss == false)
        #expect(AIRequestPhoneApprovalPhase.result(message).allowsSwipeToDismiss)
    }

    @Test func aResultForAnotherRequestIsNotShown() {
        let message = AIRequestResultText.message(for: sampleOutcome(.expired, id: "r2"))
        #expect(AIRequestPhoneApprovalPhase(result: message, requestID: "r1", isWorking: false) == .asking)
        #expect(AIRequestPhoneApprovalPhase(result: message, requestID: "r2", isWorking: false) == .result(message))
    }
}
