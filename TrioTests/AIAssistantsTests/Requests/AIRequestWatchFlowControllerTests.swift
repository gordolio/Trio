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

    /// Upstream's Confirm with `bolus` on its screen: the bolus send reads the screen's Double, and passes upstream's
    /// own `Decimal(bolusAmount)`.
    func confirm(bolus: Double) -> Bool {
        controller.screenBolus = { bolus }
        return controller.interceptBolus(Decimal(bolus))
    }

    var opens: [String] { sent.compactMap { $0[AIRequestIdentifiers.keyOpen] as? String } }
    var confirms: [AIRequestWatchConfirm] { decoded(AIRequestIdentifiers.keyConfirm) }
    var closes: [AIRequestWatchClose] { decoded(AIRequestIdentifiers.keyClose) }

    private func decoded<Message: Decodable>(_ key: String) -> [Message] {
        sent.compactMap { ($0[key] as? Data).flatMap { try? JSONDecoder().decode(Message.self, from: $0) } }
    }
}

@Suite("AI request watch flow controller") struct AIRequestWatchFlowControllerTests {
    /// A dose that's a whole number of 0.05 U steps in Double too, so the Confirm screen shows it as it is.
    private static let details = AIRequestWatchDetails(
        id: "r1",
        carbs: Decimal(string: "82.5")!,
        fat: 10,
        protein: 8,
        units: Decimal(string: "2.2")!,
        expiresAt: Date(timeIntervalSince1970: 1_792_000_300)
    )

    /// A request under half a gram of carbs: the watch's whole grams are 0, so Confirm has no carbs row.
    private static func subHalfGram(units: Decimal) -> AIRequestWatchDetails {
        AIRequestWatchDetails(
            id: "r1",
            carbs: Decimal(string: "0.4")!,
            fat: 9,
            protein: 6,
            units: units,
            expiresAt: details.expiresAt
        )
    }

    /// A harness whose controller shows `details` on the watch's screens, as the modifier puts them up, with the
    /// messages that opened it cleared.
    private static func active(_ details: AIRequestWatchDetails = details) -> FlowHarness {
        let harness = FlowHarness()
        harness.controller.open(id: details.id)
        harness.controller.receive(details)
        harness.controller.screensChanged(
            pathCount: Self.screenCount(for: harness.controller),
            carbs: harness.controller.requestedCarbs,
            bolus: Double(truncating: details.units as NSNumber)
        )
        harness.clearSent()
        return harness
    }

    /// How many screens the watch's modifier opens for the controller's request: the bolus screen and Confirm, and the
    /// carbs screen behind them when there are carbs.
    private static func screenCount(for controller: AIRequestWatchFlowController) -> Int {
        controller.requestedCarbs > 0 ? 3 : 2
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
        #expect(harness.controller.interceptBolus(Decimal(string: "2.2")!))
        harness.runTurn()

        #expect(harness.confirms == [AIRequestWatchConfirm(id: "r1", units: Decimal(string: "2.2")!, carbs: nil)])
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

    @Test("A request under half a gram, with no carbs row, logs its exact grams") func subHalfGramRequestLogsItsExactGrams() {
        // Confirm shows nothing but 0.00 U: it can still be confirmed.
        let harness = Self.active(Self.subHalfGram(units: 0))
        #expect(harness.controller.requestedCarbs == 0)

        #expect(harness.controller.interceptBolus(0))

        #expect(harness.confirms == [AIRequestWatchConfirm(id: "r1", units: 0, carbs: nil)])
        #expect(harness.controller.notice == nil)

        let withDose = Self.active(Self.subHalfGram(units: 1))
        #expect(withDose.controller.interceptBolus(1))
        #expect(withDose.confirms == [AIRequestWatchConfirm(id: "r1", units: 1, carbs: nil)])
    }

    @Test("A zeroed dose on a request under half a gram ends without answering") func zeroedSubHalfGramDoseEndsWithoutAnswering() {
        // Confirm showed 1.00 U and no carbs row; zeroed, it shows 0.00 U, and nothing is logged.
        let harness = Self.active(Self.subHalfGram(units: 1))

        #expect(harness.controller.interceptBolus(0))
        harness.runTurn()

        #expect(harness.sent.isEmpty)
        #expect(harness.controller.notice?.message == "Open the request again.")
        #expect(harness.controller.phase == .closing(id: "r1"))
    }

    @Test("The confirm sends the dose the Confirm screen shows, floored to the bolus increment") func confirmSendsTheDoseShown() {
        // Upstream's Confirm shows floor(bolusAmount / increment) * increment of its Double, and sends
        // Decimal(bolusAmount), which can round to another step.
        let cases: [(increment: String, bolus: Double, shown: String)] = [
            ("0.1", 2.15, "2.1"),
            ("0.05", 0.05 * 3, "0.15"),
            ("0.05", 0.8999999999999999, "0.85"),
            ("0.05", 0.9500000000000001, "0.95"),
            ("0.1", 1.7999999999999998, "1.7")
        ]
        for (increment, bolus, shown) in cases {
            let harness = Self.active()
            harness.controller.bolusIncrement = Decimal(string: increment)!
            // What Confirm shows, as it computes it.
            let inc = Double(increment)!
            #expect(String(format: "%.2f", floor(bolus / inc) * inc) == String(format: "%.2f", Double(shown)!))

            #expect(harness.confirm(bolus: bolus))

            let units = harness.confirms.map(\.units)
            #expect(units == [Decimal(string: shown)!], "\(bolus) at \(increment)")
            #expect(units.first?.description == shown, "\(bolus) at \(increment)")
        }
    }

    @Test("Trio's dose loads so that Confirm shows it, and sends it") func loadedDoseShowsAndSendsTheRequestsDose() {
        for (increment, dose) in [("0.05", "2.15"), ("0.1", "1.8")] {
            let harness = Self.active()
            harness.controller.bolusIncrement = Decimal(string: increment)!
            let bolus = harness.controller.loadedBolus(for: Decimal(string: dose)!)

            // In Double, 2.15 / 0.05 is 42.999…, and 1.8 / 0.1 is 17.999…: the loaded value floors to the dose itself.
            let inc = Double(increment)!
            #expect(String(format: "%.2f", floor(bolus / inc) * inc) == String(format: "%.2f", Double(dose)!))
            #expect(harness.confirm(bolus: bolus))
            #expect(harness.confirms.map(\.units) == [Decimal(string: dose)!], "\(dose) at \(increment)")
        }
        #expect(FlowHarness().controller.loadedBolus(for: 0) == 0)
    }

    @Test(
        "Values zeroed under the Confirm screen end the flow without logging or declining"
    ) func zeroedValuesEndTheFlowWithoutAnswering() throws {
        // Confirm with the values zeroed: the bolus send comes with 0 U and no carbs send.
        let confirmed = Self.active()
        #expect(confirmed.controller.interceptBolus(0))
        confirmed.runTurn()

        #expect(confirmed.sent.isEmpty)
        #expect(confirmed.controller.phase == .closing(id: "r1"))
        let notice = try #require(confirmed.controller.notice)
        #expect(notice.message == "Open the request again.")
        #expect(!notice.isSuccess)

        // The screens saw the values go to 0.
        let zeroed = Self.active()
        zeroed.controller.screensChanged(pathCount: 3, carbs: 0, bolus: 0)
        zeroed.runTurn()

        #expect(zeroed.sent.isEmpty)
        #expect(zeroed.controller.phase == .closing(id: "r1"))
        #expect(zeroed.controller.notice?.message == "Open the request again.")
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

        harness.controller.screensChanged(pathCount: 2, carbs: 0, bolus: 0)
        #expect(harness.controller.phase == .active(empty))

        #expect(harness.controller.interceptBolus(0))
        #expect(harness.confirms == [AIRequestWatchConfirm(id: "r1", units: 0, carbs: nil)])
        #expect(harness.controller.notice == nil)
    }

    @Test("Zeroing after Log Carbs doesn't stop its confirm") func zeroingAfterLogCarbsStillConfirms() {
        let harness = Self.active()

        #expect(harness.controller.interceptCarbs(83))
        // "No Bolus, Log Carbs" sets the watch's carbs to 0 after its send.
        harness.controller.screensChanged(pathCount: 3, carbs: 0, bolus: 0)
        harness.controller.screensChanged(pathCount: 0, carbs: 0, bolus: 0)
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
        #expect(harness.controller.phase == .closing(id: "r1"))
        let notice = try #require(harness.controller.notice)
        #expect(notice.message == "Open this request on your iPhone.")
    }

    // MARK: Sends after a flow ends

    @Test(
        "Sends after the phone ended the request are dropped until its screens close"
    ) func sendsAfterEndedAreSwallowedUntilTheScreensClose() {
        let harness = Self.active()
        harness.controller.ended(AIRequestEnded(id: "r1", headline: "Logged on your iPhone", isSuccess: true))
        #expect(harness.controller.phase == .closing(id: "r1"))

        // Upstream's Confirm sends 0.1 s after the crown, even after the screen went: none of it reaches the phone.
        #expect(harness.controller.interceptCarbs(83))
        #expect(harness.controller.interceptBolus(Decimal(string: "2.2")!))
        harness.runTurn()
        #expect(harness.sent.isEmpty)
        #expect(harness.intercepts == 0)

        // Back on the main screen, upstream's sends are its own again, and nothing was declined.
        harness.controller.screensChanged(pathCount: 0, carbs: 0, bolus: 0)
        #expect(harness.controller.phase == .idle)
        #expect(harness.sent.isEmpty)
        #expect(!harness.controller.interceptCarbs(83))
        #expect(!harness.controller.interceptBolus(2))
    }

    @Test("Sends after the values were zeroed are dropped") func sendsAfterZeroedValuesAreSwallowed() {
        let harness = Self.active()
        harness.controller.screensChanged(pathCount: 3, carbs: 0, bolus: 0)
        #expect(harness.controller.phase == .closing(id: "r1"))

        #expect(harness.controller.interceptCarbs(83))
        #expect(harness.controller.interceptBolus(2))
        harness.runTurn()

        #expect(harness.sent.isEmpty)
    }

    @Test(
        "Sends after the watch's confirm are dropped until its screens close"
    ) func sendsAfterTheConfirmAreSwallowedUntilTheScreensClose() {
        let harness = Self.active()
        #expect(harness.controller.interceptBolus(2))
        harness.clearSent()

        #expect(harness.controller.interceptBolus(0))
        harness.runTurn()
        #expect(harness.sent.isEmpty)

        harness.controller.screensChanged(pathCount: 0, carbs: 0, bolus: 0)
        #expect(!harness.controller.interceptBolus(2))
        #expect(harness.sent.isEmpty)
    }

    @Test(
        "Opening another request over an active one sends nothing for the first"
    ) func openingAnotherRequestOverAnActiveOneSendsNothingForTheFirst() {
        let harness = Self.active()

        harness.controller.open(id: "r2")
        // The modifier takes the first request's screens down and zeroes their values.
        harness.controller.screensChanged(pathCount: 0, carbs: 0, bolus: 0)
        harness.clearSent()
        // The first Confirm's send, 0.1 s after its crown.
        #expect(harness.controller.interceptCarbs(83))
        #expect(harness.controller.interceptBolus(0))
        harness.runTurn()
        #expect(harness.sent.isEmpty)

        // The second request's details come before its screens are up: still nothing.
        let second = AIRequestWatchDetails(
            id: "r2",
            carbs: 30,
            fat: 0,
            protein: 0,
            units: 1,
            expiresAt: Self.details.expiresAt
        )
        harness.controller.receive(second)
        #expect(harness.controller.interceptBolus(Decimal(string: "2.2")!))
        harness.runTurn()
        #expect(harness.sent.isEmpty)
        #expect(harness.controller.phase == .active(second))

        // Once its screens are up, the sends are the second request's own.
        harness.controller.screensChanged(pathCount: 3, carbs: 30, bolus: 1)
        #expect(harness.controller.interceptBolus(1))
        #expect(harness.confirms == [AIRequestWatchConfirm(id: "r2", units: 1, carbs: 0)])
    }

    // MARK: Another flow over the request's screens

    @Test(
        "A manual flow started over the request's screens declines it, and its sends are upstream's own"
    ) func aManualFlowOverTheRequestDeclinesAndLetsItsSendsThrough() {
        // The treatment menu covered the main screen as the request opened, so its screens went up underneath. The
        // wearer picks a meal from the menu: its carbs screen goes on top of the request's three.
        let harness = Self.active()
        harness.controller.screensChanged(pathCount: 4, carbs: 83, bolus: 2.2)

        #expect(harness.closes == [AIRequestWatchClose(id: "r1", dismissed: false)])
        #expect(harness.controller.phase == .idle)
        #expect(harness.controller.notice == nil)
        harness.clearSent()

        // The manual flow's Confirm: its sends go to the phone as upstream's own, not as the request's confirm.
        harness.controller.screensChanged(pathCount: 6, carbs: 40, bolus: 1)
        #expect(!harness.controller.interceptCarbs(40))
        #expect(!harness.controller.interceptBolus(1))
        harness.runTurn()
        #expect(harness.sent.isEmpty)
        #expect(harness.intercepts == 0)

        // Back on the main screen, nothing more is declined, and upstream's sends stay its own.
        harness.controller.screensChanged(pathCount: 0, carbs: 0, bolus: 0)
        #expect(harness.sent.isEmpty)
        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.interceptBolus(2))

        // A request with no carbs opens two screens, so a third is another flow's.
        let noCarbs = Self.active(Self.subHalfGram(units: 1))
        noCarbs.controller.screensChanged(pathCount: 3, carbs: 0, bolus: 1)
        #expect(noCarbs.closes == [AIRequestWatchClose(id: "r1", dismissed: false)])
        #expect(noCarbs.controller.phase == .idle)

        // Upstream's acknowledgement screen, which goes on top after the request's own confirm, isn't another flow.
        let confirmed = Self.active()
        #expect(confirmed.controller.interceptBolus(2))
        confirmed.clearSent()
        confirmed.controller.screensChanged(pathCount: 4, carbs: 0, bolus: 0)
        #expect(confirmed.sent.isEmpty)
        #expect(confirmed.controller.phase == .confirmed(id: "r1"))
    }

    // MARK: Leaving

    @Test("Leaving the screens declines the request") func leavingTheFlowDeclines() {
        let harness = Self.active()

        harness.controller.screensChanged(pathCount: 0, carbs: 83, bolus: 2.2)

        #expect(harness.closes == [AIRequestWatchClose(id: "r1", dismissed: false)])
        #expect(harness.controller.phase == .idle)
        #expect(harness.controller.notice == nil)

        // Once confirmed, going back to the main screen declines nothing.
        let confirmed = Self.active()
        _ = confirmed.controller.interceptBolus(2)
        confirmed.clearSent()
        confirmed.controller.screensChanged(pathCount: 0, carbs: 0, bolus: 0)
        #expect(confirmed.sent.isEmpty)
    }

    @Test("Cancel empties the screens and zeroes their values at once, and declines") func cancelDeclinesBeforeZeroedNotice() {
        let harness = Self.active()

        harness.controller.screensChanged(pathCount: 0, carbs: 0, bolus: 0)

        #expect(harness.closes == [AIRequestWatchClose(id: "r1", dismissed: false)])
        #expect(harness.controller.phase == .idle)
        #expect(harness.controller.notice == nil)
    }

    @Test("An empty path before the screens went up declines nothing") func emptyPathBeforeTheScreensOpenDeclinesNothing() {
        let harness = FlowHarness()
        harness.controller.open(id: "r1")
        harness.controller.receive(Self.details)
        harness.clearSent()

        harness.controller.screensChanged(pathCount: 0, carbs: 0, bolus: 0)
        #expect(harness.sent.isEmpty)
        #expect(harness.controller.phase == .active(Self.details))

        harness.controller.screensChanged(pathCount: 3, carbs: 83, bolus: 2.2)
        harness.controller.screensChanged(pathCount: 0, carbs: 83, bolus: 2.2)
        #expect(harness.closes == [AIRequestWatchClose(id: "r1", dismissed: false)])
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
        #expect(harness.controller.phase == .closing(id: "r1"))
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
        harness.controller.screensChanged(pathCount: 3, carbs: 83, bolus: 2.2)
        _ = harness.controller.interceptBolus(2)
        harness.controller.screensChanged(pathCount: 0, carbs: 0, bolus: 0)
        harness.clearSent()
        #expect(!harness.controller.interceptCarbs(83))
        #expect(!harness.controller.interceptBolus(2))

        harness.runTurn()
        #expect(harness.sent.isEmpty)
        #expect(harness.intercepts == 1)
    }

    @Test("When the phone couldn't be reached, upstream's sends are its own") func interceptsNothingWhenUnreachable() {
        let harness = FlowHarness()
        harness.controller.open(id: "r1")
        harness.runWaits()
        #expect(harness.controller.phase == .unreachable(id: "r1"))
        harness.clearSent()

        #expect(!harness.controller.interceptCarbs(83))
        #expect(!harness.controller.interceptBolus(2))
        harness.runTurn()
        #expect(harness.sent.isEmpty)
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
