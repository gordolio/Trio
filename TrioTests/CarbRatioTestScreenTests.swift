import Combine
import Foundation
import SwiftUI
import Testing

@testable import Trio

// The carb ratio test's screens, the Treatments prefill its Dose step uses, and the hub's carb ratio row.
//
// The worked example: 10 Dex4 tablets (40 g) at a carb ratio of 10 g/U and an ISF of 50 mg/dL/U, so the docs' dose is
// 4 U, the insulin on board line 4 × 1 ÷ 11 = 0.36 U and the carbs on board line 40 × 1 ÷ 11 = 3.6 g. With 4 U acting
// from 110 mg/dL, the accurate end readings are 92 to 132 (110 − 18.18 to 110 + 22.22).

private func dec(_ string: String) -> Decimal { Decimal(string: string)! }

private let minute: TimeInterval = 60

/// Three readings at `glucose`, the newest a minute old, with a flat arrow on the newest.
private func readings(_ glucose: Int) -> [BasalTestReading] {
    [1, 6, 11].map {
        BasalTestReading(date: Date().addingTimeInterval(-Double($0) * minute), glucose: glucose, direction: .flat)
    }
}

/// What the screen reads with nothing in the way of Begin: CGM and pump connected, the pump delivering, nothing on board.
private func screenData(_ readings: [BasalTestReading], iob: Decimal? = 0, cob: Decimal? = 0) -> CarbRatioTest.StateModel
    .ScreenData
{
    CarbRatioTest.StateModel.ScreenData(
        readings: readings,
        iob: iob,
        cob: cob,
        doseCOB: cob,
        hasActiveAdjustment: false,
        hasPumpSetTempBasal: false,
        pumpDelivery: .delivering,
        hasDevices: true,
        trendDirection: readings.first?.direction
    )
}

/// CR 10 g/U, ISF 50 mg/dL/U, target 100 mg/dL, Max Bolus 10 U, Max Carbs 250 g.
private func settings(
    carbRatio: Decimal? = 10,
    maxBolus: Decimal? = 10,
    maxCarbs: Decimal? = 250
) -> CarbRatioTest.StateModel.ScreenSettings {
    CarbRatioTest.StateModel.ScreenSettings(carbRatio: carbRatio, isf: 50, target: 100, maxBolus: maxBolus, maxCarbs: maxCarbs)
}

/// Begun 30 minutes ago from Closed Loop with 10 Dex4 tablets at CR 10 and ISF 50, with its session, in `phase`.
private func carbRatioTest(_ phase: CarbRatioTestPhase, handling: ISFTestIOBHandling? = nil) -> CarbRatioTestState {
    var test = CarbRatioTestState(
        phase: phase,
        startedAt: Date().addingTimeInterval(-30 * minute),
        previousMode: .closed,
        carbRatio: 10,
        isf: 50,
        target: 100,
        bolusIncrement: dec("0.05"),
        length: 4 * 3600,
        tabletBrand: GlucoseTabletBrand.dex4.rawValue,
        tabletCount: 10,
        tabletCarbs: 40,
        expectedDose: 4,
        iobLine: dec("0.36"),
        cobLine: dec("3.6")
    )
    test.sessionID = UUID()
    test.iobHandling = handling
    if phase != .settling {
        test.settledAt = Date().addingTimeInterval(-10 * minute)
    }
    return test
}

/// A carb ratio runner that keeps what its screen asked of it, and publishes what a test sends.
private final class RecordingCarbRatioTestRunner: CarbRatioTestRunning {
    let subject = CurrentValueSubject<CarbRatioTestRunnerState, Never>(CarbRatioTestRunnerState())
    /// What Begin answers.
    var beginError: SettingsTestBeginError?
    private(set) var begins: [CarbRatioTestBegin] = []
    /// The other actions, by name, in the order asked.
    @MainActor private(set) var actions: [String] = []
    @MainActor private(set) var checks = 0

    var state: CarbRatioTestRunnerState { subject.value }
    var statePublisher: AnyPublisher<CarbRatioTestRunnerState, Never> { subject.eraseToAnyPublisher() }

    @MainActor func begin(_ begin: CarbRatioTestBegin) async -> SettingsTestBeginError? {
        begins.append(begin)
        return beginError
    }

    @MainActor func countAndGoOn() { actions.append("countAndGoOn") }
    @MainActor func endEarly() async { actions.append("endEarly") }
    @MainActor func discard() { actions.append("discard") }
    @MainActor func acknowledgeResult() { actions.append("acknowledgeResult") }
    @MainActor func check() async { checks += 1 }
}

/// What the carb ratio screen reads, as a test sets it.
private final class FakeCarbRatioScreenReads: CarbRatioTestScreenReads {
    struct Failure: Error {}
    var data: CarbRatioTest.StateModel.ScreenData
    var settings: CarbRatioTest.StateModel.ScreenSettings
    var isfSchedule: [SettingsTestScheduleEntry] = []
    /// Whether the glucose read throws, as a refresh that fails.
    var failing = false

    init(_ data: CarbRatioTest.StateModel.ScreenData, settings: CarbRatioTest.StateModel.ScreenSettings) {
        self.data = data
        self.settings = settings
    }

    func isfEntries() -> [SettingsTestScheduleEntry] { isfSchedule }
    func isf(at _: Date) -> Decimal? { settings.isf }
    func target(at _: Date) -> Decimal? { settings.target }
    func carbRatio(at _: Date) -> Decimal? { settings.carbRatio }
    func carbRatioEntries() -> [SettingsTestScheduleEntry] { settings.carbRatioEntries }
    func fetchRecentGlucose(minutes _: Int) async throws -> [BasalTestReading] {
        if failing { throw Failure() }
        return data.readings
    }

    func currentIOB() -> Decimal? { data.iob }
    func currentCOB() async throws -> Decimal? { data.cob }
    func doseCOB(windowStart _: Date?) async -> Decimal? { data.doseCOB }
    func hasActiveAdjustment() async throws -> Bool { data.hasActiveAdjustment }
    func hasPumpSetTempBasal() -> Bool { data.hasPumpSetTempBasal }
    func pumpDelivery() -> ISFTestPumpDelivery? { data.pumpDelivery }
    func hasCgmAndPump() -> Bool { data.hasDevices }
    func maxBolus() -> Decimal? { settings.maxBolus }
    func maxCarbs() -> Decimal? { settings.maxCarbs }
}

/// The fake's reads, with the first carb ratio read held until `release` and giving 10 g/U, and every later one 12 g/U at
/// once, so a refresh that began first can publish its settings after one that began later.
private final class HeldSettingsReads: CarbRatioTestScreenReads, @unchecked Sendable {
    let base: FakeCarbRatioScreenReads
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var calls = 0
    private var _holding = false

    init(_ base: FakeCarbRatioScreenReads) { self.base = base }

    var isHolding: Bool { lock.withLock { _holding } }
    func release() { gate.signal() }

    func carbRatio(at _: Date) -> Decimal? {
        let call = lock.withLock { () -> Int in
            calls += 1
            if calls == 1 { _holding = true }
            return calls
        }
        guard call == 1 else { return 12 }
        _ = gate.wait(timeout: .now() + 5)
        lock.withLock { _holding = false }
        return 10
    }

    func isfEntries() -> [SettingsTestScheduleEntry] { base.isfEntries() }
    func isf(at date: Date) -> Decimal? { base.isf(at: date) }
    func target(at date: Date) -> Decimal? { base.target(at: date) }
    func carbRatioEntries() -> [SettingsTestScheduleEntry] { base.carbRatioEntries() }
    func fetchRecentGlucose(minutes: Int) async throws -> [BasalTestReading] { try await base
        .fetchRecentGlucose(minutes: minutes) }

    func currentIOB() -> Decimal? { base.currentIOB() }
    func currentCOB() async throws -> Decimal? { try await base.currentCOB() }
    func doseCOB(windowStart: Date?) async -> Decimal? { await base.doseCOB(windowStart: windowStart) }
    func hasActiveAdjustment() async throws -> Bool { try await base.hasActiveAdjustment() }
    func hasPumpSetTempBasal() -> Bool { base.hasPumpSetTempBasal() }
    func pumpDelivery() -> ISFTestPumpDelivery? { base.pumpDelivery() }
    func hasCgmAndPump() -> Bool { base.hasCgmAndPump() }
    func maxBolus() -> Decimal? { base.maxBolus() }
    func maxCarbs() -> Decimal? { base.maxCarbs() }
}

/// A carb ratio schedule in `Calendar.current`'s minutes of the day: `now` from an hour ago until `later` starts
/// `startsAfter` from now, then `later` for the rest of the day.
private func scheduleChanging(
    to later: Decimal,
    after startsAfter: TimeInterval,
    now: Decimal = 10
) -> [SettingsTestScheduleEntry] {
    func minuteOfDay(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
    let from = minuteOfDay(Date().addingTimeInterval(-3600))
    let change = minuteOfDay(Date().addingTimeInterval(startsAfter))
    // `now` runs from `from` to `change`, wrapping past midnight.
    func value(at minute: Int) -> Decimal {
        let inside = from < change ? (minute >= from && minute < change) : (minute >= from || minute < change)
        return inside ? now : later
    }
    let bounds = Array(Set([0, from, change, 1440])).sorted()
    return zip(bounds, bounds.dropFirst())
        .filter { $0 < $1 }
        .map { SettingsTestScheduleEntry(startMinutes: $0, endMinutes: $1, value: value(at: $0)) }
}

// MARK: - The screen

/// `.settingsTestFiles`: the tests that refresh the screen give it a settings test service (`makeTestService`), whose
/// history the Check screen's ISF row reads.
@Suite("Carb ratio test screen", .serialized, .settingsTestFiles) @MainActor struct CarbRatioTestScreenTests {
    /// A Check screen reading `screenData(readings(110))` and `settings()`, from Closed Loop, on `runner`.
    private func checkScreen(_ runner: RecordingCarbRatioTestRunner = RecordingCarbRatioTestRunner()) -> CarbRatioTest
        .StateModel
    {
        let manager = FakeSettingsManager()
        manager.settings.dosingMode = .closed
        let state = CarbRatioTest.StateModel()
        state.settingsManager = manager
        state.runner = runner
        state.show(screenData(readings(110)))
        state.show(settings())
        return state
    }

    // MARK: Following

    @Test("The screen shows the runner's step, settling and insulin on board for the dose") func followsRunner() {
        let state = CarbRatioTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        #expect(state.step == .check)
        let bolus = ISFTestSettlingBolus(date: Date().addingTimeInterval(-10 * minute), units: 1, isSMB: true)
        state.apply(CarbRatioTestRunnerState(test: carbRatioTest(.settling), settling: ISFTestSettlingProgress(
            decision: .waiting(loopedAt: nil, waitsForIOB: false),
            boluses: [bolus],
            readingsAfterLoop: 2,
            tempBasalRunning: true,
            iob: dec("0.2")
        )))
        #expect(state.step == .settle)
        #expect(state.settling == .waiting(loopedAt: nil, waitsForIOB: false))
        #expect(state.settlingBoluses == [bolus])
        #expect(state.settleReadings == 2)
        #expect(state.settleTempBasalRunning)
        // While settling, the insulin on board settling's last check read.
        #expect(state.currentIOB == dec("0.2"))

        state.apply(CarbRatioTestRunnerState(test: carbRatioTest(.dosing), settling: nil, doseIOB: dec("0.4")))
        #expect(state.step == .dose)
        #expect(state.settling == nil)
        #expect(state.settlingBoluses.isEmpty)
        #expect(state.doseIOB == dec("0.4"))

        state.apply(CarbRatioTestRunnerState(test: carbRatioTest(.waiting)))
        #expect(state.step == .wait)
        var finished = carbRatioTest(.finished)
        finished.endReason = .noBolus
        state.apply(CarbRatioTestRunnerState(test: finished))
        #expect(state.step == .result)
        // No bolus came: the dose and the wait were skipped.
        #expect(state.skippedSteps == [.dose, .wait])
        state.apply(CarbRatioTestRunnerState())
        #expect(state.step == .check)
        #expect(state.test == nil)
    }

    @Test("The screen follows what its runner publishes") func followsPublisher() async {
        let runner = RecordingCarbRatioTestRunner()
        runner.subject.send(CarbRatioTestRunnerState(test: carbRatioTest(.dosing)))
        let state = CarbRatioTest.StateModel()
        state.follow(runner)
        #expect(state.step == .dose)
        runner.subject.send(CarbRatioTestRunnerState(test: carbRatioTest(.waiting)))
        #expect(await eventuallyOnMain { state.step == .wait })
    }

    // MARK: Checks and Begin

    @Test("Begin turns on only once every check passes") func checksGateBegin() {
        let state = checkScreen()
        #expect(state.readyToStart)
        #expect(state.failingChecks.isEmpty)
        #expect(state.startBlocker == nil)

        // Basal Testing already on.
        state.settingsManager.settings.dosingMode = .basalTesting
        #expect(!state.readyToStart)
        #expect(state.failingChecks.map(\.id) == ["mode"])
        state.settingsManager.settings.dosingMode = .closed

        // Another test running names it first.
        state.showSession(SettingsTestSession(kind: .isf, expiresAt: Date().addingTimeInterval(3600), restore: []), lastEnd: nil)
        #expect(state.failingChecks.map(\.id) == ["otherTest"])
        #expect(state.startBlocker == "The Insulin Sensitivity test is still running. Finish it first.")
        // Its own session isn't another test.
        state.showSession(
            SettingsTestSession(kind: .carbRatio, expiresAt: Date().addingTimeInterval(3600), restore: []),
            lastEnd: nil
        )
        #expect(state.otherRunningTest == nil)
        state.showSession(nil, lastEnd: nil)
        #expect(state.readyToStart)

        // Carbs on board at the line, 3.6 g for 40 g at CR 10, hold Begin up; under it, they don't.
        state.show(screenData(readings(110), cob: dec("3.6")))
        #expect(state.failingChecks.map(\.id) == ["cob"])
        state.show(screenData(readings(110), cob: dec("3.5")))
        #expect(state.readyToStart)
        // Unread, they inform instead.
        state.show(screenData(readings(110), cob: nil))
        #expect(state.readyToStart)
        #expect(state.informingChecks.map(\.id).contains("cobUnread"))

        // Insulin on board over the whole dose (4 U) holds Begin up, and its row moves up; over the line it warns.
        state.show(screenData(readings(110), iob: dec("4.1")))
        #expect(state.failingChecks.map(\.id) == ["iobBlock"])
        #expect(!state.informingChecks.map(\.id).contains("iob"))
        state.show(screenData(readings(110), iob: dec("0.5")))
        #expect(state.readyToStart)
        #expect(state.iobDecision == .choice(line: dec("0.36")))
        #expect(state.informingChecks.first { $0.id == "iob" }?.state == .warning)

        // No carb ratio: no tablets to count.
        state.show(screenData(readings(110)))
        state.show(settings(carbRatio: nil))
        #expect(state.failingChecks.map(\.id) == ["tablets"])
        #expect(state.startBlocker == "Trio couldn't read your carb ratio, so it can't count the tablets.")
    }

    @Test("The tablet count starts at the default and stays between 1 and what the limits allow") func tabletCount() {
        let state = checkScreen()
        // 10 Dex4 tablets, 40 g, 4 U: inside 10 U and 250 g.
        #expect(state.wantedTabletCount == CarbRatioTest.Config.defaultTabletCount)
        #expect(state.tabletCount == 10)
        #expect(state.tabletCarbs == 40)
        #expect(state.checkDose == 4)

        // Never past the app's 20.
        state.wantedTabletCount = 25
        #expect(state.tabletCount == 20)
        // Never under 1.
        state.wantedTabletCount = 0
        #expect(state.tabletCount == 1)

        // Max Bolus 2 U: 0.4 U a tablet, so 5 tablets.
        state.wantedTabletCount = 10
        state.show(settings(maxBolus: 2))
        #expect(state.maxTablets == 5)
        #expect(state.tabletCount == 5)
        // Max Carbs 12 g: 3 tablets of 4 g.
        state.show(settings(maxCarbs: 12))
        #expect(state.tabletCount == 3)
        // TruePlus, 3.75 g: still 3, 11.25 g.
        state.selectedBrand = .trueplus
        #expect(state.tabletCount == 3)
        #expect(state.tabletCarbs == dec("11.25"))
        // Not even one tablet: none, and Begin is held up.
        state.show(settings(maxCarbs: 3))
        #expect(state.tabletCount == nil)
        #expect(state.failingChecks.map(\.id) == ["tablets"])

        // Limits unread: the app's cap only, as Begin then leaves them to Treatments.
        state.selectedBrand = .dex4
        state.show(settings(maxBolus: nil, maxCarbs: nil))
        #expect(state.maxTablets == CarbRatioTest.Config.maxTabletCount)
        #expect(state.tabletCount == 10)
    }

    @Test("The Tablets page says how far a 1 g/U step moves where glucose ends, and promises no end range") func precision() {
        let state = checkScreen()
        func with(_ value: Int) -> String { SettingsTestFormat.keepTogether("\(value)", unit: "mg/dL") }
        let step = SettingsTestFormat.keepTogether("1", unit: "g/U")
        // 50 × (40 ÷ 10 − 40 ÷ 11) = 18.18, so 18.
        #expect(state.endShiftPerStep == 18)
        #expect(
            state.precisionLine
                ==
                "A \(step) change in your carb ratio moves where glucose ends by about \(with(18)) with these tablets. More tablets give a clearer answer."
        )
        // 20 tablets, 80 g: twice as far, 36.36, so 36. It doesn't depend on the glucose now.
        state.wantedTabletCount = 20
        state.show(screenData([]))
        #expect(state.endShiftPerStep == 36)
        // No carb ratio: nothing to say.
        state.show(settings(carbRatio: nil))
        #expect(state.precisionLine == nil)
    }

    @Test("A carb ratio under 2 g/U, now or in the hours a test can run on, holds Begin up") func carbRatioMinimum() {
        let state = checkScreen()
        #expect(!state.blockingChecks.map(\.id).contains("carbRatioMinimum"))
        state.show(settings(carbRatio: dec("1.9")))
        #expect(state.failingChecks.map(\.id) == ["carbRatioMinimum"])
        #expect(state.startBlocker == SettingsTestBeginError.carbRatioUnderMinimum.message)
        state.show(settings(carbRatio: 2))
        #expect(state.readyToStart)
        // 2 g/U now, 1.5 g/U for the rest of the day: the hours a test begun now can reach cover it.
        var later = settings(carbRatio: 2)
        later.carbRatioEntries = [
            SettingsTestScheduleEntry(startMinutes: 0, endMinutes: 1440, value: dec("1.5"))
        ]
        state.show(later)
        #expect(state.failingChecks.map(\.id) == ["carbRatioMinimum"])
    }

    @Test("Begin sends the tablets, the length and the choice, and says the runner's refusal") func beginSendsChoices() async throws {
        let runner = RecordingCarbRatioTestRunner()
        let state = checkScreen(runner)
        state.selectedBrand = .reliOn
        state.wantedTabletCount = 8
        state.selectedLength = 3 * 3600
        state.iobChoice = .count
        state.requestStart()
        #expect(state.showStartConfirmation)
        state.confirmStart()
        #expect(await eventuallyOnMain { runner.begins.count == 1 })
        // L2: nothing on board, so the Ready page showed no choice, and Begin sends none, whatever was picked before.
        #expect(!state.checkPages.contains(.iob))
        #expect(runner.begins == [CarbRatioTestBegin(
            brand: .reliOn,
            count: 8,
            length: 3 * 3600,
            glucose: 110,
            iob: 0,
            iobChoice: nil
        )])
        #expect(state.errorMessage == nil)

        // With insulin on board over the line, the page shows the choice, and Begin sends it.
        state.show(screenData(readings(110), iob: dec("0.5")))
        #expect(state.checkPages.contains(.iob))
        state.confirmStart()
        #expect(await eventuallyOnMain { runner.begins.count == 2 })
        #expect(runner.begins.last?.iobChoice == .count)
        #expect(runner.begins.last?.iob == dec("0.5"))
        state.show(screenData(readings(110)))

        runner.beginError = .tabletsOverLimits
        state.confirmStart()
        #expect(await eventuallyOnMain { state.errorMessage == SettingsTestBeginError.tabletsOverLimits.message })

        // With checks failing, the runner isn't asked.
        state.errorMessage = nil
        state.settingsManager.settings.dosingMode = .basalTesting
        state.confirmStart()
        try await Task.sleep(for: .milliseconds(100))
        #expect(runner.begins.count == 3)

        // With no recent reading, no glucose is made up.
        state.settingsManager.settings.dosingMode = .closed
        state.show(screenData([BasalTestReading(date: Date().addingTimeInterval(-30 * minute), glucose: 110)]))
        state.confirmStart()
        try await Task.sleep(for: .milliseconds(100))
        #expect(runner.begins.count == 3)
        #expect(state.errorMessage != nil)
    }

    @Test("The Check screen's ISF row warns until an ISF test looked accurate on today's schedule") func isfRow() async {
        let harness = makeTestService()
        let state = checkScreen()
        state.testService = harness.service
        let reads = FakeCarbRatioScreenReads(screenData(readings(110)), settings: settings())
        reads.isfSchedule = [SettingsTestScheduleEntry(startMinutes: 0, endMinutes: 1440, value: 50)]
        state.screenReads = reads

        await state.refresh()
        #expect(state.isfGate == .noAccurateTest)
        #expect(state.informingChecks.first { $0.id == "isf" }?.state == .warning)
        #expect(state.readyToStart)

        // Whole seconds, as the history file keeps dates.
        let completedAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded())
        let accurate = SettingsTestRecord(
            kind: .isf,
            startedAt: completedAt.addingTimeInterval(-4 * 3600),
            completedAt: completedAt,
            startGlucose: 200,
            endGlucose: 100,
            direction: .keep,
            summary: "accurate",
            coveredEntries: reads.isfSchedule
        )
        harness.service.archive(accurate)
        await state.refresh()
        #expect(state.isfGate == .ready(lastAccurate: accurate.completedAt))
        #expect(state.informingChecks.first { $0.id == "isf" }?.state == .info)
    }

    // MARK: Dose

    @Test("Open Treatments, once the dose is offered, fills the tablets' carbs in on the sheet it opens") func openTreatments() async {
        let router = SettingsTestFakeRouter()
        let prefill = SettingsTestTreatmentsPrefill(
            router: { router },
            aiRequestFills: { false },
            testCarbsLogged: { false }
        )
        let state = CarbRatioTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        state.router = router
        state.prefill = prefill
        state.opener = SettingsTestScreenOpener(
            router: { router },
            keyWindowPresents: { false },
            recheckTicks: { Empty().eraseToAnyPublisher() }
        )
        state.apply(CarbRatioTestRunnerState(test: carbRatioTest(.dosing)))

        // No recent reading: nothing opens, and the step says why.
        state.show(screenData([]))
        state.openTreatments()
        #expect(router.mainModalScreen.value == nil)
        #expect(!prefill.isPending)
        #expect(state.errorMessage == CarbRatioTestNoDose.noRecentReading.sentence)

        // 3 flat readings, nothing on board: 40 g ÷ 10 = 4 U.
        state.errorMessage = nil
        state.show(screenData(readings(110)))
        #expect(state.canDose)
        #expect(state.docsDose == 4)
        state.openTreatments()
        #expect(router.mainModalScreen.value == .treatmentView)
        #expect(prefill.isPending)

        // The prepared fill is the tablets' 40 g.
        let sheet = Treatments.StateModel()
        sheet.maxCarbs = 250
        var recalculated = 0
        prefill.sheetAppeared(state: sheet, recalculate: { recalculated += 1 })
        #expect(sheet.carbs == 40)
        #expect(recalculated == 1)
    }

    @Test("Count It with insulin on board covering the dose is a wait, with Open Treatments off") func countedIOBCoversDoseWaits() {
        let state = CarbRatioTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        state.show(screenData(readings(110)))
        // 4.2 U on board covers the 4 U dose.
        state.apply(CarbRatioTestRunnerState(test: carbRatioTest(.dosing, handling: .count), doseIOB: dec("4.2")))
        #expect(state.noDoseReason == .iobCoversDose)
        #expect(state.noDoseReason?.isWaiting == true)
        #expect(state.docsDose == nil)
        #expect(!state.canDose)
        #expect(state.doseHoldText == CarbRatioTestNoDose.iobCoversDose.sentence)
        // 1 U on board leaves 3 U.
        state.apply(CarbRatioTestRunnerState(test: carbRatioTest(.dosing, handling: .count), doseIOB: 1))
        #expect(state.docsDose == 3)
        #expect(state.formulaDose == 4)
        #expect(state.canDose)
    }

    @Test("The yellow note says to enter the formula's dose when Trio's suggestion is past a 1 g/U step") func suggestion() {
        let manager = FakeSettingsManager()
        manager.settings.overrideFactor = dec("0.8")
        manager.preferences.bolusIncrement = dec("0.05")
        let state = CarbRatioTest.StateModel()
        state.settingsManager = manager
        state.show(screenData(readings(110)))
        state.apply(CarbRatioTestRunnerState(test: carbRatioTest(.dosing)))
        func units(_ text: String) -> String { SettingsTestFormat.keepTogether(text, unit: "U") }
        // 4 U × 80% = 3.20 U, under the 3.60 U a carb ratio of 11 gives (40 ÷ 11 = 3.64, rounded down to 0.05).
        #expect(state.trioSuggestion == dec("3.2"))
        #expect(!state.suggestionInRange(dec("3.2")))
        #expect(state.bolusRangeText == units("3.60–4.45"))
        let outside = state.suggestionNote(suggestion: dec("3.2"), dose: 4)
        #expect(
            outside.note
                ==
                "Enter \(units("4.00")). Trio's suggestion of about \(units("3.20")) is too far from the formula's dose for the test to judge."
        )
        #expect(outside.info.contains(units("3.60–4.45")))
        #expect(outside.info.contains("(80%)"))

        // 95%: 3.80 U, inside the step, so ISF's wording.
        manager.settings.overrideFactor = dec("0.95")
        #expect(state.trioSuggestion == dec("3.8"))
        #expect(state.suggestionInRange(dec("3.8")))
        let inside = state.suggestionNote(suggestion: dec("3.8"), dose: 4)
        #expect(inside.note.hasSuffix("Either is fine: the result is worked out from what you give."))
        #expect(inside.info.contains("correction"))
        // R2-4: a test that waits for insulin on board judges the bolus alone, so 0.70 U on board doesn't count.
        state.show(screenData(readings(110), iob: dec("0.7")))
        #expect(state.suggestionInRange(dec("3.8")))
        // Inside the 3.55–4.50 U the bolus may take, but not by the 0.05 U increment: "Enter 4.00 U".
        #expect(!state.suggestionInRange(dec("3.55")))
        #expect(!state.suggestionNote(suggestion: dec("3.55"), dose: 4).note.contains("Either is fine"))
        #expect(state.suggestionNote(suggestion: dec("3.6"), dose: 4).note.contains("Either is fine"))
        // Count It counts it with the bolus: 3.80 + 0.70 is past the 4.45 U top.
        state.apply(CarbRatioTestRunnerState(test: carbRatioTest(.dosing, handling: .count), doseIOB: dec("0.7")))
        #expect(!state.suggestionInRange(dec("3.8")))
        #expect(state.suggestionInRange(dec("3.2")))
    }

    // MARK: The meal's two halves

    @Test(
        "With the tablets' carbs logged first, the Dose step offers the bolus alone, whatever the arrow, with nothing filled in"
    ) func carbsLoggedFirst() {
        let router = SettingsTestFakeRouter()
        let prefill = SettingsTestTreatmentsPrefill(
            router: { router },
            aiRequestFills: { false },
            testCarbsLogged: { false }
        )
        let state = CarbRatioTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        state.router = router
        state.prefill = prefill
        state.opener = SettingsTestScreenOpener(
            router: { router },
            keyWindowPresents: { false },
            recheckTicks: { Empty().eraseToAnyPublisher() }
        )
        var test = carbRatioTest(.dosing)
        test.carbsAt = Date().addingTimeInterval(-3 * minute)
        test.carbs = 40
        state.apply(CarbRatioTestRunnerState(test: test))
        // Glucose rising from the tablets, carbs on board unread: judged at the carbs, so neither holds the bolus.
        let rising = [1, 6, 11].map {
            BasalTestReading(date: Date().addingTimeInterval(-Double($0) * minute), glucose: 140, direction: .singleUp)
        }
        state.show(screenData(rising, cob: nil))
        #expect(state.canDose)
        #expect(test.minutesLeftForBolus(at: Date()) == 12)
        state.openTreatments()
        #expect(router.mainModalScreen.value == .treatmentView)
        #expect(!prefill.isPending)
    }

    /// A Dose step for `test`, with Treatments behind a fake router and a prefill that fills nothing in.
    private func doseStep(_ test: CarbRatioTestState, doseIOB: Decimal?) -> (
        state: CarbRatioTest.StateModel,
        router: SettingsTestFakeRouter,
        prefill: SettingsTestTreatmentsPrefill
    ) {
        let router = SettingsTestFakeRouter()
        let prefill = SettingsTestTreatmentsPrefill(
            router: { router },
            aiRequestFills: { false },
            testCarbsLogged: { false }
        )
        let state = CarbRatioTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        state.router = router
        state.prefill = prefill
        state.opener = SettingsTestScreenOpener(
            router: { router },
            keyWindowPresents: { false },
            recheckTicks: { Empty().eraseToAnyPublisher() }
        )
        state.apply(CarbRatioTestRunnerState(test: test, doseIOB: doseIOB))
        state.show(screenData(readings(110), iob: nil, cob: nil))
        return (state, router, prefill)
    }

    @Test(
        "Count It with the carbs logged and insulin on board unread shows no dose, and still opens Treatments, filling nothing in"
    ) func countItAwaitsIOB() {
        // A3: no loop in the last 12 minutes, so no insulin on board to take off the formula's 4 U.
        var test = carbRatioTest(.dosing, handling: .count)
        test.carbsAt = Date().addingTimeInterval(-3 * minute)
        test.carbs = 40
        let (state, router, prefill) = doseStep(test, doseIOB: nil)
        #expect(state.noDoseReason == .iobUnread)
        #expect(state.docsDose == nil)
        #expect(state.countedDoseAwaitsIOB)
        #expect(state.canOpenTreatments)
        #expect(state.doseHoldText == nil)
        state.openTreatments()
        #expect(router.mainModalScreen.value == .treatmentView)
        #expect(!prefill.isPending)

        // Wait for It reads insulin on board only to hold the dose under its line: unread, Treatments stays closed.
        let waitForIt = doseStep(
            {
                var test = carbRatioTest(.dosing, handling: .wait)
                test.carbsAt = Date().addingTimeInterval(-3 * minute)
                test.carbs = 40
                return test
            }(),
            doseIOB: nil
        ).state
        #expect(!waitForIt.countedDoseAwaitsIOB)
        #expect(!waitForIt.canOpenTreatments)
        // Count It before the carbs are logged doesn't open Treatments without the dose.
        let beforeCarbs = doseStep(carbRatioTest(.dosing, handling: .count), doseIOB: nil).state
        #expect(!beforeCarbs.countedDoseAwaitsIOB)
        #expect(!beforeCarbs.canOpenTreatments)
    }

    @Test(
        "Once the 15 minutes for the bolus are up, the Dose step turns Open Treatments off and says the test is ending"
    ) func bolusTimeUp() {
        // R2-2: the carbs logged 16 minutes ago, no bolus seen yet.
        for handling in [ISFTestIOBHandling?.none, .count] {
            var test = carbRatioTest(.dosing, handling: handling)
            test.carbsAt = Date().addingTimeInterval(-16 * minute)
            test.carbs = 40
            let (state, router, _) = doseStep(test, doseIOB: handling == .count ? nil : 0)
            #expect(state.noDoseReason == .mealTimeUp)
            #expect(state.noDoseReason?.isWaiting == true)
            #expect(!state.canDose)
            #expect(!state.canOpenTreatments)
            #expect(state.doseHoldText == "The 15 minutes for the bolus are up, so the test is ending.")
            state.openTreatments()
            #expect(router.mainModalScreen.value == nil)
        }
    }

    @Test(
        "With the bolus in first, the Wait step opens Treatments for the carbs with nothing filled in, until the 15 minutes are up"
    ) func carbsAwaited() {
        let router = SettingsTestFakeRouter()
        let prefill = SettingsTestTreatmentsPrefill(
            router: { router },
            aiRequestFills: { false },
            testCarbsLogged: { false }
        )
        let state = CarbRatioTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        state.router = router
        state.prefill = prefill
        state.opener = SettingsTestScreenOpener(
            router: { router },
            keyWindowPresents: { false },
            recheckTicks: { Empty().eraseToAnyPublisher() }
        )
        var test = carbRatioTest(.waiting)
        test.bolusAt = Date().addingTimeInterval(-5 * minute)
        test.bolusUnits = 4
        state.apply(CarbRatioTestRunnerState(test: test))
        #expect(state.carbsMinutesLeft(at: Date()) == 10)
        state.openTreatmentsForCarbs()
        #expect(router.mainModalScreen.value == .treatmentView)
        #expect(!prefill.isPending)

        // Past the 15 minutes: nothing to log them for.
        router.mainModalScreen.send(nil)
        test.bolusAt = Date().addingTimeInterval(-16 * minute)
        state.apply(CarbRatioTestRunnerState(test: test))
        state.openTreatmentsForCarbs()
        #expect(router.mainModalScreen.value == nil)
        // Logged: none awaited.
        test.bolusAt = Date().addingTimeInterval(-5 * minute)
        test.carbs = 40
        state.apply(CarbRatioTestRunnerState(test: test))
        #expect(state.carbsAwaitedUntil == nil)
        #expect(state.carbsMinutesLeft(at: Date()) == nil)
    }

    @Test("The Result's expected end uses the tablets' planned grams, not grams logged within a gram") func expectedEndOnPlanned() {
        // R2-3: 39.5 g logged for the tablets' 40 g; 4.50 U acted, so an accurate ratio ends at 110 + 50 × (4 − 4.5) = 85,
        // where 39.5 g would give 82.5.
        let state = CarbRatioTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        var test = carbRatioTest(.finished)
        let endedAt = Date().addingTimeInterval(-10 * minute)
        test.bolusAt = endedAt.addingTimeInterval(-4 * 3600)
        test.bolusUnits = dec("4.5")
        test.iobAtBolus = 0
        test.iobAtEnd = 0
        test.startGlucose = 110
        test.carbs = dec("39.5")
        test.carbsAt = test.bolusAt
        test.endGlucose = 90
        test.endedAt = endedAt
        test.endReason = .completed
        test.interferenceUnread = false
        test.outcome = CarbRatioTestEvaluator.evaluation(of: test)?.outcome
        #expect(test.outcome == .accurate)
        state.apply(CarbRatioTestRunnerState(test: test))
        #expect(state.expectedEndAwayFromStart == 85)
    }

    @Test(
        "The Result says how much insulin was still on board at the end, and about how far it would still bring glucose"
    ) func stillToComeOff() {
        let state = CarbRatioTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        var test = carbRatioTest(.finished)
        let endedAt = Date().addingTimeInterval(-10 * minute)
        test.bolusAt = endedAt.addingTimeInterval(-4 * 3600)
        test.bolusUnits = 4
        test.iobAtBolus = 0
        test.iobAtEnd = dec("0.56")
        test.startGlucose = 110
        test.carbs = 40
        test.carbsAt = test.bolusAt
        test.endGlucose = 140
        test.endedAt = endedAt
        test.endReason = .completed
        test.interferenceUnread = false
        test.outcome = CarbRatioTestEvaluator.evaluation(of: test)?.outcome
        state.apply(CarbRatioTestRunnerState(test: test))
        #expect(state.resultBand != nil)
        // 0.56 U × 50 = 28 mg/dL.
        let units = SettingsTestFormat.keepTogether("0.56", unit: "U")
        let amount = SettingsTestFormat.keepTogether("28", unit: "mg/dL")
        #expect(state.stillToComeOffLine == "\(units) was still on board at the end: about \(amount) still to come off.")
        test.iobAtEnd = 0
        test.outcome = CarbRatioTestEvaluator.evaluation(of: test)?.outcome
        state.apply(CarbRatioTestRunnerState(test: test))
        #expect(state.stillToComeOffLine == nil)
    }

    // MARK: The pages

    @Test("The start goes Check, Tablets, How long, Ready, with Insulin on board only when there is a choice") func pageOrder() {
        let state = checkScreen()
        #expect(state.shownCheckPage == .checks)
        #expect(state.checkPages == [.checks, .tablets, .length, .ready])
        #expect(state.checkPagePosition(.tablets) == "2 of 4")
        // Back on the first page stays there.
        state.previousCheckPage()
        #expect(state.shownCheckPage == .checks)
        state.nextCheckPage()
        #expect(state.shownCheckPage == .tablets)
        state.nextCheckPage()
        #expect(state.shownCheckPage == .length)
        state.nextCheckPage()
        #expect(state.shownCheckPage == .ready)
        // Next on the last page stays there; Begin is its button.
        state.nextCheckPage()
        #expect(state.shownCheckPage == .ready)
        state.previousCheckPage()
        #expect(state.shownCheckPage == .length)

        // 0.5 U on board, over the 0.36 U line: the Insulin on board page comes after How long.
        state.show(screenData(readings(110), iob: dec("0.5")))
        #expect(state.checkPages == [.checks, .tablets, .length, .iob, .ready])
        #expect(state.checkPagePosition(.ready) == "5 of 5")
        state.nextCheckPage()
        #expect(state.shownCheckPage == .iob)
        state.nextCheckPage()
        #expect(state.shownCheckPage == .ready)
        state.previousCheckPage()
        #expect(state.shownCheckPage == .iob)

        // Back under the line while that page shows: it hands over to How long.
        state.show(screenData(readings(110), iob: 0))
        #expect(state.shownCheckPage == .length)
        state.nextCheckPage()
        #expect(state.shownCheckPage == .ready)
    }

    @Test("Next is off while a check blocks, on every page, and Cancel or Done starts the pages again") func nextBlocked() {
        let runner = RecordingCarbRatioTestRunner()
        let state = checkScreen(runner)
        // Cancel and Done refresh the screen.
        state.testService = makeTestService().service
        state.screenReads = FakeCarbRatioScreenReads(screenData(readings(110)), settings: settings())
        state.settingsManager.settings.dosingMode = .basalTesting
        #expect(!state.canGoOn)
        state.nextCheckPage()
        #expect(state.shownCheckPage == .checks)
        state.settingsManager.settings.dosingMode = .closed
        state.nextCheckPage()
        state.nextCheckPage()
        #expect(state.shownCheckPage == .length)
        // Another test begins meanwhile: Next goes off there, with the check's sentence.
        state.showSession(SettingsTestSession(kind: .isf, expiresAt: Date().addingTimeInterval(3600), restore: []), lastEnd: nil)
        #expect(!state.canGoOn)
        #expect(state.startBlocker == "The Insulin Sensitivity test is still running. Finish it first.")
        state.nextCheckPage()
        #expect(state.shownCheckPage == .length)
        state.showSession(nil, lastEnd: nil)

        state.discard()
        #expect(state.shownCheckPage == .checks)
        state.nextCheckPage()
        state.acknowledgeResult()
        #expect(state.shownCheckPage == .checks)
    }

    @Test("The Ready page sums up every pick, and Begin passes each of them") func readyPassesPicks() async {
        let runner = RecordingCarbRatioTestRunner()
        let state = checkScreen(runner)
        state.show(screenData(readings(110), iob: dec("0.5")))
        state.nextCheckPage()
        state.selectedBrand = .trueplus
        state.wantedTabletCount = 10
        state.nextCheckPage()
        state.selectedLength = 3 * 3600
        state.nextCheckPage()
        state.iobChoice = .count
        state.nextCheckPage()
        #expect(state.shownCheckPage == .ready)
        let grams = SettingsTestFormat.keepTogether("37.5", unit: "g")
        // 37.5 ÷ 10 = 3.75 U.
        #expect(state.readySummary == [
            .init(title: "Tablets", value: "10 TruePlus · \(grams)"),
            .init(title: "Bolus", value: SettingsTestFormat.keepTogether("3.75", unit: "U")),
            .init(title: "Watch for", value: "3 h after the bolus"),
            .init(title: "Insulin on board", value: "Count It")
        ])
        state.requestStart()
        state.confirmStart()
        #expect(await eventuallyOnMain { runner.begins.count == 1 })
        #expect(runner.begins == [CarbRatioTestBegin(
            brand: .trueplus,
            count: 10,
            length: 3 * 3600,
            glucose: 110,
            iob: dec("0.5"),
            iobChoice: .count
        )])
    }

    // MARK: The other actions

    @Test("Count It and Go On only once settling's time is up; the other actions go to the runner") func actions() async {
        let runner = RecordingCarbRatioTestRunner()
        let state = CarbRatioTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        state.testService = makeTestService().service
        state.screenReads = FakeCarbRatioScreenReads(screenData(readings(110)), settings: settings())
        state.runner = runner

        state.apply(CarbRatioTestRunnerState(test: carbRatioTest(.settling), settling: ISFTestSettlingProgress(
            decision: .waiting(loopedAt: nil, waitsForIOB: true),
            boluses: [],
            readingsAfterLoop: nil,
            tempBasalRunning: false
        )))
        state.countAndGoOn()
        #expect(runner.actions.isEmpty)
        state.apply(CarbRatioTestRunnerState(test: carbRatioTest(.settling), settling: ISFTestSettlingProgress(
            decision: .timeUp(loopedAt: Date().addingTimeInterval(-50 * minute)),
            boluses: [],
            readingsAfterLoop: nil,
            tempBasalRunning: false
        )))
        state.countAndGoOn()
        #expect(runner.actions == ["countAndGoOn"])

        state.iobChoice = .count
        state.discard()
        #expect(runner.actions == ["countAndGoOn", "discard"])
        #expect(state.iobChoice == .wait)
        // The refresh it starts ends with a check.
        #expect(await eventuallyOnMain { runner.checks == 1 })

        state.acknowledgeResult()
        #expect(runner.actions == ["countAndGoOn", "discard", "acknowledgeResult"])
        #expect(await eventuallyOnMain { runner.checks == 2 })

        await state.endEarly()
        #expect(runner.actions == ["countAndGoOn", "discard", "acknowledgeResult", "endEarly"])
    }

    // MARK: CodeRabbit's review

    @Test(
        "A carb ratio under 2 g/U only a 4 h test reaches holds up How long, not the checks, and 3 h clears it"
    ) func minimumOnTheLengthPage() {
        let state = checkScreen()
        // 1.5 g/U from 7.5 hours on: the hours a 4 h test can reach (Begin + 1 h + 3 h + 4 h) cover it, a 3 h one's don't.
        var later = settings()
        later.carbRatioEntries = scheduleChanging(to: dec("1.5"), after: 450 * minute)
        state.show(later)
        #expect(state.selectedLength == 4 * 3600)
        #expect(state.carbRatioUnderMinimum(for: 4 * 3600))
        #expect(!state.carbRatioUnderMinimum(for: 3 * 3600))
        // The checks read the shortest length's hours: Next goes on, to the page that can clear it.
        #expect(state.canGoOn)
        state.nextCheckPage()
        state.nextCheckPage()
        #expect(state.shownCheckPage == .length)
        // How long reads the length picked: Next goes off, saying how to clear it.
        #expect(!state.canGoOn)
        #expect(state.failingChecks.map(\.id) == ["carbRatioMinimum"])
        #expect(
            state.startBlocker == SettingsTestBeginError.carbRatioUnderMinimum.message
                + " Watching for 3 h keeps the test clear of it."
        )
        state.selectedLength = 3 * 3600
        #expect(state.canGoOn)
        state.nextCheckPage()
        #expect(state.shownCheckPage == .ready)
        #expect(state.readyToStart)
        // Back to 4 h: Begin is held up on Ready too.
        state.selectedLength = 4 * 3600
        #expect(!state.readyToStart)
    }

    @Test("The Dose step works the counted dose out with the increment Begin saved") func savedIncrement() {
        // Count It with 3.7 U on board: 4 − 3.70 = 0.30 U, under a live increment of 0.5 U but over the saved 0.05 U.
        var test = carbRatioTest(.dosing, handling: .count)
        test.bolusIncrement = dec("0.05")
        let (state, _, _) = doseStep(test, doseIOB: dec("3.7"))
        state.settingsManager.preferences.bolusIncrement = dec("0.5")
        state.show(screenData(readings(110)))
        #expect(state.docsDose == dec("0.3"))
        #expect(state.noDoseReason == nil)
        #expect(state.canDose)
    }

    @Test(
        "The tablets fit Max Bolus at the lowest carb ratio a test can meet, and the Dose step offers no dose over it"
    ) func tabletsAtTheLowestRatio() {
        let state = checkScreen()
        // 4 U: 10 Dex4 tablets at the 10 g/U now (0.4 U each), but 5 at the 5 g/U from 5 hours on (0.8 U each).
        var lower = settings(maxBolus: 4)
        lower.carbRatioEntries = scheduleChanging(to: 5, after: 300 * minute)
        state.show(lower)
        #expect(state.lowestCarbRatio == 5)
        #expect(state.maxTablets == 5)
        #expect(state.tabletCount == 5)
        // The dose shown stays the one now: 20 g ÷ 10.
        #expect(state.checkDose == 2)

        // A Dose step whose 4 U is over a Max Bolus lowered to 3 U since Begin: a dead end, not offered.
        let (dose, _, _) = doseStep(carbRatioTest(.dosing), doseIOB: nil)
        dose.show(screenData(readings(110)))
        dose.show(settings(maxBolus: 3))
        #expect(dose.noDoseReason == .overMaxBolus)
        #expect(dose.noDoseReason?.isWaiting == false)
        #expect(!dose.canDose)
        dose.show(settings(maxBolus: 4))
        #expect(dose.canDose)
    }

    @Test("The Dose step's deadline is a clock time: the dose deadline, or the meal's sooner one") func deadlineText() throws {
        let (state, _, _) = doseStep(carbRatioTest(.dosing), doseIOB: nil)
        let test = try #require(state.test)
        let time = test.doseDeadline.formatted(date: .omitted, time: .shortened)
        #expect(state.doseDeadlineText == "The test needs your bolus by \(time).")
        // The tablets' carbs logged 3 minutes ago: the bolus is due 12 minutes from now, sooner than the dose deadline.
        var logged = test
        logged.carbsAt = Date().addingTimeInterval(-3 * minute)
        logged.carbs = 40
        state.apply(CarbRatioTestRunnerState(test: logged))
        let meal = try #require(logged.bolusDeadline).formatted(date: .omitted, time: .shortened)
        #expect(state.doseDeadlineText == "The test needs your bolus by \(meal).")
    }

    @Test("An older refresh doesn't show its settings over a newer one's") func olderRefreshSettings() async {
        let state = checkScreen()
        state.testService = makeTestService().service
        let held = HeldSettingsReads(FakeCarbRatioScreenReads(screenData(readings(110)), settings: settings()))
        state.screenReads = held
        let first = Task { await state.refresh() }
        #expect(await eventually { held.isHolding })
        // The newer refresh reads 12 g/U and shows it while the older one still reads.
        await state.refresh()
        #expect(state.settingsNow.carbRatio == 12)
        held.release()
        await first.value
        #expect(state.settingsNow.carbRatio == 12)
    }

    @Test("A refresh that fails leaves insulin on board unread, so the Dose step waits for a read") func failedRefreshClearsIOB() async {
        let state = checkScreen()
        state.testService = makeTestService().service
        let reads = FakeCarbRatioScreenReads(screenData(readings(110), iob: dec("0.2")), settings: settings())
        state.screenReads = reads
        state.apply(CarbRatioTestRunnerState(test: carbRatioTest(.dosing)))
        await state.refresh()
        #expect(state.currentIOB == dec("0.2"))
        #expect(state.canDose)

        reads.failing = true
        await state.refresh()
        #expect(state.currentIOB == nil)
        #expect(state.noDoseReason == .iobUnread)
        #expect(!state.canDose)
        #expect(state.errorMessage != nil)
    }

    @Test(
        "The carbs-logged card counts down to the dose deadline when it comes before the meal's 15 minutes"
    ) func carbsLoggedCardDoseDeadline() throws {
        var test = carbRatioTest(.dosing, handling: nil)
        test.carbsAt = Date().addingTimeInterval(-3 * minute)
        test.carbs = 40
        // Settling ended 88 minutes ago, so the 90-minute dose deadline is 2 minutes off, before the meal's 12.
        test.settledAt = Date().addingTimeInterval(-88 * minute)
        let state = doseStep(test, doseIOB: nil).state
        state.show(screenData(readings(110)))
        let shown = try #require(state.test)
        #expect(shown.effectiveBolusDeadline == shown.doseDeadline)
        let time = shown.doseDeadline.formatted(date: .omitted, time: .shortened)
        #expect(
            state.carbsLoggedCard?.detail
                == "2 minutes left, until \(time). Enter only the bolus in Treatments: the carbs are in. Then take the tablets."
        )
        #expect(state.doseDeadlineText == "The test needs your bolus by \(time).")
    }

    @Test(
        "The carbs-logged card shows only with a dose due, never the formula's dose for a counted one"
    ) func carbsLoggedCard() throws {
        func logged(_ handling: ISFTestIOBHandling?, minutesAgo: Double = 3) -> CarbRatioTestState {
            var test = carbRatioTest(.dosing, handling: handling)
            test.carbsAt = Date().addingTimeInterval(-minutesAgo * minute)
            test.carbs = 40
            return test
        }
        let units = SettingsTestFormat.keepTogether("4.00", unit: "U")

        // A dose due: the dose, the minutes left and the time.
        let due = doseStep(logged(nil), doseIOB: nil).state
        due.show(screenData(readings(110)))
        let time = try #require(due.test?.bolusDeadline).formatted(date: .omitted, time: .shortened)
        #expect(due.carbsLoggedCard?.headline == "The tablets' carbs are logged. Give the bolus now: \(units).")
        #expect(
            due.carbsLoggedCard?.detail
                ==
                "12 of 15 minutes left, until \(time). Enter only the bolus in Treatments: the carbs are in. Then take the tablets."
        )

        // Count It with 4.2 U on board covering the 4 U: no dose due, so no card; the step's own says it waits.
        let covered = doseStep(logged(.count), doseIOB: dec("4.2")).state
        #expect(covered.noDoseReason == .iobCoversDose)
        #expect(covered.carbsLoggedCard == nil)
        // The meal's deadline goes in the line under the step's card instead.
        let coveredTime = try #require(covered.test?.bolusDeadline).formatted(date: .omitted, time: .shortened)
        #expect(covered.doseDeadlineText == "The test needs your bolus by \(coveredTime).")

        // Count It with insulin on board unread (A3): the bolus without a dose, never the formula's 4 U.
        let unread = doseStep(logged(.count), doseIOB: nil).state
        #expect(unread.countedDoseAwaitsIOB)
        #expect(unread.carbsLoggedCard?.headline == "The tablets' carbs are logged. Give the bolus now.")

        // Insulin on board over the line in a Wait for It test: no dose due, no card.
        let over = doseStep(logged(.wait), doseIOB: nil).state
        over.show(screenData(readings(110), iob: dec("0.5")))
        #expect(over.noDoseReason == .iobOverLine)
        #expect(over.carbsLoggedCard == nil)

        // C3, the time up: only the step's sentence that the test is ending, not a second card.
        let timeUp = doseStep(logged(nil, minutesAgo: 16), doseIOB: nil).state
        timeUp.show(screenData(readings(110)))
        #expect(timeUp.noDoseReason == .mealTimeUp)
        #expect(timeUp.carbsLoggedCard == nil)
    }

    @Test(
        "The tablets card says the result uses the tablets' grams only for a verdict on grams logged within a gram"
    ) func resultTabletsText() {
        let state = CarbRatioTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        func finished(logged: Decimal?, outcome: CarbRatioTestOutcome, interference: String? = nil) -> CarbRatioTestState {
            var test = carbRatioTest(.finished)
            test.bolusAt = Date().addingTimeInterval(-4 * 3600)
            test.carbs = logged
            test.carbsAt = logged == nil ? nil : test.bolusAt
            test.endedAt = Date()
            test.endReason = interference == nil ? .completed : .interrupted
            test.interference = interference
            test.outcome = outcome
            return test
        }
        func grams(_ text: String) -> String { SettingsTestFormat.keepTogether(text, unit: "g") }
        let tablets = "10 tablets of Dex4 (\(grams("40")))"

        state.apply(CarbRatioTestRunnerState(test: finished(logged: 40, outcome: .accurate)))
        #expect(state.resultTabletsText == "\(tablets), logged as \(grams("40")) with the bolus.")
        // 39.5 g, within a gram, with a verdict: judged on the tablets' 40 g.
        state.apply(CarbRatioTestRunnerState(test: finished(logged: dec("39.5"), outcome: .tooHigh)))
        #expect(
            state.resultTabletsText
                == "\(tablets). \(grams("39.5")) logged with the bolus; the result uses the tablets' \(grams("40"))."
        )
        // 30 g, which made the test invalid: only what was logged.
        let differ = CarbRatioTestBolusCondition.carbsDiffer(logged: 30, planned: 40).note
        state.apply(CarbRatioTestRunnerState(test: finished(logged: 30, outcome: .invalid, interference: differ)))
        #expect(state.resultTabletsText == "\(tablets). \(grams("30")) logged with the bolus.")
        // Within a gram, but no verdict for another reason: nothing about what a result used.
        state.apply(CarbRatioTestRunnerState(test: finished(logged: dec("39.5"), outcome: .invalid, interference: "x")))
        #expect(state.resultTabletsText == "\(tablets). \(grams("39.5")) logged with the bolus.")
        state.apply(CarbRatioTestRunnerState(test: finished(logged: nil, outcome: .invalid, interference: "x")))
        #expect(state.resultTabletsText == "\(tablets). Their carbs weren't logged with the bolus.")
    }

    @Test("The steps sheet lists every step of the test, in order") func stepsSheet() {
        #expect(CarbRatioTest.CheckView.steps().map(\.step) == CarbRatioTest.Step.allCases)
    }
}

// MARK: - The prefill

@Suite("Settings test Treatments prefill") @MainActor struct SettingsTestTreatmentsPrefillTests {
    private func sheet(maxCarbs: Decimal = 250) -> Treatments.StateModel {
        let state = Treatments.StateModel()
        state.maxCarbs = maxCarbs
        return state
    }

    @Test("It fills the carbs in once the sheet's limits load, once, then recalculates") func fillsOnceLimitsLoad() async {
        let router = SettingsTestFakeRouter()
        let prefill = SettingsTestTreatmentsPrefill(router: { router }, aiRequestFills: { false })
        prefill.prepare(carbs: 40)
        router.mainModalScreen.send(.treatmentView)

        let state = sheet(maxCarbs: 0)
        var recalculated = 0
        prefill.sheetAppeared(state: state, recalculate: { recalculated += 1 })
        // Max Carbs is 0 until the sheet's settings load.
        #expect(state.carbs == 0)
        #expect(recalculated == 0)
        state.maxCarbs = 250
        #expect(await eventuallyOnMain { state.carbs == 40 })
        #expect(recalculated == 1)
        #expect(!prefill.isPending)

        // The sheet appearing again, its carbs cleared, isn't filled in again.
        state.carbs = 0
        prefill.sheetAppeared(state: state, recalculate: { recalculated += 1 })
        #expect(state.carbs == 0)
        #expect(recalculated == 1)
    }

    @Test("A sheet the user opened themselves is left alone") func userSheetAlone() {
        let prefill = SettingsTestTreatmentsPrefill(router: { SettingsTestFakeRouter() }, aiRequestFills: { false })
        let state = sheet()
        prefill.sheetAppeared(state: state, recalculate: {})
        #expect(state.carbs == 0)
    }

    @Test("A sheet an AI request fills is left alone, and the fill is dropped") func aiSheetAlone() {
        let prefill = SettingsTestTreatmentsPrefill(router: { SettingsTestFakeRouter() }, aiRequestFills: { true })
        prefill.prepare(carbs: 40)
        let state = sheet()
        state.carbs = dec("82.5")
        var recalculated = 0
        prefill.sheetAppeared(state: state, recalculate: { recalculated += 1 })
        #expect(state.carbs == dec("82.5"))
        #expect(recalculated == 0)
        #expect(!prefill.isPending)
    }

    @Test("A sheet that already shows carbs keeps them") func sheetWithCarbsAlone() {
        let prefill = SettingsTestTreatmentsPrefill(router: { SettingsTestFakeRouter() }, aiRequestFills: { false })
        prefill.prepare(carbs: 40)
        let state = sheet()
        state.carbs = 12
        var recalculated = 0
        prefill.sheetAppeared(state: state, recalculate: { recalculated += 1 })
        #expect(state.carbs == 12)
        #expect(recalculated == 0)
        #expect(!prefill.isPending)
    }

    @Test("The sheet keeps the tablets' decimals while it is up, filled or not, and its own formatter after") func gramFormatter(
    ) async throws {
        let router = SettingsTestFakeRouter()
        let prefill = SettingsTestTreatmentsPrefill(router: { router }, aiRequestFills: { false }, testCarbsLogged: { false })
        #expect(prefill.gramFormatter == nil)
        // 10 TruePlus tablets.
        prefill.prepare(carbs: dec("37.5"))
        router.mainModalScreen.send(.treatmentView)
        let formatter = try #require(prefill.gramFormatter)
        formatter.locale = Locale(identifier: "en_US")
        #expect(formatter.string(from: NSDecimalNumber(decimal: dec("37.5"))) == "37.5")
        #expect(formatter.number(from: "37.5")?.decimalValue == dec("37.5"))
        let state = sheet()
        prefill.sheetAppeared(state: state, recalculate: {})
        #expect(state.carbs == dec("37.5"))
        // Filled, and still up: the field keeps showing 37.5, not 38.
        #expect(!prefill.isPending)
        #expect(prefill.gramFormatter != nil)
        prefill.sheetDisappeared()
        #expect(prefill.gramFormatter != nil)
        // Closed: back to the sheet's own.
        router.mainModalScreen.send(nil)
        #expect(await eventuallyOnMain { prefill.gramFormatter == nil })
    }

    @Test("Carbs logged while the limits load aren't filled in") func carbsLoggedWhileLimitsLoad() async throws {
        var logged = false
        let prefill = SettingsTestTreatmentsPrefill(
            router: { SettingsTestFakeRouter() },
            aiRequestFills: { false },
            testCarbsLogged: { logged }
        )
        prefill.prepare(carbs: 40)
        let state = sheet(maxCarbs: 0)
        var recalculated = 0
        prefill.sheetAppeared(state: state, recalculate: { recalculated += 1 })
        // Logged meanwhile, from another sheet.
        logged = true
        state.maxCarbs = 250
        #expect(await eventuallyOnMain { !prefill.isPending })
        try await Task.sleep(for: .milliseconds(50))
        #expect(state.carbs == 0)
        #expect(recalculated == 0)
    }

    @Test("A late limits callback from a closed sheet fills nothing, and the newer sheet still gets its fill") func staleSheet() async {
        let router = SettingsTestFakeRouter()
        let prefill = SettingsTestTreatmentsPrefill(router: { router }, aiRequestFills: { false }, testCarbsLogged: { false })
        // The first sheet appears while its limits load, then closes.
        prefill.prepare(carbs: 40)
        let old = sheet(maxCarbs: 0)
        prefill.sheetAppeared(state: old, recalculate: {})
        prefill.sheetDisappeared()
        #expect(!prefill.isPending)
        // A newer request's sheet appears, its limits loading too.
        prefill.prepare(carbs: dec("37.5"))
        let new = sheet(maxCarbs: 0)
        prefill.sheetAppeared(state: new, recalculate: {})
        // The closed sheet's limits load late: its callback fills nothing.
        old.maxCarbs = 250
        try? await Task.sleep(for: .milliseconds(100))
        #expect(old.carbs == 0)
        #expect(prefill.isPending)
        new.maxCarbs = 250
        #expect(await eventuallyOnMain { new.carbs == dec("37.5") })
    }

    @Test("The test's carbs count as logged before and after its bolus") func carbsLoggedAnyTime() {
        var test = carbRatioTest(.dosing)
        #expect(!SettingsTestTreatmentsPrefill.testCarbsLogged(in: test))
        test.carbsAt = Date().addingTimeInterval(-3 * minute)
        #expect(SettingsTestTreatmentsPrefill.testCarbsLogged(in: test))
        // The bolus recorded too: still logged, so a pending sheet isn't filled in again.
        test.bolusAt = Date().addingTimeInterval(-minute)
        test.phase = .waiting
        #expect(!test.carbsLoggedAwaitingBolus)
        #expect(SettingsTestTreatmentsPrefill.testCarbsLogged(in: test))
        #expect(!SettingsTestTreatmentsPrefill.testCarbsLogged(in: nil))
    }

    @Test("The fill is dropped when the sheet closes, or the router leaves it before it appeared") func dropsOnClose() async {
        let router = SettingsTestFakeRouter()
        let prefill = SettingsTestTreatmentsPrefill(router: { router }, aiRequestFills: { false })

        // Closed while its limits load: still the router's sheet, then not.
        prefill.prepare(carbs: 40)
        router.mainModalScreen.send(.treatmentView)
        let waiting = sheet(maxCarbs: 0)
        prefill.sheetAppeared(state: waiting, recalculate: {})
        prefill.sheetDisappeared()
        #expect(prefill.isPending)
        router.mainModalScreen.send(nil)
        prefill.sheetDisappeared()
        #expect(!prefill.isPending)
        waiting.maxCarbs = 250
        try? await Task.sleep(for: .milliseconds(100))
        #expect(waiting.carbs == 0)

        // Sent, then wiped before the sheet appeared: a sheet the user opens later isn't filled in.
        prefill.prepare(carbs: 40)
        router.mainModalScreen.send(.treatmentView)
        router.mainModalScreen.send(nil)
        #expect(await eventuallyOnMain { !prefill.isPending })
        let later = sheet()
        prefill.sheetAppeared(state: later, recalculate: {})
        #expect(later.carbs == 0)
    }
}

// MARK: - The hub

@Suite("Carb ratio hub") struct CarbRatioHubTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let english = Locale(identifier: "en_US")

    private func entry(_ start: Int, _ end: Int, _ value: Decimal) -> SettingsTestScheduleEntry {
        SettingsTestScheduleEntry(startMinutes: start, endMinutes: end, value: value)
    }

    private func record(
        _ kind: SettingsTestKind,
        _ direction: SettingsTestDirection,
        minutesAgo: Double,
        covered: [SettingsTestScheduleEntry]?
    ) -> SettingsTestRecord {
        SettingsTestRecord(
            kind: kind,
            startedAt: now.addingTimeInterval(-minutesAgo * 60 - 4 * 3600),
            completedAt: now.addingTimeInterval(-minutesAgo * 60),
            startGlucose: 110,
            endGlucose: 120,
            direction: direction,
            summary: "test",
            coveredEntries: covered
        )
    }

    @Test(
        "The carb ratio row opens the carb ratio test, but not while the old wizard's test is under way"
    ) @MainActor func rowOpens() {
        #expect(SettingsTestKind.carbRatio.availability == .available)
        #expect(SettingsTestKind.carbRatio.testScreen == .carbRatioTest)
        let state = SettingsTest.StateModel()
        #expect(state.screen(for: .carbRatio) == .carbRatioTest)
        // It opens while another test runs, so its steps can be read.
        state.activeSession = SettingsTestSession(kind: .isf, expiresAt: now.addingTimeInterval(3600), restore: [])
        #expect(state.screen(for: .carbRatio) == .carbRatioTest)
        state.carbRatioInProgress = true
        #expect(state.screen(for: .carbRatio) == nil)
    }

    @Test("A carb ratio schedule becomes periods in grams per unit, exchanges as Trio converts them") func periods() {
        let grams = CarbRatios(
            units: .grams,
            schedule: [
                CarbRatioEntry(start: "00:00", offset: 0, ratio: 10),
                CarbRatioEntry(start: "06:00", offset: 360, ratio: 12)
            ]
        )
        #expect(SettingsTestSchedule.entries(grams) == [entry(0, 360, 10), entry(360, 1440, 12)])
        let exchanges = CarbRatios(units: .exchanges, schedule: [CarbRatioEntry(start: "00:00", offset: 0, ratio: dec("1.5"))])
        // 12 g an exchange ÷ 1.5 = 8 g/U.
        #expect(SettingsTestSchedule.entries(exchanges) == [entry(0, 1440, 8)])

        let current = [entry(0, 360, 10), entry(360, 1440, 12)]
        let tooHigh = record(.carbRatio, .decrease, minutesAgo: 10, covered: [entry(360, 1440, 12)])
        let isf = record(.isf, .keep, minutesAgo: 5, covered: [entry(0, 360, 10)])
        let periods = SettingsTestSchedule.periods(for: .carbRatio, current: current, history: [isf, tooHigh])
        #expect(periods.map(\.lastDirection) == [nil, .decrease])
        #expect(SettingsTestKind.carbRatio.periodStatusText(for: periods[0]) { _ in "3 days ago" } == "Not tested yet")
        #expect(
            SettingsTestKind.carbRatio.periodStatusText(for: periods[1]) { _ in "3 days ago" }
                == "Carb ratio looked too high 3 days ago"
        )
    }

    @Test("A carb ratio shows as grams per unit, kept on one line") @MainActor func carbRatioText() {
        let state = SettingsTest.StateModel()
        #expect(state.formatCarbRatio(10) == SettingsTestFormat.keepTogether("10", unit: "g/U"))
        #expect(state.formatCarbRatio(dec("8.5")) == SettingsTestFormat.keepTogether("8.5", unit: "g/U"))
    }

    @Test("The newest ISF test decides the ISF gate, as the newest basal test decides the basal gate") func isfGate() {
        let schedule = [entry(0, 720, 50), entry(720, 1440, 45)]
        let edited = [entry(0, 720, 48), entry(720, 1440, 45)]
        let accurate = record(.isf, .keep, minutesAgo: 60, covered: [entry(0, 720, 50)])
        #expect(SettingsTestSchedule.isfGate(history: [], current: schedule) == .noAccurateTest)
        #expect(
            SettingsTestSchedule
                .isfGate(history: [accurate], current: schedule) == .ready(lastAccurate: accurate.completedAt)
        )
        #expect(SettingsTestSchedule.isfGate(history: [accurate], current: edited) == .changedSince(accurate.completedAt))
        // Only the newest ISF test counts, and other kinds don't.
        let tooLow = record(.isf, .increase, minutesAgo: 10, covered: [entry(0, 720, 50)])
        #expect(
            SettingsTestSchedule.isfGate(history: [tooLow, accurate], current: schedule)
                == .lastWasNot(.increase, tooLow.completedAt)
        )
        let basal = record(.basal, .increase, minutesAgo: 5, covered: nil)
        #expect(
            SettingsTestSchedule.isfGate(history: [basal, accurate], current: schedule)
                == .ready(lastAccurate: accurate.completedAt)
        )
        // Saved before schedules were kept: it can't vouch for the schedule.
        let legacy = record(.isf, .keep, minutesAgo: 10, covered: nil)
        #expect(SettingsTestSchedule.isfGate(history: [legacy], current: schedule) == .noAccurateTest)
    }

    @Test(
        "The carb ratio row warns in the Check screen's words, never locks, and goes while a test runs"
    ) @MainActor func gateNote() {
        #expect(SettingsTestKind.carbRatioGateNote(for: .ready(lastAccurate: now), now: now, locale: english) == nil)
        let past = now.addingTimeInterval(-3 * 86400)
        let gates: [SettingsTestSchedule.ISFGate] = [
            .noAccurateTest, .changedSince(past), .lastWasNot(.increase, past), .lastWasNot(.decrease, past)
        ]
        for gate in gates {
            #expect(
                SettingsTestKind.carbRatioGateNote(for: gate, now: now, locale: english)
                    == "\(gate.text(now: now, locale: english)). You can still start."
            )
        }
        #expect(
            SettingsTestKind.carbRatioGateNote(for: .lastWasNot(.decrease, past), now: now, locale: english)
                == "The last ISF test said ISF looks too high. You can still start."
        )
        #expect(SettingsTestSchedule.ISFGate.ready(lastAccurate: past).text(now: now, locale: english).hasPrefix(
            "Last ISF test looked accurate, "
        ))

        let state = SettingsTest.StateModel()
        #expect(state.carbRatioGateNote == nil)
        state.isfGate = .noAccurateTest
        #expect(state.carbRatioGateNote == "No accurate ISF test yet. You can still start.")
        #expect(state.screen(for: .carbRatio) == .carbRatioTest)
        state.activeSession = SettingsTestSession(kind: .basal, expiresAt: now, restore: [])
        #expect(state.carbRatioGateNote == nil)
    }

    @Test(
        "The hub hears the carb ratio runner's test reach finished, once, and not the one there as it opened"
    ) func hubHearsFinish() {
        var held = carbRatioTest(.finished)
        held.endReason = .completed
        let carbRatio = CurrentValueSubject<CarbRatioTestRunnerState, Never>(CarbRatioTestRunnerState(test: held))
        var heard = 0
        let subscription = SettingsTest.StateModel.testFinishes(
            isf: nil,
            basal: nil,
            carbRatio: carbRatio.eraseToAnyPublisher()
        ).sink { heard += 1 }
        defer { subscription.cancel() }
        #expect(heard == 0)
        let running = carbRatioTest(.waiting)
        carbRatio.send(CarbRatioTestRunnerState(test: running))
        #expect(heard == 0)
        var done = running
        done.phase = .finished
        carbRatio.send(CarbRatioTestRunnerState(test: done))
        #expect(heard == 1)
        carbRatio.send(CarbRatioTestRunnerState(test: done, doseIOB: nil))
        #expect(heard == 1)
        carbRatio.send(CarbRatioTestRunnerState())
        #expect(heard == 1)
    }
}
