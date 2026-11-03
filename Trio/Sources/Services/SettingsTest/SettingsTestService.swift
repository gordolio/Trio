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
    @discardableResult func begin(
        kind: SettingsTestKind,
        expiresIn: TimeInterval,
        restoring: [SettingsTestRestoreAction]
    ) -> SettingsTestSession?

    /// Puts everything back and clears the session, if the one running is of this kind. A test ends only its own
    /// session, so it can never undo another test's change.
    func end(kind: SettingsTestKind)

    /// Ends the session if it ran past its deadline. Safe to call at any time.
    func endIfExpired()

    /// The last session the service ended on its own, for a low or for logged carbs, and why. Kept until the next one.
    func lastEnd() -> SettingsTestEnd?

    func archive(_ record: SettingsTestRecord)
    func history(for kind: SettingsTestKind?) -> [SettingsTestRecord]
}

/// What is read to watch a running test, by the service and by the basal test's own screen. A protocol so tests can
/// stand in for Core Data.
protocol SettingsTestEvents {
    /// Temp basals the pump started in the window, oldest first. Scheduled basal, which pumps also report as a temp,
    /// is left out: it is the basal being tested, not a change to it, and a 0 U/h entry is no suspend.
    func tempBasals(from start: Date, to end: Date) async throws -> [BasalTestTempBasal]
    /// Whether carbs were logged in the window.
    func hasCarbEntries(from start: Date, to end: Date) async throws -> Bool
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
}

final class BaseSettingsTestService: SettingsTestService, Injectable {
    @Injected() private var storage: FileStorage!
    @Injected() private var settingsManager: SettingsManager!

    private let sessionSubject = CurrentValueSubject<SettingsTestSession?, Never>(nil)
    private var watchdog: AnyCancellable?
    private let lock = NSLock()

    var activeSession: SettingsTestSession? { sessionSubject.value }
    var sessionPublisher: AnyPublisher<SettingsTestSession?, Never> { sessionSubject.eraseToAnyPublisher() }

    /// What the watchdog reads to end a basal test on a low or logged carbs.
    private let events: SettingsTestEvents

    /// `events` is for tests; the app reads Core Data.
    init(resolver: Resolver, events: SettingsTestEvents? = nil) {
        self.events = events ?? CoreDataSettingsTestEvents(context: CoreDataStack.shared.newTaskContext())
        injectServices(resolver)

        // A session left over from a previous launch is either still running or past its deadline.
        if let existing = storage.retrieve(SettingsTestStorage.sessionPath, as: SettingsTestSession.self) {
            sessionSubject.send(existing)
            startWatchdog()
            endIfExpired()
        }
    }

    @discardableResult func begin(
        kind: SettingsTestKind,
        expiresIn: TimeInterval,
        restoring: [SettingsTestRestoreAction]
    ) -> SettingsTestSession? {
        guard activeSession == nil else { return nil }
        let session = SettingsTestSession(kind: kind, expiresAt: Date().addingTimeInterval(expiresIn), restore: restoring)
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
        end(session)
    }

    /// Ends a running test in Basal Testing when Trio suspended insulin for a low since it began, and a basal test when
    /// carbs were logged: the two things the basal Fast screen says end the test. The watchdog calls this, so either
    /// one brings the usual dosing back whether or not that screen is open. Why and when is kept (`lastEnd()`), so the
    /// screen, when opened again, finishes the result for the same reason with the usual mode already back. Only a
    /// session that switched to Basal Testing and is still in it: a mode the user picked since is theirs, and the basal
    /// screen reads that as an interrupted fast.
    func endIfLowOrCarbsLogged() async {
        guard let session = activeSession,
              session.restore.contains(where: \.switchesToBasalTesting),
              settingsManager.settings.dosingMode == .basalTesting
        else { return }
        let now = Date()
        let ending: SettingsTestEnd
        do {
            let temps = try await events.tempBasals(from: session.startedAt, to: now)
            if let suspendedAt = BasalTestEvaluator.firstSuspend(temps, since: session.startedAt, until: now) {
                debug(.settings, "SettingsTest: Trio suspended for a low, ending the \(session.kind.rawValue) test")
                ending = SettingsTestEnd(sessionID: session.id, cause: .low, date: suspendedAt)
            } else if session.kind == .basal, try await events.hasCarbEntries(from: session.startedAt, to: now) {
                // Only the basal test tells the user that logging carbs ends it.
                debug(.settings, "SettingsTest: carbs were logged, ending the \(session.kind.rawValue) test")
                ending = SettingsTestEnd(sessionID: session.id, cause: .carbsLogged, date: now)
            } else {
                return
            }
        } catch {
            warning(.settings, "SettingsTest: couldn't read the history to watch the \(session.kind.rawValue) test", error: error)
            return
        }
        await MainActor.run {
            guard activeSession?.id == session.id else { return }
            // Kept before the usual mode comes back, so the screen never finds the mode changed without the reason.
            storage.save(ending, as: SettingsTestStorage.lastEndPath)
            end(session)
        }
    }

    func lastEnd() -> SettingsTestEnd? {
        storage.retrieve(SettingsTestStorage.lastEndPath, as: SettingsTestEnd.self)
    }

    /// Puts back what `session` changed and clears it, if it is still the one running.
    private func end(_ session: SettingsTestSession) {
        guard activeSession?.id == session.id else { return }
        apply(session.restore)
        storage.remove(SettingsTestStorage.sessionPath)
        sessionSubject.send(nil)
        watchdog = nil
        cancelExpiryNotification()
    }

    // MARK: - Restore

    private func apply(_ actions: [SettingsTestRestoreAction]) {
        for action in actions {
            switch action {
            case let .dosingMode(testMode, previous):
                // Leave a mode the user picked themselves alone.
                guard settingsManager.settings.dosingMode == testMode else { continue }
                settingsManager.settings.dosingMode = previous
                debug(.settings, "SettingsTest: dosing mode restored to \(previous.rawValue)")
            }
        }
    }

    private func startWatchdog() {
        watchdog = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.endIfExpired()
                Task { [weak self] in await self?.endIfLowOrCarbsLogged() }
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
