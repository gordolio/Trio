import Foundation
import UserNotifications
import WatchConnectivity
import WatchKit

/// The watch's side of an AI assistant's request: registers for the service's pushes and hands the token to the phone,
/// opens a request's flow from its notification, and passes the phone's messages to the flow. It's the notification
/// center's delegate, and passes every notification that isn't a request on to `WatchNotificationHandler`.
///
/// Threads: the flow controller runs on the main queue, so everything is handed to it there. WatchConnectivity and the
/// notification center call in on their own queues, so what they share here is behind `lock`.
final class AIRequestWatchCenter: NSObject, UNUserNotificationCenterDelegate, WCSessionDelegate {
    /// How a message goes to the phone.
    private enum PhoneDelivery {
        /// Queued as user info, which the system delivers when it can.
        case queued
        /// Sent now if the phone is reachable, otherwise not at all. For a message that's only worth anything now.
        case liveOnly
        /// Sent as soon as the phone is reachable before the deadline, otherwise not at all. Right after the session
        /// activates, as on a launch from a notification, the phone can take a moment to become reachable.
        case liveBefore(Date)
        /// Queued, and also sent now if the phone is reachable, so it gets there even if the app is suspended first.
        case liveAndQueued
    }

    private struct WaitingMessage {
        let message: [String: Any]
        let delivery: PhoneDelivery
        /// Runs when a `liveOnly` or `liveBefore` message didn't go.
        let notSent: () -> Void
    }

    static let shared = AIRequestWatchCenter()

    /// How long a swipe on a request keeps the watch app running to tell the phone.
    private static let backgroundTimeout: TimeInterval = 15
    /// How long an open waits for the phone to be reachable. The phone then has the rest of the flow's 5 s to answer.
    private static let openSendWindow: TimeInterval = 4
    /// How often a `liveBefore` message checks whether the phone is reachable yet.
    private static let reachabilityCheck: UInt64 = 500_000_000

    private let lock = NSLock()
    /// Whether the session has been activated. Before that, WatchConnectivity drops anything sent.
    private var isSessionActive = false
    /// Messages sent before the session was activated.
    private var waitingForSession: [WaitingMessage] = []
    /// Swipes made before the session was activated, each waiting for it to send their close.
    private var activationWaiters: [DispatchSemaphore] = []

    override private init() {
        super.init()
    }

    /// Sets up notifications for requests on top of upstream's glucose alerts, registers for the service's pushes, and
    /// connects the request flow to the phone.
    func configure() {
        AIRequestWatchFlowController.shared.connect { [weak self] message in
            self?.sendFlowMessage(message)
        }
        // Upstream's setup first: it registers the glucose category. The center then takes over as the delegate, and
        // passes every notification that isn't a request on to `WatchNotificationHandler`.
        WatchNotificationHandler.shared.configure()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // UNUserNotificationCenter and WKApplication methods should be called on main thread
        Task { @MainActor in
            WKApplication.shared().registerForRemoteNotifications()
            // Upstream's handler reads and writes the categories the same way, a moment earlier, and its write may not
            // have landed when this reads. So the glucose category goes in again, or this write could drop it. Every
            // request category already there is replaced, which drops those an earlier build registered.
            let existing = await center.notificationCategories()
            let ours = AIRequestIdentifiers.watchCategories().union([NotificationCategoryFactory.createGlucoseCategory()])
            let ourIDs = Set(ours.map(\.identifier))
            let kept = existing.filter { !ourIDs.contains($0.identifier) && !$0.identifier.hasPrefix("trio.request.") }
            center.setNotificationCategories(kept.union(ours))
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Self.log("notification authorization failed: \(error)")
            } else if !granted {
                Self.log("notifications aren't allowed")
            }
        }
    }

    // MARK: Messages from the phone

    /// Handles a message from the phone. Returns `false` if it isn't one of the request messages, so the caller can
    /// handle it.
    func receive(_ message: [String: Any]) -> Bool {
        // A message from the phone means the session is active, so anything held back can go now.
        sessionDidActivate()

        var handled = false
        if let value = message[AIRequestIdentifiers.keyDetails] {
            handled = true
            if let details = Self.decode(AIRequestWatchDetails.self, from: value) {
                DispatchQueue.main.async {
                    AIRequestWatchFlowController.shared.receive(details)
                }
            } else {
                Self.log("couldn't read a request's details from the phone")
            }
        }
        if let value = message[AIRequestIdentifiers.keyEnded] {
            handled = true
            if let ended = Self.decode(AIRequestEnded.self, from: value) {
                removeDeliveredNotifications(of: ended.id)
                DispatchQueue.main.async {
                    AIRequestWatchFlowController.shared.ended(ended)
                }
                Self.log("\(ended.id) ended: \(ended.headline)")
            } else {
                Self.log("couldn't read a request's ending from the phone")
            }
        }
        return handled
    }

    /// Removes the request's notifications that are still in Notification Center, under whichever identifier they
    /// came.
    private func removeDeliveredNotifications(of id: String) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let identifiers = delivered
                .filter { AIRequestIdentifiers.requestID(in: $0.request.content.userInfo) == id }
                .map(\.request.identifier)
            if !identifiers.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: identifiers)
            }
        }
    }

    // MARK: Messages to the phone

    /// Sends the watch's push token to the phone, which passes it on to the service.
    func sendPushToken(_ hex: String) {
        sendToPhone([AIRequestIdentifiers.keyWatchPushToken: hex], delivery: .queued)
    }

    /// Sends a message of the request flow. An open and a confirm go live or not at all, never queued: a late open
    /// would hold the request for a watch that stopped waiting, and a late confirm would give a bolus long after the
    /// wearer asked. An open may wait a few seconds for the phone; a confirm that doesn't go now tells the flow. A close
    /// declines, so it goes however it can.
    private func sendFlowMessage(_ message: [String: Any]) {
        if message[AIRequestIdentifiers.keyOpen] != nil {
            sendToPhone(message, delivery: .liveBefore(Date().addingTimeInterval(Self.openSendWindow)))
        } else if let value = message[AIRequestIdentifiers.keyConfirm] {
            let id = Self.decode(AIRequestWatchConfirm.self, from: value)?.id
            sendToPhone(message, delivery: .liveOnly) {
                guard let id else { return }
                DispatchQueue.main.async {
                    AIRequestWatchFlowController.shared.confirmNotDelivered(id: id)
                }
            }
        } else {
            sendToPhone(message, delivery: .liveAndQueued)
        }
    }

    /// Sends a message to the phone, as `delivery` says. A message sent before the session is active (as at launch,
    /// before `WatchState` has activated it) waits for the activation or the phone's first message.
    private func sendToPhone(_ message: [String: Any], delivery: PhoneDelivery, notSent: @escaping () -> Void = {}) {
        let item = WaitingMessage(message: message, delivery: delivery, notSent: notSent)
        let isActive = lock.withLock {
            if !isSessionActive {
                waitingForSession.append(item)
            }
            return isSessionActive
        }
        if isActive {
            hand(item)
        }
    }

    /// Marks the session active and sends the messages held back until now. Safe to call more than once.
    func sessionDidActivate() {
        let (waiting, waiters) = lock.withLock {
            isSessionActive = true
            defer {
                waitingForSession = []
                activationWaiters = []
            }
            return (waitingForSession, activationWaiters)
        }
        for item in waiting {
            hand(item)
        }
        for waiter in waiters {
            waiter.signal()
        }
    }

    private func hand(_ item: WaitingMessage) {
        let session = WCSession.default
        switch item.delivery {
        case .queued:
            session.transferUserInfo(item.message)
        case .liveOnly:
            guard session.isReachable else {
                Self.log("the phone isn't reachable, so a message isn't sent")
                item.notSent()
                return
            }
            session.sendMessage(item.message, replyHandler: nil) { error in
                Self.log("couldn't message the phone, so it isn't sent: \(error)")
                item.notSent()
            }
        case let .liveBefore(deadline):
            guard Date() < deadline else {
                Self.log("the phone wasn't reachable in time, so a message isn't sent")
                item.notSent()
                return
            }
            guard session.isReachable else {
                Task {
                    try? await Task.sleep(nanoseconds: Self.reachabilityCheck)
                    self.hand(item)
                }
                return
            }
            session.sendMessage(item.message, replyHandler: nil) { error in
                Self.log("couldn't message the phone, so it isn't sent: \(error)")
                item.notSent()
            }
        case .liveAndQueued:
            session.transferUserInfo(item.message)
            if session.isReachable {
                session.sendMessage(item.message, replyHandler: nil) { error in
                    Self.log("couldn't message the phone; it's queued too: \(error)")
                }
            }
        }
    }

    /// Swiping a request away can launch the app in the background, before `WatchState` exists to activate the
    /// session. Then the center activates it, is its delegate until `WatchState` takes over, and keeps the app running
    /// until the close is handed to WatchConnectivity.
    private func requestDismissed(_ id: String) {
        let waiter: DispatchSemaphore? = lock.withLock {
            guard !isSessionActive else { return nil }
            let waiter = DispatchSemaphore(value: 0)
            activationWaiters.append(waiter)
            return waiter
        }
        AIRequestWatchFlowController.shared.notificationDismissed(id: id)
        guard let waiter else { return }
        activateSessionIfUnowned()
        ProcessInfo.processInfo.performExpiringActivity(withReason: "Tell the phone a request was dismissed") { expired in
            guard !expired else {
                waiter.signal()
                return
            }
            if waiter.wait(timeout: .now() + Self.backgroundTimeout) == .timedOut {
                Self.log("the session wasn't active in time to tell the phone \(id) was dismissed")
            }
        }
    }

    /// Activates the session, as its delegate, unless `WatchState` already has.
    private func activateSessionIfUnowned() {
        // On the main queue, where `WatchState` sets itself up, so the two can't both take the session.
        DispatchQueue.main.async {
            guard WCSession.isSupported() else { return }
            let session = WCSession.default
            guard session.activationState != .activated, session.delegate == nil else { return }
            session.delegate = self
            session.activate()
            Self.log("activating the session to tell the phone")
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // A request shows over the app too. Anything else shows as with upstream, which shows nothing while the app is
        // open.
        let isRequest = AIRequestIdentifiers.requestID(in: notification.request.content.userInfo) != nil
        completionHandler(isRequest ? [.banner, .sound] : [])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        // The iPhone's backup, forwarded to the wrist, opens the request on the watch as its own notification does.
        let isBackup = content.categoryIdentifier == AIRequestIdentifiers.categoryPhone
        let id = isBackup
            ? content.userInfo[AIRequestIdentifiers.backupRequestIDKey] as? String
            : AIRequestIdentifiers.requestID(in: content.userInfo)
        guard let id else {
            if isBackup {
                Self.log("ignored the iPhone's notification without a request ID")
                completionHandler()
            } else {
                WatchNotificationHandler.shared.userNotificationCenter(
                    center,
                    didReceive: response,
                    withCompletionHandler: completionHandler
                )
            }
            return
        }
        defer { completionHandler() }

        switch response.actionIdentifier {
        case AIRequestIdentifiers.actionReview,
             UNNotificationDefaultActionIdentifier:
            DispatchQueue.main.async {
                AIRequestWatchFlowController.shared.open(id: id)
            }
        case UNNotificationDismissActionIdentifier:
            requestDismissed(id)
        default:
            Self.log("unknown action \(response.actionIdentifier) for \(id)")
        }
    }

    // MARK: WCSessionDelegate

    // The center is the session's delegate only after `activateSessionIfUnowned`, until `WatchState` takes over.
    // It handles the request messages and ignores the rest. The other required methods are iOS only.

    func session(_: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else {
            Self.log("couldn't activate the session: \(String(describing: error))")
            return
        }
        sessionDidActivate()
    }

    func session(_: WCSession, didReceiveMessage message: [String: Any]) {
        _ = receive(message)
    }

    func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        _ = receive(userInfo)
    }

    // MARK: Helpers

    private static func decode<Message: Decodable>(_ type: Message.Type, from value: Any) -> Message? {
        guard let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func log(_ message: String) {
        Task { await WatchLogger.shared.log("AI requests: \(message)") }
    }
}
