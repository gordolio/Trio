import Foundation
import Testing

@testable import Trio

/// What a value was when a closure saw it, read back by the test once it is done.
private final class Seen<Value> {
    private let lock = NSLock()
    private var _value: Value?

    var value: Value? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// An exact decimal: a literal goes through a Double.
private func dec(_ string: String) -> Decimal { Decimal(string: string)! }

// The worked example the tests run on: 10 Dex4 tablets (40 g) at a carb ratio of 10 g/U and an ISF of 50 mg/dL/U, so
// the docs' dose is 4 U, the insulin on board line 4 × 1 ÷ 11 = 0.36 U and the carbs on board line 40 × 1 ÷ 11 = 3.6 g.
// With 4 U acting from 110 mg/dL, the accurate end readings are 92 to 132 (110 − 18.18 to 110 + 22.22).

@Suite("Carb ratio test runner", .serialized, .settingsTestFiles) struct CarbRatioTestRunnerTests {
    typealias Withdrawal = RecordingSettingsTestNotifier.Withdrawal

    private static let statePath = "trio/carb_ratio_test_state.json"
    private let minute: TimeInterval = 60
    private let hour: TimeInterval = 3600

    /// The service with the carb ratio runner, and the fakes they share.
    private struct Rig {
        let harness: SettingsTestHarness
        let data: FakeSettingsTestData

        var service: BaseSettingsTestService { harness.service }
        var runner: CarbRatioTestRunner { harness.service.carbRatioRunner as! CarbRatioTestRunner }
        var settings: FakeSettingsManager { harness.settings }
        var storage: FileStorage { harness.storage }
        var notifier: RecordingSettingsTestNotifier { harness.notifier }
    }

    /// Writes `test` before the service and its runner are made, as a launch finds them.
    private func makeRig(
        test: CarbRatioTestState?,
        session: SettingsTestSession?,
        mode: DosingMode = .basalTesting,
        data: FakeSettingsTestData,
        settings: FakeSettingsManager = FakeSettingsManager(),
        storage: FileStorage = BaseFileStorage()
    ) -> Rig {
        let harness = makeTestService(
            mode: mode,
            existing: session,
            data: data,
            settings: settings,
            storage: storage,
            beforeStart: { storage in
                if let test { storage.save(test, as: Self.statePath) }
            },
            runners: { context, notifier in
                [CarbRatioTestRunner(
                    service: context.service,
                    reads: data,
                    storage: context.storage,
                    settingsManager: context.settingsManager,
                    notifier: notifier
                )]
            }
        )
        return Rig(harness: harness, data: data)
    }

    private func cleanUp(_ storage: FileStorage) {
        SettingsTestFilesTrait.removeFiles(from: storage)
    }

    // MARK: - Fixtures

    private func allDay(_ value: Decimal) -> [SettingsTestScheduleEntry] {
        [SettingsTestScheduleEntry(startMinutes: 0, endMinutes: 1440, value: value)]
    }

    /// A carb ratio of 10, an ISF of 50 and a target of 100 all day, nothing on board, and a pump delivering its
    /// scheduled basal.
    private func crData() -> FakeSettingsTestData {
        let data = FakeSettingsTestData()
        data.isfSchedule = allDay(50)
        data.targetSchedule = allDay(100)
        data.carbRatio = 10
        data.carbRatioSchedule = allDay(10)
        data.iob = 0
        data.deliveryState = .delivering
        return data
    }

    /// Begun `startedAgo` ago from Closed Loop with the worked example's tablets, as Begin saves it, with its session ID.
    private func settlingTest(startedAgo: TimeInterval, length: TimeInterval = 4 * 3600) -> CarbRatioTestState {
        var state = CarbRatioTestState(
            phase: .settling,
            startedAt: Date().addingTimeInterval(-startedAgo),
            previousMode: .closed,
            carbRatio: 10,
            isf: 50,
            target: 100,
            bolusIncrement: dec("0.05"),
            length: length,
            tabletBrand: GlucoseTabletBrand.dex4.rawValue,
            tabletCount: 10,
            tabletCarbs: 40,
            expectedDose: 4,
            iobLine: dec("0.36"),
            cobLine: dec("3.6")
        )
        state.sessionID = UUID()
        state.crEntries = allDay(10)
        state.isfEntries = allDay(50)
        state.carbsAtBegin = []
        return state
    }

    /// Settled `settledAgo` ago, 20 minutes after Begin, on the Dose step.
    private func dosingTest(settledAgo: TimeInterval, length: TimeInterval = 4 * 3600) -> CarbRatioTestState {
        var state = settlingTest(startedAgo: settledAgo + 20 * minute, length: length)
        state.phase = .dosing
        state.settledAt = Date().addingTimeInterval(-settledAgo)
        return state
    }

    /// Waiting out the chosen length from a 4 U bolus `bolusAgo` ago at 110 mg/dL, given 10 minutes after settling, with
    /// no insulin on board at it and the tablets' 40 g logged with it (none when `carbs` is nil).
    private func waitingTest(
        bolusAgo: TimeInterval,
        carbs: Decimal? = 40,
        length: TimeInterval = 4 * 3600
    ) -> CarbRatioTestState {
        var state = dosingTest(settledAgo: bolusAgo + 10 * minute, length: length)
        let bolusAt = Date().addingTimeInterval(-bolusAgo)
        state.phase = .waiting
        state.bolusAt = bolusAt
        state.bolusUnits = 4
        state.startGlucose = 110
        state.iobAtBolus = 0
        if let carbs {
            state.carbs = carbs
            state.carbsAt = bolusAt
            state.carbsID = FakeSettingsTestData.carbEntryID(bolusAt)
        }
        return state
    }

    /// The test's session in Basal Testing from Closed Loop, as Begin starts it, with its bolus window from the end of
    /// settling.
    private func session(of test: CarbRatioTestState) -> SettingsTestSession {
        SettingsTestSession(
            id: test.sessionID ?? UUID(),
            kind: .carbRatio,
            startedAt: test.startedAt,
            expiresAt: test.startedAt.addingTimeInterval(7 * hour),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)],
            bolusWindowStart: test.settledAt,
            settles: true,
            carbsAtBegin: test.carbsAtBegin,
            waitLength: test.length
        )
    }

    /// Three CGM readings of `glucose` in the 11 minutes up to a minute before `date`.
    private func readings(_ glucose: Int, before date: Date) -> [BasalTestReading] {
        [11, 6, 1].map { BasalTestReading(date: date.addingTimeInterval(-Double($0) * minute), glucose: glucose) }
    }

    /// A 4 U bolus a minute ago with the tablets' 40 g logged 2 minutes before it, and everything the Dose step holds the
    /// dose for as it should be at the meal, the carbs: 110 mg/dL, a flat arrow, no insulin on board, and no carbs on
    /// board in Trio's loop before the tablets. By the bolus glucose is rising from them (125, arrow up), and Trio's loop
    /// after them counts them (40 g): neither is the meal's.
    private func goodBolusData() -> (data: FakeSettingsTestData, bolusAt: Date, carbsAt: Date) {
        let data = crData()
        let bolusAt = Date().addingTimeInterval(-minute)
        let carbsAt = bolusAt.addingTimeInterval(-2 * minute)
        data.boluses = [ISFTestBolus(date: bolusAt, units: 4)]
        data.logCarbs(40, at: carbsAt)
        data.readings = readings(110, before: carbsAt)
            + [BasalTestReading(date: bolusAt.addingTimeInterval(-30), glucose: 125, direction: .singleUp)]
        data.arrows = [ISFTestArrowReading(date: carbsAt.addingTimeInterval(-minute), direction: .flat)]
        data.determinations = [
            ISFTestDetermination(date: bolusAt.addingTimeInterval(-4 * minute), iob: 0, cob: 0),
            ISFTestDetermination(date: bolusAt.addingTimeInterval(-30), iob: 0, cob: 40)
        ]
        return (data, bolusAt, carbsAt)
    }

    /// The worked example `length` and a minute after its bolus: readings that start and end at 110, nothing left on
    /// board, the tablets' 40 g logged with the bolus. Accurate: 40 g ÷ 4 U = 10 g/U.
    private func completedData(length: TimeInterval = 4 * 3600) -> (data: FakeSettingsTestData, test: CarbRatioTestState) {
        let test = waitingTest(bolusAgo: length + minute, length: length)
        let bolusAt = test.bolusAt!
        let plannedEnd = bolusAt.addingTimeInterval(length)
        let data = crData()
        data.boluses = [ISFTestBolus(date: bolusAt, units: 4)]
        data.logCarbs(40, at: bolusAt)
        data.readings = readings(110, before: bolusAt) + readings(110, before: plannedEnd)
        data.determinations = [ISFTestDetermination(date: plannedEnd.addingTimeInterval(-3 * minute), iob: 0, cob: 0)]
        return (data, test)
    }

    private func begin(
        count: Int = 10,
        length: TimeInterval = 3 * 3600,
        iob: Decimal? = 0,
        choice: ISFTestIOBHandling = .wait
    ) -> CarbRatioTestBegin {
        CarbRatioTestBegin(brand: .dex4, count: count, length: length, glucose: 110, iob: iob, iobChoice: choice)
    }

    // MARK: - Begin

    @Test(
        "Begin saves the test, then its session, then the test with its session, and only then switches to Basal Testing"
    ) func beginStartsTheTest() async throws {
        let settings = FakeSettingsManager()
        let reader = BaseFileStorage()
        let atModeChange = Seen<(test: CarbRatioTestState?, session: SettingsTestSession?)>()
        settings.onSettingsChange = { [unowned settings] in
            guard settings.settings.dosingMode == .basalTesting else { return }
            atModeChange.value = (
                reader.retrieve(Self.statePath, as: CarbRatioTestState.self),
                reader.retrieve("trio/settings_test_session.json", as: SettingsTestSession.self)
            )
        }
        let data = crData()
        // An entry from this morning, there at Begin, which the test keeps so it doesn't spoil it.
        let morning = Date().addingTimeInterval(-5 * hour)
        data.logCarbs(30, at: morning)
        let rig = makeRig(test: nil, session: nil, mode: .closed, data: data, settings: settings)
        defer { cleanUp(rig.storage) }

        #expect(await rig.runner.begin(begin(length: 3 * hour)) == nil)
        let session = try #require(rig.service.activeSession)
        #expect(session.kind == .carbRatio)
        #expect(session.settles == true)
        #expect(session.waitLength == 3 * hour)
        #expect(session.carbsAtBegin == [FakeSettingsTestData.carbEntryID(morning)])
        // Settling's hour, the 90 minutes for the bolus, the 3 hours and the half hour after them.
        let expiry = session.startedAt.addingTimeInterval(hour + 90 * minute + 3 * hour + 30 * minute)
        #expect(abs(session.expiresAt.timeIntervalSince(expiry)) < 1)
        #expect(rig.settings.settings.dosingMode == .basalTesting)

        let test = try #require(rig.runner.state.test)
        #expect(test.phase == .settling)
        #expect(test.previousMode == .closed)
        #expect(test.sessionID == session.id)
        #expect(test.carbRatio == 10)
        #expect(test.isf == 50)
        #expect(test.target == 100)
        #expect(test.length == 3 * hour)
        #expect(test.tabletBrand == GlucoseTabletBrand.dex4.rawValue)
        #expect(test.tabletCount == 10)
        #expect(test.tabletCarbs == 40)
        #expect(test.expectedDose == 4)
        #expect(test.iobLine == dec("0.36"))
        #expect(test.cobLine == dec("3.6"))
        // No choice to make with nothing on board.
        #expect(test.iobHandling == nil)
        #expect(test.crEntries == allDay(10))
        #expect(test.isfEntries == allDay(50))
        #expect(test.carbsAtBegin == session.carbsAtBegin)
        #expect(rig.runner.isRunning)

        // Both on disk, matched to each other, before Basal Testing came on.
        let seen = try #require(atModeChange.value)
        #expect(seen.test?.id == test.id)
        #expect(seen.test?.sessionID == session.id)
        #expect(seen.session?.id == session.id)
        // Begin schedules nothing through the notifier, and withdraws the last test's ended notice.
        #expect(rig.notifier.center.added.isEmpty)
        #expect(rig.notifier.withdrawn == [Withdrawal(kind: .carbRatio, slot: .ended)])
        // And the old wizard's notifications, pending and delivered, so one left from a test of its can't come mid-test.
        for identifier in ["Trio.calibrationReadyToTest", "Trio.calibrationResultsReady"] {
            #expect(rig.notifier.center.removedPending.contains(identifier))
            #expect(rig.notifier.center.removedDelivered.contains(identifier))
        }
        await rig.runner.discard()
    }

    @Test("Begin keeps the docs' 3 to 4 hours, whatever length it is sent") func beginClampsTheLength() async {
        for (sent, kept) in [(2 * hour, 3 * hour), (5 * hour, 4 * hour)] {
            let rig = makeRig(test: nil, session: nil, mode: .closed, data: crData())
            #expect(await rig.runner.begin(begin(length: sent)) == nil)
            #expect(rig.runner.state.test?.length == kept)
            #expect(rig.service.activeSession?.waitLength == kept)
            await rig.runner.discard()
            cleanUp(rig.storage)
        }
    }

    @Test("Over the line, insulin on board offers the choice Begin saves") func beginSavesTheChoice() async {
        let rig = makeRig(test: nil, session: nil, mode: .closed, data: crData())
        defer { cleanUp(rig.storage) }
        // 0.5 U: over the 0.36 U line, under the 4 U dose.
        #expect(await rig.runner.begin(begin(iob: dec("0.5"), choice: .count)) == nil)
        #expect(rig.runner.state.test?.iobHandling == .count)
        await rig.runner.discard()
    }

    /// What Begin refuses, each with the one thing that makes it.
    enum BeginRefusal: String, CaseIterable {
        case basalTestingOn
        case carbsUnreadable
        case adjustment
        case noISF
        case noCarbRatio
        case overMaxBolus
        case overMaxCarbs
        case iobOverDose
        case carbsOnBoard
        case carbRatioUnderMinimum
        case carbRatioUnderMinimumLater
    }

    @Test("Begin is refused, with nothing saved or changed", arguments: BeginRefusal.allCases) func beginRefused(
        _ refusal: BeginRefusal
    ) async {
        let data = crData()
        var mode = DosingMode.closed
        var start = begin()
        let expected: SettingsTestBeginError
        switch refusal {
        case .basalTestingOn:
            mode = .basalTesting
            expected = .basalTestingOn
        case .carbsUnreadable:
            data.failingCarbs = true
            expected = .dataUnreadable(FakeSettingsTestData.Failure().localizedDescription)
        case .adjustment:
            data.activeAdjustment = true
            expected = .adjustmentActive
        case .noISF:
            data.isfSchedule = []
            expected = .settingsUnreadable
        case .noCarbRatio:
            data.carbRatio = nil
            expected = .carbRatioUnreadable
        case .overMaxBolus:
            // 3 U allows 7 tablets (28 g, 2.8 U), not 10.
            data.maxBolusSetting = 3
            expected = .tabletsOverLimits
        case .overMaxCarbs:
            // 30 g allows 7 tablets.
            data.maxCarbsSetting = 30
            expected = .tabletsOverLimits
        case .iobOverDose:
            // More than the whole 4 U dose.
            start.iob = dec("4.5")
            expected = .iobOverDose
        case .carbsOnBoard:
            // 3.6 g from Trio's latest loop: at the line.
            data.determinations = [ISFTestDetermination(date: Date().addingTimeInterval(-2 * minute), iob: 0, cob: dec("3.6"))]
            expected = .carbsOnBoard
        case .carbRatioUnderMinimum:
            // 1.9 g/U: a 1 g/U step under it is under the docs' 1.0 g/U.
            data.carbRatio = dec("1.9")
            data.carbRatioSchedule = allDay(dec("1.9"))
            expected = .carbRatioUnderMinimum
        case .carbRatioUnderMinimumLater:
            // The ratio now reads 10 g/U, but the schedule Begin keeps for the hours a bolus could come at has 1.5 g/U.
            data.carbRatioSchedule = allDay(dec("1.5"))
            expected = .carbRatioUnderMinimum
        }
        let rig = makeRig(test: nil, session: nil, mode: mode, data: data)
        defer { cleanUp(rig.storage) }

        #expect(await rig.runner.begin(start) == expected)
        #expect(rig.storage.retrieve(Self.statePath, as: CarbRatioTestState.self) == nil)
        #expect(rig.runner.state.test == nil)
        #expect(!rig.runner.isRunning)
        #expect(rig.service.activeSession == nil)
        #expect(rig.settings.settings.dosingMode == mode)
        #expect(rig.notifier.withdrawn.isEmpty)
    }

    @Test("Begin is refused while another test's session runs") func beginRefusedWhileAnotherRuns() async {
        let isf = SettingsTestSession(
            kind: .isf,
            expiresAt: Date().addingTimeInterval(hour),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )
        let rig = makeRig(test: nil, session: isf, mode: .closed, data: crData())
        defer { cleanUp(rig.storage) }

        #expect(await rig.runner.begin(begin()) == .otherTestRunning)
        #expect(rig.runner.state.test == nil)
        #expect(rig.service.activeSession?.id == isf.id)
        #expect(rig.settings.settings.dosingMode == .closed)
    }

    @Test(
        "Begin is refused, with nothing changed, when the session or the test isn't saved",
        arguments: ["trio/settings_test_session.json", "trio/carb_ratio_test_state.json"]
    ) func beginRefusedWhenNotSaved(_ path: String) async {
        let rig = makeRig(
            test: nil,
            session: nil,
            mode: .closed,
            data: crData(),
            storage: FailingSaveFileStorage(failingSaves: [path])
        )
        defer { cleanUp(rig.storage) }

        #expect(await rig.runner.begin(begin()) == .notSaved)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.service.activeSession == nil)
        #expect(rig.runner.state.test == nil)
        #expect(!rig.runner.isRunning)
    }

    // MARK: - Settling

    /// Trio's first loop in Basal Testing 5 minutes after Begin and its latest 2 minutes ago, with nothing on board, and 3
    /// readings of 110 since the first.
    private func settledData(_ test: CarbRatioTestState) -> FakeSettingsTestData {
        let data = crData()
        data.determinations = [
            ISFTestDetermination(date: test.startedAt.addingTimeInterval(5 * minute), iob: 0, cob: 0),
            ISFTestDetermination(date: Date().addingTimeInterval(-2 * minute), iob: 0, cob: 0)
        ]
        data.readings = [8, 12, 16].map {
            BasalTestReading(date: test.startedAt.addingTimeInterval(Double($0) * minute), glucose: 110)
        }
        return data
    }

    @Test("Settling ends with the screen closed and says the dose is ready, once") func settlesWithTheScreenClosed() async {
        let test = settlingTest(startedAgo: 20 * minute)
        let rig = makeRig(test: test, session: session(of: test), data: settledData(test))
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        let settled = rig.runner.state.test
        #expect(settled?.phase == .dosing)
        #expect(settled?.settledAt != nil)
        #expect(rig.service.activeSession?.bolusWindowStart == settled?.settledAt)
        #expect(rig.runner.state.settling == nil)
        // The step offered the dose, so the notice went and nothing is owed.
        #expect(rig.notifier.posted == [.carbRatioStep(.settledToDose)])
        #expect(rig.notifier.postedOffMain.isEmpty)
        #expect(settled?.doseNoticeDue == nil)
        #expect(settled?.doseOfferedAt != nil)
        await rig.runner.check()
        #expect(rig.notifier.posted.count == 1)
    }

    @Test("\"Carb Ratio Dose Ready\" waits for a flat arrow, and goes once it is flat") func doseReadyWaitsForAFlatArrow() async {
        let test = settlingTest(startedAgo: 20 * minute)
        let data = settledData(test)
        let newest = data.readings.last!.date
        data.arrows = [ISFTestArrowReading(date: newest, direction: .singleUp)]
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .dosing)
        #expect(rig.runner.state.test?.doseNoticeDue == true)
        #expect(rig.notifier.posted.isEmpty)

        data.arrows = [ISFTestArrowReading(date: newest, direction: .flat)]
        await rig.runner.check()
        #expect(rig.notifier.posted == [.carbRatioStep(.settledToDose)])
        #expect(rig.runner.state.test?.doseNoticeDue == nil)
    }

    @Test("Settling waits for the tablets' line, and after the hour asks once, then Count It settles") func timeUpAndCountIt() async {
        var test = settlingTest(startedAgo: 61 * minute)
        test.iobHandling = .wait
        let data = crData()
        // 0.5 U on board, over the 0.36 U line; Trio's first loop 5 minutes in, and readings of 110 every 10 minutes.
        data.iob = dec("0.5")
        let loopedAt = test.startedAt.addingTimeInterval(5 * minute)
        data.determinations = [ISFTestDetermination(date: loopedAt, iob: dec("0.5"), cob: 0)]
        data.readings = [10, 20, 30, 40, 50, 60].map {
            BasalTestReading(date: test.startedAt.addingTimeInterval(Double($0) * minute), glucose: 110)
        }
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .settling)
        #expect(rig.runner.state.settling?.decision == .timeUp(loopedAt: loopedAt))
        #expect(rig.runner.state.settling?.iob == dec("0.5"))
        #expect(rig.notifier.posted == [.carbRatioStep(.timeUp)])
        #expect(rig.runner.state.test?.timeUpNoticePosted == true)
        await rig.runner.check()
        #expect(rig.notifier.posted.count == 1)

        await rig.runner.countAndGoOn()
        await rig.runner.check()
        #expect(rig.runner.state.test?.iobHandling == .count)
        #expect(rig.runner.state.test?.phase == .dosing)
        #expect(rig.notifier.withdrawn.contains(Withdrawal(kind: .carbRatio, slot: .step)))
    }

    @Test("Settling's hour up with no loop in Basal Testing ends the test with the step's sentence") func settlingDeadEnd() async {
        let test = settlingTest(startedAgo: 61 * minute)
        let rig = makeRig(test: test, session: session(of: test), data: crData())
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        let sentence = ISFTestEvaluator.deadEndSentence(settling: .noLoop)
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.endReason == .interrupted)
        #expect(rig.runner.state.test?.interference == sentence)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.service.history(for: .carbRatio).isEmpty)
        #expect(rig.notifier.posted.last?.title == "Carb Ratio Test Ended")
    }

    // MARK: - The Dose step

    /// Three level readings of 110, the newest a minute old, and Trio's latest loop 2 minutes ago with nothing on board.
    private func doseStepData() -> FakeSettingsTestData {
        let data = crData()
        data.readings = readings(110, before: Date())
        data.determinations = [ISFTestDetermination(date: Date().addingTimeInterval(-2 * minute), iob: 0, cob: 0)]
        return data
    }

    @Test("A Dose step with no ISF to judge the dose by ends the test with its sentence") func doseDeadEnd() async {
        var test = dosingTest(settledAgo: 10 * minute)
        test.isf = 0
        test.isfEntries = nil
        let rig = makeRig(test: test, session: session(of: test), data: doseStepData())
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.interference == CarbRatioTestNoDose.noSettings.sentence)
        #expect(rig.settings.settings.dosingMode == .closed)
    }

    @Test(
        "Counting insulin on board that covers the dose waits for it to come down, and says the dose is ready once it does"
    ) func countedIOBCoveringTheDoseWaits() async {
        var test = dosingTest(settledAgo: 10 * minute)
        test.iobHandling = .count
        test.doseNoticeDue = true
        let data = doseStepData()
        // 4 U on board covers the 4 U dose.
        data.determinations = [ISFTestDetermination(date: Date().addingTimeInterval(-2 * minute), iob: 4, cob: 0)]
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .dosing)
        #expect(rig.runner.state.doseIOB == 4)
        #expect(rig.notifier.posted.isEmpty)
        #expect(rig.settings.settings.dosingMode == .basalTesting)

        // Down to 1 U: 3 U left to give.
        data.determinations = [ISFTestDetermination(date: Date().addingTimeInterval(-minute), iob: 1, cob: 0)]
        await rig.runner.check()
        #expect(rig.runner.state.doseIOB == 1)
        #expect(rig.notifier.posted == [.carbRatioStep(.settledToDose)])
    }

    @Test(
        "Once the tablets' carbs are logged ahead of the bolus, the Dose step asks for the bolus alone, by 15 minutes after them"
    ) func carbsLoggedAheadOfTheBolus() async throws {
        var test = dosingTest(settledAgo: 10 * minute)
        test.doseNoticeDue = true
        let data = doseStepData()
        // Logged 3 minutes ago; the loop since counts them, and the tablets have set the arrow rising.
        let carbsAt = Date().addingTimeInterval(-3 * minute)
        data.logCarbs(40, at: carbsAt)
        data.arrows = [ISFTestArrowReading(date: data.readings.last!.date, direction: .singleUp)]
        data.determinations = [
            ISFTestDetermination(date: carbsAt.addingTimeInterval(-4 * minute), iob: 0, cob: 0),
            ISFTestDetermination(date: Date().addingTimeInterval(-minute), iob: 0, cob: 40)
        ]
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        let dosing = try #require(rig.runner.state.test)
        #expect(dosing.phase == .dosing)
        #expect(dosing.carbsLoggedAwaitingBolus)
        #expect(dosing.carbs == 40)
        #expect(dosing.bolusDeadline == carbsAt.addingTimeInterval(15 * minute))
        // The rising arrow and the tablets' own carbs on board don't take the bolus back.
        #expect(dosing.doseOfferedAt != nil)
        // The meal has begun: "Carb Ratio Dose Ready" is no longer owed.
        #expect(dosing.doseNoticeDue == nil)
        #expect(rig.notifier.posted.isEmpty)
        #expect(rig.settings.settings.dosingMode == .basalTesting)
    }

    @Test("The tablets' carbs with no bolus in 15 minutes end the test, so the usual dosing covers them") func carbsWithoutBolus(
    ) async throws {
        let test = dosingTest(settledAgo: 30 * minute)
        let data = doseStepData()
        let carbsAt = Date().addingTimeInterval(-16 * minute)
        data.logCarbs(40, at: carbsAt)
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        let finished = try #require(rig.runner.state.test)
        #expect(finished.phase == .finished)
        #expect(finished.outcome == .invalid)
        #expect(finished.interference == CarbRatioTestEvaluator.carbsWithoutBolusNote)
        #expect(abs(try #require(finished.endedAt).timeIntervalSince(carbsAt.addingTimeInterval(15 * minute))) < 0.01)
        #expect(rig.settings.settings.dosingMode == .closed)
        // Its note already says the usual mode is back, so the notice doesn't say it twice.
        #expect(rig.notifier.posted.last?.body == CarbRatioTestEvaluator.carbsWithoutBolusNote)
    }

    @Test(
        "The service's end for a meal not paired, from a runner that hadn't checked, is finished in the half's own words"
    ) func serviceMealUnpaired() async {
        let test = dosingTest(settledAgo: 30 * minute)
        let data = doseStepData()
        data.logCarbs(40, at: Date().addingTimeInterval(-16 * minute))
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.service.checkSessionAndRunners()
        #expect(rig.service.lastEnd()?.cause == .mealUnpaired)
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.interference == CarbRatioTestEvaluator.carbsWithoutBolusNote)
        #expect(rig.settings.settings.dosingMode == .closed)
    }

    // MARK: - The bolus and the tablets' carbs

    @Test(
        "A bolus with the tablets' carbs logged just before it moves on to the wait, keeping the grams logged"
    ) func goodBolusRuns() async {
        let test = dosingTest(settledAgo: 10 * minute)
        let (data, bolusAt, carbsAt) = goodBolusData()
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        let waiting = rig.runner.state.test
        #expect(waiting?.phase == .waiting)
        #expect(waiting?.bolusAt == bolusAt)
        #expect(waiting?.bolusUnits == 4)
        // At the meal, the carbs: not the 125 the tablets had raised it to by the bolus, nor its rising arrow.
        #expect(waiting?.startGlucose == 110)
        #expect(waiting?.iobAtBolus == 0)
        // The 40 g Trio's loop after them counted isn't carbs on board from before.
        #expect(waiting?.carbs == 40)
        #expect(waiting?.carbsAt == carbsAt)
        #expect(waiting?.carbsID == FakeSettingsTestData.carbEntryID(carbsAt))
        #expect(waiting?.pendingEnd == nil)
        #expect(waiting?.plannedEnd == bolusAt.addingTimeInterval(4 * hour))
        // Narrowed to the entry in force at the bolus.
        #expect(waiting?.crEntries == allDay(10))
        #expect(rig.settings.settings.dosingMode == .basalTesting)
        #expect(rig.service.activeSession != nil)
        #expect(rig.notifier.withdrawn.contains(Withdrawal(kind: .carbRatio, slot: .step)))
        #expect(rig.notifier.posted.isEmpty)

        // The watchdog lets the tablets' entry through.
        await rig.service.checkSessionAndRunners()
        #expect(rig.service.activeSession != nil)
        #expect(rig.runner.state.test?.phase == .waiting)
    }

    /// A 4 U bolus a minute ago with no carbs logged yet: 110 mg/dL before it, a flat arrow, nothing on board.
    private func bolusFirstData() -> (data: FakeSettingsTestData, bolusAt: Date) {
        let data = crData()
        let bolusAt = Date().addingTimeInterval(-minute)
        data.boluses = [ISFTestBolus(date: bolusAt, units: 4)]
        data.readings = readings(110, before: bolusAt)
        data.arrows = [ISFTestArrowReading(date: bolusAt.addingTimeInterval(-minute), direction: .flat)]
        data.determinations = [ISFTestDetermination(date: bolusAt.addingTimeInterval(-3 * minute), iob: 0, cob: 0)]
        return (data, bolusAt)
    }

    @Test(
        "A bolus before the tablets' carbs are logged waits for them, then the meal is judged at the bolus"
    ) func carbsLoggedAfterTheBolus() async {
        let test = dosingTest(settledAgo: 20 * minute)
        let (data, bolusAt) = bolusFirstData()
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .waiting)
        #expect(rig.runner.state.test?.carbs == nil)
        #expect(rig.runner.state.test?.iobAtBolus == 0)

        // Logged with the bolus's time.
        data.logCarbs(40, at: bolusAt)
        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .waiting)
        #expect(rig.runner.state.test?.carbs == 40)
        #expect(rig.runner.state.test?.carbsID == FakeSettingsTestData.carbEntryID(bolusAt))
        #expect(rig.runner.state.test?.startGlucose == 110)
        #expect(rig.runner.state.test?.pendingEnd == nil)
        #expect(rig.settings.settings.dosingMode == .basalTesting)
    }

    @Test("Carbs logged other than the tablets' grams end the test at the meal, with no verdict") func gramsDiffer() async {
        let test = dosingTest(settledAgo: 20 * minute)
        let (data, bolusAt) = bolusFirstData()
        data.logCarbs(30, at: bolusAt)
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        let note = CarbRatioTestBolusCondition.carbsDiffer(logged: 30, planned: 40).note
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.outcome == .invalid)
        #expect(rig.runner.state.test?.interference == note)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.service.history(for: .carbRatio).isEmpty)
    }

    @Test(
        "A bolus more than a 1 g/U step from the formula's ends the test at the bolus, and so does one cut short since"
    ) func bolusOffTheFormula() async {
        do {
            // Trio's 80% suggestion, 3.2 U for the formula's 4.
            let test = dosingTest(settledAgo: 20 * minute)
            let (data, bolusAt) = bolusFirstData()
            data.boluses = [ISFTestBolus(date: bolusAt, units: dec("3.2"))]
            data.logCarbs(40, at: bolusAt)
            let rig = makeRig(test: test, session: session(of: test), data: data)
            await rig.runner.check()
            let note = CarbRatioTestBolusCondition.bolusOffFormula(given: dec("3.2"), formula: 4).note
            #expect(rig.runner.state.test?.phase == .finished)
            #expect(rig.runner.state.test?.interference == note)
            #expect(rig.settings.settings.dosingMode == .closed)
            // The note says the usual mode is back, so the notice doesn't say it twice.
            #expect(rig.notifier.posted.last?.body == note)
            cleanUp(rig.storage)
        }

        // Saved at 4 U, written since with the 3 U delivered.
        let test = waitingTest(bolusAgo: hour)
        let data = crData()
        data.boluses = [ISFTestBolus(date: test.bolusAt!, units: 3)]
        data.logCarbs(40, at: test.bolusAt!)
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }
        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.bolusUnits == 3)
        #expect(rig.runner.state.test?.interference == CarbRatioTestBolusCondition.bolusOffFormula(given: 3, formula: 4).note)
    }

    @Test("End Test on a bolus cut short since the last check gives the off-the-formula note") func endEarlyBolusCutShort() async {
        let test = waitingTest(bolusAgo: hour)
        let data = crData()
        data.boluses = [ISFTestBolus(date: test.bolusAt!, units: 3)]
        data.logCarbs(40, at: test.bolusAt!)
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.endEarly()
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.endReason == .interrupted)
        #expect(rig.runner.state.test?.interference == CarbRatioTestBolusCondition.bolusOffFormula(given: 3, formula: 4).note)
    }

    @Test(
        "With its session lost, the runner itself ends a meal not paired, and brings the usual mode back"
    ) func lostSessionPairing(
    ) async throws {
        let test = waitingTest(bolusAgo: 20 * minute, carbs: nil)
        let data = crData()
        data.boluses = [ISFTestBolus(date: test.bolusAt!, units: 4)]
        // No session: lost, with Basal Testing still on, so no watchdog check ends it.
        let rig = makeRig(test: test, session: nil, mode: .basalTesting, data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        let finished = try #require(rig.runner.state.test)
        #expect(finished.phase == .finished)
        #expect(finished.interference == CarbRatioTestEvaluator.bolusWithoutCarbsNote)
        #expect(abs(try #require(finished.endedAt).timeIntervalSince(try #require(test.carbsDeadline))) < 0.01)
        #expect(rig.settings.settings.dosingMode == .closed)
    }

    @Test(
        "A low before the CGM has readings after the meal, or before the carbs were logged, gives no verdict"
    ) func earlyLowNoVerdict() async throws {
        // F5: the bolus 10 minutes ago, Trio's suspend a minute after it on a forecast that saw the bolus alone, the
        // carbs logged a minute later, and no reading since the bolus.
        let test = waitingTest(bolusAgo: 10 * minute, carbs: nil)
        let bolusAt = test.bolusAt!
        let data = crData()
        data.boluses = [ISFTestBolus(date: bolusAt, units: 4)]
        data.logCarbs(40, at: bolusAt.addingTimeInterval(2 * minute))
        data.readings = readings(110, before: bolusAt)
        data.determinations = [ISFTestDetermination(date: bolusAt.addingTimeInterval(-3 * minute), iob: 0, cob: 0)]
        data.basalTestingSuspends(at: bolusAt.addingTimeInterval(minute), startedAt: test.startedAt)
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        let finished = try #require(rig.runner.state.test)
        #expect(finished.phase == .finished)
        #expect(finished.endReason == .low)
        #expect(finished.outcome == .inconclusive)
        #expect(finished.endGlucose == nil)
        #expect(rig.service.history(for: .carbRatio).isEmpty)
        #expect(rig.notifier.posted.last?.title == "Carb Ratio Test Ended")
    }

    @Test(
        "No carbs logged by 15 minutes after the bolus ends the test, dated then, saying to log them"
    ) func noCarbsEndsTheTest() async throws {
        let test = waitingTest(bolusAgo: 20 * minute, carbs: nil)
        let data = crData()
        data.boluses = [ISFTestBolus(date: test.bolusAt!, units: 4)]
        data.readings = readings(110, before: Date())
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        let finished = try #require(rig.runner.state.test)
        #expect(finished.phase == .finished)
        #expect(finished.endReason == .interrupted)
        #expect(finished.outcome == .invalid)
        #expect(finished.interference == CarbRatioTestEvaluator.bolusWithoutCarbsNote)
        let deadline = try #require(test.carbsDeadline)
        #expect(abs(try #require(finished.endedAt).timeIntervalSince(deadline)) < 0.01)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.service.history(for: .carbRatio).isEmpty)
        #expect(
            rig.notifier.posted == [.ended(.carbRatio, sentence: CarbRatioTestEvaluator.bolusWithoutCarbsNote, modeBack: true)]
        )
    }

    @Test("Short of 15 minutes after the bolus, no carbs yet keeps the test running") func noCarbsYetKeepsRunning() async {
        let test = waitingTest(bolusAgo: 10 * minute, carbs: nil)
        let data = crData()
        data.boluses = [ISFTestBolus(date: test.bolusAt!, units: 4)]
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .waiting)
        #expect(rig.settings.settings.dosingMode == .basalTesting)
        #expect(rig.notifier.posted.isEmpty)
    }

    /// A condition the Dose step holds the dose for that didn't hold at the bolus.
    enum Spoiled: CaseIterable {
        case moving
        case carbsOnBoard
        case iobOverLine
        case unread
        case gramsDiffer

        var condition: CarbRatioTestBolusCondition {
            switch self {
            case .moving: return .glucoseMoving
            case .carbsOnBoard: return .carbsOnBoard
            case .iobOverLine: return .iobOverLine
            case .unread: return .unread
            case .gramsDiffer: return .carbsDiffer(logged: 30, planned: 40)
            }
        }
    }

    @Test(
        "A spoiled bolus ends the test with no verdict, its ending saved before the usual mode comes back",
        arguments: Spoiled.allCases
    ) func spoiledBolusEnds(_ spoiled: Spoiled) async {
        let test = dosingTest(settledAgo: 10 * minute)
        let (data, bolusAt, carbsAt) = goodBolusData()
        switch spoiled {
        case .moving:
            data.arrows = [ISFTestArrowReading(date: carbsAt.addingTimeInterval(-minute), direction: .singleUp)]
        case .carbsOnBoard:
            // 3.6 g on board before the tablets: at the line.
            data.determinations[0] = ISFTestDetermination(date: carbsAt.addingTimeInterval(-2 * minute), iob: 0, cob: dec("3.6"))
        case .iobOverLine:
            // 0.4 U on board just before the bolus, over the 0.36 U line, in a test that waits for it.
            data.determinations[1] = ISFTestDetermination(date: bolusAt.addingTimeInterval(-30), iob: dec("0.4"), cob: 40)
        case .unread:
            data.readings = []
        case .gramsDiffer:
            data.carbGrams[carbsAt] = 30
        }
        let settings = FakeSettingsManager()
        let reader = BaseFileStorage()
        let atModeChange = Seen<CarbRatioTestState>()
        settings.onSettingsChange = { [unowned settings] in
            guard settings.settings.dosingMode != .basalTesting else { return }
            atModeChange.value = reader.retrieve(Self.statePath, as: CarbRatioTestState.self)
        }
        let rig = makeRig(test: test, session: session(of: test), data: data, settings: settings)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        let finished = rig.runner.state.test
        #expect(finished?.phase == .finished)
        #expect(finished?.outcome == .invalid)
        #expect(finished?.interference == spoiled.condition.note)
        #expect(atModeChange.value?.pendingEnd?.note == spoiled.condition.note)
        #expect(atModeChange.value?.bolusAt != nil)
        #expect(rig.service.activeSession == nil)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.service.history(for: .carbRatio).isEmpty)
        #expect(rig.notifier.posted.filter { $0.slot == .ended }.count == 1)
        #expect(rig.notifier.posted.last == .ended(.carbRatio, sentence: spoiled.condition.note, modeBack: true))
    }

    // MARK: - What spoils a running test

    @Test("Other carbs logged during the wait end the test, with the screen closed") func extraCarbsEnd() async {
        let test = waitingTest(bolusAgo: hour)
        let data = crData()
        data.boluses = [ISFTestBolus(date: test.bolusAt!, units: 4)]
        data.logCarbs(40, at: test.bolusAt!)
        data.logCarbs(15, at: test.bolusAt!.addingTimeInterval(30 * minute))
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.interference == CarbRatioTestEvaluator.otherCarbsNote)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.service.history(for: .carbRatio).isEmpty)
    }

    @Test(
        "The watchdog's end for other carbs is finished by the runner in the same check, in its own words"
    ) func watchdogCarbsEnd(
    ) async {
        let test = waitingTest(bolusAgo: hour)
        let data = crData()
        data.boluses = [ISFTestBolus(date: test.bolusAt!, units: 4)]
        data.logCarbs(40, at: test.bolusAt!)
        data.logCarbs(15, at: test.bolusAt!.addingTimeInterval(30 * minute))
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.service.checkSessionAndRunners()
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.interference == CarbRatioTestEvaluator.otherCarbsNote)
        #expect(
            rig.notifier.posted.last?
                .body == "Carbs other than the tablets were logged during the test. Your usual dosing mode is back."
        )
        #expect(rig.settings.settings.dosingMode == .closed)
    }

    @Test("A second bolus ends the test") func secondBolusEnds() async {
        let test = waitingTest(bolusAgo: 30 * minute)
        let data = crData()
        data.logCarbs(40, at: test.bolusAt!)
        data.boluses = [
            ISFTestBolus(date: test.bolusAt!, units: 4),
            ISFTestBolus(date: test.bolusAt!.addingTimeInterval(10 * minute), units: 1)
        ]
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.service.checkSessionAndRunners()
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.interference == "Another bolus was given during the test.")
        #expect(rig.settings.settings.dosingMode == .closed)
    }

    @Test("Trio's suspend for a low before the bolus ends the test with no verdict") func lowBeforeTheBolus() async {
        let test = dosingTest(settledAgo: 10 * minute)
        let data = doseStepData()
        data.basalTestingSuspends(at: Date().addingTimeInterval(-5 * minute), startedAt: test.startedAt)
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.endReason == .interrupted)
        #expect(rig.runner.state.test?.interference == "Trio suspended insulin for a low before the dose.")
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.service.history(for: .carbRatio).isEmpty)
    }

    @Test(
        "A low after the bolus at or below the start glucose says the ratio is too low, and above it says nothing",
        arguments: [100, 120]
    ) func lowAfterTheBolus(_ atSuspend: Int) async throws {
        let test = waitingTest(bolusAgo: hour)
        let bolusAt = test.bolusAt!
        let suspendAt = bolusAt.addingTimeInterval(50 * minute)
        let data = crData()
        data.boluses = [ISFTestBolus(date: bolusAt, units: 4)]
        data.logCarbs(40, at: bolusAt)
        data.readings = readings(110, before: bolusAt) + readings(atSuspend, before: suspendAt)
        data.basalTestingSuspends(at: suspendAt, startedAt: test.startedAt)
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        let finished = try #require(rig.runner.state.test)
        #expect(finished.phase == .finished)
        #expect(finished.endReason == .low)
        #expect(finished.endGlucose == atSuspend)
        #expect(rig.settings.settings.dosingMode == .closed)
        if atSuspend <= 110 {
            // 4 U given is no more than 40 ÷ 9 = 4.44 U, rounded up to 4.45.
            #expect(finished.outcome == .tooLow)
            let record = try #require(rig.service.history(for: .carbRatio).first)
            #expect(record.direction == .increase)
            #expect(record.summary == "Trio suspended insulin for a low")
            #expect(rig.notifier.posted.last == .finished(.carbRatio))
        } else {
            #expect(finished.outcome == .inconclusive)
            #expect(CarbRatioTestEvaluator.noVerdict(for: finished) == .forecastSuspend)
            #expect(rig.service.history(for: .carbRatio).isEmpty)
            #expect(rig.notifier.posted.last?.title == "Carb Ratio Test Ended")
        }
    }

    // MARK: - Endings

    @Test(
        "A test that ran its chosen 3 hours is judged and archived with the screen closed, with its record"
    ) func finishesWithItsRecord() async throws {
        let (data, test) = completedData(length: 3 * hour)
        let settings = FakeSettingsManager()
        let reader = BaseFileStorage()
        let atModeChange = Seen<CarbRatioTestState>()
        settings.onSettingsChange = { [unowned settings] in
            guard settings.settings.dosingMode != .basalTesting else { return }
            atModeChange.value = reader.retrieve(Self.statePath, as: CarbRatioTestState.self)
        }
        let rig = makeRig(test: test, session: session(of: test), data: data, settings: settings)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(atModeChange.value?.pendingEnd?.reason == .completed)
        let finished = try #require(rig.runner.state.test)
        #expect(finished.phase == .finished)
        #expect(finished.endReason == .completed)
        #expect(finished.outcome == .accurate)
        #expect(finished.iobAtEnd == 0)
        #expect(finished.endGlucose == 110)
        #expect(rig.service.activeSession == nil)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.notifier.posted == [.finished(.carbRatio)])

        let record = try #require(rig.service.history(for: .carbRatio).first)
        #expect(rig.service.history(for: .carbRatio).count == 1)
        #expect(record.kind == .carbRatio)
        // To the millisecond the state file keeps.
        #expect(abs(record.startedAt.timeIntervalSince(try #require(test.bolusAt))) < 0.01)
        #expect(record.direction == .keep)
        #expect(record.startGlucose == 110)
        #expect(record.endGlucose == 110)
        #expect(record.summary == "Glucose ended about where your carb ratio says")
        #expect(record.coveredEntries == allDay(10))
        #expect(record.bolusUnits == 4)
        #expect(record.testCarbs == 40)
        #expect(record.tabletCarbs == 40)
        #expect(record.iobCounted == 0)
        #expect(record.judgedUnits == 4)
    }

    @Test("Short of its chosen 3 hours the test keeps running") func runsItsLength() async {
        let test = waitingTest(bolusAgo: 3 * hour - 5 * minute, length: 3 * hour)
        let data = crData()
        data.boluses = [ISFTestBolus(date: test.bolusAt!, units: 4)]
        data.logCarbs(40, at: test.bolusAt!)
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .waiting)
        #expect(rig.settings.settings.dosingMode == .basalTesting)
    }

    @Test("End Test from the screen gives no result and posts no notice") func endEarlyPostsNothing() async {
        let test = waitingTest(bolusAgo: hour)
        let data = crData()
        data.boluses = [ISFTestBolus(date: test.bolusAt!, units: 4)]
        data.logCarbs(40, at: test.bolusAt!)
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.endEarly()
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.endReason == .endedEarly)
        #expect(rig.runner.state.test?.outcome == .inconclusive)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.service.history(for: .carbRatio).isEmpty)
        #expect(rig.notifier.posted.isEmpty)
        #expect(rig.notifier.withdrawn.contains(Withdrawal(kind: .carbRatio, slot: .step)))
        #expect(rig.notifier.legacyWithdrawals >= 1)
    }

    @Test("Cancel Test brings the usual mode back and keeps nothing; Done clears a result") func discardAndDone() async throws {
        do {
            let test = dosingTest(settledAgo: 10 * minute)
            let rig = makeRig(test: test, session: session(of: test), data: crData())
            await rig.runner.discard()
            #expect(rig.runner.state.test == nil)
            #expect(!rig.runner.isRunning)
            #expect(rig.settings.settings.dosingMode == .closed)
            #expect(rig.service.activeSession == nil)
            #expect(rig.storage.retrieve(Self.statePath, as: CarbRatioTestState.self) == nil)
            #expect(rig.notifier.withdrawn.contains(Withdrawal(kind: .carbRatio, slot: .step)))
            // Done does nothing without a result.
            await rig.runner.acknowledgeResult()
            #expect(rig.notifier.withdrawn.count == 1)
            cleanUp(rig.storage)
        }

        var result = waitingTest(bolusAgo: 5 * hour)
        result.phase = .finished
        result.endedAt = result.plannedEnd
        result.endReason = .completed
        result.outcome = .accurate
        let rig = makeRig(test: result, session: nil, mode: .closed, data: crData())
        defer { cleanUp(rig.storage) }
        // Cancel Test leaves a result alone.
        await rig.runner.discard()
        #expect(rig.runner.state.test?.phase == .finished)
        await rig.runner.acknowledgeResult()
        #expect(rig.runner.state.test == nil)
        #expect(rig.storage.retrieve(Self.statePath, as: CarbRatioTestState.self) == nil)
        #expect(rig.notifier.withdrawn.contains(Withdrawal(kind: .carbRatio, slot: .ended)))
    }

    @Test("The service gives the carb ratio runner") func serviceGivesTheRunner() {
        let rig = makeRig(test: nil, session: nil, mode: .closed, data: crData())
        defer { cleanUp(rig.storage) }
        #expect(rig.service.carbRatioRunner === rig.runner)
        #expect(rig.service.isfRunner == nil)
    }

    // MARK: - The service's watchdog for a carb ratio test

    /// A carb ratio session begun `age` ago on a whole second, in Basal Testing, settled `settledAfter` its start (nil
    /// while it settles), running `length` after its bolus, with no carb entries there at Begin.
    private func crSession(
        age: TimeInterval,
        settledAfter: TimeInterval? = 20 * 60,
        length: TimeInterval = 3 * 3600
    ) -> SettingsTestSession {
        let startedAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - age).rounded(.down))
        return SettingsTestSession(
            kind: .carbRatio,
            startedAt: startedAt,
            expiresAt: Date().addingTimeInterval(hour),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)],
            bolusWindowStart: settledAfter.map { startedAt.addingTimeInterval($0) },
            settles: true,
            carbsAtBegin: [],
            waitLength: length
        )
    }

    /// The service alone, with `session` found at launch.
    private func watchdog(_ session: SettingsTestSession, data: FakeSettingsTestData) -> SettingsTestHarness {
        makeTestService(mode: .basalTesting, existing: session, data: data)
    }

    @Test("Carbs logged while a carb ratio test settles end it") func watchdogCarbsWhileSettling() async {
        let session = crSession(age: 10 * minute, settledAfter: nil)
        let data = FakeSettingsTestData()
        data.logCarbs(40, at: session.startedAt.addingTimeInterval(5 * minute))
        let harness = watchdog(session, data: data)
        defer { cleanUp(harness.storage) }

        await harness.service.endIfLowOrInterrupted()
        #expect(harness.service.activeSession == nil)
        #expect(harness.settings.settings.dosingMode == .closed)
        #expect(harness.service.lastEnd()?.cause == .carbsLogged)
    }

    @Test(
        "The tablets' carbs logged after settling, before the bolus, keep a carb ratio test running"
    ) func watchdogLetsTheTabletsThrough(
    ) async {
        let session = crSession(age: 30 * minute)
        let data = FakeSettingsTestData()
        data.logCarbs(40, at: session.startedAt.addingTimeInterval(25 * minute))
        let harness = watchdog(session, data: data)
        defer { cleanUp(harness.storage) }

        await harness.service.endIfLowOrInterrupted()
        #expect(harness.service.activeSession?.id == session.id)
        #expect(harness.settings.settings.dosingMode == .basalTesting)
        #expect(harness.service.lastEnd() == nil)
    }

    @Test("The tablets' carbs logged up to 15 minutes after the bolus keep it running") func watchdogCarbsAfterTheBolus() async {
        let session = crSession(age: hour)
        let bolusAt = session.startedAt.addingTimeInterval(30 * minute)
        let data = FakeSettingsTestData()
        data.boluses = [ISFTestBolus(date: bolusAt, units: 4)]
        data.logCarbs(40, at: bolusAt.addingTimeInterval(15 * minute))
        let harness = watchdog(session, data: data)
        defer { cleanUp(harness.storage) }

        await harness.service.endIfLowOrInterrupted()
        #expect(harness.service.activeSession?.id == session.id)
        #expect(harness.settings.settings.dosingMode == .basalTesting)
        #expect(harness.service.lastEnd() == nil)
        harness.service.end(kind: .carbRatio)
    }

    @Test("Another entry after the tablets' carbs ends a carb ratio test") func watchdogSecondCarbEntry() async {
        let session = crSession(age: hour)
        let bolusAt = session.startedAt.addingTimeInterval(30 * minute)
        let data = FakeSettingsTestData()
        data.boluses = [ISFTestBolus(date: bolusAt, units: 4)]
        data.logCarbs(40, at: bolusAt)
        data.logCarbs(10, at: bolusAt.addingTimeInterval(5 * minute))
        let harness = watchdog(session, data: data)
        defer { cleanUp(harness.storage) }

        await harness.service.endIfLowOrInterrupted()
        #expect(harness.service.activeSession == nil)
        #expect(harness.settings.settings.dosingMode == .closed)
        #expect(harness.service.lastEnd()?.cause == .carbsLogged)
    }

    @Test(
        "Carbs logged more than 15 minutes after the bolus end it as a meal not paired, dated 15 minutes after the bolus"
    ) func watchdogLateCarbs() async {
        let session = crSession(age: hour)
        let bolusAt = session.startedAt.addingTimeInterval(30 * minute)
        let data = FakeSettingsTestData()
        data.boluses = [ISFTestBolus(date: bolusAt, units: 4)]
        data.logCarbs(40, at: bolusAt.addingTimeInterval(16 * minute))
        let harness = watchdog(session, data: data)
        defer { cleanUp(harness.storage) }

        await harness.service.endIfLowOrInterrupted()
        #expect(harness.service.activeSession == nil)
        #expect(
            harness.service.lastEnd()
                == SettingsTestEnd(sessionID: session.id, cause: .mealUnpaired, date: bolusAt.addingTimeInterval(15 * minute))
        )
    }

    @Test(
        "The tablets' carbs with no bolus in 15 minutes end a carb ratio test from the watchdog, dated then"
    ) func watchdogCarbsWithoutBolus() async {
        // Settled 20 minutes after Begin; the carbs a minute later; now 16 minutes after them.
        let session = crSession(age: 37 * minute)
        let carbsAt = session.startedAt.addingTimeInterval(21 * minute)
        let data = FakeSettingsTestData()
        data.logCarbs(40, at: carbsAt)
        let harness = watchdog(session, data: data)
        defer { cleanUp(harness.storage) }

        await harness.service.endIfLowOrInterrupted()
        #expect(harness.service.activeSession == nil)
        #expect(harness.settings.settings.dosingMode == .closed)
        #expect(
            harness.service.lastEnd()
                == SettingsTestEnd(sessionID: session.id, cause: .mealUnpaired, date: carbsAt.addingTimeInterval(15 * minute))
        )
    }

    @Test(
        "A bolus with no carbs in 15 minutes ends a carb ratio test from the watchdog, dated then"
    ) func watchdogBolusWithoutCarbs(
    ) async {
        let session = crSession(age: 50 * minute)
        let bolusAt = session.startedAt.addingTimeInterval(30 * minute)
        let data = FakeSettingsTestData()
        data.boluses = [ISFTestBolus(date: bolusAt, units: 4)]
        let harness = watchdog(session, data: data)
        defer { cleanUp(harness.storage) }

        await harness.service.endIfLowOrInterrupted()
        #expect(harness.service.activeSession == nil)
        #expect(
            harness.service.lastEnd()
                == SettingsTestEnd(sessionID: session.id, cause: .mealUnpaired, date: bolusAt.addingTimeInterval(15 * minute))
        )
    }

    @Test("Short of 15 minutes, a half of the meal alone keeps a carb ratio test running") func watchdogHalfMealInTime() async {
        let session = crSession(age: 44 * minute)
        let data = FakeSettingsTestData()
        data.boluses = [ISFTestBolus(date: session.startedAt.addingTimeInterval(30 * minute), units: 4)]
        let harness = watchdog(session, data: data)
        defer { cleanUp(harness.storage) }

        await harness.service.endIfLowOrInterrupted()
        #expect(harness.service.activeSession?.id == session.id)
        #expect(harness.service.lastEnd() == nil)
        harness.service.end(kind: .carbRatio)
    }

    @Test("Carbs that can't be read end a carb ratio test") func watchdogCarbsUnreadable() async {
        let session = crSession(age: 30 * minute)
        let data = FakeSettingsTestData()
        data.failingCarbs = true
        let harness = watchdog(session, data: data)
        defer { cleanUp(harness.storage) }

        await harness.service.endIfLowOrInterrupted()
        #expect(harness.service.activeSession == nil)
        #expect(harness.settings.settings.dosingMode == .closed)
        #expect(harness.service.lastEnd()?.cause == .carbsUnreadable)
    }

    @Test("A second bolus ends a carb ratio test, dated at that bolus") func watchdogSecondBolus() async {
        let session = crSession(age: hour)
        let second = session.startedAt.addingTimeInterval(40 * minute)
        let data = FakeSettingsTestData()
        data.boluses = [
            ISFTestBolus(date: session.startedAt.addingTimeInterval(30 * minute), units: 4),
            ISFTestBolus(date: second, units: 1)
        ]
        // The tablets' carbs with the first, so the meal is paired.
        data.logCarbs(40, at: session.startedAt.addingTimeInterval(30 * minute))
        let harness = watchdog(session, data: data)
        defer { cleanUp(harness.storage) }

        await harness.service.endIfLowOrInterrupted()
        #expect(harness.service.activeSession == nil)
        #expect(harness.service.lastEnd() == SettingsTestEnd(sessionID: session.id, cause: .extraBolus, date: second))
    }

    @Test("No bolus by the dose deadline ends a carb ratio test, dated at the deadline") func watchdogNoBolus() async {
        let session = crSession(age: 20 * minute + 95 * minute)
        let harness = watchdog(session, data: FakeSettingsTestData())
        defer { cleanUp(harness.storage) }

        await harness.service.endIfLowOrInterrupted()
        let deadline = session.startedAt.addingTimeInterval(20 * minute + 90 * minute)
        #expect(harness.service.activeSession == nil)
        #expect(harness.settings.settings.dosingMode == .closed)
        #expect(harness.service.lastEnd() == SettingsTestEnd(sessionID: session.id, cause: .noBolus, date: deadline))
    }

    @Test("A carb ratio test that never settles ends for no bolus at settling's bound") func watchdogNeverSettled() async {
        let session = crSession(age: 151 * minute, settledAfter: nil)
        let harness = watchdog(session, data: FakeSettingsTestData())
        defer { cleanUp(harness.storage) }

        await harness.service.endIfLowOrInterrupted()
        let deadline = session.startedAt.addingTimeInterval(hour + 90 * minute)
        #expect(harness.service.lastEnd() == SettingsTestEnd(sessionID: session.id, cause: .noBolus, date: deadline))
    }

    @Test(
        "Half an hour after a carb ratio test's chosen 3 hours the usual mode comes back, with no reason kept"
    ) func watchdogWaitOver() async {
        // The bolus 30 minutes after Start; the ISF test's 4 hours would keep both running.
        for (pastEnd, ends) in [(minute, true), (-minute, false)] {
            let session = crSession(age: 30 * minute + 3 * hour + 30 * minute + pastEnd, length: 3 * hour)
            let data = FakeSettingsTestData()
            let bolusAt = session.startedAt.addingTimeInterval(30 * minute)
            data.boluses = [ISFTestBolus(date: bolusAt, units: 4)]
            data.logCarbs(40, at: bolusAt)
            let harness = watchdog(session, data: data)

            await harness.service.endIfLowOrInterrupted()
            #expect((harness.service.activeSession == nil) == ends)
            #expect(harness.settings.settings.dosingMode == (ends ? .closed : .basalTesting))
            #expect(harness.service.lastEnd() == nil)
            harness.service.end(kind: .carbRatio)
            cleanUp(harness.storage)
        }
    }

    @Test(
        "A zero temp only Closed Loop asked for as a carb ratio test began isn't its low; one Basal Testing asked for is"
    ) func watchdogSuspendIsSettleAware() async {
        do {
            let session = crSession(age: 10 * minute, settledAfter: nil)
            let data = FakeSettingsTestData()
            // Asked for 30 seconds before Begin, so by a loop still in Closed Loop.
            data.trioSuspends(at: session.startedAt.addingTimeInterval(30))
            let harness = watchdog(session, data: data)
            await harness.service.endIfLowOrInterrupted()
            #expect(harness.service.activeSession?.id == session.id)
            #expect(harness.service.lastEnd() == nil)
            harness.service.end(kind: .carbRatio)
            cleanUp(harness.storage)
        }

        let session = crSession(age: 10 * minute, settledAfter: nil)
        let data = FakeSettingsTestData()
        let suspendAt = session.startedAt.addingTimeInterval(5 * minute)
        data.basalTestingSuspends(at: suspendAt, startedAt: session.startedAt)
        let harness = watchdog(session, data: data)
        defer { cleanUp(harness.storage) }
        await harness.service.endIfLowOrInterrupted()
        #expect(harness.service.activeSession == nil)
        #expect(harness.service.lastEnd() == SettingsTestEnd(sessionID: session.id, cause: .low, date: suspendAt))
    }

    @Test(
        "The bolus window start makes a carb ratio session last its chosen length from there, which survives a relaunch"
    ) func bolusWindowStartUsesTheLength() async throws {
        let harness = makeTestService(mode: .closed)
        defer { cleanUp(harness.storage) }
        let session = try #require(harness.service.begin(
            kind: .carbRatio,
            expiresIn: hour,
            restoring: [.dosingMode(testMode: .basalTesting, previous: .closed)],
            settles: true,
            carbsAtBegin: [],
            waitLength: 3 * hour
        ))
        harness.settings.settings.dosingMode = .basalTesting
        let late = session.startedAt.addingTimeInterval(2 * hour)
        harness.service.setBolusWindowStart(kind: .carbRatio, at: late)
        // The 90 minutes for the bolus, the 3 hours and the half hour after them.
        #expect(harness.service.activeSession?.expiresAt == late.addingTimeInterval(90 * minute + 3 * hour + 30 * minute))
        #expect(harness.service.savedSession()?.waitLength == 3 * hour)
        harness.service.end(kind: .carbRatio)
    }
}
