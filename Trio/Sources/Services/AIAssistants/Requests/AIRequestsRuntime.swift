import Combine
import Foundation
import Swinject
import UIKit
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
    private var foregroundObserver: NSObjectProtocol?

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
        // The seen store creates the folder that the pending request is kept in.
        let seen = AIRequestSeenStore.appDefault()
        let pendingFileURL = URL.applicationSupportDirectory
            .appendingPathComponent("AIAssistants", isDirectory: true)
            .appendingPathComponent("pending-request.json")

        // The link forwards what the watch sends to the coordinator, which needs the link to reach the watch.
        let relay = WatchRelay()
        let watchLink = AIRequestsRuntime.makeWatchLink(
            session: WCSession.default,
            relay: relay,
            allowsMealRequests: { preferences.value.allowsMealRequests },
            onWatchTokenChanged: uploadNow
        )
        watchLink.follow(preferences.changes.eraseToAnyPublisher())
        let phoneBackup = AIRequestPhoneBackup()
        let coordinator = AIRequestCoordinator(
            seen: seen,
            pendingFileURL: pendingFileURL,
            preferences: { preferences.value },
            treatments: BaseAIRequestTreatments(resolver: resolver),
            watch: watchLink,
            phoneBackup: phoneBackup,
            reporters: [.service: ServiceRequestReporter(api: api)]
        )
        // Subscribed here, before anything can start the coordinator: `left` has no replay, and `start()` can expire the
        // request that was pending when Trio quit.
        relay.connect(coordinator: coordinator, link: watchLink)

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
        relay.checkInBeforeOpening { [checkIn] in await checkIn.checkIn(reason: .open, waitingForRunning: true) }
        // Opening Trio means it's running now, which iOS doesn't promise for a push.
        foregroundObserver = Foundation.NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [checkIn] _ in
            Task { await checkIn.checkIn(reason: .foreground) }
        }
    }

    deinit {
        if let foregroundObserver { Foundation.NotificationCenter.default.removeObserver(foregroundObserver) }
    }
}

extension AIRequestsRuntime {
    /// The link to the watch, handing what the watch sends to `relay`. The watch's open, confirm and close take a
    /// while to carry out, so each one runs on a task of its own.
    static func makeWatchLink(
        session: AIRequestWatchSession,
        defaults: UserDefaults = .standard,
        relay: WatchRelay,
        allowsMealRequests: @escaping () -> Bool,
        onWatchTokenChanged: @escaping () -> Void
    ) -> AIRequestWatchLink {
        AIRequestWatchLink(
            session: session,
            defaults: defaults,
            allowsMealRequests: allowsMealRequests,
            onOpen: { id in Task { await relay.open(id) } },
            onConfirm: { confirm in Task { await relay.confirm(confirm) } },
            onClose: { close in Task { await relay.close(close) } },
            onWatchTokenChanged: onWatchTokenChanged
        )
    }
}

/// Hands what the watch sends to the coordinator, and tells the watch what comes of it: the request's details when it
/// opens one, or why it ended, the acknowledgement of its confirmation, and the ending of a request that leaves
/// pending. The coordinator
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
    /// Checks in and waits for it: set once the check-in exists, which is made after the relay.
    private var checkInForOpen: (() async -> Void)?
    /// The opens in flight, by request ID, so the watch asking again for the same request joins the one running.
    private var opening: [String: Task<AIRequestWatchDetails?, Never>] = [:]

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

    /// Sets how an open of a request Trio hasn't seen checks in first.
    func checkInBeforeOpening(_ checkIn: @escaping () async -> Void) {
        lock.withLock { checkInForOpen = checkIn }
    }

    /// The wearer opened the request on the watch. It's answered with the request's details, or, when the request
    /// isn't pending or its time is up, with why it ended, so the watch says so rather than waiting for details that
    /// won't come. The watch can be told about a request before Trio is (the service pushes the meal to the watch as
    /// its estimate comes in), so a request Trio hasn't seen is checked in for first. The watch may ask again while
    /// that runs; it joins the open in flight, and only the first answers.
    func open(_ id: String) async {
        guard let connection = current else { return }
        let (task, isFirst) = lock.withLock { () -> (Task<AIRequestWatchDetails?, Never>, Bool) in
            if let running = opening[id] { return (running, false) }
            let task = Task { await self.details(of: id, connection: connection) }
            opening[id] = task
            return (task, true)
        }
        let details = await task.value
        guard isFirst else { return }
        lock.withLock { opening[id] = nil }
        if let details {
            connection.link.sendDetails(details)
        } else {
            connection.link.sendEnded(ending(ofRequest: id))
        }
    }

    /// The request's details, checking in first when Trio has neither it pending nor its ending.
    private func details(of id: String, connection: Connection) async -> AIRequestWatchDetails? {
        if let details = await connection.coordinator.open(id: id, on: .watch) { return details }
        let (knowsEnding, checkIn) = lock.withLock { (endings.contains { $0.id == id }, checkInForOpen) }
        guard !knowsEnding, connection.coordinator.current.value?.request.id != id, let checkIn else { return nil }
        debug(.remote, "AI requests: the watch opened \(id) before Trio had it, so it checks in first")
        await checkIn()
        return await connection.coordinator.open(id: id, on: .watch)
    }

    /// The wearer confirmed on the watch. It's carried out, and the watch is told how it went as soon as the pump
    /// answers, before the report to trio-rc, as upstream's watch is. A request that isn't pending any more is not
    /// carried out.
    func confirm(_ confirm: AIRequestWatchConfirm) async {
        guard let connection = current else { return }
        let link = connection.link
        let report = await connection.coordinator.carryOutWatchConfirm(confirm) { [weak self] report in
            self?.acknowledge(report, id: confirm.id, on: link)
        }
        if report == nil {
            acknowledge(nil, id: confirm.id, on: link)
        }
    }

    /// The wearer left the request's screens on the watch, or swiped its notification away.
    func close(_ close: AIRequestWatchClose) async {
        guard let coordinator = current?.coordinator else { return }
        await coordinator.close(id: close.id, on: .watch, dismissed: close.dismissed)
    }

    // MARK: Acknowledging

    private func acknowledge(_ report: AIRequestReport?, id: String, on link: AIRequestWatchLink) {
        guard let acknowledgment = acknowledgment(for: report, id: id) else { return }
        link.sendAcknowledgment(success: acknowledgment.success, message: acknowledgment.message)
    }

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
            if current?.coordinator.taker(of: id) == .phone {
                // The iPhone's Log took it a moment ago, and its claim hasn't taken it out of pending yet.
                return (false, AIRequestLeftText.headline(for: .claimed(.phone), source: "").headline)
            }
            // The request ended before Trio launched, or isn't one it knows. Nothing was logged for it.
            return (false, AIRequestLeftText.headline(for: .expired, source: "").headline)
        }
        // The watch sent its confirm twice. The first one's acknowledgement tells the wearer how it went.
        guard ending.left != .claimed(.watch) else { return nil }
        return (false, AIRequestLeftText.headline(for: ending.left, source: ending.source).headline)
    }

    // MARK: Endings

    /// Why the request ended, as the relay remembers it. One it doesn't remember ended before Trio launched, or its
    /// time is up while the iPhone's sheet holds it: nothing was logged for it on the watch, and it's expired there.
    private func ending(ofRequest id: String) -> AIRequestEnded {
        let ending = lock.withLock { endings.last { $0.id == id } }
        let text = AIRequestLeftText.headline(for: ending?.left ?? .expired, source: ending?.source ?? "")
        return AIRequestEnded(id: id, headline: text.headline, isSuccess: text.isSuccess)
    }

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
