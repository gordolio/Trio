import Combine
import CoreData
import Foundation
import Swinject

/// One test kind's lifecycle, run in `SettingsTestService` from Begin to a prepared result, with nothing waiting for the
/// test's screen. The service holds one per kind (`SettingsTestRuntime.makeRunners`) and checks the running ones on its
/// watchdog, on Core Data changes and at launch.
protocol SettingsTestRunner: AnyObject {
    var kind: SettingsTestKind { get }
    /// Past Begin and not yet at its prepared result. Thread-safe (read from the runner's subject), and it must not call
    /// back into the service: the service reads it while it holds the watchdog's lock.
    var isRunning: Bool { get }
    /// Coalesced: one runs at a time; a call during one waits for it and one more run.
    func check() async
}

/// How a runner's `check()` is coalesced: one run at a time, and a call made during one waits for it and for one more
/// run, shared by every call made meanwhile, so a change that came in after the reads started is never missed. Each
/// runner holds one and passes its check as `body`.
final class SettingsTestCheckCoalescer {
    /// Whether a run is going, whether another was asked for meanwhile, and who waits for that one.
    private struct Round {
        var running = false
        var again = false
        var waiting: [CheckedContinuation<Bool, Never>] = []
    }

    private var round = Round()
    private let lock = NSLock()

    /// Runs `body`, or, while a run is going, waits for it and for the one more run it then makes. The lock is held only
    /// around the round's bookkeeping, never across `body`.
    func run(_ body: () async -> Void) async {
        let leads = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let startsOne = lock.withLock { () -> Bool in
                guard round.running else {
                    round.running = true
                    return true
                }
                round.again = true
                round.waiting.append(continuation)
                return false
            }
            if startsOne { continuation.resume(returning: true) }
        }
        guard leads else { return }
        var done: [CheckedContinuation<Bool, Never>] = []
        while true {
            await body()
            done.forEach { $0.resume(returning: false) }
            let next = lock.withLock { () -> [CheckedContinuation<Bool, Never>]? in
                guard round.again else {
                    round.running = false
                    return nil
                }
                let waiting = round.waiting
                round.again = false
                round.waiting = []
                return waiting
            }
            guard let next else { return }
            done = next
        }
    }

    /// How many calls wait for the run going now and the one after it. Internal, for tests.
    var waiting: Int {
        lock.withLock { round.waiting.count }
    }
}

/// A check started in the background that no caller waits for, coalesced: one run at a time, and a request made during
/// one asks for one more run once it is done, shared by every request made meanwhile, so a change that came in after the
/// reads started is never missed. A request never waits, so a run that never returns holds up only this check's later
/// runs, and costs one waiting task however many requests come in. The service holds one for its own checks and one per
/// runner (`SettingsTestService.checkSession`). The lock is held only around the bookkeeping, never across a run.
final class SettingsTestBackgroundCheck {
    /// The task making the runs while one is going, and whether another run was asked for meanwhile.
    private var running: Task<Void, Never>?
    private var again = false
    private let lock = NSLock()

    /// Starts `body` in a task, or, while one is going, asks it for one more run. Each holder passes the same `body`
    /// every time: a run going on repeats the one it started with. Returns the task that makes the run this request asked
    /// for, so a test can wait for it; the app never does.
    @discardableResult func request(_ body: @escaping () async -> Void) -> Task<Void, Never> {
        lock.withLock {
            if let running {
                again = true
                return running
            }
            let task = Task { await self.runUntilDone(body) }
            running = task
            return task
        }
    }

    private func runUntilDone(_ body: () async -> Void) async {
        while true {
            await body()
            let more = lock.withLock { () -> Bool in
                guard again else {
                    running = nil
                    return false
                }
                again = false
                return true
            }
            guard more else { return }
        }
    }
}

/// What the service hands its runners: itself, and the storage and settings manager it was injected with, so a runner
/// restores and saves through the same instances the service does (in tests, the same fakes).
struct SettingsTestRunnerContext {
    /// Runners hold it weak.
    let service: SettingsTestService
    let storage: FileStorage
    let settingsManager: SettingsManager
}

/// What the service runs its tests with: how its runners are built, and what asks it to check them.
struct SettingsTestRuntime {
    var makeRunners: (SettingsTestRunnerContext) -> [SettingsTestRunner]
    /// Each emission asks for a check, once `triggerDebounce` has passed without another.
    var checkTriggers: AnyPublisher<Void, Never>
    var triggerDebounce: DispatchQueue.SchedulerTimeType.Stride = .seconds(2)

    /// The app's own runtime: the basal and ISF runners, posting through one notifier and reading through their screens'
    /// providers, and a check on every change of the data a running test reads. The providers resolve only data services
    /// that never resolve this one, and build nothing but Core Data contexts, so the service's init stays light.
    static func app(resolver: Resolver) -> SettingsTestRuntime {
        SettingsTestRuntime(
            makeRunners: { context in
                let notifier = SettingsTestNotifier()
                return [
                    BasalTestRunner(
                        service: context.service,
                        reads: BasalTest.Provider(resolver: resolver),
                        storage: context.storage,
                        settingsManager: context.settingsManager,
                        notifier: notifier
                    ),
                    ISFTestRunner(
                        service: context.service,
                        reads: ISFTest.Provider(resolver: resolver),
                        storage: context.storage,
                        settingsManager: context.settingsManager,
                        notifier: notifier
                    )
                ]
            },
            checkTriggers: CoreDataStack.shared.entityChangePublisher
                .filter { ids in triggersCheck(entityNames: ids.map(\.entity.name)) }
                .map { _ in () }
                .eraseToAnyPublisher()
        )
    }

    /// No runners and nothing that triggers a check: for tests that don't exercise them.
    static let inert = SettingsTestRuntime(
        makeRunners: { _ in [] },
        checkTriggers: Empty(completeImmediately: false).eraseToAnyPublisher()
    )

    /// The Core Data entities whose changes trigger a check: the glucose, determinations, pump history and carbs that
    /// the service's low, carbs and bolus checks and the runners read.
    static let triggerEntities: Set<String> = ["GlucoseStored", "OrefDetermination", "PumpEventStored", "CarbEntryStored"]

    /// Whether a change to objects of these entities triggers a check: one of them is in `triggerEntities`.
    static func triggersCheck(entityNames: [String?]) -> Bool {
        entityNames.contains { name in name.map(triggerEntities.contains) ?? false }
    }
}

/// Why a test can't begin, with the sentence its screen shows.
enum SettingsTestBeginError: Error, Equatable {
    case otherTestRunning
    /// Basal Testing is already on, so it would be kept as the usual mode and nothing would ever turn it off.
    case basalTestingOn
    case settingsUnreadable
    /// What Begin keeps couldn't be read (the carb entries there at Begin), with the error's description.
    case dataUnreadable(String)
    /// The test or its session didn't save, so a relaunch would find no way back from Basal Testing.
    case notSaved
    /// A basal fast: carbs Begin read are dated under the docs' 2 hours before it (`BasalTest.Config.fastBeforeStart`),
    /// logged after the Check screen last read them. `readyAt` is 2 hours after the newest.
    case recentCarbs(readyAt: Date)
    /// An ISF test that starts by raising glucose with tablets, with no carb ratio to count them from.
    case carbRatioUnreadable
    /// An override or a temp target is running, started after the Check screen last read them: both change basal and
    /// sensitivity, so the test wouldn't show what the settings do on their own.
    case adjustmentActive

    var message: String {
        switch self {
        case .otherTestRunning:
            return String(localized: "Another settings test is running. Finish it first.")
        case .basalTestingOn:
            // The Check screen's mode check says the same.
            return String(localized: "Switch to your usual dosing mode first, so Trio can return you to it")
        case .settingsUnreadable:
            return String(localized: "Trio couldn't read your ISF and glucose target. Check them, then try again.")
        case let .dataUnreadable(description):
            // What the test screens say when their own reads fail.
            return "Couldn't read your data: \(description)"
        case .notSaved:
            // Trio's own words for a change it couldn't save (`AdjustmentManager`).
            return String(localized: "Could not save the change.")
        case let .recentCarbs(readyAt):
            // The Check screen's food row says the same.
            let ready = readyAt.formatted(date: .omitted, time: .shortened)
            return String(localized: "Ready at \(ready) (2 h after your last carbs)")
        case .carbRatioUnreadable:
            // The Raise step's words for it.
            return String(localized: "Trio couldn't read your carb ratio, so it can't count the tablets.")
        case .adjustmentActive:
            return String(localized: "An override or temp target is running. End it first, then try again.")
        }
    }
}
