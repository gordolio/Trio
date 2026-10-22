import Combine
import CoreData
import Foundation
import Testing

@testable import Trio

/// Records calls and throws the error scripted for a call's name. A scripted `.signedOut` is also sent on
/// `signedOut`, with `serviceURL`, as the client does.
final class FakeAIAssistantsAPI: AIAssistantsAPIClient {
    private let lock = NSLock()
    private let signedOutSubject = PassthroughSubject<URL, Never>()
    private var recordedCalls: [String] = []
    private var recordedStatuses: [StatusSnapshot] = []
    private var recordedRequestStates: [(id: String, body: AIRequestStateBody)] = []
    private var storedInbox = AIInbox(requests: [])
    /// Keyed by call name: "putDevice", "deleteDevice", "putStatus", "getInbox" or "putRequestState".
    var errors: [String: AIAssistantsAPIError] = [:]
    /// When set, `putStatus` waits for it to open.
    var statusGate: UploadGate?
    /// When set, `getInbox` waits for it to open, after recording the call.
    var inboxGate: UploadGate?
    /// When set, `getInbox` decodes it with the API's decoder instead of returning `inbox`, so a malformed
    /// body throws as it does from the service.
    var inboxBody: Data?
    /// Runs when `putStatus` finishes, as a token refresh writes the store during a request.
    var whenStatusSent: (() -> Void)?
    /// The address the calls go to.
    var serviceURL = URL(string: "https://svc.example.com")!

    var signedOut: AnyPublisher<URL, Never> { signedOutSubject.eraseToAnyPublisher() }

    var calls: [String] { lock.withLock { recordedCalls } }
    var statuses: [StatusSnapshot] { lock.withLock { recordedStatuses } }
    var requestStates: [(id: String, body: AIRequestStateBody)] { lock.withLock { recordedRequestStates } }
    /// Each state report sent, including the failed ones, as `"<id>:<state>"`.
    var reportedStates: [String] { requestStates.map { "\($0.id):\($0.body.state.rawValue)" } }
    /// What `getInbox` returns.
    var inbox: AIInbox {
        get { lock.withLock { storedInbox } }
        set { lock.withLock { storedInbox = newValue } }
    }

    func putDevice(_: DeviceRegistration) async throws {
        try record("putDevice")
    }

    func deleteDevice() async throws {
        try record("deleteDevice")
    }

    func putStatus(_ snapshot: StatusSnapshot) async throws {
        lock.withLock { recordedStatuses.append(snapshot) }
        try record("putStatus")
        if let statusGate { await statusGate.wait() }
        whenStatusSent?()
    }

    func getInbox() async throws -> AIInbox {
        lock.withLock { recordedCalls.append("getInbox") }
        if let inboxGate { await inboxGate.wait() }
        if let error = lock.withLock({ errors["getInbox"] }) { throw thrown(error) }
        if let inboxBody { return try AIInbox.decoder.decode(AIInbox.self, from: inboxBody) }
        return inbox
    }

    func putRequestState(id: String, _ body: AIRequestStateBody) async throws {
        lock.withLock { recordedRequestStates.append((id, body)) }
        try record("putRequestState")
    }

    private func record(_ call: String) throws {
        let error = lock.withLock {
            recordedCalls.append(call)
            return errors[call]
        }
        if let error { throw thrown(error) }
    }

    private func thrown(_ error: AIAssistantsAPIError) -> AIAssistantsAPIError {
        if error == .signedOut {
            signedOutSubject.send(serviceURL)
        }
        return error
    }
}

/// Holds whoever waits on it until it opens.
final class UploadGate {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if isOpen { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let continuations = lock.withLock {
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        continuations.forEach { $0.resume() }
    }
}

/// Records background activities as "begin <name>" and "end <name>".
final class FakeBackgroundActivity {
    private let lock = NSLock()
    private var recorded: [String] = []

    var events: [String] { lock.withLock { recorded } }

    func begin(_ name: String) -> () -> Void {
        lock.withLock { recorded.append("begin \(name)") }
        return { [self] in lock.withLock { recorded.append("end \(name)") } }
    }
}

final class TestBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Polls `condition` for up to 2 s.
func eventuallyTrue(_ condition: () -> Bool) async -> Bool {
    for _ in 0 ..< 400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// Long enough for several 20 ms debounce windows to pass.
func letDebouncePass() async {
    try? await Task.sleep(for: .milliseconds(150))
}

@Suite("AI Assistants link service", .serialized) struct AIAssistantsServiceTests {
    let baseURL = URL(string: "https://svc.example.com")!
    let tokens = AIAssistantsTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 1_000_000))
    let now = Date(timeIntervalSince1970: 1_792_000_000)
    let device = DeviceRegistration(
        apnsToken: String(repeating: "ab", count: 32),
        bundleId: "org.nightscout.TEAMID.trio",
        apnsEnvironment: "sandbox",
        appVersion: "1.0.2.12"
    )
    let store = AIAssistantsTokenStore(keychain: InMemoryKeychain())
    let ann = AIAssistantsAccount(email: "ann@example.com", name: "Ann Lee")
    let api = FakeAIAssistantsAPI()
    let triggers = PassthroughSubject<Void, Never>()
    /// What `deviceRegistration()` returns: nil until the phone has a push token.
    let pushDevice = TestBox<DeviceRegistration?>(nil)
    /// When the loop last ran, as the snapshot reports it.
    let lastLoop = TestBox<Date?>(nil)
    /// What the service's `now()` returns; starts at `now`.
    let clock: TestBox<Date>
    let activity = FakeBackgroundActivity()
    let stack: CoreDataStack
    let builder: AIAssistantsSnapshotBuilder

    init() async throws {
        clock = TestBox(now)
        stack = try await CoreDataStack.createForTests()
        let lastLoop = self.lastLoop
        builder = AIAssistantsSnapshotBuilder(
            context: stack.newTaskContext(),
            loopInfo: { .init(lastLoopDate: lastLoop.value, lastError: nil) },
            units: { .mgdL }
        )
    }

    func makeService() -> BaseAIAssistantsService {
        let clock = self.clock
        let pushDevice = self.pushDevice
        return BaseAIAssistantsService(
            api: api,
            store: store,
            builder: builder,
            triggers: triggers.eraseToAnyPublisher(),
            debounce: .milliseconds(20),
            deviceRegistration: { pushDevice.value },
            beginBackgroundActivity: activity.begin,
            now: { clock.value }
        )
    }

    /// The loop runs again, so the next snapshot differs from the last one.
    func loopRuns() {
        lastLoop.value = (lastLoop.value ?? now).addingTimeInterval(5 * 60)
    }

    func makeLinkedService() -> BaseAIAssistantsService {
        store.baseURL = baseURL
        store.tokens = tokens
        return makeService()
    }

    var linkedJustNow: AIAssistantsLinkState {
        .linked(host: "svc.example.com", lastUpload: now, lastError: nil)
    }

    // MARK: - Link and unlink

    @Test("Without stored tokens the service starts not linked") func initialStateNotLinkedWithoutTokens() {
        store.baseURL = baseURL
        #expect(makeService().state.value == .notLinked)
    }

    @Test("With stored tokens the service starts linked") func initialStateLinkedWithStoredTokens() {
        let service = makeLinkedService()
        #expect(service.state.value == .linked(host: "svc.example.com", lastUpload: nil, lastError: nil))
    }

    @Test("Completing the link saves the address and tokens, then uploads") func completeLinkSavesTokensAndUploads() async {
        let service = makeService()
        await service.completeLink(baseURL: baseURL, tokens: tokens, account: nil)
        #expect(store.baseURL == baseURL)
        #expect(store.tokens == tokens)
        #expect(api.calls == ["putStatus"])
        #expect(service.state.value == linkedJustNow)
    }

    @Test("Linking again registers the device again") func relinkRegistersDeviceAgain() async {
        // Unlink on the website deletes the device but leaves Trio's lastDevice behind.
        store.lastDevice = device
        pushDevice.value = device
        let service = makeService()
        await service.completeLink(baseURL: baseURL, tokens: tokens, account: nil)
        #expect(api.calls == ["putDevice", "putStatus"])
        #expect(store.lastDevice == device)
    }

    @Test("Linking again sends the status even if it hasn't changed") func relinkSendsUnchangedStatus() async {
        // The service has no status for a new link, for example after Unlink on the website.
        let service = makeLinkedService()
        await service.uploadNow()
        await service.completeLink(baseURL: baseURL, tokens: tokens, account: nil)
        #expect(api.calls == ["putStatus", "putStatus"])
    }

    @Test(
        "Unlinking deletes the device and clears the store, even if the delete fails"
    ) func unlinkDeletesDeviceAndClearsStoreEvenIfDeleteFails() async {
        store.lastDevice = device
        store.account = ann
        api.errors["deleteDevice"] = .network
        let service = makeLinkedService()
        let deleted = await service.unlink()
        #expect(deleted == false)
        #expect(api.calls == ["deleteDevice"])
        #expect(store.baseURL == nil)
        #expect(store.tokens == nil)
        #expect(store.lastDevice == nil)
        #expect(store.account == nil)
        #expect(service.account.value == nil)
        #expect(service.state.value == .notLinked)
    }

    @Test("Unlinking says the service deleted the device") func unlinkReportsDeletedDevice() async {
        let service = makeLinkedService()
        let deleted = await service.unlink()
        #expect(deleted == true)
        #expect(api.calls == ["deleteDevice"])
    }

    // MARK: - Account

    @Test("Completing the link saves and publishes the account") func completeLinkSavesAccount() async {
        let service = makeService()
        await service.completeLink(baseURL: baseURL, tokens: tokens, account: ann)
        #expect(store.account == ann)
        #expect(service.account.value == ann)
    }

    @Test("The account is published before the linked state") func accountPublishedBeforeLinkedState() async {
        let service = makeService()
        let accountWhenLinked = TestBox<AIAssistantsAccount??>(nil)
        let subscription = service.state.sink { state in
            if case .linked = state, accountWhenLinked.value == nil {
                accountWhenLinked.value = .some(service.account.value)
            }
        }
        await service.completeLink(baseURL: baseURL, tokens: tokens, account: ann)
        subscription.cancel()
        #expect(accountWhenLinked.value == .some(ann))
    }

    @Test("A stored account is published at launch") func storedAccountPublishedAtLaunch() {
        store.account = ann
        #expect(makeLinkedService().account.value == ann)
    }

    @Test("Linking again without an account forgets the old one") func relinkWithoutAccountForgetsOldOne() async {
        store.account = ann
        let service = makeService()
        await service.completeLink(baseURL: baseURL, tokens: tokens, account: nil)
        #expect(store.account == nil)
        #expect(service.account.value == nil)
    }

    // MARK: - Uploads

    @Test("An upload sends the built snapshot and records the time") func uploadSendsBuiltSnapshot() async {
        let service = makeLinkedService()
        await service.uploadNow()
        #expect(api.statuses.map(\.generatedAt) == [now])
        #expect(api.statuses.first?.units == "mg/dL")
        #expect(service.state.value == linkedJustNow)
        #expect(activity.events == ["begin AI Assistants upload", "end AI Assistants upload"])
    }

    @Test("An unchanged status isn't sent again") func unchangedStatusIsNotSentAgain() async {
        // Saving the Nightscout, Apple Health or Tidepool upload flags triggers an upload too.
        let service = makeLinkedService()
        await service.uploadNow()
        clock.value = now.addingTimeInterval(60)
        await service.uploadNow()
        #expect(api.calls == ["putStatus"])
        // The last upload time stays when nothing was sent.
        #expect(service.state.value == linkedJustNow)
    }

    @Test("A trigger keeps the app running until its upload finishes") func triggerKeepsAppRunningUntilUploadFinishes() async {
        let gate = UploadGate()
        api.statusGate = gate
        let service = makeLinkedService()
        triggers.send(())
        // Held from the trigger itself, so a locked phone isn't suspended during the debounce.
        #expect(activity.events == ["begin AI Assistants pending upload"])
        #expect(await eventuallyTrue { api.calls == ["putStatus"] })
        #expect(activity.events == ["begin AI Assistants pending upload", "begin AI Assistants upload"])
        gate.open()
        #expect(await eventuallyTrue { activity.events.count == 4 })
        #expect(
            activity.events == [
                "begin AI Assistants pending upload",
                "begin AI Assistants upload",
                "end AI Assistants upload",
                "end AI Assistants pending upload"
            ]
        )
        #expect(service.state.value == linkedJustNow)
    }

    @Test("Rapid triggers while linked upload once, after the debounce") func triggerWhileLinkedUploadsOnceAfterDebounce() async {
        let service = makeLinkedService()
        triggers.send(())
        triggers.send(())
        triggers.send(())
        #expect(api.calls.isEmpty)
        #expect(await eventuallyTrue { api.calls.count == 1 })
        await letDebouncePass()
        #expect(api.calls == ["putStatus"])
        #expect(service.state.value == linkedJustNow)
    }

    @Test("Each trigger renews the background activity") func eachTriggerRenewsBackgroundActivity() async {
        // iOS ends a background task after about 30 s, and a loop's saves can keep the debounce
        // going longer than that, so the trigger that ends a burst needs a fresh task.
        let service = makeLinkedService()
        triggers.send(())
        triggers.send(())
        #expect(
            activity.events == [
                "begin AI Assistants pending upload",
                "begin AI Assistants pending upload",
                "end AI Assistants pending upload"
            ]
        )
        #expect(await eventuallyTrue { activity.events.count == 6 })
        #expect(
            activity.events
                .suffix(3) == ["begin AI Assistants upload", "end AI Assistants upload", "end AI Assistants pending upload"]
        )
        #expect(service.state.value == linkedJustNow)
    }

    @Test("Triggers while not linked do nothing") func triggerWhileNotLinkedDoesNothing() async {
        let service = makeService()
        triggers.send(())
        await letDebouncePass()
        #expect(api.calls.isEmpty)
        #expect(activity.events.isEmpty)
        #expect(service.state.value == .notLinked)
    }

    @Test(
        "The device is registered once, then again only when its token changes"
    ) func registersDeviceOnceThenOnlyWhenTokenChanges(
    ) async {
        pushDevice.value = device
        let service = makeLinkedService()
        await service.uploadNow()
        loopRuns()
        await service.uploadNow()
        loopRuns()
        pushDevice.value = DeviceRegistration(
            apnsToken: String(repeating: "cd", count: 32),
            bundleId: device.bundleId,
            apnsEnvironment: device.apnsEnvironment,
            appVersion: device.appVersion
        )
        await service.uploadNow()
        #expect(api.calls == ["putDevice", "putStatus", "putStatus", "putDevice", "putStatus"])
        #expect(store.lastDevice == pushDevice.value)
    }

    @Test(
        "Without a push token, status still uploads; the device registers once one appears"
    ) func noPushTokenStillUploadsStatusAndRegistersLater(
    ) async {
        let service = makeLinkedService()
        await service.uploadNow()
        #expect(api.calls == ["putStatus"])
        #expect(service.state.value == linkedJustNow)
        pushDevice.value = device
        loopRuns()
        await service.uploadNow()
        #expect(api.calls == ["putStatus", "putDevice", "putStatus"])
        #expect(store.lastDevice == device)
    }

    @Test("A failed device registration doesn't block the status, and is retried") func deviceErrorStillUploadsStatus() async {
        pushDevice.value = device
        api.errors["putDevice"] = .http(400, "invalid_body")
        let service = makeLinkedService()
        await service.uploadNow()
        #expect(api.calls == ["putDevice", "putStatus"])
        #expect(store.lastDevice == nil)
        #expect(service.state.value == linkedJustNow)
        api.errors = [:]
        loopRuns()
        await service.uploadNow()
        #expect(api.calls == ["putDevice", "putStatus", "putDevice", "putStatus"])
        #expect(store.lastDevice == device)
    }

    @Test(
        "Offline keeps the link, shows Offline and doesn't retry until the next trigger"
    ) func networkErrorKeepsLinkedAndSetsOffline(
    ) async {
        api.errors["putStatus"] = .network
        let service = makeLinkedService()
        await service.uploadNow()
        #expect(service.state.value == .linked(host: "svc.example.com", lastUpload: nil, lastError: "Offline"))
        await letDebouncePass()
        #expect(api.calls == ["putStatus"])
        api.errors = [:]
        triggers.send(())
        #expect(await eventuallyTrue { service.state.value == linkedJustNow })
        #expect(api.calls == ["putStatus", "putStatus"])
    }

    @Test("A revoked link signs out and stops uploading") func signedOutStopsUploading() async {
        api.errors["putStatus"] = .signedOut
        let service = makeLinkedService()
        await service.uploadNow()
        #expect(service.state.value == .signedOut(host: "svc.example.com"))
        triggers.send(())
        await letDebouncePass()
        await service.uploadNow()
        #expect(api.calls == ["putStatus"])
        #expect(service.state.value == .signedOut(host: "svc.example.com"))
    }

    @Test("Signed out while registering the device: no status is sent") func signedOutDuringDeviceRegistrationStopsUpload() async {
        pushDevice.value = device
        api.errors["putDevice"] = .signedOut
        let service = makeLinkedService()
        await service.uploadNow()
        #expect(api.calls == ["putDevice"])
        #expect(service.state.value == .signedOut(host: "svc.example.com"))
    }

    @Test("Other errors are shown, and the last upload time is kept") func otherErrorShownAsLastError() async {
        let service = makeLinkedService()
        await service.uploadNow()
        api.errors["putStatus"] = .http(413, "too_large")
        loopRuns()
        await service.uploadNow()
        #expect(
            service.state
                .value == .linked(host: "svc.example.com", lastUpload: now, lastError: "Upload failed (error 413 too_large)")
        )
    }

    @Test("Uploads overlapping one in flight run at most one more upload") func overlappingTriggersRunAtMostOneExtraUpload() async {
        let gate = UploadGate()
        api.statusGate = gate
        let service = makeLinkedService()
        let first = Task { await service.uploadNow() }
        #expect(await eventuallyTrue { api.calls == ["putStatus"] })
        loopRuns()
        await service.uploadNow()
        await service.uploadNow()
        #expect(api.calls == ["putStatus"])
        gate.open()
        await first.value
        #expect(api.calls == ["putStatus", "putStatus"])
    }

    @Test(
        "Unlinking during an upload waits for it, then deletes the device and clears the store"
    ) func unlinkDuringUploadWaitsForItThenDeletesDevice() async {
        let gate = UploadGate()
        api.statusGate = gate
        // The upload refreshed its token, which writes the store.
        api.whenStatusSent = { [store, tokens] in store.tokens = tokens }
        let service = makeLinkedService()
        let upload = Task { await service.uploadNow() }
        #expect(await eventuallyTrue { api.calls == ["putStatus"] })
        let unlink = Task { await service.unlink() }
        await letDebouncePass()
        // No new upload starts while the link is ending.
        loopRuns()
        await service.uploadNow()
        #expect(api.calls == ["putStatus"])
        gate.open()
        await unlink.value
        await upload.value
        #expect(api.calls == ["putStatus", "deleteDevice"])
        #expect(store.baseURL == nil)
        #expect(store.tokens == nil)
        #expect(service.state.value == .notLinked)
    }

    // MARK: - Calls besides the uploads

    /// A check-in over the service's store and API, as the runtime makes it.
    func makeCheckIn() -> AIAssistantsCheckIn {
        let store = self.store
        return AIAssistantsCheckIn(
            api: api,
            coordinator: makeCoordinator(serviceReporter: ServiceRequestReporter(api: api)).coordinator,
            isLinked: { store.baseURL != nil && store.tokens != nil },
            loopRuns: Empty().eraseToAnyPublisher(),
            beginBackgroundActivity: activity.begin,
            removeDeliveredCheckIns: {}
        )
    }

    @Test("A check-in that finds Trio signed out shows signed out") func checkInSignedOutSignsOut() async {
        api.errors["getInbox"] = .signedOut
        let service = makeLinkedService()
        await makeCheckIn().checkIn(reason: .loop)
        #expect(service.state.value == .signedOut(host: "svc.example.com"))
    }

    @Test("A state report that finds Trio signed out shows signed out") func stateReportSignedOutSignsOut() async {
        api.errors["putRequestState"] = .signedOut
        let service = makeLinkedService()
        await ServiceRequestReporter(api: api).report(.expired, for: "r1")
        #expect(service.state.value == .signedOut(host: "svc.example.com"))
    }

    @Test("Signed out of another address leaves the link alone") func signedOutOfAnotherHostKeepsLink() async {
        api.errors["getInbox"] = .signedOut
        api.serviceURL = URL(string: "https://old.example.com")!
        let service = makeLinkedService()
        await makeCheckIn().checkIn(reason: .loop)
        #expect(service.state.value == .linked(host: "svc.example.com", lastUpload: nil, lastError: nil))
    }

    @Test(
        "Unlinking during a check-in waits for it, and no check-in starts until the link is gone"
    ) func unlinkDuringCheckInWaitsForIt() async {
        let gate = UploadGate()
        api.inboxGate = gate
        let service = makeLinkedService()
        let checkIn = makeCheckIn()
        service.checkIn = checkIn
        let running = Task { await checkIn.checkIn(reason: .push) }
        #expect(await eventuallyTrue { api.calls == ["getInbox"] })
        let unlink = Task { await service.unlink() }
        await letDebouncePass()
        #expect(api.calls == ["getInbox"])
        await checkIn.checkIn(reason: .loop)
        #expect(api.calls == ["getInbox"])
        gate.open()
        _ = await unlink.value
        await running.value
        #expect(api.calls == ["getInbox", "deleteDevice"])
        #expect(store.tokens == nil)
        #expect(service.state.value == .notLinked)

        // Linked again, the check-ins run again.
        await service.completeLink(baseURL: baseURL, tokens: tokens, account: nil)
        await checkIn.checkIn(reason: .loop)
        #expect(api.calls.suffix(2) == ["putStatus", "getInbox"])
    }

    // MARK: - App wiring

    @Test(
        "Loop runs, loop errors and changes to the watched entities trigger uploads"
    ) func appTriggersFireForLoopRunsAndWatchedEntities(
    ) async {
        let loopRuns = PassthroughSubject<Date, Never>()
        let loopErrors = PassthroughSubject<Error?, Never>()
        let changes = PassthroughSubject<Set<NSManagedObjectID>, Never>()
        let fired = TestBox(0)
        let subscription = BaseAIAssistantsService.appTriggers(
            lastLoopDate: loopRuns.eraseToAnyPublisher(),
            lastLoopError: loopErrors.eraseToAnyPublisher(),
            entityChanges: changes.eraseToAnyPublisher()
        )
        .sink { fired.value += 1 }
        let context = stack.newTaskContext()
        let (watched, forecast) = await context.perform {
            (
                [
                    GlucoseStored(context: context).objectID,
                    CarbEntryStored(context: context).objectID,
                    PumpEventStored(context: context).objectID,
                    OverrideStored(context: context).objectID,
                    TempTargetStored(context: context).objectID
                ],
                Forecast(context: context).objectID
            )
        }
        changes.send([forecast])
        #expect(fired.value == 0)
        for id in watched {
            changes.send([id])
        }
        #expect(fired.value == 5)
        loopRuns.send(now)
        #expect(fired.value == 6)
        // A failed loop doesn't set lastLoopDate, only lastError; clearing the error isn't news.
        loopErrors.send(nil)
        #expect(fired.value == 6)
        loopErrors.send(URLError(.timedOut))
        #expect(fired.value == 7)
        subscription.cancel()
    }

    @Test("The device registration needs a push token") func deviceRegistrationReadsPushTokenFromDefaults() throws {
        let suite = "AIAssistantsServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(BaseAIAssistantsService.currentDeviceRegistration(defaults: defaults) == nil)
        defaults.set("", forKey: "deviceToken")
        #expect(BaseAIAssistantsService.currentDeviceRegistration(defaults: defaults) == nil)

        defaults.set(device.apnsToken, forKey: "deviceToken")
        let sandbox = try #require(BaseAIAssistantsService.currentDeviceRegistration(defaults: defaults))
        #expect(sandbox.apnsToken == device.apnsToken)
        #expect(sandbox.apnsEnvironment == "sandbox")
        #expect(sandbox.bundleId == Bundle.main.bundleIdentifier)
        // The version Settings shows (1.0.2.12), not the build number.
        #expect(sandbox.appVersion == Bundle.main.appDevVersion ?? Bundle.main.releaseVersionNumber)
        #expect(sandbox.appVersion != Bundle.main.buildVersionNumber)

        defaults.set(true, forKey: "isAPNSProduction")
        #expect(BaseAIAssistantsService.currentDeviceRegistration(defaults: defaults)?.apnsEnvironment == "production")
    }

    @Test("The device registration has no watch until the watch sends its push token") func deviceRegistrationWatchNeedsToken() throws {
        let suite = "AIAssistantsServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(device.apnsToken, forKey: "deviceToken")
        let allowed = AIAssistantsPreferences(allowsMealRequests: true)
        #expect(BaseAIAssistantsService.currentDeviceRegistration(defaults: defaults, preferences: allowed)?.watch == nil)

        defaults.set("", forKey: "AIAssistants.watchPushToken")
        #expect(BaseAIAssistantsService.currentDeviceRegistration(defaults: defaults, preferences: allowed)?.watch == nil)

        let watchToken = String(repeating: "cd", count: 32)
        defaults.set(watchToken, forKey: "AIAssistants.watchPushToken")
        let sandbox = try #require(BaseAIAssistantsService.currentDeviceRegistration(defaults: defaults, preferences: allowed))
        #expect(sandbox.watch == WatchRegistration(
            apnsToken: watchToken,
            bundleId: "\(Bundle.main.bundleIdentifier ?? "").watchkitapp",
            apnsEnvironment: "sandbox"
        ))

        // The watch is pushed to through the phone's APNs environment.
        defaults.set(true, forKey: "isAPNSProduction")
        let production = BaseAIAssistantsService.currentDeviceRegistration(defaults: defaults, preferences: allowed)
        #expect(production?.watch?.apnsEnvironment == "production")
        #expect(production?.watch?.apnsToken == watchToken)
    }

    @Test("The device registration has no watch while meal requests are off") func deviceRegistrationWatchNeedsMealRequests(
    ) throws {
        let suite = "AIAssistantsServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(device.apnsToken, forKey: "deviceToken")
        let watchToken = String(repeating: "cd", count: 32)
        defaults.set(watchToken, forKey: "AIAssistants.watchPushToken")

        let off = BaseAIAssistantsService.currentDeviceRegistration(defaults: defaults, preferences: AIAssistantsPreferences())
        #expect(off != nil && off?.watch == nil)
        // No preferences, no runtime: no meal requests either.
        #expect(BaseAIAssistantsService.currentDeviceRegistration(defaults: defaults)?.watch == nil)
        let on = BaseAIAssistantsService.currentDeviceRegistration(
            defaults: defaults,
            preferences: AIAssistantsPreferences(allowsMealRequests: true)
        )
        #expect(on?.watch?.apnsToken == watchToken)
    }

    @Test("The device registration carries the wake-up push type of the preferences") func deviceRegistrationWakePushType() throws {
        let suite = "AIAssistantsServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(device.apnsToken, forKey: "deviceToken")
        // No preferences, no runtime: the service treats a missing type as passive.
        #expect(BaseAIAssistantsService.currentDeviceRegistration(defaults: defaults)?.wakePushType == nil)

        var preferences = AIAssistantsPreferences()
        let passive = BaseAIAssistantsService.currentDeviceRegistration(defaults: defaults, preferences: preferences)
        #expect(passive?.wakePushType == "passive")
        preferences.wakePushType = .timeSensitive
        let timeSensitive = BaseAIAssistantsService.currentDeviceRegistration(defaults: defaults, preferences: preferences)
        #expect(timeSensitive?.wakePushType == "timeSensitive")
        preferences.wakePushType = .background
        let background = BaseAIAssistantsService.currentDeviceRegistration(defaults: defaults, preferences: preferences)
        #expect(background?.wakePushType == "background")
    }

    @Test("A new watch or wake-up push type registers the device again") func changedWatchOrWakePushTypeRegistersDeviceAgain(
    ) async {
        let watch = WatchRegistration(
            apnsToken: String(repeating: "cd", count: 32),
            bundleId: "org.nightscout.TEAMID.trio.watchkitapp",
            apnsEnvironment: "sandbox"
        )
        func registration(watch: WatchRegistration?, wakePushType: String?) -> DeviceRegistration {
            DeviceRegistration(
                apnsToken: device.apnsToken,
                bundleId: device.bundleId,
                apnsEnvironment: device.apnsEnvironment,
                appVersion: device.appVersion,
                watch: watch,
                wakePushType: wakePushType
            )
        }
        let service = makeLinkedService()
        pushDevice.value = registration(watch: nil, wakePushType: "passive")
        await service.uploadNow()
        await service.uploadNow()
        #expect(api.calls == ["putDevice", "putStatus"])

        pushDevice.value = registration(watch: watch, wakePushType: "passive")
        await service.uploadNow()
        #expect(api.calls == ["putDevice", "putStatus", "putDevice"])
        #expect(store.lastDevice?.watch == watch)

        pushDevice.value = registration(watch: watch, wakePushType: "timeSensitive")
        await service.uploadNow()
        #expect(api.calls == ["putDevice", "putStatus", "putDevice", "putDevice"])
        #expect(store.lastDevice?.wakePushType == "timeSensitive")
    }

    @Test(
        "Turning meal requests on or off, or a new wake-up push type, uploads; the first value and other changes don't"
    ) func registrationPreferenceChangeUploads() async {
        // Each step gives the device registration a new value, so an upload shows as a `putDevice`.
        func registration(_ wakePushType: String) -> DeviceRegistration {
            DeviceRegistration(
                apnsToken: device.apnsToken,
                bundleId: device.bundleId,
                apnsEnvironment: device.apnsEnvironment,
                appVersion: device.appVersion,
                wakePushType: wakePushType
            )
        }
        let service = makeLinkedService()
        pushDevice.value = registration("passive")
        let preferences = CurrentValueSubject<AIAssistantsPreferences, Never>(AIAssistantsPreferences())
        service.uploadWhenRegistrationPreferencesChange(preferences.eraseToAnyPublisher())
        await letDebouncePass()
        #expect(api.calls.isEmpty)

        // Another preference changed.
        preferences.send(AIAssistantsPreferences(phoneBackupDelay: 30))
        await letDebouncePass()
        #expect(api.calls.isEmpty)

        // Meal requests on: the registration has the watch from now on.
        preferences.send(AIAssistantsPreferences(allowsMealRequests: true, phoneBackupDelay: 30))
        #expect(await eventuallyTrue { api.calls == ["putDevice", "putStatus"] })

        pushDevice.value = registration("timeSensitive")
        preferences.send(AIAssistantsPreferences(allowsMealRequests: true, phoneBackupDelay: 30, wakePushType: .timeSensitive))
        #expect(await eventuallyTrue { api.calls == ["putDevice", "putStatus", "putDevice"] })

        // Meal requests off: the watch goes.
        pushDevice.value = registration("background")
        preferences.send(AIAssistantsPreferences(phoneBackupDelay: 30, wakePushType: .timeSensitive))
        #expect(await eventuallyTrue { api.calls == ["putDevice", "putStatus", "putDevice", "putDevice"] })

        // The same values again aren't a change.
        pushDevice.value = registration("passive")
        preferences.send(AIAssistantsPreferences(phoneBackupDelay: 60, wakePushType: .timeSensitive))
        await letDebouncePass()
        #expect(api.calls == ["putDevice", "putStatus", "putDevice", "putDevice"])
    }
}
