import Foundation
import Testing

@testable import Trio

@Suite("AI request coordinator – requests") struct AIRequestCoordinatorRequestTests {
    @Test func newRequestIsAskedOnTheWatchWithTheDose() async {
        let h = makeCoordinator(dose: 1.2, watchAvailable: true)
        await h.coordinator.receive(meal(id: "r1", carbs: 20), via: .service)
        #expect(h.reporter.states == ["r1:pending"])
        guard case let .pending(askedOn, shown, display) = h.reporter.reports.first?.report else {
            Issue.record("Expected a pending report")
            return
        }
        #expect(askedOn == .watch && shown.units == "1.20")
        #expect(h.backup.scheduled.map(\.delay) == [15])
        let prompt = h.prompt("r1")
        #expect(prompt.shown == shown && prompt.title == display.title && prompt.body == display.body)
    }

    @Test func noWatchMeansThePhoneRightAway() async {
        let h = makeCoordinator(watchAvailable: false)
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        guard case let .pending(askedOn, _, _) = h.reporter.reports.first?.report else {
            Issue.record("Expected a pending report")
            return
        }
        #expect(askedOn == .phone)
        #expect(h.backup.scheduled.map(\.delay) == [0])
    }

    @Test func backupFollowsThePreferences() async {
        let h = makeCoordinator(preferences: AIAssistantsPreferences(allowsMealRequests: true, phoneBackupDelay: 30))
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(h.backup.scheduled.map(\.delay) == [30])
    }

    @Test func mealRequestsOffRefusesServiceRequests() async {
        let h = makeCoordinator(preferences: AIAssistantsPreferences(allowsMealRequests: false))
        await h.coordinator.receive(meal(id: "a"), via: .service)
        #expect(h.reporter.reports(for: "a") == [.failed(reason: "Meal requests are off in Trio", carbsLogged: false)])
        #expect(h.backup.scheduled.isEmpty && h.coordinator.current.value == nil)
    }

    @Test func pendingRecordsWhenTheRequestArrivedAndWhenTheIPhoneAsksToo() async {
        let h = makeCoordinator(preferences: AIAssistantsPreferences(allowsMealRequests: true, phoneBackupDelay: 30))
        await h.coordinator.receive(meal(id: "a"), via: .service)
        let pending = h.coordinator.current.value
        #expect(pending?.receivedAt == coordinatorTestStart)
        #expect(pending?.phoneAskAt == coordinatorTestStart + 30)
    }

    @Test func pendingFileFromTheBuildBeforeStillReads() async throws {
        // The file has the approval style, answer route and answer token, and the loop run the dose was worked out on.
        // None of them is read, so the request is pending as one saved now would be.
        let files = CoordinatorFiles.temporary()
        try previousBuildPendingJSON(id: "a", units: "1.20").write(to: files.pending)
        let h = makeCoordinator(files: files)
        await h.coordinator.start()
        let pending = try #require(h.coordinator.current.value)
        #expect(pending.request.id == "a" && pending.units == 1.2 && pending.askedOn == .watch)
        #expect(pending.prompt.shown.units == "1.20" && pending.phoneAskAt == coordinatorTestStart + 15)
        // Opening it works out the dose again, as it does for any request.
        #expect(await h.coordinator.open(id: "a", on: .phone)?.units == 1.2)
    }

    @Test func arrivalNoLongerRefusesForRecentInsulin() async {
        // A bolus just before the request used to make the bolus checks refuse it on arrival. The screens it opens have
        // their own checks, so it's asked about, and the only thing Trio works out first is the dose.
        let h = makeCoordinator()
        // A minute before the request, a 3 U bolus went in.
        await h.coordinator.receive(meal(id: "r0"), via: .service)
        let bolus = await h.coordinator.carryOutWatchConfirm(AIRequestWatchConfirm(id: "r0", units: 3, carbs: nil))
        #expect(bolus == .delivering(shown: AIRequestShown(carbs: 20, fat: 10, protein: 8, units: 3)))
        // Trio's calculator sees it as insulin on board, which leaves no dose for the new meal.
        h.now = coordinatorTestStart + 60
        h.treatments.doseResult = AIRequestDose(units: 0)
        h.treatments.noDoseReasonResult = "insulin on board is at your max"

        await h.coordinator.receive(meal(id: "r1"), via: .service)

        #expect(h.coordinator.current.value?.request.id == "r1")
        #expect(h.reporter.states == ["r0:pending", "r0:delivering", "r1:pending"])
        #expect(h.prompt("r1").body.hasSuffix("Trio suggests no insulin now: insulin on board is at your max"))
        // Nothing was checked, stored or given for it.
        #expect(h.treatments.events == ["store r0", "enact 3", "enacted 3"])
    }

    @Test func notificationHasNoFatProteinLineWhenEntriesAreOff() async throws {
        // "Enable Fat and Protein Entries" is off, as it is by default: the fat and protein won't be logged, so the
        // notification doesn't show them.
        let h = makeCoordinator(dose: 1.2)
        h.treatments.logsFatAndProtein = false
        await h.coordinator.receive(meal(id: "r1", carbs: 20, fat: 10, protein: 8), via: .service)
        guard case let .pending(_, _, display) = h.reporter.reports.first?.report else {
            Issue.record("Expected a pending report")
            return
        }
        #expect(display.body == "Bolus 1.20\u{00A0}U · 20\u{00A0}g carbs")
        #expect(h.prompt("r1").body == display.body)

        // With them on, they're shown.
        h.treatments.logsFatAndProtein = true
        await h.coordinator.receive(meal(id: "r2", carbs: 20, fat: 10, protein: 8), via: .service)
        #expect(h.prompt("r2").body == "Bolus 1.20\u{00A0}U · 20\u{00A0}g carbs\n10\u{00A0}g fat · 8\u{00A0}g protein")
    }

    @Test func fatAndProteinOnlyIsRefusedWhenEntriesAreOff() async {
        // With "Enable Fat and Protein Entries" off, only carbs are logged: a request with none would log nothing.
        let h = makeCoordinator()
        h.treatments.logsFatAndProtein = false
        await h.coordinator.receive(meal(id: "r1", carbs: 0, fat: 10, protein: 8), via: .service)
        await h.coordinator.receive(meal(id: "r2", carbs: 0, fat: 0, protein: 8), via: .service)
        #expect(h.reporter.reports.map(\.report) == [
            .failed(reason: "Fat and protein entries are off in Trio", carbsLogged: false),
            .failed(reason: "Fat and protein entries are off in Trio", carbsLogged: false)
        ])
        #expect(h.backup.scheduled.isEmpty && h.coordinator.current.value == nil)

        // With carbs, it's asked; with the entries on, so is a request without carbs.
        await h.coordinator.receive(meal(id: "r3", carbs: Decimal(string: "0.5")!, fat: 10, protein: 8), via: .service)
        h.treatments.logsFatAndProtein = true
        await h.coordinator.receive(meal(id: "r4", carbs: 0, fat: 10, protein: 8), via: .service)
        #expect(h.reporter.states.contains("r3:pending") && h.reporter.states.contains("r4:pending"))
    }

    @Test func overMaxCarbsFailsWithoutAsking() async {
        let h = makeCoordinator(limits: .init(maxCarbs: 50, maxFat: 50, maxProtein: 50, maxBolus: 10))
        await h.coordinator.receive(meal(id: "r1", carbs: 80), via: .service)
        #expect(h.reporter.reports.map(\.report) == [.failed(reason: "Over your max carbs (50 g)", carbsLogged: false)])
        #expect(h.backup.scheduled.isEmpty && h.coordinator.current.value == nil)
    }

    @Test func overMaxFatOrProteinFailsWithItsOwnWording() async {
        let h = makeCoordinator(limits: .init(maxCarbs: 50, maxFat: 30, maxProtein: 40, maxBolus: 10))
        await h.coordinator.receive(meal(id: "r1", fat: 31), via: .service)
        await h.coordinator.receive(meal(id: "r2", protein: 41), via: .service)
        await h.coordinator.receive(meal(id: "r3", carbs: 50, fat: 30, protein: 40), via: .service)
        #expect(h.reporter.states == ["r1:failed", "r2:failed", "r3:pending"])
        #expect(h.reporter.reports.prefix(2).map(\.report) == [
            .failed(reason: "Over your max fat (30 g)", carbsLogged: false),
            .failed(reason: "Over your max protein (40 g)", carbsLogged: false)
        ])
    }

    @Test(arguments: [
        // (carbs, fat, protein)
        (Decimal(-1), Decimal(10), Decimal(8)),
        (Decimal(20), Decimal(-0.5), Decimal(8)),
        (Decimal(20), Decimal(10), Decimal(-8))
    ]) func negativeAmountFailsWithoutAsking(carbs: Decimal, fat: Decimal, protein: Decimal) async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1", carbs: carbs, fat: fat, protein: protein), via: .service)
        #expect(h.reporter.reports.map(\.report) == [.failed(reason: "Invalid amounts", carbsLogged: false)])
        #expect(h.backup.scheduled.isEmpty && h.coordinator.current.value == nil)
    }

    @Test func requestIsAskedForAtMostFiveMinutesAfterItWasMade() async {
        let h = makeCoordinator()
        let request = timedMeal(id: "r1", createdAt: coordinatorTestStart, expiresAt: coordinatorTestStart + 60 * 60)
        await h.coordinator.receive(request, via: .service)
        #expect(h.coordinator.current.value?.request.expiresAt == coordinatorTestStart + 5 * 60)
        #expect(h.prompt("r1").expiresAt == coordinatorTestStart + 5 * 60)
        h.now = coordinatorTestStart + 5 * 60
        await h.coordinator.expireIfDue()
        #expect(h.reporter.states == ["r1:pending", "r1:expired"])
    }

    @Test func requestFromAServiceClockAheadIsAskedForAtMostFiveMinutesFromNow() async {
        let h = makeCoordinator()
        let createdAt = coordinatorTestStart + 10 * 60
        await h.coordinator.receive(timedMeal(id: "r1", createdAt: createdAt, expiresAt: createdAt + 5 * 60), via: .service)
        #expect(h.coordinator.current.value?.request.expiresAt == coordinatorTestStart + 5 * 60)
    }

    @Test func shorterLifetimeIsKept() async {
        let h = makeCoordinator()
        await h.coordinator.receive(
            timedMeal(id: "r1", createdAt: coordinatorTestStart, expiresAt: coordinatorTestStart + 60),
            via: .service
        )
        #expect(h.coordinator.current.value?.request.expiresAt == coordinatorTestStart + 60)
    }

    @Test func expiredOnArrivalIsNotAsked() async {
        let h = makeCoordinator(now: coordinatorTestStart + 5 * 60)
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(h.reporter.states == ["r1:expired"])
        #expect(h.backup.scheduled.isEmpty && h.coordinator.current.value == nil)
    }

    @Test func requestWithoutIDIsDropped() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: ""), via: .service)
        #expect(h.reporter.reports.isEmpty && h.backup.scheduled.isEmpty && h.coordinator.current.value == nil)
    }

    @Test func unsavedRequestIDFailsWithoutAsking() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let h = makeCoordinator(files: CoordinatorFiles(
            seen: folder.appendingPathComponent("seen-requests.json"),
            pending: CoordinatorFiles.temporary().pending
        ))
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        try FileManager.default.removeItem(at: folder) // so the next seen-ID write fails
        await h.coordinator.receive(meal(id: "r2"), via: .service)
        #expect(h.reporter.states == ["r1:pending", "r2:failed"])
        #expect(h.reporter.reports.last?.report == .failed(reason: "Trio couldn't save the request ID", carbsLogged: false))
        #expect(h.coordinator.current.value?.request.id == "r1")
        #expect(h.backup.scheduled.map(\.id) == ["r1"] && h.backup.cancelled.isEmpty)
        await h.coordinator.receive(meal(id: "r2"), via: .service) // seen, but neither pending nor final
        #expect(h.reporter.states == ["r1:pending", "r2:failed"])
    }

    @Test func repeatedIDIsNotAskedAgainAndRepeatsTheOutcome() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        h.now = coordinatorTestStart + 5 * 60
        await h.coordinator.expireIfDue()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(h.reporter.states == ["r1:pending", "r1:expired", "r1:expired"])
        #expect(h.backup.scheduled.count == 1)
    }

    @Test func repeatedPendingRequestResendsPending() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(h.reporter.states == ["r1:pending", "r1:pending"])
        #expect(h.reporter.reports.count == 2 && h.reporter.reports[0].report == h.reporter.reports[1].report)
        #expect(h.backup.scheduled.count == 1 && h.coordinator.current.value?.request.id == "r1")
    }

    @Test func repeatedIDAfterRelaunchRepeatsTheSavedOutcome() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        h.now = coordinatorTestStart + 5 * 60
        await h.coordinator.expireIfDue()
        let relaunched = makeCoordinator(files: h.files, now: h.now)
        await relaunched.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(relaunched.reporter.states == ["r1:expired"])
        #expect(relaunched.backup.scheduled.isEmpty)
    }

    @Test func finalReportSurvivesRelaunch() async {
        let h = makeCoordinator(limits: .init(maxCarbs: 50, maxFat: 50, maxProtein: 50, maxBolus: 10))
        await h.coordinator.receive(meal(id: "r1", carbs: 80), via: .service)
        let failed = AIRequestReport.failed(reason: "Over your max carbs (50 g)", carbsLogged: false)
        #expect(h.reporter.reports.map(\.report) == [failed])
        // Default limits: asking again would make it pending, so a `failed` here is the saved report.
        let relaunched = makeCoordinator(files: h.files)
        await relaunched.coordinator.receive(meal(id: "r1", carbs: 80), via: .service)
        #expect(relaunched.reporter.reports.map(\.report) == [failed])
        #expect(relaunched.backup.scheduled.isEmpty && relaunched.coordinator.current.value == nil)
    }

    @Test func newRequestReplacesThePendingOne() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        await h.coordinator.receive(meal(id: "r2"), via: .service)
        #expect(h.reporter.states == ["r1:pending", "r1:replaced", "r2:pending"])
        #expect(h.backup.cancelled == ["r1"])
        #expect(h.coordinator.current.value?.request.id == "r2")
    }

    @Test func expiresAtExpiresAt() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        h.now = coordinatorTestStart + 5 * 60 - 1
        await h.coordinator.expireIfDue()
        #expect(h.reporter.states == ["r1:pending"])
        h.now = coordinatorTestStart + 5 * 60
        await h.coordinator.expireIfDue()
        #expect(h.reporter.states == ["r1:pending", "r1:expired"])
        #expect(h.coordinator.current.value == nil)
        #expect(h.backup.cancelled == ["r1"])
        #expect(!FileManager.default.fileExists(atPath: h.files.pending.path))
    }

    @Test func receiveBeforeStartKeepsTheOldRequest() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        let relaunched = makeCoordinator(files: h.files)
        await relaunched.coordinator.receive(meal(id: "r2"), via: .service)
        #expect(relaunched.reporter.states == ["r1:replaced", "r2:pending"])
        #expect(relaunched.backup.cancelled == ["r1"])
    }

    @Test func relaunchExpiresAnOverdueRequest() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        let relaunched = makeCoordinator(files: h.files, now: coordinatorTestStart + 5 * 60)
        await relaunched.coordinator.start()
        #expect(relaunched.reporter.states == ["r1:expired"])
        #expect(relaunched.coordinator.current.value == nil)
        #expect(relaunched.backup.scheduled.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.files.pending.path))
    }

    @Test func relaunchKeepsARequestStillInItsWindow() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        let relaunched = makeCoordinator(files: h.files, now: coordinatorTestStart + 4 * 60)
        await relaunched.coordinator.start()
        #expect(relaunched.coordinator.current.value?.request.id == "r1")
        #expect(relaunched.coordinator.current.value == h.coordinator.current.value)
        #expect(relaunched.reporter.reports.isEmpty && relaunched.backup.scheduled.isEmpty)
        relaunched.now = coordinatorTestStart + 5 * 60
        await relaunched.coordinator.expireIfDue()
        #expect(relaunched.reporter.states == ["r1:expired"])
    }

    @Test func withdrawPendingReportsWithdrawn() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        await h.coordinator.withdraw(id: "r1", request: nil, via: .service)
        #expect(h.reporter.states == ["r1:pending", "r1:withdrawn"])
        #expect(h.backup.cancelled == ["r1"])
        #expect(h.coordinator.current.value == nil)
        #expect(!FileManager.default.fileExists(atPath: h.files.pending.path))
    }

    @Test func withdrawOfAFinishedRequestResendsItsOutcome() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        h.now = coordinatorTestStart + 5 * 60
        await h.coordinator.expireIfDue()
        await h.coordinator.withdraw(id: "r1", request: nil, via: .service)
        #expect(h.reporter.states == ["r1:pending", "r1:expired", "r1:expired"])
        #expect(h.backup.cancelled == ["r1"])
    }

    @Test func withdrawOfAnUnseenRequestMarksItSeen() async {
        let h = makeCoordinator()
        await h.coordinator.withdraw(id: "r9", request: meal(id: "r9"), via: .service)
        #expect(h.reporter.states == ["r9:withdrawn"])
        await h.coordinator.receive(meal(id: "r9"), via: .service)
        #expect(h.reporter.states == ["r9:withdrawn", "r9:withdrawn"])
        #expect(h.backup.scheduled.isEmpty && h.coordinator.current.value == nil)
    }

    @Test func onlyTheFirstFinalStateIsReported() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        h.now = coordinatorTestStart + 5 * 60
        await h.coordinator.expireIfDue()
        await h.coordinator.expireIfDue()
        await h.coordinator.withdraw(id: "r1", request: nil, via: .service)
        await h.coordinator.withdraw(id: "r1", request: meal(id: "r1"), via: .service)
        // The second expiry sends nothing, and each withdraw re-sends the first final report.
        #expect(h.reporter.states == ["r1:pending", "r1:expired", "r1:expired", "r1:expired"])
    }

    @Test func doseIsFlooredToTwoDecimals() async {
        let h = makeCoordinator(dose: 0.275)
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(h.coordinator.current.value?.units == 0.27)
        #expect(h.prompt("r1").shown.units == "0.27")
    }

    // MARK: The text

    @Test func promptAndReportCarryTheDoseAndFatAndProtein() async {
        let h = makeCoordinator(dose: 1.2)
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        guard case let .pending(_, _, display) = h.reporter.reports.first?.report else {
            Issue.record("Expected a pending report")
            return
        }
        #expect(display.title == "ChatGPT: slice of pizza")
        #expect(display.body == "Bolus 1.20\u{00A0}U · 20\u{00A0}g carbs\n10\u{00A0}g fat · 8\u{00A0}g protein")
        #expect(h.prompt("r1").title == display.title)
        #expect(h.prompt("r1").body == display.body)
        // Trio asked about the dose it shows, and the fake has no reason to give.
        #expect(h.treatments.reasonedUnits == [1.2])
    }

    @Test func theResentPendingReportIsTheSame() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(h.reporter.reports.count == 2)
        #expect(h.reporter.reports[0].report == h.reporter.reports[1].report)
    }

    @Test func aZeroDoseRequestSaysWhy() async {
        let h = makeCoordinator(dose: 0)
        h.treatments.noDoseReasonResult = "glucose is forecast to go low"
        await h.coordinator.receive(meal(id: "r1", carbs: 35, fat: 0, protein: 0), via: .service)
        #expect(h.prompt("r1").body == """
        No bolus · 35\u{00A0}g carbs
        Trio suggests no insulin now: glucose is forecast to go low
        """)
        #expect(h.prompt("r1").shown.units == "0.00")
        // Trio asked for the reason of the dose it shows.
        #expect(h.treatments.reasonedUnits == [0])
    }

    @Test func aZeroDoseRequestWithoutAKnownReasonSaysSoPlainly() async {
        let h = makeCoordinator(dose: 0)
        await h.coordinator.receive(meal(id: "r1", carbs: 35, fat: 0, protein: 0), via: .service)
        #expect(h.prompt("r1").body == "No bolus · 35\u{00A0}g carbs\nTrio suggests no insulin now")
    }

    // MARK: The watch is open

    @Test func viewingPostponesTheBackupOnce() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(h.coordinator.current.value?.phoneAskAt == coordinatorTestStart + 15)

        h.now = coordinatorTestStart + 10
        await h.coordinator.postponePhoneBackup(id: "r1")
        // Opening the screen again doesn't put it off again.
        h.now = coordinatorTestStart + 20
        await h.coordinator.postponePhoneBackup(id: "r1")

        #expect(h.backup.scheduled.map(\.delay) == [15, 60])
        #expect(h.backup.scheduled.map(\.id) == ["r1", "r1"])
        #expect(h.backup.scheduled.map(\.askedOn) == [.watch, .watch])
        #expect(h.backup.cancelled == ["r1"])
        #expect(h.coordinator.current.value?.phoneAskAt == coordinatorTestStart + 70)
    }

    @Test func postponedBackupIsSavedAndSurvivesARelaunch() async {
        let files = CoordinatorFiles.temporary()
        let h = makeCoordinator(files: files)
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        await h.coordinator.postponePhoneBackup(id: "r1")

        let relaunched = makeCoordinator(files: files)
        await relaunched.coordinator.start()
        #expect(relaunched.coordinator.current.value?.phoneAskAt == coordinatorTestStart + 60)
    }

    @Test func viewingLeavesARequestAskedOnThePhoneAlone() async {
        let h = makeCoordinator(watchAvailable: false)
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        await h.coordinator.postponePhoneBackup(id: "r1")
        #expect(h.backup.scheduled.map(\.delay) == [0])
        #expect(h.backup.cancelled.isEmpty)
        #expect(h.coordinator.current.value?.phoneAskAt == coordinatorTestStart)
    }

    @Test func viewingForAnotherOrNoRequestChangesNothing() async {
        let h = makeCoordinator()
        await h.coordinator.postponePhoneBackup(id: "r1") // nothing is pending
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        await h.coordinator.postponePhoneBackup(id: "r2")
        #expect(h.backup.scheduled.map(\.delay) == [15])
        #expect(h.backup.cancelled.isEmpty)
        #expect(h.coordinator.current.value?.phoneAskAt == coordinatorTestStart + 15)
    }

    @Test func eachRequestCanBePostponedOnce() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        await h.coordinator.postponePhoneBackup(id: "r1")
        await h.coordinator.receive(meal(id: "r2"), via: .service) // replaces r1
        await h.coordinator.postponePhoneBackup(id: "r2")
        await h.coordinator.postponePhoneBackup(id: "r2")
        #expect(h.backup.scheduled.map(\.delay) == [15, 60, 15, 60])
        #expect(h.backup.scheduled.map(\.id) == ["r1", "r1", "r2", "r2"])
    }
}

/// A meal request made and expiring at the given times.
private func timedMeal(id: String, createdAt: Date, expiresAt: Date) -> AIMealRequest {
    AIMealRequest(
        id: id,
        source: "ChatGPT",
        description: "slice of pizza",
        carbs: 20,
        fat: 10,
        protein: 8,
        createdAt: createdAt,
        expiresAt: expiresAt
    )
}
