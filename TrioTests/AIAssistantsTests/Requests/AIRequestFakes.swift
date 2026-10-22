import Combine
import Foundation
import Testing

@testable import Trio

/// When the coordinator tests start. Whole seconds.
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

/// The meal a `storeCarbs` call stored.
struct StoredCarbs: Equatable {
    let id: String
    let carbs: Decimal
    let fat: Decimal
    let protein: Decimal
}

final class FakeTreatments: AIRequestTreatments {
    private let lock = NSLock()
    private var storedRequests: [AIMealRequest] = []
    private var storedMeals: [StoredCarbs] = []
    private var enactedUnits: [Decimal] = []
    private var recordedEvents: [String] = []
    private var reasonUnits: [Decimal] = []
    private var storeHook: (() async -> Void)?
    private var enactHook: (() async -> Void)?

    var limits = AIRequestLimits(maxCarbs: 250, maxFat: 250, maxProtein: 250, maxBolus: 10)
    /// The wearer's "Enable Fat and Protein Entries": on, so a request's fat and protein are logged.
    var logsFatAndProtein = true
    /// What `dose(forCarbs:)` returns: 1.2 U.
    var doseResult = AIRequestDose(units: 1.2)
    /// What `noDoseReason(units:)` returns.
    var noDoseReasonResult: String?
    /// What `enactBolus` returns: `nil` means the pump accepted it.
    var enactResult: String?
    var storeError: Error?

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

    /// The `units` of each `noDoseReason(units:)` call.
    var reasonedUnits: [Decimal] { lock.withLock { reasonUnits } }
    var stored: [AIMealRequest] { lock.withLock { storedRequests } }
    /// What each `storeCarbs` stored.
    var storedCarbs: [StoredCarbs] { lock.withLock { storedMeals } }
    var enacted: [Decimal] { lock.withLock { enactedUnits } }
    /// Every call in order: `store <id>`, `enact <units>` and, when it returns, `enacted <units>`.
    var events: [String] { lock.withLock { recordedEvents } }

    func dose(forCarbs _: Decimal) async -> AIRequestDose {
        doseResult
    }

    func noDoseReason(units: Decimal) async -> String? {
        lock.withLock { reasonUnits.append(units) }
        return noDoseReasonResult
    }

    func storeCarbs(for request: AIMealRequest, carbs: Decimal, fat: Decimal, protein: Decimal) async throws {
        let hook = lock.withLock {
            defer { storeHook = nil }
            return storeHook
        }
        await hook?()
        if let storeError { throw storeError }
        lock.withLock {
            storedRequests.append(request)
            storedMeals.append(StoredCarbs(id: request.id, carbs: carbs, fat: fat, protein: protein))
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
    var isWatchAvailable = true
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
    private var reportHook: ((AIRequestReport) -> Void)?

    /// Runs inside each `report`, before it's recorded.
    var whileReporting: ((AIRequestReport) -> Void)? {
        get { lock.withLock { reportHook } }
        set { lock.withLock { reportHook = newValue } }
    }

    var reports: [(id: String, report: AIRequestReport)] { lock.withLock { recorded } }
    /// Each report as `"<id>:<state>"`.
    var states: [String] { reports.map { "\($0.id):\($0.report.state.rawValue)" } }

    /// The reports for one request, in order.
    func reports(for id: String) -> [AIRequestReport] {
        reports.filter { $0.id == id }.map(\.report)
    }

    func report(_ report: AIRequestReport, for id: String) async {
        whileReporting?(report)
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

/// One `left` the coordinator sent.
struct LeftEvent: Equatable {
    let id: String
    let left: AIRequestLeft
    let source: String
}

/// A coordinator over fakes, its clock, the prompts it asked with, and each `left` it sent.
final class CoordinatorHarness {
    let coordinator: AIRequestCoordinator
    /// Gets every report, unless a service reporter was given; then it gets none.
    let reporter: RecordingReporter
    let treatments: FakeTreatments
    let watch: FakeWatch
    let backup: FakePhoneBackup
    let files: CoordinatorFiles

    private let clock: TestBox<Date>
    private let lock = NSLock()
    private var promptsByID: [String: AIRequestPrompt] = [:]
    private var leftEvents: [LeftEvent] = []
    private var subscription: AnyCancellable?
    private var leftSubscription: AnyCancellable?

    /// Each `left` the coordinator sent, in order.
    var left: [LeftEvent] { lock.withLock { leftEvents } }

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
        treatments.doseResult = AIRequestDose(units: dose)
        treatments.limits = limits
        watch.isWatchAvailable = watchAvailable
        self.clock = clock
        self.reporter = reporter
        self.treatments = treatments
        self.watch = watch
        self.backup = backup
        self.files = files
        coordinator = AIRequestCoordinator(
            seen: AIRequestSeenStore(fileURL: files.seen, now: { clock.value }),
            pendingFileURL: files.pending,
            preferences: { preferences },
            treatments: treatments,
            watch: watch,
            phoneBackup: backup,
            reporters: [.service: serviceReporter ?? reporter],
            now: { clock.value }
        )
        subscription = coordinator.current
            .compactMap { $0?.prompt }
            .sink { [weak self] prompt in
                guard let self else { return }
                lock.withLock { self.promptsByID[prompt.id] = prompt }
            }
        leftSubscription = coordinator.left
            .sink { [weak self] event in
                guard let self else { return }
                lock.withLock { self.leftEvents.append(LeftEvent(id: event.id, left: event.left, source: event.source)) }
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
            expiresAt: .distantPast
        )
    }
}

/// A coordinator over fakes. Its preferences allow meal requests, which are off until the wearer turns them on.
func makeCoordinator(
    dose: Decimal = 1.2,
    watchAvailable: Bool = true,
    limits: AIRequestLimits = AIRequestLimits(maxCarbs: 250, maxFat: 250, maxProtein: 250, maxBolus: 10),
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

/// A pending-request file as the build before this one wrote it, with the approval style, answer route and answer token
/// in its prompt, and the loop run its dose was worked out on: a request from `meal(id:)`, asked on the watch, with the
/// dose `units`.
func previousBuildPendingJSON(id: String, units: String) throws -> Data {
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
            expiresAt: request.expiresAt
        ),
        askedOn: .watch,
        units: dose,
        receivedAt: coordinatorTestStart,
        phoneAskAt: coordinatorTestStart + 15
    )
    var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(pending)) as? [String: Any])
    object["iobAsOf"] = coordinatorTestStart.timeIntervalSinceReferenceDate
    var prompt = try #require(object["prompt"] as? [String: Any])
    prompt["approvalStyle"] = "oneGesture"
    prompt["answerRoute"] = "serviceOnly"
    prompt["answerToken"] = "token"
    object["prompt"] = prompt
    return try JSONSerialization.data(withJSONObject: object)
}
