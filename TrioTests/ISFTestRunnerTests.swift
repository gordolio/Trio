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

@Suite("ISF test runner", .serialized, .settingsTestFiles) struct ISFTestRunnerTests {
    typealias Withdrawal = RecordingSettingsTestNotifier.Withdrawal

    private static let statePath = "trio/isf_test_state.json"
    private let minute: TimeInterval = 60
    private let hour: TimeInterval = 3600

    /// The service with the ISF runner, and the fakes they share.
    private struct Rig {
        let harness: SettingsTestHarness
        let data: FakeSettingsTestData

        var service: BaseSettingsTestService { harness.service }
        var runner: ISFTestRunner { harness.service.isfRunner as! ISFTestRunner }
        var settings: FakeSettingsManager { harness.settings }
        var storage: FileStorage { harness.storage }
        var notifier: RecordingSettingsTestNotifier { harness.notifier }
    }

    /// Writes `test` (and anything `beforeStart` writes) before the service and its runner are made, as a launch finds
    /// them.
    private func makeRig(
        test: ISFTestState?,
        session: SettingsTestSession?,
        mode: DosingMode = .basalTesting,
        data: FakeSettingsTestData,
        settings: FakeSettingsManager = FakeSettingsManager(),
        beforeStart: ((FileStorage) -> Void)? = nil
    ) -> Rig {
        let harness = makeTestService(
            mode: mode,
            existing: session,
            data: data,
            settings: settings,
            beforeStart: { storage in
                if let test { storage.save(test, as: Self.statePath) }
                beforeStart?(storage)
            },
            runners: { context, notifier in
                [ISFTestRunner(
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
        for path in [
            "trio/settings_test_session.json",
            "trio/settings_test_history.json",
            "trio/settings_test_last_end.json",
            Self.statePath
        ] {
            storage.remove(path)
        }
    }

    // MARK: - Fixtures

    /// The settings the tests run on: ISF 50 and target 100 all day, a carb ratio of 10, nothing on board, and a pump
    /// delivering its scheduled basal.
    private func isfData() -> FakeSettingsTestData {
        let data = FakeSettingsTestData()
        data.isfSchedule = [SettingsTestScheduleEntry(startMinutes: 0, endMinutes: 1440, value: 50)]
        data.targetSchedule = [SettingsTestScheduleEntry(startMinutes: 0, endMinutes: 1440, value: 100)]
        data.carbRatio = 10
        data.iob = 0
        data.deliveryState = .delivering
        return data
    }

    /// Begun `startedAgo` ago from Closed Loop, at 210 mg/dL, on target 100, ISF 50 and CR 10, with its session.
    private func settlingTest(startedAgo: TimeInterval) -> ISFTestState {
        var state = ISFTestState(
            phase: .settling,
            startedAt: Date().addingTimeInterval(-startedAgo),
            previousMode: .closed,
            isf: 50,
            target: 100,
            carbRatio: 10
        )
        state.sessionID = UUID()
        state.bolusIncrement = Decimal(string: "0.05")
        state.expectedDose = Decimal(string: "2.2")
        state.iobLine = Decimal(string: "0.11")
        state.plannedPhase = .dosing
        return state
    }

    /// Settled `settledAgo` ago, 20 minutes after Begin, on the Dose step.
    private func dosingTest(settledAgo: TimeInterval) -> ISFTestState {
        var state = settlingTest(startedAgo: settledAgo + 20 * minute)
        state.phase = .dosing
        state.settledAt = Date().addingTimeInterval(-settledAgo)
        return state
    }

    /// On the Raise step, with one Dex4 tablet's 4 g taken `tabletsAgo` ago from 110 mg/dL, 10 minutes after settling.
    private func raisingTest(tabletsAgo: TimeInterval) -> ISFTestState {
        var state = dosingTest(settledAgo: tabletsAgo + 10 * minute)
        state.phase = .raising
        state.tabletBrand = GlucoseTabletBrand.dex4.rawValue
        state.tabletCarbs = 4
        state.tabletsTakenAt = Date().addingTimeInterval(-tabletsAgo)
        state.tabletsGlucose = 110
        return state
    }

    /// Waiting out the 4 hours from a bolus `bolusAgo` ago, given 10 minutes after settling.
    private func waitingTest(bolusAgo: TimeInterval, units: Decimal = 2, startGlucose: Int = 210) -> ISFTestState {
        var state = dosingTest(settledAgo: bolusAgo + 10 * minute)
        state.phase = .waiting
        state.bolusAt = Date().addingTimeInterval(-bolusAgo)
        state.bolusUnits = units
        state.startGlucose = startGlucose
        return state
    }

    /// The test's session in Basal Testing from Closed Loop, with its bolus window from the end of settling.
    private func session(of test: ISFTestState) -> SettingsTestSession {
        SettingsTestSession(
            id: test.sessionID ?? UUID(),
            kind: .isf,
            startedAt: test.startedAt,
            expiresAt: test.startedAt.addingTimeInterval(7 * hour),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)],
            bolusWindowStart: test.settledAt,
            settles: true
        )
    }

    /// Three CGM readings of `glucose` in the 11 minutes up to a minute before `date`.
    private func readings(_ glucose: Int, before date: Date) -> [BasalTestReading] {
        [11, 6, 1].map { BasalTestReading(date: date.addingTimeInterval(-Double($0) * minute), glucose: glucose) }
    }

    /// A 2 U bolus a minute ago, with everything the Dose step holds the dose for as it should be: 210 mg/dL, a flat
    /// arrow, no carbs and no insulin on board.
    private func goodBolusData() -> (data: FakeSettingsTestData, bolusAt: Date) {
        let data = isfData()
        let bolusAt = Date().addingTimeInterval(-minute)
        data.boluses = [ISFTestBolus(date: bolusAt, units: 2)]
        data.readings = readings(210, before: bolusAt)
        data.arrows = [ISFTestArrowReading(date: bolusAt.addingTimeInterval(-minute), direction: .flat)]
        data.determinations = [ISFTestDetermination(date: bolusAt.addingTimeInterval(-3 * minute), iob: 0, cob: 0)]
        return (data, bolusAt)
    }

    /// A 2.24 U bolus 4 hours and a minute ago at 212 mg/dL, with readings that end at 100 and nothing left on board:
    /// accurate for an ISF of 50 (112 mg/dL ÷ 2.24 U).
    private func completedData() -> (data: FakeSettingsTestData, test: ISFTestState) {
        let test = waitingTest(bolusAgo: 4 * hour + minute, units: Decimal(string: "2.24")!, startGlucose: 212)
        let bolusAt = test.bolusAt!
        let plannedEnd = bolusAt.addingTimeInterval(4 * hour)
        let data = isfData()
        data.boluses = [ISFTestBolus(date: bolusAt, units: Decimal(string: "2.24")!)]
        data.readings = readings(212, before: bolusAt) + readings(100, before: plannedEnd)
        data.determinations = [ISFTestDetermination(date: plannedEnd.addingTimeInterval(-3 * minute), iob: 0, cob: 0)]
        return (data, test)
    }

    /// A test and its session as the ISF screen saved them before the update: the test without `settledAt` or
    /// `pendingEnd`, the session without `settles` or `bolusWindowStart`. Waiting after a 2 U bolus at 210 at `bolusAt`,
    /// or on the Dose step without one.
    private func legacyFiles(startedAt: Date, bolusAt: Date?) throws -> (state: String, session: String) {
        func json(_ value: some Encodable) throws -> String {
            try #require(String(data: JSONCoding.encoder.encode(value), encoding: .utf8))
        }
        let sessionID = UUID()
        var fields = [
            "\"id\" : \"\(UUID().uuidString)\"",
            "\"phase\" : \"\(bolusAt == nil ? "dosing" : "waiting")\"",
            "\"startedAt\" : \(try json(startedAt))",
            "\"previousMode\" : \"closed\"",
            "\"sessionID\" : \"\(sessionID.uuidString)\"",
            "\"isf\" : 50",
            "\"target\" : 100",
            "\"readings\" : [ ]"
        ]
        if let bolusAt {
            fields += ["\"bolusAt\" : \(try json(bolusAt))", "\"bolusUnits\" : 2", "\"startGlucose\" : 210"]
        }
        let session = [
            "\"id\" : \"\(sessionID.uuidString)\"",
            "\"kind\" : \"isf\"",
            "\"startedAt\" : \(try json(startedAt))",
            "\"expiresAt\" : \(try json(startedAt.addingTimeInterval(6 * hour)))",
            "\"restore\" : \(try json([SettingsTestRestoreAction.dosingMode(testMode: .basalTesting, previous: .closed)]))"
        ]
        return ("{\n" + fields.joined(separator: ",\n") + "\n}", "{\n" + session.joined(separator: ",\n") + "\n}")
    }

    /// Begins a test at 210 mg/dL through the runner, so the service made no check of its own at launch and the only
    /// checks are the test's own, then changes it as the runner would have saved it later. The session keeps Begin's
    /// times. For a test that changes the data or sets a read to fail after the rig is made.
    private func beginThenChange(_ rig: Rig, _ change: (inout ISFTestState) -> Void) async throws {
        #expect(await rig.runner.begin(ISFTestBegin(glucose: 210, iob: 0, iobChoice: .wait)) == nil)
        var test = try #require(rig.runner.state.test)
        change(&test)
        await rig.runner.save(test)
    }

    /// The service and runner at the first launch after the update, with `legacyFiles` on disk.
    private func makeLegacyRig(startedAt: Date, bolusAt: Date?, data: FakeSettingsTestData) throws -> Rig {
        let files = try legacyFiles(startedAt: startedAt, bolusAt: bolusAt)
        #expect(!files.state.contains("pendingEnd") && !files.state.contains("settledAt"))
        #expect(!files.session.contains("settles") && !files.session.contains("bolusWindowStart"))
        return makeRig(test: nil, session: nil, data: data, beforeStart: { storage in
            storage.save(files.state, as: Self.statePath)
            storage.save(files.session, as: "trio/settings_test_session.json")
        })
    }

    // MARK: - Begin

    @Test("Begin saves the test, starts its session and switches to Basal Testing") func beginStartsTheTest() async {
        do {
            let rig = makeRig(test: nil, session: nil, mode: .closed, data: isfData())
            defer { cleanUp(rig.storage) }

            #expect(await rig.runner.begin(ISFTestBegin(glucose: 210, iob: 0, iobChoice: .wait)) == nil)
            #expect(rig.service.activeSession?.kind == .isf)
            #expect(rig.settings.settings.dosingMode == .basalTesting)
            let saved = rig.storage.retrieve(Self.statePath, as: ISFTestState.self)
            #expect(saved?.sessionID != nil)
            #expect(saved?.sessionID == rig.service.activeSession?.id)
            #expect(saved?.phase == .settling)
            #expect(saved?.previousMode == .closed)
            #expect(saved?.expectedDose == Decimal(string: "2.2"))
            #expect(saved?.iobLine == Decimal(string: "0.11"))
            #expect(rig.runner.state.test?.id == saved?.id)
            #expect(rig.runner.isRunning)
            // Begin schedules nothing through the notifier, the runner's only route.
            #expect(rig.notifier.center.added.isEmpty)
            // Done with before the next service is made, so nothing of this one's can reach the files it uses.
            await rig.runner.discard()
        }

        // With a basal session already running: refused, nothing saved, the mode left alone.
        let basal = SettingsTestSession(
            kind: .basal,
            expiresAt: Date().addingTimeInterval(hour),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )
        let busy = makeRig(test: nil, session: basal, mode: .basalTesting, data: isfData())
        #expect(await busy.runner.begin(ISFTestBegin(glucose: 210, iob: 0, iobChoice: .wait)) == .otherTestRunning)
        #expect(busy.storage.retrieve(Self.statePath, as: ISFTestState.self) == nil)
        #expect(busy.runner.state.test == nil)
        #expect(busy.service.activeSession?.id == basal.id)
        #expect(busy.settings.settings.dosingMode == .basalTesting)
        cleanUp(busy.storage)
    }

    @Test("Begin is refused in Basal Testing, before anything is saved") func beginRefusedInBasalTesting() async {
        // No session and no test: Basal Testing picked by hand, say. Kept as the usual mode, nothing would turn it off.
        let rig = makeRig(test: nil, session: nil, mode: .basalTesting, data: isfData())
        defer { cleanUp(rig.storage) }

        #expect(await rig.runner.begin(ISFTestBegin(glucose: 210, iob: 0, iobChoice: .wait)) == .basalTestingOn)
        #expect(rig.storage.retrieve(Self.statePath, as: ISFTestState.self) == nil)
        #expect(rig.runner.state.test == nil)
        #expect(rig.service.activeSession == nil)
        #expect(rig.settings.settings.dosingMode == .basalTesting)
        #expect(rig.notifier.withdrawn.isEmpty)
    }

    @Test("A new Begin withdraws the last test's ended notice") func beginWithdrawsTheEndedNotice() async throws {
        // A result left on screen, not cleared with Done.
        var result = waitingTest(bolusAgo: 5 * hour)
        result.phase = .finished
        result.endedAt = result.plannedEnd
        result.endReason = .completed
        result.outcome = .accurate
        let rig = makeRig(test: result, session: nil, mode: .closed, data: isfData())
        defer {
            rig.service.end(kind: .isf)
            cleanUp(rig.storage)
        }

        #expect(await rig.runner.begin(ISFTestBegin(glucose: 210, iob: 0, iobChoice: .wait)) == nil)
        #expect(rig.notifier.withdrawn.contains(Withdrawal(kind: .isf, slot: .ended)))
    }

    @Test("Begin is refused while a test runs, one whose session was lost among them") func beginRefusedWhileRunning() async throws {
        // Lost with Basal Testing still on: the service has no session to refuse with, and a new test would take Basal
        // Testing as its usual mode.
        let running = dosingTest(settledAgo: 10 * minute)
        let rig = makeRig(test: running, session: nil, mode: .basalTesting, data: isfData())
        defer { cleanUp(rig.storage) }

        #expect(await rig.runner.begin(ISFTestBegin(glucose: 210, iob: 0, iobChoice: .wait)) == .otherTestRunning)
        #expect(rig.service.activeSession == nil)
        #expect(rig.runner.state.test?.id == running.id)
        #expect(try #require(rig.storage.retrieve(Self.statePath, as: ISFTestState.self)).id == running.id)
        #expect(rig.settings.settings.dosingMode == .basalTesting)
    }

    // MARK: - Settling

    @Test("Settling ends with the screen closed and says the next step is ready, once") func settlesWithTheScreenClosed() async {
        let test = settlingTest(startedAgo: 20 * minute)
        let data = isfData()
        // Trio's first loop in Basal Testing 5 minutes after Begin, and 3 readings of 210 since. Its latest loop, 2 minutes
        // ago, read no carbs on board, so the Dose step shows the dose.
        data.determinations = [
            ISFTestDetermination(date: test.startedAt.addingTimeInterval(5 * minute), iob: 0, cob: 0),
            ISFTestDetermination(date: Date().addingTimeInterval(-2 * minute), iob: 0, cob: 0)
        ]
        data.readings = [8, 12, 16].map {
            BasalTestReading(date: test.startedAt.addingTimeInterval(Double($0) * minute), glucose: 210)
        }
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .dosing)
        #expect(rig.runner.state.test?.settledAt != nil)
        #expect(rig.service.activeSession?.bolusWindowStart == rig.runner.state.test?.settledAt)
        #expect(rig.runner.state.settling == nil)
        #expect(rig.notifier.posted == [.isfStep(.settledToDose)])
        // Posted on the main thread.
        #expect(rig.notifier.postedOffMain.isEmpty)
        await rig.runner.check()
        #expect(rig.notifier.posted.count == 1)
    }

    @Test(
        "Settling onto a Dose step whose dose insulin on board covers says nothing, then says the dose is ready once it decays"
    ) func settledWithIOBCoveringTheDose() async throws {
        let data = isfData()
        let rig = makeRig(test: nil, session: nil, mode: .closed, data: data)
        defer { cleanUp(rig.storage) }
        let startedAt = Date().addingTimeInterval(-20 * minute)
        try await beginThenChange(rig) { test in
            test.startedAt = startedAt
            test.iobHandling = .count
        }
        // 2.5 U on board, counted, over the docs' 2.2 U correction from 210: the Dose step is a dead end, Cancel only.
        let onBoard = Decimal(string: "2.5")!
        data.iob = onBoard
        data.determinations = [
            ISFTestDetermination(date: startedAt.addingTimeInterval(5 * minute), iob: onBoard, cob: 0),
            ISFTestDetermination(date: Date().addingTimeInterval(-2 * minute), iob: onBoard, cob: 0)
        ]
        data.readings = [8, 12, 16].map {
            BasalTestReading(date: startedAt.addingTimeInterval(Double($0) * minute), glucose: 210)
        }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .dosing)
        #expect(rig.runner.state.doseIOB == onBoard)
        #expect(rig.notifier.posted.isEmpty)
        await rig.runner.check()
        #expect(rig.notifier.posted.isEmpty)

        // Insulin on board decays to 0.5 U: the Dose step shows 1.70 U, and the notice it owed goes now, once.
        let decayed = Decimal(string: "0.5")!
        data.iob = decayed
        data.determinations.append(ISFTestDetermination(date: Date().addingTimeInterval(-minute), iob: decayed, cob: 0))
        await rig.runner.check()
        #expect(rig.notifier.posted == [.isfStep(.settledToDose)])
        // Posted on the main thread.
        #expect(rig.notifier.postedOffMain.isEmpty)
        await rig.runner.check()
        #expect(rig.notifier.posted.count == 1)
    }

    @Test("An owed \"ISF Dose Ready\" is never posted once the user moves on from the Dose step") func owedNoticeClearedByAMove(
    ) async throws {
        let data = isfData()
        let rig = makeRig(test: nil, session: nil, mode: .closed, data: data)
        defer { cleanUp(rig.storage) }
        let startedAt = Date().addingTimeInterval(-20 * minute)
        try await beginThenChange(rig) { $0.startedAt = startedAt }
        // Settles onto a Dose step that waits for carbs on board to be read, so "ISF Dose Ready" is owed.
        data.determinations = [ISFTestDetermination(date: startedAt.addingTimeInterval(5 * minute), iob: 0, cob: 0)]
        data.readings = [8, 12, 16].map {
            BasalTestReading(date: startedAt.addingTimeInterval(Double($0) * minute), glucose: 210)
        }
        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .dosing)
        #expect(rig.notifier.posted.isEmpty)

        // The user takes the Raise step instead, and comes back with Skip, Dose Now; meanwhile carbs on board are read, so
        // the Dose step now shows the dose. The user moved on themselves: nothing is said.
        await rig.runner.raiseFirst()
        data.determinations.append(ISFTestDetermination(date: Date().addingTimeInterval(-minute), iob: 0, cob: 0))
        await rig.runner.check()
        await rig.runner.moveToDose()
        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .dosing)
        #expect(rig.notifier.posted.isEmpty)
    }

    @Test(
        "Settling onto a Dose step that then offers tablets says how many to take, and the dose is ready once it shows"
    ) func settledToADoseStepOfferingTablets() async throws {
        let data = isfData()
        let rig = makeRig(test: nil, session: nil, mode: .closed, data: data)
        defer { cleanUp(rig.storage) }
        // Begun at 210, so Begin planned the Dose step. Settling ends 40 minutes in, after a CGM gap: its 3 readings are
        // over 12 minutes old, so it goes to the planned Dose step, which waits for a reading.
        let startedAt = Date().addingTimeInterval(-40 * minute)
        try await beginThenChange(rig) { $0.startedAt = startedAt }
        data.determinations = [
            ISFTestDetermination(date: startedAt.addingTimeInterval(5 * minute), iob: 0, cob: 0),
            ISFTestDetermination(date: Date().addingTimeInterval(-2 * minute), iob: 0, cob: 0)
        ]
        data.readings = [8, 12, 16].map {
            BasalTestReading(date: startedAt.addingTimeInterval(Double($0) * minute), glucose: 210)
        }
        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .dosing)
        #expect(rig.notifier.posted.isEmpty)

        // The CGM is back at 95, under the target of 100: the Dose step offers Take Glucose Tablets.
        data.readings += [11, 6, 1].map { BasalTestReading(date: Date().addingTimeInterval(-Double($0) * minute), glucose: 95) }
        await rig.runner.check()
        #expect(rig.notifier.posted == [.isfStep(.settledToRaise)])
        #expect(rig.notifier.postedOffMain.isEmpty)
        await rig.runner.check()
        #expect(rig.notifier.posted.count == 1)

        // Glucose rises past the target by itself: the Dose step shows a dose, and "ISF Dose Ready", still owed, goes once.
        data.readings += [0.6, 0.4, 0.2].map {
            BasalTestReading(date: Date().addingTimeInterval(-$0 * minute), glucose: 210)
        }
        await rig.runner.check()
        #expect(rig.notifier.posted == [.isfStep(.settledToRaise), .isfStep(.settledToDose)])
        await rig.runner.check()
        #expect(rig.notifier.posted.count == 2)
    }

    @Test(
        "Settling onto a Dose step that waits for a reading says the dose is ready once it shows, once"
    ) func settledWhileAReadingIsAwaited() async throws {
        let data = isfData()
        let rig = makeRig(test: nil, session: nil, mode: .closed, data: data)
        defer { cleanUp(rig.storage) }
        let startedAt = Date().addingTimeInterval(-20 * minute)
        try await beginThenChange(rig) { $0.startedAt = startedAt }
        // Trio's first loop in Basal Testing 5 minutes after Begin and 3 readings of 210 since, but no loop in the last 12
        // minutes: carbs on board are unread, so the Dose step waits.
        data.determinations = [ISFTestDetermination(date: startedAt.addingTimeInterval(5 * minute), iob: 0, cob: 0)]
        data.readings = [8, 12, 16].map {
            BasalTestReading(date: startedAt.addingTimeInterval(Double($0) * minute), glucose: 210)
        }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .dosing)
        #expect(rig.notifier.posted.isEmpty)

        // Trio loops again and reads no carbs on board: the Dose step shows the dose.
        data.determinations.append(ISFTestDetermination(date: Date().addingTimeInterval(-minute), iob: 0, cob: 0))
        await rig.runner.check()
        #expect(rig.notifier.posted == [.isfStep(.settledToDose)])
        // Posted on the main thread.
        #expect(rig.notifier.postedOffMain.isEmpty)
        await rig.runner.check()
        #expect(rig.notifier.posted.count == 1)
    }

    @Test("Settling at 120 moves on to Raise and says the tablets are next") func settlesToRaise() async {
        let test = settlingTest(startedAgo: 20 * minute)
        let data = isfData()
        data.determinations = [ISFTestDetermination(date: test.startedAt.addingTimeInterval(5 * minute), iob: 0, cob: 0)]
        data.readings = [8, 12, 16].map {
            BasalTestReading(date: test.startedAt.addingTimeInterval(Double($0) * minute), glucose: 120)
        }
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .raising)
        #expect(rig.notifier.posted == [.isfStep(.settledToRaise)])
        #expect(rig.notifier.postedOffMain.isEmpty)
    }

    @Test("Checks asked for during one wait for it and for one more, shared") func checksCoalesce() async {
        // Begun here, so the service made no check of its own at launch. Settling reads the determinations once a check.
        let data = isfData()
        let rig = makeRig(test: nil, session: nil, mode: .closed, data: data)
        defer {
            rig.service.end(kind: .isf)
            cleanUp(rig.storage)
        }
        #expect(await rig.runner.begin(ISFTestBegin(glucose: 210, iob: 0, iobChoice: .wait)) == nil)
        let gate = TestGate()
        data.onFetchDeterminations = { await gate.pass() }
        let runner = rig.runner

        let first = Task { await runner.check() }
        #expect(await eventually { gate.waiting == 1 })
        let others = (0 ..< 3).map { _ in Task { await runner.check() } }
        #expect(await eventually { runner.checks.waiting == 3 })
        gate.open()
        await first.value
        for other in others {
            await other.value
        }
        #expect(data.determinationReads == 2)
    }

    // MARK: - The test bolus

    enum Spoiled: CaseIterable {
        case moving
        case carbs
        case iobOverLine
        case unread
        /// The newest reading more than 12 minutes before the bolus: no start glucose, so unread.
        case unreadStale
        case atOrBelowTarget
        case tabletsNotActed

        var condition: ISFTestBolusCondition {
            switch self {
            case .moving: return .glucoseMoving
            case .carbs: return .carbsOnBoard
            case .iobOverLine: return .iobOverLine
            case .unread,
                 .unreadStale: return .unread
            case .atOrBelowTarget: return .atOrBelowTarget
            case .tabletsNotActed: return .tabletsNotActed
            }
        }
    }

    @Test(
        "A spoiled bolus cancels the test from the service, with the screen closed",
        arguments: Spoiled.allCases
    ) func spoiledBolusCancels(_ spoiled: Spoiled) async {
        let test = spoiled == .tabletsNotActed ? raisingTest(tabletsAgo: 5 * minute) : dosingTest(settledAgo: 10 * minute)
        let (data, bolusAt) = goodBolusData()
        // The data for that condition only.
        switch spoiled {
        case .moving:
            data.arrows = [ISFTestArrowReading(date: bolusAt.addingTimeInterval(-minute), direction: .singleUp)]
        case .carbs:
            data.determinations = [ISFTestDetermination(date: bolusAt.addingTimeInterval(-3 * minute), iob: 0, cob: 12)]
        case .iobOverLine:
            data.determinations = [
                ISFTestDetermination(date: bolusAt.addingTimeInterval(-3 * minute), iob: Decimal(string: "0.3"), cob: 0)
            ]
        case .unread:
            data.readings = []
        case .unreadStale:
            data.readings = readings(210, before: bolusAt.addingTimeInterval(-12 * minute))
        case .atOrBelowTarget:
            data.readings = readings(100, before: bolusAt)
        case .tabletsNotActed:
            // One reading since the tablets 5 minutes ago; the dose needs 3 above the glucose they were taken at.
            data.readings = readings(120, before: bolusAt)
        }
        // Set before the service is made, so a check it runs at launch can't come before it.
        let settings = FakeSettingsManager()
        let reader = BaseFileStorage()
        let atModeChange = Seen<ISFTestState>()
        settings.onSettingsChange = { [unowned settings] in
            guard settings.settings.dosingMode != .basalTesting else { return }
            atModeChange.value = reader.retrieve(Self.statePath, as: ISFTestState.self)
        }
        let rig = makeRig(test: test, session: session(of: test), data: data, settings: settings)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        let finished = rig.runner.state.test
        #expect(finished?.phase == .finished)
        #expect(finished?.outcome == .invalid)
        #expect(finished?.interference == spoiled.condition.note)
        #expect(finished?.pendingEnd == nil)
        // Item 3: saved, with the bolus, before the usual mode came back.
        #expect(atModeChange.value?.pendingEnd?.note == spoiled.condition.note)
        #expect(atModeChange.value?.pendingEnd?.byUser == false)
        #expect(atModeChange.value?.bolusAt != nil)
        #expect(rig.service.activeSession == nil)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.service.history(for: .isf).isEmpty)
        #expect(rig.notifier.posted.filter { $0.slot == .ended }.count == 1)
        #expect(rig.notifier.posted.last == .ended(.isf, sentence: spoiled.condition.note, modeBack: true))
        #expect(rig.notifier.withdrawn.contains(Withdrawal(kind: .isf, slot: .step)))
    }

    @Test("A bolus whose conditions held leaves the test running and withdraws the step notice") func goodBolusRuns() async {
        let test = dosingTest(settledAgo: 10 * minute)
        let (data, bolusAt) = goodBolusData()
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .waiting)
        #expect(rig.runner.state.test?.bolusAt == bolusAt)
        #expect(rig.runner.state.test?.bolusUnits == 2)
        #expect(rig.runner.state.test?.startGlucose == 210)
        #expect(rig.runner.state.test?.pendingEnd == nil)
        #expect(rig.settings.settings.dosingMode == .basalTesting)
        #expect(rig.service.activeSession != nil)
        #expect(rig.notifier.withdrawn.contains(Withdrawal(kind: .isf, slot: .step)))
        #expect(rig.notifier.posted.isEmpty)
    }

    @Test("A start glucose that couldn't be read is read again on the next check, not called unread") func startGlucoseReread() async {
        let test = dosingTest(settledAgo: 10 * minute)
        let (data, _) = goodBolusData()
        // The read of the readings at the bolus throws once, then works.
        data.failNext(.glucose)
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        await rig.runner.check()
        #expect(data.thrown(.glucose) == 1)
        #expect(rig.runner.state.test?.phase == .waiting)
        #expect(rig.runner.state.test?.startGlucose == 210)
        #expect(rig.notifier.posted.isEmpty)
        #expect(rig.settings.settings.dosingMode == .basalTesting)
    }

    /// A read the bolus is judged on, besides the start glucose.
    enum ThrownRead: CaseIterable {
        /// The readings since the tablets, which say whether they acted.
        case tabletsReadings
        /// The CGM's arrow at the bolus.
        case arrow
        /// Trio's determinations at the bolus: carbs and insulin on board.
        case determinations

        var read: FakeSettingsTestData.FailingRead {
            switch self {
            case .tabletsReadings: return .glucose
            case .arrow: return .arrow
            case .determinations: return .determinations
            }
        }
    }

    @Test(
        "A read at the bolus that throws decides nothing, and the next check judges the bolus",
        arguments: ThrownRead.allCases
    ) func thrownReadAtTheBolus(_ thrown: ThrownRead) async throws {
        let (data, bolusAt) = goodBolusData()
        let rig = makeRig(test: nil, session: nil, mode: .closed, data: data)
        defer { cleanUp(rig.storage) }
        // Settled 45 minutes ago; tablets taken at 110 half an hour ago acted and the Dose step came next, so the readings
        // since the tablets are read at the bolus too. Every condition holds once read.
        try await beginThenChange(rig) { test in
            test.startedAt = Date().addingTimeInterval(-65 * minute)
            test.settledAt = Date().addingTimeInterval(-45 * minute)
            test.phase = .dosing
            test.tabletBrand = GlucoseTabletBrand.dex4.rawValue
            test.tabletCarbs = 4
            test.tabletsTakenAt = Date().addingTimeInterval(-30 * minute)
            test.tabletsGlucose = 110
        }
        switch thrown {
        case .tabletsReadings:
            // The start glucose's read goes first and works.
            data.failNext(.glucose, afterPassing: 1)
        case .arrow,
             .determinations:
            data.failNext(thrown.read)
        }

        await rig.runner.check()
        #expect(data.thrown(thrown.read) == 1)
        // Nothing decided: the bolus isn't taken as the test's, and nothing ends the test.
        #expect(rig.runner.state.test?.phase == .dosing)
        #expect(rig.runner.state.test?.bolusAt == nil)
        #expect(rig.runner.state.test?.pendingEnd == nil)
        #expect(rig.service.activeSession != nil)
        #expect(rig.settings.settings.dosingMode == .basalTesting)

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .waiting)
        #expect(rig.runner.state.test?.bolusAt == bolusAt)
        #expect(rig.runner.state.test?.pendingEnd == nil)
        #expect(rig.settings.settings.dosingMode == .basalTesting)
        #expect(rig.notifier.posted.filter { $0.slot == .ended }.isEmpty)
    }

    // MARK: - Endings

    @Test(
        "A failed condition saved before a relaunch gives no verdict after the planned end"
    ) func failedConditionSurvivesRelaunch() async throws {
        var test = dosingTest(settledAgo: 5 * hour + 10 * minute)
        let bolusAt = Date().addingTimeInterval(-5 * hour)
        test.bolusAt = bolusAt
        test.bolusUnits = 2
        test.startGlucose = 210
        let pending = ISFTestPendingEnd(
            reason: .interrupted,
            at: bolusAt.addingTimeInterval(minute),
            note: ISFTestBolusCondition.glucoseMoving.note,
            byUser: false
        )
        test.pendingEnd = pending
        // No session: it was lost with Basal Testing still on.
        let rig = makeRig(test: test, session: nil, mode: .basalTesting, data: isfData())
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        let finished = try #require(rig.runner.state.test)
        #expect(finished.phase == .finished)
        #expect(finished.outcome == .invalid)
        #expect(finished.endReason == .interrupted)
        #expect(finished.interference == ISFTestBolusCondition.glucoseMoving.note)
        // The ending saved, not one worked out again at the planned end.
        #expect(abs(try #require(finished.endedAt).timeIntervalSince(pending.at)) < 0.01)
        #expect(finished.pendingEnd == nil)
        #expect(rig.service.history(for: .isf).isEmpty)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.notifier.posted.filter { $0.slot == .ended }.count == 1)
    }

    @Test("A saved ending is finished at the next check, before anything else is read") func pendingEndFinishedFirst() async {
        // Saved with a bolus a minute ago whose conditions, read again now, would hold: a check that judged it again would
        // move on to the 4 hours and leave Basal Testing on.
        var test = dosingTest(settledAgo: 10 * minute)
        let (data, bolusAt) = goodBolusData()
        test.bolusAt = bolusAt
        test.bolusUnits = 2
        test.startGlucose = 210
        test.pendingEnd = ISFTestPendingEnd(
            reason: .interrupted,
            at: bolusAt.addingTimeInterval(30),
            note: ISFTestBolusCondition.glucoseMoving.note,
            byUser: false
        )
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.interference == ISFTestBolusCondition.glucoseMoving.note)
        #expect(rig.service.activeSession == nil)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.notifier.posted.last == .ended(.isf, sentence: ISFTestBolusCondition.glucoseMoving.note, modeBack: true))
    }

    @Test("A test that ran its 4 hours is judged and archived with the screen closed") func finishesInTheService() async {
        let (data, test) = completedData()
        // Set before the service is made, so a check it runs at launch can't come before it.
        let settings = FakeSettingsManager()
        let reader = BaseFileStorage()
        let atModeChange = Seen<ISFTestState>()
        settings.onSettingsChange = { [unowned settings] in
            guard settings.settings.dosingMode != .basalTesting else { return }
            atModeChange.value = reader.retrieve(Self.statePath, as: ISFTestState.self)
        }
        let rig = makeRig(test: test, session: session(of: test), data: data, settings: settings)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        // The ending was saved before the usual mode came back.
        #expect(atModeChange.value?.pendingEnd?.reason == .completed)
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.outcome == .accurate)
        #expect(rig.service.history(for: .isf).count == 1)
        #expect(rig.service.activeSession == nil)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.notifier.posted.last == .finished(.isf))
        #expect(rig.notifier.posted.filter { $0.slot == .ended }.count == 1)
    }

    @Test("A watchdog end is finished by the runner in the same check") func watchdogEndFinished() async {
        let test = waitingTest(bolusAgo: 30 * minute)
        let data = isfData()
        let bolusAt = test.bolusAt!
        data.boluses = [
            ISFTestBolus(date: bolusAt, units: 2),
            ISFTestBolus(date: bolusAt.addingTimeInterval(10 * minute), units: 1)
        ]
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.service.checkSessionAndRunners()
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.interference == "Another bolus was given during the test.")
        #expect(rig.notifier.posted.last?.body == "Another bolus was given during the test. Your usual dosing mode is back.")
        #expect(rig.settings.settings.dosingMode == .closed)
    }

    @Test("End Test while the service finishes keeps one ending") func endTestRacesTheService() async {
        // Past the planned end.
        let (data, test) = completedData()
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }
        let runner = rig.runner

        async let user: Void = runner.endEarly()
        async let watch: Void = runner.check()
        _ = await (user, watch)
        #expect(runner.state.test?.phase == .finished)
        // What this pins is one archive: whichever finish wins, an End Test past the 4 hours completes too, so a second
        // finish would archive again. The claim and the final save's guard both keep it to one. The notice count only
        // bounds it: none (End Test won) and one (the check won) both pass.
        #expect(rig.service.history(for: .isf).count == 1)
        #expect(rig.notifier.posted.filter { $0.slot == .ended }.count <= 1)
    }

    @Test("End Test from the screen posts no notice") func endEarlyPostsNothing() async {
        let test = waitingTest(bolusAgo: hour)
        let data = isfData()
        data.boluses = [ISFTestBolus(date: test.bolusAt!, units: 2)]
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.endEarly()
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.endReason == .endedEarly)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.notifier.posted.filter { $0.slot == .ended }.isEmpty)
        #expect(rig.notifier.withdrawn.contains(Withdrawal(kind: .isf, slot: .step)))
    }

    // MARK: - Raise and dose

    @Test(
        "Raise moves on to Dose by itself once the tablets acted and glucose leveled, and says so once"
    ) func tabletsActedMovesToDose() async {
        let test = raisingTest(tabletsAgo: 20 * minute)
        func data(arrow: BloodGlucose.Direction) -> FakeSettingsTestData {
            let data = isfData()
            let now = Date()
            // 110 when the tablets were taken, then 118, 126 and 128.
            data.readings = [(25, 110), (14, 118), (7, 126), (2, 128)].map {
                BasalTestReading(date: now.addingTimeInterval(-Double($0.0) * minute), glucose: $0.1)
            }
            data.arrows = [ISFTestArrowReading(date: now.addingTimeInterval(-2 * minute), direction: arrow)]
            data.determinations = [ISFTestDetermination(date: now.addingTimeInterval(-3 * minute), iob: 0, cob: 0)]
            return data
        }

        do {
            let rig = makeRig(test: test, session: session(of: test), data: data(arrow: .flat))
            defer { cleanUp(rig.storage) }
            await rig.runner.check()
            #expect(rig.runner.state.test?.phase == .dosing)
            #expect(rig.notifier.posted == [.isfStep(.tabletsActed)])
            // Posted on the main thread.
            #expect(rig.notifier.postedOffMain.isEmpty)
            await rig.runner.check()
            #expect(rig.notifier.posted.count == 1)
            // Done with before the next service is made, so nothing of this one's can reach the files it uses.
            await rig.runner.discard()
        }

        // Still rising: the Raise step waits, and nothing is said.
        let rising = makeRig(test: test, session: session(of: test), data: data(arrow: .singleUp))
        defer { cleanUp(rising.storage) }
        await rising.runner.check()
        #expect(rising.runner.state.test?.phase == .raising)
        #expect(rising.notifier.posted.isEmpty)
    }

    @Test(
        "Tablets that acted with glucose still at or below the target move on to Dose with no notice, until a dose shows"
    ) func tabletsActedWithNoDose() async throws {
        // A target of 130: after tablets at 110, glucose rose to 118, 126 and 128 and leveled off, so they acted, but the
        // mean the dose is worked out from is still under the target. The Dose step offers more tablets, not a dose.
        let data = isfData()
        data.targetSchedule = [SettingsTestScheduleEntry(startMinutes: 0, endMinutes: 1440, value: 130)]
        let rig = makeRig(test: nil, session: nil, mode: .closed, data: data)
        defer { cleanUp(rig.storage) }
        let now = Date()
        try await beginThenChange(rig) { test in
            test.startedAt = now.addingTimeInterval(-60 * minute)
            test.settledAt = now.addingTimeInterval(-40 * minute)
            test.phase = .raising
            test.tabletBrand = GlucoseTabletBrand.dex4.rawValue
            test.tabletCarbs = 4
            test.tabletsTakenAt = now.addingTimeInterval(-20 * minute)
            test.tabletsGlucose = 110
        }
        data.readings = [(25, 110), (14, 118), (7, 126), (2, 128)].map {
            BasalTestReading(date: now.addingTimeInterval(-Double($0.0) * minute), glucose: $0.1)
        }
        data.arrows = [ISFTestArrowReading(date: now.addingTimeInterval(-2 * minute), direction: .flat)]
        data.determinations = [ISFTestDetermination(date: now.addingTimeInterval(-3 * minute), iob: 0, cob: 0)]

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .dosing)
        #expect(rig.notifier.posted.isEmpty)
        await rig.runner.check()
        #expect(rig.notifier.posted.isEmpty)

        // Glucose keeps rising, past the target: the Dose step shows a dose, and the tablets' "ISF Dose Ready" goes, once.
        data.readings += [0.6, 0.4, 0.2].map {
            BasalTestReading(date: Date().addingTimeInterval(-$0 * minute), glucose: 150)
        }
        await rig.runner.check()
        #expect(rig.notifier.posted == [.isfStep(.tabletsActed)])
        #expect(rig.notifier.postedOffMain.isEmpty)
        await rig.runner.check()
        #expect(rig.notifier.posted.count == 1)
    }

    @Test("Work Out the Dose and Skip, Dose Now withdraw the step notice") func moveToDoseWithdrawsTheStepNotice() async {
        let test = raisingTest(tabletsAgo: 5 * minute)
        let rig = makeRig(test: test, session: session(of: test), data: isfData())
        defer { cleanUp(rig.storage) }

        await rig.runner.moveToDose()
        #expect(rig.runner.state.test?.phase == .dosing)
        #expect(rig.notifier.withdrawn.contains(Withdrawal(kind: .isf, slot: .step)))
    }

    @Test(
        "A mode picked during the test ends it with no result, leaves that mode, and the notice doesn't say the usual mode is back"
    ) func modeChanged() async {
        let test = waitingTest(bolusAgo: 30 * minute)
        let data = isfData()
        data.boluses = [ISFTestBolus(date: test.bolusAt!, units: 2)]
        // The user picked Open Loop; the service restores nothing over a mode that isn't Basal Testing.
        let rig = makeRig(test: test, session: session(of: test), mode: .open, data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.outcome == .invalid)
        #expect(rig.runner.state.test?.interference == "The dosing mode changed during the test.")
        #expect(rig.settings.settings.dosingMode == .open)
        #expect(rig.service.activeSession == nil)
        #expect(rig.notifier.posted.last == .ended(.isf, sentence: "The dosing mode changed during the test.", modeBack: false))
    }

    @Test("A check's insulin on board read for the dose isn't put back on a test End Test finished") func doseIOBNotWrittenBack(
    ) async throws {
        let data = isfData()
        data.determinations = [
            ISFTestDetermination(date: Date().addingTimeInterval(-3 * minute), iob: Decimal(string: "0.4"), cob: 0)
        ]
        let rig = makeRig(test: nil, session: nil, mode: .closed, data: data)
        defer { cleanUp(rig.storage) }
        // On the Dose step of a test that counts insulin on board.
        try await beginThenChange(rig) { test in
            test.startedAt = Date().addingTimeInterval(-30 * minute)
            test.settledAt = Date().addingTimeInterval(-10 * minute)
            test.phase = .dosing
            test.iobHandling = .count
        }
        let runner = rig.runner
        await runner.check()
        #expect(runner.state.doseIOB == Decimal(string: "0.4"))

        // A check held in its read of insulin on board; End Test finishes the test meanwhile and clears it.
        let gate = TestGate()
        data.onFetchDeterminations = { await gate.pass() }
        let held = Task { await runner.check() }
        #expect(await eventually { gate.waiting == 1 })
        await runner.endEarly()
        #expect(runner.state.test?.phase == .finished)
        #expect(runner.state.doseIOB == nil)

        gate.open()
        await held.value
        #expect(runner.state.doseIOB == nil)
    }

    @Test("The runner reads insulin on board for a counted dose and publishes it") func doseIOBPublished() async {
        func data() -> FakeSettingsTestData {
            let data = isfData()
            data.determinations = [
                ISFTestDetermination(date: Date().addingTimeInterval(-3 * minute), iob: Decimal(string: "0.4"), cob: 0)
            ]
            return data
        }
        do {
            var counting = dosingTest(settledAgo: 10 * minute)
            counting.iobHandling = .count
            let rig = makeRig(test: counting, session: session(of: counting), data: data())
            defer { cleanUp(rig.storage) }
            await rig.runner.check()
            #expect(rig.runner.state.doseIOB == Decimal(string: "0.4"))
            // Done with before the next service is made, so nothing of this one's can reach the files it uses.
            await rig.runner.discard()
        }

        // A test that waits for insulin on board doesn't take it off the dose, so it isn't read.
        var waiting = dosingTest(settledAgo: 10 * minute)
        waiting.iobHandling = .wait
        let other = makeRig(test: waiting, session: session(of: waiting), data: data())
        defer { cleanUp(other.storage) }
        await other.runner.check()
        #expect(other.runner.state.doseIOB == nil)
    }

    @Test("Count It and Go On after the settling hour counts insulin on board and settles") func countAndGoOn() async {
        var test = settlingTest(startedAgo: 61 * minute)
        test.iobHandling = .wait
        let data = isfData()
        // 0.3 U on board, over the 0.11 U line; Trio's first loop 5 minutes in, and readings of 210 every 10 minutes since.
        data.iob = Decimal(string: "0.3")
        let loopedAt = test.startedAt.addingTimeInterval(5 * minute)
        data.determinations = [ISFTestDetermination(date: loopedAt, iob: Decimal(string: "0.3"), cob: 0)]
        data.readings = [10, 20, 30, 40, 50, 60].map {
            BasalTestReading(date: test.startedAt.addingTimeInterval(Double($0) * minute), glucose: 210)
        }
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .settling)
        #expect(rig.runner.state.settling?.decision == .timeUp(loopedAt: loopedAt))
        // The insulin on board the decision rests on, for the Settle step to show.
        #expect(rig.runner.state.settling?.iob == Decimal(string: "0.3"))
        await rig.runner.countAndGoOn()
        await rig.runner.check()
        #expect(rig.runner.state.test?.iobHandling == .count)
        #expect(rig.runner.state.test?.phase == .dosing)
    }

    // MARK: - Launch

    @Test("A test saved by the screens before the move is finished at launch") func oldStateFinishedAtLaunch() async throws {
        let bolusAt = Date().addingTimeInterval(-5 * hour)
        let data = isfData()
        data.boluses = [ISFTestBolus(date: bolusAt, units: 2)]
        let rig = try makeLegacyRig(startedAt: bolusAt.addingTimeInterval(-30 * minute), bolusAt: bolusAt, data: data)
        defer { cleanUp(rig.storage) }

        #expect(await eventually { rig.runner.state.test?.phase == .finished })
        #expect(await eventually { rig.notifier.posted.last?.slot == .ended })
        #expect(rig.notifier.center.removedPending.contains("Trio.isfTestFinished"))
        #expect(rig.notifier.center.removedDelivered.contains("Trio.isfTestFinished"))
        #expect(rig.settings.settings.dosingMode == .closed)
    }

    @Test("End Test on a test begun before the update withdraws its fixed-time notification") func endEarlyWithdrawsLegacy() async throws {
        let bolusAt = Date().addingTimeInterval(-hour)
        let data = isfData()
        data.boluses = [ISFTestBolus(date: bolusAt, units: 2)]
        let rig = try makeLegacyRig(startedAt: bolusAt.addingTimeInterval(-30 * minute), bolusAt: bolusAt, data: data)
        defer { cleanUp(rig.storage) }
        #expect(rig.runner.state.test?.phase == .waiting)

        await rig.runner.endEarly()
        #expect(rig.runner.state.test?.phase == .finished)
        // Nothing posted, so the withdrawal is the ending's own.
        #expect(rig.notifier.posted.isEmpty)
        #expect(rig.notifier.center.removedPending.contains("Trio.isfTestFinished"))
        #expect(rig.notifier.center.removedDelivered.contains("Trio.isfTestFinished"))
    }

    @Test("Cancel Test on a test begun before the update withdraws its fixed-time notification") func discardWithdrawsLegacy() async throws {
        let data = isfData()
        let rig = try makeLegacyRig(startedAt: Date().addingTimeInterval(-20 * minute), bolusAt: nil, data: data)
        defer { cleanUp(rig.storage) }
        #expect(rig.runner.state.test?.phase == .dosing)

        await rig.runner.discard()
        #expect(rig.runner.state.test == nil)
        #expect(rig.notifier.posted.isEmpty)
        #expect(rig.notifier.center.removedPending.contains("Trio.isfTestFinished"))
        #expect(rig.notifier.center.removedDelivered.contains("Trio.isfTestFinished"))
    }

    // MARK: - The user's endings

    @Test("Cancel Test brings the usual mode back, keeps nothing and withdraws the step notice") func discardKeepsNothing() async {
        let test = dosingTest(settledAgo: 10 * minute)
        let rig = makeRig(test: test, session: session(of: test), data: isfData())
        defer { cleanUp(rig.storage) }

        await rig.runner.discard()
        #expect(rig.runner.state.test == nil)
        #expect(!rig.runner.isRunning)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.service.activeSession == nil)
        #expect(rig.storage.retrieve(Self.statePath, as: ISFTestState.self) == nil)
        #expect(rig.service.history(for: .isf).isEmpty)
        #expect(rig.notifier.withdrawn.contains(Withdrawal(kind: .isf, slot: .step)))
        #expect(rig.notifier.posted.isEmpty)
    }

    @Test("Done clears the result") func acknowledgeClears() async {
        var test = waitingTest(bolusAgo: 5 * hour)
        test.phase = .finished
        test.endedAt = test.plannedEnd
        test.endReason = .completed
        test.outcome = .accurate
        let rig = makeRig(test: test, session: nil, mode: .closed, data: isfData())
        defer { cleanUp(rig.storage) }

        #expect(rig.runner.state.test?.phase == .finished)
        await rig.runner.acknowledgeResult()
        #expect(rig.runner.state.test == nil)
        #expect(!rig.runner.isRunning)
        #expect(rig.storage.retrieve(Self.statePath, as: ISFTestState.self) == nil)
        #expect(rig.notifier.center.removedPending.contains("Trio.isfTestFinished"))
        // Its "Your result is ready" notice too, so it can't open the cleared result later.
        #expect(rig.notifier.withdrawn.contains(Withdrawal(kind: .isf, slot: .ended)))
    }

    @Test("Done does nothing to a test still running") func acknowledgeOnlyFinished() async throws {
        let test = dosingTest(settledAgo: 10 * minute)
        let rig = makeRig(test: test, session: session(of: test), data: isfData())
        defer { cleanUp(rig.storage) }

        await rig.runner.acknowledgeResult()
        #expect(rig.runner.state.test?.id == test.id)
        #expect(rig.runner.isRunning)
        #expect(try #require(rig.storage.retrieve(Self.statePath, as: ISFTestState.self)).id == test.id)
        #expect(rig.service.activeSession != nil)
        #expect(rig.settings.settings.dosingMode == .basalTesting)
    }

    @Test("Cancel Test does nothing to a finished test, whose result Done clears") func discardNotFinished() async throws {
        var test = waitingTest(bolusAgo: 5 * hour)
        test.phase = .finished
        test.endedAt = test.plannedEnd
        test.endReason = .completed
        test.outcome = .accurate
        let rig = makeRig(test: test, session: nil, mode: .closed, data: isfData())
        defer { cleanUp(rig.storage) }

        await rig.runner.discard()
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(try #require(rig.storage.retrieve(Self.statePath, as: ISFTestState.self)).id == test.id)
        #expect(rig.notifier.withdrawn.isEmpty)
    }
}
