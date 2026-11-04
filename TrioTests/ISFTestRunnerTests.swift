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
        storage: FileStorage = BaseFileStorage(),
        beforeStart: ((FileStorage) -> Void)? = nil
    ) -> Rig {
        let harness = makeTestService(
            mode: mode,
            existing: session,
            data: data,
            settings: settings,
            storage: storage,
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

    /// Waiting out the 4 hours from a bolus `bolusAgo` ago, given 10 minutes after settling, with no insulin on board at
    /// it, as the bolus check read it.
    private func waitingTest(bolusAgo: TimeInterval, units: Decimal = 2, startGlucose: Int = 210) -> ISFTestState {
        var state = dosingTest(settledAgo: bolusAgo + 10 * minute)
        state.phase = .waiting
        state.bolusAt = Date().addingTimeInterval(-bolusAgo)
        state.bolusUnits = units
        state.startGlucose = startGlucose
        state.iobAtBolus = 0
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
        "Settling onto a Dose step whose dose insulin on board covers ends the test with the step's sentence, saying no dose is ready"
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
        let sentence = "Your insulin on board already covers the formula's correction, so there's no dose to give."
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.interference == sentence)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.notifier.posted == [.ended(.isf, sentence: sentence, modeBack: true)])
        // Posted on the main thread.
        #expect(rig.notifier.postedOffMain.isEmpty)
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
        // Risen from the tablets, which the CGM showed with a rising arrow, and level: 210 for the half hour before the
        // bolus.
        data.readings = [26, 21, 16].map {
            BasalTestReading(
                date: Date().addingTimeInterval(-Double($0) * minute),
                glucose: 210,
                direction: $0 == 26 ? .singleUp : nil
            )
        } + data.readings
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
        let test = raisingTest(tabletsAgo: 40 * minute)
        func data(arrow: BloodGlucose.Direction) -> FakeSettingsTestData {
            let data = isfData()
            let now = Date()
            // 110 when the tablets were taken, then a rise to 146 the CGM showed with a rising arrow, which has stopped: the
            // newest 3-reading mean, 145, is no higher than the one before it.
            data.readings = [(45, 110), (38, 125), (33, 140), (28, 146), (23, 146), (18, 146), (13, 146), (8, 145), (3, 145)]
                .map {
                    BasalTestReading(
                        date: now.addingTimeInterval(-Double($0.0) * minute),
                        glucose: $0.1,
                        direction: $0.0 == 38 || $0.0 == 33 ? .singleUp : nil
                    )
                }
            data.arrows = [ISFTestArrowReading(date: now.addingTimeInterval(-3 * minute), direction: arrow)]
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

        // The arrow still moving: the Raise step waits, and nothing is said.
        let rising = makeRig(test: test, session: session(of: test), data: data(arrow: .singleUp))
        defer { cleanUp(rising.storage) }
        await rising.runner.check()
        #expect(rising.runner.state.test?.phase == .raising)
        #expect(rising.notifier.posted.isEmpty)
    }

    @Test(
        "Tablets that acted with glucose still at or below the target move on to Dose with no notice, until a dose shows"
    ) func tabletsActedWithNoDose() async throws {
        // A target of 130: after tablets at 110, glucose rose to 126 and leveled off, so they acted, but the mean the dose
        // is worked out from is still under the target. The Dose step offers more tablets, not a dose.
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
            test.tabletsTakenAt = now.addingTimeInterval(-40 * minute)
            test.tabletsGlucose = 110
        }
        func set(_ points: [(Double, Int)], rising: Set<Double> = [38, 33]) {
            data.readings = points.map {
                BasalTestReading(
                    date: now.addingTimeInterval(-$0.0 * minute),
                    glucose: $0.1,
                    direction: rising.contains($0.0) ? .singleUp : .flat
                )
            }
            data.arrows = []
        }
        set([(45, 110), (38, 118), (33, 122), (28, 126), (23, 126), (18, 126), (13, 126), (8, 125), (3, 125)])
        data.determinations = [ISFTestDetermination(date: now.addingTimeInterval(-3 * minute), iob: 0, cob: 0)]

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .dosing)
        #expect(rig.notifier.posted.isEmpty)
        await rig.runner.check()
        #expect(rig.notifier.posted.isEmpty)

        // Glucose rises again, past the target, under a rising arrow: the dose is held while the arrow moves.
        set(
            [(45, 110), (38, 118), (33, 122), (28, 126), (23, 126), (18, 126), (13, 140), (8, 150), (3, 150)],
            rising: [38, 33, 3]
        )
        await rig.runner.check()
        #expect(rig.notifier.posted.isEmpty)
        // The arrow is flat again: latched when the step moved on, leveled off holds (fix round 3, N3), so the Dose step
        // shows a dose, and the tablets' "ISF Dose Ready" goes, once.
        set([(45, 110), (38, 118), (33, 122), (28, 126), (23, 126), (18, 126), (13, 140), (8, 150), (3, 150), (1, 150)])
        await rig.runner.check()
        #expect(rig.notifier.posted == [.isfStep(.tabletsActed)])
        #expect(rig.notifier.postedOffMain.isEmpty)
        await rig.runner.check()
        #expect(rig.notifier.posted.count == 1)
    }

    @Test("Skip, Dose Now withdraws the step notice") func moveToDoseWithdrawsTheStepNotice() async {
        // Before the tablets: once they are taken, Skip does nothing (fix round 5, L2).
        var test = dosingTest(settledAgo: 10 * minute)
        test.phase = .raising
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

    // MARK: - Adversarial review 2, part 1

    /// What the Result says when the pump was suspended, alarmed or changed.
    private static let pumpNote = "Your pump was suspended, gave an alarm, or had its site or reservoir changed during the test."

    @Test(
        "Carbs logged during the test but dated before Begin end it; those already there at Begin don't"
    ) func backdatedCarbsEndTheTest() async throws {
        let data = isfData()
        // A meal logged before Begin, eaten 3 hours before it: there at Begin.
        data.carbs = [Date().addingTimeInterval(-3 * hour)]
        let rig = makeRig(test: nil, session: nil, mode: .closed, data: data)
        defer { cleanUp(rig.storage) }
        #expect(await rig.runner.begin(ISFTestBegin(glucose: 210, iob: 0, iobChoice: .wait)) == nil)
        await rig.service.checkSessionAndRunners()
        #expect(rig.runner.state.test?.phase == .settling)
        #expect(rig.service.activeSession != nil)

        // A snack eaten 30 minutes before Begin, logged now with the time it was eaten, as the Wait step asks.
        data.carbs.append(Date().addingTimeInterval(-30 * minute))
        await rig.service.checkSessionAndRunners()
        #expect(rig.service.lastEnd()?.cause == .carbsLogged)
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.outcome == .invalid)
        #expect(rig.runner.state.test?.interference == "Carbs were logged during the test.")
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.notifier.posted.last == .ended(.isf, sentence: "Carbs were logged during the test.", modeBack: true))
    }

    /// The Settle step's dead ends once the hour is up, which offer only Cancel Test.
    enum SettleDeadEnd: CaseIterable {
        case noLoop
        case tooFewReadings
        case tempBasalRunning
    }

    @Test(
        "A Settle step that offers only Cancel Test ends the test, with the sentence it shows and the usual mode back",
        arguments: SettleDeadEnd.allCases
    ) func settleDeadEndEndsTheTest(_ deadEnd: SettleDeadEnd) async {
        let test = settlingTest(startedAgo: 61 * minute)
        let data = isfData()
        let loopedAt = test.startedAt.addingTimeInterval(5 * minute)
        let sentence: String
        switch deadEnd {
        case .noLoop:
            sentence =
                "Trio hasn't looped in Basal Testing yet, so the test can't start. Check your CGM and pump, then begin again."
        case .tooFewReadings:
            data.determinations = [ISFTestDetermination(date: loopedAt, iob: 0, cob: 0)]
            data.readings = [BasalTestReading(date: loopedAt.addingTimeInterval(5 * minute), glucose: 210)]
            sentence =
                "Trio hasn't had enough CGM readings since you began to start the test. Check your CGM, then begin again."
        case .tempBasalRunning:
            data.determinations = [ISFTestDetermination(date: loopedAt, iob: 0, cob: 0)]
            data.readings = [10, 20, 30].map {
                BasalTestReading(date: loopedAt.addingTimeInterval(Double($0) * minute), glucose: 210)
            }
            data.deliveryState = .tempBasal
            // Set on the pump, in the history, and no zero temp a Basal Testing determination asked for (fix round 3, N2).
            data
                .temps =
                [BasalTestTempBasal(date: loopedAt.addingTimeInterval(40 * minute), rate: Decimal(string: "0.5")!, minutes: 60)]
            sentence =
                "A temp basal is still running on your pump, so the test can't start. Cancel it on the pump, then begin again."
        }
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.outcome == .invalid)
        #expect(rig.runner.state.test?.interference == sentence)
        #expect(rig.service.activeSession == nil)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.notifier.posted.last == .ended(.isf, sentence: sentence, modeBack: true))
    }

    /// The Dose step's dead ends, which offer only Cancel Test.
    enum DoseDeadEnd: CaseIterable {
        case carbsOnBoard
        case iobCoversDose
        case atOrBelowTargetWithoutTablets
    }

    @Test(
        "A Dose step that offers only Cancel Test ends the test, with the sentence it shows and the usual mode back",
        arguments: DoseDeadEnd.allCases
    ) func doseDeadEndEndsTheTest(_ deadEnd: DoseDeadEnd) async {
        var test = dosingTest(settledAgo: 10 * minute)
        let data = isfData()
        let now = Date()
        data.readings = readings(210, before: now)
        data.determinations = [ISFTestDetermination(date: now.addingTimeInterval(-2 * minute), iob: 0, cob: 0)]
        let sentence: String
        switch deadEnd {
        case .carbsOnBoard:
            data.determinations = [ISFTestDetermination(date: now.addingTimeInterval(-2 * minute), iob: 0, cob: 20)]
            sentence = "Carbs are on board, so the test can't be judged. The docs test ISF with no carbs on board."
        case .iobCoversDose:
            // Counted, 2.5 U on board covers the docs' 2.2 U correction from 210.
            test.iobHandling = .count
            data.iob = Decimal(string: "2.5")
            data.determinations = [
                ISFTestDetermination(date: now.addingTimeInterval(-2 * minute), iob: Decimal(string: "2.5"), cob: 0)
            ]
            sentence = "Your insulin on board already covers the formula's correction, so there's no dose to give."
        case .atOrBelowTargetWithoutTablets:
            // A target of 160, at or above the docs' 150, so tablets have nothing to aim past.
            test.target = 160
            data.readings = readings(155, before: now)
            sentence = "Your glucose is at or below your target, so the formula gives no dose."
        }
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.outcome == .invalid)
        #expect(rig.runner.state.test?.interference == sentence)
        #expect(rig.service.activeSession == nil)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.notifier.posted.last == .ended(.isf, sentence: sentence, modeBack: true))
    }

    @Test("\"ISF Dose Ready\" waits for a flat arrow, and goes once it is flat") func doseReadyWaitsForAFlatArrow() async {
        let test = settlingTest(startedAgo: 20 * minute)
        let data = isfData()
        data.determinations = [
            ISFTestDetermination(date: test.startedAt.addingTimeInterval(5 * minute), iob: 0, cob: 0),
            ISFTestDetermination(date: Date().addingTimeInterval(-2 * minute), iob: 0, cob: 0)
        ]
        data.readings = [8, 12, 16].map {
            BasalTestReading(date: test.startedAt.addingTimeInterval(Double($0) * minute), glucose: 210)
        }
        // SMBs are off now, and glucose is rising: the Dose step shows the leveling card, with Open Treatments off.
        data.arrows = [ISFTestArrowReading(date: test.startedAt.addingTimeInterval(16 * minute), direction: .singleUp)]
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .dosing)
        #expect(rig.notifier.posted.isEmpty)
        #expect(rig.runner.state.test?.doseNoticeDue == .settled)

        // The arrow flattens: Open Treatments turns on, and the notice goes, once.
        let flatAt = Date().addingTimeInterval(-30)
        data.readings.append(BasalTestReading(date: flatAt, glucose: 210))
        data.arrows.append(ISFTestArrowReading(date: flatAt, direction: .flat))
        await rig.runner.check()
        #expect(rig.notifier.posted == [.isfStep(.settledToDose)])
        await rig.runner.check()
        #expect(rig.notifier.posted.count == 1)
    }

    @Test(
        "\"ISF Dose Ready\" waits for insulin on board under the line for the dose shown"
    ) func doseReadyWaitsForTheDoseLine() async {
        // Begun at 210, so its line is 0.11 U; settling ends at 150, so the dose shown is 1.00 U and its line 0.05 U.
        var test = settlingTest(startedAgo: 20 * minute)
        test.iobHandling = .wait
        let data = isfData()
        data.iob = Decimal(string: "0.08")
        data.determinations = [
            ISFTestDetermination(date: test.startedAt.addingTimeInterval(5 * minute), iob: Decimal(string: "0.08"), cob: 0),
            ISFTestDetermination(date: Date().addingTimeInterval(-2 * minute), iob: Decimal(string: "0.08"), cob: 0)
        ]
        data.readings = [8, 12, 16].map {
            BasalTestReading(date: test.startedAt.addingTimeInterval(Double($0) * minute), glucose: 150)
        }
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .dosing)
        #expect(rig.notifier.posted.isEmpty)

        data.iob = Decimal(string: "0.04")
        await rig.runner.check()
        #expect(rig.notifier.posted == [.isfStep(.settledToDose)])
    }

    @Test(
        "The tablets' \"ISF Dose Ready\" waits until Open Treatments would turn on"
    ) func tabletsActedNoticeWaitsForTheDoseGate() async {
        var test = raisingTest(tabletsAgo: 40 * minute)
        test.iobHandling = .wait
        let data = isfData()
        let now = Date()
        // 110 when the tablets were taken, then a rise to 124 that leveled off: a dose of 0.48 U, whose line is 0.02 U.
        data.readings = [(45, 110), (38, 118), (33, 122), (28, 124), (23, 124), (18, 124), (13, 124), (8, 124), (3, 124)]
            .map {
                BasalTestReading(
                    date: now.addingTimeInterval(-Double($0.0) * minute),
                    glucose: $0.1,
                    direction: $0.0 == 38 ? .fortyFiveUp : nil
                )
            }
        data.arrows = [ISFTestArrowReading(date: now.addingTimeInterval(-3 * minute), direction: .flat)]
        data.determinations = [ISFTestDetermination(date: now.addingTimeInterval(-3 * minute), iob: 0, cob: 0)]
        data.iob = Decimal(string: "0.05")
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .dosing)
        #expect(rig.notifier.posted.isEmpty)

        data.iob = 0
        await rig.runner.check()
        #expect(rig.notifier.posted == [.isfStep(.tabletsActed)])
    }

    @Test(
        "Begin is refused, with nothing changed, when the session or the test isn't saved",
        arguments: ["trio/settings_test_session.json", "trio/isf_test_state.json"]
    ) func beginRefusedWhenNotSaved(_ path: String) async {
        let rig = makeRig(
            test: nil,
            session: nil,
            mode: .closed,
            data: isfData(),
            storage: FailingSaveFileStorage(failingSaves: [path])
        )
        defer { cleanUp(rig.storage) }

        #expect(await rig.runner.begin(ISFTestBegin(glucose: 210, iob: 0, iobChoice: .wait)) == .notSaved)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.service.activeSession == nil)
        #expect(rig.runner.state.test == nil)
        #expect(!rig.runner.isRunning)
    }

    @Test(
        "A test with no session ID brings the usual mode back as it ends, with Basal Testing on and no session running"
    ) func noSessionIDRestoresTheMode() async {
        var test = dosingTest(settledAgo: 10 * minute)
        test.sessionID = nil
        let rig = makeRig(test: test, session: nil, mode: .basalTesting, data: isfData())
        defer { cleanUp(rig.storage) }

        await rig.runner.discard()
        #expect(rig.settings.settings.dosingMode == .closed)
    }

    /// The endings whose note says the usual dosing came back.
    enum ModeBackEnding: CaseIterable {
        case carbsUnreadable
        case modeChangedRestored
    }

    @Test(
        "A note that says the usual dosing came back is worded from the mode in force once the test ended",
        arguments: ModeBackEnding.allCases
    ) func noteFollowsTheMode(_ ending: ModeBackEnding) async throws {
        let test = waitingTest(bolusAgo: 30 * minute)
        let data = isfData()
        data.boluses = [ISFTestBolus(date: test.bolusAt!, units: 2)]
        let sessionID = try #require(test.sessionID)
        let kept: SettingsTestEnd
        let sentence: String
        switch ending {
        case .carbsUnreadable:
            kept = SettingsTestEnd(sessionID: sessionID, cause: .carbsUnreadable, date: Date().addingTimeInterval(-minute))
            sentence = "Trio couldn't read part of the history to check the test, so it can't say what your ISF did."
        case .modeChangedRestored:
            kept = SettingsTestEnd(
                sessionID: sessionID,
                cause: .modeChanged,
                date: Date().addingTimeInterval(-minute),
                modeRestored: true
            )
            sentence = "The dosing mode changed during the test."
        }
        // The service ended the session, but Basal Testing is on: its write of the usual mode didn't last, say.
        let rig = makeRig(test: test, session: nil, mode: .basalTesting, data: data, beforeStart: { storage in
            storage.save(kept, as: "trio/settings_test_last_end.json")
        })
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.settings.settings.dosingMode == .basalTesting)
        #expect(rig.runner.state.test?.interference == sentence)
        #expect(rig.notifier.posted.last == .ended(.isf, sentence: sentence, modeBack: false))
    }

    @Test("Begin keeps the carb entries there then, with the test and its session") func beginKeepsTheCarbs() async {
        let data = isfData()
        let dinner = Date().addingTimeInterval(-3 * hour)
        // More than a day before: not kept, and too old to spoil the test.
        data.carbs = [dinner, Date().addingTimeInterval(-25 * hour)]
        let rig = makeRig(test: nil, session: nil, mode: .closed, data: data)
        defer { cleanUp(rig.storage) }

        #expect(await rig.runner.begin(ISFTestBegin(glucose: 210, iob: 0, iobChoice: .wait)) == nil)
        let kept = [FakeSettingsTestData.carbEntryID(dinner)]
        #expect(rig.runner.state.test?.carbsAtBegin == kept)
        #expect(rig.service.activeSession?.carbsAtBegin == kept)
        #expect(rig.storage.retrieve(Self.statePath, as: ISFTestState.self)?.carbsAtBegin == kept)
        #expect(rig.service.savedSession()?.carbsAtBegin == kept)
        await rig.runner.discard()
    }

    @Test("Begin is refused, with nothing changed, when the carb entries can't be read") func beginRefusedWithoutCarbs() async {
        let data = isfData()
        data.failingCarbs = true
        let rig = makeRig(test: nil, session: nil, mode: .closed, data: data)
        defer { cleanUp(rig.storage) }

        let refusal = await rig.runner.begin(ISFTestBegin(glucose: 210, iob: 0, iobChoice: .wait))
        #expect(refusal == .dataUnreadable(FakeSettingsTestData.Failure().localizedDescription))
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.service.activeSession == nil)
        #expect(rig.runner.state.test == nil)
        #expect(rig.storage.retrieve(Self.statePath, as: ISFTestState.self) == nil)
    }

    @Test("The time-up question isn't a dead end: the test waits for Count It or Cancel") func timeUpQuestionWaits() async {
        var test = settlingTest(startedAgo: 61 * minute)
        test.iobHandling = .wait
        let data = isfData()
        data.iob = Decimal(string: "0.3")
        let loopedAt = test.startedAt.addingTimeInterval(5 * minute)
        data.determinations = [ISFTestDetermination(date: loopedAt, iob: Decimal(string: "0.3"), cob: 0)]
        data.readings = [10, 20, 30].map {
            BasalTestReading(date: loopedAt.addingTimeInterval(Double($0) * minute), glucose: 210)
        }
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.settling?.decision == .timeUp(loopedAt: loopedAt))
        #expect(rig.runner.state.test?.phase == .settling)
        #expect(rig.service.activeSession != nil)
        // Only "ISF Test Waiting", the question's own notice (fix round 5).
        #expect(rig.notifier.posted == [.isfStep(.timeUp)])
    }

    @Test("A Dose step that offers tablets or waits for a reading isn't a dead end") func doseWaysOnAreNoDeadEnds() async {
        // At or below a target tablets can raise glucose past: Take Glucose Tablets.
        do {
            let test = dosingTest(settledAgo: 10 * minute)
            let data = isfData()
            data.readings = readings(95, before: Date())
            data.determinations = [ISFTestDetermination(date: Date().addingTimeInterval(-2 * minute), iob: 0, cob: 0)]
            let rig = makeRig(test: test, session: session(of: test), data: data)
            defer { cleanUp(rig.storage) }
            await rig.runner.check()
            #expect(rig.runner.state.test?.phase == .dosing)
            await rig.runner.discard()
        }
        // No determination in the last 12 minutes: carbs on board unread, so the step waits.
        let test = dosingTest(settledAgo: 10 * minute)
        let data = isfData()
        data.readings = readings(210, before: Date())
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }
        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .dosing)
    }

    // MARK: - Adversarial review 2, part 2

    /// An ISF schedule, in `Calendar.current`'s minutes of the day, that changes from `values.0` to `values.1` at `after`
    /// from `date`, and is `values.0` at `date`.
    private func changingISF(
        at date: Date,
        after: TimeInterval,
        values: (Decimal, Decimal) = (50, 40)
    ) -> [SettingsTestScheduleEntry] {
        func minute(_ date: Date) -> Int {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
        func entry(_ start: Int, _ end: Int, _ value: Decimal) -> SettingsTestScheduleEntry {
            SettingsTestScheduleEntry(startMinutes: start, endMinutes: end, value: value)
        }
        let now = minute(date)
        let change = minute(date.addingTimeInterval(after))
        let entries = change > now
            ? [entry(0, change, values.0), entry(change, 1440, values.1)]
            : [entry(0, change, values.0), entry(change, now, values.1), entry(now, 1440, values.0)]
        return entries.filter { $0.startMinutes < $0.endMinutes }
    }

    @Test(
        "Raise waits while glucose still rises from the tablets, flat arrow or not, and moves on once it stopped rising"
    ) func tabletsWaitUntilLevel() async {
        let test = raisingTest(tabletsAgo: 40 * minute)
        let data = isfData()
        let now = Date()
        func set(_ points: [(Double, Int)]) {
            data.readings = points.map { BasalTestReading(date: now.addingTimeInterval(-$0.0 * minute), glucose: $0.1) }
            data.arrows = data.readings.map { ISFTestArrowReading(date: $0.date, direction: .flat) }
        }
        data.determinations = [ISFTestDetermination(date: now.addingTimeInterval(-3 * minute), iob: 0, cob: 0)]
        // From 110 when they were taken, still rising under a flat arrow: nothing moves and nothing is said (C1).
        set([(38, 112), (33, 118), (28, 124), (23, 130), (18, 136), (13, 140), (8, 143), (3, 145)])
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .raising)
        #expect(rig.notifier.posted.isEmpty)

        // It stopped rising: the newest 3-reading mean (145) is no higher than the one before it (146), and the CGM showed
        // the rise with a rising arrow (fix round 3, R1).
        set([(43, 112), (38, 125), (33, 140), (28, 146), (23, 146), (18, 146), (13, 146), (8, 146), (3, 145)])
        data.readings = data.readings.map {
            let minutesAgo = (Date().timeIntervalSince($0.date) / minute).rounded()
            return minutesAgo == 38 || minutesAgo == 33
                ? BasalTestReading(date: $0.date, glucose: $0.glucose, direction: .singleUp) : $0
        }
        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .dosing)
        #expect(rig.notifier.posted == [.isfStep(.tabletsActed)])
    }

    @Test("A bolus whose 4 hours cover more than one ISF value gives no verdict") func bolusAcrossAnISFChange() async {
        var test = dosingTest(settledAgo: 10 * minute)
        let (data, bolusAt) = goodBolusData()
        // The schedule Begin saved changes from 50 to 40 two hours after the bolus.
        test.coveredEntries = changingISF(at: bolusAt, after: 2 * hour)
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        let finished = rig.runner.state.test
        #expect(finished?.phase == .finished)
        #expect(finished?.outcome == .invalid)
        #expect(finished?.interference == ISFTestBolusCondition.isfChanges.note)
        #expect(rig.service.history(for: .isf).isEmpty)
        #expect(rig.settings.settings.dosingMode == .closed)
    }

    @Test("A CGM gap before the end leaves no end glucose, so no verdict, not one from readings before it") func endGapNoVerdict(
    ) async throws {
        let (data, test) = completedData()
        let bolusAt = try #require(test.bolusAt)
        let plannedEnd = bolusAt.addingTimeInterval(4 * hour)
        // The CGM stopped 70 minutes before the end, at 140, and was back at 100 8 minutes before it, with no backfill.
        data.readings = readings(212, before: bolusAt) + [(70, 140), (65, 140), (8, 100)].map {
            BasalTestReading(date: plannedEnd.addingTimeInterval(-Double($0.0) * minute), glucose: $0.1)
        }
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        let finished = try #require(rig.runner.state.test)
        #expect(finished.phase == .finished)
        #expect(finished.endGlucose == nil)
        #expect(finished.outcome == .inconclusive)
        #expect(ISFTestEvaluator.noVerdict(for: finished) == .noReadings)
        #expect(rig.service.history(for: .isf).isEmpty)
    }

    @Test(
        "A record's ISF entries are the ones fixed at the bolus, not narrowed again at the finish"
    ) func recordEntriesFixedAtTheBolus(
    ) async throws {
        // The 4 hours from a bolus half an hour ago cover two entries of the same ISF, as narrowed at the bolus.
        var test = waitingTest(bolusAgo: 30 * minute)
        let bolusAt = try #require(test.bolusAt)
        let entries = changingISF(at: bolusAt, after: 2 * hour, values: (50, 50))
        test.coveredEntries = entries
        let data = isfData()
        data.boluses = [ISFTestBolus(date: bolusAt, units: 2)]
        // Trio suspended for a low 20 minutes after the bolus, at 95 under the target of 100.
        let suspendAt = bolusAt.addingTimeInterval(20 * minute)
        data.trioSuspends(at: suspendAt)
        data.readings = readings(210, before: bolusAt) + readings(95, before: suspendAt)
        data.determinations = [ISFTestDetermination(date: bolusAt.addingTimeInterval(-3 * minute), iob: 0, cob: 0)]
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.endReason == .low)
        let record = try #require(rig.service.history(for: .isf).first)
        #expect(record.direction == .increase)
        #expect(record.coveredEntries == entries)
    }

    @Test("Wait for It keeps the insulin on board at the bolus, as Count It does") func waitKeepsIOBAtTheBolus() async {
        var test = dosingTest(settledAgo: 10 * minute)
        test.iobHandling = .wait
        let (data, bolusAt) = goodBolusData()
        // 0.10 U on board, under the 0.11 U line for the 2.20 U dose.
        data.determinations = [
            ISFTestDetermination(date: bolusAt.addingTimeInterval(-3 * minute), iob: Decimal(string: "0.1"), cob: 0)
        ]
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .waiting)
        #expect(rig.runner.state.test?.iobAtBolus == Decimal(string: "0.1"))
        #expect(rig.runner.state.test.flatMap(ISFTestEvaluator.givenUnits(of:)) == Decimal(string: "2.1"))
    }

    @Test(
        "\"ISF Test Settled\" waits until the Raise step has a recent reading to count tablets from, and goes once"
    ) func settledToRaiseWaitsForAReading() async {
        var test = settlingTest(startedAgo: 40 * minute)
        test.plannedPhase = .raising
        let data = isfData()
        data.determinations = [ISFTestDetermination(date: test.startedAt.addingTimeInterval(5 * minute), iob: 0, cob: 0)]
        // 3 readings since Trio's first loop, now over 12 minutes old: settling ends on the Raise step Begin planned,
        // which can't count tablets yet.
        data.readings = [8, 12, 16].map {
            BasalTestReading(date: test.startedAt.addingTimeInterval(Double($0) * minute), glucose: 120)
        }
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .raising)
        #expect(rig.notifier.posted.isEmpty)

        // The CGM is back: the step can count the tablets now, and says so, once.
        data.readings += [11, 6, 1].map { BasalTestReading(date: Date().addingTimeInterval(-Double($0) * minute), glucose: 120) }
        await rig.runner.check()
        #expect(rig.notifier.posted == [.isfStep(.settledToRaise)])
        #expect(rig.notifier.postedOffMain.isEmpty)
        await rig.runner.check()
        #expect(rig.notifier.posted.count == 1)
    }

    /// The endings whose note says the usual dosing came back, with no words of their own without it until part 2.
    enum TimeEnding: CaseIterable {
        case settlingTimedOut
        case bolusNotSeen
    }

    @Test(
        "Settling or the bolus not seen in time says the usual dosing came back only when it did",
        arguments: TimeEnding.allCases, [true, false]
    ) func timeEndingNoteFollowsTheMode(_ ending: TimeEnding, _ modeBack: Bool) async throws {
        let test: ISFTestState
        let data = isfData()
        switch ending {
        case .settlingTimedOut:
            test = settlingTest(startedAgo: ISFTest.Config.settleAllowance + ISFTest.Config.doseAllowance + minute)
        case .bolusNotSeen:
            test = waitingTest(bolusAgo: 30 * minute)
            data.boluses = [ISFTestBolus(date: try #require(test.bolusAt), units: 2)]
        }
        let sessionID = try #require(test.sessionID)
        // The service ended the session for no bolus; with the mode not back, its write of the usual mode didn't last.
        let kept = SettingsTestEnd(
            sessionID: sessionID,
            cause: .noBolus,
            date: ending == .settlingTimedOut ? test.noBolusDeadline : Date().addingTimeInterval(-minute)
        )
        let rig = makeRig(
            test: test,
            session: nil,
            mode: modeBack ? .closed : .basalTesting,
            data: data,
            beforeStart: { storage in
                storage.save(kept, as: "trio/settings_test_last_end.json")
            }
        )
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        let sentence: String
        switch (ending, modeBack) {
        case (.settlingTimedOut, true):
            sentence = "Settling didn't finish in time, so Trio brought your usual dosing back. Nothing was saved."
        case (.settlingTimedOut, false): sentence = "Settling didn't finish in time. Nothing was saved."
        case (.bolusNotSeen, true):
            sentence = "Trio didn't see the bolus in time, so it brought your usual dosing back. Nothing was saved."
        case (.bolusNotSeen, false): sentence = "Trio didn't see the bolus in time. Nothing was saved."
        }
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.interference == sentence)
        #expect(rig.notifier.posted.last == .ended(.isf, sentence: sentence, modeBack: modeBack))
    }

    // MARK: - Adversarial review 2, fix round 3

    /// Readings at `(minutes before now, mg/dL)`, each with the CGM's arrow `direction` unless it has its own.
    private func cgm(
        _ points: [(Double, Int)],
        _ direction: BloodGlucose.Direction = .flat,
        rising: Set<Double> = []
    ) -> [BasalTestReading] {
        let now = Date()
        return points.map {
            BasalTestReading(
                date: now.addingTimeInterval(-$0.0 * minute),
                glucose: $0.1,
                direction: rising.contains($0.0) ? .singleUp : direction
            )
        }
    }

    @Test(
        "A +1 mg/dL plateau under flat arrows never unlocks the dose; a rise with a rising arrow, then a plateau, does"
    ) func plateauNeedsARisingArrow() async {
        var test = raisingTest(tabletsAgo: 40 * minute)
        test.tabletsGlucose = 112
        let data = isfData()
        data.determinations = [ISFTestDetermination(date: Date().addingTimeInterval(-3 * minute), iob: 0, cob: 0)]
        // 113 for half an hour after tablets at 112, every arrow flat (R1).
        data.readings = cgm([3, 8, 13, 18, 23, 28, 33, 38].map { ($0, 113) })
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .raising)
        #expect(rig.notifier.posted.isEmpty)

        // The CGM showed the rise with a rising arrow, and glucose has stopped rising.
        data.readings = cgm([(3, 150), (8, 150), (13, 150), (18, 150), (23, 150), (28, 150), (33, 135), (38, 118)], rising: [33])
        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .dosing)
        #expect(rig.notifier.posted == [.isfStep(.tabletsActed)])
    }

    @Test(
        "A Dose step whose ISF change the dose window can't get past ends the test with the step's sentence"
    ) func stuckISFChangeEndsTheTest() async {
        // Settled 10 minutes ago, so the dose deadline is 80 minutes away; the ISF changes 3 hours from now.
        var test = dosingTest(settledAgo: 10 * minute)
        test.coveredEntries = changingISF(at: Date(), after: 3 * hour)
        let data = isfData()
        data.readings = cgm([(11, 210), (6, 210), (1, 210)])
        data.determinations = [ISFTestDetermination(date: Date().addingTimeInterval(-2 * minute), iob: 0, cob: 0)]
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        let sentence = "The 4 hours from now cover more than one ISF."
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.interference == sentence)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.notifier.posted.last == .ended(.isf, sentence: sentence, modeBack: true))
    }

    @Test(
        "Basal Testing's own suspend for a low, as the pump enacts it, ends the test as a low before the dose, not as a temp basal left running"
    ) func basalTestingSuspendInFlight() async {
        // On the time-up question: an hour in, insulin on board still over the line.
        var test = settlingTest(startedAgo: 61 * minute)
        test.iobHandling = .wait
        let data = isfData()
        data.iob = Decimal(string: "0.3")
        let loopedAt = test.startedAt.addingTimeInterval(5 * minute)
        data.determinations = [ISFTestDetermination(date: loopedAt, iob: Decimal(string: "0.3"), cob: 0)]
        data.readings = [10, 20, 30].map {
            BasalTestReading(date: loopedAt.addingTimeInterval(Double($0) * minute), glucose: 90)
        }
        // Glucose falls; a Basal Testing determination asks for a zero temp, and the pump reports a temp basal before its
        // row reaches the history (N2).
        let askedAt = Date().addingTimeInterval(-20)
        data.zeroTempDeterminations = [askedAt]
        data.deliveryState = .tempBasal
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .settling)
        #expect(rig.notifier.posted.isEmpty)

        // Its row comes in: the low ends the test as one.
        data.temps = [BasalTestTempBasal(date: askedAt.addingTimeInterval(10), rate: 0, minutes: 30)]
        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.interference == "Trio suspended insulin for a low before the dose.")
    }

    @Test(
        "After the latch, a noisy plateau leaves the dose offered, and a bolus under a flat arrow is accepted"
    ) func latchedBolusAccepted() async {
        var test = raisingTest(tabletsAgo: 60 * minute)
        test.phase = .dosing
        // Leveled off, and latched, when the Dose step first offered the dose.
        test.tabletsLeveledAt = Date().addingTimeInterval(-10 * minute)
        let (data, _) = goodBolusData()
        // Since then the newest block reads a mg/dL over the one before: the readings alone would say still rising (N3).
        data.readings = cgm([(31, 150), (26, 150), (21, 150), (12, 150), (7, 152), (2, 151)])
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .waiting)
        #expect(rig.runner.state.test?.pendingEnd == nil)
        #expect(rig.settings.settings.dosingMode == .basalTesting)
    }

    @Test(
        "The bolus's ISF-change check is judged from the last moment the Dose step offered the dose, which a check saves"
    ) func bolusJudgedFromTheLastOffer() async throws {
        // Offered 5 minutes before the bolus; the ISF changes 3 h 58 m after the bolus, which its 4 hours just reach and
        // the offer's don't (N4).
        var test = dosingTest(settledAgo: 10 * minute)
        let (data, bolusAt) = goodBolusData()
        let offeredAt = bolusAt.addingTimeInterval(-5 * minute)
        test.doseOfferedAt = offeredAt
        test.coveredEntries = changingISF(at: offeredAt, after: 4 * hour + 3 * minute)
        do {
            let rig = makeRig(test: test, session: session(of: test), data: data)
            defer { cleanUp(rig.storage) }
            await rig.runner.check()
            #expect(rig.runner.state.test?.phase == .waiting)
            #expect(rig.runner.state.test?.interference == nil)
            await rig.runner.discard()
        }

        // A check while the step offers the dose saves the moment.
        let offering = dosingTest(settledAgo: 10 * minute)
        let offerData = isfData()
        offerData.readings = cgm([(11, 210), (6, 210), (1, 210)])
        offerData.determinations = [ISFTestDetermination(date: Date().addingTimeInterval(-2 * minute), iob: 0, cob: 0)]
        let rig = makeRig(test: offering, session: session(of: offering), data: offerData)
        defer { cleanUp(rig.storage) }
        let before = Date()
        await rig.runner.check()
        let saved = try #require(rig.runner.state.test?.doseOfferedAt)
        #expect(saved >= before.addingTimeInterval(-1))
    }

    @Test("A runner step acts only for its live session: a lost one posts no \"ISF Dose Ready\"") func lostSessionPostsNothing() async {
        var test = dosingTest(settledAgo: 10 * minute)
        test.doseNoticeDue = .settled
        let data = isfData()
        data.readings = cgm([(11, 210), (6, 210), (1, 210)])
        data.determinations = [ISFTestDetermination(date: Date().addingTimeInterval(-2 * minute), iob: 0, cob: 0)]
        // No session: lost, with Basal Testing still on (N5).
        let rig = makeRig(test: test, session: nil, mode: .basalTesting, data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .dosing)
        #expect(rig.notifier.posted.isEmpty)
    }

    @Test(
        "A bolus after a check found the offer gone is judged from its own time: its 4 hours across a change are a failed condition"
    ) func bolusAfterTheOfferWentAway() async throws {
        // Settled 70 minutes ago; the Dose step last offered the dose an hour ago. The ISF changes 4 h 30 m after that
        // offer, past its 4 hours but inside the 4 hours of a bolus now.
        var test = dosingTest(settledAgo: 70 * minute)
        let offeredAt = Date().addingTimeInterval(-61 * minute)
        test.doseOfferedAt = offeredAt
        test.coveredEntries = changingISF(at: offeredAt, after: 4 * hour + 30 * minute)
        // A check since finds no dose offered: no reading, and carbs on board unread.
        let data = isfData()
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }
        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .dosing)

        // The bolus comes after that check, with every other condition held.
        let bolusAt = Date()
        data.boluses = [ISFTestBolus(date: bolusAt, units: 2)]
        data.readings = readings(210, before: bolusAt)
        data.arrows = [ISFTestArrowReading(date: bolusAt.addingTimeInterval(-minute), direction: .flat)]
        data.determinations = [ISFTestDetermination(date: bolusAt.addingTimeInterval(-3 * minute), iob: 0, cob: 0)]
        await rig.runner.check()
        let finished = try #require(rig.runner.state.test)
        #expect(finished.phase == .finished)
        #expect(finished.interference == ISFTestBolusCondition.isfChanges.note)
        #expect(rig.service.history(for: .isf).isEmpty)
    }

    // MARK: - Adversarial review 2, fix round 5

    /// What the Raise step reads now from `data`, as the screen builds it: the readings newest first, the newest one's
    /// arrow, and nothing on board.
    private func stepInputs(_ data: FakeSettingsTestData) -> ISFTestDoseInputs {
        let newestFirst = data.readings.sorted { $0.date > $1.date }
        return ISFTestDoseInputs(
            readings: newestFirst,
            direction: newestFirst.first?.direction,
            iob: 0,
            doseIOB: nil,
            cob: 0,
            increment: Decimal(string: "0.05")!,
            now: Date()
        )
    }

    /// After tablets at 110 taken 45 minutes ago: a rise to 150 the CGM showed with a rising arrow, then level.
    private func risenAfterTablets() -> [BasalTestReading] {
        cgm(
            [(3, 150), (8, 150), (13, 150), (18, 150), (23, 150), (28, 150), (33, 140), (38, 125), (43, 115)],
            rising: [28]
        )
    }

    @Test(
        "Once the tablets are taken, Skip, Dose Now does nothing: no latch, and no dose until the readings show the rise leveled off"
    ) func skipAfterTheTablets() async {
        let test = raisingTest(tabletsAgo: 45 * minute)
        let data = isfData()
        data.determinations = [ISFTestDetermination(date: Date().addingTimeInterval(-3 * minute), iob: 0, cob: 0)]
        // Still 110 under flat arrows: they haven't acted.
        data.readings = cgm([3, 8, 13, 18, 23, 28, 33, 38, 43].map { ($0, 110) })
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        // A Skip, Dose Now tap that came in after "I've Taken Them" (L2).
        await rig.runner.moveToDose()
        #expect(rig.runner.state.test?.phase == .raising)
        #expect(rig.runner.state.test?.tabletsLeveledAt == nil)
        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .raising)
        #expect(rig.notifier.posted.isEmpty)
        // Work Out My Dose on these readings does nothing either.
        await rig.runner.workOutDose(stepInputs(data))
        #expect(rig.runner.state.test?.phase == .raising)
        #expect(rig.runner.state.test?.tabletsLeveledAt == nil)

        // Glucose rose and leveled off: the readings rule passes, and the step moves on by itself.
        data.readings = risenAfterTablets()
        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .dosing)
        #expect(rig.runner.state.test?.tabletsLeveledAt != nil)
        #expect(rig.notifier.posted == [.isfStep(.tabletsActed)])
    }

    @Test(
        "Work Out My Dose moves on, and latches \"leveled off\", only when the dose can be worked out from what the step read"
    ) func workOutMyDoseLatches() async {
        let test = raisingTest(tabletsAgo: 45 * minute)
        let data = isfData()
        data.readings = risenAfterTablets()
        // No determination of the last 12 minutes, so the runner's own check reads carbs on board as unread and waits.
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }
        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .raising)

        // The step read carbs on board as unread too: no dose, nothing moves (L2).
        await rig.runner.workOutDose(stepInputs(data).with(cob: nil))
        #expect(rig.runner.state.test?.phase == .raising)
        #expect(rig.runner.state.test?.tabletsLeveledAt == nil)
        // It read none: the dose can be worked out, so the step moves on and latches at that moment.
        let inputs = stepInputs(data)
        await rig.runner.workOutDose(inputs)
        #expect(rig.runner.state.test?.phase == .dosing)
        #expect(rig.runner.state.test?.tabletsLeveledAt == inputs.now)
        #expect(rig.notifier.withdrawn.contains(Withdrawal(kind: .isf, slot: .step)))
    }

    @Test(
        "Settling onto Raise when no moment before the dose deadline gets past an ISF change ends the test before the tablets"
    ) func raiseISFChangeDeadEnd() async {
        // Settling at 120 on target 100 leads to Raise; the ISF changes 3 hours from now, past the dose deadline 90
        // minutes away, so every bolus moment's 4 hours reach it (M1).
        var test = settlingTest(startedAgo: 20 * minute)
        test.coveredEntries = changingISF(at: Date(), after: 3 * hour)
        let data = isfData()
        data.determinations = [ISFTestDetermination(date: test.startedAt.addingTimeInterval(5 * minute), iob: 0, cob: 0)]
        data.readings = [8, 12, 16].map {
            BasalTestReading(date: test.startedAt.addingTimeInterval(Double($0) * minute), glucose: 120)
        }
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        let sentence = "The 4 hours from now cover more than one ISF."
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.interference == sentence)
        #expect(rig.settings.settings.dosingMode == .closed)
        // No "ISF Test Settled" asking for tablets first: only the ended notice.
        #expect(rig.notifier.posted == [.ended(.isf, sentence: sentence, modeBack: true)])
    }

    @Test(
        "On the Raise step the ISF-change dead end comes only before the tablets: once they are taken, the step waits for them"
    ) func raiseDeadEndOnlyBeforeTablets() async {
        let stuck = changingISF(at: Date(), after: 3 * hour)
        do {
            var taken = raisingTest(tabletsAgo: 5 * minute)
            taken.coveredEntries = stuck
            let rig = makeRig(test: taken, session: session(of: taken), data: isfData())
            defer { cleanUp(rig.storage) }
            await rig.runner.check()
            #expect(rig.runner.state.test?.phase == .raising)
            // Done with before the next service is made, so nothing of this one's can reach the files it uses.
            await rig.runner.discard()
        }

        // Settled 10 minutes ago, no tablets yet: the deadline is 80 minutes away (M1).
        var before = dosingTest(settledAgo: 10 * minute)
        before.phase = .raising
        before.coveredEntries = stuck
        let rig = makeRig(test: before, session: session(of: before), data: isfData())
        defer { cleanUp(rig.storage) }
        await rig.runner.check()
        let sentence = "The 4 hours from now cover more than one ISF."
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.interference == sentence)
        #expect(rig.notifier.posted.last == .ended(.isf, sentence: sentence, modeBack: true))
    }

    /// On the time-up question an hour in: Trio's first loop 5 minutes after Begin and 3 readings of `glucose` since.
    private func timeUpData(_ test: ISFTestState, glucose: Int = 210, iob: Decimal = Decimal(string: "0.3")!)
        -> FakeSettingsTestData
    {
        let data = isfData()
        data.iob = iob
        let loopedAt = test.startedAt.addingTimeInterval(5 * minute)
        data.determinations = [ISFTestDetermination(date: loopedAt, iob: iob, cob: 0)]
        data.readings = [10, 20, 30].map {
            BasalTestReading(date: loopedAt.addingTimeInterval(Double($0) * minute), glucose: glucose)
        }
        return data
    }

    @Test(
        "A temp basal set on the pump before Begin, still running at settling's time-up, is its dead end"
    ) func tempSetBeforeBeginIsTheDeadEnd() async {
        let test = settlingTest(startedAgo: 61 * minute)
        let data = timeUpData(test, iob: 0)
        data.deliveryState = .tempBasal
        // Set on the pump 10 minutes before Begin, for 2 hours, before Trio read it: its row is dated before Begin (L3 a).
        data.temps = [
            BasalTestTempBasal(date: test.startedAt.addingTimeInterval(-10 * minute), rate: Decimal(string: "0.5")!, minutes: 120)
        ]
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        let sentence =
            "A temp basal is still running on your pump, so the test can't start. Cancel it on the pump, then begin again."
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.interference == sentence)
        #expect(rig.notifier.posted.last == .ended(.isf, sentence: sentence, modeBack: true))
    }

    @Test(
        "A temp basal that ran and ended since Begin isn't the one running: Basal Testing's suspend in flight ends the test as a low"
    ) func endedTempIsNotTheDeadEnd() async {
        var test = settlingTest(startedAgo: 61 * minute)
        test.iobHandling = .wait
        let data = timeUpData(test, glucose: 90)
        // Set on the pump after Begin, it ran its 30 minutes and ended (L3 b).
        data.temps = [
            BasalTestTempBasal(date: test.startedAt.addingTimeInterval(10 * minute), rate: Decimal(string: "0.5")!, minutes: 30)
        ]
        // Glucose falls; a Basal Testing determination asks for a zero temp, and the pump reports a temp basal before its
        // row reaches the history.
        let askedAt = Date().addingTimeInterval(-20)
        data.zeroTempDeterminations = [askedAt]
        data.deliveryState = .tempBasal
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .settling)
        #expect(rig.notifier.posted.isEmpty)

        data.temps.append(BasalTestTempBasal(date: askedAt.addingTimeInterval(10), rate: 0, minutes: 30))
        await rig.runner.check()
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.interference == "Trio suspended insulin for a low before the dose.")
    }

    @Test(
        "A lost session still reaches its dead end: the test ends with the step's sentence and the usual mode back"
    ) func lostSessionReachesItsDeadEnd() async {
        // The Dose step's ISF-change dead end, with no session and no end of it kept: lost, Basal Testing still on (L5).
        var test = dosingTest(settledAgo: 10 * minute)
        test.coveredEntries = changingISF(at: Date(), after: 3 * hour)
        let data = isfData()
        data.readings = cgm([(11, 210), (6, 210), (1, 210)])
        data.determinations = [ISFTestDetermination(date: Date().addingTimeInterval(-2 * minute), iob: 0, cob: 0)]
        let rig = makeRig(test: test, session: nil, mode: .basalTesting, data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        let sentence = "The 4 hours from now cover more than one ISF."
        #expect(rig.runner.state.test?.phase == .finished)
        #expect(rig.runner.state.test?.interference == sentence)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.notifier.posted.last == .ended(.isf, sentence: sentence, modeBack: true))
    }

    @Test(
        "Settling's hour up with insulin on board over the line says so once, not inside the hour, not again after a relaunch"
    ) func timeUpNoticePostedOnce() async throws {
        // Inside the hour, still waiting for insulin on board: nothing.
        do {
            var early = settlingTest(startedAgo: 30 * minute)
            early.iobHandling = .wait
            let rig = makeRig(test: early, session: session(of: early), data: timeUpData(early))
            defer { cleanUp(rig.storage) }
            await rig.runner.check()
            #expect(
                rig.runner.state.settling?.decision
                    == .waiting(loopedAt: early.startedAt.addingTimeInterval(5 * minute), waitsForIOB: true)
            )
            #expect(rig.notifier.posted.isEmpty)
            await rig.runner.discard()
        }

        var test = settlingTest(startedAgo: 61 * minute)
        test.iobHandling = .wait
        let data = timeUpData(test)
        let saved: ISFTestState
        do {
            let rig = makeRig(test: test, session: session(of: test), data: data)
            defer { cleanUp(rig.storage) }
            await rig.runner.check()
            #expect(rig.notifier.posted == [.isfStep(.timeUp)])
            #expect(rig.notifier.postedOffMain.isEmpty)
            #expect(rig.storage.retrieve(Self.statePath, as: ISFTestState.self)?.timeUpNoticePosted == true)
            await rig.runner.check()
            #expect(rig.notifier.posted.count == 1)
            saved = try #require(rig.runner.state.test)
            await rig.runner.discard()
        }

        // Trio relaunched with the test as saved: nothing again.
        let relaunched = makeRig(test: saved, session: session(of: saved), data: data)
        defer { cleanUp(relaunched.storage) }
        await relaunched.runner.check()
        #expect(relaunched.runner.state.settling?.decision == .timeUp(loopedAt: test.startedAt.addingTimeInterval(5 * minute)))
        #expect(relaunched.notifier.posted.isEmpty)

        // Its words, and its tap opens the ISF screen, on the step the test is on.
        let notice = SettingsTestNotice.isfStep(.timeUp)
        #expect(notice.title == "ISF Test Waiting")
        #expect(notice.body == "Insulin on board is still over the line after an hour. Tap to count it and go on, or cancel.")
        #expect(notice.slot == .step)
        let content = SettingsTestNotifier.content(for: notice)
        #expect(SettingsTestHooks.kind(category: content.categoryIdentifier, userInfo: content.userInfo) == .isf)
        #expect(SettingsTestKind.isf.testScreen == .isfTest)
    }

    /// How the time-up question goes away.
    enum TimeUpAnswer: CaseIterable {
        case countIt
        case cancel
        case settlesByItself
    }

    @Test(
        "\"ISF Test Waiting\" is withdrawn on Count It and Go On, on Cancel Test and when settling moves on by itself",
        arguments: TimeUpAnswer.allCases
    ) func timeUpNoticeWithdrawn(_ answer: TimeUpAnswer) async {
        var test = settlingTest(startedAgo: 61 * minute)
        test.iobHandling = .wait
        let data = timeUpData(test)
        let rig = makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }
        await rig.runner.check()
        #expect(rig.notifier.posted == [.isfStep(.timeUp)])
        #expect(!rig.notifier.withdrawn.contains(Withdrawal(kind: .isf, slot: .step)))

        switch answer {
        case .countIt:
            await rig.runner.countAndGoOn()
            // The check it starts, done before the test ends.
            await rig.runner.check()
            #expect(rig.runner.state.test?.phase == .dosing)
        case .cancel:
            await rig.runner.discard()
        case .settlesByItself:
            // Insulin on board comes under the line: settling ends without the question.
            data.iob = 0
            await rig.runner.check()
            #expect(rig.runner.state.test?.phase == .dosing)
        }
        #expect(rig.notifier.withdrawn.contains(Withdrawal(kind: .isf, slot: .step)))
        #expect(rig.notifier.posted == [.isfStep(.timeUp)])
    }
}
