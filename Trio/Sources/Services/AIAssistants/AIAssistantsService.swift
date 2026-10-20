import Combine
import CoreData
import Foundation
import Swinject
import UIKit

enum AIAssistantsLinkState: Equatable {
    case notLinked
    case linked(host: String, lastUpload: Date?, lastError: String?)
    case signedOut(host: String)
}

/// Trio's link to the trio-rc service: the stored address and tokens, whether they still
/// work, and the status uploads.
protocol AIAssistantsService: AnyObject {
    var state: CurrentValueSubject<AIAssistantsLinkState, Never> { get }
    /// Who Trio signed in as; sent before the state that goes with it.
    var account: CurrentValueSubject<AIAssistantsAccount?, Never> { get }
    func completeLink(baseURL: URL, tokens: AIAssistantsTokens, account: AIAssistantsAccount?) async
    /// Forgets the link. Returns `false` if the service couldn't be told, so it may still hold
    /// the last status.
    @discardableResult func unlink() async -> Bool
    /// Registers this phone if its push token changed, then uploads the status if it changed.
    /// While an upload is in flight, this only asks for one more upload after it.
    func uploadNow() async
}

final class BaseAIAssistantsService: AIAssistantsService {
    let state: CurrentValueSubject<AIAssistantsLinkState, Never>
    let account: CurrentValueSubject<AIAssistantsAccount?, Never>

    private let api: AIAssistantsAPIClient
    private let store: AIAssistantsTokenStore
    private let builder: AIAssistantsSnapshotBuilder
    private let deviceRegistration: () -> DeviceRegistration?
    private let beginBackgroundActivity: (String) -> () -> Void
    private let now: () -> Date
    private let queue = DispatchQueue(label: "BaseAIAssistantsService.queue", qos: .utility)
    private var subscriptions = Set<AnyCancellable>()

    private let uploadLock = NSLock()
    private var isUploading = false
    private var uploadRequested = false
    /// Set while unlinking: no upload starts.
    private var isUnlinking = false
    /// Unlinks waiting for the upload in flight to finish.
    private var waitingForUpload: [CheckedContinuation<Void, Never>] = []
    /// The last status the service accepted.
    private var lastSentStatus: StatusSnapshot?
    /// Ends the background task that keeps Trio running from a trigger until its upload.
    private var endPendingActivity: (() -> Void)?
    /// The check-ins, which use the link on their own, so unlinking stops them as it stops the uploads. Set once
    /// the runtime that makes them is built.
    var checkIn: AIAssistantsCheckIn?

    /// Uses its own device-only Keychain rather than the shared one, which syncs through iCloud.
    convenience init(resolver: Resolver) {
        let store = AIAssistantsTokenStore.deviceOnly()
        let apsManager = resolver.resolve(APSManager.self)!
        let settingsManager = resolver.resolve(SettingsManager.self)!
        let api = AIAssistantsAPI(store: store, auth: AIAssistantsAuthClient())
        self.init(
            api: api,
            store: store,
            builder: AIAssistantsSnapshotBuilder(
                context: CoreDataStack.shared.newTaskContext(),
                loopInfo: { .init(lastLoopDate: apsManager.lastLoopDate, lastError: apsManager.lastError.value) },
                units: { settingsManager.settings.units }
            ),
            triggers: BaseAIAssistantsService.appTriggers(
                lastLoopDate: apsManager.lastLoopDateSubject.eraseToAnyPublisher(),
                lastLoopError: apsManager.lastError.eraseToAnyPublisher(),
                entityChanges: CoreDataStack.shared.entityChangePublisher
            ),
            debounce: .seconds(10),
            deviceRegistration: {
                BaseAIAssistantsService.currentDeviceRegistration(preferences: AIRequestsRuntime.shared?.preferences.value)
            },
            beginBackgroundActivity: BaseAIAssistantsService.beginBackgroundTask(named:),
            now: Date.init
        )

        // A new watch push token needs the device registered again. A check-in runs while the API has the
        // address and tokens it sends with; signing out clears the tokens.
        let runtime = AIRequestsRuntime(
            resolver: resolver,
            api: api,
            isLinked: { store.baseURL != nil && store.tokens != nil },
            loopRuns: apsManager.lastLoopDateSubject.eraseToAnyPublisher(),
            uploadNow: { [weak self] in Task { await self?.uploadNow() } }
        )
        AIRequestsRuntime.shared = runtime
        checkIn = runtime.checkIn
        uploadWhenWakePushTypeChanges(runtime.preferences.changes.eraseToAnyPublisher())
        Task { await runtime.coordinator.start() }
    }

    init(
        api: AIAssistantsAPIClient,
        store: AIAssistantsTokenStore,
        builder: AIAssistantsSnapshotBuilder,
        triggers: AnyPublisher<Void, Never>,
        debounce: DispatchQueue.SchedulerTimeType.Stride,
        deviceRegistration: @escaping () -> DeviceRegistration?,
        beginBackgroundActivity: @escaping (String) -> () -> Void,
        now: @escaping () -> Date
    ) {
        self.api = api
        self.store = store
        self.builder = builder
        self.deviceRegistration = deviceRegistration
        self.beginBackgroundActivity = beginBackgroundActivity
        self.now = now
        account = CurrentValueSubject(store.account)
        if let baseURL = store.baseURL, store.tokens != nil {
            state = CurrentValueSubject(.linked(host: Self.host(of: baseURL), lastUpload: nil, lastError: nil))
        } else {
            state = CurrentValueSubject(.notLinked)
        }
        triggers
            .handleEvents(receiveOutput: { [weak self] in self?.holdUntilUploaded() })
            .debounce(for: debounce, scheduler: queue)
            .sink { [weak self] in self?.triggered() }
            .store(in: &subscriptions)
        api.signedOut
            .sink { [weak self] baseURL in self?.signedOut(of: baseURL) }
            .store(in: &subscriptions)
    }

    func completeLink(baseURL: URL, tokens: AIAssistantsTokens, account: AIAssistantsAccount?) async {
        store.baseURL = baseURL
        store.tokens = tokens
        store.account = account
        self.account.send(account)
        // The service has no device or status for a new link, for example after Unlink on the website.
        store.lastDevice = nil
        uploadLock.withLock { lastSentStatus = nil }
        state.send(.linked(host: Self.host(of: baseURL), lastUpload: nil, lastError: nil))
        debug(.service, "AI Assistants: linked to \(Self.host(of: baseURL))")
        await uploadNow()
    }

    /// Deleting the device also deletes its status and revokes Trio's tokens on the service.
    /// Trio forgets the link even if that request fails, for example when offline.
    @discardableResult func unlink() async -> Bool {
        await stopUploads()
        await checkIn?.pause()
        // A check-in asked for from here on finds Trio not linked.
        defer { checkIn?.resume() }
        var deleted = true
        do {
            try await api.deleteDevice()
        } catch {
            debug(.service, "AI Assistants: unlink request failed: \(error)")
            deleted = false
        }
        store.clear()
        account.send(nil)
        state.send(.notLinked)
        uploadLock.withLock { isUnlinking = false }
        return deleted
    }

    /// Keeps new uploads from starting and waits for the one in flight. Its token refresh could
    /// otherwise write tokens back after the store is cleared, or use up the refresh token the
    /// delete needs.
    private func stopUploads() async {
        await withCheckedContinuation { continuation in
            let resumeNow = uploadLock.withLock {
                isUnlinking = true
                uploadRequested = false
                guard isUploading else { return true }
                waitingForUpload.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    // MARK: - Uploads

    func uploadNow() async {
        guard startUpload() else { return }
        let endActivity = beginBackgroundActivity("AI Assistants upload")
        defer { endActivity() }
        repeat {
            await upload()
        } while uploadAgain()
    }

    /// The loop ends its background task as soon as it finishes, so on a locked phone Trio
    /// could be suspended before the debounce fires. Keep it running until the upload is done.
    /// Each trigger gets a fresh task: iOS ends one after about 30 s, and a loop's saves can
    /// keep the debounce going longer than that.
    private func holdUntilUploaded() {
        guard case .linked = state.value else { return }
        let endNew = beginBackgroundActivity("AI Assistants pending upload")
        let endOld = uploadLock.withLock {
            defer { endPendingActivity = endNew }
            return endPendingActivity
        }
        endOld?()
    }

    private func triggered() {
        let endActivity = uploadLock.withLock {
            defer { endPendingActivity = nil }
            return endPendingActivity
        }
        Task { [weak self] in
            if let self, case .linked = self.state.value {
                await self.uploadNow()
            }
            endActivity?()
        }
    }

    /// False while unlinking, or while an upload is in flight; that upload then runs once more.
    private func startUpload() -> Bool {
        uploadLock.withLock {
            if isUnlinking {
                return false
            }
            if isUploading {
                uploadRequested = true
                return false
            }
            isUploading = true
            return true
        }
    }

    private func uploadAgain() -> Bool {
        let (again, unlinks) = uploadLock.withLock {
            if uploadRequested {
                uploadRequested = false
                return (true, [CheckedContinuation<Void, Never>]())
            }
            isUploading = false
            defer { waitingForUpload = [] }
            return (false, waitingForUpload)
        }
        unlinks.forEach { $0.resume() }
        return again
    }

    /// Nothing is queued or retried: a failed upload waits for the next trigger. A status equal
    /// to the last one sent isn't sent again; saves of the Nightscout, Apple Health and Tidepool
    /// upload flags trigger uploads too.
    private func upload() async {
        guard case let .linked(host, _, _) = state.value else { return }
        do {
            try await registerDeviceIfChanged()
            let status = try await builder.build(now: now())
            if let lastSent = uploadLock.withLock({ lastSentStatus }), status.isSameStatus(as: lastSent) {
                return
            }
            try await api.putStatus(status)
            uploadLock.withLock { lastSentStatus = status }
            finish(host: host) { _ in .linked(host: host, lastUpload: self.now(), lastError: nil) }
        } catch AIAssistantsAPIError.signedOut {
            // The client has told `signedOut(of:)` too, unless another call found out first.
            finish(host: host) { _ in .signedOut(host: host) }
        } catch {
            debug(.service, "AI Assistants: upload failed: \(error)")
            let message = Self.message(for: error)
            finish(host: host) { lastUpload in .linked(host: host, lastUpload: lastUpload, lastError: message) }
        }
    }

    /// Any call to the service can find Trio signed out: an upload, a check-in or a state report.
    private func signedOut(of baseURL: URL) {
        let host = Self.host(of: baseURL)
        debug(.service, "AI Assistants: signed out of \(host)")
        finish(host: host) { _ in .signedOut(host: host) }
    }

    /// Applies the result of an upload or a sign-out, unless the link changed meanwhile (unlinked, or
    /// linked to another address). `newState` gets the current last upload time.
    private func finish(host: String, _ newState: (Date?) -> AIAssistantsLinkState) {
        guard case let .linked(currentHost, lastUpload, _) = state.value, currentHost == host else { return }
        state.send(newState(lastUpload))
    }

    /// A failed registration is tried again on the next upload, and doesn't hold up the status
    /// unless Trio was signed out.
    private func registerDeviceIfChanged() async throws {
        guard let device = deviceRegistration(), device != store.lastDevice else { return }
        do {
            try await api.putDevice(device)
            store.lastDevice = device
        } catch AIAssistantsAPIError.signedOut {
            throw AIAssistantsAPIError.signedOut
        } catch {
            debug(.service, "AI Assistants: device registration failed: \(error)")
        }
    }

    private static func message(for error: Error) -> String {
        switch error as? AIAssistantsAPIError {
        case .network?:
            return String(localized: "Offline")
        case let .http(status, code?)?:
            return String(localized: "Upload failed (error \(status) \(code))")
        case let .http(status, nil)?:
            return String(localized: "Upload failed (error \(status))")
        default:
            return String(localized: "Upload failed (\(error.localizedDescription))")
        }
    }

    // MARK: - App wiring

    /// The wake-up push type is part of the device registration, so a new one is uploaded to tell the
    /// service. The first value is the current one, and a repeat isn't a change.
    func uploadWhenWakePushTypeChanges(_ preferences: AnyPublisher<AIAssistantsPreferences, Never>) {
        preferences
            .map(\.wakePushType)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task {
                    if let self, case .linked = self.state.value {
                        await self.uploadNow()
                    }
                }
            }
            .store(in: &subscriptions)
    }

    /// Loop runs, loop failures (which don't change `lastLoopDate`), and saves of the rows a
    /// snapshot reads.
    static func appTriggers(
        lastLoopDate: AnyPublisher<Date, Never>,
        lastLoopError: AnyPublisher<Error?, Never>,
        entityChanges: AnyPublisher<Set<NSManagedObjectID>, Never>
    ) -> AnyPublisher<Void, Never> {
        let entities: Set<String> = ["GlucoseStored", "CarbEntryStored", "PumpEventStored", "OverrideStored", "TempTargetStored"]
        return entityChanges
            .filter { ids in ids.contains { id in id.entity.name.map { entities.contains($0) } ?? false } }
            .map { _ in () }
            .merge(
                with: lastLoopDate.map { _ in () },
                lastLoopError.compactMap { $0 }.map { _ in () }
            )
            .eraseToAnyPublisher()
    }

    /// Returns the function that ends the task. iOS ends it after about 30 s if it's still
    /// running; the upload then fails as offline and waits for the next trigger.
    static func beginBackgroundTask(named name: String) -> () -> Void {
        let lock = NSLock()
        var taskID = UIBackgroundTaskIdentifier.invalid
        let end = {
            let id = lock.withLock {
                defer { taskID = .invalid }
                return taskID
            }
            if id != .invalid {
                UIApplication.shared.endBackgroundTask(id)
            }
        }
        let id = UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: end)
        lock.withLock { taskID = id }
        return end
    }

    /// This phone's push registration, which Trio Remote Control stores on every launch.
    /// `nil` until the phone has a push token. The version is the one Settings shows
    /// (1.0.2.12), not the build number. The watch is included once it has sent its push token, and
    /// the wake-up push type when there are `preferences`.
    static func currentDeviceRegistration(
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main,
        preferences: AIAssistantsPreferences? = nil
    ) -> DeviceRegistration? {
        guard let token = defaults.string(forKey: "deviceToken"), !token.isEmpty else { return nil }
        let bundleId = bundle.bundleIdentifier ?? ""
        let environment = defaults.bool(forKey: "isAPNSProduction") ? "production" : "sandbox"
        let watchToken = defaults.string(forKey: AIRequestWatchLink.watchPushTokenKey).flatMap { $0.isEmpty ? nil : $0 }
        return DeviceRegistration(
            apnsToken: token,
            bundleId: bundleId,
            apnsEnvironment: environment,
            appVersion: bundle.appDevVersion ?? bundle.releaseVersionNumber ?? "",
            // The service pushes to the watch through the phone's APNs environment.
            watch: watchToken.map {
                WatchRegistration(apnsToken: $0, bundleId: "\(bundleId).watchkitapp", apnsEnvironment: environment)
            },
            wakePushType: preferences?.wakePushType.rawValue
        )
    }

    private static func host(of url: URL) -> String {
        url.host ?? url.absoluteString
    }
}

private extension StatusSnapshot {
    /// Equal to `other` apart from when it was built.
    func isSameStatus(as other: StatusSnapshot) -> Bool {
        StatusSnapshot(
            schemaVersion: schemaVersion,
            generatedAt: other.generatedAt,
            units: units,
            glucose: glucose,
            iob: iob,
            cob: cob,
            loop: loop,
            prediction: prediction,
            override: override,
            tempTarget: tempTarget,
            recentTreatments: recentTreatments
        ) == other
    }
}
