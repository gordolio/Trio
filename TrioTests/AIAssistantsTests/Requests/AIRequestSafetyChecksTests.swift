import Foundation
import Testing

@testable import Trio

@Suite("AI request safety checks") struct AIRequestSafetyChecksTests {
    @Test func checkBolusUsesTheDoseIOBTime() async {
        let h = makeCoordinator()
        let loopRun = coordinatorTestStart - 20
        h.treatments.doseResult = AIRequestDose(units: 1.2, iobAsOf: loopRun)
        await h.coordinator.receive(meal(id: "a"), via: .service)
        #expect(h.treatments.checkedSince == [loopRun]) // checked on arrival
        _ = await h.coordinator.answer(.phone(.approve, id: "a"))
        #expect(h.treatments.checkedSince == [loopRun, loopRun]) // and again at approval
    }

    @Test func recentInsulinRefusesWithoutAsking() async {
        let h = makeCoordinator()
        h.treatments.checkResult = "Trio gave 0.50 U after working out this dose. Ask again in a few minutes"
        await h.coordinator.receive(meal(id: "a"), via: .service)
        #expect(h.coordinator.current.value == nil)
        #expect(h.watch.delivered.isEmpty && h.backup.scheduled.isEmpty)
        #expect(h.reporter.reports(for: "a") == [.failed(
            reason: "Trio gave 0.50 U after working out this dose. Ask again in a few minutes",
            carbsLogged: false
        )])
    }

    @Test func noRecentLoopRefusesADose() async {
        let h = makeCoordinator()
        h.treatments.doseResult = AIRequestDose(units: 1.2, iobAsOf: nil)
        await h.coordinator.receive(meal(id: "a"), via: .service)
        #expect(
            h.reporter
                .reports(for: "a") == [.failed(reason: "Trio hasn't looped in the last 30 minutes", carbsLogged: false)]
        )
    }

    @Test func noRecentLoopStillAsksForACarbsOnlyRequest() async {
        let h = makeCoordinator()
        h.treatments.doseResult = AIRequestDose(units: 0, iobAsOf: nil)
        await h.coordinator.receive(meal(id: "a"), via: .service)
        #expect(h.coordinator.current.value?.request.id == "a")
    }

    @Test func mealRequestsOffRefusesServiceRequests() async {
        let h = makeCoordinator(preferences: AIAssistantsPreferences(allowsMealRequests: false))
        await h.coordinator.receive(meal(id: "a"), via: .service)
        #expect(h.reporter.reports(for: "a") == [.failed(reason: "Meal requests are off in Trio", carbsLogged: false)])
        await h.coordinator.receive(meal(id: "b"), via: .local) // test requests still work
        #expect(h.coordinator.current.value?.request.id == "b")
    }

    @Test func pendingRecordsWhenAndOnWhatItWasWorkedOut() async {
        let h = makeCoordinator(preferences: AIAssistantsPreferences(allowsMealRequests: true, phoneBackupDelay: 30))
        await h.coordinator.receive(meal(id: "a"), via: .service)
        let pending = h.coordinator.current.value
        #expect(pending?.receivedAt == coordinatorTestStart)
        #expect(pending?.iobAsOf == coordinatorTestStart - 60)
        #expect(pending?.phoneAskAt == coordinatorTestStart + 30)
    }

    @Test func pendingFileFromBeforeTheUpdateIsRefusedAtApproval() async throws {
        // A pending-request.json without receivedAt, iobAsOf or phoneAskAt.
        let files = CoordinatorFiles.temporary()
        try oldPendingJSON(id: "a", units: "1.20").write(to: files.pending)
        let h = makeCoordinator(files: files)
        await h.coordinator.start()
        #expect(h.coordinator.current.value?.request.id == "a")
        _ = await h.coordinator.answer(.phone(.approve, id: "a"))
        #expect(h.treatments.enacted.isEmpty)
        #expect(
            h.reporter.reports(for: "a").last ==
                .failed(reason: "Trio hasn't looped in the last 30 minutes", carbsLogged: false)
        )
    }

    @Test func carbsLoggedAfterArrivalRefusesTheApproval() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "a"), via: .service)
        h.treatments.carbsLoggedResult = true
        _ = await h.coordinator.answer(.phone(.approve, id: "a"))
        #expect(h.treatments.carbsLoggedAfter == [coordinatorTestStart])
        #expect(h.treatments.stored.isEmpty && h.treatments.enacted.isEmpty)
        #expect(
            h.reporter.reports(for: "a").last ==
                .failed(reason: "Carbs were logged after this request arrived", carbsLogged: false)
        )
    }

    @Test func zeroDoseAtApprovalRefusesAShownDose() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "a"), via: .service)
        h.treatments.doseResult = AIRequestDose(units: 0, iobAsOf: coordinatorTestStart)
        _ = await h.coordinator.answer(.phone(.approve, id: "a"))
        #expect(h.treatments.stored.isEmpty && h.treatments.enacted.isEmpty)
        #expect(
            h.reporter.reports(for: "a").last ==
                .failed(reason: "Trio no longer suggests insulin for this meal", carbsLogged: false)
        )
    }

    @Test func lowerDoseAtApprovalStillGivesTheShownDose() async {
        // Only a 0 refuses: the signed dose can't change, and max IOB is the validator's job.
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "a"), via: .service)
        h.treatments.doseResult = AIRequestDose(units: 0.9, iobAsOf: coordinatorTestStart)
        _ = await h.coordinator.answer(.phone(.approve, id: "a"))
        #expect(h.treatments.enacted == [1.2])
    }

    @Test func dryRunChecksEverythingAndGivesNothing() async {
        let h = makeCoordinator()
        var request = meal(id: "t", carbs: 10, fat: 0, protein: 0)
        request.testKind = .dryRun
        await h.coordinator.receive(request, via: .local)
        _ = await h.coordinator.answer(.phone(.approve, id: "t"))
        #expect(h.treatments.checkedSince.count == 2)
        #expect(h.treatments.carbsLoggedAfter == [coordinatorTestStart])
        #expect(h.treatments.stored.isEmpty && h.treatments.enacted.isEmpty)
        #expect(h.reporter.reports(for: "t").last == .dryRun(shown: h.prompt("t").shown))
    }

    @Test func dryRunKeepsItsTestKindWhenItsLifetimeIsCapped() async {
        // A request that asks for more than 5 minutes is asked with a shorter one, and is still a dry run.
        let h = makeCoordinator()
        var request = AIMealRequest(
            id: "t", source: "Test", description: "test request", carbs: 10, fat: 0, protein: 0,
            createdAt: coordinatorTestStart, expiresAt: coordinatorTestStart + 60 * 60
        )
        request.testKind = .dryRun
        await h.coordinator.receive(request, via: .local)
        #expect(h.coordinator.current.value?.request.testKind == .dryRun)
        _ = await h.coordinator.answer(.phone(.approve, id: "t"))
        #expect(h.treatments.stored.isEmpty && h.treatments.enacted.isEmpty)
    }

    @Test func recentInsulinReasonSaysHowMuchWithTwoDecimals() {
        #expect(
            BaseAIRequestTreatments.reason(for: .recentBolusWithinWindow(totalRecent: 0.5)) ==
                "Trio gave 0.50 U after working out this dose. Ask again in a few minutes"
        )
        #expect(
            BaseAIRequestTreatments.reason(for: .recentBolusWithinWindow(totalRecent: 2.125)) ==
                "Trio gave 2.13 U after working out this dose. Ask again in a few minutes"
        )
    }
}
