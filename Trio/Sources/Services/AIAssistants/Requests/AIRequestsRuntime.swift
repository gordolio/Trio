import Combine
import Foundation
import Swinject
import UIKit
import UserNotifications
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
    /// Sends each outcome to the watch and the notifier, for as long as the runtime lives.
    private let outcomeSubscription: AnyCancellable

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
        let relay = WatchRelay()
        let watchLink = AIRequestWatchLink(
            session: WCSession.default,
            keys: keys,
            onAnswer: { relay.forward($0) },
            onViewing: { relay.viewing($0) },
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
        relay.coordinator = coordinator

        // Subscribed here, before anything can start the coordinator: `outcomes` has no replay, and `start()` can send
        // one at once, for an approval that Trio stopped carrying out. A later subscriber would miss it.
        // The sheet counts as showing a request only while Trio is in front. Both are read on the main queue, where the
        // outcomes are received.
        let notifier = AIRequestsRuntime.makeNotifier(
            center: UNUserNotificationCenter.current(),
            presentedID: { MainActor.assumeIsolated { AIRequestPhoneApprovalPresenter.shared.presented?.id } },
            isAppActive: { MainActor.assumeIsolated { UIApplication.shared.applicationState == .active } }
        )
        outcomeSubscription = coordinator.outcomes
            .receive(on: DispatchQueue.main)
            .sink { outcome in
                AIRequestsRuntime.publish(outcome, to: watchLink, notifier: notifier)
            }

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

extension AIRequestsRuntime {
    /// The notifier for failures after an approval. It skips a request only while the approval sheet is showing it to
    /// the wearer: the sheet is presenting it, and Trio is in front. The sheet stays presented through "Checking…" and
    /// its result, so a wearer who approves and then locks the phone or switches apps still gets the notification.
    /// `presentedID` and `isAppActive` are read on the main queue.
    static func makeNotifier(
        center: AIRequestNotificationScheduling,
        presentedID: @escaping () -> String?,
        isAppActive: @escaping () -> Bool
    ) -> AIRequestResultNotifier {
        AIRequestResultNotifier(center: center, isShowing: { id in isAppActive() && presentedID() == id })
    }

    /// Tells the watch and the iPhone how a request ended. The watch hears the result of a request it was asked, and
    /// the notifier decides whether the iPhone needs a notification.
    static func publish(
        _ outcome: AIRequestOutcome,
        to watchLink: AIRequestWatchLink,
        notifier: AIRequestResultNotifier
    ) {
        if outcome.askedOn == .watch {
            watchLink.sendResult(AIRequestResultText.message(for: outcome))
        }
        notifier.notify(outcome)
    }
}

/// Hands what the watch sends to the coordinator, which is made after the link that receives it. It is set before
/// anything can reach the link.
private final class WatchRelay {
    var coordinator: AIRequestCoordinator?

    func forward(_ answer: AIRequestAnswer) {
        guard let coordinator else { return }
        Task { _ = await coordinator.answer(.watch(answer)) }
    }

    /// The watch opened the approval screen of the request with this ID.
    func viewing(_ id: String) {
        guard let coordinator else { return }
        Task { await coordinator.postponePhoneBackup(id: id) }
    }
}

/// Reports the debug request's states, which have nowhere to go: it logs the ID and the state, nothing else.
final class LoggingReporter: AIRequestReporter {
    func report(_ report: AIRequestReport, for id: String) async {
        debug(.service, "AI requests: reported \(id) as \(report.state.rawValue)")
    }
}
