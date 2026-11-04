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

/// The basal test's reads passed on to the fakes, with the manual-bolus read counted and held at a gate: a check that finds
/// nothing to end the fast reads it once, in the middle of its reads.
private final class GatedBasalReads: BasalTestReads {
    private let base: BasalTestReads
    private let lock = NSLock()
    private var _manualBolusReads = 0
    let gate = TestGate()

    init(_ base: BasalTestReads) {
        self.base = base
    }

    var manualBolusReads: Int { lock.withLock { _manualBolusReads } }

    func basalEntries() -> [SettingsTestScheduleEntry] { base.basalEntries() }
    func isf(at date: Date) -> Decimal? { base.isf(at: date) }

    func fetchGlucose(from start: Date, to end: Date) async throws -> [BasalTestReading] {
        try await base.fetchGlucose(from: start, to: end)
    }

    func fetchSuspendReading(from start: Date, to end: Date) async throws -> BasalTestEvaluator.SuspendReading {
        try await base.fetchSuspendReading(from: start, to: end)
    }

    func hasCarbEntries(from start: Date, to end: Date) async throws -> Bool {
        try await base.hasCarbEntries(from: start, to: end)
    }

    func hasManualBolus(from start: Date, to end: Date) async throws -> Bool {
        lock.withLock { _manualBolusReads += 1 }
        await gate.pass()
        return try await base.hasManualBolus(from: start, to: end)
    }

    func fetchSMBs(since start: Date, until end: Date) async throws -> [BasalTestSMB] {
        try await base.fetchSMBs(since: start, until: end)
    }

    func fetchTempBasals(from start: Date, to end: Date) async throws -> [BasalTestTempBasal] {
        try await base.fetchTempBasals(from: start, to: end)
    }
}

@Suite("Basal test runner", .serialized, .settingsTestFiles) struct BasalTestRunnerTests {
    typealias Withdrawal = RecordingSettingsTestNotifier.Withdrawal

    private static let statePath = "trio/basal_test_state.json"
    private let minute: TimeInterval = 60
    private let hour: TimeInterval = 3600

    /// The service with the basal runner, and the fakes they share.
    private struct Rig {
        let harness: SettingsTestHarness
        let runner: BasalTestRunner
        let data: FakeSettingsTestData

        var service: BaseSettingsTestService { harness.service }
        var settings: FakeSettingsManager { harness.settings }
        var storage: FileStorage { harness.storage }
        var notifier: RecordingSettingsTestNotifier { harness.notifier }
    }

    /// Writes `test` (and anything `beforeStart` writes) before the service and its runner are made, as a launch finds
    /// them. The runner reads from `reads`, the fakes themselves unless a test passes others.
    private func makeRig(
        test: BasalTestState?,
        session: SettingsTestSession?,
        mode: DosingMode = .basalTesting,
        data: FakeSettingsTestData,
        reads: BasalTestReads? = nil,
        settings: FakeSettingsManager = FakeSettingsManager(),
        beforeStart: ((FileStorage) -> Void)? = nil
    ) throws -> Rig {
        var built: BasalTestRunner?
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
                let runner = BasalTestRunner(
                    service: context.service,
                    reads: reads ?? data,
                    storage: context.storage,
                    settingsManager: context.settingsManager,
                    notifier: notifier
                )
                built = runner
                return [runner]
            }
        )
        return Rig(harness: harness, runner: try #require(built), data: data)
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

    /// The settings the tests run on: an ISF of 50 and a basal of 1 U/h all day, so one docs step (10%) over 4 hours moves
    /// glucose 20 mg/dL.
    private func basalData() -> FakeSettingsTestData {
        let data = FakeSettingsTestData()
        data.basalSchedule = [SettingsTestScheduleEntry(startMinutes: 0, endMinutes: 1440, value: 1)]
        data.isfSchedule = [SettingsTestScheduleEntry(startMinutes: 0, endMinutes: 1440, value: 50)]
        return data
    }

    /// Begun `startedAgo` ago from Closed Loop at 110 mg/dL, planned for `hours` hours, with its ISF and basal and a
    /// session id.
    private func runningFast(startedAgo: TimeInterval, hours: Int = 4) -> BasalTestState {
        var state = BasalTestState(
            startedAt: Date().addingTimeInterval(-startedAgo),
            plannedDuration: TimeInterval(hours) * hour,
            startGlucose: 110,
            startIOB: 0,
            previousMode: .closed,
            timeBlock: "Overnight",
            isf: 50,
            scheduledBasal: 1,
            coveredEntries: [SettingsTestScheduleEntry(startMinutes: 0, endMinutes: 1440, value: 1)]
        )
        state.sessionID = UUID()
        return state
    }

    /// A fast that ended, with the fields a finish fills in.
    private func finishedFast(
        outcome: BasalTestOutcome,
        reason: BasalTestEndReason,
        interference: String? = nil
    ) -> BasalTestState {
        var state = runningFast(startedAgo: 5 * hour)
        state.phase = .finished
        state.endedAt = state.plannedEnd
        state.endReason = reason
        state.outcome = outcome
        state.interference = interference
        return state
    }

    /// A result with no verdict: carbs were logged.
    private var interrupted: BasalTestState {
        finishedFast(outcome: .invalid, reason: .interrupted, interference: "Carbs were logged during the fast.")
    }

    /// A result with no verdict: the pump history couldn't be read at the planned end.
    private var unchecked: BasalTestState {
        finishedFast(outcome: .inconclusive, reason: .unchecked)
    }

    /// The fast's session in Basal Testing from Closed Loop, with time left.
    private func session(of test: BasalTestState) -> SettingsTestSession {
        SettingsTestSession(
            id: test.sessionID ?? UUID(),
            kind: .basal,
            startedAt: test.startedAt,
            expiresAt: Date().addingTimeInterval(hour),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )
    }

    /// Readings of `glucose` every 15 minutes from the start of the fast to the planned end, or to now if that is sooner,
    /// and one 30 seconds before it.
    private func readings(_ glucose: Int, for test: BasalTestState) -> [BasalTestReading] {
        let span = min(test.plannedDuration, Date().timeIntervalSince(test.startedAt))
        return (stride(from: 0, to: span, by: 15 * minute) + [span - 30]).map {
            BasalTestReading(date: test.startedAt.addingTimeInterval($0), glucose: glucose)
        }
    }

    /// A fast begun 4 hours and a minute ago, planned for 4, with readings that stayed at 110: it ran its hours and glucose
    /// didn't move.
    private func completedFast() -> (data: FakeSettingsTestData, test: BasalTestState) {
        let test = runningFast(startedAgo: 4 * hour + minute)
        let data = basalData()
        data.readings = readings(110, for: test)
        return (data, test)
    }

    /// A fast and its session as the basal screen saved them before the update: no `pendingEnd`, and a fixed-time
    /// notification the screen scheduled.
    private func legacyFiles(startedAt: Date) throws -> (state: String, session: String) {
        func json(_ value: some Encodable) throws -> String {
            try #require(String(data: JSONCoding.encoder.encode(value), encoding: .utf8))
        }
        let sessionID = UUID()
        let state = [
            "\"id\" : \"\(UUID().uuidString)\"",
            "\"phase\" : \"running\"",
            "\"startedAt\" : \(try json(startedAt))",
            "\"plannedDuration\" : 14400",
            "\"startGlucose\" : 110",
            "\"startIOB\" : 0",
            "\"previousMode\" : \"closed\"",
            "\"timeBlock\" : \"Overnight\"",
            "\"sessionID\" : \"\(sessionID.uuidString)\"",
            "\"isf\" : 50",
            "\"scheduledBasal\" : 1",
            "\"readings\" : [ ]"
        ]
        let session = [
            "\"id\" : \"\(sessionID.uuidString)\"",
            "\"kind\" : \"basal\"",
            "\"startedAt\" : \(try json(startedAt))",
            "\"expiresAt\" : \(try json(startedAt.addingTimeInterval(4.5 * hour)))",
            "\"restore\" : \(try json([SettingsTestRestoreAction.dosingMode(testMode: .basalTesting, previous: .closed)]))"
        ]
        return ("{\n" + state.joined(separator: ",\n") + "\n}", "{\n" + session.joined(separator: ",\n") + "\n}")
    }

    /// The service and runner at the first launch after the update, with `legacyFiles` on disk.
    private func makeLegacyRig(startedAt: Date, data: FakeSettingsTestData) throws -> Rig {
        let files = try legacyFiles(startedAt: startedAt)
        #expect(!files.state.contains("pendingEnd"))
        return try makeRig(test: nil, session: nil, data: data, beforeStart: { storage in
            storage.save(files.state, as: Self.statePath)
            storage.save(files.session, as: "trio/settings_test_session.json")
        })
    }

    /// Begins a fast through the runner, so the service made no check of its own at launch, and then changes the state the
    /// runner holds, as a state the runner would have saved at some point.
    private func beginThenChange(_ rig: Rig, _ change: (inout BasalTestState) -> Void) async throws {
        #expect(await rig.runner.begin(BasalTestBegin(glucose: 110, iob: 0, hours: 4)) == nil)
        var test = try #require(rig.runner.state)
        change(&test)
        await rig.runner.save(test)
    }

    // MARK: - Begin

    @Test("Begin starts the fast and posts nothing") func beginStartsTheFast() async throws {
        do {
            let rig = try makeRig(test: nil, session: nil, mode: .closed, data: basalData())
            defer { cleanUp(rig.storage) }

            #expect(await rig.runner.begin(BasalTestBegin(glucose: 110, iob: 0, hours: 4)) == nil)
            #expect(rig.service.activeSession?.kind == .basal)
            #expect(rig.settings.settings.dosingMode == .basalTesting)
            #expect(rig.runner.state?.sessionID == rig.service.activeSession?.id)
            let saved = rig.storage.retrieve(Self.statePath, as: BasalTestState.self)
            #expect(saved?.id == rig.runner.state?.id)
            #expect(saved?.sessionID == rig.service.activeSession?.id)
            #expect(saved?.phase == .running)
            #expect(saved?.previousMode == .closed)
            #expect(saved?.startGlucose == 110)
            #expect(saved?.plannedDuration == 4 * hour)
            // What the fast runs on, as the settings are now.
            #expect(saved?.isf == 50)
            #expect(saved?.scheduledBasal == 1)
            #expect(saved?.coveredEntries?.isEmpty == false)
            #expect(rig.runner.isRunning)
            // Begin schedules nothing through the notifier, the runner's only route.
            #expect(rig.notifier.posted.isEmpty)
            #expect(rig.notifier.center.added.isEmpty)
            // Done with before the next service is made, so nothing of this one's can reach the files it uses.
            await rig.runner.discard()
        }

        // With another test's session already running: refused, nothing saved, the mode left alone.
        let other = SettingsTestSession(
            kind: .isf,
            expiresAt: Date().addingTimeInterval(hour),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )
        let busy = try makeRig(test: nil, session: other, mode: .basalTesting, data: basalData())
        defer { cleanUp(busy.storage) }
        #expect(await busy.runner.begin(BasalTestBegin(glucose: 110, iob: 0, hours: 4)) == .otherTestRunning)
        #expect(busy.storage.retrieve(Self.statePath, as: BasalTestState.self) == nil)
        #expect(busy.runner.state == nil)
        #expect(busy.service.activeSession?.id == other.id)
        #expect(busy.settings.settings.dosingMode == .basalTesting)
    }

    @Test("Begin is refused in Basal Testing, before anything is saved") func beginRefusedInBasalTesting() async throws {
        // No session and no fast: Basal Testing picked by hand, say. Kept as the usual mode, nothing would turn it off.
        let rig = try makeRig(test: nil, session: nil, mode: .basalTesting, data: basalData())
        defer { cleanUp(rig.storage) }

        #expect(await rig.runner.begin(BasalTestBegin(glucose: 110, iob: 0, hours: 4)) == .basalTestingOn)
        #expect(rig.storage.retrieve(Self.statePath, as: BasalTestState.self) == nil)
        #expect(rig.runner.state == nil)
        #expect(rig.service.activeSession == nil)
        #expect(rig.settings.settings.dosingMode == .basalTesting)
        #expect(rig.notifier.withdrawn.isEmpty)
    }

    @Test("A new Begin withdraws the last fast's ended notice") func beginWithdrawsTheEndedNotice() async throws {
        // A result left on screen, not cleared with Done.
        let rig = try makeRig(test: interrupted, session: nil, mode: .closed, data: basalData())
        defer {
            rig.service.end(kind: .basal)
            cleanUp(rig.storage)
        }

        #expect(await rig.runner.begin(BasalTestBegin(glucose: 110, iob: 0, hours: 4)) == nil)
        #expect(rig.notifier.withdrawn.contains(Withdrawal(kind: .basal, slot: .ended)))
    }

    @Test("A refused Begin leaves the result that was there") func refusedBeginKeepsTheResult() async throws {
        let result = interrupted
        let other = SettingsTestSession(
            kind: .isf,
            expiresAt: Date().addingTimeInterval(hour),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )
        let rig = try makeRig(test: result, session: other, mode: .basalTesting, data: basalData())
        defer { cleanUp(rig.storage) }
        // As the runner loaded it: dates read back from the file are not the fixture's to the last digit.
        let shown = try #require(rig.runner.state)
        #expect(shown.id == result.id)
        #expect(shown.phase == .finished)

        #expect(await rig.runner.begin(BasalTestBegin(glucose: 110, iob: 0, hours: 4)) == .otherTestRunning)
        #expect(rig.runner.state == shown)
        #expect(rig.storage.retrieve(Self.statePath, as: BasalTestState.self) == shown)
        #expect(rig.settings.settings.dosingMode == .basalTesting)
    }

    @Test("Begin is refused while a fast runs, one whose session was lost among them") func beginRefusedWhileRunning() async throws {
        // Lost with Basal Testing still on: the service has no session to refuse with, and a new fast would take Basal
        // Testing as its usual mode.
        let running = runningFast(startedAgo: hour)
        let rig = try makeRig(test: running, session: nil, mode: .basalTesting, data: basalData())
        defer { cleanUp(rig.storage) }

        #expect(await rig.runner.begin(BasalTestBegin(glucose: 110, iob: 0, hours: 4)) == .otherTestRunning)
        #expect(rig.service.activeSession == nil)
        #expect(rig.runner.state?.id == running.id)
        #expect(try #require(rig.storage.retrieve(Self.statePath, as: BasalTestState.self)).id == running.id)
        #expect(rig.settings.settings.dosingMode == .basalTesting)
    }

    @Test("The state is published as the fast begins and ends") func statePublished() async throws {
        let rig = try makeRig(test: nil, session: nil, mode: .closed, data: basalData())
        defer { cleanUp(rig.storage) }
        let seen = Seen<[BasalTestState?]>()
        seen.value = []
        let subscription = rig.runner.statePublisher.sink { state in seen.value = (seen.value ?? []) + [state] }
        defer { subscription.cancel() }

        #expect(await rig.runner.begin(BasalTestBegin(glucose: 110, iob: 0, hours: 4)) == nil)
        await rig.runner.discard()
        let states = try #require(seen.value)
        // What it held when subscribed to (none), the fast as saved, and none again once discarded.
        #expect(states.count >= 3)
        #expect(states.first.flatMap { $0 } == nil)
        #expect(states.dropFirst().first.flatMap { $0 }?.phase == .running)
        #expect(states.last.flatMap { $0 } == nil)
    }

    // MARK: - Endings the service decides

    @Test("A fast that ran its hours is judged and archived with the screen closed") func finishesInTheService() async throws {
        let (data, test) = completedFast()
        // Set before the service is made, so a check it runs at launch can't come before it.
        let settings = FakeSettingsManager()
        let reader = BaseFileStorage()
        let atModeChange = Seen<BasalTestState>()
        settings.onSettingsChange = { [unowned settings] in
            guard settings.settings.dosingMode != .basalTesting else { return }
            atModeChange.value = reader.retrieve(Self.statePath, as: BasalTestState.self)
        }
        let rig = try makeRig(test: test, session: session(of: test), data: data, settings: settings)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        // The ending was saved before the usual mode came back.
        #expect(atModeChange.value?.pendingEnd?.reason == .completed)
        #expect(atModeChange.value?.pendingEnd?.byUser == false)
        #expect(rig.runner.state?.phase == .finished)
        #expect(rig.runner.state?.outcome == .steady)
        #expect(rig.runner.state?.endReason == .completed)
        #expect(rig.runner.state?.pendingEnd == nil)
        #expect(rig.service.history(for: .basal).count == 1)
        #expect(rig.service.activeSession == nil)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.notifier.posted.last == .finished(.basal))
        #expect(rig.notifier.posted.filter { $0.slot == .ended }.count == 1)
        // Posted on the main thread.
        #expect(rig.notifier.postedOffMain.isEmpty)
        // What was saved is what the runner holds.
        #expect(rig.storage.retrieve(Self.statePath, as: BasalTestState.self)?.phase == .finished)
    }

    @Test("Trio's suspend for a low ends the fast with its result, screen closed") func lowEndsTheFast() async throws {
        let test = runningFast(startedAgo: 2 * hour)
        let data = basalData()
        data.trioSuspends(at: test.startedAt.addingTimeInterval(hour))
        let rig = try makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.service.checkSessionAndRunners()
        #expect(rig.runner.state?.phase == .finished)
        #expect(rig.runner.state?.endReason == .low)
        #expect(rig.runner.state?.outcome == .falling)
        #expect(rig.service.history(for: .basal).count == 1)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.notifier.posted.last == .finished(.basal))
        #expect(rig.notifier.postedOffMain.isEmpty)
    }

    @Test("Carbs end the fast with no verdict and say so") func carbsEndTheFast() async throws {
        let test = runningFast(startedAgo: 2 * hour)
        let data = basalData()
        data.carbs = [test.startedAt.addingTimeInterval(30 * minute)]
        let rig = try makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.service.checkSessionAndRunners()
        #expect(rig.runner.state?.phase == .finished)
        #expect(rig.runner.state?.outcome == .invalid)
        #expect(rig.runner.state?.interference == "Carbs were logged during the fast.")
        #expect(rig.service.history(for: .basal).isEmpty)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.notifier.posted.last == .ended(.basal, sentence: "Carbs were logged during the fast.", modeBack: true))
        #expect(rig.notifier.posted.filter { $0.slot == .ended }.count == 1)
        #expect(rig.notifier.postedOffMain.isEmpty)
    }

    @Test("A bolus the history shows ends the fast with no verdict") func bolusEndsTheFast() async throws {
        // The runner's own check finds it: the service ends a basal test for a low or carbs, not for a bolus.
        let test = runningFast(startedAgo: 2 * hour)
        let data = basalData()
        data.boluses = [ISFTestBolus(date: test.startedAt.addingTimeInterval(30 * minute), units: 1)]
        let rig = try makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state?.phase == .finished)
        #expect(rig.runner.state?.endReason == .interrupted)
        #expect(rig.runner.state?.interference == "A bolus was given during the fast.")
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.notifier.posted.last == .ended(.basal, sentence: "A bolus was given during the fast.", modeBack: true))
    }

    @Test(
        "A mode picked during the fast ends it with no result, and the notice doesn't say the usual mode is back"
    ) func modeChanged() async throws {
        let test = runningFast(startedAgo: hour)
        // The user picked Open Loop; the service restores nothing over a mode that isn't Basal Testing.
        let rig = try makeRig(test: test, session: session(of: test), mode: .open, data: basalData())
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state?.phase == .finished)
        #expect(rig.runner.state?.outcome == .invalid)
        #expect(rig.runner.state?.interference == "The dosing mode changed during the fast.")
        #expect(rig.settings.settings.dosingMode == .open)
        #expect(rig.service.activeSession == nil)
        #expect(rig.notifier.posted.last == .ended(.basal, sentence: "The dosing mode changed during the fast.", modeBack: false))
    }

    @Test("A fast whose time is up with the pump history unread ends with no verdict") func uncheckedAtTheEnd() async throws {
        let (data, test) = completedFast()
        // The temp basals are read for a low and again for Trio's own dosing, so both reads fail.
        data.failingTemps = true
        let rig = try makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state?.phase == .finished)
        #expect(rig.runner.state?.endReason == .unchecked)
        #expect(rig.runner.state?.outcome == .inconclusive)
        #expect(rig.runner.state?.interferenceUnread == true)
        #expect(rig.service.history(for: .basal).isEmpty)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(
            rig.notifier.posted.last
                == .ended(
                    .basal,
                    sentence: "Trio couldn't read all its records of carbs, boluses and its own dosing, so it can't tell whether something interrupted this fast.",
                    modeBack: true
                )
        )
    }

    @Test("A running fast no check ends is left running, and says nothing") func runningIsLeftAlone() async throws {
        let test = runningFast(startedAgo: hour)
        let data = basalData()
        data.readings = readings(110, for: test)
        let rig = try makeRig(test: test, session: session(of: test), data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state?.phase == .running)
        #expect(rig.runner.state?.pendingEnd == nil)
        #expect(rig.service.activeSession != nil)
        #expect(rig.settings.settings.dosingMode == .basalTesting)
        #expect(rig.notifier.posted.isEmpty)
    }

    @Test("Checks asked for during one wait for it and for one more, shared") func checksCoalesce() async throws {
        // Begun here, so the service made no check of its own at launch. A check that finds nothing to end the fast reads
        // the manual boluses once.
        let data = basalData()
        let reads = GatedBasalReads(data)
        let rig = try makeRig(test: nil, session: nil, mode: .closed, data: data, reads: reads)
        defer {
            rig.service.end(kind: .basal)
            cleanUp(rig.storage)
        }
        #expect(await rig.runner.begin(BasalTestBegin(glucose: 110, iob: 0, hours: 4)) == nil)
        let runner = rig.runner

        let first = Task { await runner.check() }
        #expect(await eventually { reads.gate.waiting == 1 })
        let others = (0 ..< 3).map { _ in Task { await runner.check() } }
        #expect(await eventually { runner.checks.waiting == 3 })
        reads.gate.open()
        await first.value
        for other in others {
            await other.value
        }
        #expect(reads.manualBolusReads == 2)
    }

    // MARK: - A session that is gone

    /// A fast begun 2 hours ago whose session is gone, with Basal Testing still on, and the data of `carbs` 30 minutes in.
    private func lostSessionFast(carbs: Bool) -> (data: FakeSettingsTestData, test: BasalTestState) {
        let test = runningFast(startedAgo: 2 * hour)
        let data = basalData()
        if carbs { data.carbs = [test.startedAt.addingTimeInterval(30 * minute)] }
        return (data, test)
    }

    /// The service's record of ending `test`'s session earlier, as the user then picked Basal Testing again themselves.
    private func serviceEnded(_ test: BasalTestState) throws -> (FileStorage) -> Void {
        let sessionID = try #require(test.sessionID)
        let end = SettingsTestEnd(sessionID: sessionID, cause: .modeChanged, date: test.startedAt.addingTimeInterval(30 * minute))
        return { storage in storage.save(end, as: "trio/settings_test_last_end.json") }
    }

    @Test("A fast whose session was lost puts the usual mode back itself as it ends") func lostSessionFinishRestoresTheMode() async throws {
        let (data, test) = lostSessionFast(carbs: true)
        let settings = FakeSettingsManager()
        let reader = BaseFileStorage()
        let atModeChange = Seen<BasalTestState>()
        settings.onSettingsChange = { [unowned settings] in
            guard settings.settings.dosingMode != .basalTesting else { return }
            atModeChange.value = reader.retrieve(Self.statePath, as: BasalTestState.self)
        }
        let rig = try makeRig(test: test, session: nil, mode: .basalTesting, data: data, settings: settings)
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state?.phase == .finished)
        #expect(rig.runner.state?.interference == "Carbs were logged during the fast.")
        #expect(rig.settings.settings.dosingMode == .closed)
        // The ending was saved before the mode came back.
        #expect(atModeChange.value?.pendingEnd?.reason == .interrupted)
        // The mode is back, so the notice says so.
        #expect(rig.notifier.posted.last == .ended(.basal, sentence: "Carbs were logged during the fast.", modeBack: true))
    }

    @Test("Discard on a fast whose session was lost puts the usual mode back itself") func lostSessionDiscardRestoresTheMode() async throws {
        let (data, test) = lostSessionFast(carbs: false)
        let rig = try makeRig(test: test, session: nil, mode: .basalTesting, data: data)
        defer { cleanUp(rig.storage) }

        await rig.runner.discard()
        #expect(rig.runner.state == nil)
        #expect(rig.storage.retrieve(Self.statePath, as: BasalTestState.self) == nil)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.notifier.posted.isEmpty)
    }

    @Test(
        "A session the service already ended leaves the user's mode alone as the fast ends"
    ) func serviceEndedFinishLeavesTheMode() async throws {
        let (data, test) = lostSessionFast(carbs: false)
        let rig = try makeRig(
            test: test,
            session: nil,
            mode: .basalTesting,
            data: data,
            beforeStart: try serviceEnded(test)
        )
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state?.phase == .finished)
        #expect(rig.runner.state?.interference == "The dosing mode changed during the fast.")
        #expect(rig.settings.settings.dosingMode == .basalTesting)
        // The usual mode didn't come back, so the notice doesn't say it did.
        #expect(
            rig.notifier.posted.last
                == .ended(.basal, sentence: "The dosing mode changed during the fast.", modeBack: false)
        )
    }

    @Test(
        "Discard on a fast whose session the service already ended leaves the user's mode alone"
    ) func serviceEndedDiscardLeavesTheMode() async throws {
        // Begun through the runner, so there is no launch check: the service's record below would have that check finish
        // the fast, and a Discard after it would find nothing to discard.
        let rig = try makeRig(test: nil, session: nil, mode: .closed, data: basalData())
        defer { cleanUp(rig.storage) }
        #expect(await rig.runner.begin(BasalTestBegin(glucose: 110, iob: 0, hours: 4)) == nil)
        let test = try #require(rig.runner.state)
        // The service ended the session for a mode change and kept its record; the user then picked Basal Testing again.
        rig.service.end(kind: .basal)
        try serviceEnded(test)(rig.storage)
        rig.settings.settings.dosingMode = .basalTesting

        await rig.runner.discard()
        #expect(rig.runner.state == nil)
        #expect(rig.settings.settings.dosingMode == .basalTesting)
    }

    @Test(
        "A fast that finishes while the other kind's session runs leaves that session and its Basal Testing alone"
    ) func finishBesideTheOtherKindsSession() async throws {
        // The fast ran its hours and its own session is gone; an ISF test began 10 minutes ago and owns Basal Testing now.
        let (data, test) = completedFast()
        let isf = SettingsTestSession(
            kind: .isf,
            startedAt: Date().addingTimeInterval(-10 * minute),
            expiresAt: Date().addingTimeInterval(6 * hour),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)],
            settles: true
        )
        let rig = try makeRig(test: test, session: isf, mode: .basalTesting, data: data)
        defer { cleanUp(rig.storage) }
        let savedSession = try #require(rig.storage.retrieve("trio/settings_test_session.json", as: SettingsTestSession.self))

        await rig.runner.check()
        #expect(rig.runner.state?.phase == .finished)
        #expect(rig.runner.state?.endReason == .completed)
        // The fast's restore didn't fire: Basal Testing is the ISF test's.
        #expect(rig.settings.settings.dosingMode == .basalTesting)
        // Nothing of the ISF session changed, in memory or on disk, and nothing ended it.
        #expect(rig.service.activeSession == savedSession)
        #expect(rig.storage.retrieve("trio/settings_test_session.json", as: SettingsTestSession.self) == savedSession)
        #expect(rig.service.lastEnd() == nil)
        // The usual mode isn't back, so a notice without a verdict wouldn't say it is; this one has a verdict.
        #expect(rig.notifier.posted.last == .finished(.basal))
    }

    @Test("Discard with no fast still ends a basal session left running, and brings its mode back") func discardEndsALeftSession(
    ) async throws {
        let session = SettingsTestSession(
            kind: .basal,
            expiresAt: Date().addingTimeInterval(hour),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )
        let rig = try makeRig(test: nil, session: session, mode: .basalTesting, data: basalData())
        defer { cleanUp(rig.storage) }

        await rig.runner.discard()
        #expect(rig.service.activeSession == nil)
        #expect(rig.settings.settings.dosingMode == .closed)
    }

    @Test("An end a check dated in the future is now") func futureEndIsNow() async throws {
        // The service's record says a low ended the fast an hour from now: the fast can't have ended after the moment it
        // was finished.
        let test = runningFast(startedAgo: 2 * hour)
        let sessionID = try #require(test.sessionID)
        let future = SettingsTestEnd(sessionID: sessionID, cause: .low, date: Date().addingTimeInterval(hour))
        let rig = try makeRig(
            test: test,
            session: nil,
            mode: .closed,
            data: basalData(),
            beforeStart: { storage in storage.save(future, as: "trio/settings_test_last_end.json") }
        )
        defer { cleanUp(rig.storage) }
        let before = Date()

        await rig.runner.check()
        let after = Date()
        let finished = try #require(rig.runner.state)
        #expect(finished.phase == .finished)
        #expect(finished.endReason == .low)
        let endedAt = try #require(finished.endedAt)
        #expect(endedAt <= after)
        #expect(endedAt > before.addingTimeInterval(-minute))
    }

    // MARK: - Endings saved first

    @Test("A decided ending saved before a relaunch is finished the same way") func pendingEndResumesAtLaunch() async throws {
        // The service had already put the usual mode back and the session was gone when the app was killed: running on
        // disk, past its planned end, with the ending the check decided.
        var test = runningFast(startedAgo: 5 * hour)
        let pending = BasalTestPendingEnd(
            reason: .interrupted,
            at: test.startedAt.addingTimeInterval(30 * minute),
            note: "Carbs were logged during the fast.",
            byUser: false
        )
        test.pendingEnd = pending
        let rig = try makeRig(test: test, session: nil, mode: .closed, data: basalData())
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        let finished = try #require(rig.runner.state)
        #expect(finished.phase == .finished)
        #expect(finished.outcome == .invalid)
        #expect(finished.endReason == .interrupted)
        #expect(finished.interference == "Carbs were logged during the fast.")
        // The ending saved, not one worked out again at the planned end.
        #expect(abs(try #require(finished.endedAt).timeIntervalSince(pending.at)) < 0.01)
        #expect(finished.pendingEnd == nil)
        #expect(rig.service.history(for: .basal).isEmpty)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.notifier.posted.filter { $0.slot == .ended }.count == 1)
        #expect(rig.notifier.posted.last == .ended(.basal, sentence: "Carbs were logged during the fast.", modeBack: true))
    }

    @Test("A saved ending is finished at the next check, before anything else is read") func pendingEndFinishedFirst() async throws {
        // Saved with a ending for a bolus, on a fast whose reads now show nothing wrong and whose time isn't up: a check
        // that decided again would leave it running in Basal Testing.
        var test = runningFast(startedAgo: hour)
        test.pendingEnd = BasalTestPendingEnd(
            reason: .interrupted,
            at: test.startedAt.addingTimeInterval(30 * minute),
            note: "A bolus was given during the fast.",
            byUser: false
        )
        let rig = try makeRig(test: test, session: session(of: test), data: basalData())
        defer { cleanUp(rig.storage) }

        await rig.runner.check()
        #expect(rig.runner.state?.phase == .finished)
        #expect(rig.runner.state?.interference == "A bolus was given during the fast.")
        #expect(rig.service.activeSession == nil)
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.notifier.posted.last == .ended(.basal, sentence: "A bolus was given during the fast.", modeBack: true))
    }

    @Test("A saved ending wins over the one End Now asks for") func pendingEndWinsOverTheArguments() async throws {
        let rig = try makeRig(test: nil, session: nil, mode: .closed, data: basalData())
        defer {
            rig.service.end(kind: .basal)
            cleanUp(rig.storage)
        }
        try await beginThenChange(rig) { test in
            test.pendingEnd = BasalTestPendingEnd(
                reason: .interrupted,
                at: test.startedAt,
                note: "A bolus was given during the fast.",
                byUser: false
            )
        }

        await rig.runner.endEarly()
        // The saved reason, note and notice, not End Now's.
        #expect(rig.runner.state?.phase == .finished)
        #expect(rig.runner.state?.endReason == .interrupted)
        #expect(rig.runner.state?.interference == "A bolus was given during the fast.")
        #expect(rig.settings.settings.dosingMode == .closed)
        #expect(rig.notifier.posted.last == .ended(.basal, sentence: "A bolus was given during the fast.", modeBack: true))
    }

    @Test("End Now while the service finishes keeps one ending") func endNowRacesTheService() async throws {
        let rig = try makeRig(test: nil, session: nil, mode: .closed, data: basalData())
        defer { cleanUp(rig.storage) }
        let data = rig.data
        // Past the planned end, so both would judge it. Begun here, so neither has run yet.
        try await beginThenChange(rig) { test in
            test.startedAt = Date().addingTimeInterval(-4 * hour - minute)
            data.readings = readings(110, for: test)
        }
        let runner = rig.runner

        async let user: Void = runner.endEarly()
        async let watch: Void = runner.check()
        _ = await (user, watch)
        #expect(runner.state?.phase == .finished)
        // What this pins is one archive: whichever finish wins, End Now past the 4 hours is judged too, so a second finish
        // would archive again. The claim and the final save's guard both keep it to one. The notice count only bounds it:
        // none (End Now won) and one (the check won) both pass.
        #expect(rig.service.history(for: .basal).count == 1)
        #expect(rig.notifier.posted.filter { $0.slot == .ended }.count <= 1)
        #expect(rig.settings.settings.dosingMode == .closed)
    }

    // MARK: - Launch

    @Test("A fast saved by the screen before the move is finished at launch") func oldStateFinishedAtLaunch() async throws {
        // Past its planned end by 10 minutes, with the screen's session still running.
        let rig = try makeLegacyRig(startedAt: Date().addingTimeInterval(-4 * hour - 10 * minute), data: basalData())
        defer { cleanUp(rig.storage) }

        #expect(await eventually { rig.runner.state?.phase == .finished })
        #expect(await eventually { rig.notifier.posted.last?.slot == .ended })
        #expect(rig.notifier.center.removedPending.contains("Trio.basalTestFinished"))
        #expect(rig.notifier.center.removedDelivered.contains("Trio.basalTestFinished"))
        // The ending's own withdrawal, apart from the one a post makes.
        #expect(rig.notifier.legacyWithdrawals >= 1)
        #expect(rig.settings.settings.dosingMode == .closed)
    }

    @Test("End Now on a fast begun before the update withdraws its fixed-time notification") func endNowWithdrawsLegacy() async throws {
        let rig = try makeLegacyRig(startedAt: Date().addingTimeInterval(-hour), data: basalData())
        defer { cleanUp(rig.storage) }
        #expect(rig.runner.state?.phase == .running)

        await rig.runner.endEarly()
        #expect(rig.runner.state?.phase == .finished)
        // Nothing posted, so the withdrawal is the ending's own.
        #expect(rig.notifier.posted.isEmpty)
        #expect(rig.notifier.center.removedPending.contains("Trio.basalTestFinished"))
        #expect(rig.notifier.center.removedDelivered.contains("Trio.basalTestFinished"))
    }

    @Test("Discard on a fast begun before the update withdraws its fixed-time notification") func discardWithdrawsLegacy() async throws {
        let rig = try makeLegacyRig(startedAt: Date().addingTimeInterval(-hour), data: basalData())
        defer { cleanUp(rig.storage) }
        #expect(rig.runner.state?.phase == .running)

        await rig.runner.discard()
        #expect(rig.runner.state == nil)
        #expect(rig.notifier.posted.isEmpty)
        #expect(rig.notifier.center.removedPending.contains("Trio.basalTestFinished"))
        #expect(rig.notifier.center.removedDelivered.contains("Trio.basalTestFinished"))
    }

    // MARK: - The user's endings

    @Test("End Now and See Result posts no notice; Discard keeps nothing") func userEndings() async throws {
        do {
            let test = runningFast(startedAgo: hour)
            let data = basalData()
            data.readings = readings(110, for: test)
            let rig = try makeRig(test: test, session: session(of: test), data: data)
            defer { cleanUp(rig.storage) }

            await rig.runner.endEarly()
            #expect(rig.runner.state?.phase == .finished)
            #expect(rig.runner.state?.endReason == .endedEarly)
            #expect(rig.runner.state?.outcome == .inconclusive)
            #expect(rig.settings.settings.dosingMode == .closed)
            #expect(rig.service.activeSession == nil)
            #expect(rig.service.history(for: .basal).isEmpty)
            #expect(rig.notifier.posted.isEmpty)
            #expect(rig.notifier.center.added.isEmpty)
            // Done with before the next service is made, so nothing of this one's can reach the files it uses.
            await rig.runner.acknowledgeResult()
        }

        let test = runningFast(startedAgo: hour)
        let second = try makeRig(test: test, session: session(of: test), data: basalData())
        defer { cleanUp(second.storage) }

        await second.runner.discard()
        #expect(second.runner.state == nil)
        #expect(!second.runner.isRunning)
        #expect(second.storage.retrieve(Self.statePath, as: BasalTestState.self) == nil)
        #expect(second.settings.settings.dosingMode == .closed)
        #expect(second.service.activeSession == nil)
        #expect(second.service.history(for: .basal).isEmpty)
        #expect(second.notifier.posted.isEmpty)
    }

    @Test("Done clears the result and withdraws the legacy notification") func acknowledgeClears() async throws {
        let rig = try makeRig(test: interrupted, session: nil, mode: .closed, data: basalData())
        defer { cleanUp(rig.storage) }

        #expect(rig.runner.state?.phase == .finished)
        await rig.runner.acknowledgeResult()
        #expect(rig.runner.state == nil)
        #expect(!rig.runner.isRunning)
        #expect(rig.storage.retrieve(Self.statePath, as: BasalTestState.self) == nil)
        #expect(rig.notifier.center.removedPending.contains("Trio.basalTestFinished"))
        #expect(rig.notifier.center.removedDelivered.contains("Trio.basalTestFinished"))
        // Its ended notice too, so it can't open the cleared result later.
        #expect(rig.notifier.withdrawn.contains(Withdrawal(kind: .basal, slot: .ended)))
        #expect(rig.notifier.posted.isEmpty)
    }

    @Test("Done does nothing to a fast still running") func acknowledgeOnlyFinished() async throws {
        let test = runningFast(startedAgo: hour)
        let rig = try makeRig(test: test, session: session(of: test), data: basalData())
        defer { cleanUp(rig.storage) }

        await rig.runner.acknowledgeResult()
        #expect(rig.runner.state?.id == test.id)
        #expect(rig.runner.isRunning)
        #expect(try #require(rig.storage.retrieve(Self.statePath, as: BasalTestState.self)).id == test.id)
        #expect(rig.service.activeSession != nil)
        #expect(rig.settings.settings.dosingMode == .basalTesting)
        #expect(rig.notifier.center.removedPending.isEmpty)
    }

    @Test("Discard does nothing to a finished fast, whose result Done clears") func discardNotFinished() async throws {
        let result = interrupted
        let rig = try makeRig(test: result, session: nil, mode: .closed, data: basalData())
        defer { cleanUp(rig.storage) }

        await rig.runner.discard()
        #expect(rig.runner.state?.phase == .finished)
        #expect(try #require(rig.storage.retrieve(Self.statePath, as: BasalTestState.self)).id == result.id)
        #expect(rig.notifier.center.removedPending.isEmpty)
        #expect(rig.notifier.posted.isEmpty)
    }

    // MARK: - The Result's words

    @Test("The Result's paragraphs moved unchanged") func resultParagraphs() throws {
        let invalid = interrupted
        let interference = try #require(invalid.interference)
        #expect(BasalTestEvaluator.resultParagraphs(for: .invalid, test: invalid, evaluation: nil) == [interference])
        #expect(
            BasalTestEvaluator.resultParagraphs(for: .inconclusive, test: unchecked, evaluation: nil).first
                == "Trio couldn't read the pump history to check for a low, so it can't judge this fast."
        )
    }
}
