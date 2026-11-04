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
    @discardableResult func begin(
        kind: SettingsTestKind,
        expiresIn: TimeInterval,
        restoring: [SettingsTestRestoreAction],
        settles: Bool
    ) -> SettingsTestSession?

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
}

extension SettingsTestService {
    /// A session that doesn't settle.
    @discardableResult func begin(
        kind: SettingsTestKind,
        expiresIn: TimeInterval,
        restoring: [SettingsTestRestoreAction]
    ) -> SettingsTestSession? {
        begin(kind: kind, expiresIn: expiresIn, restoring: restoring, settles: false)
    }
}

/// What is read to watch a running test, by the service and by the basal test's own screen. A protocol so tests can
/// stand in for Core Data.
protocol SettingsTestEvents {
    /// Temp basals the pump started in the window, oldest first. Scheduled basal, which pumps also report as a temp,
    /// is left out: it is the basal being tested, not a change to it, and a 0 U/h entry is no suspend.
    func tempBasals(from start: Date, to end: Date) async throws -> [BasalTestTempBasal]
    /// When Trio's determinations in the window asked for a zero temp basal with time on it, oldest first. A
    /// determination is dated by when it was due, or when it was made if that is missing. The pump history doesn't say
    /// who set a temp, so these are what tell Trio's suspend from a zero temp set on the pump.
    func zeroTempDeterminations(from start: Date, to end: Date) async throws -> [Date]
    /// Whether carbs were logged in the window.
    func hasCarbEntries(from start: Date, to end: Date) async throws -> Bool
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

    func hasCarbEntries(from start: Date, to end: Date) async throws -> Bool {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: CarbEntryStored.self,
            onContext: context,
            predicate: NSPredicate(format: "carbs > 0 AND date >= %@ AND date <= %@", start as NSDate, end as NSDate),
            key: "date",
            ascending: false,
            fetchLimit: 1
        )
        let context = context
        return await context.perform { !((results as? [CarbEntryStored]) ?? []).isEmpty }
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

    /// The newest CGM reading from `earliest` to `date` inclusive, with the CGM's own arrow for it: what the ISF test
    /// reads the arrow at its bolus from. Nil when there is none. Not in `SettingsTestEvents`, because the watchdog
    /// doesn't use it.
    func arrowReading(atOrBefore date: Date, since earliest: Date) async throws -> ISFTestArrowReading? {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSPredicate(format: "date >= %@ AND date <= %@", earliest as NSDate, date as NSDate),
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
    private let lock = NSLock()
    /// While the service puts a session's changes back, so its own change of mode isn't taken for the user's.
    private var restoring = false

    var activeSession: SettingsTestSession? { sessionSubject.value }
    var sessionPublisher: AnyPublisher<SettingsTestSession?, Never> { sessionSubject.eraseToAnyPublisher() }

    /// What the watchdog reads to end a basal or ISF test on a low, basal stopped, carbs, or a second bolus or none.
    private let events: SettingsTestEvents

    /// `events` is for tests; the app reads Core Data.
    init(resolver: Resolver, events: SettingsTestEvents? = nil) {
        self.events = events ?? CoreDataSettingsTestEvents(context: CoreDataStack.shared.newTaskContext())
        injectServices(resolver)
        broadcaster.register(SettingsObserver.self, observer: self)

        // A session left over from a previous launch is either still running or past its deadline. Either way it is
        // checked for a low first, so one that ran past its deadline while the app was closed keeps the low it had.
        if let existing = storage.retrieve(SettingsTestStorage.sessionPath, as: SettingsTestSession.self) {
            sessionSubject.send(existing)
            startWatchdog()
            checkSessionInBackground()
        }
    }

    @discardableResult func begin(
        kind: SettingsTestKind,
        expiresIn: TimeInterval,
        restoring: [SettingsTestRestoreAction],
        settles: Bool
    ) -> SettingsTestSession? {
        guard activeSession == nil else { return nil }
        let session = SettingsTestSession(
            kind: kind,
            expiresAt: Date().addingTimeInterval(expiresIn),
            restore: restoring,
            settles: settles ? true : nil
        )
        storage.save(session, as: SettingsTestStorage.sessionPath)
        sessionSubject.send(session)
        scheduleExpiryNotification(at: session.expiresAt, kind: kind)
        startWatchdog()
        return session
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
    /// mode back with the mode in force now (`SettingsTestRestoreAction.modeToRestore`), so the screen can say so.
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
    /// test. The watchdog calls this, so any one of them brings the usual dosing back whether or not that screen is
    /// open. Basal stopped without Trio asking, by a zero temp set on the pump, ends it too: the test is spoiled, and it
    /// isn't kept as a low. So do carbs that can't be read, in a basal or an ISF test: Basal Testing gives no insulin
    /// for food, so it mustn't stay on unchecked. Why and when is kept (`lastEnd()`), so the screen, when opened again,
    /// finishes the result for the same reason with the usual mode already back. A second bolus is dated at that bolus,
    /// and no bolus at the end of the time allowed, so the screen can tell whether they came before the planned end. A
    /// suspend is looked for first, then carbs, then boluses; a suspend that can't be read doesn't stop the others being
    /// read, and boluses that can't be read leave the test running. Only a session that switched to Basal Testing: a
    /// mode the user picked since is theirs, unless Basal Testing suspended for a low before the change
    /// (`noteTestModeLeft`). That low is still this test's. Without one, the session ends as a mode change
    /// (`modeChanged`, dated at the change), so the screen reads it as an interrupted test. Either way the end puts the
    /// usual mode back only if Basal Testing is on again by then (`SettingsTestRestoreAction.modeToRestore`). For an ISF
    /// test, the pump suspended, alarmed or changed since Begin ends it too (`pumpInterrupted`), after a low and before
    /// carbs.
    ///
    /// An ISF test whose 4 hours from its bolus, and the grace after them, are over is ended too, with no reason kept,
    /// as on expiry: nothing spoiled it, so the screen finishes it as completed when opened. Its session lasts until the
    /// latest the 4 hours could end, so without this Basal Testing could stay on for up to the time allowed for the
    /// bolus after a test that had run its course.
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
        } else if session.kind == .isf, let interruptedAt = await pumpInterruption(of: session, until: now) {
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
            // Kept before the usual mode comes back, so the screen never finds the mode changed without the reason.
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
    /// wasn't, and when the pump history can't be read: the test screen's own check then can't rule it out and gives no
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

    /// What carbs since `session` began say: they end it if any were logged, and also if they can't be read, so the
    /// usual dosing comes back. Nil to keep going.
    private func carbsEnding(of session: SettingsTestSession, until end: Date) async -> SettingsTestEndCause? {
        do {
            return try await events.hasCarbEntries(from: session.startedAt, to: end) ? .carbsLogged : nil
        } catch {
            warning(.settings, "SettingsTest: couldn't read carbs to watch the \(session.kind.rawValue) test", error: error)
            return .carbsUnreadable
        }
    }

    /// What the boluses say ends a running ISF test.
    private enum ISFBolusCheck {
        /// Something spoiled it, kept for the screen.
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

    /// What the watchdog does on each tick, and what a session recovered at launch gets once: the low, carbs and bolus
    /// check first, then the expiry check. In that order because a session past its deadline is ended whatever it
    /// finds, and ending it first would lose the low, which the basal screen would then report as an interrupted fast.
    /// The expiry check runs even when the history can't be read, so the usual mode always comes back.
    func checkSession() async {
        await endIfLowOrInterrupted()
        // Where the watchdog's timer ran it before, so the mode and the session are changed on the main actor.
        await MainActor.run { endIfExpired() }
    }

    private func checkSessionInBackground() {
        Task { [weak self] in await self?.checkSession() }
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
        watchdog = nil
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
        watchdog = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.checkSessionInBackground() }
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
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Test time is up")
        content.body = String(
            localized: "Your \(kind.title) test has run its course. Open Trio to return to your normal dosing."
        )
        content.sound = .default
        let interval = max(1, date.timeIntervalSinceNow)
        let request = UNNotificationRequest(
            identifier: SettingsTestStorage.expiryNotificationID,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func cancelExpiryNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [SettingsTestStorage.expiryNotificationID])
        center.removeDeliveredNotifications(withIdentifiers: [SettingsTestStorage.expiryNotificationID])
    }
}

extension BaseSettingsTestService: SettingsObserver {
    /// A mode picked during a test that switched to Basal Testing: a low from before the change is checked for at once,
    /// before the basal screen's next check reads the change as an interrupted fast.
    func settingsDidChange(_: TrioSettings) {
        guard noteTestModeLeft() else { return }
        checkSessionInBackground()
    }
}
