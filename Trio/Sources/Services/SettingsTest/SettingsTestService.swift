import Combine
import CoreData
import Foundation
import Swinject
import UserNotifications

private enum SettingsTestStorage {
    static let sessionPath = "trio/settings_test_session.json"
    static let historyPath = "trio/settings_test_history.json"
    static let lastEndPath = "trio/settings_test_last_end.json"
    static let maxHistory = 200
    static let expiryNotificationID = "Trio.settingsTestExpired"
}

/// Keeps track of a running settings test and makes sure anything it changed is put back.
protocol SettingsTestService: AnyObject {
    var activeSession: SettingsTestSession? { get }
    var sessionPublisher: AnyPublisher<SettingsTestSession?, Never> { get }

    /// Starts a session. Call this *before* making the temporary change, so there is a way back
    /// the moment the change takes effect. Restore actions only apply if the change is in effect.
    /// Returns nil, changing nothing, while another session is running: its way back must not be overwritten.
    /// `settles` marks an ISF session that settles before its bolus window starts (`setBolusWindowStart`).
    /// `carbsAtBegin` are the carb entries Begin kept (`SettingsTestCarbRule.keptAtBegin`), nil for none.
    @discardableResult func begin(
        kind: SettingsTestKind,
        expiresIn: TimeInterval,
        restoring: [SettingsTestRestoreAction],
        settles: Bool,
        carbsAtBegin: [String]?
    ) -> SettingsTestSession?

    /// The session as saved, read back from disk: what a relaunch would find. Nil when none is.
    func savedSession() -> SettingsTestSession?

    /// Puts everything back and clears the session, if the one running is of this kind. A test ends only its own
    /// session, so it can never undo another test's change.
    func end(kind: SettingsTestKind)

    /// Ends the session if it ran past its deadline. Safe to call at any time.
    func endIfExpired()

    /// Keeps when the running session's bolus window began, if the one running is of this kind: for an ISF test, the
    /// end of its settling, from which the watchdog looks for the test bolus. Persisted with the session. The session
    /// then lasts at least until the latest its test can end from there, the time for the bolus, the docs' 4 hours and
    /// the grace after them, so a late end of settling can't have it expire before the 4 hours are up. Never shorter.
    func setBolusWindowStart(kind: SettingsTestKind, at date: Date)

    /// The last session the service ended on its own, for a low, for carbs logged or unreadable, for basal stopped
    /// without Trio asking, or for an ISF test's second bolus or no bolus, and why. Kept until the next one.
    func lastEnd() -> SettingsTestEnd?

    func archive(_ record: SettingsTestRecord)
    func history(for kind: SettingsTestKind?) -> [SettingsTestRecord]

    /// The runner that runs tests of this kind, or nil while it has none.
    func runner(for kind: SettingsTestKind) -> SettingsTestRunner?
}

extension SettingsTestService {
    /// A session that doesn't settle, with no carb entries kept.
    @discardableResult func begin(
        kind: SettingsTestKind,
        expiresIn: TimeInterval,
        restoring: [SettingsTestRestoreAction]
    ) -> SettingsTestSession? {
        begin(kind: kind, expiresIn: expiresIn, restoring: restoring, settles: false, carbsAtBegin: nil)
    }

    /// A session with no carb entries kept.
    @discardableResult func begin(
        kind: SettingsTestKind,
        expiresIn: TimeInterval,
        restoring: [SettingsTestRestoreAction],
        settles: Bool
    ) -> SettingsTestSession? {
        begin(kind: kind, expiresIn: expiresIn, restoring: restoring, settles: settles, carbsAtBegin: nil)
    }
}

/// What is read to watch a running test, by the service and, through their providers, by the runners. A protocol so
/// tests can stand in for Core Data.
protocol SettingsTestEvents {
    /// Temp basals the pump started in the window, oldest first. Scheduled basal, which pumps also report as a temp,
    /// is left out: it is the basal being tested, not a change to it, and a 0 U/h entry is no suspend.
    func tempBasals(from start: Date, to end: Date) async throws -> [BasalTestTempBasal]
    /// When Trio's determinations in the window asked for a zero temp basal with time on it, oldest first. A
    /// determination is dated by when it was due, or when it was made if that is missing. The pump history doesn't say
    /// who set a temp, so these are what tell Trio's suspend from a zero temp set on the pump.
    func zeroTempDeterminations(from start: Date, to end: Date) async throws -> [Date]
    /// The carb entries dated in the window, oldest first: carbs above 0, fat and protein's carb equivalents among them.
    func carbEntries(from start: Date, to end: Date) async throws -> [SettingsTestCarbEntry]
    /// Every bolus in the window, oldest first, from any source (Treatments, the pump or the Watch), manual or flagged as
    /// an SMB: an ISF test runs in Basal Testing, which gives no SMBs, and the pump history can flag a manual bolus as an
    /// SMB when it writes the amount delivered, so the flag can't tell the test's boluses apart. A bolus recorded at 0 U,
    /// cancelled before anything was delivered, is left out.
    func allBoluses(from start: Date, to end: Date) async throws -> [ISFTestBolus]
    /// When the pump was suspended or resumed, gave an alarm (an occlusion among them), or had its site, reservoir or
    /// pod changed (a rewind, a prime, a site change) in the window, oldest first: the pump history rows upstream
    /// records for them (`PumpEventStored.EventType`). Any of them means basal or a bolus may not have gone in as
    /// recorded.
    func pumpInterruptions(from start: Date, to end: Date) async throws -> [Date]
}

extension SettingsTestEvents {
    /// Whether basal was stopped from `start` to `end` inclusive, and if it was, whether Trio asked for it. Trio's
    /// determinations are read a little either side of the window, so one that asked for a zero temp at its edge counts.
    func suspendReading(from start: Date, to end: Date) async throws -> BasalTestEvaluator.SuspendReading {
        let temps = try await tempBasals(from: start, to: end)
        // Without a zero temp there is no one to ask about, so a failed read of the determinations can't leave a fast
        // with no suspend unchecked.
        guard BasalTestEvaluator.firstSuspend(temps, since: start, until: end) != nil else { return .none }
        let determinations = try await zeroTempDeterminations(
            from: start.addingTimeInterval(-BasalTestEvaluator.zeroTempAskedBefore),
            to: end.addingTimeInterval(BasalTestEvaluator.zeroTempAskedAfter)
        )
        return BasalTestEvaluator.suspendReading(temps, zeroTempDeterminations: determinations, since: start, until: end)
    }

    /// The same for an ISF test begun at `startedAt`: a zero temp counts as Trio's low only when a determination from
    /// `ISFTest.Config.settleLoopMargin` after Begin asked for it, and one only Closed Loop asked for is settling's
    /// (`ISFTestEvaluator.suspendReading`).
    func isfSuspendReading(startedAt: Date, to end: Date) async throws -> BasalTestEvaluator.SuspendReading {
        let temps = try await tempBasals(from: startedAt, to: end)
        guard BasalTestEvaluator.firstSuspend(temps, since: startedAt, until: end) != nil else { return .none }
        let determinations = try await zeroTempDeterminations(
            from: startedAt.addingTimeInterval(-BasalTestEvaluator.zeroTempAskedBefore),
            to: end.addingTimeInterval(BasalTestEvaluator.zeroTempAskedAfter)
        )
        return ISFTestEvaluator.suspendReading(temps, zeroTempDeterminations: determinations, startedAt: startedAt, until: end)
    }
}

/// Reads them from Core Data.
final class CoreDataSettingsTestEvents: SettingsTestEvents {
    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    func tempBasals(from start: Date, to end: Date) async throws -> [BasalTestTempBasal] {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: PumpEventStored.self,
            onContext: context,
            predicate: NSPredicate(
                format: "tempBasal != nil AND tempBasal.isScheduledBasal == NO AND timestamp >= %@ AND timestamp <= %@",
                start as NSDate,
                end as NSDate
            ),
            key: "timestamp",
            ascending: true,
            relationshipKeyPathsForPrefetching: ["tempBasal"]
        )
        let context = context
        return await context.perform {
            ((results as? [PumpEventStored]) ?? []).compactMap { event in
                guard let date = event.timestamp, let temp = event.tempBasal, let rate = temp.rate else { return nil }
                return BasalTestTempBasal(date: date, rate: rate.decimalValue, minutes: Int(temp.duration))
            }
        }
    }

    func zeroTempDeterminations(from start: Date, to end: Date) async throws -> [Date] {
        let due = NSPredicate(format: "deliverAt >= %@ AND deliverAt <= %@", start as NSDate, end as NSDate)
        let made = NSPredicate(
            format: "deliverAt == nil AND timestamp >= %@ AND timestamp <= %@",
            start as NSDate,
            end as NSDate
        )
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: OrefDetermination.self,
            onContext: context,
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "rate == 0 AND duration > 0"),
                NSCompoundPredicate(orPredicateWithSubpredicates: [due, made])
            ]),
            key: "deliverAt",
            ascending: true,
            propertiesToFetch: ["deliverAt", "timestamp"]
        )
        return ((results as? [[String: Any]]) ?? [])
            .compactMap { row in (row["deliverAt"] as? Date) ?? (row["timestamp"] as? Date) }
            .sorted()
    }

    func carbEntries(from start: Date, to end: Date) async throws -> [SettingsTestCarbEntry] {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: CarbEntryStored.self,
            onContext: context,
            predicate: NSPredicate(format: "carbs > 0 AND date >= %@ AND date <= %@", start as NSDate, end as NSDate),
            key: "date",
            ascending: true
        )
        let context = context
        return await context.perform {
            ((results as? [CarbEntryStored]) ?? []).compactMap { entry in
                guard let date = entry.date else { return nil }
                // A fetched entry's object ID is its permanent one, the same in every context and after a relaunch.
                return SettingsTestCarbEntry(id: entry.objectID.uriRepresentation().absoluteString, date: date)
            }
        }
    }

    func allBoluses(from start: Date, to end: Date) async throws -> [ISFTestBolus] {
        // One recorded at 0 U (cancelled before anything was delivered) is dropped; one with no amount isn't.
        try await bolusRecords(from: start, to: end).compactMap { ISFTestBolus(date: $0.date, amount: $0.amount) }
    }

    /// The pump history types upstream stores for a suspend or resume, an alarm, and a site, reservoir or pod change
    /// (`PumpEventType.storedEventType`).
    static let pumpInterruptionTypes: [PumpEventStored.EventType] = [
        .pumpSuspend, .pumpResume, .pumpAlarm, .rewind, .prime, .siteChange
    ]

    func pumpInterruptions(from start: Date, to end: Date) async throws -> [Date] {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: PumpEventStored.self,
            onContext: context,
            predicate: NSPredicate(
                format: "type IN %@ AND timestamp >= %@ AND timestamp <= %@",
                Self.pumpInterruptionTypes.map(\.rawValue),
                start as NSDate,
                end as NSDate
            ),
            key: "timestamp",
            ascending: true
        )
        let context = context
        return await context.perform {
            ((results as? [PumpEventStored]) ?? []).compactMap(\.timestamp).sorted()
        }
    }

    /// Trio's determinations in the window, oldest first, each dated by when it was due, or when it was made if that is
    /// missing, with the insulin on board it held: what the ISF test's settling and its count of insulin on board at the
    /// bolus read. Not in `SettingsTestEvents`, because the watchdog doesn't use it.
    func determinations(from start: Date, to end: Date) async throws -> [ISFTestDetermination] {
        let due = NSPredicate(format: "deliverAt >= %@ AND deliverAt <= %@", start as NSDate, end as NSDate)
        let made = NSPredicate(
            format: "deliverAt == nil AND timestamp >= %@ AND timestamp <= %@",
            start as NSDate,
            end as NSDate
        )
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: OrefDetermination.self,
            onContext: context,
            predicate: NSCompoundPredicate(orPredicateWithSubpredicates: [due, made]),
            key: "deliverAt",
            ascending: true,
            propertiesToFetch: ["deliverAt", "timestamp", "iob", "cob"]
        )
        return ((results as? [[String: Any]]) ?? [])
            .compactMap { row in
                guard let date = (row["deliverAt"] as? Date) ?? (row["timestamp"] as? Date) else { return nil }
                return ISFTestDetermination(
                    date: date,
                    iob: (row["iob"] as? NSDecimalNumber)?.decimalValue,
                    cob: (row["cob"] as? NSNumber).map { Decimal($0.intValue) }
                )
            }
            .sorted { $0.date < $1.date }
    }

    /// The CGM readings dated from `start` to `end` inclusive, oldest first: what the basal and ISF tests read glucose
    /// from. A manual BG entry or a CGM calibration (`isManual`) is no CGM reading, has no arrow, and can sit 15 mg/dL off
    /// the CGM, so it is left out of this and every other glucose read of the tests'. Not in `SettingsTestEvents`, because
    /// the watchdog doesn't use it.
    func glucose(from start: Date, to end: Date) async throws -> [BasalTestReading] {
        try await glucose(
            matching: NSPredicate(format: "date >= %@ AND date <= %@", start as NSDate, end as NSDate),
            ascending: true
        )
    }

    /// The CGM readings dated after `cutoff`, newest first.
    func recentGlucose(since cutoff: Date) async throws -> [BasalTestReading] {
        try await glucose(matching: NSPredicate(format: "date > %@", cutoff as NSDate), ascending: false)
    }

    /// CGM rows only: no manual BG entry or calibration (`glucose(from:to:)`).
    private static let cgmOnly = NSPredicate(format: "isManual == NO")

    private func glucose(matching predicate: NSPredicate, ascending: Bool) async throws -> [BasalTestReading] {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [Self.cgmOnly, predicate]),
            key: "date",
            ascending: ascending
        )
        let context = context
        return await context.perform {
            ((results as? [GlucoseStored]) ?? []).compactMap { stored in
                guard let date = stored.date else { return nil }
                return BasalTestReading(date: date, glucose: Int(stored.glucose), direction: stored.directionEnum)
            }
        }
    }

    /// The CGM's own arrow on the newest CGM reading dated after `cutoff`. Nil when there is none, or it gave none.
    func newestDirection(since cutoff: Date) async throws -> BloodGlucose.Direction? {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                Self.cgmOnly,
                NSPredicate(format: "date > %@", cutoff as NSDate)
            ]),
            key: "date",
            ascending: false,
            fetchLimit: 1
        )
        let context = context
        return await context.perform { (results as? [GlucoseStored])?.first?.directionEnum }
    }

    /// The newest CGM reading from `earliest` to `date` inclusive, with the CGM's own arrow for it: what the ISF test
    /// reads the arrow at its bolus from. Nil when there is none. A manual entry or calibration is left out
    /// (`glucose(from:to:)`). Not in `SettingsTestEvents`, because the watchdog doesn't use it.
    func arrowReading(atOrBefore date: Date, since earliest: Date) async throws -> ISFTestArrowReading? {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                Self.cgmOnly,
                NSPredicate(format: "date >= %@ AND date <= %@", earliest as NSDate, date as NSDate)
            ]),
            key: "date",
            ascending: false,
            fetchLimit: 1
        )
        let context = context
        return await context.perform {
            guard let newest = (results as? [GlucoseStored])?.first, let readAt = newest.date else { return nil }
            return ISFTestArrowReading(date: readAt, direction: newest.directionEnum)
        }
    }

    /// Every bolus row in the window, oldest first, manual or flagged as an SMB, with its amount, 0 U included: what the
    /// ISF test reads the test bolus again from (`ISFTestBolusRecord`), and what `allBoluses` is read from. Not in
    /// `SettingsTestEvents`, because the watchdog doesn't use it.
    func bolusRecords(from start: Date, to end: Date) async throws -> [ISFTestBolusRecord] {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: PumpEventStored.self,
            onContext: context,
            predicate: NSPredicate(
                format: "bolus != nil AND timestamp >= %@ AND timestamp <= %@",
                start as NSDate,
                end as NSDate
            ),
            key: "timestamp",
            ascending: true,
            relationshipKeyPathsForPrefetching: ["bolus"]
        )
        let context = context
        return await context.perform {
            ((results as? [PumpEventStored]) ?? []).compactMap { event in
                guard let date = event.timestamp, let bolus = event.bolus else { return nil }
                // A bolus being delivered is stored with the amount programmed and written again, from another context,
                // with the amount delivered. Refreshed, so a copy this context already holds can't keep the first amount.
                context.refresh(bolus, mergeChanges: true)
                return ISFTestBolusRecord(date: date, amount: bolus.amount?.decimalValue)
            }
        }
    }
}

final class BaseSettingsTestService: SettingsTestService, Injectable {
    @Injected() private var storage: FileStorage!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var broadcaster: Broadcaster!

    private let sessionSubject = CurrentValueSubject<SettingsTestSession?, Never>(nil)
    private var watchdog: AnyCancellable?
    private let watchdogLock = NSLock()
    private let lock = NSLock()
    /// One per test kind that runs in the service, built by the runtime at init.
    private(set) var runners: [SettingsTestRunner] = []
    private var triggerSubscription: AnyCancellable?
    /// The service's own checks, one at a time (`checkSessionInBackground`).
    private let ownChecks = SettingsTestBackgroundCheck()
    /// Each runner's checks the service starts, one at a time per runner, by the runner's identity (`checkSession`).
    /// Built at init with the runners, and not changed after.
    private var runnerChecks: [ObjectIdentifier: SettingsTestBackgroundCheck] = [:]
    /// While the service puts a session's changes back, so its own change of mode isn't taken for the user's.
    private var restoring = false

    var activeSession: SettingsTestSession? { sessionSubject.value }
    var sessionPublisher: AnyPublisher<SettingsTestSession?, Never> { sessionSubject.eraseToAnyPublisher() }

    /// What the watchdog reads to end a basal or ISF test on a low, basal stopped, carbs, or a second bolus or none.
    private let events: SettingsTestEvents

    /// `events` and `runtime` are for tests; the app reads Core Data and builds the runtime itself.
    init(resolver: Resolver, events: SettingsTestEvents? = nil, runtime: SettingsTestRuntime? = nil) {
        self.events = events ?? CoreDataSettingsTestEvents(context: CoreDataStack.shared.newTaskContext())
        let runtime = runtime ?? .app(resolver: resolver)
        injectServices(resolver)
        broadcaster.register(SettingsObserver.self, observer: self)
        runners = runtime.makeRunners(
            SettingsTestRunnerContext(service: self, storage: storage, settingsManager: settingsManager)
        )
        runnerChecks = Dictionary(uniqueKeysWithValues: runners.map { (ObjectIdentifier($0), SettingsTestBackgroundCheck()) })

        // A session left over from a previous launch is either still running or past its deadline. Either way it is
        // checked for a low first, so one that ran past its deadline while the app was closed keeps the low it had. A
        // runner that loaded a test it is still running is checked too.
        let existing = storage.retrieve(SettingsTestStorage.sessionPath, as: SettingsTestSession.self)
        if let existing {
            sessionSubject.send(existing)
        }
        if existing != nil || runners.contains(where: \.isRunning) {
            startWatchdog()
            checkSessionInBackground()
        }

        // A change to what a running test reads is checked soon, not at the next tick of the watchdog.
        triggerSubscription = runtime.checkTriggers
            .debounce(for: runtime.triggerDebounce, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, isWatching else { return }
                watchdogTick()
            }
    }

    func runner(for kind: SettingsTestKind) -> SettingsTestRunner? {
        runners.first { $0.kind == kind }
    }

    /// Whether the watchdog's timer runs, which it does while a session or a runner is running.
    var isWatching: Bool {
        watchdogLock.withLock { watchdog != nil }
    }

    @discardableResult func begin(
        kind: SettingsTestKind,
        expiresIn: TimeInterval,
        restoring: [SettingsTestRestoreAction],
        settles: Bool,
        carbsAtBegin: [String]?
    ) -> SettingsTestSession? {
        guard activeSession == nil else { return nil }
        let session = SettingsTestSession(
            kind: kind,
            expiresAt: Date().addingTimeInterval(expiresIn),
            restore: restoring,
            settles: settles ? true : nil,
            carbsAtBegin: carbsAtBegin
        )
        storage.save(session, as: SettingsTestStorage.sessionPath)
        sessionSubject.send(session)
        scheduleExpiryNotification(at: session.expiresAt, kind: kind)
        startWatchdog()
        return session
    }

    func savedSession() -> SettingsTestSession? {
        storage.retrieve(SettingsTestStorage.sessionPath, as: SettingsTestSession.self)
    }

    func end(kind: SettingsTestKind) {
        guard let session = activeSession, session.kind == kind else { return }
        end(session)
    }

    func endIfExpired() {
        guard let session = activeSession, session.expiresAt <= Date() else { return }
        debug(.settings, "SettingsTest: \(session.kind.rawValue) test expired, restoring settings")
        // Another mode was picked during it: kept as why, with whether the end puts the usual mode back.
        if let leftAt = session.leftTestModeAt {
            storage.save(modeChangedEnd(of: session, at: leftAt), as: SettingsTestStorage.lastEndPath)
        }
        end(session)
    }

    /// The record of a session ended because another mode was picked at `leftAt`, saying whether its end puts the usual
    /// mode back with the mode in force now (`SettingsTestRestoreAction.modeToRestore`), so the runner can say so.
    private func modeChangedEnd(of session: SettingsTestSession, at leftAt: Date) -> SettingsTestEnd {
        let mode = settingsManager.settings.dosingMode
        return SettingsTestEnd(
            sessionID: session.id,
            cause: .modeChanged,
            date: leftAt,
            modeRestored: session.restore.contains { $0.modeToRestore(current: mode) != nil }
        )
    }

    func setBolusWindowStart(kind: SettingsTestKind, at date: Date) {
        guard var session = activeSession, session.kind == kind else { return }
        session.bolusWindowStart = date
        let latestEnd = date.addingTimeInterval(
            ISFTest.Config.doseAllowance + ISFTest.Config.docsWait + ISFTest.Config.expiryGrace
        )
        let extended = latestEnd > session.expiresAt
        if extended {
            session.expiresAt = latestEnd
        }
        storage.save(session, as: SettingsTestStorage.sessionPath)
        sessionSubject.send(session)
        if extended {
            // The same identifier, so this replaces the one scheduled at the start.
            scheduleExpiryNotification(at: latestEnd, kind: kind)
        }
    }

    /// Ends a running test in Basal Testing when something spoiled it, since it began: Trio suspended insulin for a low
    /// (any test), carbs were logged (a basal or an ISF test), or, for an ISF test only, a second bolus was
    /// given after its own, or none came in the time allowed for one. Those are the things the test screens say end the
    /// test. The watchdog calls this, so any one of them brings the usual dosing back at once, before the test's runner
    /// finishes it. Basal stopped without Trio asking, by a zero temp set on the pump, ends it too: the test is spoiled,
    /// and it isn't kept as a low. So do carbs that can't be read, in a basal or an ISF test: Basal Testing gives no
    /// insulin for food, so it mustn't stay on unchecked. Why and when is kept (`lastEnd()`), so the runner finishes the
    /// result for the same reason, with the usual mode already back. A second bolus is dated at that bolus, and no bolus
    /// at the end of the time allowed, so the runner can tell whether they came before the planned end. A suspend is
    /// looked for first, then carbs, then boluses; a suspend that can't be read doesn't stop the others being
    /// read, and boluses that can't be read leave the test running. Only a session that switched to Basal Testing: a
    /// mode the user picked since is theirs, unless Basal Testing suspended for a low before the change
    /// (`noteTestModeLeft`). That low is still this test's. Without one, the session ends as a mode change
    /// (`modeChanged`, dated at the change), so the runner reads it as an interrupted test. Either way the end puts the
    /// usual mode back only if Basal Testing is on again by then (`SettingsTestRestoreAction.modeToRestore`). The pump
    /// suspended, alarmed or changed since Begin ends a basal or an ISF test too (`pumpInterrupted`), after a low and
    /// before carbs. Carbs are those dated from Begin on, and those dated in the day before it that weren't there at Begin
    /// (`SettingsTestCarbRule`).
    ///
    /// An ISF test whose 4 hours from its bolus, and the grace after them, are over is ended too, with no reason kept,
    /// as on expiry: nothing spoiled it, so the runner finishes it as completed. Its session lasts until the latest the 4
    /// hours could end, so without this Basal Testing could stay on for up to the time allowed for the bolus after a test
    /// that had run its course.
    func endIfLowOrInterrupted() async {
        guard let session = activeSession, session.restore.contains(where: \.switchesToBasalTesting) else { return }
        let watching = session.leftTestModeAt == nil
        guard !watching || settingsManager.settings.dosingMode == .basalTesting else { return }
        let now = Date()
        // Once another mode was picked, only what happened before then is Basal Testing's.
        let until = session.leftTestModeAt.map { min($0, now) } ?? now
        let suspend: BasalTestEvaluator.SuspendReading
        do {
            // An ISF test settles first, so a zero temp only Closed Loop asked for as it began isn't its low.
            suspend = session.kind == .isf
                ? try await events.isfSuspendReading(startedAt: session.startedAt, to: until)
                : try await events.suspendReading(from: session.startedAt, to: until)
        } catch {
            // Carbs are still read: Basal Testing gives no insulin for food, so carbs must end it even then. So are an ISF
            // test's boluses, so a second one or none still brings the usual dosing back.
            warning(.settings, "SettingsTest: couldn't read temp basals to watch the \(session.kind.rawValue) test", error: error)
            suspend = .unreadable
        }
        // Nil ends the session with no reason kept.
        let ending: SettingsTestEnd?
        if case let .suspended(suspendedAt) = suspend {
            debug(.settings, "SettingsTest: Trio suspended for a low, ending the \(session.kind.rawValue) test")
            ending = SettingsTestEnd(sessionID: session.id, cause: .low, date: suspendedAt)
        } else if let leftAt = session.leftTestModeAt {
            // A low before the change can't be ruled out yet; the next check reads again, and expiry still ends it.
            guard suspend != .unreadable else { return }
            // Whether the end puts the usual mode back is worked out as it ends, on the main actor below.
            debug(.settings, "SettingsTest: the mode was changed during the \(session.kind.rawValue) test, ending it")
            ending = SettingsTestEnd(sessionID: session.id, cause: .modeChanged, date: leftAt)
        } else if case let .unexplained(stoppedAt) = suspend {
            debug(.settings, "SettingsTest: basal was stopped without Trio asking, ending the \(session.kind.rawValue) test")
            ending = SettingsTestEnd(sessionID: session.id, cause: .basalStopped, date: stoppedAt)
        } else if let interruptedAt = await pumpInterruption(of: session, until: now) {
            debug(.settings, "SettingsTest: the pump was suspended, alarmed or changed, ending the \(session.kind.rawValue) test")
            ending = SettingsTestEnd(sessionID: session.id, cause: .pumpInterrupted, date: interruptedAt)
        } else if session.kind == .basal || session.kind == .isf, let cause = await carbsEnding(of: session, until: now) {
            // Only the basal and ISF tests tell the user that logging carbs ends them.
            debug(.settings, "SettingsTest: \(cause.rawValue), ending the \(session.kind.rawValue) test")
            ending = SettingsTestEnd(sessionID: session.id, cause: cause, date: now)
        } else if session.kind == .isf, let bolusCheck = await isfBolusCheck(for: session, now: now) {
            switch bolusCheck {
            case let .spoiled(bolusEnd): ending = bolusEnd
            case .waitOver: ending = nil
            }
        } else {
            return
        }
        await MainActor.run {
            // The reads above took time: the session may have ended, or its bolus window started, since it was copied,
            // and what they found was decided on the copy. The next check decides on the session as it is.
            guard Self.isUnchanged(session, live: activeSession) else { return }
            // Kept before the usual mode comes back, so the runner never finds the mode changed without the reason.
            if let ending {
                let kept = ending.cause == .modeChanged ? modeChangedEnd(of: session, at: ending.date) : ending
                storage.save(kept, as: SettingsTestStorage.lastEndPath)
            }
            end(session)
        }
    }

    /// Whether the session a check copied before its reads is still the one running, with the same bolus window start,
    /// so what the check found from the copy still holds.
    static func isUnchanged(_ copy: SettingsTestSession, live: SettingsTestSession?) -> Bool {
        guard let live else { return false }
        return live.id == copy.id && live.bolusWindowStart == copy.bolusWindowStart
    }

    /// When the pump was first suspended, alarmed or changed since `session` began (`pumpInterruptions`). Nil when it
    /// wasn't, and when the pump history can't be read: the runner's own check then can't rule it out and gives no
    /// verdict, and the session's expiry still brings the usual dosing back.
    private func pumpInterruption(of session: SettingsTestSession, until end: Date) async -> Date? {
        do {
            return try await events.pumpInterruptions(from: session.startedAt, to: end).first
        } catch {
            warning(
                .settings,
                "SettingsTest: couldn't read the pump history to watch the \(session.kind.rawValue) test",
                error: error
            )
            return nil
        }
    }

    /// What carbs say about `session`: they end it if any were logged that spoil it (`SettingsTestCarbRule.spoil`), from
    /// Begin on or dated before it and logged since, and also if they can't be read, so the usual dosing comes back. Nil
    /// to keep going.
    private func carbsEnding(of session: SettingsTestSession, until end: Date) async -> SettingsTestEndCause? {
        do {
            let entries = try await events.carbEntries(
                from: SettingsTestCarbRule.readFrom(startedAt: session.startedAt, kept: session.carbsAtBegin),
                to: end
            )
            return SettingsTestCarbRule.spoil(entries, startedAt: session.startedAt, kept: session.carbsAtBegin)
                ? .carbsLogged
                : nil
        } catch {
            warning(.settings, "SettingsTest: couldn't read carbs to watch the \(session.kind.rawValue) test", error: error)
            return .carbsUnreadable
        }
    }

    /// What the boluses say ends a running ISF test.
    private enum ISFBolusCheck {
        /// Something spoiled it, kept for the runner.
        case spoiled(SettingsTestEnd)
        /// The 4 hours from its bolus and the grace after them are over, and nothing spoiled it.
        case waitOver
    }

    /// What the boluses end an ISF test for, if they do. While it settles (no `bolusWindowStartInEffect`: a session that
    /// settles, with no window start kept yet; one from before settling was kept starts it at Start) there is no test
    /// bolus to come after, and an SMB from the mode before landing then is no second one, so only the latest a bolus
    /// window could close, Start plus the time for settling and the dose, ends it for no bolus, dated then. Once the
    /// window has begun: a second bolus from its start on (`allBoluses`, whatever its SMB flag), dated at that bolus,
    /// or, once the time allowed for the test's bolus has run out, none in that time, dated at the deadline. The first
    /// bolus is the test's own; a second one spoils the drop the test measures per unit. Then, with nothing spoiled, the
    /// end of the 4 hours from the test's bolus and the grace after them. Nil to keep going, also when the boluses can't
    /// be read: no bolus can't be told from one not seen, and the session's expiry still brings the usual dosing back.
    private func isfBolusCheck(for session: SettingsTestSession, now: Date) async -> ISFBolusCheck? {
        guard let windowStart = session.bolusWindowStartInEffect else {
            let deadline = session.startedAt.addingTimeInterval(ISFTest.Config.settleAllowance + ISFTest.Config.doseAllowance)
            guard now >= deadline else { return nil }
            debug(.settings, "SettingsTest: the \(session.kind.rawValue) test never settled, ending it for no bolus")
            return .spoiled(SettingsTestEnd(sessionID: session.id, cause: .noBolus, date: deadline))
        }
        let boluses: [ISFTestBolus]
        do {
            // From the window's start, exact: a bolus before it was given while the test settled.
            boluses = try await events.allBoluses(from: windowStart, to: now)
        } catch {
            warning(.settings, "SettingsTest: couldn't read boluses to watch the \(session.kind.rawValue) test", error: error)
            return nil
        }
        if let second = boluses.dropFirst().first {
            debug(.settings, "SettingsTest: a second bolus was given, ending the \(session.kind.rawValue) test")
            return .spoiled(SettingsTestEnd(sessionID: session.id, cause: .extraBolus, date: second.date))
        }
        let deadline = windowStart.addingTimeInterval(ISFTest.Config.doseAllowance)
        let testBolus = ISFTestEvaluator.testBolus(boluses, since: windowStart, deadline: deadline)
        // Left on until it expired, Basal Testing would run for hours with no test to show for it.
        if now >= deadline, testBolus == nil {
            debug(.settings, "SettingsTest: no bolus came in time, ending the \(session.kind.rawValue) test")
            return .spoiled(SettingsTestEnd(sessionID: session.id, cause: .noBolus, date: deadline))
        }
        if let testBolus, now >= testBolus.date.addingTimeInterval(ISFTest.Config.docsWait + ISFTest.Config.expiryGrace) {
            debug(.settings, "SettingsTest: the \(session.kind.rawValue) test's wait is over, restoring settings")
            return .waitOver
        }
        return nil
    }

    /// Notes when a session that switched to Basal Testing first finds another mode picked, so a low Basal Testing
    /// suspended for before then is still kept (`endIfLowOrInterrupted`). True if this was that change. Reads the mode
    /// in force, not the one a notification carried. The service's own restore isn't such a change: it ends the session.
    @discardableResult func noteTestModeLeft(at date: Date = Date()) -> Bool {
        guard !restoring, settingsManager.settings.dosingMode != .basalTesting,
              var session = activeSession, session.leftTestModeAt == nil,
              session.restore.contains(where: \.switchesToBasalTesting)
        else { return false }
        session.leftTestModeAt = date
        storage.save(session, as: SettingsTestStorage.sessionPath)
        sessionSubject.send(session)
        debug(.settings, "SettingsTest: Basal Testing was left during the \(session.kind.rawValue) test")
        return true
    }

    /// The service's own check, which each tick of the watchdog and each change of the data a test reads start after their
    /// own expiry check (`watchdogTick`), and which a session or a runner recovered at launch gets once: the low, carbs
    /// and bolus check first, then the expiry check, then a check of each runner that is running, started on its own,
    /// then the watchdog stops if nothing is running. In that order because a session past its deadline is ended whatever
    /// it finds, and ending it first would lose the low, which the runner would then report as an interrupted test; and a
    /// runner's check, started after them, reads the ending the service just kept (`lastEnd()`). The expiry check runs
    /// even when the history can't be read, so the usual mode always comes back. A tick starts the runners' checks before
    /// this one too (`watchdogTick`), so a read here that never returns can't stop them.
    ///
    /// Nothing here waits for a runner. A runner's check that never returned (a stuck Core Data read, say) would
    /// otherwise stop every later check of the service, its expiry restore among them, for as long as Trio ran. Each
    /// runner's checks are coalesced on their own (`SettingsTestBackgroundCheck`), so one that hangs holds up only that
    /// runner's later checks. Returns those checks, started here or asked here for one more run, so a test can wait for
    /// them; the service never does.
    @discardableResult func checkSession() async -> [Task<Void, Never>] {
        await endIfLowOrInterrupted()
        // Where the watchdog's timer ran it before, so the mode and the session are changed on the main actor.
        await MainActor.run { endIfExpired() }
        let started = runners.filter(\.isRunning).compactMap { checkInBackground($0) }
        await MainActor.run { stopWatchdogIfIdle() }
        return started
    }

    /// Starts `runner`'s check without waiting for it, or asks the one going for one more run. After each run the watchdog
    /// stops if nothing is running, as at the end of `checkSession`, since a runner's check is what finishes its test.
    /// Nil for a runner the service doesn't hold.
    @discardableResult private func checkInBackground(_ runner: SettingsTestRunner) -> Task<Void, Never>? {
        runnerChecks[ObjectIdentifier(runner)]?.request { [weak self, weak runner] in
            await runner?.check()
            await MainActor.run { self?.stopWatchdogIfIdle() }
        }
    }

    /// What each tick of the watchdog and each change of the data a test reads does, on the main thread: the expiry
    /// check first, then each running runner's check, then the service's own, without waiting for either
    /// (`checkSessionInBackground`). The expiry check needs only the session and the clock, so a read that never returns,
    /// the service's own among them, can't hold back the last-resort restore. The runners' checks start here on their
    /// own, not only after the service's reads, so a read of the service's that never returns can't stop them either; the
    /// service's check asks each for one more run once its reads are done, so a runner still reads the ending it kept.
    /// A session the coalesced checks end meanwhile is gone by the time either looks again, so running it twice ends
    /// nothing twice. Only at launch does the low come first (`init`). Internal, for tests.
    func watchdogTick() {
        endIfExpired()
        for runner in runners where runner.isRunning {
            checkInBackground(runner)
        }
        checkSessionInBackground()
    }

    /// Checks without waiting for it: one service check at a time, and a call made during one asks for one more run once
    /// it is done (`SettingsTestBackgroundCheck`), so a change that came in after the reads started is never missed. The
    /// check never waits for a runner, so every tick and trigger gets one. Internal, for tests.
    func checkSessionInBackground() {
        ownChecks.request { [weak self] in
            _ = await self?.checkSession()
        }
    }

    func lastEnd() -> SettingsTestEnd? {
        storage.retrieve(SettingsTestStorage.lastEndPath, as: SettingsTestEnd.self)
    }

    /// Puts back what `session` changed and clears it, if it is still the one running: the usual mode while Basal
    /// Testing is on, whether or not the user left it and picked it again; any other mode is the user's and stays
    /// (`SettingsTestRestoreAction.modeToRestore`).
    private func end(_ session: SettingsTestSession) {
        guard activeSession?.id == session.id else { return }
        restoring = true
        apply(session.restore)
        restoring = false
        storage.remove(SettingsTestStorage.sessionPath)
        sessionSubject.send(nil)
        // The watchdog goes on until its next check finds nothing running (`stopWatchdogIfIdle`): a runner may still be
        // finishing what the session's end started.
        cancelExpiryNotification()
    }

    // MARK: - Restore

    private func apply(_ actions: [SettingsTestRestoreAction]) {
        for action in actions {
            // Leave a mode the user picked themselves alone.
            guard let previous = action.modeToRestore(current: settingsManager.settings.dosingMode) else { continue }
            settingsManager.settings.dosingMode = previous
            debug(.settings, "SettingsTest: dosing mode restored to \(previous.rawValue)")
        }
    }

    private func startWatchdog() {
        let timer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.watchdogTick() }
        watchdogLock.withLock { watchdog = timer }
    }

    /// Stops the watchdog when no session and no runner is running, so it costs nothing between tests. Checked and
    /// cleared under the one lock: a session begun in between sends itself before `begin` starts its watchdog, which
    /// waits for this lock, so the new watchdog is never the one cleared.
    private func stopWatchdogIfIdle() {
        watchdogLock.withLock {
            guard activeSession == nil, !runners.contains(where: \.isRunning) else { return }
            watchdog = nil
        }
    }

    // MARK: - History

    func archive(_ record: SettingsTestRecord) {
        lock.lock()
        defer { lock.unlock() }
        var records = storage.retrieve(SettingsTestStorage.historyPath, as: [SettingsTestRecord].self) ?? []
        records.append(record)
        if records.count > SettingsTestStorage.maxHistory {
            records.removeFirst(records.count - SettingsTestStorage.maxHistory)
        }
        storage.save(records, as: SettingsTestStorage.historyPath)
    }

    func history(for kind: SettingsTestKind?) -> [SettingsTestRecord] {
        lock.lock()
        defer { lock.unlock() }
        let records = storage.retrieve(SettingsTestStorage.historyPath, as: [SettingsTestRecord].self) ?? []
        let filtered = kind.map { kind in records.filter { $0.kind == kind } } ?? records
        return filtered.sorted { $0.completedAt > $1.completedAt }
    }

    // MARK: - Notifications

    /// Fires if the app isn't opened before the deadline. The restore itself happens the next time
    /// Trio runs, so the text asks the user to open it.
    private func scheduleExpiryNotification(at date: Date, kind: SettingsTestKind) {
        let interval = max(1, date.timeIntervalSinceNow)
        let request = UNNotificationRequest(
            identifier: SettingsTestStorage.expiryNotificationID,
            content: Self.expiryContent(kind: kind),
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// The notification for a session that ran out of time with Trio not running. A tap opens the test's screen
    /// (`SettingsTestHooks`).
    static func expiryContent(kind: SettingsTestKind) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Test time is up")
        content.body = String(
            localized: "Your \(kind.title) test has run its course. Open Trio to return to your normal dosing."
        )
        content.sound = .default
        content.categoryIdentifier = SettingsTestNotice.category
        content.userInfo = [SettingsTestNotice.kindKey: kind.rawValue]
        return content
    }

    private func cancelExpiryNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [SettingsTestStorage.expiryNotificationID])
        center.removeDeliveredNotifications(withIdentifiers: [SettingsTestStorage.expiryNotificationID])
    }
}

extension BaseSettingsTestService: SettingsObserver {
    /// A mode picked during a test that switched to Basal Testing: a low from before the change is checked for at once,
    /// before the runner's next check reads the change as an interrupted test.
    func settingsDidChange(_: TrioSettings) {
        guard noteTestModeLeft() else { return }
        checkSessionInBackground()
    }
}
