import Combine
import Foundation
import LoopKit
import SwiftUI
import Swinject
import Testing
import UserNotifications

@testable import Trio

// Shared fakes and the one harness for the settings test service's runtime and its runners' tests.

/// A settings manager that keeps everything in memory.
final class FakeSettingsManager: SettingsManager {
    var settings = TrioSettings() {
        didSet { onSettingsChange?() }
    }

    /// Called each time the settings change, so a test can look at what else was true at that moment.
    var onSettingsChange: (() -> Void)?
    var preferences = Preferences()
    var pumpSettings = PumpSettings(insulinActionCurve: 10, maxBolus: 10, maxBasal: 2)
    func updateInsulinCurve(_: InsulinType?) {}
}

/// Tells no one: a test calls the service's observer itself.
final class SilentBroadcaster: Broadcaster {
    func register<T>(_: T.Type, observer _: T) {}
    func unregister<T>(_: T.Type, observer _: T) {}
    func unregister<T>(_: T.Type) {}
    func notify<T>(_: T.Type, on _: DispatchQueue, block _: @escaping (T) -> Void) {}
}

/// Pump history, Trio's determinations and carbs as a test sets them, with how often the service asked.
final class FakeSettingsTestData: SettingsTestEvents {
    var temps: [BasalTestTempBasal] = []
    /// When Trio's determinations asked for a zero temp.
    var zeroTempDeterminations: [Date] = []
    var carbs: [Date] = []
    var boluses: [ISFTestBolus] = []
    /// Boluses the pump history flagged as SMBs. In Basal Testing that can only be a bolus the user gave, flagged when
    /// its delivered amount came in, and the read takes them like the others.
    var smbFlaggedBoluses: [ISFTestBolus] = []
    /// When the pump was suspended or resumed, alarmed, or had its site or reservoir changed.
    var pumpEvents: [Date] = []
    var failing = false
    /// Fail only one read each.
    var failingTemps = false
    var failingDeterminations = false
    var failingCarbs = false
    /// Fails only the bolus read, so the temps and carbs before it are still read.
    var failingBoluses = false
    var failingPumpEvents = false

    /// The counters a launch check and a test's own calls can change at the same time.
    private let counterLock = NSLock()
    private var _reads = 0
    private var _failures: [FailingRead: ReadFailures] = [:]
    private var _determinationReads = 0
    private var _tempBasalReads = 0

    var reads: Int { counterLock.withLock { _reads } }

    private func countRead() {
        counterLock.withLock { _reads += 1 }
    }

    /// The ISF runner's reads a test can have throw a set number of times (`failNext`).
    enum FailingRead {
        /// `fetchGlucose`.
        case glucose
        /// `fetchArrowReading`.
        case arrow
        /// `fetchDeterminations`.
        case determinations
    }

    /// How many reads of one kind throw, after how many go through first, and how many have thrown.
    private struct ReadFailures {
        var passing = 0
        var left = 0
        var thrown = 0
    }

    /// Has the next `times` reads of `read` throw, after letting `passing` of them through first.
    func failNext(_ read: FailingRead, times: Int = 1, afterPassing passing: Int = 0) {
        counterLock.withLock { _failures[read] = ReadFailures(passing: passing, left: times) }
    }

    /// How many reads of `read` have thrown.
    func thrown(_ read: FailingRead) -> Int {
        counterLock.withLock { _failures[read]?.thrown ?? 0 }
    }

    /// Whether this read is one set to throw, counting it if it is.
    private func takesFailure(_ read: FailingRead) -> Bool {
        counterLock.withLock {
            guard var failures = _failures[read], failures.left > 0 else { return false }
            defer { _failures[read] = failures }
            if failures.passing > 0 {
                failures.passing -= 1
                return false
            }
            failures.left -= 1
            failures.thrown += 1
            return true
        }
    }

    /// Awaited by every read of the temp basals, the first read of the service's own check, so a test can hold one there.
    var onTempBasals: (() async -> Void)?
    /// How many times the temp basals were read.
    var tempBasalReads: Int { counterLock.withLock { _tempBasalReads } }

    // What the ISF test's runner reads besides (`ISFTestReads`). Its bolus records are read back from `boluses`.
    /// CGM readings, oldest first.
    var readings: [BasalTestReading] = []
    /// The CGM's arrows, each dated at the reading in `readings` it came with; a reading with none has no arrow.
    var arrows: [ISFTestArrowReading] = []
    /// Trio's determinations, with the insulin and carbs on board each held.
    var determinations: [ISFTestDetermination] = []
    /// The rows the pump history flags as SMBs.
    var smbs: [BasalTestSMB] = []
    /// Insulin on board now. Nil while Trio hasn't worked it out.
    var iob: Decimal?
    /// What the pump is doing with basal now (`ISFTestReads.pumpDelivery()`, whose name a property can't share).
    var deliveryState: ISFTestPumpDelivery?
    var isfSchedule: [SettingsTestScheduleEntry] = []
    var targetSchedule: [SettingsTestScheduleEntry] = []
    /// The basal schedule the basal test's runner reads (`BasalTestReads.basalEntries`).
    var basalSchedule: [SettingsTestScheduleEntry] = []
    var carbRatio: Decimal?
    /// Awaited by every read of the determinations, so a test can hold a check in the middle of its reads.
    var onFetchDeterminations: (() async -> Void)?
    var determinationReads: Int { counterLock.withLock { _determinationReads } }

    fileprivate func countDeterminationRead() {
        counterLock.withLock { _determinationReads += 1 }
    }

    struct Failure: Error {}

    /// Trio's suspend for a low at `date`: the zero temp the pump started, and the determination just before it.
    func trioSuspends(at date: Date) {
        temps.append(BasalTestTempBasal(date: date, rate: 0, minutes: 30))
        zeroTempDeterminations.append(date.addingTimeInterval(-30))
    }

    func tempBasals(from start: Date, to end: Date) async throws -> [BasalTestTempBasal] {
        countRead()
        counterLock.withLock { _tempBasalReads += 1 }
        await onTempBasals?()
        if failing || failingTemps { throw Failure() }
        return temps.filter { $0.date >= start && $0.date <= end }
    }

    func zeroTempDeterminations(from start: Date, to end: Date) async throws -> [Date] {
        countRead()
        if failing || failingDeterminations { throw Failure() }
        return zeroTempDeterminations.filter { $0 >= start && $0 <= end }
    }

    func hasCarbEntries(from start: Date, to end: Date) async throws -> Bool {
        countRead()
        if failing || failingCarbs { throw Failure() }
        return carbs.contains { $0 >= start && $0 <= end }
    }

    func allBoluses(from start: Date, to end: Date) async throws -> [ISFTestBolus] {
        countRead()
        if failing || failingBoluses { throw Failure() }
        // `units` stands for the amount the history recorded, and a bolus recorded at 0 U is dropped as the real source
        // drops it (`ISFTestBolus(date:amount:)`).
        return (boluses + smbFlaggedBoluses)
            .filter { $0.date >= start && $0.date <= end }
            .compactMap { ISFTestBolus(date: $0.date, amount: $0.units) }
            .sorted { $0.date < $1.date }
    }

    func pumpInterruptions(from start: Date, to end: Date) async throws -> [Date] {
        countRead()
        if failing || failingPumpEvents { throw Failure() }
        return pumpEvents.filter { $0 >= start && $0 <= end }.sorted()
    }
}

/// The same scenario as the ISF test's runner reads it, so the watchdog and the runner see one set of data.
extension FakeSettingsTestData: ISFTestReads {
    func isfEntries() -> [SettingsTestScheduleEntry] { isfSchedule }
    func targetEntries() -> [SettingsTestScheduleEntry] { targetSchedule }
    func isf(at date: Date) -> Decimal? { ISFTestEvaluator.scheduleValue(in: isfSchedule, at: date) }
    func target(at date: Date) -> Decimal? { ISFTestEvaluator.scheduleValue(in: targetSchedule, at: date) }
    func carbRatio(at _: Date) -> Decimal? { carbRatio }
    func currentIOB() -> Decimal? { iob }
    func pumpDelivery() -> ISFTestPumpDelivery? { deliveryState }

    /// From Trio's newest determination of the last 12 minutes, as the provider reads it.
    func currentCOB() async throws -> Decimal? {
        let now = Date()
        let recent = try await fetchDeterminations(
            from: now.addingTimeInterval(-BasalTest.Config.endReadingMaxAge - ISFTest.Config.savedDateTolerance),
            to: now.addingTimeInterval(ISFTest.Config.savedDateTolerance)
        )
        return ISFTestEvaluator.recentCOB(recent, now: now)
    }

    func fetchGlucose(from start: Date, to end: Date) async throws -> [BasalTestReading] {
        if failing { throw Failure() }
        if takesFailure(.glucose) { throw Failure() }
        return readings.filter { $0.date >= start && $0.date <= end }.sorted { $0.date < $1.date }
    }

    /// Newest first.
    func fetchRecentGlucose(minutes: Int) async throws -> [BasalTestReading] {
        if failing { throw Failure() }
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        return readings.filter { $0.date > cutoff }.sorted { $0.date > $1.date }
    }

    /// The newest reading's arrow, nil when it came with none, as the provider reads it.
    func fetchNewestDirection() async throws -> BloodGlucose.Direction? {
        if failing { throw Failure() }
        guard let newest = readings.max(by: { $0.date < $1.date }) else { return nil }
        return arrow(at: newest.date)
    }

    /// The arrow that came with the reading at `date`, nil when it came with none.
    private func arrow(at date: Date) -> BloodGlucose.Direction? {
        arrows.first { $0.date == date }?.direction
    }

    func fetchDeterminations(from start: Date, to end: Date) async throws -> [ISFTestDetermination] {
        countDeterminationRead()
        await onFetchDeterminations?()
        if failing { throw Failure() }
        if takesFailure(.determinations) { throw Failure() }
        return determinations.filter { $0.date >= start && $0.date <= end }.sorted { $0.date < $1.date }
    }

    func fetchBoluses(from start: Date, to end: Date) async throws -> [ISFTestBolus] {
        try await allBoluses(from: start, to: end)
    }

    func fetchBolusRecords(from start: Date, to end: Date) async throws -> [ISFTestBolusRecord] {
        if failing || failingBoluses { throw Failure() }
        return (boluses + smbFlaggedBoluses)
            .filter { $0.date >= start && $0.date <= end }
            .sorted { $0.date < $1.date }
            .map { ISFTestBolusRecord(date: $0.date, amount: $0.units) }
    }

    func fetchSMBs(since start: Date, until end: Date) async throws -> [BasalTestSMB] {
        if failing { throw Failure() }
        return smbs.filter { $0.date >= start && $0.date <= end }.sorted { $0.date < $1.date }
    }

    func fetchTempBasals(from start: Date, to end: Date) async throws -> [BasalTestTempBasal] {
        try await tempBasals(from: start, to: end)
    }

    /// The newest reading from the 12 minutes before `date` to it, with its arrow, as the provider reads it.
    func fetchArrowReading(atOrBefore date: Date) async throws -> ISFTestArrowReading? {
        if failing { throw Failure() }
        if takesFailure(.arrow) { throw Failure() }
        let latest = date.addingTimeInterval(ISFTest.Config.savedDateTolerance)
        let earliest = date.addingTimeInterval(-BasalTest.Config.endReadingMaxAge - ISFTest.Config.savedDateTolerance)
        guard let newest = readings.filter({ $0.date >= earliest && $0.date <= latest }).max(by: { $0.date < $1.date })
        else { return nil }
        return ISFTestArrowReading(date: newest.date, direction: arrow(at: newest.date))
    }

    func fetchSuspendReading(startedAt: Date, to end: Date) async throws -> BasalTestEvaluator.SuspendReading {
        try await isfSuspendReading(startedAt: startedAt, to: end)
    }

    func fetchPumpInterruptions(from start: Date, to end: Date) async throws -> [Date] {
        try await pumpInterruptions(from: start, to: end)
    }

    func fetchDoseIOB(at now: Date) async throws -> Decimal? {
        let recent = try await fetchDeterminations(
            from: now.addingTimeInterval(-BasalTest.Config.endReadingMaxAge - ISFTest.Config.savedDateTolerance),
            to: now.addingTimeInterval(ISFTest.Config.savedDateTolerance)
        )
        return ISFTestEvaluator.recentIOB(recent, now: now)
    }
}

/// The same scenario as the basal test's runner reads it. Its ISF, glucose, SMB, temp basal and carb reads are the ones above
/// (`ISFTestReads`); a manual bolus is one of `boluses`, not one the history flags as an SMB.
extension FakeSettingsTestData: BasalTestReads {
    func basalEntries() -> [SettingsTestScheduleEntry] { basalSchedule }

    func fetchSuspendReading(from start: Date, to end: Date) async throws -> BasalTestEvaluator.SuspendReading {
        try await suspendReading(from: start, to: end)
    }

    func hasManualBolus(from start: Date, to end: Date) async throws -> Bool {
        if failing || failingBoluses { throw Failure() }
        return boluses.contains { $0.date >= start && $0.date <= end }
    }
}

// MARK: - Notifications

/// Records what the notifier asked the notification center for.
final class RecordingNotificationCenter: SettingsTestNotificationCenter {
    private let lock = NSLock()
    private var _added: [UNNotificationRequest] = []
    private var _removedPending: [String] = []
    private var _removedDelivered: [String] = []
    private var _addError: Error?

    /// What `add` reports to its completion handler: nil is a notification that was accepted.
    var addError: Error? {
        get { lock.withLock { _addError } }
        set { lock.withLock { _addError = newValue } }
    }

    var added: [UNNotificationRequest] { lock.withLock { _added } }
    var removedPending: [String] { lock.withLock { _removedPending } }
    var removedDelivered: [String] { lock.withLock { _removedDelivered } }

    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable(Error?) -> Void)?) {
        lock.withLock { _added.append(request) }
        completionHandler?(addError)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        lock.withLock { _removedPending.append(contentsOf: identifiers) }
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        lock.withLock { _removedDelivered.append(contentsOf: identifiers) }
    }
}

/// Records each notice a runner posts or withdraws, and passes it on to a real notifier over its own recording center,
/// so a test can also check what reached the center.
final class RecordingSettingsTestNotifier: SettingsTestNotifying {
    struct Withdrawal: Equatable {
        let kind: SettingsTestKind
        let slot: SettingsTestNotice.Slot
    }

    let center = RecordingNotificationCenter()
    private let notifier: SettingsTestNotifier
    private let lock = NSLock()
    private var _posted: [SettingsTestNotice] = []
    private var _postedOffMain: [SettingsTestNotice] = []
    private var _withdrawn: [Withdrawal] = []
    private var _legacyWithdrawals = 0

    var posted: [SettingsTestNotice] { lock.withLock { _posted } }
    /// The notices posted from off the main thread.
    var postedOffMain: [SettingsTestNotice] { lock.withLock { _postedOffMain } }
    var withdrawn: [Withdrawal] { lock.withLock { _withdrawn } }
    /// How often the legacy notifications were withdrawn on their own, without a post.
    var legacyWithdrawals: Int { lock.withLock { _legacyWithdrawals } }

    init() {
        notifier = SettingsTestNotifier(center: center)
    }

    func post(_ notice: SettingsTestNotice) {
        let onMain = Thread.isMainThread
        lock.withLock {
            _posted.append(notice)
            if !onMain { _postedOffMain.append(notice) }
        }
        notifier.post(notice)
    }

    func withdraw(_ kind: SettingsTestKind, _ slot: SettingsTestNotice.Slot) {
        lock.withLock { _withdrawn.append(Withdrawal(kind: kind, slot: slot)) }
        notifier.withdraw(kind, slot)
    }

    func withdrawLegacy() {
        lock.withLock { _legacyWithdrawals += 1 }
        notifier.withdrawLegacy()
    }
}

// MARK: - Runner

/// A runner a test sets running or idle, counting how often the service checked it and what the service had kept as the
/// last ending when it did.
final class FakeSettingsTestRunner: SettingsTestRunner {
    let kind: SettingsTestKind
    private weak var service: SettingsTestService?
    private let lock = NSLock()
    private var _running: Bool
    private var _checks = 0
    private var _lastEndSeen: SettingsTestEnd?

    /// `running` is idle by default, so the service makes no check for it at init unless a test says it is running.
    init(kind: SettingsTestKind, service: SettingsTestService, running: Bool = false) {
        self.kind = kind
        self.service = service
        _running = running
    }

    var running: Bool {
        get { lock.withLock { _running } }
        set { lock.withLock { _running = newValue } }
    }

    var isRunning: Bool { running }
    var checks: Int { lock.withLock { _checks } }
    /// What `service.lastEnd()` returned in the latest check.
    var lastEndSeen: SettingsTestEnd? { lock.withLock { _lastEndSeen } }

    func check() async {
        let end = service?.lastEnd()
        lock.withLock {
            _checks += 1
            _lastEndSeen = end
        }
    }
}

// MARK: - Router

/// Trio's router with nothing behind it, for what a test sends to the main modal. Named apart from the private
/// `FakeRouter` of `AIRequestTreatmentsSessionTests`.
final class SettingsTestFakeRouter: Router {
    let mainModalScreen = CurrentValueSubject<Screen?, Never>(nil)
    let mainSecondaryModalView = CurrentValueSubject<AnyView?, Never>(nil)

    func view(for _: Screen) -> AnyView {
        AnyView(EmptyView())
    }
}

// MARK: - Shared files

/// One suite at a time may use the settings test files on disk (the session, history, last end and each test's state):
/// they are one set for the whole process, and Swift Testing runs suites side by side. Without this, a session another
/// suite saved reaches a service that was meant to start with none.
actor SettingsTestFilesLock {
    static let shared = SettingsTestFilesLock()

    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !held {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Holds the lock for the whole of a suite that uses those files, so the suites that do run one after another. Every
/// such suite carries it, the old service suite and the runtime and runner suites alike. A suite's tests already run one
/// at a time (`.serialized`). While it holds the lock, `isHeld` is true for the suite's tests, which `makeTestService`
/// checks, so a suite that forgets the trait fails at once.
///
/// It also removes the files as the suite starts, after each of its tests, and as it ends, so a run leaves nothing on disk:
/// the test host's own `SettingsTestService` and its runners load whatever is there when the host launches, and would run
/// a test found there beside the suites.
///
/// A suite trait: put it on the suite. It conforms to `TestTrait` only so the suite's tests get their own scope, and on a
/// lone `@Test` it would remove the files after that test but never take the lock.
struct SettingsTestFilesTrait: SuiteTrait, TestTrait, TestScoping {
    @TaskLocal static var isHeld = false
    /// True inside one test's own scope, the one that removes its files after it, so a test can see that scope is there.
    @TaskLocal static var inTestScope = false

    /// The settings test files on disk: the session, the history, the last end and each test's state.
    static let paths = [
        "trio/settings_test_session.json",
        "trio/settings_test_history.json",
        "trio/settings_test_last_end.json",
        "trio/isf_test_state.json",
        "trio/basal_test_state.json"
    ]

    static func removeFiles(from storage: FileStorage = BaseFileStorage()) {
        for path in paths {
            storage.remove(path)
        }
    }

    /// On the suite and on each of its tests: the suite holds the lock, and each test's files are removed after it.
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        test.isSuite || testCase != nil ? self : nil
    }

    func provideScope(
        for test: Test,
        testCase _: Test.Case?,
        performing function: @Sendable() async throws -> Void
    ) async throws {
        guard test.isSuite else {
            // Passed or not.
            defer { Self.removeFiles() }
            try await Self.$inTestScope.withValue(true) { try await function() }
            return
        }
        // A suite inside one that holds the lock runs under it.
        guard !Self.isHeld else {
            try await function()
            return
        }
        await SettingsTestFilesLock.shared.acquire()
        // What a run that crashed left.
        Self.removeFiles()
        do {
            try await Self.$isHeld.withValue(true) { try await function() }
        } catch {
            Self.removeFiles()
            await SettingsTestFilesLock.shared.release()
            throw error
        }
        Self.removeFiles()
        await SettingsTestFilesLock.shared.release()
    }
}

extension Trait where Self == SettingsTestFilesTrait {
    /// The suite uses the settings test files on disk, so it runs while no other suite that does is running.
    static var settingsTestFiles: Self { SettingsTestFilesTrait() }
}

// MARK: - Waiting

/// Holds whoever passes until a test opens it, then lets everyone through.
final class TestGate {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiting: Int { lock.withLock { waiters.count } }

    func pass() async {
        await withCheckedContinuation { continuation in
            let goes = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if goes { continuation.resume() }
        }
    }

    func open() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        released.forEach { $0.resume() }
    }
}

/// Whether the condition holds within the timeout, polled every 10 ms.
func eventually(timeout: Duration = .seconds(2), _ condition: @escaping () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// The same, with the condition read on the main actor, for what an `@MainActor` object holds. Its sleeps let the main
/// queue run, so anything the object put there happens meanwhile.
@MainActor func eventuallyOnMain(timeout: Duration = .seconds(2), _ condition: @MainActor() -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

// MARK: - Harness

extension BaseSettingsTestService {
    /// One check of the service, then the runner checks it started, which the service itself never waits for: for a test
    /// that looks at what a runner did with what the service's check found.
    func checkSessionAndRunners() async {
        for runnerCheck in await checkSession() {
            await runnerCheck.value
        }
    }
}

struct SettingsTestHarness {
    let service: BaseSettingsTestService
    let settings: FakeSettingsManager
    let storage: FileStorage
    let notifier: RecordingSettingsTestNotifier
}

/// Clears the session, history, last-end and both test-state paths (unless `keepingFiles`), saves `existing`, runs
/// `beforeStart(storage)` to write state files, sets `settings.settings.dosingMode = mode`, registers `storage`,
/// `settings` and `SilentBroadcaster` in a `Container`, then builds the service with `events: data` and a runtime whose
/// `makeRunners` calls `runners(context, notifier)`. The context's `settingsManager` is `settings`, the same instance.
/// The calling suite must carry `.settingsTestFiles` (the files on disk are shared), which this checks.
func makeTestService(
    mode: DosingMode = .closed,
    existing: SettingsTestSession? = nil,
    data: FakeSettingsTestData = FakeSettingsTestData(),
    settings: FakeSettingsManager = FakeSettingsManager(),
    beforeStart: (FileStorage) -> Void = { _ in },
    triggers: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher(),
    triggerDebounce: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(50),
    runners: @escaping (SettingsTestRunnerContext, RecordingSettingsTestNotifier) -> [SettingsTestRunner] = { _, _ in [] },
    keepingFiles: Bool = false
) -> SettingsTestHarness {
    precondition(
        SettingsTestFilesTrait.isHeld,
        "A suite that uses makeTestService must carry the .settingsTestFiles trait: the settings test files on disk are shared"
    )
    let storage = BaseFileStorage()
    if !keepingFiles {
        SettingsTestFilesTrait.removeFiles(from: storage)
    }
    if let existing { storage.save(existing, as: "trio/settings_test_session.json") }
    beforeStart(storage)
    settings.settings.dosingMode = mode

    let container = Container()
    container.register(FileStorage.self) { _ in storage }
    container.register(SettingsManager.self) { _ in settings }
    // The app's broadcaster is shared, so another suite's settings change would reach this service.
    container.register(Broadcaster.self) { _ in SilentBroadcaster() }

    let notifier = RecordingSettingsTestNotifier()
    let runtime = SettingsTestRuntime(
        makeRunners: { runners($0, notifier) },
        checkTriggers: triggers,
        triggerDebounce: triggerDebounce
    )
    let service = BaseSettingsTestService(resolver: container, events: data, runtime: runtime)
    return SettingsTestHarness(service: service, settings: settings, storage: storage, notifier: notifier)
}
