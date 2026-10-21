import Foundation
import Testing
import UserNotifications

@testable import Trio

/// A controller whose sends, main-queue turns and waits are recorded, and run only when a test says.
private final class FlowHarness {
    private(set) var sent: [[String: Any]] = []
    private var turns: [() -> Void] = []
    private(set) var waits: [(seconds: TimeInterval, work: () -> Void)] = []
    private(set) var intercepts = 0

    private(set) lazy var controller: AIRequestWatchFlowController = {
        let controller = AIRequestWatchFlowController(
            send: { [unowned self] in self.sent.append($0) },
            nextTurn: { [unowned self] in self.turns.append($0) },
            wait: { [unowned self] in self.waits.append(($0, $1)) },
            locale: Locale(identifier: "en_US")
        )
        controller.onIntercepted = { [unowned self] in self.intercepts += 1 }
        return controller
    }()

    /// Runs what was left for the next main-queue turn.
    func runTurn() {
        let due = turns
        turns = []
        due.forEach { $0() }
    }

    /// Runs the waits that are due.
    func runWaits() {
        let due = waits
        waits = []
        due.forEach { $0.work() }
    }

    func clearSent() {
        sent = []
    }

    var opens: [String] { sent.compactMap { $0[AIRequestIdentifiers.keyOpen] as? String } }
    var confirms: [AIRequestWatchConfirm] { decoded(AIRequestIdentifiers.keyConfirm) }
    var closes: [AIRequestWatchClose] { decoded(AIRequestIdentifiers.keyClose) }

    private func decoded<Message: Decodable>(_ key: String) -> [Message] {
        sent.compactMap { ($0[key] as? Data).flatMap { try? JSONDecoder().decode(Message.self, from: $0) } }
    }
}

@Suite("AI request watch flow controller") struct AIRequestWatchFlowControllerTests {
    private static let details = AIRequestWatchDetails(
        id: "r1",
        carbs: Decimal(string: "82.5")!,
        fat: 10,
        protein: 8,
        units: Decimal(string: "2.15")!,
        expiresAt: Date(timeIntervalSince1970: 1_792_000_300)
    )

    /// A harness whose controller shows `details`, with the messages that opened it cleared.
    private static func active(_ details: AIRequestWatchDetails = details) -> FlowHarness {
        let harness = FlowHarness()
        harness.controller.open(id: details.id)
        harness.controller.receive(details)
        harness.clearSent()
        return harness
    }

    // MARK: Opening

    @Test("Review asks the phone for the request, and waits for its details") func openSendsTheOpenMessage() {
        let harness = FlowHarness()
        harness.controller.open(id: "r1")

        #expect(harness.opens == ["r1"])
        #expect(harness.sent.count == 1)
        #expect(harness.controller.phase == .loading(id: "r1"))

        harness.controller.receive(Self.details)
        #expect(harness.controller.phase == .active(Self.details))
        #expect(harness.controller.requestedCarbs == 83)
    }

    @Test(
        "Without the phone's details in 5 s, the watch says to open the request on the iPhone"
    ) func noDetailsInFiveSecondsIsUnreachable() throws {
        let harness = FlowHarness()
        harness.controller.open(id: "r1")
        #expect(harness.waits.map(\.seconds) == [5])
        #expect(harness.controller.notice == nil)

        harness.runWaits()

        #expect(harness.controller.phase == .unreachable(id: "r1"))
        let notice = try #require(harness.controller.notice)
        #expect(notice.message == "Open this request on your iPhone.")
        #expect(!notice.isSuccess)
        // Details that come after the watch gave up don't open the screens.
        harness.controller.receive(Self.details)
        #expect(harness.controller.phase == .unreachable(id: "r1"))
    }

    @Test("Details in time aren't undone by the wait") func detailsInTimeOutlastTheWait() {
        let harness = FlowHarness()
        harness.controller.open(id: "r1")
        harness.controller.receive(Self.details)

        harness.runWaits()

        #expect(harness.controller.phase == .active(Self.details))
        #expect(harness.controller.notice == nil)
    }

    @Test("Details for another request are ignored") func detailsForAnotherRequestAreIgnored() {
        let harness = FlowHarness()
        harness.controller.receive(Self.details)
        #expect(harness.controller.phase == .idle)

        harness.controller.open(id: "r2")
        harness.controller.receive(Self.details)
        #expect(harness.controller.phase == .loading(id: "r2"))
    }

    @Test("A request whose expiry passed while a screen held it still opens and stays open") func pastExpiryNeverClosesTheFlow() {
        let held = AIRequestWatchDetails(
            id: "r1",
            carbs: 40,
            fat: 0,
            protein: 0,
            units: 1,
            expiresAt: Date(timeIntervalSince1970: 0)
        )
        let harness = Self.active(held)
        harness.runWaits()
        harness.runTurn()

        #expect(harness.controller.phase == .active(held))
        #expect(harness.controller.interceptBolus(1))
        #expect(harness.confirms == [AIRequestWatchConfirm(id: "r1", units: 1, carbs: 0)])
    }

    // MARK: The Confirm screen's carbs

    @Test(
        "The Confirm screen shows the request's exact grams only while the carbs are unchanged"
    ) func carbsTextShowsExactGramsOnlyWhileUnchanged() {
        let harness = FlowHarness()
        #expect(harness.controller.carbsText(forAmount: 83) == nil)

        harness.controller.open(id: "r1")
        harness.controller.receive(Self.details)

        // 82.5 rounds to 83, the whole grams the watch's screens hold.
        #expect(harness.controller.carbsText(forAmount: 83) == "82.5 g")
        #expect(harness.controller.carbsText(forAmount: 80) == nil)

        let whole = Self.active(AIRequestWatchDetails(
            id: "r2",
            carbs: Decimal(string: "35.00")!,
            fat: 0,
            protein: 0,
            units: 1,
            expiresAt: Self.details.expiresAt
        ))
        #expect(whole.controller.carbsText(forAmount: 35) == "35 g")
    }

    // MARK: Confirming

    @Test(
        "Unchanged carbs log the request's exact grams, in one confirm with the bolus"
    ) func unchangedCarbsLogTheRequestsExactGrams() {
        let harness = Self.active()

        #expect(harness.controller.interceptCarbs(83))
        #expect(harness.controller.interceptBolus(Decimal(string: "2.15")!))
        harness.runTurn()

        #expect(harness.confirms == [AIRequestWatchConfirm(id: "r1", units: Decimal(string: "2.15")!, carbs: nil)])
        #expect(harness.sent.count == 1)
        #expect(harness.controller.phase == .confirmed(id: "r1"))
        #expect(harness.intercepts == 2)
    }

    @Test("Carbs changed on the watch log the watch's whole grams") func changedCarbsLogTheWatchsWholeGrams() {
        let harness = Self.active()

        #expect(harness.controller.interceptCarbs(80))
        #expect(harness.controller.interceptBolus(2))
        harness.runTurn()

        #expect(harness.confirms == [AIRequestWatchConfirm(id: "r1", units: 2, carbs: 80)])
        #expect(harness.sent.count == 1)
    }

    @Test("Log Carbs alone sends a zero-unit confirm on the next main-queue turn") func carbsOnlySendsAZeroUnitConfirm() {
        let harness = Self.active()

        #expect(harness.controller.interceptCarbs(83))
        // Upstream's Confirm calls the bolus send right after the carbs send, so nothing goes before the next turn.
        #expect(harness.sent.isEmpty)
        harness.runTurn()

        #expect(harness.confirms == [AIRequestWatchConfirm(id: "r1", units: 0, carbs: nil)])
        #expect(harness.controller.phase == .confirmed(id: "r1"))
    }

    @Test("A bolus without carbs logs zero carbs") func bolusWithCarbsSetToZeroSendsZeroCarbs() {
        let harness = Self.active()

        #expect(harness.controller.interceptBolus(Decimal(string: "1.5")!))
        harness.runTurn()

        #expect(harness.confirms == [AIRequestWatchConfirm(id: "r1", units: Decimal(string: "1.5")!, carbs: 0)])
    }

    @Test(
        "Values zeroed under the Confirm screen end the flow without logging or declining"
    ) func zeroedValuesEndTheFlowWithoutAnswering() throws {
        // Confirm with the values zeroed: the bolus send comes with 0 U and no carbs send.
        let confirmed = Self.active()
        #expect(confirmed.controller.interceptBolus(0))
        confirmed.runTurn()

        #expect(confirmed.sent.isEmpty)
        #expect(confirmed.controller.phase == .idle)
        let notice = try #require(confirmed.controller.notice)
        #expect(notice.message == "Open the request again.")
        #expect(!notice.isSuccess)

        // The screen saw the values go to 0.
        let zeroed = Self.active()
        zeroed.controller.valuesZeroed()
        zeroed.runTurn()

        #expect(zeroed.sent.isEmpty)
        #expect(zeroed.controller.phase == .idle)
        #expect(zeroed.controller.notice?.message == "Open the request again.")
        #expect(!zeroed.controller.interceptBolus(2))
    }

    @Test("A request with no carbs and no dose still confirms as it was shown") func nothingToZeroStillConfirms() {
        let empty = AIRequestWatchDetails(
            id: "r1",
            carbs: 0,
            fat: 12,
            protein: 20,
            units: 0,
            expiresAt: Self.details.expiresAt
        )
        let harness = Self.active(empty)

        harness.controller.valuesZeroed()
        #expect(harness.controller.phase == .active(empty))

        #expect(harness.controller.interceptBolus(0))
        #expect(harness.confirms == [AIRequestWatchConfirm(id: "r1", units: 0, carbs: 0)])
        #expect(harness.controller.notice == nil)
    }

    @Test("Zeroing after Log Carbs doesn't stop its confirm") func zeroingAfterLogCarbsStillConfirms() {
        let harness = Self.active()

        #expect(harness.controller.interceptCarbs(83))
        // "No Bolus, Log Carbs" sets the watch's carbs to 0 after its send.
        harness.controller.valuesZeroed()
        harness.controller.pathEmptied()
        harness.runTurn()

        #expect(harness.confirms == [AIRequestWatchConfirm(id: "r1", units: 0, carbs: nil)])
        #expect(harness.closes.isEmpty)
    }

    @Test(
        "A confirm that didn't reach the phone says to open the request on the iPhone"
    ) func undeliveredConfirmSaysToOpenOnTheIPhone() throws {
        let harness = Self.active()
        #expect(harness.controller.interceptBolus(2))

        harness.controller.confirmNotDelivered(id: "other")
        #expect(harness.controller.phase == .confirmed(id: "r1"))

        harness.controller.confirmNotDelivered(id: "r1")
        #expect(harness.controller.phase == .idle)
        let notice = try #require(harness.controller.notice)
        #expect(notice.message == "Open this request on your iPhone.")
    }

    // MARK: Leaving

    @Test("Leaving the screens declines the request") func leavingTheFlowDeclines() {
        let harness = Self.active()

        harness.controller.pathEmptied()

        #expect(harness.closes == [AIRequestWatchClose(id: "r1", dismissed: false)])
        #expect(harness.controller.phase == .idle)
        #expect(harness.controller.notice == nil)

        // Once confirmed, going back to the main screen declines nothing.
        let confirmed = Self.active()
        _ = confirmed.controller.interceptBolus(2)
        confirmed.clearSent()
        confirmed.controller.pathEmptied()
        #expect(confirmed.sent.isEmpty)
    }

    @Test("Swiping the notification away declines the request as dismissed") func dismissingTheNotificationDeclines() {
        let harness = FlowHarness()

        harness.controller.notificationDismissed(id: "r1")

        #expect(harness.closes == [AIRequestWatchClose(id: "r1", dismissed: true)])
    }

    @Test("The phone's ending closes the open flow of its request only") func endedClosesTheActiveFlowOnly() throws {
        let logged = AIRequestEnded(id: "r1", headline: "Logged on your iPhone", isSuccess: true)

        let idle = FlowHarness()
        idle.controller.ended(logged)
        #expect(idle.controller.notice == nil)

        let harness = Self.active()
        harness.controller.ended(AIRequestEnded(id: "r2", headline: "Expired", isSuccess: false))
        #expect(harness.controller.phase == .active(Self.details))
        #expect(harness.controller.notice == nil)

        harness.controller.ended(logged)
        #expect(harness.controller.phase == .idle)
        let notice = try #require(harness.controller.notice)
        #expect(notice.message == "Logged on your iPhone")
        #expect(notice.isSuccess)
        #expect(harness.sent.isEmpty)

        // After the watch's own confirm, the phone's acknowledgement is the one result shown.
        let confirmed = Self.active()
        _ = confirmed.controller.interceptBolus(2)
        confirmed.controller.ended(logged)
        #expect(confirmed.controller.phase == .confirmed(id: "r1"))
        #expect(confirmed.controller.notice == nil)
    }

    @Test("An ending while the watch waits for the details shows it") func endedWhileLoadingShowsIt() {
        let harness = FlowHarness()
        harness.controller.open(id: "r1")

        harness.controller.ended(AIRequestEnded(id: "r1", headline: "Expired", isSuccess: false))
        harness.runWaits()

        #expect(harness.controller.phase == .idle)
        #expect(harness.controller.notice?.message == "Expired")
    }

    @Test("Without an open request, upstream's sends go to the phone as they always do") func interceptsNothingWhenIdle() {
        let harness = FlowHarness()
        #expect(!harness.controller.interceptCarbs(83))
        #expect(!harness.controller.interceptBolus(2))

        harness.controller.open(id: "r1")
        harness.clearSent()
        #expect(!harness.controller.interceptCarbs(83))
        #expect(!harness.controller.interceptBolus(2))

        harness.controller.receive(Self.details)
        _ = harness.controller.interceptBolus(2)
        harness.clearSent()
        #expect(!harness.controller.interceptCarbs(83))
        #expect(!harness.controller.interceptBolus(2))

        harness.runTurn()
        #expect(harness.sent.isEmpty)
        #expect(harness.intercepts == 1)
    }

    // MARK: Notifications

    @Test(
        "The watch registers the Review category, which reaches the app when swiped away, and the iPhone's backup"
    ) func watchRegistersTheReviewAndPhoneCategories() throws {
        let categories = AIRequestIdentifiers.watchCategories()
        #expect(Set(categories.map(\.identifier)) == ["trio.request.review", "trio.request.phone"])

        let review = try #require(categories.first { $0.identifier == "trio.request.review" })
        #expect(review.actions.map(\.identifier) == ["AIRequest.review"])
        #expect(review.actions[0].options.contains(.foreground))
        #expect(review.options.contains(.customDismissAction))

        let phone = try #require(categories.first { $0.identifier == "trio.request.phone" })
        #expect(phone.actions.isEmpty)
    }
}
