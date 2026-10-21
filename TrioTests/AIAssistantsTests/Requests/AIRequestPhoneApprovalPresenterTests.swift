import Combine
import Foundation
import SwiftUI
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

    // MARK: The sheet's heights

    @Test func askingTakesTheWholeHeightWhenThereIsAWarning() {
        for phase in [AIRequestPhoneApprovalPhase.asking, .checking] {
            #expect(phase.detents(hasWarning: true, isAccessibilitySize: false) == [.large])
            #expect(phase.detents(hasWarning: true, isAccessibilitySize: true) == [.large])
        }
    }

    @Test func askingTakesTheWholeHeightAtAnAccessibilitySize() {
        for phase in [AIRequestPhoneApprovalPhase.asking, .checking] {
            #expect(phase.detents(hasWarning: false, isAccessibilitySize: true) == [.large])
        }
    }

    @Test func askingIsAHalfSheetWithNoWarningAndOrdinaryText() {
        for phase in [AIRequestPhoneApprovalPhase.asking, .checking] {
            #expect(phase.detents(hasWarning: false, isAccessibilitySize: false) == [.medium])
        }
    }

    @Test func aResultCanBePulledUpWhateverElseIsTrue() {
        let phase = AIRequestPhoneApprovalPhase.result(AIRequestResultText.message(for: sampleOutcome(.expired)))
        for hasWarning in [false, true] {
            for isAccessibilitySize in [false, true] {
                #expect(phase.detents(hasWarning: hasWarning, isAccessibilitySize: isAccessibilitySize) == [.medium, .large])
            }
        }
    }

    // MARK: The sheet's haptics

    /// The sheet's result for how a request ended.
    private func result(_ report: AIRequestReport, approvedOn: AIRequestAnswerSide? = nil, declinedOn: AIRequestDeclinedOn? = nil)
        -> AIRequestResultMessage
    {
        AIRequestResultText.message(for: sampleOutcome(report, approvedOn: approvedOn, declinedOn: declinedOn))
    }

    @Test func aSuccessPlaysSuccess() {
        #expect(AIRequestPhoneHaptic(result: result(.delivering(shown: sampleShown), approvedOn: .phone)) == .success)
        #expect(AIRequestPhoneHaptic(result: result(.logged(shown: sampleShown), approvedOn: .phone)) == .success)
    }

    @Test func aRefusalPlaysError() {
        #expect(AIRequestPhoneHaptic(result: result(.failed(reason: "Glucose is low", carbsLogged: false))) == .error)
    }

    @Test func carbsLoggedWithoutTheBolusPlaysWarning() {
        let message = result(.failed(reason: "The pump didn't answer", carbsLogged: true), approvedOn: .phone)
        #expect(message.tone == .warning)
        #expect(AIRequestPhoneHaptic(result: message) == .warning)
    }

    @Test func expiryPlaysWarning() {
        #expect(AIRequestPhoneHaptic(result: result(.expired)) == .warning)
    }

    @Test func anEndNobodyAnsweredPlaysWarning() {
        // Replaced and canceled carry no word of their own for a haptic, so they warn as expiry does.
        #expect(AIRequestPhoneHaptic(result: result(.replaced)) == .warning)
        #expect(AIRequestPhoneHaptic(result: result(.withdrawn)) == .warning)
    }

    @Test func aDeclinePlaysALightImpact() {
        #expect(AIRequestPhoneHaptic(result: result(.declined(on: .phone), declinedOn: .phone)) == .lightImpact)
        #expect(AIRequestPhoneHaptic(result: result(.declined(on: .watch), declinedOn: .watch)) == .lightImpact)
        #expect(AIRequestPhoneHaptic(result: result(.declined(on: .dismissed), declinedOn: .dismissed)) == .lightImpact)
    }

    @Test func aResultPlaysItsHapticOnArrival() {
        let success = AIRequestPhoneApprovalPhase.result(result(.delivering(shown: sampleShown), approvedOn: .phone))
        #expect(success.haptic(after: .asking) == .success)
        // The watch answered while Face ID was up.
        #expect(success.haptic(after: .checking) == .success)
        let declined = AIRequestPhoneApprovalPhase.result(result(.declined(on: .phone), declinedOn: .phone))
        #expect(declined.haptic(after: .checking) == .lightImpact)
    }

    @Test func askingAndCheckingPlayNothing() {
        // Face ID has its own haptics, and a Face ID that didn't pass changes nothing.
        #expect(AIRequestPhoneApprovalPhase.checking.haptic(after: .asking) == nil)
        #expect(AIRequestPhoneApprovalPhase.asking.haptic(after: .checking) == nil)
        #expect(AIRequestPhoneApprovalPhase.asking.haptic(after: .asking) == nil)
    }

    @Test func aResultPlaysItsHapticOnlyOnce() {
        let phase = AIRequestPhoneApprovalPhase.result(result(.expired))
        #expect(phase.haptic(after: phase) == nil)
    }

    @Test func eachHapticMapsToItsSensoryFeedback() {
        #expect(AIRequestPhoneHaptic.success.feedback == .success)
        #expect(AIRequestPhoneHaptic.error.feedback == .error)
        #expect(AIRequestPhoneHaptic.warning.feedback == .warning)
        #expect(AIRequestPhoneHaptic.lightImpact.feedback == .impact(weight: .light))
    }

    // MARK: The countdown

    @Test func secondsLeftRoundUpAndStopAtZero() {
        let end = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(AIRequestPhoneApprovalView.secondsLeft(until: end, now: end - 300) == 300)
        #expect(AIRequestPhoneApprovalView.secondsLeft(until: end, now: end - 59.4) == 60)
        #expect(AIRequestPhoneApprovalView.secondsLeft(until: end, now: end - 0.2) == 1)
        #expect(AIRequestPhoneApprovalView.secondsLeft(until: end, now: end + 30) == 0)
    }

    @Test func theCountdownTurnsUrgentInTheLastMinute() {
        #expect(AIRequestPhoneApprovalView.isUrgent(secondsLeft: 61) == false)
        #expect(AIRequestPhoneApprovalView.isUrgent(secondsLeft: 60))
        #expect(AIRequestPhoneApprovalView.isUrgent(secondsLeft: 1))
        #expect(AIRequestPhoneApprovalView.isUrgent(secondsLeft: 0))
    }

    // MARK: VoiceOver

    @Test func theResultIsSpokenAsItsHeadlineThenItsDetail() {
        let message = result(.declined(on: .phone), declinedOn: .phone)
        #expect(AIRequestPhoneApprovalView.spoken(result: message) == "Declined. Nothing was logged.")
    }
}
