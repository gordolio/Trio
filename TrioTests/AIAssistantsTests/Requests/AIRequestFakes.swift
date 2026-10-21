import Combine
import Foundation
import Testing

@testable import Trio

/// When the coordinator tests start. Whole seconds, so a signed `answeredAt` compares exactly.
let coordinatorTestStart = Date(timeIntervalSince1970: 1_792_000_000)

/// A meal request created at `coordinatorTestStart`. It expires 5 minutes later.
func meal(id: String, carbs: Decimal = 20, fat: Decimal = 10, protein: Decimal = 8) -> AIMealRequest {
    AIMealRequest(
        id: id,
        source: "ChatGPT",
        description: "slice of pizza",
        carbs: carbs,
        fat: fat,
        protein: protein,
        createdAt: coordinatorTestStart,
        expiresAt: coordinatorTestStart + 5 * 60
    )
}

final class FakeTreatments: AIRequestTreatments {
    private let lock = NSLock()
    private var checkedUnits: [Decimal] = []
    private var checkedSinceDates: [Date] = []
    private var carbsCheckedAfter: [Date] = []
    private var storedRequests: [AIMealRequest] = []
    private var enactedUnits: [Decimal] = []
    private var recordedEvents: [String] = []
    private var checkHook: (() async -> Void)?
    private var storeHook: (() async -> Void)?
    private var enactHook: (() async -> Void)?

    var limits = AIRequestLimits(maxCarbs: 250, maxFat: 250, maxProtein: 250)
    /// What `dose(forCarbs:)` returns: 1.2 U, worked out on a loop run a minute before the tests start.
    var doseResult = AIRequestDose(units: 1.2, iobAsOf: coordinatorTestStart - 60)
    /// What `checkBolus` returns: `nil` allows the bolus.
    var checkResult: String?
    /// What `carbsLogged(after:)` returns: `true` means carbs were logged after the date.
    var carbsLoggedResult = false
    /// What `enactBolus` returns: `nil` means the pump accepted it.
    var enactResult: String?
    var storeError: Error?

    /// Runs once, inside the next `checkBolus`, while the coordinator waits for it.
    var whileCheckingBolus: (() async -> Void)? {
        get { lock.withLock { checkHook } }
        set { lock.withLock { checkHook = newValue } }
    }

    /// Runs once, inside the next `storeCarbs`, while the coordinator waits for it.
    var whileStoringCarbs: (() async -> Void)? {
        get { lock.withLock { storeHook } }
        set { lock.withLock { storeHook = newValue } }
    }

    /// Runs once, inside the next `enactBolus`, while the coordinator waits for it.
    var whileEnactingBolus: (() async -> Void)? {
        get { lock.withLock { enactHook } }
        set { lock.withLock { enactHook = newValue } }
    }

    var checked: [Decimal] { lock.withLock { checkedUnits } }
    /// The `since` of each `checkBolus` call.
    var checkedSince: [Date] { lock.withLock { checkedSinceDates } }
    /// The `after` of each `carbsLogged(after:)` call.
    var carbsLoggedAfter: [Date] { lock.withLock { carbsCheckedAfter } }
    var stored: [AIMealRequest] { lock.withLock { storedRequests } }
    var enacted: [Decimal] { lock.withLock { enactedUnits } }
    /// Every call in order: `check <units>`, `store <id>`, `enact <units>` and, when it returns, `enacted <units>`.
    var events: [String] { lock.withLock { recordedEvents } }

    func dose(forCarbs _: Decimal) async -> AIRequestDose {
        doseResult
    }

    func display(for request: AIMealRequest, units: Decimal) async -> AIRequestDisplay {
        AIRequestDisplay(title: "\(request.source): \(request.description)", body: "\(request.carbs) g carbs · \(units) U")
    }

    func checkBolus(_ units: Decimal, since: Date) async -> String? {
        let hook = lock.withLock {
            checkedUnits.append(units)
            checkedSinceDates.append(since)
            recordedEvents.append("check \(units)")
            defer { checkHook = nil }
            return checkHook
        }
        await hook?()
        return checkResult
    }

    func carbsLogged(after date: Date) async -> Bool {
        lock.withLock { carbsCheckedAfter.append(date) }
        return carbsLoggedResult
    }

    func storeCarbs(for request: AIMealRequest) async throws {
        let hook = lock.withLock {
            defer { storeHook = nil }
            return storeHook
        }
        await hook?()
        if let storeError { throw storeError }
        lock.withLock {
            storedRequests.append(request)
            recordedEvents.append("store \(request.id)")
        }
    }

    func enactBolus(_ units: Decimal) async -> String? {
        let hook = lock.withLock {
            enactedUnits.append(units)
            recordedEvents.append("enact \(units)")
            defer { enactHook = nil }
            return enactHook
        }
        await hook?()
        lock.withLock { recordedEvents.append("enacted \(units)") }
        return enactResult
    }
}

final class FakeWatch: AIRequestWatchDelivery {
    private let lock = NSLock()
    private var deliveredPrompts: [AIRequestPrompt] = []
    private var withdrawnIDs: [String] = []

    var isWatchAvailable = true

    var delivered: [AIRequestPrompt] { lock.withLock { deliveredPrompts } }
    var withdrawn: [String] { lock.withLock { withdrawnIDs } }

    func deliver(_ prompt: AIRequestPrompt) {
        lock.withLock { deliveredPrompts.append(prompt) }
    }

    func withdraw(id: String) {
        lock.withLock { withdrawnIDs.append(id) }
    }
}

final class FakePhoneBackup: AIRequestPhoneBackupScheduling {
    private let lock = NSLock()
    private var scheduledBackups: [(id: String, delay: TimeInterval, askedOn: AIRequestAskedOn)] = []
    private var cancelledIDs: [String] = []

    var scheduled: [(id: String, delay: TimeInterval, askedOn: AIRequestAskedOn)] { lock.withLock { scheduledBackups } }
    var cancelled: [String] { lock.withLock { cancelledIDs } }

    func schedule(_ prompt: AIRequestPrompt, after delay: TimeInterval, askedOn: AIRequestAskedOn) {
        lock.withLock { scheduledBackups.append((prompt.id, delay, askedOn)) }
    }

    func cancel(id: String) {
        lock.withLock { cancelledIDs.append(id) }
    }
}

final class RecordingReporter: AIRequestReporter {
    private let lock = NSLock()
    private var recorded: [(id: String, report: AIRequestReport)] = []

    var reports: [(id: String, report: AIRequestReport)] { lock.withLock { recorded } }
    /// Each report as `"<id>:<state>"`.
    var states: [String] { reports.map { "\($0.id):\($0.report.state.rawValue)" } }

    /// The reports for one request, in order.
    func reports(for id: String) -> [AIRequestReport] {
        reports.filter { $0.id == id }.map(\.report)
    }

    func report(_ report: AIRequestReport, for id: String) async {
        lock.withLock { recorded.append((id, report)) }
    }
}

/// Where a coordinator keeps its state. A second coordinator on the same files is a relaunch.
struct CoordinatorFiles {
    let seen: URL
    /// The coordinator keeps its final reports in the same folder.
    let pending: URL

    /// Files in a new folder of their own.
    static func temporary() -> CoordinatorFiles {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ai-requests-\(UUID().uuidString)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return CoordinatorFiles(
            seen: folder.appendingPathComponent("seen-requests.json"),
            pending: folder.appendingPathComponent("pending-request.json")
        )
    }
}

/// A coordinator over fakes, its clock, and the prompts it asked with.
final class CoordinatorHarness {
    let coordinator: AIRequestCoordinator
    /// Gets every report, unless a service reporter was given; then it gets the local ones only.
    let reporter: RecordingReporter
    let treatments: FakeTreatments
    let watch: FakeWatch
    let backup: FakePhoneBackup
    let keys: AIRequestKeyStore
    let files: CoordinatorFiles

    private let clock: TestBox<Date>
    private let lock = NSLock()
    private var promptsByID: [String: AIRequestPrompt] = [:]
    private var subscription: AnyCancellable?

    /// What the coordinator's `now()` returns.
    var now: Date {
        get { clock.value }
        set { clock.value = newValue }
    }

    init(
        dose: Decimal,
        watchAvailable: Bool,
        limits: AIRequestLimits,
        preferences: AIAssistantsPreferences,
        files: CoordinatorFiles,
        now: Date,
        serviceReporter: AIRequestReporter?
    ) {
        let clock = TestBox(now)
        let reporter = RecordingReporter()
        let treatments = FakeTreatments()
        let watch = FakeWatch()
        let backup = FakePhoneBackup()
        let keys = AIRequestKeyStore(keychain: InMemoryAIRequestKeychain())
        treatments.doseResult = AIRequestDose(units: dose, iobAsOf: treatments.doseResult.iobAsOf)
        treatments.limits = limits
        watch.isWatchAvailable = watchAvailable
        self.clock = clock
        self.reporter = reporter
        self.treatments = treatments
        self.watch = watch
        self.backup = backup
        self.keys = keys
        self.files = files
        coordinator = AIRequestCoordinator(
            seen: AIRequestSeenStore(fileURL: files.seen, now: { clock.value }),
            pendingFileURL: files.pending,
            keys: keys,
            preferences: { preferences },
            treatments: treatments,
            watch: watch,
            phoneBackup: backup,
            reporters: [.service: serviceReporter ?? reporter, .local: reporter],
            now: { clock.value }
        )
        subscription = coordinator.current
            .compactMap { $0?.prompt }
            .sink { [weak self] prompt in
                guard let self else { return }
                lock.withLock { self.promptsByID[prompt.id] = prompt }
            }
    }

    /// The prompt the coordinator asked with for `id`. It stays available after the request leaves pending.
    func prompt(_ id: String) -> AIRequestPrompt {
        if let prompt = lock.withLock({ promptsByID[id] }) { return prompt }
        Issue.record("No prompt was asked for \(id)")
        return AIRequestPrompt(
            id: id,
            source: "",
            description: "",
            shown: AIRequestShown(carbs: "", fat: "", protein: "", units: ""),
            title: "",
            body: "",
            expiresAt: .distantPast,
            approvalStyle: .twoStep,
            answerRoute: .both,
            answerToken: nil,
            answerURL: nil
        )
    }
}

/// A coordinator over fakes. Its preferences allow meal requests, which are off until the wearer turns them on.
func makeCoordinator(
    dose: Decimal = 1.2,
    watchAvailable: Bool = true,
    limits: AIRequestLimits = AIRequestLimits(maxCarbs: 250, maxFat: 250, maxProtein: 250),
    preferences: AIAssistantsPreferences = AIAssistantsPreferences(allowsMealRequests: true),
    files: CoordinatorFiles = .temporary(),
    now: Date = coordinatorTestStart,
    serviceReporter: AIRequestReporter? = nil
) -> CoordinatorHarness {
    CoordinatorHarness(
        dose: dose,
        watchAvailable: watchAvailable,
        limits: limits,
        preferences: preferences,
        files: files,
        now: now,
        serviceReporter: serviceReporter
    )
}

/// A pending-request file as Trio wrote it before it recorded `receivedAt`, `iobAsOf` and `phoneAskAt`: a request
/// from `meal(id:)`, asked on the watch, with the dose `units`.
func oldPendingJSON(id: String, units: String) throws -> Data {
    let request = meal(id: id)
    let dose = try #require(Decimal(string: units))
    let shown = AIRequestShown(carbs: request.carbs, fat: request.fat, protein: request.protein, units: dose)
    let pending = PendingAIRequest(
        request: request,
        channel: .service,
        prompt: AIRequestPrompt(
            id: id,
            source: request.source,
            description: request.description,
            shown: shown,
            title: "\(request.source): \(request.description)",
            body: "\(request.carbs) g carbs · \(shown.units) U",
            expiresAt: request.expiresAt,
            approvalStyle: .twoStep,
            answerRoute: .both,
            answerToken: nil,
            answerURL: nil
        ),
        askedOn: .watch,
        units: dose
    )
    var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(pending)) as? [String: Any])
    for key in ["receivedAt", "iobAsOf", "phoneAskAt"] {
        object.removeValue(forKey: key)
    }
    return try JSONSerialization.data(withJSONObject: object)
}
