import Foundation
import Testing

@testable import Trio

@Suite("AI request coordinator – requests") struct AIRequestCoordinatorRequestTests {
    @Test func newRequestIsAskedOnTheWatchWithTheDose() async {
        let h = makeCoordinator(dose: 1.2, watchAvailable: true)
        await h.coordinator.receive(meal(id: "r1", carbs: 20), via: .service)
        #expect(h.reporter.states == ["r1:pending"])
        guard case let .pending(askedOn, style, route, shown, display) = h.reporter.reports.first?.report else {
            Issue.record("Expected a pending report")
            return
        }
        #expect(askedOn == .watch && style == .twoStep && route == .both && shown.units == "1.20")
        #expect(h.backup.scheduled.map(\.delay) == [15])
        #expect(h.watch.delivered.isEmpty) // service requests reach the watch by push
        let prompt = h.prompt("r1")
        #expect(prompt.shown == shown && prompt.title == display.title && prompt.body == display.body)
        #expect(prompt.answerToken == nil && prompt.answerURL == nil)
    }

    @Test func noWatchMeansThePhoneRightAway() async {
        let h = makeCoordinator(watchAvailable: false)
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        guard case let .pending(askedOn, _, _, _, _) = h.reporter.reports.first?.report else {
            Issue.record("Expected a pending report")
            return
        }
        #expect(askedOn == .phone)
        #expect(h.backup.scheduled.map(\.delay) == [0])
    }

    @Test func localRequestIsDeliveredOverWatchConnectivity() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .local)
        #expect(h.reporter.states == ["r1:pending"])
        #expect(h.watch.delivered.count == 1 && h.watch.delivered.first == h.prompt("r1"))
    }

    @Test func promptFollowsThePreferences() async {
        let h = makeCoordinator(preferences: AIAssistantsPreferences(
            allowsMealRequests: true,
            approvalStyle: .oneGesture,
            phoneBackupDelay: 30,
            answerRoute: .watchOnly
        ))
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        guard case let .pending(_, style, route, _, _) = h.reporter.reports.first?.report else {
            Issue.record("Expected a pending report")
            return
        }
        #expect(style == .oneGesture && route == .watchOnly)
        #expect(h.prompt("r1").approvalStyle == .oneGesture && h.prompt("r1").answerRoute == .watchOnly)
        #expect(h.backup.scheduled.map(\.delay) == [30])
    }

    @Test func overMaxCarbsFailsWithoutAsking() async {
        let h = makeCoordinator(limits: .init(maxCarbs: 50, maxFat: 50, maxProtein: 50))
        await h.coordinator.receive(meal(id: "r1", carbs: 80), via: .service)
        #expect(h.reporter.reports.map(\.report) == [.failed(reason: "Over your max carbs (50 g)", carbsLogged: false)])
        #expect(h.backup.scheduled.isEmpty && h.coordinator.current.value == nil)
    }

    @Test func overMaxFatOrProteinFailsWithItsOwnWording() async {
        let h = makeCoordinator(limits: .init(maxCarbs: 50, maxFat: 30, maxProtein: 40))
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
        #expect(h.backup.scheduled.isEmpty && h.watch.delivered.isEmpty && h.coordinator.current.value == nil)
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
        #expect(h.backup.scheduled.map(\.id) == ["r1"] && h.backup.cancelled.isEmpty && h.watch.withdrawn.isEmpty)
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
        let h = makeCoordinator(limits: .init(maxCarbs: 50, maxFat: 50, maxProtein: 50))
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
        #expect(h.watch.withdrawn == ["r1"])
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
        #expect(h.backup.cancelled == ["r1"] && h.watch.withdrawn == ["r1"])
        #expect(!FileManager.default.fileExists(atPath: h.files.pending.path))
    }

    @Test func receiveBeforeStartKeepsTheOldRequest() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        let relaunched = makeCoordinator(files: h.files)
        await relaunched.coordinator.receive(meal(id: "r2"), via: .service)
        #expect(relaunched.reporter.states == ["r1:replaced", "r2:pending"])
        #expect(relaunched.backup.cancelled == ["r1"] && relaunched.watch.withdrawn == ["r1"])
    }

    @Test func relaunchExpiresAnOverdueRequest() async {
        let h = makeCoordinator()
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        let relaunched = makeCoordinator(files: h.files, now: coordinatorTestStart + 5 * 60)
        await relaunched.coordinator.start()
        #expect(relaunched.reporter.states == ["r1:expired"])
        #expect(relaunched.coordinator.current.value == nil)
        #expect(relaunched.backup.scheduled.isEmpty && relaunched.watch.delivered.isEmpty)
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
        #expect(h.backup.cancelled == ["r1"] && h.watch.withdrawn == ["r1"])
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
        #expect(h.backup.cancelled == ["r1"] && h.watch.withdrawn == ["r1"])
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

    // MARK: The context and the text

    private static let pizzaContext = AIRequestContext(
        glucose: "142 mg/dL ↗",
        glucoseAgeMinutes: 3,
        recentCarbs: .init(amount: "20", minutesAgo: 6),
        recentBolus: .init(amount: "3.00", minutesAgo: 8)
    )

    @Test func promptAndReportCarryTheContext() async {
        let h = makeCoordinator(dose: 1.2)
        h.treatments.contextResult = Self.pizzaContext
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        guard case let .pending(_, _, _, _, display) = h.reporter.reports.first?.report else {
            Issue.record("Expected a pending report")
            return
        }
        #expect(h.prompt("r1").context == Self.pizzaContext)
        #expect(display.context == Self.pizzaContext)
        #expect(display.context == h.treatments.contextResult)
        // Trio asked for the context of the dose it shows.
        #expect(h.treatments.contextedUnits == [1.2])
        // The text is built from the same context, with the dose first.
        #expect(h.prompt("r1").body == display.body)
        #expect(display.title == "ChatGPT: slice of pizza")
        #expect(display.body == """
        Bolus 1.20\u{00A0}U · 20\u{00A0}g carbs
        10\u{00A0}g fat · 8\u{00A0}g protein · 142 mg/dL ↗ · 3 min ago
        Carbs 20\u{00A0}g logged 6 min ago
        Bolus 3.00\u{00A0}U given 8 min ago
        """)
        #expect(h.prompt("r1").testKind == nil)
    }

    @Test func theResentPendingReportKeepsTheContext() async {
        let h = makeCoordinator()
        h.treatments.contextResult = Self.pizzaContext
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(h.reporter.reports.count == 2)
        guard case let .pending(_, _, _, _, resent) = h.reporter.reports.last?.report else {
            Issue.record("Expected a pending report")
            return
        }
        #expect(resent.context == Self.pizzaContext)
        #expect(h.reporter.reports[0].report == h.reporter.reports[1].report)
    }

    @Test func contextSurvivesARelaunchInThePendingFile() async {
        let files = CoordinatorFiles.temporary()
        let first = makeCoordinator(files: files)
        first.treatments.contextResult = Self.pizzaContext
        await first.coordinator.receive(meal(id: "r1"), via: .service)
        let second = makeCoordinator(files: files)
        await second.coordinator.start()
        #expect(second.coordinator.current.value?.prompt.context == Self.pizzaContext)
    }

    @Test func approvalStyleIsInTheBodyAndInThePrompt() async {
        let h = makeCoordinator(preferences: AIAssistantsPreferences(allowsMealRequests: true, approvalStyle: .oneGesture))
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(h.prompt("r1").approvalStyle == .oneGesture)
        #expect(h.prompt("r1").body.hasSuffix("\nApprove gives the bolus now"))
        let twoStep = makeCoordinator()
        await twoStep.coordinator.receive(meal(id: "r1"), via: .service)
        #expect(!twoStep.prompt("r1").body.contains("Approve gives"))
    }

    @Test(arguments: [
        (AIRequestTestKind.dryRun, "Test only: nothing is logged or given"),
        (AIRequestTestKind.real, "Real dose. Decline unless you're eating this.")
    ]) func aTestRequestSaysSoAndKeepsItsKind(kind: AIRequestTestKind, line: String) async {
        let h = makeCoordinator()
        var request = meal(id: "r1", carbs: 10, fat: 0, protein: 0)
        request.testKind = kind
        await h.coordinator.receive(request, via: .local)
        #expect(h.prompt("r1").testKind == kind)
        #expect(h.prompt("r1").body.hasSuffix("\n" + line))
        #expect(h.watch.delivered.first?.testKind == kind)
    }

    @Test func aZeroDoseRequestSaysWhy() async {
        let h = makeCoordinator(dose: 0)
        h.treatments.contextResult = AIRequestContext(noDoseReason: "glucose is forecast to go low")
        await h.coordinator.receive(meal(id: "r1", carbs: 35, fat: 0, protein: 0), via: .service)
        #expect(h.prompt("r1").body == """
        No bolus · 35\u{00A0}g carbs
        Trio suggests no insulin now: glucose is forecast to go low
        """)
        #expect(h.prompt("r1").shown.units == "0.00")
    }

    @Test func aZeroDoseRequestWithoutAKnownReasonSaysSoPlainly() async {
        let h = makeCoordinator(dose: 0)
        await h.coordinator.receive(meal(id: "r1", carbs: 35, fat: 0, protein: 0), via: .service)
        #expect(h.prompt("r1").body == "No bolus · 35\u{00A0}g carbs\nTrio suggests no insulin now")
        #expect(h.prompt("r1").context?.noDoseReason == nil)
    }

    // MARK: The display MAC

    @Test func pendingReportCarriesTheDisplayMAC() async throws {
        let h = makeCoordinator(preferences: AIAssistantsPreferences(allowsMealRequests: true, approvalStyle: .oneGesture))
        let key = try #require(h.keys.rotate())
        h.treatments.contextResult = Self.pizzaContext
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        guard case let .pending(_, style, _, shown, display) = h.reporter.reports.first?.report else {
            Issue.record("Expected a pending report")
            return
        }
        let mac = try #require(display.mac)
        #expect(h.prompt("r1").displayMac == mac)
        // It covers the amounts, the text, the style and the context the watch gets.
        #expect(AIRequestSigner.isValidDisplayMAC(
            mac,
            id: "r1",
            approvalStyle: style,
            shown: shown,
            title: display.title,
            body: display.body,
            context: display.context,
            key: key
        ))
        #expect(style == .oneGesture && display.context == Self.pizzaContext)
        #expect(shown == h.prompt("r1").shown)
        #expect(mac == AIRequestSigner.displayMAC(
            id: "r1", approvalStyle: .oneGesture, shown: AIRequestShown(carbs: 20, fat: 10, protein: 8, units: 1.2),
            title: display.title, body: display.body, context: Self.pizzaContext, key: key
        ))
        // The pending report sent again, and after a relaunch, is the same.
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        guard case let .pending(_, _, _, _, resent) = h.reporter.reports.last?.report else {
            Issue.record("Expected the pending report again")
            return
        }
        #expect(h.reporter.reports.count == 2 && resent.mac == mac)
        let relaunched = makeCoordinator(files: h.files)
        await relaunched.coordinator.start()
        #expect(relaunched.coordinator.current.value?.prompt.displayMac == mac)
    }

    @Test func withoutAKeyTheRequestIsNotSigned() async {
        let h = makeCoordinator(preferences: AIAssistantsPreferences(allowsMealRequests: true, approvalStyle: .oneGesture))
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        guard case let .pending(_, _, _, _, display) = h.reporter.reports.first?.report else {
            Issue.record("Expected a pending report")
            return
        }
        // The watch then opens the request instead of approving it from the notification.
        #expect(display.mac == nil && h.prompt("r1").displayMac == nil)
    }

    @Test func aLocalRequestCarriesTheDisplayMACToTheWatch() async throws {
        let h = makeCoordinator()
        let key = try #require(h.keys.rotate())
        await h.coordinator.receive(meal(id: "r1"), via: .local)
        let delivered = try #require(h.watch.delivered.first)
        #expect(AIRequestSigner.isValidDisplayMAC(
            delivered.displayMac,
            id: "r1",
            approvalStyle: .twoStep,
            shown: delivered.shown,
            title: delivered.title,
            body: delivered.body,
            context: delivered.context,
            key: key
        ))
    }

    @Test func aRequestWithALineBreakInItsIDOrSourceIsNotSigned() async throws {
        // The watch would refuse it anyway; signed, its lines could be read as other fields.
        let h = makeCoordinator()
        _ = try #require(h.keys.rotate())
        await h.coordinator.receive(meal(id: "r1\noneGesture"), via: .service)
        let base = meal(id: "r2")
        let multiLineSource = AIMealRequest(
            id: base.id,
            source: "ChatGPT\noneGesture",
            description: base.description,
            carbs: base.carbs,
            fat: base.fat,
            protein: base.protein,
            createdAt: base.createdAt,
            expiresAt: base.expiresAt
        )
        await h.coordinator.receive(multiLineSource, via: .service)
        let displays: [AIRequestDisplay] = h.reporter.reports.compactMap {
            guard case let .pending(_, _, _, _, display) = $0.report else { return nil }
            return display
        }
        #expect(displays.count == 2)
        #expect(displays.allSatisfy { $0.mac == nil })
    }

    @Test func aRequestWithAnEmptyContextStringIsNotSigned() async throws {
        // Present but empty signs the same as missing, so the watch never trusts it.
        let h = makeCoordinator()
        _ = try #require(h.keys.rotate())
        h.treatments.contextResult = AIRequestContext(glucose: "", glucoseAgeMinutes: 3)
        await h.coordinator.receive(meal(id: "r1"), via: .service)
        guard case let .pending(_, _, _, _, display) = h.reporter.reports.first?.report else {
            Issue.record("Expected a pending report")
            return
        }
        #expect(display.mac == nil && h.prompt("r1").displayMac == nil)
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
