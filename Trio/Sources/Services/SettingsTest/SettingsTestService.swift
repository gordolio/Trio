import Combine
import Foundation
import Swinject
import UserNotifications

private enum SettingsTestStorage {
    static let sessionPath = "trio/settings_test_session.json"
    static let historyPath = "trio/settings_test_history.json"
    static let maxHistory = 200
    static let expiryNotificationID = "Trio.settingsTestExpired"
}

/// Keeps track of a running settings test and makes sure anything it changed is put back.
protocol SettingsTestService: AnyObject {
    var activeSession: SettingsTestSession? { get }
    var sessionPublisher: AnyPublisher<SettingsTestSession?, Never> { get }

    /// Starts a session. Call this *before* making the temporary change, so there is a way back
    /// the moment the change takes effect. Restore actions only apply if the change is in effect.
    @discardableResult func begin(
        kind: SettingsTestKind,
        expiresIn: TimeInterval,
        restoring: [SettingsTestRestoreAction]
    ) -> SettingsTestSession

    /// Puts everything back and clears the session.
    func end()

    /// Ends the session if it ran past its deadline. Safe to call at any time.
    func endIfExpired()

    func archive(_ record: SettingsTestRecord)
    func history(for kind: SettingsTestKind?) -> [SettingsTestRecord]
}

final class BaseSettingsTestService: SettingsTestService, Injectable {
    @Injected() private var storage: FileStorage!
    @Injected() private var settingsManager: SettingsManager!

    private let sessionSubject = CurrentValueSubject<SettingsTestSession?, Never>(nil)
    private var watchdog: AnyCancellable?
    private let lock = NSLock()

    var activeSession: SettingsTestSession? { sessionSubject.value }
    var sessionPublisher: AnyPublisher<SettingsTestSession?, Never> { sessionSubject.eraseToAnyPublisher() }

    init(resolver: Resolver) {
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
    ) -> SettingsTestSession {
        let session = SettingsTestSession(kind: kind, expiresAt: Date().addingTimeInterval(expiresIn), restore: restoring)
        storage.save(session, as: SettingsTestStorage.sessionPath)
        sessionSubject.send(session)
        scheduleExpiryNotification(at: session.expiresAt, kind: kind)
        startWatchdog()
        return session
    }

    func end() {
        guard let session = activeSession else { return }
        apply(session.restore)
        storage.remove(SettingsTestStorage.sessionPath)
        sessionSubject.send(nil)
        watchdog = nil
        cancelExpiryNotification()
    }

    func endIfExpired() {
        guard let session = activeSession, session.expiresAt <= Date() else { return }
        debug(.service, "SettingsTest: \(session.kind.rawValue) test expired, restoring settings")
        end()
    }

    // MARK: - Restore

    private func apply(_ actions: [SettingsTestRestoreAction]) {
        for action in actions {
            switch action {
            case let .dosingMode(testMode, previous):
                // Leave a mode the user picked themselves alone.
                guard settingsManager.settings.dosingMode == testMode else { continue }
                settingsManager.settings.dosingMode = previous
                debug(.service, "SettingsTest: dosing mode restored to \(previous.rawValue)")
            }
        }
    }

    private func startWatchdog() {
        watchdog = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.endIfExpired() }
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
