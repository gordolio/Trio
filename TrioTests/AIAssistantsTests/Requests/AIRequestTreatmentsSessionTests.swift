import Combine
import Foundation
import SwiftUI
import Testing
import UserNotifications

@testable import Trio

/// Trio's router, recording each screen sent to the main modal after it was made.
private final class FakeRouter: Router {
    let mainModalScreen = CurrentValueSubject<Screen?, Never>(nil)
    let mainSecondaryModalView = CurrentValueSubject<AnyView?, Never>(nil)
    private(set) var sent: [Screen?] = []
    private var subscription: AnyCancellable?

    init() {
        subscription = mainModalScreen.dropFirst().sink { [weak self] screen in self?.sent.append(screen) }
    }

    func view(for _: Screen) -> AnyView {
        AnyView(EmptyView())
    }
}

/// Trio's pump history, standing in for `PumpHistoryStorage` and its Core Data rows.
private final class FakePumpHistory {
    let updates = PassthroughSubject<Void, Never>()
    private let lock = NSLock()
    private var stored: [AIRequestPumpBolusEvent] = []

    /// Stores the bolus and sends the update, as `PumpHistoryStorage` does once it has saved.
    func store(_ event: AIRequestPumpBolusEvent, sendingUpdate: Bool = true) {
        lock.withLock { stored.append(event) }
        if sendingUpdate {
            updates.send()
        }
    }

    func boluses(since date: Date) -> [AIRequestPumpBolusEvent] {
        lock.withLock { stored.filter { $0.timestamp >= date } }
    }
}

/// A request for 82.5 g of pizza with 10 g fat and 5 g protein, created at `coordinatorTestStart`.
private func pizza(id: String = "r1") -> AIMealRequest {
    AIMealRequest(
        id: id,
        source: "ChatGPT",
        description: "pizza",
        carbs: d("82.5"),
        fat: 10,
        protein: 5,
        createdAt: coordinatorTestStart,
        expiresAt: coordinatorTestStart + 5 * 60
    )
}

private func d(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}

/// What the sheet's report says it logged and gave for `pizza()`, with `units`.
private func pizzaShown(units: Decimal) -> AIRequestShown {
    AIRequestShown(carbs: d("82.5"), fat: 10, protein: 5, units: units)
}

/// The Treatments sheet a request opens: the opener, the session behind the sheet, and how both end.
@Suite("AI request Treatments sheet") @MainActor struct AIRequestTreatmentsSessionTests {
    private let h: CoordinatorHarness
    private let router: FakeRouter
    private let center: FakeNotificationCenter
    /// Stands in for `APSManager.bolusProgress`.
    private let progress: CurrentValueSubject<Decimal?, Never>
    /// Stands in for `BolusFailureObserver.bolusDidFail()`.
    private let failures: PassthroughSubject<Void, Never>
    /// The text of `APSManager.lastError`.
    private let lastError: TestBox<String?>
    /// Stands in for `APSManager.roundBolus(amount:)`.
    private let rounding: TestBox<(Decimal) -> Decimal>
    /// How many times the bolus signals were stopped.
    private let signalStops: TestBox<Int>
    /// Sends when the session's deadline passes.
    private let deadline: PassthroughSubject<Void, Never>
    /// The seconds of each deadline the session set.
    private let deadlines: TestBox<[TimeInterval]>
    private let history: FakePumpHistory
    /// Whether the key window shows a sheet, a cover or an alert outside Trio's router.
    private let keyWindowPresents: TestBox<Bool>
    private let session: AIRequestTreatmentsSession
    private let opener: AIRequestTreatmentsOpener

    init() {
        let h = makeCoordinator()
        let router = FakeRouter()
        let center = FakeNotificationCenter()
        let progress = CurrentValueSubject<Decimal?, Never>(nil)
        let failures = PassthroughSubject<Void, Never>()
        let lastError = TestBox<String?>(nil)
        let rounding = TestBox<(Decimal) -> Decimal>({ $0 })
        let signalStops = TestBox(0)
        let deadline = PassthroughSubject<Void, Never>()
        let deadlines = TestBox<[TimeInterval]>([])
        let history = FakePumpHistory()
        let keyWindowPresents = TestBox(false)
        let session = AIRequestTreatmentsSession(
            coordinator: { h.coordinator },
            router: { router },
            notifications: { center },
            bolusSignals: {
                AIRequestBolusSignals(
                    progress: progress,
                    failures: failures.eraseToAnyPublisher(),
                    lastErrorText: { lastError.value },
                    roundBolus: { rounding.value($0) },
                    historyUpdates: history.updates.eraseToAnyPublisher(),
                    boluses: { history.boluses(since: $0) },
                    stop: { signalStops.value += 1 }
                )
            },
            deadline: { seconds in
                deadlines.value.append(seconds)
                return deadline.eraseToAnyPublisher()
            },
            now: { h.now }
        )
        self.h = h
        self.router = router
        self.center = center
        self.progress = progress
        self.failures = failures
        self.lastError = lastError
        self.rounding = rounding
        self.signalStops = signalStops
        self.deadline = deadline
        self.deadlines = deadlines
        self.history = history
        self.keyWindowPresents = keyWindowPresents
        self.session = session
        opener = AIRequestTreatmentsOpener(
            router: { router },
            coordinator: { h.coordinator },
            session: session,
            now: { h.now },
            isDue: { pending, now in await AIRequestPhoneBackup(center: center).isDue(pending, now: now) },
            keyWindowPresents: { keyWindowPresents.value }
        )
    }

    /// Lets the session see what was sent to it, which it receives on the main queue.
    private func flushMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Opens `request` from its notification, and shows its sheet with the wearer's limits loaded.
    @discardableResult private func openSheet(_ request: AIMealRequest = pizza()) async -> Treatments.StateModel {
        await h.coordinator.receive(request, via: .service)
        await opener.open(requestID: request.id).value
        await flushMainQueue()
        let state = Treatments.StateModel()
        state.maxCarbs = 250
        session.sheetAppeared(state: state, recalculate: {})
        return state
    }

    /// The wearer presses Log with `amount` in the Bolus field, for now.
    private func submit(_ state: Treatments.StateModel, amount: Decimal, external: Bool = false) {
        state.amount = amount
        state.externalInsulin = external
        state.date = h.now
        session.willSubmit(from: state)
    }

    /// The pump took this bolus, `seconds` after Log, and Trio stored it.
    private func storeOwnBolus(_ amount: Decimal?, after seconds: TimeInterval = 5) async {
        history.store(AIRequestPumpBolusEvent(timestamp: h.now + seconds, amount: amount, isSMB: false, isExternal: false))
        await settle()
    }

    /// The loop gave an SMB, `seconds` after Log, and Trio stored it.
    private func storeSMB(_ amount: Decimal, after seconds: TimeInterval = 5) async {
        history.store(AIRequestPumpBolusEvent(timestamp: h.now + seconds, amount: amount, isSMB: true, isExternal: false))
        await settle()
    }

    /// Lets the session read the pump history it was told of, and act on it.
    private func settle() async {
        await flushMainQueue()
        try? await Task.sleep(for: .milliseconds(20))
        await flushMainQueue()
    }

    /// Face ID passed: upstream shows its progress just before it gives the insulin.
    private func unlock(_ state: Treatments.StateModel) async {
        state.isAwaitingDeterminationResult = true
        await flushMainQueue()
    }

    /// Face ID failed or was canceled: upstream shows its alert.
    private func failFaceID(_ state: Treatments.StateModel) async {
        state.showDeterminationFailureAlert = true
        await flushMainQueue()
    }

    /// The sheet closes the way upstream closes it: the router's modal goes, then the sheet disappears.
    private func closeSheet() async {
        router.mainModalScreen.send(nil)
        await flushMainQueue()
        session.sheetDisappeared()
    }

    /// Waits for the request's final report, after its pending one.
    private func finalReport(_ id: String = "r1") async -> AIRequestReport? {
        _ = await eventuallyTrue { h.reporter.reports(for: id).count >= 2 }
        let reports = h.reporter.reports(for: id)
        return reports.count >= 2 ? reports.last : nil
    }

    /// Gives the session time to report, then checks it reported nothing.
    private func expectNoFinalReport() async {
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.reporter.states == ["r1:pending"])
    }

    // MARK: Opening

    @Test func opensTreatmentsForThePendingRequest() async {
        await h.coordinator.receive(pizza(), via: .service)
        await opener.open(requestID: "r1").value
        #expect(router.sent == [.treatmentView])
        #expect(session.requestID == "r1")

        // The sheet holds the request past its expiry while it's open.
        h.now = coordinatorTestStart + 5 * 60 + 1
        await h.coordinator.expireIfDue()
        #expect(h.coordinator.current.value?.request.id == "r1")

        // The sheet is filled in with the request when it appears.
        let state = Treatments.StateModel()
        state.maxCarbs = 250
        session.sheetAppeared(state: state, recalculate: {})
        #expect(state.carbs == d("82.5"))
        #expect(state.note == "AI: ChatGPT – pizza")
    }

    @Test func doesNotOpenWhileAnotherSheetIsOpen() async {
        await h.coordinator.receive(pizza(), via: .service)
        // The iPhone is asking for it, so bringing Trio to the front would open it too.
        h.now = coordinatorTestStart + 15
        router.mainModalScreen.send(.settings)
        await opener.open(requestID: "r1").value
        await opener.openDueRequest()
        #expect(router.sent == [.settings])

        router.mainModalScreen.send(nil)
        router.mainSecondaryModalView.send(AnyView(EmptyView()))
        await opener.open(requestID: "r1").value
        await opener.openDueRequest()
        #expect(router.sent == [.settings, nil])
        #expect(session.requestID == nil)
        #expect(session.gramFormatter == nil)
    }

    @Test func doesNotOpenOverALocalSheet() async {
        // Home shows a sheet of its own, outside the router.
        await h.coordinator.receive(pizza(), via: .service)
        h.now = coordinatorTestStart + 15
        keyWindowPresents.value = true
        await opener.open(requestID: "r1").value
        await opener.openDueRequest()
        #expect(router.sent.isEmpty)
        #expect(session.requestID == nil)
        #expect(session.gramFormatter == nil)

        // Once it's gone, opening Trio again opens the request.
        keyWindowPresents.value = false
        await opener.openDueRequest()
        #expect(router.sent == [.treatmentView])
    }

    @Test func doesNotOpenWhenThatSheetCloses() async {
        await h.coordinator.receive(pizza(), via: .service)
        router.mainModalScreen.send(.settings)
        await opener.open(requestID: "r1").value
        router.mainModalScreen.send(nil)
        await flushMainQueue()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(router.sent == [.settings, nil])
        #expect(session.requestID == nil)
        // The request keeps waiting.
        #expect(h.coordinator.current.value?.request.id == "r1")
        #expect(h.reporter.states == ["r1:pending"])
    }

    @Test func doesNotOpenAnotherRequest() async {
        await h.coordinator.receive(pizza(id: "r1"), via: .service)
        await opener.open(requestID: "r2").value
        #expect(router.sent.isEmpty)

        // Nor one a newer request replaced.
        await h.coordinator.receive(pizza(id: "r2"), via: .service)
        await opener.open(requestID: "r1").value
        #expect(router.sent.isEmpty)
        #expect(session.requestID == nil)
    }

    @Test func opensTheDueRequestWhenTrioComesToTheFront() async {
        // Asked on the watch first; the iPhone asks too 15 s later.
        await h.coordinator.receive(pizza(), via: .service)
        await opener.openDueRequest()
        #expect(router.sent.isEmpty)

        h.now = coordinatorTestStart + 15
        await opener.openDueRequest()
        #expect(router.sent == [.treatmentView])
        #expect(session.requestID == "r1")
    }

    // MARK: Filling in

    @Test func prefillWaitsForLimits() async {
        await h.coordinator.receive(pizza(), via: .service)
        await opener.open(requestID: "r1").value
        let state = Treatments.StateModel()
        #expect(state.maxCarbs == 0)
        let recalculated = TestBox(0)
        session.sheetAppeared(state: state, recalculate: { recalculated.value += 1 })
        await flushMainQueue()
        #expect(state.carbs == 0)
        #expect(state.note.isEmpty)
        #expect(recalculated.value == 0)

        state.maxCarbs = 100
        #expect(await eventuallyTrue { state.carbs == d("82.5") })
        #expect(state.fat == 10)
        #expect(state.protein == 5)
        #expect(state.note == "AI: ChatGPT – pizza")
        #expect(state.amount == 0)
        #expect(recalculated.value == 1)
    }

    @Test func requestFormatterKeepsFractionalGrams() async throws {
        await h.coordinator.receive(pizza(), via: .service)
        await opener.open(requestID: "r1").value
        let formatter = try #require(session.gramFormatter)
        #expect(formatter.numberStyle == .decimal)
        #expect(formatter.maximumIntegerDigits == 3)
        #expect(formatter.maximumFractionDigits == 2)
        #expect(formatter.minimumFractionDigits == 0)
        // The sheet formats in the wearer's locale; this checks the digits, so it pins one.
        formatter.locale = Locale(identifier: "en_US")
        #expect(formatter.string(from: 82.5) == "82.5")
        #expect(formatter.string(from: 82) == "82")
        #expect(formatter.string(from: d("82.25") as NSNumber) == "82.25")
    }

    @Test func noFormatterWithoutARequest() async {
        #expect(session.gramFormatter == nil)
        await openSheet()
        #expect(session.gramFormatter != nil)
        await closeSheet()
        #expect(session.gramFormatter == nil)

        // A sheet the wearer opens afterwards is a manual one.
        let manual = Treatments.StateModel()
        manual.maxCarbs = 250
        session.sheetAppeared(state: manual, recalculate: {})
        #expect(session.gramFormatter == nil)
        #expect(manual.carbs == 0)
    }

    @Test func manualSheetIsLeftAlone() async {
        // A request is pending, but the wearer opened Treatments themselves.
        await h.coordinator.receive(pizza(), via: .service)
        router.mainModalScreen.send(.treatmentView)
        let state = Treatments.StateModel()
        state.maxCarbs = 250
        state.carbs = 40
        session.sheetAppeared(state: state, recalculate: {})
        #expect(state.carbs == 40)
        #expect(state.note.isEmpty)
        submit(state, amount: 1)
        await unlock(state)
        progress.send(0)
        await closeSheet()
        await expectNoFinalReport()
        #expect(h.left.isEmpty)
        #expect(deadlines.value.isEmpty)
    }

    // MARK: Closing

    @Test func closingWithoutSubmitDeclines() async {
        await openSheet()
        await closeSheet()
        #expect(await finalReport() == .declined(on: .phone))
        #expect(session.requestID == nil)
        // The wearer closed it: no notice.
        await flushMainQueue()
        #expect(center.added.isEmpty)
    }

    @Test func coverOverTheSheetDoesNotEndTheSession() async {
        // The AI food chat covers the sheet: the sheet disappears, but the router still shows it.
        let state = await openSheet()
        session.sheetDisappeared()
        #expect(session.requestID == "r1")
        #expect(session.gramFormatter != nil)
        await expectNoFinalReport()

        // The cover goes: the sheet appears again and keeps what the wearer typed.
        state.carbs = 60
        session.sheetAppeared(state: state, recalculate: {})
        await flushMainQueue()
        #expect(state.carbs == 60)

        await closeSheet()
        #expect(await finalReport() == .declined(on: .phone))
        #expect(session.requestID == nil)
    }

    @Test func routerResetBeforeTheSheetAppearsIsNotADecline() async {
        // On a cold launch, Main sends the router nil as it starts, before the sheet has appeared.
        await h.coordinator.receive(pizza(), via: .service)
        await opener.open(requestID: "r1").value
        await flushMainQueue()
        router.mainModalScreen.send(nil)
        await flushMainQueue()
        #expect(session.requestID == nil)
        #expect(session.gramFormatter == nil)
        await expectNoFinalReport()
        #expect(h.left.isEmpty)

        // The request keeps waiting, and opens again.
        #expect(h.coordinator.current.value?.request.id == "r1")
        await opener.open(requestID: "r1").value
        #expect(router.sent == [.treatmentView, nil, .treatmentView])
        #expect(session.requestID == "r1")
    }

    @Test func submittingNothingDeclines() async {
        // "Continue Without Treatment" with every field cleared logs nothing, so it's the same as closing.
        let state = await openSheet()
        state.carbs = 0
        state.fat = 0
        state.protein = 0
        submit(state, amount: 0)
        await closeSheet()
        #expect(await finalReport() == .declined(on: .phone))
    }

    @Test func carbsOnlyReportsLogged() async {
        let state = await openSheet()
        submit(state, amount: 0)
        await closeSheet()
        #expect(await finalReport() == .logged(shown: pizzaShown(units: 0)))
        #expect(deadlines.value.isEmpty)
    }

    // MARK: A pump bolus

    @Test func startedBolusReportsDelivering() async {
        let state = await openSheet()
        submit(state, amount: 2)
        await unlock(state)
        progress.send(0)
        await storeOwnBolus(2)
        await closeSheet()
        #expect(await finalReport() == .delivering(shown: pizzaShown(units: 2)))
        #expect(h.left == [LeftEvent(id: "r1", left: .claimed(.phone), source: "ChatGPT")])
        #expect(signalStops.value == 1)
        await flushMainQueue()
        #expect(center.added.isEmpty)
    }

    @Test func ownPumpEventReportsTheBolus() async {
        // A loop run closes the sheet while Face ID is up; the pump then takes what it can deliver.
        let state = await openSheet()
        submit(state, amount: d("2.17"))
        await closeSheet()
        await unlock(state)
        await storeOwnBolus(d("2.15"))
        #expect(await finalReport() == .delivering(shown: pizzaShown(units: d("2.15"))))
    }

    @Test func pumpUnitsAreReportedRounded() async {
        // The pump's event has no amount, so the units are what the pump gives for the bolus field.
        rounding.value = { amount in
            var value = amount * 10
            var rounded = Decimal()
            NSDecimalRound(&rounded, &value, 0, .down)
            return rounded / 10
        }
        let state = await openSheet()
        submit(state, amount: d("2.17"))
        await unlock(state)
        await storeOwnBolus(nil)
        await closeSheet()
        #expect(await finalReport() == .delivering(shown: pizzaShown(units: d("2.1"))))
    }

    @Test func loopCycleDuringFaceIDStillReportsTheBolus() async {
        // A loop cycle closes the sheet while Face ID is up; upstream then gives the bolus.
        let state = await openSheet()
        submit(state, amount: 2)
        await closeSheet()
        await expectNoFinalReport()
        #expect(session.requestID == nil)
        #expect(session.gramFormatter == nil)

        await unlock(state)
        progress.send(0)
        await storeOwnBolus(2)
        #expect(await finalReport() == .delivering(shown: pizzaShown(units: 2)))
    }

    @Test func progressAloneIsNotAStart() async {
        // The pump's progress says a bolus started, but no bolus of this sheet's is in the pump history.
        let state = await openSheet()
        submit(state, amount: 2)
        await unlock(state)
        progress.send(0)
        await settle()
        await closeSheet()
        await expectNoFinalReport()
    }

    @Test func smbProgressAfterUnlockIsNotThisBolus() async {
        // An SMB goes in after Face ID passed, and then this bolus fails.
        let state = await openSheet()
        submit(state, amount: 2)
        await unlock(state)
        progress.send(0)
        await storeSMB(d("0.3"))
        await closeSheet()
        await expectNoFinalReport()

        lastError.value = "Pump Error (Occlusion)."
        failures.send()
        #expect(await finalReport() == .failed(reason: "Pump Error (Occlusion).", carbsLogged: true))
    }

    @Test func otherBolusFailureAfterOwnEventDoesNotOverride() async {
        // This bolus is in the pump history; a failure broadcast after it, with the sheet open, is another's.
        let state = await openSheet()
        submit(state, amount: 2)
        await unlock(state)
        await storeOwnBolus(2)
        failures.send()
        await settle()
        await closeSheet()
        #expect(await finalReport() == .delivering(shown: pizzaShown(units: 2)))
    }

    @Test func failureAfterOwnEventWithTheSheetClosedDoesNotOverride() async {
        // The sheet closed first, so this bolus is reported as soon as its event is stored; a failure after it is
        // another's.
        let state = await openSheet()
        submit(state, amount: 2)
        await closeSheet()
        await unlock(state)
        await storeOwnBolus(2)
        #expect(await finalReport() == .delivering(shown: pizzaShown(units: 2)))
        failures.send()
        await settle()
        #expect(h.reporter.states == ["r1:pending", "r1:delivering"])
    }

    @Test func failureWithItsOwnEventStoredReportsTheBolus() async {
        // The pump stored this bolus before the failure broadcast was heard: the bolus is what the pump took.
        let state = await openSheet()
        submit(state, amount: 2)
        await unlock(state)
        history.store(AIRequestPumpBolusEvent(timestamp: h.now + 5, amount: 2, isSMB: false, isExternal: false))
        failures.send()
        await settle()
        await closeSheet()
        #expect(await finalReport() == .delivering(shown: pizzaShown(units: 2)))
    }

    @Test func missedFlagFlipStillReportsFromThePumpEvent() async {
        // The sheet's progress flag went by unseen, but this bolus is in the pump history.
        let state = await openSheet()
        submit(state, amount: 2)
        await storeOwnBolus(2)
        await closeSheet()
        #expect(await finalReport() == .delivering(shown: pizzaShown(units: 2)))
    }

    @Test func bolusesBeforeLogAreNotThisBolus() async {
        // A bolus stored before Log, by hand on the watch say, isn't this sheet's.
        let state = await openSheet()
        submit(state, amount: 2)
        await unlock(state)
        await storeOwnBolus(2, after: -30)
        await closeSheet()
        await expectNoFinalReport()
    }

    @Test func failedBolusReportsFailedWithCarbs() async {
        let state = await openSheet()
        submit(state, amount: 2)
        await unlock(state)
        lastError.value = "Pump Error (Occlusion)."
        failures.send()
        await settle()
        await closeSheet()
        #expect(await finalReport() == .failed(reason: "Pump Error (Occlusion).", carbsLogged: true))
    }

    @Test func failedBolusWithoutAnErrorSaysBolusFailed() async {
        let state = await openSheet()
        submit(state, amount: 2)
        await unlock(state)
        failures.send()
        await settle()
        await closeSheet()
        #expect(await finalReport() == .failed(reason: "Bolus failed", carbsLogged: true))
    }

    @Test func unlockStaysPassedOnceSeen() async {
        // The progress flag goes back to false once the loop has run; Face ID still passed, so the failure counts.
        let state = await openSheet()
        submit(state, amount: 2)
        await unlock(state)
        state.isAwaitingDeterminationResult = false
        await flushMainQueue()
        failures.send()
        await settle()
        await closeSheet()
        #expect(await finalReport() == .failed(reason: "Bolus failed", carbsLogged: true))
    }

    @Test func faceIDCancelReportsNotStarted() async {
        // An earlier bolus left the progress at 0; it isn't this one starting.
        progress.send(0)
        let state = await openSheet()
        submit(state, amount: 2)
        await failFaceID(state)
        await closeSheet()
        #expect(await finalReport() == .failed(reason: "The bolus wasn't started", carbsLogged: true))
    }

    @Test func smbDuringFaceIDCancelIsNotABolus() async {
        let state = await openSheet()
        submit(state, amount: 2)
        // An SMB starts while Face ID is up, before it passes.
        progress.send(0)
        await storeSMB(d("0.3"))
        await failFaceID(state)
        await closeSheet()
        #expect(await finalReport() == .failed(reason: "The bolus wasn't started", carbsLogged: true))
    }

    @Test func unknownOutcomeSendsNoReport() async {
        // Face ID passed, but neither this bolus's event nor a failure is heard.
        let state = await openSheet()
        submit(state, amount: 2)
        #expect(deadlines.value == [120])
        await unlock(state)
        await closeSheet()
        await expectNoFinalReport()

        // Two minutes pass: nothing is reported, and a late event changes nothing.
        deadline.send()
        await settle()
        await storeOwnBolus(2)
        await expectNoFinalReport()
        #expect(signalStops.value == 1)
    }

    @Test func deadlineFindsAnEventTheUpdatesMissed() async {
        // The pump history was stored without its update reaching the session.
        let state = await openSheet()
        submit(state, amount: 2)
        await unlock(state)
        await closeSheet()
        history.store(
            AIRequestPumpBolusEvent(timestamp: h.now + 5, amount: 2, isSMB: false, isExternal: false),
            sendingUpdate: false
        )
        deadline.send()
        #expect(await finalReport() == .delivering(shown: pizzaShown(units: 2)))
    }

    // MARK: External insulin

    @Test func externalAfterUnlockIsLogged() async {
        let state = await openSheet()
        submit(state, amount: 3, external: true)
        await unlock(state)
        history.store(AIRequestPumpBolusEvent(timestamp: h.now, amount: 3, isSMB: false, isExternal: true))
        await settle()
        await closeSheet()
        #expect(await finalReport() == .logged(shown: pizzaShown(units: 3)))
    }

    @Test func externalWaitsForItsPumpEvent() async {
        // Face ID passed and the sheet closed, but the external insulin isn't stored yet.
        let state = await openSheet()
        submit(state, amount: 3, external: true)
        await unlock(state)
        await closeSheet()
        await expectNoFinalReport()

        // Another external dose isn't this one.
        history.store(AIRequestPumpBolusEvent(timestamp: h.now, amount: 1, isSMB: false, isExternal: true))
        await settle()
        await expectNoFinalReport()

        history.store(AIRequestPumpBolusEvent(timestamp: h.now, amount: 3, isSMB: false, isExternal: true))
        #expect(await finalReport() == .logged(shown: pizzaShown(units: 3)))
    }

    @Test func backdatedExternalInsulinIsFound() async {
        // The wearer set the sheet's time 15 minutes back, so the external insulin is stored then.
        let state = await openSheet()
        state.amount = 3
        state.externalInsulin = true
        state.date = h.now - 15 * 60
        session.willSubmit(from: state)
        await unlock(state)
        history.store(AIRequestPumpBolusEvent(timestamp: h.now - 15 * 60, amount: 3, isSMB: false, isExternal: true))
        await settle()
        await closeSheet()
        #expect(await finalReport() == .logged(shown: pizzaShown(units: 3)))
    }

    @Test func externalWithoutItsEventSendsNoReport() async {
        // Face ID passed, but saving the external insulin failed: nothing was stored.
        let state = await openSheet()
        submit(state, amount: 3, external: true)
        await unlock(state)
        await closeSheet()
        deadline.send()
        await settle()
        await expectNoFinalReport()
    }

    @Test func externalWithFaceIDCancelIsNotLogged() async {
        let state = await openSheet()
        submit(state, amount: 3, external: true)
        await failFaceID(state)
        await closeSheet()
        #expect(await finalReport() == .failed(reason: "The bolus wasn't started", carbsLogged: true))
    }

    // MARK: Claims

    @Test func failedClaimDoesNothingMore() async {
        // The watch took the request before the session heard it leave.
        await h.coordinator.receive(pizza(), via: .service)
        let pending = h.coordinator.current.value!
        session.begin(pending)
        router.mainModalScreen.send(.treatmentView)
        let state = Treatments.StateModel()
        state.maxCarbs = 250
        session.sheetAppeared(state: state, recalculate: {})
        #expect(await h.coordinator.claim(id: "r1", on: .watch))
        submit(state, amount: 2)
        await unlock(state)
        await storeOwnBolus(2)
        await closeSheet()
        await expectNoFinalReport()
        #expect(h.left == [LeftEvent(id: "r1", left: .claimed(.watch), source: "ChatGPT")])
    }

    // MARK: Leaving

    @Test func watchClaimClosesTheSheet() async throws {
        await openSheet()
        #expect(await h.coordinator.claim(id: "r1", on: .watch))
        await flushMainQueue()
        await flushMainQueue()
        #expect(router.sent == [.treatmentView, nil])
        // The router closing the sheet ends the session.
        #expect(session.gramFormatter == nil)
        #expect(session.requestID == nil)

        let notice = try #require(center.added.first)
        #expect(center.added.count == 1)
        #expect(notice.content.title == "Logged on your watch")
        #expect(notice.content.body == "ChatGPT: pizza")
        #expect(notice.content.categoryIdentifier == "trio.request.notice")
        #expect(notice.identifier == "ai-request-result-r1")
        #expect(notice.trigger == nil)

        // The sheet goes, and reports nothing.
        session.sheetDisappeared()
        await expectNoFinalReport()
        #expect(h.left == [LeftEvent(id: "r1", left: .claimed(.watch), source: "ChatGPT")])
    }

    @Test func withdrawnRequestClosesTheSheetWithItsReason() async throws {
        await openSheet()
        await h.coordinator.withdraw(id: "r1", request: nil, via: .service)
        await flushMainQueue()
        #expect(router.sent == [.treatmentView, nil])
        #expect(try #require(center.added.first).content.title == "Canceled by ChatGPT")

        session.sheetDisappeared()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.reporter.states == ["r1:pending", "r1:withdrawn"])
    }

    @Test func noticeShowsAsABannerWithoutSound() {
        #expect(AIRequestIdentifiers.categoryNotice == "trio.request.notice")
        #expect(AIRequestHooks.presentationOptions(category: "trio.request.notice", userInfo: [:]) == [.banner, .list])
    }
}
