import Combine
import Foundation
import SwiftUI
import Testing
import UserNotifications

@testable import Trio

/// Trio's router, recording each screen sent to the main modal after it was made.
final class FakeRouter: Router {
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
    private let session: AIRequestTreatmentsSession
    private let opener: AIRequestTreatmentsOpener

    init() {
        let h = makeCoordinator()
        let router = FakeRouter()
        let center = FakeNotificationCenter()
        let progress = CurrentValueSubject<Decimal?, Never>(nil)
        let failures = PassthroughSubject<Void, Never>()
        let lastError = TestBox<String?>(nil)
        let session = AIRequestTreatmentsSession(
            coordinator: { h.coordinator },
            router: { router },
            notifications: { center },
            bolusSignals: {
                AIRequestBolusSignals(
                    progress: progress,
                    failures: failures.eraseToAnyPublisher(),
                    lastErrorText: { lastError.value }
                )
            }
        )
        self.h = h
        self.router = router
        self.center = center
        self.progress = progress
        self.failures = failures
        self.lastError = lastError
        self.session = session
        opener = AIRequestTreatmentsOpener(
            router: { router },
            coordinator: { h.coordinator },
            session: session,
            now: { h.now },
            isDue: { pending, now in await AIRequestPhoneBackup(center: center).isDue(pending, now: now) }
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
        let state = Treatments.StateModel()
        state.maxCarbs = 250
        session.sheetAppeared(state: state, recalculate: {})
        return state
    }

    /// Waits for the request's final report, after its pending one.
    private func finalReport(_ id: String = "r1") async -> AIRequestReport? {
        _ = await eventuallyTrue { h.reporter.reports(for: id).count >= 2 }
        let reports = h.reporter.reports(for: id)
        return reports.count >= 2 ? reports.last : nil
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
        #expect(formatter.string(from: 82.5) == "82.5")
        #expect(formatter.string(from: 82) == "82")
        #expect(formatter.string(from: d("82.25") as NSNumber) == "82.25")
        #expect(formatter.numberStyle == .decimal)
        #expect(formatter.maximumIntegerDigits == 3)
        #expect(formatter.maximumFractionDigits == 2)
        #expect(formatter.minimumFractionDigits == 0)
    }

    @Test func noFormatterWithoutARequest() async {
        #expect(session.gramFormatter == nil)
        await openSheet()
        #expect(session.gramFormatter != nil)
        session.sheetDisappeared()
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
        let state = Treatments.StateModel()
        state.maxCarbs = 250
        state.carbs = 40
        session.sheetAppeared(state: state, recalculate: {})
        #expect(state.carbs == 40)
        #expect(state.note.isEmpty)
        session.willSubmit(carbs: 40, fat: 0, protein: 0, amount: 1, isExternal: false)
        session.sheetDisappeared()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.reporter.states == ["r1:pending"])
        #expect(h.left.isEmpty)
        #expect(router.sent.isEmpty)
    }

    // MARK: Ending

    @Test func closingWithoutSubmitDeclines() async {
        await openSheet()
        session.sheetDisappeared()
        #expect(await finalReport() == .declined(on: .phone))
        #expect(session.requestID == nil)
        // The wearer closed it: no notice.
        await flushMainQueue()
        #expect(center.added.isEmpty)
    }

    @Test func startedBolusReportsDelivering() async {
        await openSheet()
        session.willSubmit(carbs: d("82.5"), fat: 10, protein: 5, amount: 2, isExternal: false)
        progress.send(0)
        await flushMainQueue()
        session.sheetDisappeared()
        #expect(await finalReport() == .delivering(shown: pizzaShown(units: 2)))
        #expect(h.left == [LeftEvent(id: "r1", left: .claimed(.phone), source: "ChatGPT")])
        await flushMainQueue()
        #expect(center.added.isEmpty)
    }

    @Test func failedBolusReportsFailedWithCarbs() async {
        await openSheet()
        session.willSubmit(carbs: d("82.5"), fat: 10, protein: 5, amount: 2, isExternal: false)
        lastError.value = "Pump Error (Occlusion)."
        failures.send()
        await flushMainQueue()
        session.sheetDisappeared()
        #expect(await finalReport() == .failed(reason: "Pump Error (Occlusion).", carbsLogged: true))
    }

    @Test func failedBolusWithoutAnErrorSaysBolusFailed() async {
        await openSheet()
        session.willSubmit(carbs: d("82.5"), fat: 10, protein: 5, amount: 2, isExternal: false)
        failures.send()
        await flushMainQueue()
        session.sheetDisappeared()
        #expect(await finalReport() == .failed(reason: "Bolus failed", carbsLogged: true))
    }

    @Test func faceIDCancelReportsNotStarted() async {
        // An earlier bolus left the progress at 0; it isn't this one starting.
        progress.send(0)
        await openSheet()
        session.willSubmit(carbs: d("82.5"), fat: 10, protein: 5, amount: 2, isExternal: false)
        await flushMainQueue()
        session.sheetDisappeared()
        #expect(await finalReport() == .failed(reason: "The bolus wasn't started", carbsLogged: true))
    }

    @Test func carbsOnlyReportsLogged() async {
        await openSheet()
        session.willSubmit(carbs: d("82.5"), fat: 10, protein: 5, amount: 0, isExternal: false)
        session.sheetDisappeared()
        #expect(await finalReport() == .logged(shown: pizzaShown(units: 0)))
    }

    @Test func externalInsulinReportsLogged() async {
        await openSheet()
        session.willSubmit(carbs: d("82.5"), fat: 10, protein: 5, amount: 3, isExternal: true)
        session.sheetDisappeared()
        #expect(await finalReport() == .logged(shown: pizzaShown(units: 3)))
    }

    @Test func submittingNothingDeclines() async {
        // "Continue Without Treatment" with every field cleared logs nothing, so it's the same as closing.
        await openSheet()
        session.willSubmit(carbs: 0, fat: 0, protein: 0, amount: 0, isExternal: false)
        session.sheetDisappeared()
        #expect(await finalReport() == .declined(on: .phone))
    }

    @Test func failedClaimDoesNothingMore() async {
        // The watch took the request before the session heard it leave.
        await h.coordinator.receive(pizza(), via: .service)
        let pending = h.coordinator.current.value!
        session.begin(pending)
        let state = Treatments.StateModel()
        state.maxCarbs = 250
        session.sheetAppeared(state: state, recalculate: {})
        #expect(await h.coordinator.claim(id: "r1", on: .watch))
        session.willSubmit(carbs: d("82.5"), fat: 10, protein: 5, amount: 2, isExternal: false)
        progress.send(0)
        await flushMainQueue()
        session.sheetDisappeared()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.reporter.states == ["r1:pending"])
        #expect(h.left == [LeftEvent(id: "r1", left: .claimed(.watch), source: "ChatGPT")])
    }

    // MARK: Leaving

    @Test func watchClaimClosesTheSheet() async throws {
        await openSheet()
        #expect(await h.coordinator.claim(id: "r1", on: .watch))
        await flushMainQueue()
        #expect(router.sent == [.treatmentView, nil])

        let notice = try #require(center.added.first)
        #expect(center.added.count == 1)
        #expect(notice.content.title == "Logged on your watch")
        #expect(notice.content.body == "ChatGPT: pizza")
        #expect(notice.content.categoryIdentifier == "trio.request.notice")
        #expect(notice.identifier == "ai-request-result-r1")
        #expect(notice.trigger == nil)

        // The sheet goes, and reports nothing.
        session.sheetDisappeared()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.reporter.states == ["r1:pending"])
        #expect(h.left == [LeftEvent(id: "r1", left: .claimed(.watch), source: "ChatGPT")])
        #expect(session.gramFormatter == nil)
        #expect(session.requestID == nil)
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
