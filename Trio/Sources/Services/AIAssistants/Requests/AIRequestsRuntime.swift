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

        // The link forwards what the watch sends to the coordinator, which needs the link to reach the watch.
        let relay = WatchRelay()
        let watchLink = AIRequestsRuntime.makeWatchLink(
            session: WCSession.default,
            keys: keys,
            relay: relay,
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
            reporters: [.service: ServiceRequestReporter(api: api)]
        )
        // Subscribed here too, before anything can start the coordinator: `left` has no replay either, and `start()` can
        // expire the request that was pending when Trio quit.
        relay.connect(coordinator: coordinator, link: watchLink)

        // Subscribed here, before anything can start the coordinator: `outcomes` has no replay, and `start()` can send
        // one at once, for an approval that Trio stopped carrying out. A later subscriber would miss it.
        // The Treatments sheet counts as showing a request only while Trio is in front. Both are read on the main queue,
        // where the outcomes are received.
        let notifier = AIRequestsRuntime.makeNotifier(
            center: UNUserNotificationCenter.current(),
            presentedID: { MainActor.assumeIsolated { AIRequestTreatmentsSession.shared.requestID } },
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
    /// The link to the watch, handing what the watch sends to `relay`. The watch's open, confirm and close take a
    /// while to carry out, so each one runs on a task of its own.
    static func makeWatchLink(
        session: AIRequestWatchSession,
        keys: AIRequestKeyStore,
        defaults: UserDefaults = .standard,
        relay: WatchRelay,
        onWatchTokenChanged: @escaping () -> Void
    ) -> AIRequestWatchLink {
        AIRequestWatchLink(
            session: session,
            keys: keys,
            defaults: defaults,
            onAnswer: { relay.forward($0) },
            onViewing: { relay.viewing($0) },
            onOpen: { id in Task { await relay.open(id) } },
            onConfirm: { confirm in Task { await relay.confirm(confirm) } },
            onClose: { close in Task { await relay.close(close) } },
            onWatchTokenChanged: onWatchTokenChanged
        )
    }

    /// The notifier for failures after an approval. It skips a request only while its Treatments sheet is up and Trio is in
    /// front. `presentedID` and `isAppActive` are read on the main queue.
    static func makeNotifier(
        center: AIRequestNotificationScheduling,
        presentedID: @escaping () -> String?,
        isAppActive: @escaping () -> Bool
    ) -> AIRequestResultNotifier {
        AIRequestResultNotifier(center: center, isShowing: { id in isAppActive() && presentedID() == id })
    }

    /// Tells the watch and the iPhone how a request ended. The watch hears the result of a request it was asked or that
    /// Trio showed it, and the notifier decides whether the iPhone needs a notification.
    static func publish(
        _ outcome: AIRequestOutcome,
        to watchLink: AIRequestWatchLink,
        notifier: AIRequestResultNotifier
    ) {
        if outcome.reachesWatch {
            watchLink.sendResult(AIRequestResultText.message(for: outcome))
        }
        notifier.notify(outcome)
    }
}

/// Hands what the watch sends to the coordinator, and tells the watch what comes of it: the request's details when it
/// opens one, the acknowledgement of its confirmation, and the ending of a request that leaves pending. The coordinator
/// is made after the link that receives the watch's messages, and needs that link, so the relay is connected to both
/// once they exist, before anything can reach the link.
final class WatchRelay {
    /// Why a request left pending, as the coordinator said.
    private typealias Left = (id: String, left: AIRequestLeft, source: String)

    private struct Connection {
        let coordinator: AIRequestCoordinator
        let link: AIRequestWatchLink
    }

    /// How many requests' endings the relay remembers. The wearer is only ever asked one at a time, so a confirm that
    /// finds its request gone is for one of the last few.
    private static let rememberedEndings = 20
    /// Upstream's own texts for the bolus and carbs it acknowledges, so the watch says the same as for its own bolus.
    private static let bolusEnactedText = String(
        localized: "Bolus enacted successfully.",
        comment: "Success message for enacting a bolus"
    )
    private static let carbsLoggedText = String(
        localized: "Carbs logged successfully.",
        comment: "Success message sent to watch when carbs are logged successfully"
    )

    private let lock = NSLock()
    private var connection: Connection?
    /// The last endings, oldest first.
    private var endings: [Left] = []
    private var leftSubscription: AnyCancellable?

    private var current: Connection? { lock.withLock { connection } }

    /// Connects the relay to the coordinator and the link, and sends the watch each `left` of the coordinator, from the
    /// main queue, for as long as the relay lives.
    func connect(coordinator: AIRequestCoordinator, link: AIRequestWatchLink) {
        lock.withLock { connection = Connection(coordinator: coordinator, link: link) }
        // The ending is remembered as it's sent, before the main queue gets it, so a confirm that finds the request gone
        // already knows why.
        leftSubscription = coordinator.left
            .handleEvents(receiveOutput: { [weak self] event in self?.remember(event) })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.sendEnded(event) }
    }

    func forward(_ answer: AIRequestAnswer) {
        guard let coordinator = current?.coordinator else { return }
        Task { _ = await coordinator.answer(.watch(answer)) }
    }

    /// The watch opened the approval screen of the request with this ID.
    func viewing(_ id: String) {
        guard let coordinator = current?.coordinator else { return }
        Task { await coordinator.postponePhoneBackup(id: id) }
    }

    /// The wearer opened the request on the watch. It's answered with the request's details, or with nothing when the
    /// request isn't pending, so the watch's own wait for them runs out.
    func open(_ id: String) async {
        guard let connection = current else { return }
        guard let details = await connection.coordinator.open(id: id, on: .watch) else { return }
        connection.link.sendDetails(details)
    }

    /// The wearer confirmed on the watch. It's carried out, and the watch is told how it went. A request that isn't
    /// pending any more is not carried out.
    func confirm(_ confirm: AIRequestWatchConfirm) async {
        guard let connection = current else { return }
        let report = await connection.coordinator.carryOutWatchConfirm(confirm)
        guard let acknowledgment = acknowledgment(for: report, id: confirm.id) else { return }
        connection.link.sendAcknowledgment(success: acknowledgment.success, message: acknowledgment.message)
    }

    /// The wearer left the request's screens on the watch, or swiped its notification away.
    func close(_ close: AIRequestWatchClose) async {
        guard let coordinator = current?.coordinator else { return }
        await coordinator.close(id: close.id, on: .watch, dismissed: close.dismissed)
    }

    // MARK: Acknowledging

    /// What the watch is told about its confirmation, or `nil` if it's told nothing. `report` is `nil` when the
    /// request wasn't pending, and then nothing was logged: the watch is told why, in the words the other screen
    /// closed with.
    private func acknowledgment(for report: AIRequestReport?, id: String) -> (success: Bool, message: String)? {
        switch report {
        case .delivering?:
            return (true, Self.bolusEnactedText)
        case .logged?:
            return (true, Self.carbsLoggedText)
        case let .failed(reason, _)?:
            return (false, reason)
        case .declined?,
             .expired?,
             nil,
             .pending?,
             .replaced?,
             .withdrawn?:
            return lateAcknowledgment(forRequest: id)
        }
    }

    private func lateAcknowledgment(forRequest id: String) -> (success: Bool, message: String)? {
        guard let ending = lock.withLock({ endings.last { $0.id == id } }) else {
            // The request ended before Trio launched, or isn't one it knows. Nothing was logged for it.
            return (false, AIRequestLeftText.headline(for: .expired, source: "").headline)
        }
        // The watch sent its confirm twice. The first one's acknowledgement tells the wearer how it went.
        guard ending.left != .claimed(.watch) else { return nil }
        return (false, AIRequestLeftText.headline(for: ending.left, source: ending.source).headline)
    }

    // MARK: Endings

    private func remember(_ event: Left) {
        lock.withLock {
            endings.append(event)
            if endings.count > Self.rememberedEndings {
                endings.removeFirst(endings.count - Self.rememberedEndings)
            }
        }
    }

    /// Tells the watch the request left pending, unless the watch itself took it: its Confirm screen knows.
    private func sendEnded(_ event: Left) {
        guard event.left != .claimed(.watch), let link = current?.link else { return }
        let text = AIRequestLeftText.headline(for: event.left, source: event.source)
        link.sendEnded(AIRequestEnded(id: event.id, headline: text.headline, isSuccess: text.isSuccess))
    }
}
