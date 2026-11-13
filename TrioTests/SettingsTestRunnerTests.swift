import Combine
import Foundation
import SwiftUI
import Testing
import UserNotifications

@testable import Trio

// MARK: - Runners for the runtime tests

/// An idle runner that calls `onRead` with the number of reads of `isRunning` so far once armed, so a test can act in
/// the middle of the service's idle check.
private final class ProbingRunner: SettingsTestRunner {
    let kind: SettingsTestKind
    private let lock = NSLock()
    private var reads = 0
    private var onRead: ((Int) -> Void)?

    init(kind: SettingsTestKind) {
        self.kind = kind
    }

    func arm(_ onRead: @escaping (Int) -> Void) {
        lock.withLock {
            reads = 0
            self.onRead = onRead
        }
    }

    var isRunning: Bool {
        let (read, hook) = lock.withLock { () -> (Int, ((Int) -> Void)?) in
            reads += 1
            return (reads, onRead)
        }
        hook?(read)
        return false
    }

    func check() async {}
}

/// A runner a test sets running, whose check waits at a gate until the test opens it, counting the checks that got in.
private final class GatedRunner: SettingsTestRunner {
    let kind: SettingsTestKind
    private let lock = NSLock()
    private var _running = false
    private var _entered = 0
    private var gateOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(kind: SettingsTestKind) {
        self.kind = kind
    }

    var running: Bool {
        get { lock.withLock { _running } }
        set { lock.withLock { _running = newValue } }
    }

    var isRunning: Bool { running }
    var entered: Int { lock.withLock { _entered } }

    func check() async {
        lock.withLock { _entered += 1 }
        await withCheckedContinuation { continuation in
            let passes = lock.withLock { () -> Bool in
                if gateOpen { return true }
                waiters.append(continuation)
                return false
            }
            if passes { continuation.resume() }
        }
    }

    /// Lets the checks waiting go, and every later one straight through.
    func openGate() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            gateOpen = true
            defer { waiters = [] }
            return waiters
        }
        released.forEach { $0.resume() }
    }
}

// MARK: - Runtime

@Suite("Settings test runtime", .serialized, .settingsTestFiles) struct SettingsTestRuntimeTests {
    /// A basal test in Basal Testing that began `startedAt`, with an hour left.
    private func basalSession(startedAt: Date) -> SettingsTestSession {
        SettingsTestSession(
            kind: .basal,
            startedAt: startedAt,
            expiresAt: Date().addingTimeInterval(3600),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )
    }

    /// On a whole second, so the kept record reads back exactly.
    private var anHourAgo: Date {
        Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded(.down))
    }

    private func cleanUp(_ storage: FileStorage) {
        storage.remove("trio/settings_test_session.json")
        storage.remove("trio/settings_test_history.json")
        storage.remove("trio/settings_test_last_end.json")
    }

    @Test("A running runner's check starts after the watchdog's own end, from the same check") func runnerAfterWatchdog() async throws {
        let data = FakeSettingsTestData()
        let startedAt = anHourAgo
        var built: FakeSettingsTestRunner?
        // Running at init, so the startup check includes it. The low suspend is added after that check has run, so it finds
        // nothing.
        let harness = makeTestService(
            mode: .basalTesting,
            existing: basalSession(startedAt: startedAt),
            data: data,
            runners: { context, _ in
                let runner = FakeSettingsTestRunner(kind: .basal, service: context.service, running: true)
                built = runner
                return [runner]
            }
        )
        defer { cleanUp(harness.storage) }
        let runner = try #require(built)

        #expect(await eventually { runner.checks >= 1 })
        let before = runner.checks
        data.trioSuspends(at: startedAt.addingTimeInterval(600))
        await harness.service.checkSessionAndRunners()
        #expect(harness.service.activeSession == nil)
        #expect(runner.checks == before + 1)
        #expect(runner.lastEndSeen?.cause == .low)
    }

    @Test("A runner still running is checked with no session; an idle one is not") func runnerWithoutSession() async {
        var built: [FakeSettingsTestRunner] = []
        // Nothing on disk and both fakes idle at init, so there is no startup check.
        let harness = makeTestService(runners: { context, _ in
            built = [
                FakeSettingsTestRunner(kind: .basal, service: context.service),
                FakeSettingsTestRunner(kind: .isf, service: context.service)
            ]
            return built
        })
        defer { cleanUp(harness.storage) }
        let running = built[0]
        let idle = built[1]

        running.running = true
        await harness.service.checkSessionAndRunners()
        #expect(running.checks == 1)
        #expect(idle.checks == 0)
    }

    @Test("The service gives each kind's runner, and none for a kind without one") func runnerForKind() {
        var built: FakeSettingsTestRunner?
        let harness = makeTestService(runners: { context, _ in
            let runner = FakeSettingsTestRunner(kind: .isf, service: context.service)
            built = runner
            return [runner]
        })
        defer { cleanUp(harness.storage) }

        #expect(harness.service.runner(for: .isf) === built)
        #expect(harness.service.runner(for: .basal) == nil)
        #expect(harness.service.runner(for: .carbRatio) == nil)
    }

    @Test(
        "Data changes make one tick, after the debounce: the runner's check it starts, and one after the service's own"
    ) func dataChangeChecksOnce() async throws {
        let triggers = PassthroughSubject<Void, Never>()
        var built: FakeSettingsTestRunner?
        // Nothing on disk and the fake idle at init, so there is no startup check.
        let harness = makeTestService(
            triggers: triggers.eraseToAnyPublisher(),
            triggerDebounce: .milliseconds(50),
            runners: { context, _ in
                let runner = FakeSettingsTestRunner(kind: .basal, service: context.service)
                built = runner
                return [runner]
            }
        )
        defer {
            harness.service.end(kind: .basal)
            cleanUp(harness.storage)
        }
        let runner = try #require(built)

        harness.service.begin(kind: .basal, expiresIn: 3600, restoring: [])
        runner.running = true
        triggers.send(())
        triggers.send(())
        triggers.send(())
        // The tick starts the runner's check on its own, and the service's check asks it for one more once its reads are
        // done, so the runner reads any ending the service kept.
        #expect(await eventually { runner.checks == 2 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(runner.checks == 2)
    }

    @Test("A pump history, glucose, determination or carbs change is a trigger; another isn't") func triggerEntities() {
        for name in ["GlucoseStored", "OrefDetermination", "PumpEventStored", "CarbEntryStored"] {
            #expect(SettingsTestRuntime.triggersCheck(entityNames: [name]))
        }
        #expect(SettingsTestRuntime.triggersCheck(entityNames: ["OverrideStored", "PumpEventStored"]))
        #expect(!SettingsTestRuntime.triggersCheck(entityNames: ["OverrideStored"]))
        #expect(!SettingsTestRuntime.triggersCheck(entityNames: [nil]))
        #expect(!SettingsTestRuntime.triggersCheck(entityNames: []))
    }

    @Test("Data changes with nothing running check nothing") func dataChangeIdle() async throws {
        let triggers = PassthroughSubject<Void, Never>()
        var built: FakeSettingsTestRunner?
        let harness = makeTestService(
            triggers: triggers.eraseToAnyPublisher(),
            triggerDebounce: .milliseconds(50),
            runners: { context, _ in
                let runner = FakeSettingsTestRunner(kind: .basal, service: context.service)
                built = runner
                return [runner]
            }
        )
        defer { cleanUp(harness.storage) }
        let runner = try #require(built)

        // Running only now, after the service started with nothing to watch, so the watchdog is off: a data change must
        // not check it, which only the service's own `isWatching` guard stops.
        #expect(!harness.service.isWatching)
        runner.running = true
        triggers.send(())
        try await Task.sleep(for: .milliseconds(200))
        #expect(runner.checks == 0)
        #expect(!harness.service.isWatching)
    }

    @Test("A session recovered at launch checks its runner") func launchChecks() async throws {
        var built: FakeSettingsTestRunner?
        let harness = makeTestService(
            mode: .basalTesting,
            existing: basalSession(startedAt: anHourAgo),
            runners: { context, _ in
                let runner = FakeSettingsTestRunner(kind: .basal, service: context.service, running: true)
                built = runner
                return [runner]
            }
        )
        defer { cleanUp(harness.storage) }
        let runner = try #require(built)

        #expect(await eventually { runner.checks >= 1 })
        #expect(harness.service.isWatching)
    }

    @Test("A runner running at launch with no session starts the watchdog and checks") func launchChecksRunnerWithoutSession() async throws {
        var built: FakeSettingsTestRunner?
        let harness = makeTestService(runners: { context, _ in
            let runner = FakeSettingsTestRunner(kind: .isf, service: context.service, running: true)
            built = runner
            return [runner]
        })
        defer { cleanUp(harness.storage) }
        let runner = try #require(built)

        #expect(await eventually { runner.checks >= 1 })
        // Still running, so the watchdog goes on.
        #expect(harness.service.isWatching)
    }

    @Test("The watchdog runs while a runner runs after its session ended, and stops when nothing runs") func watchdogLife() async throws {
        var built: FakeSettingsTestRunner?
        let harness = makeTestService(runners: { context, _ in
            let runner = FakeSettingsTestRunner(kind: .basal, service: context.service)
            built = runner
            return [runner]
        })
        defer { cleanUp(harness.storage) }
        let runner = try #require(built)

        harness.service.begin(kind: .basal, expiresIn: 3600, restoring: [])
        runner.running = true
        #expect(harness.service.isWatching)

        harness.service.end(kind: .basal)
        await harness.service.checkSessionAndRunners()
        #expect(harness.service.isWatching)

        runner.running = false
        await harness.service.checkSession()
        #expect(!harness.service.isWatching)
    }

    @Test("The watchdog keeps running for a live session, with no runner or an idle one") func watchdogStaysWithASession() async throws {
        for withIdleRunner in [false, true] {
            let harness = makeTestService(runners: { context, _ in
                withIdleRunner ? [FakeSettingsTestRunner(kind: .basal, service: context.service)] : []
            })
            defer { cleanUp(harness.storage) }

            harness.service.begin(kind: .basal, expiresIn: 3600, restoring: [])
            #expect(harness.service.isWatching)
            await harness.service.checkSession()
            #expect(harness.service.activeSession != nil)
            #expect(harness.service.isWatching, "idle runner: \(withIdleRunner)")

            harness.service.end(kind: .basal)
            await harness.service.checkSession()
            #expect(!harness.service.isWatching, "idle runner: \(withIdleRunner)")
        }
    }

    @Test("The idle check can't stop the watchdog of a session that begins while it checks") func beginDuringTheIdleCheck() async throws {
        var built: ProbingRunner?
        let harness = makeTestService(runners: { _, _ in
            let runner = ProbingRunner(kind: .basal)
            built = runner
            return [runner]
        })
        let service = harness.service
        defer {
            service.end(kind: .basal)
            cleanUp(harness.storage)
        }
        let runner = try #require(built)

        // With no session `checkSession` reads `isRunning` twice: for the runners to check, then in the idle check, after
        // it saw no session. A session begun on another thread right then must keep its watchdog.
        runner.arm { read in
            guard read == 2 else { return }
            Thread.detachNewThread { service.begin(kind: .basal, expiresIn: 3600, restoring: []) }
            let deadline = Date().addingTimeInterval(2)
            while service.activeSession == nil, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            // Long enough for `begin` to reach its watchdog start, if nothing holds it back.
            Thread.sleep(forTimeInterval: 0.05)
        }
        await service.checkSession()
        #expect(await eventually { service.activeSession != nil })
        #expect(await eventually { service.isWatching })
    }

    @Test(
        "A runner's checks asked for while one runs make one more run of it, however many were asked"
    ) func backgroundChecksCoalesce() async throws {
        var built: GatedRunner?
        let harness = makeTestService(runners: { _, _ in
            let runner = GatedRunner(kind: .basal)
            built = runner
            return [runner]
        })
        defer { cleanUp(harness.storage) }
        let runner = try #require(built)

        runner.running = true
        harness.service.checkSessionInBackground()
        #expect(await eventually { runner.entered == 1 })
        // The first is held at the gate: three more come in meanwhile.
        harness.service.checkSessionInBackground()
        harness.service.checkSessionInBackground()
        harness.service.checkSessionInBackground()
        try await Task.sleep(for: .milliseconds(200))
        #expect(runner.entered == 1)

        runner.openGate()
        #expect(await eventually { runner.entered == 2 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(runner.entered == 2)
        runner.running = false
    }

    /// What ends the session while a runner's check hangs.
    enum HungRunnerEnding: CaseIterable {
        case expiry
        case low
        case carbs
    }

    /// What asks the service to check: its watchdog's tick, or a change of the data a test reads.
    enum CheckCall: CaseIterable {
        case tick
        case dataChange
    }

    @Test(
        "A runner check that never returns can't stop the service ending a session and bringing the usual mode back",
        arguments: HungRunnerEnding.allCases, CheckCall.allCases
    ) func hungRunnerCheck(_ ending: HungRunnerEnding, _ call: CheckCall) async throws {
        let data = FakeSettingsTestData()
        let triggers = PassthroughSubject<Void, Never>()
        let startedAt = anHourAgo
        var session = basalSession(startedAt: startedAt)
        if ending == .expiry {
            // Past its deadline only after the launch check has run.
            session.expiresAt = Date().addingTimeInterval(1)
        }
        var built: GatedRunner?
        let harness = makeTestService(
            mode: .basalTesting,
            existing: session,
            data: data,
            triggers: triggers.eraseToAnyPublisher(),
            runners: { _, _ in
                // Running at init, so the launch check reaches it, and its check waits at a gate this test never opens: a
                // stuck Core Data read, say.
                let runner = GatedRunner(kind: .basal)
                runner.running = true
                built = runner
                return [runner]
            }
        )
        defer { cleanUp(harness.storage) }
        let runner = try #require(built)
        // Let go only once the test is over, so nothing is left waiting.
        defer {
            runner.running = false
            runner.openGate()
        }

        #expect(await eventually { runner.entered == 1 })
        // The launch check's own reads found nothing to end the session.
        #expect(harness.service.activeSession != nil)
        switch ending {
        case .expiry:
            while Date() < session.expiresAt {
                try await Task.sleep(for: .milliseconds(20))
            }
        case .low:
            data.trioSuspends(at: startedAt.addingTimeInterval(600))
        case .carbs:
            data.carbs = [startedAt.addingTimeInterval(600)]
        }
        switch call {
        case .tick:
            // What the watchdog's timer calls, on the main thread.
            await MainActor.run { harness.service.watchdogTick() }
        case .dataChange:
            triggers.send(())
        }

        #expect(await eventually { harness.service.activeSession == nil })
        #expect(harness.settings.settings.dosingMode == .closed)
        switch ending {
        case .expiry: #expect(harness.service.lastEnd() == nil)
        case .low: #expect(harness.service.lastEnd()?.cause == .low)
        case .carbs: #expect(harness.service.lastEnd()?.cause == .carbsLogged)
        }
        // The stuck check is still the only one: the service asked it for one more run, and piled up nothing.
        #expect(runner.entered == 1)
    }

    @Test(
        "A read of the service's own that never returns can't hold back the expiry restore",
        arguments: CheckCall.allCases
    ) func stuckOwnReadExpiry(_ call: CheckCall) async throws {
        let data = FakeSettingsTestData()
        let triggers = PassthroughSubject<Void, Never>()
        // Every read of the temp basals, the service's first, waits at a gate this test never opens: a stuck Core Data read
        // on the service's own context, say.
        let gate = TestGate()
        data.onTempBasals = { await gate.pass() }
        // Past its deadline already: the launch check, low first, is held at its read before it reaches the expiry check.
        var session = basalSession(startedAt: anHourAgo)
        session.expiresAt = Date().addingTimeInterval(-60)
        let harness = makeTestService(
            mode: .basalTesting,
            existing: session,
            data: data,
            triggers: triggers.eraseToAnyPublisher()
        )
        defer { cleanUp(harness.storage) }
        // Let go only once the test is over, so nothing is left waiting.
        defer { gate.open() }

        #expect(await eventually { gate.waiting == 1 })
        #expect(harness.service.activeSession != nil)
        switch call {
        case .tick:
            // What the watchdog's timer calls, on the main thread.
            await MainActor.run { harness.service.watchdogTick() }
        case .dataChange:
            triggers.send(())
        }

        #expect(await eventually { harness.service.activeSession == nil })
        #expect(harness.settings.settings.dosingMode == .closed)
        // Still the one read: the expiry check needed none.
        #expect(data.tempBasalReads == 1)
    }

    @Test(
        "A read of the service's own that never returns can't stop the runners' checks",
        arguments: CheckCall.allCases
    ) func stuckOwnReadRunnersChecked(_ call: CheckCall) async throws {
        let data = FakeSettingsTestData()
        let triggers = PassthroughSubject<Void, Never>()
        // Every read of the temp basals, the service's first, waits at a gate this test opens only at its end.
        let gate = TestGate()
        data.onTempBasals = { await gate.pass() }
        var built: FakeSettingsTestRunner?
        let harness = makeTestService(
            mode: .basalTesting,
            existing: basalSession(startedAt: anHourAgo),
            data: data,
            triggers: triggers.eraseToAnyPublisher(),
            runners: { context, _ in
                let runner = FakeSettingsTestRunner(kind: .basal, service: context.service, running: true)
                built = runner
                return [runner]
            }
        )
        defer { cleanUp(harness.storage) }
        let runner = try #require(built)
        defer {
            runner.running = false
            gate.open()
        }

        // The launch check is held at its first read, before it would start the runner's.
        #expect(await eventually { gate.waiting == 1 })
        #expect(runner.checks == 0)
        switch call {
        case .tick:
            await MainActor.run { harness.service.watchdogTick() }
        case .dataChange:
            triggers.send(())
        }
        #expect(await eventually { runner.checks >= 1 })
        #expect(data.tempBasalReads == 1)
    }

    @Test("The service's own checks run one at a time; calls during one make one more, however many") func ownChecksCoalesce(
    ) async throws {
        let data = FakeSettingsTestData()
        let gate = TestGate()
        // Held before the service is made, so its launch check waits at its first read.
        data.onTempBasals = { await gate.pass() }
        let harness = makeTestService(mode: .basalTesting, existing: basalSession(startedAt: anHourAgo), data: data)
        defer { cleanUp(harness.storage) }

        #expect(await eventually { gate.waiting == 1 })
        harness.service.checkSessionInBackground()
        harness.service.checkSessionInBackground()
        harness.service.checkSessionInBackground()
        try await Task.sleep(for: .milliseconds(200))
        #expect(data.tempBasalReads == 1)

        gate.open()
        #expect(await eventually { data.tempBasalReads == 2 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(data.tempBasalReads == 2)
        #expect(harness.service.activeSession != nil)
    }

    @Test("The files trait gives each test of its suite its own scope") func filesTraitScopesEachTest() {
        // Only the per-test scope removes a test's files after it; the suite's scope alone would leave them to the next.
        #expect(SettingsTestFilesTrait.inTestScope)
        #expect(SettingsTestFilesTrait.isHeld)
    }

    @Test("The expiry notice opens its test") func expiryContent() {
        let content = BaseSettingsTestService.expiryContent(kind: .isf)
        #expect(content.title == "Test time is up")
        #expect(content.categoryIdentifier == SettingsTestNotice.category)
        #expect(content.userInfo[SettingsTestNotice.kindKey] as? String == "isf")
    }

    @Test("The files trait removes what a test left on disk, passed or not") func filesTraitCleansUp() async throws {
        struct Failed: Error {}
        let storage = BaseFileStorage()
        let test = try #require(Test.current)
        let fast = BasalTestState(
            startedAt: Date(),
            plannedDuration: 3600,
            startGlucose: 110,
            startIOB: 0,
            previousMode: .closed,
            timeBlock: "Morning"
        )
        try await SettingsTestFilesTrait().provideScope(for: test, testCase: Test.Case.current) {
            storage.save(fast, as: "trio/basal_test_state.json")
            #expect(storage.retrieve("trio/basal_test_state.json", as: BasalTestState.self) != nil)
        }
        #expect(storage.retrieve("trio/basal_test_state.json", as: BasalTestState.self) == nil)

        await #expect(throws: Failed.self) {
            try await SettingsTestFilesTrait().provideScope(for: test, testCase: Test.Case.current) {
                storage.save(fast, as: "trio/basal_test_state.json")
                throw Failed()
            }
        }
        #expect(storage.retrieve("trio/basal_test_state.json", as: BasalTestState.self) == nil)
    }

    @Test("A test that can't begin says why") func beginErrorMessages() {
        #expect(SettingsTestBeginError.otherTestRunning.message == "Another settings test is running. Finish it first.")
        // The Check screen's mode check's own sentence.
        #expect(
            SettingsTestBeginError.basalTestingOn.message
                == "Switch to your usual dosing mode first, so Trio can return you to it"
        )
        #expect(
            SettingsTestBeginError.settingsUnreadable.message
                == "Trio couldn't read your ISF and glucose target. Check them, then try again."
        )
        // The screens' own words for a read that failed, and Trio's for a change it couldn't save.
        #expect(
            SettingsTestBeginError.dataUnreadable("The disk is full.")
                .message == "Couldn't read your data: The disk is full."
        )
        #expect(SettingsTestBeginError.notSaved.message == "Could not save the change.")
    }
}

// MARK: - Notices

@Suite("Settings test notices") struct SettingsTestNoticeTests {
    @Test("Each kind's notices have their own identifiers") func identifiers() {
        #expect(SettingsTestNotice.finished(.isf).identifier == "Trio.settingsTest.isf.ended")
        #expect(SettingsTestNotice.finished(.basal).identifier == "Trio.settingsTest.basal.ended")
    }

    @Test("A finished notice says the result is ready") func finishedCopy() {
        #expect(SettingsTestNotice.finished(.isf).title == "ISF Test Finished")
        #expect(SettingsTestNotice.finished(.isf).body == "Your result is ready. Tap to see what your ISF did.")
        #expect(SettingsTestNotice.finished(.basal).title == "Basal Test Finished")
        #expect(SettingsTestNotice.finished(.basal).body == "Your result is ready. Tap to see how your basal held up.")
    }

    @Test("An ended notice gives the sentence, and says the mode is back only when it is") func endedCopy() {
        let moving = "The bolus came while your glucose was still moving, so the test can't be judged."
        #expect(SettingsTestNotice.ended(.isf, sentence: moving, modeBack: true).title == "ISF Test Ended")
        #expect(
            SettingsTestNotice.ended(.isf, sentence: moving, modeBack: true).body == moving + " Your usual dosing mode is back."
        )
        #expect(SettingsTestNotice.ended(.isf, sentence: moving, modeBack: false).body == moving)
        let restored = "The dosing mode changed during the test, so it has no result. Your usual dosing mode is back."
        #expect(SettingsTestNotice.ended(.isf, sentence: restored, modeBack: true).body == restored)
        #expect(
            SettingsTestNotice.ended(.basal, sentence: "Carbs were logged during the fast.", modeBack: true).title
                == "Basal Test Ended"
        )
    }

    @Test("A notice's content carries its category and kind") func content() {
        let content = SettingsTestNotifier.content(for: .finished(.basal))
        #expect(content.categoryIdentifier == "Trio.settingsTest")
        #expect(content.userInfo["settingsTestKind"] as? String == "basal")
    }

    @Test(
        "Posting a notice withdraws the legacy finished notifications and adds its own, delivered at once"
    ) func postWithdrawsLegacy() {
        let center = RecordingNotificationCenter()
        let notifier = SettingsTestNotifier(center: center)
        notifier.post(.finished(.isf))
        #expect(Set(center.removedPending).isSuperset(of: ["Trio.isfTestFinished", "Trio.basalTestFinished"]))
        #expect(Set(center.removedDelivered).isSuperset(of: ["Trio.isfTestFinished", "Trio.basalTestFinished"]))
        #expect(center.added.map(\.identifier) == ["Trio.settingsTest.isf.ended"])
        #expect(center.added.first?.trigger == nil)
    }

    @Test("A notification the center refuses is logged") func failedAddIsLogged() {
        struct Refused: Error {}
        let center = RecordingNotificationCenter()
        center.addError = Refused()
        // The logger's capture is shared by the whole process, and the logging suites use it too: try again if theirs
        // took its place for a moment.
        var logged: [LogRecord] = []
        for _ in 0 ..< 5 where logged.isEmpty {
            let sink = InMemoryLogSink(capacity: 1000)
            TrioLogger.capturing(into: sink) { SettingsTestNotifier(center: center).post(.finished(.isf)) }
            logged = sink.snapshot().filter { $0.file == "SettingsTestNotices.swift" && $0.level == .warning }
        }
        #expect(logged.contains { $0.message.contains("Trio.settingsTest.isf.ended") })
    }

    @Test("Withdrawing a notice removes its pending and delivered copies, and no other") func withdrawRemovesBoth() {
        let center = RecordingNotificationCenter()
        let notifier = SettingsTestNotifier(center: center)
        notifier.withdraw(.isf, .step)
        #expect(center.removedPending == ["Trio.settingsTest.isf.step"])
        #expect(center.removedDelivered == ["Trio.settingsTest.isf.step"])
        #expect(center.added.isEmpty)
    }

    @Test("A tap on a settings test notice names its kind; any other is left alone") func tapKind() {
        #expect(SettingsTestHooks.kind(category: "Trio.settingsTest", userInfo: ["settingsTestKind": "isf"]) == .isf)
        #expect(SettingsTestHooks.kind(category: "other", userInfo: ["settingsTestKind": "isf"]) == nil)
        #expect(SettingsTestHooks.kind(category: "Trio.settingsTest", userInfo: ["settingsTestKind": "nope"]) == nil)
    }
}

// MARK: - Screen opener

/// An opener over a fake router, with the key window's sheet and the 1 s re-check under the test's hand.
@MainActor private final class OpenerRig {
    let router = SettingsTestFakeRouter()
    let ticks = PassthroughSubject<Void, Never>()
    /// Trio going to the background.
    let backgrounds = PassthroughSubject<Void, Never>()
    /// What `keyWindowPresents` answers.
    var presents = false
    private(set) var opener: SettingsTestScreenOpener!

    init() {
        opener = SettingsTestScreenOpener(
            router: { [router] in router },
            keyWindowPresents: { [unowned self] in presents },
            recheckTicks: { [ticks] in ticks.eraseToAnyPublisher() },
            backgrounded: backgrounds.eraseToAnyPublisher()
        )
    }
}

@Suite("Settings test screen opener") @MainActor struct SettingsTestScreenOpenerTests {
    private let rig = OpenerRig()
    private var opener: SettingsTestScreenOpener { rig.opener }
    private var router: SettingsTestFakeRouter { rig.router }

    @Test("A tap opens the test's screen when nothing else is shown") func opensTheTestScreen() {
        #expect(opener.open(.isf))
        #expect(router.mainModalScreen.value == .isfTest)
    }

    @Test("Each test opens its own screen") func screensByKind() {
        #expect(SettingsTestKind.basal.testScreen == .basalTest)
        #expect(SettingsTestKind.isf.testScreen == .isfTest)
        #expect(SettingsTestKind.carbRatio.testScreen == .carbRatioTest)
    }

    @Test("A tap still waiting when Trio goes to the background is dropped, and opens nothing later") func droppedInBackground(
    ) async throws {
        router.mainModalScreen.send(.treatmentView)
        #expect(!opener.open(.isf))
        #expect(opener.pending == .isf)
        #expect(opener.isRechecking)

        rig.backgrounds.send(())
        #expect(await eventuallyOnMain { opener.pending == nil })
        #expect(!opener.isRechecking)
        // The sheet closes much later: the test's screen doesn't come up uninvited.
        router.mainModalScreen.send(nil)
        rig.ticks.send(())
        try await Task.sleep(for: .milliseconds(100))
        #expect(router.mainModalScreen.value == nil)

        // Going to the background with nothing waiting changes nothing; a new tap opens as usual.
        rig.backgrounds.send(())
        #expect(opener.open(.isf))
        #expect(router.mainModalScreen.value == .isfTest)
    }

    @Test("A tap over another sheet waits for it to close, then opens") func waitsForAnotherSheet() async {
        router.mainModalScreen.send(.treatmentView)
        #expect(!opener.open(.isf))
        #expect(router.mainModalScreen.value == .treatmentView)
        #expect(opener.isRechecking)
        router.mainModalScreen.send(nil)
        #expect(await eventuallyOnMain { router.mainModalScreen.value == .isfTest })
        // Pending until the screen has appeared, not until it was sent.
        #expect(opener.pending == .isf)
        #expect(opener.isRechecking)
        opener.screenAppeared(.isf)
        #expect(opener.pending == nil)
        #expect(!opener.isRechecking)
    }

    @Test("A tap at launch opens the screen even though Main wipes the router as it appears") func coldLaunchTap() async throws {
        // Sent before Main exists, and wiped when Main's `$modal` sends its first `nil`.
        #expect(opener.open(.isf))
        #expect(router.mainModalScreen.value == .isfTest)
        router.mainModalScreen.send(nil)
        // Not at once, but on the next tick of the 1 s timer, when what Main echoes has settled.
        try await Task.sleep(for: .milliseconds(100))
        #expect(router.mainModalScreen.value == nil)
        rig.ticks.send(())
        #expect(router.mainModalScreen.value == .isfTest)
        opener.screenAppeared(.isf)
        #expect(opener.pending == nil)
        #expect(!opener.isRechecking)
        #expect(opener.wasOpenedFromNotice(.isf))
    }

    @Test("The screen shows through Main's own pipelines when the tap came before Main subscribed") func coldLaunchThroughMain(
    ) async throws {
        #expect(opener.open(.isf))

        // `Main.StateModel.subscribe()`: the router's screen goes to `modal` on the main queue, and `modal` sending `nil`
        // (its first value included) sends `nil` to the router. SwiftUI shows what `modal` holds once the turns of the
        // main queue that set it are done, so a screen appears when `modal` has held it for a moment.
        let modal = CurrentValueSubject<Screen?, Never>(nil)
        var subscriptions: Set<AnyCancellable> = []
        router.mainModalScreen
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { modal.send($0) }
            .store(in: &subscriptions)
        modal
            .removeDuplicates()
            .filter { $0 == nil }
            .sink { [router] _ in router.mainModalScreen.send(nil) }
            .store(in: &subscriptions)
        modal
            .debounce(for: .milliseconds(30), scheduler: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [opener] screen in
                if screen == .isfTest { opener.screenAppeared(.isf) }
            }
            .store(in: &subscriptions)

        // The wipe has gone round and nothing shows. The timer sends the screen again, and it stays.
        try await Task.sleep(for: .milliseconds(150))
        #expect(modal.value == nil)
        #expect(opener.pending == .isf)
        rig.ticks.send(())
        #expect(await eventuallyOnMain { modal.value == .isfTest })
        #expect(await eventuallyOnMain { opener.pending == nil })
        #expect(opener.wasOpenedFromNotice(.isf))
        withExtendedLifetime(subscriptions) {}
    }

    @Test("A screen that keeps vanishing is sent five more times, then given up on") func givesUpAfterFiveRepresents() {
        #expect(opener.open(.isf))
        for _ in 1 ... SettingsTestScreenOpener.maxRepresents {
            router.mainModalScreen.send(nil)
            rig.ticks.send(())
            #expect(router.mainModalScreen.value == .isfTest)
        }
        #expect(opener.pending == .isf)
        // The sixth wipe: no more.
        router.mainModalScreen.send(nil)
        rig.ticks.send(())
        #expect(router.mainModalScreen.value == nil)
        #expect(opener.pending == nil)
        #expect(!opener.isRechecking)
    }

    @Test("A screen that appears on a later try is opened from a notice") func appearsOnALaterTry() {
        #expect(opener.open(.isf))
        for _ in 1 ... 3 {
            router.mainModalScreen.send(nil)
            rig.ticks.send(())
            #expect(router.mainModalScreen.value == .isfTest)
        }
        opener.screenAppeared(.isf)
        #expect(opener.pending == nil)
        #expect(opener.wasOpenedFromNotice(.isf))
    }

    @Test("A screen that was sent and didn't appear is not sent again by a change of the router") func notOnRouterChange() async throws {
        #expect(opener.open(.isf))
        router.mainModalScreen.send(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(router.mainModalScreen.value == nil)
        #expect(opener.pending == .isf)
    }

    @Test("The latest tap wins while one waits") func latestTapWins() async {
        router.mainModalScreen.send(.treatmentView)
        #expect(!opener.open(.isf))
        #expect(!opener.open(.basal))
        #expect(opener.pending == .basal)
        router.mainModalScreen.send(nil)
        #expect(await eventuallyOnMain { router.mainModalScreen.value == .basalTest })
    }

    @Test("A newer tap replaces one whose screen was sent but hasn't appeared") func newerTapReplacesASentOne() async {
        #expect(opener.open(.isf))
        #expect(!opener.open(.basal))
        #expect(opener.pending == .basal)
        // The first screen arrives after all: it is shown, and the newer tap goes on waiting for it to close.
        opener.screenAppeared(.isf)
        #expect(opener.pending == .basal)
        #expect(!opener.wasOpenedFromNotice(.isf))
        opener.screenDisappeared(.isf)
        router.mainModalScreen.send(nil)
        #expect(await eventuallyOnMain { router.mainModalScreen.value == .basalTest })
    }

    @Test("A sheet shown outside the router keeps a tap waiting too") func waitsForASecondaryModal() async {
        router.mainSecondaryModalView.send(AnyView(EmptyView()))
        #expect(!opener.open(.isf))
        router.mainSecondaryModalView.send(nil)
        #expect(await eventuallyOnMain { router.mainModalScreen.value == .isfTest })
    }

    @Test("A sheet still animating out doesn't strand a pending tap: the 1 s re-check opens it") func recheckOpens() {
        rig.presents = true
        #expect(!opener.open(.isf))
        rig.ticks.send(())
        #expect(router.mainModalScreen.value == nil)
        rig.presents = false
        rig.ticks.send(())
        #expect(router.mainModalScreen.value == .isfTest)
        opener.screenAppeared(.isf)
        #expect(!opener.isRechecking)
    }

    @Test("A waiting tap isn't opened over a screen the user opened meanwhile") func notOverAScreenOpenedMeanwhile() async throws {
        router.mainModalScreen.send(.treatmentView)
        #expect(!opener.open(.isf))
        opener.screenAppeared(.isf)
        router.mainModalScreen.send(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(router.mainModalScreen.value == nil)
        #expect(opener.pending == nil)
        #expect(!opener.isRechecking)
        #expect(!opener.wasOpenedFromNotice(.isf))
    }

    @Test("Open Treatments from a notice-opened test brings the test back when Treatments closes") func backAfterTreatments() async {
        #expect(opener.open(.isf))
        opener.screenAppeared(.isf)
        #expect(opener.wasOpenedFromNotice(.isf))
        opener.treatmentsOpened(from: .isf)
        router.mainModalScreen.send(.treatmentView)
        opener.screenDisappeared(.isf)
        router.mainModalScreen.send(nil)
        #expect(await eventuallyOnMain { router.mainModalScreen.value == .isfTest })
        opener.screenAppeared(.isf)
        #expect(opener.wasOpenedFromNotice(.isf))
        #expect(opener.pending == nil)
    }

    @Test("A screen opened from Settings isn't one the opener presented") func notFromNotice() {
        opener.screenAppeared(.isf)
        #expect(!opener.wasOpenedFromNotice(.isf))
    }

    @Test("A screen is from a notice once it has appeared, not when it was sent") func fromNoticeOnAppearance() {
        #expect(opener.open(.isf))
        #expect(!opener.wasOpenedFromNotice(.isf))
        opener.screenAppeared(.isf)
        #expect(opener.wasOpenedFromNotice(.isf))
    }

    @Test("A screen the opener presented is cleared when it disappears") func fromNoticeClears() {
        #expect(opener.open(.isf))
        opener.screenAppeared(.isf)
        #expect(opener.wasOpenedFromNotice(.isf))
        opener.screenDisappeared(.isf)
        opener.screenAppeared(.isf)
        #expect(!opener.wasOpenedFromNotice(.isf))
    }

    @Test("A tap opens no second copy of a screen that is showing") func notWhenShowing() {
        opener.screenAppeared(.isf)
        #expect(!opener.open(.isf))
        opener.screenDisappeared(.isf)
        #expect(opener.open(.isf))
    }

    @Test("A duplicate appear of one view doesn't leave its screen showing after it has gone") func duplicateAppear() {
        let view = UUID()
        opener.screenAppeared(.isf, viewID: view)
        opener.screenAppeared(.isf, viewID: view)
        opener.screenDisappeared(.isf, viewID: view)
        #expect(!opener.isShowing(.isf))
        #expect(opener.open(.isf))

        // The same without a view of its own.
        opener.screenAppeared(.basal)
        opener.screenAppeared(.basal)
        opener.screenDisappeared(.basal)
        #expect(!opener.isShowing(.basal))
    }

    @Test("Two views of one kind count apart") func twoViews() {
        let first = UUID()
        let second = UUID()
        opener.screenAppeared(.isf, viewID: first)
        opener.screenAppeared(.isf, viewID: second)
        opener.screenDisappeared(.isf, viewID: first)
        #expect(opener.isShowing(.isf))
        opener.screenDisappeared(.isf, viewID: second)
        #expect(!opener.isShowing(.isf))
    }

    @Test("The carb ratio test opens its own screen") func carbRatioScreen() {
        #expect(opener.open(.carbRatio))
        #expect(router.mainModalScreen.value == .carbRatioTest)
    }

    // MARK: A tap before the router exists (a launch from closed)

    /// An opener whose router isn't there until `available` is set, and a 1 s timer the test drives.
    private final class LateRouter {
        let ticks = PassthroughSubject<Void, Never>()
        let router = SettingsTestFakeRouter()
        var available: SettingsTestFakeRouter?
    }

    private func lateOpener(_ late: LateRouter) -> SettingsTestScreenOpener {
        SettingsTestScreenOpener(
            router: { late.available },
            keyWindowPresents: { false },
            recheckTicks: { late.ticks.eraseToAnyPublisher() }
        )
    }

    @Test("A tap before the router exists stays pending, and opens once a free router appears") func waitsForTheRouter() {
        let late = LateRouter()
        let opener = lateOpener(late)
        #expect(!opener.open(.isf))
        #expect(opener.pending == .isf)
        #expect(opener.isRechecking)
        // The timer finds no router for a long while: nothing is sent, nothing is given up, no try is counted.
        for _ in 1 ... 12 {
            late.ticks.send(())
        }
        #expect(late.router.mainModalScreen.value == nil)
        #expect(opener.pending == .isf)
        #expect(opener.isRechecking)
        // The router appears, free: the next look sends the screen, which stays pending until it appears.
        late.available = late.router
        late.ticks.send(())
        #expect(late.router.mainModalScreen.value == .isfTest)
        #expect(opener.pending == .isf)
        opener.screenAppeared(.isf)
        #expect(opener.pending == nil)
        #expect(!opener.isRechecking)
        #expect(opener.wasOpenedFromNotice(.isf))
    }

    @Test("A router that appears busy is waited on too, and its changes are watched from then on") func lateRouterBusy() async {
        let late = LateRouter()
        let opener = lateOpener(late)
        #expect(!opener.open(.isf))
        late.router.mainModalScreen.send(.treatmentView)
        late.available = late.router
        late.ticks.send(())
        // Not over another sheet.
        #expect(late.router.mainModalScreen.value == .treatmentView)
        #expect(opener.pending == .isf)
        // Its closing is seen on the router's change, without waiting for the timer.
        late.router.mainModalScreen.send(nil)
        #expect(await eventuallyOnMain { late.router.mainModalScreen.value == .isfTest })
        opener.screenAppeared(.isf)
        #expect(opener.pending == nil)
    }

    @Test("A tap before the router exists shows through Main's own pipelines once the router is there") func lateRouterThroughMain(
    ) async throws {
        let late = LateRouter()
        let opener = lateOpener(late)
        #expect(!opener.open(.isf))
        late.available = late.router

        // `Main.StateModel.subscribe()` as in `coldLaunchThroughMain`, once the router exists.
        let modal = CurrentValueSubject<Screen?, Never>(nil)
        var subscriptions: Set<AnyCancellable> = []
        late.router.mainModalScreen
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { modal.send($0) }
            .store(in: &subscriptions)
        modal
            .removeDuplicates()
            .filter { $0 == nil }
            .sink { [router = late.router] _ in router.mainModalScreen.send(nil) }
            .store(in: &subscriptions)
        modal
            .debounce(for: .milliseconds(30), scheduler: DispatchQueue.main)
            .compactMap { $0 }
            .sink { screen in
                if screen == .isfTest { opener.screenAppeared(.isf) }
            }
            .store(in: &subscriptions)

        // Main's first `nil` has gone round, nothing shows, the tap is still waiting; the timer sends the screen and it stays.
        try await Task.sleep(for: .milliseconds(150))
        #expect(modal.value == nil)
        #expect(opener.pending == .isf)
        late.ticks.send(())
        #expect(await eventuallyOnMain { modal.value == .isfTest })
        #expect(await eventuallyOnMain { opener.pending == nil })
        #expect(opener.wasOpenedFromNotice(.isf))
        withExtendedLifetime(subscriptions) {}
    }

    @Test(
        "A tap whose screen is already showing replaces an older tap still waiting, so closing it opens nothing"
    ) func tapOnTheShowingScreenReplacesAWaitingOne() async throws {
        // The ISF screen is showing, opened from Settings: a basal tap waits for it to close.
        router.mainModalScreen.send(.isfTest)
        opener.screenAppeared(.isf)
        #expect(!opener.open(.basal))
        #expect(opener.pending == .basal)
        // The newest tap is the ISF test's, whose screen is up already: nothing is left waiting.
        #expect(!opener.open(.isf))
        #expect(opener.pending == nil)
        #expect(!opener.isRechecking)
        opener.screenDisappeared(.isf)
        router.mainModalScreen.send(nil)
        rig.ticks.send(())
        try await Task.sleep(for: .milliseconds(100))
        #expect(router.mainModalScreen.value == nil)
    }
}

// MARK: - The delegate set at launch

/// A stand-in for the notification center that holds its delegate strongly, as a test needs.
private final class FakeDelegateHolder: SettingsTestDelegateHolder {
    var delegate: UNUserNotificationCenterDelegate?
}

private final class OtherDelegate: NSObject, UNUserNotificationCenterDelegate {}

/// Counts calls, from any thread.
private final class LaunchCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func hit() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Suite("Settings test launch notifications") @MainActor struct SettingsTestLaunchNotificationsTests {
    private let noticeInfo: [AnyHashable: Any] = ["settingsTestKind": "isf"]

    @Test("A tap on a test's notice reaches the opener, and its completion is called once") func routesATestNotice() async {
        let completed = LaunchCallCounter()
        var opened: [SettingsTestKind] = []
        let handled = SettingsTestLaunchNotifications.handle(
            category: "Trio.settingsTest",
            userInfo: noticeInfo,
            completion: { completed.hit() },
            open: { opened.append($0) }
        )
        #expect(handled)
        #expect(completed.value == 1)
        #expect(await eventuallyOnMain { opened == [.isf] })
        // And not again.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(opened == [.isf])
        #expect(completed.value == 1)
    }

    @Test("Each kind's notice opens its own kind") func eachKind() async {
        var opened: [SettingsTestKind] = []
        for raw in ["basal", "isf"] {
            SettingsTestLaunchNotifications.handle(
                category: "Trio.settingsTest",
                userInfo: ["settingsTestKind": raw],
                completion: {},
                open: { opened.append($0) }
            )
        }
        #expect(await eventuallyOnMain { opened == [.basal, .isf] })
    }

    @Test("Any other response only gets its completion handler, once, and opens nothing") func otherResponses() async {
        let completed = LaunchCallCounter()
        var opened: [SettingsTestKind] = []
        for (category, info) in [
            ("Trio.glucoseAlert", noticeInfo),
            ("Trio.settingsTest", [:]),
            ("Trio.settingsTest", ["settingsTestKind": "nope"]),
            ("", [:])
        ] as [(String, [AnyHashable: Any])] {
            let handled = SettingsTestLaunchNotifications.handle(
                category: category,
                userInfo: info,
                completion: { completed.hit() },
                open: { opened.append($0) }
            )
            #expect(!handled, "\(category) \(info)")
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(completed.value == 4)
        #expect(opened.isEmpty)
    }

    @Test("The delegate is set when there is none, and a delegate already set is left alone") func installOnlyWhenNone() {
        let none = FakeDelegateHolder()
        #expect(SettingsTestLaunchNotifications.install(on: none))
        #expect(none.delegate === SettingsTestLaunchNotifications.shared)

        let taken = FakeDelegateHolder()
        let theirs = OtherDelegate()
        taken.delegate = theirs
        #expect(!SettingsTestLaunchNotifications.install(on: taken))
        #expect(taken.delegate === theirs)

        // Installing twice leaves the same delegate, and says it did nothing the second time.
        #expect(!SettingsTestLaunchNotifications.install(on: none))
        #expect(none.delegate === SettingsTestLaunchNotifications.shared)
    }

    @Test("Setting another delegate replaces it, as the notifications manager does") func replacedLater() {
        let holder = FakeDelegateHolder()
        SettingsTestLaunchNotifications.install(on: holder)
        let manager = OtherDelegate()
        holder.delegate = manager
        #expect(holder.delegate === manager)
    }

    @Test("The launch delegate answers no notification being shown") func hasNoWillPresent() {
        // Nothing was presented in that window before, and nothing is now.
        #expect(!SettingsTestLaunchNotifications.shared.responds(
            to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))
        ))
        #expect(SettingsTestLaunchNotifications.shared.responds(
            to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))
        ))
    }
}

// MARK: - Coalescing

/// Counts the runs of a coalesced body, and the most that ran at once.
private final class RunCounter {
    private let lock = NSLock()
    private var _runs = 0
    private var _running = 0
    private var _mostAtOnce = 0

    var runs: Int { lock.withLock { _runs } }
    var mostAtOnce: Int { lock.withLock { _mostAtOnce } }

    func start() {
        lock.withLock {
            _runs += 1
            _running += 1
            _mostAtOnce = max(_mostAtOnce, _running)
        }
    }

    func stop() {
        lock.withLock { _running -= 1 }
    }
}

@Suite("Settings test check coalescer") struct SettingsTestCheckCoalescerTests {
    @Test("One run at a time, and the calls made during one share exactly one more") func callsDuringARunShareOneRerun() async {
        let coalescer = SettingsTestCheckCoalescer()
        let counter = RunCounter()
        let gate = TestGate()
        func body() async {
            counter.start()
            await gate.pass()
            counter.stop()
        }

        let first = Task { await coalescer.run { await body() } }
        #expect(await eventually { gate.waiting == 1 })
        let others = (0 ..< 3).map { _ in Task { await coalescer.run { await body() } } }
        #expect(await eventually { coalescer.waiting == 3 })
        // They wait, none of them starting a run of its own.
        #expect(counter.runs == 1)
        gate.open()
        await first.value
        for other in others {
            await other.value
        }
        #expect(counter.runs == 2)
        #expect(counter.mostAtOnce == 1)
        #expect(coalescer.waiting == 0)

        // Once it is idle, a call runs at once, on its own.
        await coalescer.run { await body() }
        #expect(counter.runs == 3)
    }
}

// MARK: - Screens

/// An ISF runner that keeps what its screen asked of it, and publishes what a test sends.
private final class RecordingISFTestRunner: ISFTestRunning {
    let subject = CurrentValueSubject<ISFTestRunnerState, Never>(ISFTestRunnerState())
    /// What Begin answers.
    var beginError: SettingsTestBeginError?
    /// What Begin publishes and then takes back, putting back what it held, as a Begin that fails after saving does.
    var publishesOnBegin: ISFTestRunnerState?
    private(set) var begins: [ISFTestBegin] = []
    private(set) var tablets: [ISFTestTabletsTaken] = []
    /// The other actions, by name, in the order asked.
    private(set) var actions: [String] = []

    var state: ISFTestRunnerState { subject.value }
    var statePublisher: AnyPublisher<ISFTestRunnerState, Never> { subject.eraseToAnyPublisher() }

    @MainActor func begin(_ begin: ISFTestBegin) async -> SettingsTestBeginError? {
        begins.append(begin)
        if let published = publishesOnBegin {
            let prior = subject.value
            subject.send(published)
            subject.send(prior)
        }
        return beginError
    }

    @MainActor func countAndGoOn() { actions.append("countAndGoOn") }
    @MainActor func tabletsTaken(_ tablets: ISFTestTabletsTaken) { self.tablets.append(tablets) }
    @MainActor func moveToDose() { actions.append("moveToDose") }
    @MainActor func workOutDose(_: ISFTestDoseInputs) { actions.append("workOutDose") }
    @MainActor func raiseFirst() { actions.append("raiseFirst") }
    @MainActor func endEarly() async { actions.append("endEarly") }
    @MainActor func discard() { actions.append("discard") }
    @MainActor func acknowledgeResult() { actions.append("acknowledgeResult") }
    /// How many checks were asked for.
    @MainActor private(set) var checks = 0
    @MainActor func check() async { checks += 1 }
}

/// A basal runner that keeps the Begins its screen asked for, and publishes what a test sends.
private final class RecordingBasalTestRunner: BasalTestRunning {
    let subject = CurrentValueSubject<BasalTestState?, Never>(nil)
    /// What Start answers.
    var beginError: SettingsTestBeginError?
    /// What Start publishes and then takes back, putting back what it held, as a Start that fails after saving does.
    var publishesOnBegin: BasalTestState?
    private(set) var begins: [BasalTestBegin] = []

    var state: BasalTestState? { subject.value }
    var statePublisher: AnyPublisher<BasalTestState?, Never> { subject.eraseToAnyPublisher() }

    @MainActor func begin(_ begin: BasalTestBegin) async -> SettingsTestBeginError? {
        begins.append(begin)
        if let published = publishesOnBegin {
            let prior = subject.value
            subject.send(published)
            subject.send(prior)
        }
        return beginError
    }

    /// The other actions, by name, in the order asked.
    @MainActor private(set) var actions: [String] = []
    @MainActor private(set) var checks = 0
    @MainActor func endEarly() async { actions.append("endEarly") }
    @MainActor func discard() { actions.append("discard") }
    @MainActor func acknowledgeResult() { actions.append("acknowledgeResult") }
    @MainActor func check() async { checks += 1 }
}

private extension ISFTest.StateModel {
    /// Next, as the Check step does it: the page it goes to comes up on screen (`checkPageAppeared`).
    func goNext() {
        nextCheckPage()
        checkPageAppeared(shownCheckPage)
    }

    /// Back, as the Check step does it.
    func goBack() {
        previousCheckPage()
        checkPageAppeared(shownCheckPage)
    }
}

/// What the ISF screen reads, as a test sets it: `data`, an ISF schedule (none by default), the ISF and target in force
/// (none by default), and no basal schedule.
private final class FakeISFScreenReads: ISFTestProvider {
    var data: ISFTest.StateModel.ScreenData
    var isfSchedule: [SettingsTestScheduleEntry] = []
    var isfNow: Decimal?
    var targetNow: Decimal?

    init(_ data: ISFTest.StateModel.ScreenData) {
        self.data = data
    }

    func isfEntries() -> [SettingsTestScheduleEntry] { isfSchedule }
    func basalEntries() -> [SettingsTestScheduleEntry] { [] }
    func isf(at _: Date) -> Decimal? { isfNow }
    func target(at _: Date) -> Decimal? { targetNow }
    func fetchRecentGlucose(minutes _: Int) async throws -> [BasalTestReading] { data.readings }
    func currentIOB() -> Decimal? { data.iob }
    func currentCOB() async throws -> Decimal? { data.cob }
    func hasActiveAdjustment() async throws -> Bool { data.hasActiveAdjustment }
    func hasPumpSetTempBasal() -> Bool { data.hasPumpSetTempBasal }
    func pumpDelivery() -> ISFTestPumpDelivery? { data.pumpDelivery }
    func hasCgmAndPump() -> Bool { data.hasDevices }
    func fetchNewestDirection() async throws -> BloodGlucose.Direction? { data.trendDirection }
}

/// What the basal screen reads, as a test sets it, keeping when each week of SMBs was read from. No SMBs or carbs on
/// board samples unless a test sets them.
private final class FakeBasalScreenReads: BasalTestProvider {
    var data: BasalTest.StateModel.ScreenData
    var smbs: [BasalTestSMB] = []
    var cobSamples: [BasalTestCOBSample] = []
    private let lock = NSLock()
    private var _smbReadsSince: [Date] = []

    init(_ data: BasalTest.StateModel.ScreenData) {
        self.data = data
    }

    /// Where each read of SMBs started, in the order read.
    var smbReadsSince: [Date] { lock.withLock { _smbReadsSince } }

    func basalEntries() -> [SettingsTestScheduleEntry] { [] }
    func fetchRecentGlucose(minutes _: Int) async throws -> [BasalTestReading] { data.readings }
    func getCurrentIOB() -> Decimal { data.iob }
    func getCurrentCOB() async throws -> Decimal { data.cob }
    func lastCarbEntry(withinHours _: Int) async throws -> Date? { data.lastCarb }
    func hasActiveAdjustment() async throws -> Bool { data.hasActiveAdjustment }
    func hasPumpSetTempBasal() -> Bool { data.hasPumpSetTempBasal }
    func hasCgmAndPump() -> Bool { data.hasDevices }
    func fetchNewestDirection() async throws -> BloodGlucose.Direction? { data.trendDirection }

    func fetchSMBs(since start: Date, until _: Date) async throws -> [BasalTestSMB] {
        lock.withLock { _smbReadsSince.append(start) }
        return smbs
    }

    func fetchCOBSamples(since _: Date) async throws -> [BasalTestCOBSample] { cobSamples }
}

/// Holds the first call of a read until `release`, then gives `first` for it; every later call gives `later` at once.
/// So a refresh that began first can finish after one that began later.
private final class HeldRead<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var held: CheckedContinuation<Void, Never>?
    private var released = false
    private let first: Value
    private let later: Value

    init(first: Value, later: Value) {
        self.first = first
        self.later = later
    }

    /// Whether the first call is waiting.
    var isHolding: Bool { lock.withLock { held != nil } }

    func read() async -> Value {
        let call = lock.withLock { () -> Int in
            calls += 1
            return calls
        }
        guard call == 1 else { return later }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if released { return true }
                held = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return first
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { held = nil }
            return held
        }
        continuation?.resume()
    }
}

/// The ISF screen's reads, with its carbs-on-board read held the first time (`HeldRead`).
private final class HeldCOBISFScreenReads: ISFTestProvider {
    let data: ISFTest.StateModel.ScreenData
    let cob: HeldRead<Decimal?>

    init(_ data: ISFTest.StateModel.ScreenData, cob: HeldRead<Decimal?>) {
        self.data = data
        self.cob = cob
    }

    func isfEntries() -> [SettingsTestScheduleEntry] { [] }
    func basalEntries() -> [SettingsTestScheduleEntry] { [] }
    func isf(at _: Date) -> Decimal? { nil }
    func target(at _: Date) -> Decimal? { nil }
    func fetchRecentGlucose(minutes _: Int) async throws -> [BasalTestReading] { data.readings }
    func currentIOB() -> Decimal? { data.iob }
    func currentCOB() async throws -> Decimal? { await cob.read() }
    func hasActiveAdjustment() async throws -> Bool { data.hasActiveAdjustment }
    func hasPumpSetTempBasal() -> Bool { data.hasPumpSetTempBasal }
    func pumpDelivery() -> ISFTestPumpDelivery? { data.pumpDelivery }
    func hasCgmAndPump() -> Bool { data.hasDevices }
    func fetchNewestDirection() async throws -> BloodGlucose.Direction? { data.trendDirection }
}

/// The basal screen's reads, with its last-carbs read held the first time (`HeldRead`).
private final class HeldCarbsBasalScreenReads: BasalTestProvider {
    let data: BasalTest.StateModel.ScreenData
    let lastCarb: HeldRead<Date?>

    init(_ data: BasalTest.StateModel.ScreenData, lastCarb: HeldRead<Date?>) {
        self.data = data
        self.lastCarb = lastCarb
    }

    func basalEntries() -> [SettingsTestScheduleEntry] { [] }
    func fetchRecentGlucose(minutes _: Int) async throws -> [BasalTestReading] { data.readings }
    func getCurrentIOB() -> Decimal { data.iob }
    func getCurrentCOB() async throws -> Decimal { data.cob }
    func lastCarbEntry(withinHours _: Int) async throws -> Date? { await lastCarb.read() }
    func hasActiveAdjustment() async throws -> Bool { data.hasActiveAdjustment }
    func hasPumpSetTempBasal() -> Bool { data.hasPumpSetTempBasal }
    func hasCgmAndPump() -> Bool { data.hasDevices }
    func fetchNewestDirection() async throws -> BloodGlucose.Direction? { data.trendDirection }
    func fetchSMBs(since _: Date, until _: Date) async throws -> [BasalTestSMB] { [] }
    func fetchCOBSamples(since _: Date) async throws -> [BasalTestCOBSample] { [] }
}

/// The basal screen's reads, with the SMB read (what the Check screen's fasting source reads) failing.
private final class FailingSMBBasalScreenReads: BasalTestProvider {
    struct SMBReadFailed: Error {}
    let data: BasalTest.StateModel.ScreenData

    init(_ data: BasalTest.StateModel.ScreenData) { self.data = data }

    func basalEntries() -> [SettingsTestScheduleEntry] { [] }
    func fetchRecentGlucose(minutes _: Int) async throws -> [BasalTestReading] { data.readings }
    func getCurrentIOB() -> Decimal { data.iob }
    func getCurrentCOB() async throws -> Decimal { data.cob }
    func lastCarbEntry(withinHours _: Int) async throws -> Date? { data.lastCarb }
    func hasActiveAdjustment() async throws -> Bool { data.hasActiveAdjustment }
    func hasPumpSetTempBasal() -> Bool { data.hasPumpSetTempBasal }
    func hasCgmAndPump() -> Bool { data.hasDevices }
    func fetchNewestDirection() async throws -> BloodGlucose.Direction? { data.trendDirection }
    func fetchSMBs(since _: Date, until _: Date) async throws -> [BasalTestSMB] { throw SMBReadFailed() }
    func fetchCOBSamples(since _: Date) async throws -> [BasalTestCOBSample] { [] }
}

/// `.settingsTestFiles`: the tests that refresh a screen give it a settings test service (`makeTestService`), whose
/// history the ISF screen's basal row reads.
@Suite(
    "Settings test screens follow the runners",
    .serialized,
    .settingsTestFiles
) @MainActor struct SettingsTestScreenStateTests {
    private let minute: TimeInterval = 60

    /// Begun 30 minutes ago from Closed Loop on ISF 50, target 100 and CR 10, with its session, in `phase`.
    private func isfTest(_ phase: ISFTestPhase) -> ISFTestState {
        var test = ISFTestState(
            phase: phase,
            startedAt: Date().addingTimeInterval(-30 * minute),
            previousMode: .closed,
            isf: 50,
            target: 100,
            carbRatio: 10
        )
        test.sessionID = UUID()
        return test
    }

    /// Begun an hour ago from Closed Loop at 110 mg/dL, planned for 4 hours.
    private func runningFast() -> BasalTestState {
        var test = BasalTestState(
            startedAt: Date().addingTimeInterval(-60 * minute),
            plannedDuration: 4 * 3600,
            startGlucose: 110,
            startIOB: 0,
            previousMode: .closed,
            timeBlock: "Overnight"
        )
        test.sessionID = UUID()
        return test
    }

    /// Three readings at `glucose`, the newest a minute old, so a dose can be worked out from them.
    private func readings(_ glucose: Int) -> [BasalTestReading] {
        [1, 6, 11].map { BasalTestReading(date: Date().addingTimeInterval(-Double($0) * minute), glucose: glucose) }
    }

    /// What the ISF screen reads with nothing in the way of Begin: CGM and pump connected, the pump delivering, `iob` on
    /// board (none by default).
    private func isfData(_ readings: [BasalTestReading], iob: Decimal? = 0) -> ISFTest.StateModel.ScreenData {
        ISFTest.StateModel.ScreenData(
            readings: readings,
            iob: iob,
            cob: 0,
            hasActiveAdjustment: false,
            hasPumpSetTempBasal: false,
            pumpDelivery: .delivering,
            hasDevices: true,
            trendDirection: .flat
        )
    }

    private func basalData(_ readings: [BasalTestReading]) -> BasalTest.StateModel.ScreenData {
        BasalTest.StateModel.ScreenData(
            readings: readings,
            iob: Decimal(string: "0.5")!,
            cob: 0,
            lastCarb: nil,
            hasActiveAdjustment: false,
            hasPumpSetTempBasal: false,
            hasDevices: true,
            trendDirection: .flat
        )
    }

    // MARK: Following

    @Test("The ISF screen shows the runner's step, settling and insulin on board for the dose") func isfFollowsRunner() {
        let state = ISFTest.StateModel()
        let settling = isfTest(.settling)
        let bolus = ISFTestSettlingBolus(date: Date().addingTimeInterval(-10 * minute), units: 1, isSMB: true)
        state.apply(ISFTestRunnerState(test: settling, settling: ISFTestSettlingProgress(
            decision: .waiting(loopedAt: nil, waitsForIOB: false),
            boluses: [bolus],
            readingsAfterLoop: 2,
            tempBasalRunning: true
        )))
        #expect(state.step == .settle)
        #expect(state.test == settling)
        #expect(state.settling == .waiting(loopedAt: nil, waitsForIOB: false))
        #expect(state.settlingBoluses == [bolus])
        #expect(state.settleReadings == 2)
        #expect(state.settleTempBasalRunning)

        // Settled: nothing of settling is left, and the dose's insulin on board is the runner's.
        state.apply(ISFTestRunnerState(test: isfTest(.dosing), settling: nil, doseIOB: Decimal(string: "0.4")))
        #expect(state.step == .dose)
        #expect(state.settling == nil)
        #expect(state.settlingBoluses.isEmpty)
        #expect(state.settleReadings == nil)
        #expect(!state.settleTempBasalRunning)
        #expect(state.doseIOB == Decimal(string: "0.4"))

        state.apply(ISFTestRunnerState(test: isfTest(.finished), settling: nil))
        #expect(state.step == .result)
        #expect(state.doseIOB == nil)
        state.apply(ISFTestRunnerState())
        #expect(state.step == .check)
        #expect(state.test == nil)
    }

    @Test("The ISF screen follows what its runner publishes") func isfFollowsPublisher() async {
        let runner = RecordingISFTestRunner()
        runner.subject.send(ISFTestRunnerState(test: isfTest(.raising)))
        let state = ISFTest.StateModel()
        state.follow(runner)
        // What the runner holds now, at once.
        #expect(state.step == .raise)
        runner.subject.send(ISFTestRunnerState(test: isfTest(.waiting)))
        #expect(await eventuallyOnMain { state.step == .wait })
    }

    @Test("The basal screen shows the runner's fast, and follows what it publishes") func basalFollowsRunner() async {
        let state = BasalTest.StateModel()
        let running = runningFast()
        state.apply(running)
        #expect(state.step == .fast)
        #expect(state.test == running)
        state.apply(nil)
        #expect(state.step == .check)

        let runner = RecordingBasalTestRunner()
        runner.subject.send(running)
        state.follow(runner)
        #expect(state.step == .fast)
        runner.subject.send(nil)
        #expect(await eventuallyOnMain { state.step == .check })
    }

    // MARK: Open Treatments

    /// The opener a test drives, with no sheet of its own and its 1 s re-check on `ticks`.
    private func makeOpener(
        router: SettingsTestFakeRouter,
        ticks: PassthroughSubject<Void, Never>
    ) -> SettingsTestScreenOpener {
        SettingsTestScreenOpener(
            router: { router },
            keyWindowPresents: { false },
            recheckTicks: { ticks.eraseToAnyPublisher() }
        )
    }

    @Test(
        "Open Treatments from a notice-opened ISF screen brings it back after Treatments; from Settings it doesn't"
    ) func openTreatmentsBringsTestBack() async throws {
        let router = SettingsTestFakeRouter()
        let ticks = PassthroughSubject<Void, Never>()
        let opener = makeOpener(router: router, ticks: ticks)
        let state = ISFTest.StateModel()
        state.router = router
        state.opener = opener

        #expect(opener.open(.isf))
        opener.screenAppeared(.isf)
        state.sendToTreatments()
        #expect(router.mainModalScreen.value == .treatmentView)
        #expect(opener.pending == .isf)
        // Treatments takes the test screen's place, then closes.
        opener.screenDisappeared(.isf)
        router.mainModalScreen.send(nil)
        #expect(await eventuallyOnMain { router.mainModalScreen.value == .isfTest })
        opener.screenAppeared(.isf)
        #expect(opener.pending == nil)
        opener.screenDisappeared(.isf)
        router.mainModalScreen.send(nil)

        // Opened from Settings: Treatments opens, and nothing waits for it to close.
        let settingsRouter = SettingsTestFakeRouter()
        let settingsOpener = makeOpener(router: settingsRouter, ticks: ticks)
        state.router = settingsRouter
        state.opener = settingsOpener
        settingsOpener.screenAppeared(.isf)
        state.sendToTreatments()
        #expect(settingsRouter.mainModalScreen.value == .treatmentView)
        #expect(settingsOpener.pending == nil)
        settingsRouter.mainModalScreen.send(nil)
        try await Task.sleep(for: .milliseconds(100))
        ticks.send(())
        #expect(settingsRouter.mainModalScreen.value == nil)
    }

    @Test("A notice-opened ISF screen closed without Treatments opening isn't brought back") func closedWithoutTreatments(
    ) async throws {
        let router = SettingsTestFakeRouter()
        let ticks = PassthroughSubject<Void, Never>()
        let opener = makeOpener(router: router, ticks: ticks)
        let state = ISFTest.StateModel()
        state.router = router
        state.opener = opener

        #expect(opener.open(.isf))
        opener.screenAppeared(.isf)
        state.sendToTreatments()
        #expect(opener.pending == .isf)
        // Treatments didn't open: the sheet was closed, by the user or by Main, with the test screen in it.
        router.mainModalScreen.send(nil)
        opener.screenDisappeared(.isf)
        #expect(opener.pending == nil)
        #expect(!opener.isRechecking)
        try await Task.sleep(for: .milliseconds(100))
        ticks.send(())
        #expect(router.mainModalScreen.value == nil)
    }

    // MARK: Begin

    @Test("The ISF screen begins only when its checks pass and it has a recent glucose") func isfBeginGuards() async throws {
        let runner = RecordingISFTestRunner()
        let settings = FakeSettingsManager()
        settings.settings.dosingMode = .basalTesting
        let state = ISFTest.StateModel()
        state.settingsManager = settings
        state.runner = runner
        state.show(isfData(readings(180)))

        // Already on Basal Testing, which Begin would record as the usual mode: the runner isn't asked.
        #expect(!state.readyToStart)
        state.confirmStart()
        try await Task.sleep(for: .milliseconds(100))
        #expect(runner.begins.isEmpty)
        #expect(state.errorMessage == nil)

        // From the usual mode it is, from Ready, with the glucose the dose is worked out from. No insulin on board page
        // applies (no dose is worked out without the settings), so a pick kept from before isn't sent. Begin reads, so
        // the screen waits for it.
        settings.settings.dosingMode = .closed
        state.iobChoice = .count
        #expect(state.readyToStart)
        state.goNext()
        #expect(state.shownCheckPage == .ready)
        state.confirmStart()
        #expect(await eventuallyOnMain { runner.begins.count == 1 })
        #expect(runner.begins == [ISFTestBegin(glucose: 180, iob: 0, iobChoice: nil)])
        #expect(state.errorMessage == nil)

        // The runner's refusal is said.
        runner.beginError = .otherTestRunning
        state.confirmStart()
        #expect(await eventuallyOnMain { state.errorMessage == SettingsTestBeginError.otherTestRunning.message })

        // With no recent reading, no glucose is made up: today's message, and the runner isn't asked.
        state.errorMessage = nil
        state.show(isfData([BasalTestReading(date: Date().addingTimeInterval(-30 * minute), glucose: 180)]))
        #expect(state.readyToStart)
        state.confirmStart()
        try await Task.sleep(for: .milliseconds(100))
        #expect(runner.begins.count == 2)
        #expect(state.errorMessage == String(
            localized: "Trio has no recent glucose reading. Wait for your CGM's next reading, then try again."
        ))
    }

    @Test("The basal screen begins only when its checks pass and it has a glucose") func basalBeginGuards() async throws {
        let runner = RecordingBasalTestRunner()
        let settings = FakeSettingsManager()
        settings.settings.dosingMode = .basalTesting
        let state = BasalTest.StateModel()
        state.settingsManager = settings
        state.runner = runner
        state.show(basalData(readings(110)))

        #expect(!state.readyToStart)
        state.confirmStart()
        try await Task.sleep(for: .milliseconds(100))
        #expect(runner.begins.isEmpty)

        // Start reads, so the screen waits for it.
        settings.settings.dosingMode = .closed
        state.selectedHours = 6
        #expect(state.readyToStart)
        state.confirmStart()
        #expect(await eventuallyOnMain { runner.begins.count == 1 })
        #expect(runner.begins == [BasalTestBegin(glucose: 110, iob: Decimal(string: "0.5")!, hours: 6)])

        state.show(basalData([]))
        state.confirmStart()
        try await Task.sleep(for: .milliseconds(100))
        #expect(runner.begins.count == 1)
    }

    /// The hub opens a test while another runs, so its steps can be read; its own Check is what keeps it from starting.
    /// The running test has Basal Testing on, so the mode check fails too, but it must not say to switch modes: that
    /// would end the running test. The footer names the running test instead.
    @Test("While another test runs, each Check screen says so and doesn't begin") func checkBlocksWhileAnotherRuns() async throws {
        let isfSettings = FakeSettingsManager()
        isfSettings.settings.dosingMode = .closed
        let isfRunner = RecordingISFTestRunner()
        let isf = ISFTest.StateModel()
        isf.settingsManager = isfSettings
        isf.runner = isfRunner
        isf.show(isfData(readings(180)))
        isf.iobChoice = .count
        #expect(isf.readyToStart)

        // The basal test switched Trio to Basal Testing as it began.
        isfSettings.settings.dosingMode = .basalTesting
        isf.showSession(
            SettingsTestSession(kind: .basal, expiresAt: Date().addingTimeInterval(3600), restore: []),
            lastEnd: nil
        )
        #expect(!isf.readyToStart)
        #expect(isf.startBlocker == "The Basal Rates test is still running. Finish it first.")
        #expect(isf.failingChecks.map(\.id) == ["otherTest", "mode"])
        #expect(isf.failingChecks.last?.detail == "The Basal Rates test has Basal Testing on. It goes off when that test ends.")
        #expect(isf.otherRunningTest == .basal)
        #expect(!isf.usualModeIsOn)
        isf.confirmStart()

        // The other test's check blocks on its own too, e.g. once the mode was changed and its session hasn't ended yet.
        isfSettings.settings.dosingMode = .closed
        #expect(!isf.readyToStart)
        #expect(isf.failingChecks.map(\.id) == ["otherTest"])
        #expect(isf.usualModeIsOn)
        isf.confirmStart()

        // With no test running, Basal Testing left on still asks for the usual mode, as before.
        isfSettings.settings.dosingMode = .basalTesting
        isf.showSession(nil, lastEnd: nil)
        #expect(isf.otherRunningTest == nil)
        #expect(isf.startBlocker == "Switch to your usual dosing mode first, so Trio can return you to it")

        // A session of its own kind isn't another test: the mode line keeps its way back.
        isf.showSession(
            SettingsTestSession(kind: .isf, expiresAt: Date().addingTimeInterval(3600), restore: []),
            lastEnd: nil
        )
        #expect(isf.otherRunningTest == nil)
        #expect(isf.failingChecks.map(\.id) == ["mode"])
        #expect(isf.startBlocker == "Switch to your usual dosing mode first, so Trio can return you to it")

        let basalSettings = FakeSettingsManager()
        basalSettings.settings.dosingMode = .closed
        let basalRunner = RecordingBasalTestRunner()
        let basal = BasalTest.StateModel()
        basal.settingsManager = basalSettings
        basal.runner = basalRunner
        basal.show(basalData(readings(110)))
        #expect(basal.readyToStart)

        basalSettings.settings.dosingMode = .basalTesting
        basal.showSession(
            SettingsTestSession(kind: .isf, expiresAt: Date().addingTimeInterval(3600), restore: []),
            lastEnd: nil
        )
        #expect(!basal.readyToStart)
        #expect(basal.startBlocker == "The Insulin Sensitivity test is still running. Finish it first.")
        #expect(basal.failingChecks.map(\.id) == ["otherTest", "mode"])
        #expect(
            basal.failingChecks.last?.detail
                == "The Insulin Sensitivity test has Basal Testing on. It goes off when that test ends."
        )
        #expect(basal.otherRunningTest == .isf)
        #expect(!basal.usualModeIsOn)
        basal.confirmStart()

        basalSettings.settings.dosingMode = .closed
        #expect(basal.failingChecks.map(\.id) == ["otherTest"])
        basal.confirmStart()

        basalSettings.settings.dosingMode = .basalTesting
        basal.showSession(nil, lastEnd: nil)
        #expect(basal.otherRunningTest == nil)
        #expect(basal.startBlocker == "Switch to your usual dosing mode first, so Trio can return you to it")

        basal.showSession(
            SettingsTestSession(kind: .basal, expiresAt: Date().addingTimeInterval(3600), restore: []),
            lastEnd: nil
        )
        #expect(basal.otherRunningTest == nil)
        #expect(basal.failingChecks.map(\.id) == ["mode"])
        #expect(basal.startBlocker == "Switch to your usual dosing mode first, so Trio can return you to it")

        // Begin and Start send to the runner from a task, so give any that slipped past the guard time to arrive.
        try await Task.sleep(for: .milliseconds(100))
        #expect(isfRunner.begins.isEmpty)
        #expect(basalRunner.begins.isEmpty)
    }

    @Test("Each steps sheet lists every step of its test, in order") func stepsSheets() {
        #expect(ISFTest.CheckView.steps(aim: "150 mg/dL").map(\.step) == ISFTest.Step.allCases)
        #expect(BasalTest.CheckView.steps().map(\.step) == BasalTest.Step.allCases)
    }

    // MARK: The pages

    /// A basal screen on `runner` in Closed Loop, showing `basalData(readings(110))`: nothing in the way of Start.
    private func basalPagesScreen(_ runner: RecordingBasalTestRunner = RecordingBasalTestRunner()) -> BasalTest.StateModel {
        let settings = FakeSettingsManager()
        settings.settings.dosingMode = .closed
        let state = BasalTest.StateModel()
        state.settingsManager = settings
        state.screenReads = FakeBasalScreenReads(basalData(readings(110)))
        state.runner = runner
        state.show(basalData(readings(110)))
        return state
    }

    /// An ISF screen on `runner` in Closed Loop, refreshed from `glucose` and `iob` with ISF 50 and target 100: nothing
    /// else in the way of Begin.
    private func isfPagesScreen(
        _ runner: RecordingISFTestRunner = RecordingISFTestRunner(),
        glucose: Int = 180,
        iob: Decimal? = 0
    ) async -> ISFTest.StateModel {
        let settings = FakeSettingsManager()
        settings.settings.dosingMode = .closed
        let reads = FakeISFScreenReads(isfData(readings(glucose), iob: iob))
        reads.isfNow = 50
        reads.targetNow = 100
        let state = ISFTest.StateModel()
        state.settingsManager = settings
        state.testService = makeTestService().service
        state.screenReads = reads
        state.runner = runner
        await state.refresh()
        return state
    }

    @Test("The basal start goes Check, How long, Ready") func basalPageOrder() {
        let state = basalPagesScreen()
        #expect(state.shownCheckPage == .checks)
        #expect(state.checkPages == [.checks, .length, .ready])
        #expect(state.checkPagePosition(.length) == "2 of 3")
        // Back on the first page stays there.
        state.previousCheckPage()
        #expect(state.shownCheckPage == .checks)
        state.nextCheckPage()
        #expect(state.shownCheckPage == .length)
        state.nextCheckPage()
        #expect(state.shownCheckPage == .ready)
        // Next on the last page stays there; Start is its button.
        state.nextCheckPage()
        #expect(state.shownCheckPage == .ready)
        state.previousCheckPage()
        #expect(state.shownCheckPage == .length)
        state.previousCheckPage()
        #expect(state.shownCheckPage == .checks)
    }

    @Test(
        "Basal Next is off while a check blocks, on every page, and Cancel or Done starts the pages again"
    ) func basalNextBlocked() {
        let state = basalPagesScreen()
        state.settingsManager.settings.dosingMode = .basalTesting
        #expect(!state.canGoOn)
        #expect(state.startBlocker == "Switch to your usual dosing mode first, so Trio can return you to it")
        state.nextCheckPage()
        #expect(state.shownCheckPage == .checks)
        state.settingsManager.settings.dosingMode = .closed
        state.nextCheckPage()
        #expect(state.shownCheckPage == .length)
        // Another test begins meanwhile: Next goes off there, with the check's sentence.
        state.showSession(SettingsTestSession(kind: .isf, expiresAt: Date().addingTimeInterval(3600), restore: []), lastEnd: nil)
        #expect(!state.canGoOn)
        #expect(state.startBlocker == "The Insulin Sensitivity test is still running. Finish it first.")
        state.nextCheckPage()
        #expect(state.shownCheckPage == .length)
        state.showSession(nil, lastEnd: nil)
        state.nextCheckPage()
        #expect(state.shownCheckPage == .ready)

        state.discard()
        #expect(state.shownCheckPage == .checks)
        state.nextCheckPage()
        #expect(state.shownCheckPage == .length)
        state.acknowledgeResult()
        #expect(state.shownCheckPage == .checks)
    }

    @Test("The basal Ready page sums up the fast, and Start passes the hours picked") func basalReadyPassesHours() async {
        let runner = RecordingBasalTestRunner()
        let state = basalPagesScreen(runner)
        state.nextCheckPage()
        state.selectedHours = 6
        state.nextCheckPage()
        #expect(state.shownCheckPage == .ready)
        // The end is a clock time from the minute the page shows, which its timeline passes on as the clock moves, so it
        // keeps up while the page is open; How long's "This fast" reads the same window.
        let shown = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func end(_ start: Date) -> String {
            start.addingTimeInterval(6 * 3600).formatted(date: .omitted, time: .shortened)
        }
        #expect(state.readySummary(now: shown) == [
            .init(title: "Fast for", value: "6 hours"),
            .init(title: "Ends about", value: end(shown))
        ])
        let later = shown.addingTimeInterval(60)
        #expect(state.readySummary(now: later).last?.value == end(later))
        #expect(end(later) != end(shown))
        #expect(state.plannedWindow(startingAt: later).start == later)
        #expect(state.plannedWindow(startingAt: later).end == later.addingTimeInterval(6 * 3600))
        state.requestStart()
        #expect(state.showStartConfirmation)
        state.confirmStart()
        #expect(await eventuallyOnMain { runner.begins.count == 1 })
        #expect(runner.begins == [BasalTestBegin(glucose: 110, iob: Decimal(string: "0.5")!, hours: 6)])
    }

    @Test("The ISF start goes Check, Ready, with Insulin on board only when there is a choice") func isfPageOrder() async {
        // 180 mg/dL on target 100 and ISF 50: a 1.60 U dose, whose line is 0.08 U. Nothing on board, nothing to choose.
        let state = await isfPagesScreen()
        #expect(state.expectedDose == Decimal(string: "1.6")!)
        #expect(state.shownCheckPage == .checks)
        #expect(state.checkPages == [.checks, .ready])
        #expect(state.checkPagePosition(.ready) == "2 of 2")
        // Back on the first page stays there.
        state.goBack()
        #expect(state.shownCheckPage == .checks)
        state.goNext()
        #expect(state.shownCheckPage == .ready)
        // Next on the last page stays there; Begin is its button.
        state.goNext()
        #expect(state.shownCheckPage == .ready)
        state.goBack()
        #expect(state.shownCheckPage == .checks)

        // 0.5 U on board, over the line and no more than the dose: the Insulin on board page comes after the checks.
        state.show(isfData(readings(180), iob: Decimal(string: "0.5")!))
        #expect(state.iobDecision == .choice(line: Decimal(string: "0.08")!))
        #expect(state.checkPages == [.checks, .iob, .ready])
        #expect(state.checkPagePosition(.iob) == "2 of 3")
        state.goNext()
        #expect(state.shownCheckPage == .iob)
        state.goNext()
        #expect(state.shownCheckPage == .ready)
        state.goBack()
        #expect(state.shownCheckPage == .iob)

        // Back under the line while that page shows: it hands over to the checks.
        state.show(isfData(readings(180)))
        #expect(state.shownCheckPage == .checks)
        state.goNext()
        #expect(state.shownCheckPage == .ready)

        // More than the whole dose holds Begin up instead: no Insulin on board page, and Next is off with the sentence.
        state.show(isfData(readings(180), iob: 2))
        #expect(state.iobDecision == .blocked)
        #expect(state.checkPages == [.checks, .ready])
        state.goBack()
        #expect(!state.canGoOn)
        let dose = SettingsTestFormat.keepTogether("1.60", unit: "U")
        #expect(state.startBlocker == "2.00 U is more than the test's whole dose (\(dose)). Begin once it has come down.")
        state.goNext()
        #expect(state.shownCheckPage == .checks)
    }

    @Test(
        "ISF Next is off while a check blocks, on every page, and Cancel or Done starts the pages again"
    ) func isfNextBlocked() async {
        let state = await isfPagesScreen(iob: Decimal(string: "0.5")!)
        state.settingsManager.settings.dosingMode = .basalTesting
        #expect(!state.canGoOn)
        #expect(state.startBlocker == "Switch to your usual dosing mode first, so Trio can return you to it")
        state.goNext()
        #expect(state.shownCheckPage == .checks)
        state.settingsManager.settings.dosingMode = .closed
        state.goNext()
        #expect(state.shownCheckPage == .iob)
        // Another test begins meanwhile: Next goes off there, with the check's sentence.
        state.showSession(
            SettingsTestSession(kind: .basal, expiresAt: Date().addingTimeInterval(3600), restore: []),
            lastEnd: nil
        )
        #expect(!state.canGoOn)
        #expect(state.startBlocker == "The Basal Rates test is still running. Finish it first.")
        state.goNext()
        #expect(state.shownCheckPage == .iob)
        state.showSession(nil, lastEnd: nil)
        state.goNext()
        #expect(state.shownCheckPage == .ready)

        state.discard()
        #expect(state.shownCheckPage == .checks)
        state.goNext()
        #expect(state.shownCheckPage == .iob)
        state.acknowledgeResult()
        #expect(state.shownCheckPage == .checks)
    }

    @Test("The ISF Ready page sums up the start, and Begin passes the choice made on its page") func isfReadyPassesChoice(
    ) async {
        let runner = RecordingISFTestRunner()
        let state = await isfPagesScreen(runner, iob: Decimal(string: "0.5")!)
        state.goNext()
        #expect(state.shownCheckPage == .iob)
        state.iobChoice = .count
        state.goNext()
        #expect(state.shownCheckPage == .ready)
        #expect(state.readySummary == [
            .init(title: "After settling", value: "The dose"),
            .init(title: "Dose", value: "About \(SettingsTestFormat.keepTogether("1.60", unit: "U"))"),
            .init(title: "Insulin on board", value: "Count It")
        ])
        state.requestStart()
        #expect(state.showStartConfirmation)
        state.confirmStart()
        #expect(await eventuallyOnMain { runner.begins.count == 1 })
        #expect(runner.begins == [ISFTestBegin(glucose: 180, iob: Decimal(string: "0.5")!, iobChoice: .count)])
    }

    @Test("Below 150 the ISF Ready page says tablets come first, with the dose they aim for") func isfReadyRaise() async {
        // 120 mg/dL, under the docs' 150, on target 100: tablets first, then a 1.00 U dose from 150. Nothing on board.
        let state = await isfPagesScreen(glucose: 120)
        #expect(state.checkPages == [.checks, .ready])
        state.goNext()
        #expect(state.shownCheckPage == .ready)
        #expect(state.readySummary == [
            .init(title: "After settling", value: "Glucose tablets, then the dose"),
            .init(title: "Dose", value: "About \(SettingsTestFormat.keepTogether("1.00", unit: "U"))")
        ])
    }

    @Test(
        "The basal SMB row sits with the hours on How long to fast, not on the checks, and counts the hours picked"
    ) func basalSMBRowWithTheHours() async {
        let reads = FakeBasalScreenReads(basalData(readings(110)))
        // An SMB half an hour past the minute a 4 h fast started now ends, so outside its hours and inside a 6 h one's
        // whatever the clocks do in between, with no carbs on board. It goes by its time of day, so it sits on a fixed
        // mid-January day, when no clock changes.
        let now = Date()
        let fourHours = SettingsTestTimeWindow(from: now, to: now.addingTimeInterval(4 * 3600), calendar: .current)
        let smbMinute = (fourHours.endMinutes + 30) % 1440
        let smbAt = Calendar.current.date(from: DateComponents(
            year: 2026,
            month: 1,
            day: 15,
            hour: smbMinute / 60,
            minute: smbMinute % 60
        ))!
        reads.smbs = [BasalTestSMB(date: smbAt, units: Decimal(string: "0.3")!)]
        let daysBefore = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 10))!
        reads.cobSamples = [BasalTestCOBSample(date: daysBefore, cob: 0)]
        let state = BasalTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        state.screenReads = reads
        await state.refresh()
        #expect(!state.informingChecks.map(\.id).contains("smbs"))
        #expect(state.informingChecks.count == 4)
        #expect(state.selectedHours == 4)
        #expect(state.smbCheck?.value == "None")
        state.selectedHours = 6
        #expect(state.smbCheck?.value == "1 SMB, 0.30 U")
    }

    @Test("Start is off on the basal Ready page while a check fails, with its sentence") func basalReadyBlocked() async throws {
        let runner = RecordingBasalTestRunner()
        let state = basalPagesScreen(runner)
        state.nextCheckPage()
        state.nextCheckPage()
        #expect(state.shownCheckPage == .ready)
        state.settingsManager.settings.dosingMode = .basalTesting
        #expect(state.shownCheckPage == .ready)
        #expect(!state.readyToStart)
        #expect(state.startBlocker == "Switch to your usual dosing mode first, so Trio can return you to it")
        state.requestStart()
        #expect(!state.showStartConfirmation)
        state.confirmStart()
        try await Task.sleep(for: .milliseconds(100))
        #expect(runner.begins.isEmpty)
    }

    @Test(
        "Insulin on board going over the line while the ISF Ready page shows brings its page up before Begin"
    ) func isfIOBPageComesUpBehind() async {
        let runner = RecordingISFTestRunner()
        let state = await isfPagesScreen(runner)
        state.goNext()
        #expect(state.shownCheckPage == .ready)
        // 0.5 U comes up, over the 0.08 U line: its page shows, with Next, so Begin can't go without the choice.
        state.show(isfData(readings(180), iob: Decimal(string: "0.5")!))
        #expect(state.checkPages == [.checks, .iob, .ready])
        #expect(state.shownCheckPage == .iob)
        #expect(!state.pagesAllowBegin)
        // The page comes up on screen, and stays until Next.
        state.checkPageAppeared(state.shownCheckPage)
        #expect(state.shownCheckPage == .iob)
        state.iobChoice = .count
        state.goNext()
        #expect(state.shownCheckPage == .ready)
        #expect(state.pagesAllowBegin)
        #expect(state.readySummary.last == .init(title: "Insulin on board", value: "Count It"))
        // Shown once, it doesn't come up again when it stops applying and applies again.
        state.show(isfData(readings(180)))
        state.show(isfData(readings(180), iob: Decimal(string: "0.5")!))
        #expect(state.shownCheckPage == .ready)
        state.requestStart()
        state.confirmStart()
        #expect(await eventuallyOnMain { runner.begins.count == 1 })
        #expect(runner.begins == [ISFTestBegin(glucose: 180, iob: Decimal(string: "0.5")!, iobChoice: .count)])
    }

    @Test("An ISF page counts as shown once it comes up on screen, not when Next is tapped") func isfPageSeenOnAppear() async {
        let state = await isfPagesScreen(iob: Decimal(string: "0.5")!)
        state.nextCheckPage()
        #expect(state.checkPage == .iob)
        #expect(!state.seenCheckPages.contains(.iob))
        // Next again before it came up goes nowhere past it.
        state.nextCheckPage()
        #expect(state.shownCheckPage == .iob)
        #expect(!state.pagesAllowBegin)
        state.checkPageAppeared(.iob)
        #expect(state.seenCheckPages == [.checks, .iob])
        state.goNext()
        #expect(state.pagesAllowBegin)
    }

    @Test(
        "An ISF Begin confirmation left open while insulin on board's page comes up doesn't begin, or come back by itself"
    ) func isfConfirmationAcrossHandOver() async throws {
        let runner = RecordingISFTestRunner()
        let state = await isfPagesScreen(runner)
        state.goNext()
        #expect(state.shownCheckPage == .ready)

        // Begin asks to confirm; 0.5 U on board comes up before the answer. Confirming does nothing: its question
        // hasn't been asked, and Ready isn't what shows.
        state.requestStart()
        #expect(state.showStartConfirmation)
        state.show(isfData(readings(180), iob: Decimal(string: "0.5")!))
        #expect(state.shownCheckPage == .iob)
        state.confirmStart()
        #expect(!state.showStartConfirmation)
        // Nor can it be asked for again until Ready shows.
        state.requestStart()
        #expect(!state.showStartConfirmation)
        try await Task.sleep(for: .milliseconds(100))
        #expect(runner.begins.isEmpty)

        // Back under the line, Begin asks again; over it once more, the page comes up on screen, which closes the
        // confirmation, so it doesn't open again by itself when Ready comes back.
        state.show(isfData(readings(180)))
        #expect(state.shownCheckPage == .ready)
        state.requestStart()
        #expect(state.showStartConfirmation)
        state.show(isfData(readings(180), iob: Decimal(string: "0.5")!))
        state.checkPageAppeared(state.shownCheckPage)
        #expect(state.checkPage == .iob)
        #expect(!state.showStartConfirmation)
        state.goNext()
        #expect(state.shownCheckPage == .ready)
        #expect(!state.showStartConfirmation)

        // From Ready, with the question asked: Begin goes, with the docs' way picked.
        state.requestStart()
        state.confirmStart()
        #expect(await eventuallyOnMain { runner.begins.count == 1 })
        #expect(runner.begins == [ISFTestBegin(glucose: 180, iob: Decimal(string: "0.5")!, iobChoice: .wait)])
    }

    @Test(
        "A Start or Begin that fails, its test published and taken back, leaves the pages as they were"
    ) func failedBeginKeepsPages(
    ) async {
        let basalRunner = RecordingBasalTestRunner()
        basalRunner.publishesOnBegin = runningFast()
        basalRunner.beginError = .notSaved
        let basal = basalPagesScreen(basalRunner)
        basal.follow(basalRunner)
        basal.nextCheckPage()
        basal.selectedHours = 6
        basal.nextCheckPage()
        #expect(basal.shownCheckPage == .ready)
        basal.requestStart()
        basal.confirmStart()
        #expect(await eventuallyOnMain { basal.errorMessage == SettingsTestBeginError.notSaved.message })
        // What the runner published reaches the screen through the main queue: let it.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(basal.step == .check)
        #expect(basal.shownCheckPage == .ready)
        #expect(basal.selectedHours == 6)

        let isfRunner = RecordingISFTestRunner()
        isfRunner.publishesOnBegin = ISFTestRunnerState(test: isfTest(.settling))
        isfRunner.beginError = .notSaved
        let isf = await isfPagesScreen(isfRunner, iob: Decimal(string: "0.5")!)
        isf.follow(isfRunner)
        isf.goNext()
        isf.iobChoice = .count
        isf.goNext()
        #expect(isf.shownCheckPage == .ready)
        isf.requestStart()
        isf.confirmStart()
        #expect(await eventuallyOnMain { isf.errorMessage == SettingsTestBeginError.notSaved.message })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(isf.step == .check)
        #expect(isf.shownCheckPage == .ready)
        #expect(isf.iobChoice == .count)
        #expect(isf.seenCheckPages == [.checks, .iob, .ready])
    }

    @Test(
        "Insulin on board going past the whole dose while the ISF Ready page shows turns Begin off, with its sentence"
    ) func isfReadyBlocked() async throws {
        let runner = RecordingISFTestRunner()
        let state = await isfPagesScreen(runner, iob: Decimal(string: "0.5")!)
        state.goNext()
        state.goNext()
        #expect(state.shownCheckPage == .ready)
        state.show(isfData(readings(180), iob: 2))
        #expect(state.checkPages == [.checks, .ready])
        #expect(state.shownCheckPage == .ready)
        #expect(!state.readyToStart)
        let dose = SettingsTestFormat.keepTogether("1.60", unit: "U")
        #expect(state.startBlocker == "2.00 U is more than the test's whole dose (\(dose)). Begin once it has come down.")
        state.requestStart()
        #expect(!state.showStartConfirmation)
        state.confirmStart()
        try await Task.sleep(for: .milliseconds(100))
        #expect(runner.begins.isEmpty)
    }

    @Test(
        "A test that goes away while the screen is open starts the next one on the checks, basal and ISF"
    ) func goneTestResetsPages(
    ) async {
        let basal = basalPagesScreen()
        basal.nextCheckPage()
        basal.nextCheckPage()
        #expect(basal.shownCheckPage == .ready)
        basal.apply(runningFast())
        #expect(basal.step == .fast)
        // Cancelled or cleared elsewhere: the runner publishes no test.
        basal.apply(nil)
        #expect(basal.step == .check)
        #expect(basal.shownCheckPage == .checks)

        let isf = await isfPagesScreen(iob: Decimal(string: "0.5")!)
        isf.goNext()
        isf.iobChoice = .count
        isf.goNext()
        #expect(isf.shownCheckPage == .ready)
        isf.apply(ISFTestRunnerState(test: isfTest(.settling)))
        #expect(isf.step == .settle)
        isf.apply(ISFTestRunnerState())
        #expect(isf.step == .check)
        #expect(isf.shownCheckPage == .checks)
        #expect(isf.seenCheckPages == [.checks])
        // On the docs' way again, as Cancel and Done start it.
        #expect(isf.iobChoice == .wait)
    }

    // MARK: The other actions

    @Test("The ISF screen's own guards hold an action back, and the runner gets the rest") func isfActionGuards() {
        let runner = RecordingISFTestRunner()
        let state = ISFTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        state.runner = runner

        // Count It and Go On only once settling's time is up.
        state.apply(ISFTestRunnerState(test: isfTest(.settling), settling: ISFTestSettlingProgress(
            decision: .waiting(loopedAt: nil, waitsForIOB: true),
            boluses: [],
            readingsAfterLoop: nil,
            tempBasalRunning: false
        )))
        state.countAndGoOn()
        #expect(runner.actions.isEmpty)
        state.apply(ISFTestRunnerState(test: isfTest(.settling), settling: ISFTestSettlingProgress(
            decision: .timeUp(loopedAt: Date().addingTimeInterval(-50 * minute)),
            boluses: [],
            readingsAfterLoop: nil,
            tempBasalRunning: false
        )))
        state.countAndGoOn()
        #expect(runner.actions == ["countAndGoOn"])

        // Tablets: none to count says why; the count goes to the runner with the glucose it was counted from.
        state.apply(ISFTestRunnerState(test: isfTest(.raising)))
        state.show(isfData([]))
        state.tabletsTaken()
        #expect(runner.tablets.isEmpty)
        #expect(state.errorMessage != nil)
        state.errorMessage = nil
        state.show(isfData(readings(110)))
        state.selectedBrand = .dex4
        state.tabletsTaken()
        // (150 − 110) × 10 ÷ 50 = 8 g, two 4 g tablets.
        #expect(runner.tablets == [ISFTestTabletsTaken(brand: .dex4, count: 2, glucose: 110)])

        // Work Out My Dose only once the dose can be worked out; Skip, Dose Now at any time.
        #expect(!state.canDose)
        state.workOutDose()
        #expect(runner.actions == ["countAndGoOn"])
        state.skipTablets()
        #expect(runner.actions == ["countAndGoOn", "moveToDose"])

        // Back to the tablets only at or below the target.
        state.apply(ISFTestRunnerState(test: isfTest(.dosing)))
        state.show(isfData(readings(180)))
        state.raiseFirst()
        #expect(runner.actions == ["countAndGoOn", "moveToDose"])
        state.show(isfData(readings(90)))
        state.raiseFirst()
        #expect(runner.actions == ["countAndGoOn", "moveToDose", "raiseFirst"])

        // Work Out My Dose once glucose rose from the tablets and leveled off, with what the step read (fix round 5, L2).
        var risen = isfTest(.raising)
        risen.tabletsTakenAt = Date().addingTimeInterval(-40 * minute)
        risen.tabletsGlucose = 110
        state.apply(ISFTestRunnerState(test: risen))
        state.show(isfData(readings([(3, 150), (8, 150), (13, 150), (18, 150), (23, 150), (28, 150), (33, 135), (38, 118)])))
        #expect(state.canDose)
        state.workOutDose()
        #expect(runner.actions == ["countAndGoOn", "moveToDose", "raiseFirst", "workOutDose"])
    }

    @Test("Open Treatments only once the dose can be worked out") func openTreatmentsNeedsADose() {
        let router = SettingsTestFakeRouter()
        let state = ISFTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        state.router = router
        state.opener = makeOpener(router: router, ticks: PassthroughSubject())
        state.apply(ISFTestRunnerState(test: isfTest(.dosing)))
        // No recent reading, so no dose.
        state.show(isfData([]))
        state.openTreatments()
        #expect(router.mainModalScreen.value == nil)
        // 180 on target 100 and ISF 50: 1.6 U, with a flat arrow, nothing on board.
        state.show(isfData(readings(180)))
        #expect(state.canDose)
        state.openTreatments()
        #expect(router.mainModalScreen.value == .treatmentView)
    }

    // MARK: Ending

    @Test("An ISF step whose test is ending takes none of its actions") func isfEndingTakesNoActions() async {
        let runner = RecordingISFTestRunner()
        let router = SettingsTestFakeRouter()
        let state = ISFTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        state.testService = makeTestService().service
        state.screenReads = FakeISFScreenReads(isfData(readings(180)))
        state.router = router
        state.opener = makeOpener(router: router, ticks: PassthroughSubject())
        state.runner = runner
        state.show(isfData(readings(180)))
        let ending = ISFTestPendingEnd(reason: .noBolus, at: Date(), note: nil, byUser: false)

        // The Dose step, with a dose that Open Treatments would give.
        var dosing = isfTest(.dosing)
        dosing.pendingEnd = ending
        state.apply(ISFTestRunnerState(test: dosing))
        state.openTreatments()
        state.discard()
        #expect(router.mainModalScreen.value == nil)

        // The Settle step, at its time-up question.
        var settling = isfTest(.settling)
        settling.pendingEnd = ending
        state.apply(ISFTestRunnerState(test: settling, settling: ISFTestSettlingProgress(
            decision: .timeUp(loopedAt: Date().addingTimeInterval(-50 * minute)),
            boluses: [],
            readingsAfterLoop: nil,
            tempBasalRunning: false
        )))
        state.countAndGoOn()

        // The Raise step and the Wait step.
        var raising = isfTest(.raising)
        raising.pendingEnd = ending
        state.apply(ISFTestRunnerState(test: raising))
        state.skipTablets()
        state.tabletsTaken()
        var waiting = isfTest(.waiting)
        waiting.pendingEnd = ending
        state.apply(ISFTestRunnerState(test: waiting))
        await state.endEarly()

        #expect(runner.actions.isEmpty)
        #expect(runner.tablets.isEmpty)
    }

    @Test(
        "A step whose session the service ended is ending until its runner finishes; a lost session's Cancel Test stays"
    ) func endingWithNoSession() async throws {
        let runner = RecordingISFTestRunner()
        let settings = FakeSettingsManager()
        let state = ISFTest.StateModel()
        state.settingsManager = settings
        state.testService = makeTestService().service
        state.screenReads = FakeISFScreenReads(isfData(readings(180)))
        state.runner = runner
        let test = isfTest(.dosing)
        let sessionID = try #require(test.sessionID)
        state.apply(ISFTestRunnerState(test: test))
        let session = SettingsTestSession(
            id: sessionID,
            kind: .isf,
            startedAt: test.startedAt,
            expiresAt: Date().addingTimeInterval(3600),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )

        // Its session runs: the step's actions go to the runner.
        settings.settings.dosingMode = .basalTesting
        state.showSession(session, lastEnd: nil)
        #expect(!state.isEnding)

        // The service ended it for no bolus and brought the usual mode back: its runner's finish is to come.
        settings.settings.dosingMode = .closed
        state.showSession(nil, lastEnd: SettingsTestEnd(sessionID: sessionID, cause: .noBolus, date: Date()))
        #expect(state.isEnding)
        state.discard()
        await state.endEarly()
        #expect(runner.actions.isEmpty)

        // Lost, with Basal Testing still on and no end of it kept: Cancel Test is the way back.
        settings.settings.dosingMode = .basalTesting
        state.showSession(nil, lastEnd: nil)
        #expect(!state.isEnding)
        state.discard()
        #expect(runner.actions == ["discard"])
    }

    @Test("A fast that is ending takes neither End Now nor Discard") func basalEndingTakesNoActions() async {
        let runner = RecordingBasalTestRunner()
        let state = BasalTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        state.screenReads = FakeBasalScreenReads(basalData(readings(110)))
        state.runner = runner
        var fast = runningFast()
        fast.pendingEnd = BasalTestPendingEnd(reason: .completed, at: Date(), note: nil, byUser: false)
        state.apply(fast)

        state.discard()
        await state.endEarly()
        #expect(runner.actions.isEmpty)
    }

    // MARK: Settle

    @Test("The Settle step shows the insulin on board settling's last check read") func settleIOBFollowsRunner() {
        let state = ISFTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        var test = isfTest(.settling)
        test.iobLine = Decimal(string: "0.11")
        test.iobHandling = .wait
        func progress(waitsForIOB: Bool, iob: Decimal?) -> ISFTestSettlingProgress {
            ISFTestSettlingProgress(
                decision: .waiting(loopedAt: nil, waitsForIOB: waitsForIOB),
                boluses: [],
                readingsAfterLoop: nil,
                tempBasalRunning: false,
                iob: iob
            )
        }
        // The screen's own read says none on board.
        state.show(isfData(readings(180)))

        state.apply(ISFTestRunnerState(test: test, settling: progress(waitsForIOB: true, iob: Decimal(string: "0.3"))))
        #expect(state.currentIOB == Decimal(string: "0.3"))
        #expect(state.settleWaitsForIOB)
        // A refresh in between doesn't move the Settle step off the number its step rests on.
        state.show(isfData(readings(180)))
        #expect(state.currentIOB == Decimal(string: "0.3"))
        #expect(state.settleWaitsForIOB)

        state.apply(ISFTestRunnerState(test: test, settling: progress(waitsForIOB: false, iob: Decimal(string: "0.05"))))
        #expect(state.currentIOB == Decimal(string: "0.05"))
        #expect(!state.settleWaitsForIOB)

        // Settled: the screen's own read again.
        state.apply(ISFTestRunnerState(test: isfTest(.dosing)))
        #expect(state.currentIOB == 0)
    }

    // MARK: Forwarding

    /// An ISF screen on `runner`, reading `isfData(readings(180))`, with a settings test service that runs no test.
    private func isfScreen(_ runner: RecordingISFTestRunner) -> ISFTest.StateModel {
        let state = ISFTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        state.testService = makeTestService().service
        state.screenReads = FakeISFScreenReads(isfData(readings(180)))
        state.runner = runner
        return state
    }

    @Test("The ISF screen's refresh shows what it read, then has the runner check once") func isfRefreshChecks() async {
        let runner = RecordingISFTestRunner()
        let state = isfScreen(runner)
        await state.refresh()
        #expect(state.currentGlucose == 180)
        #expect(runner.checks == 1)
        await state.checkRunningTest()
        #expect(runner.checks == 2)
    }

    @Test("ISF Cancel Test, Done and End Test go to the runner; the first two start again on the docs' way") func isfEndings(
    ) async {
        let runner = RecordingISFTestRunner()
        let state = isfScreen(runner)

        state.iobChoice = .count
        state.discard()
        #expect(runner.actions == ["discard"])
        #expect(state.iobChoice == .wait)
        // The refresh it starts ends with a check.
        #expect(await eventuallyOnMain { runner.checks == 1 })

        state.iobChoice = .count
        state.acknowledgeResult()
        #expect(runner.actions == ["discard", "acknowledgeResult"])
        #expect(state.iobChoice == .wait)
        #expect(await eventuallyOnMain { runner.checks == 2 })

        await state.endEarly()
        #expect(runner.actions == ["discard", "acknowledgeResult", "endEarly"])
    }

    @Test("The basal screen's refresh, Discard, Done and End Now go to the runner") func basalForwards() async {
        let runner = RecordingBasalTestRunner()
        let state = BasalTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        state.screenReads = FakeBasalScreenReads(basalData(readings(110)))
        state.runner = runner

        await state.refresh()
        #expect(state.currentGlucose == 110)
        #expect(runner.checks == 1)
        await state.checkRunningTest()
        #expect(runner.checks == 2)

        state.discard()
        #expect(runner.actions == ["discard"])
        #expect(await eventuallyOnMain { runner.checks == 3 })
        state.acknowledgeResult()
        #expect(runner.actions == ["discard", "acknowledgeResult"])
        #expect(await eventuallyOnMain { runner.checks == 4 })
        await state.endEarly()
        #expect(runner.actions == ["discard", "acknowledgeResult", "endEarly"])
    }

    @Test("A fast that finishes on the basal screen has the week before it read for its Result") func basalFinishReadsTheWeek(
    ) async throws {
        let reads = FakeBasalScreenReads(basalData(readings(110)))
        let state = BasalTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        state.screenReads = reads
        let running = runningFast()
        state.apply(running)
        var finished = running
        finished.phase = .finished
        finished.endedAt = Date()
        state.apply(finished)
        #expect(await eventually { reads.smbReadsSince.count == 1 })
        #expect(reads.smbReadsSince.first == running.startedAt.addingTimeInterval(-BasalTest.Config.smbLookback))

        // The same finished fast published again, or one the screen opened on, reads nothing more here (`refresh` reads
        // the week for a screen opened on a finished fast).
        state.apply(finished)
        state.apply(nil)
        state.apply(finished)
        try await Task.sleep(for: .milliseconds(100))
        #expect(reads.smbReadsSince.count == 1)
    }

    // MARK: Adversarial review 2, part 2

    /// Readings at `(minutes before now, mg/dL)`, newest first.
    private func readings(_ points: [(Double, Int)]) -> [BasalTestReading] {
        points.map { BasalTestReading(date: Date().addingTimeInterval(-$0.0 * minute), glucose: $0.1) }
    }

    @Test(
        "The basal fast starts from the 3-reading mean, and not without a reading 12 minutes old or newer"
    ) func basalStartsFromTheMean() async throws {
        let runner = RecordingBasalTestRunner()
        let settings = FakeSettingsManager()
        settings.settings.dosingMode = .closed
        let state = BasalTest.StateModel()
        state.settingsManager = settings
        state.runner = runner
        // 112, 108 and 104, the newest a minute old: the fast starts from their mean, 108, not the newest reading.
        state.show(basalData(readings([(1, 112), (6, 108), (11, 104)])))
        #expect(state.readyToStart)
        state.confirmStart()
        #expect(await eventuallyOnMain { runner.begins.count == 1 })
        #expect(runner.begins.first?.glucose == 108)

        // The newest 13 minutes old: Start says there is no recent reading, and the runner isn't asked.
        let noRecent = "Trio has no recent glucose reading. Wait for your CGM's next reading, then try again."
        state.show(basalData(readings([(13, 110), (18, 110), (23, 110)])))
        state.requestStart()
        #expect(!state.showStartConfirmation)
        #expect(state.errorMessage == noRecent)
        state.errorMessage = nil
        state.confirmStart()
        try await Task.sleep(for: .milliseconds(100))
        #expect(runner.begins.count == 1)
        #expect(state.errorMessage == noRecent)
    }

    @Test(
        "The ISF Result's action follows the user's own Dynamic ISF: Logarithmic gets the docs' line for it"
    ) func isfResultActionFollowsDynamicISF() {
        let settings = FakeSettingsManager()
        let state = ISFTest.StateModel()
        state.settingsManager = settings
        var finished = isfTest(.finished)
        finished.outcome = .tooHigh
        state.apply(ISFTestRunnerState(test: finished))
        #expect(state.resultAction == .openSensitivities)
        settings.preferences.useNewFormula = true
        #expect(state.resultAction == .reevaluateDynamicSettings)
        // Sigmoid's line in the docs is the profile ISF's.
        settings.preferences.sigmoid = true
        #expect(state.resultAction == .openSensitivities)
    }

    @Test("Open Treatments and Work Out My Dose say why when their gate fails") func gatesSayWhy() {
        let router = SettingsTestFakeRouter()
        let state = ISFTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        state.router = router
        state.opener = makeOpener(router: router, ticks: PassthroughSubject())
        state.apply(ISFTestRunnerState(test: isfTest(.dosing)))

        // The newest reading has aged past 12 minutes since the step was drawn: no dose now, so the tap says why.
        state.show(isfData(readings([(13, 180), (18, 180), (23, 180)])))
        state.openTreatments()
        #expect(router.mainModalScreen.value == nil)
        #expect(state.errorMessage == "Waiting for a recent CGM reading")
        // A dose, with the arrow moving.
        state.errorMessage = nil
        var moving = isfData(readings(180))
        moving.trendDirection = .singleUp
        state.show(moving)
        state.openTreatments()
        #expect(router.mainModalScreen.value == nil)
        #expect(state.errorMessage == "Open Treatments turns on once the arrow is flat.")
        // Carbs on board: the step's own sentence.
        state.errorMessage = nil
        var carbs = isfData(readings(180))
        carbs.cob = 8
        state.show(carbs)
        state.openTreatments()
        #expect(
            state.errorMessage == "Carbs are on board, so the test can't be judged. The docs test ISF with no carbs on board."
        )

        // Work Out My Dose with the tablets taken a minute ago: they haven't acted yet.
        state.errorMessage = nil
        var raising = isfTest(.raising)
        raising.tabletsTakenAt = Date().addingTimeInterval(-minute)
        raising.tabletsGlucose = 110
        state.apply(ISFTestRunnerState(test: raising))
        state.show(isfData(readings(110)))
        state.workOutDose()
        #expect(state.errorMessage == "Waiting for your glucose to rise from the tablets.")
    }

    @Test("The hub hears each runner's test reach finished, once each, and not the one there as it opened") func hubHearsFinishes() {
        let held = isfTest(.finished)
        let isf = CurrentValueSubject<ISFTestRunnerState, Never>(ISFTestRunnerState(test: held))
        let basal = CurrentValueSubject<BasalTestState?, Never>(nil)
        var heard = 0
        let subscription = SettingsTest.StateModel.testFinishes(
            isf: isf.eraseToAnyPublisher(),
            basal: basal.eraseToAnyPublisher()
        ).sink { heard += 1 }
        defer { subscription.cancel() }
        // The result each runner holds now is the one the hub read as it opened.
        #expect(heard == 0)
        // A new ISF test runs, then finishes: heard once, however often it is published after.
        let running = isfTest(.waiting)
        isf.send(ISFTestRunnerState(test: running))
        #expect(heard == 0)
        var done = running
        done.phase = .finished
        isf.send(ISFTestRunnerState(test: done))
        #expect(heard == 1)
        isf.send(ISFTestRunnerState(test: done, settling: nil, doseIOB: nil))
        #expect(heard == 1)
        // Done clears it: nothing to hear.
        isf.send(ISFTestRunnerState())
        #expect(heard == 1)
        // A basal fast finishes.
        let fast = runningFast()
        basal.send(fast)
        var ended = fast
        ended.phase = .finished
        basal.send(ended)
        #expect(heard == 2)
        basal.send(nil)
        #expect(heard == 2)
    }

    // MARK: Adversarial review 2, fix round 3

    /// An ISF schedule of 6-hour blocks in `Calendar.current`'s minutes of the day, values 50, 45, 40 and 35, whose first
    /// change comes `firstChangeAfter` from now.
    private func sixHourBlocks(firstChangeAfter: TimeInterval) -> [SettingsTestScheduleEntry] {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: Date().addingTimeInterval(firstChangeAfter))
        let first = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let starts = (0 ..< 4).map { (first + $0 * 360) % 1440 }.sorted()
        let values: [Decimal] = [50, 45, 40, 35]
        func entry(_ start: Int, _ end: Int, _ value: Decimal) -> SettingsTestScheduleEntry {
            SettingsTestScheduleEntry(startMinutes: start, endMinutes: end, value: value)
        }
        let blocks = starts.enumerated().map { index, start in
            entry(start, index + 1 < starts.count ? starts[index + 1] : 1440, values[index])
        }
        return ([entry(0, starts[0], values[3])] + blocks).filter { $0.startMinutes < $0.endMinutes }
    }

    @Test(
        "The Check holds Begin up when no bolus moment the test can reach has its 4 hours on one ISF value, and only informs otherwise"
    ) func checkBlocksAStuckISFChange() async {
        let settings = FakeSettingsManager()
        settings.settings.dosingMode = .closed
        let state = ISFTest.StateModel()
        state.settingsManager = settings
        state.testService = makeTestService().service
        let reads = FakeISFScreenReads(isfData(readings(180)))
        // 6-hour blocks, the next change 2 h 45 m away: past the latest dose deadline, so every bolus moment's 4 hours
        // reach past it (N1).
        reads.isfSchedule = sixHourBlocks(firstChangeAfter: 165 * 60)
        state.screenReads = reads
        await state.refresh()
        #expect(!state.readyToStart)
        #expect(state.failingChecks.map(\.id).contains("isfChange"))
        #expect(state.startBlocker == "The 4 hours from now cover more than one ISF.")
        #expect(!state.informingChecks.map(\.id).contains("isfChange"))

        // The next change 2 h 20 m away (a Begin at 9:40 on blocks at 00/06/12/18): past a dose deadline 90 minutes after
        // settling's earliest end, so Begin waits too (fix round 5, M1).
        reads.isfSchedule = sixHourBlocks(firstChangeAfter: 140 * 60)
        await state.refresh()
        #expect(!state.readyToStart)
        #expect(state.startBlocker == "The 4 hours from now cover more than one ISF.")
        reads.isfSchedule = sixHourBlocks(firstChangeAfter: 120 * 60)
        await state.refresh()
        #expect(!state.readyToStart)

        // The next change an hour away: a bolus from it on is on one value, so the row only informs, as before.
        reads.isfSchedule = sixHourBlocks(firstChangeAfter: 60 * 60)
        await state.refresh()
        #expect(state.readyToStart)
        #expect(state.informingChecks.map(\.id).contains("isfChange"))
    }

    // MARK: - CodeRabbit on PR #26

    @Test(
        "An ISF refresh that finishes after a newer one has shown its reads shows nothing of its own"
    ) func olderISFRefreshShowsNothing(
    ) async {
        let state = ISFTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        state.testService = makeTestService().service
        // The older refresh read no carbs on board, before carbs went in; the newer one reads them.
        let cob = HeldRead<Decimal?>(first: 0, later: 30)
        state.screenReads = HeldCOBISFScreenReads(isfData(readings(180)), cob: cob)

        async let older: Void = state.refresh()
        #expect(await eventually { cob.isHolding })
        await state.refresh()
        #expect(state.currentCOB == 30)
        cob.release()
        await older
        #expect(state.currentCOB == 30)
    }

    @Test(
        "A basal refresh that finishes after a newer one has shown its reads shows nothing of its own"
    ) func olderBasalRefreshShowsNothing(
    ) async {
        let state = BasalTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        // The older refresh read no carbs, before a snack was logged; the newer one reads it.
        let snack = Date().addingTimeInterval(-30 * minute)
        let lastCarb = HeldRead<Date?>(first: nil, later: snack)
        state.screenReads = HeldCarbsBasalScreenReads(basalData(readings(110)), lastCarb: lastCarb)

        async let older: Void = state.refresh()
        #expect(await eventually { lastCarb.isHolding })
        await state.refresh()
        #expect(state.lastCarb == snack)
        lastCarb.release()
        await older
        #expect(state.lastCarb == snack)
        #expect(!state.fastedLongEnough)
    }

    @Test(
        "A basal refresh whose SMB read fails shows the error, though its own reads were just shown"
    ) func fastingSourceErrorShows(
    ) async {
        let state = BasalTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        state.screenReads = FailingSMBBasalScreenReads(basalData(readings(110)))

        await state.refresh()
        #expect(state.errorMessage != nil)
    }

    @Test(
        "The Wait and Fast steps show no glucose now, nor a change from it, once the newest reading is out of date"
    ) func staleReadingIsNotNow() {
        let old = [16, 21, 26].map { BasalTestReading(date: Date().addingTimeInterval(-Double($0) * minute), glucose: 180) }

        let isf = ISFTest.StateModel()
        isf.show(isfData(readings(180)))
        #expect(isf.glucoseNow == 180)
        isf.show(isfData(old))
        #expect(isf.readingIsStale)
        #expect(isf.glucoseNow == nil)

        let basal = BasalTest.StateModel()
        basal.show(basalData(readings(110)))
        #expect(basal.glucoseNow == 110)
        basal.show(basalData(old))
        #expect(basal.readingIsStale)
        #expect(basal.glucoseNow == nil)
    }

    @Test(
        "The ISF screen's arrow is the newest reading's own, read with the readings the dose comes from"
    ) func isfArrowFromTheDoseReadings(
    ) async {
        let state = ISFTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        state.testService = makeTestService().service
        // The newest reading the dose reads came with a rising arrow; the newest-direction read, a moment later, found a
        // newer reading's flat arrow.
        var data = isfData(readings(180))
        data.readings[0] = BasalTestReading(date: data.readings[0].date, glucose: 180, direction: .singleUp)
        data.trendDirection = .flat
        state.screenReads = FakeISFScreenReads(data)
        state.apply(ISFTestRunnerState(test: isfTest(.dosing)))

        await state.refresh()
        #expect(state.doseInputs.direction == .singleUp)
        #expect(!state.glucoseIsLevel)
        #expect(!state.canDose)
    }

    // MARK: - CodeRabbit on PR #26, round 2

    @Test(
        "The basal Check's glucose row shows the mean the fast starts from, and without one the newest reading and its age"
    ) func basalGlucoseRowIsTheMean() throws {
        let state = BasalTest.StateModel()
        state.settingsManager = FakeSettingsManager()
        func readings(_ ages: [(minutes: Double, glucose: Int)]) -> [BasalTestReading] {
            ages.map { BasalTestReading(date: Date().addingTimeInterval(-$0.minutes * minute), glucose: $0.glucose) }
        }

        state.show(basalData(readings([(1, 112), (6, 108), (11, 104)])))
        #expect(state.startGlucose == 108)
        let row = try #require(state.informingChecks.first { $0.id == "glucose" })
        #expect(row.value == state.formatWithUnits(108))
        #expect(
            row.info.body
                ==
                "The average of your last 3 CGM readings, where the fast starts from. Without a recent reading, this shows your newest one and how old it is. It's here for you to judge and doesn't hold up the start."
        )

        // The newest 13 minutes old: no mean to start from, so the newest reading and how old it is.
        state.show(basalData(readings([(13, 112), (18, 108), (23, 104)])))
        #expect(state.startGlucose == nil)
        let old = try #require(state.informingChecks.first { $0.id == "glucose" })
        #expect(old.value?.hasPrefix(state.formatWithUnits(112) + ", ") == true)
        #expect(old.value?.hasSuffix(" ago") == true)
    }

    @Test(
        "Trio's suggestion too small for the test to judge says to enter the formula's dose, in the note and its sheet"
    ) func suggestionTooSmallSaysEnterTheDose() throws {
        let settings = FakeSettingsManager()
        settings.settings.overrideFactor = Decimal(string: "0.57")!
        let state = ISFTest.StateModel()
        state.settingsManager = settings
        var test = isfTest(.dosing)
        test.target = 140
        state.apply(ISFTestRunnerState(test: test))
        func shown(_ units: Decimal) -> String { SettingsTestFormat.keepTogether(state.formatUnits(units), unit: "U") }

        // 155 on target 140 and ISF 50: 0.30 U, a 15 mg/dL drop. 57% of it is 0.17 U, 8.5 mg/dL: no whole reading lies
        // within a docs step of where that takes glucose, so it would end as too small to judge.
        state.show(isfData(readings(155)))
        let dose = try #require(state.docsDose)
        let suggestion = try #require(state.trioSuggestion)
        #expect(dose == Decimal(string: "0.3"))
        #expect(suggestion == Decimal(string: "0.17"))
        #expect(ISFTestEvaluator.suggestionTooSmall(suggestion: suggestion, dose: dose, glucose: 155, isf: 50, iob: 0))
        let small = state.suggestionNote(suggestion: suggestion, dose: dose)
        #expect(
            small.note
                ==
                "Trio will suggest about \(shown(suggestion)). That's 57% of the formula's \(shown(dose)). Enter the formula's \(shown(dose)) instead of tapping Trio's suggestion."
        )
        #expect(
            small.info
                ==
                "Trio's bolus calculator suggests the formula's dose times your Recommended Bolus Percentage (57%). That's too small for this test to tell your ISF apart from CGM noise, so enter the formula's \(shown(dose))."
        )

        // At 210 it's 1.40 U and 0.80 U: either is fine, as before.
        state.show(isfData(readings(210)))
        let bigger = try #require(state.docsDose)
        let biggerSuggestion = try #require(state.trioSuggestion)
        #expect(!ISFTestEvaluator.suggestionTooSmall(suggestion: biggerSuggestion, dose: bigger, glucose: 210, isf: 50, iob: 0))
        let fine = state.suggestionNote(suggestion: biggerSuggestion, dose: bigger)
        #expect(fine.note.hasSuffix("Either is fine: the result is worked out from what you give."))
        #expect(
            fine.info
                .hasSuffix(
                    "Tap Trio's suggestion or enter the formula's dose: the test judges your ISF per unit you actually give."
                )
        )
    }
}
