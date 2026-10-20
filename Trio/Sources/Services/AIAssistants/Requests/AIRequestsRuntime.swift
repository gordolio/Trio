import Combine
import Foundation
import Swinject
import WatchConnectivity

/// Everything that handles an AI assistant's requests, built once at launch. The hooks in
/// the upstream files reach it through `shared`.
final class AIRequestsRuntime {
    /// Set by the service at launch, and read by the hooks on other threads. Setting it also gives the watch
    /// messages that arrived before it to its link.
    static var shared: AIRequestsRuntime? {
        get { sharedLock.withLock { installed } }
        set {
            sharedLock.withLock { installed = newValue }
            AIRequestHooks.watchMessages.install(newValue.map { runtime in { runtime.watchLink.receive($0) } })
        }
    }

    private static let sharedLock = NSLock()
    private static var installed: AIRequestsRuntime?

    let coordinator: AIRequestCoordinator
    let watchLink: AIRequestWatchLink
    let phoneBackup: AIRequestPhoneBackupScheduling
    /// The one store of the request preferences, so a change in the settings reaches the coordinator.
    let preferences: AIAssistantsPreferencesStore
    let checkIn: AIAssistantsCheckIn

    /// `isLinked` says whether Trio is linked to the service, and `loopRuns` sends each loop run's date.
    /// `uploadNow` registers the device with the service again, which a new watch push token needs.
    init(
        resolver: Resolver,
        api: AIAssistantsAPIClient,
        isLinked: @escaping () -> Bool,
        loopRuns: AnyPublisher<Date, Never>,
        uploadNow: @escaping () -> Void
    ) {
        let preferences = AIAssistantsPreferencesStore()
        let keys = AIRequestKeyStore()
        // The seen store creates the folder that the pending request is kept in.
        let seen = AIRequestSeenStore.appDefault()
        let pendingFileURL = URL.applicationSupportDirectory
            .appendingPathComponent("AIAssistants", isDirectory: true)
            .appendingPathComponent("pending-request.json")

        // The link forwards answers to the coordinator, which needs the link to reach the watch.
        let answers = WatchAnswerRelay()
        let watchLink = AIRequestWatchLink(
            session: WCSession.default,
            keys: keys,
            onAnswer: { answers.forward($0) },
            onWatchTokenChanged: uploadNow
        )
        let phoneBackup = AIRequestPhoneBackup()
        let coordinator = AIRequestCoordinator(
            seen: seen,
            pendingFileURL: pendingFileURL,
            keys: keys,
            preferences: { preferences.value },
            treatments: BaseAIRequestTreatments(resolver: resolver),
            watch: watchLink,
            phoneBackup: phoneBackup,
            reporters: [.service: ServiceRequestReporter(api: api), .local: LoggingReporter()]
        )
        answers.coordinator = coordinator

        self.coordinator = coordinator
        self.watchLink = watchLink
        self.phoneBackup = phoneBackup
        self.preferences = preferences
        checkIn = AIAssistantsCheckIn(
            api: api,
            coordinator: coordinator,
            isLinked: isLinked,
            loopRuns: loopRuns,
            beginBackgroundActivity: BaseAIAssistantsService.beginBackgroundTask(named:),
            removeDeliveredCheckIns: AIAssistantsCheckIn.removeDeliveredCheckIns
        )
    }
}

/// Hands the watch's answers to the coordinator, which is made after the link that receives them. It is set
/// before anything can reach the link.
private final class WatchAnswerRelay {
    var coordinator: AIRequestCoordinator?

    func forward(_ answer: AIRequestAnswer) {
        guard let coordinator else { return }
        Task { _ = await coordinator.answer(.watch(answer)) }
    }
}

/// Reports the debug request's states, which have nowhere to go: it logs the ID and the state, nothing else.
final class LoggingReporter: AIRequestReporter {
    func report(_ report: AIRequestReport, for id: String) async {
        debug(.service, "AI requests: reported \(id) as \(report.state.rawValue)")
    }
}
