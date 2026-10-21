import Foundation
import Observation
import UserNotifications
import WatchConnectivity
import WatchKit

/// The watch's side of an AI assistant's request: keeps the answer key, shows a request as a notification,
/// and signs and sends the wearer's answer. It's the notification center's delegate, and passes every
/// notification that isn't a request on to `WatchNotificationHandler`.
@Observable final class AIRequestWatchCenter: NSObject, UNUserNotificationCenterDelegate, WCSessionDelegate {
    /// How a message goes to the phone.
    enum PhoneDelivery {
        /// Queued as user info, which the system delivers when it can.
        case queued
        /// Sent now if the phone is reachable, otherwise queued.
        case live
        /// Queued, and also sent now if the phone is reachable. For answers from the background: the queued copy
        /// goes out even if the app is suspended before a failed send could fall back to the queue.
        case liveAndQueued
    }

    private struct WaitingMessage {
        let message: [String: Any]
        let delivery: PhoneDelivery
        let handedOff: () -> Void
    }

    static let shared = AIRequestWatchCenter()

    private static let keyAccount = "answer-key"
    /// How long a notification action keeps the watch app running to send its answer. The service request
    /// itself times out after 10 s.
    private static let backgroundAnswerTimeout: TimeInterval = 15

    /// The request the approval screen shows.
    var presented: AIRequestPrompt?

    @ObservationIgnored private let keychain = SystemAIRequestKeychain()
    @ObservationIgnored private let lock = NSLock()
    /// Requests the phone withdrew. A prompt queued as user info can arrive after its withdraw.
    @ObservationIgnored private var withdrawnIDs: Set<String> = []
    /// Whether the session has been activated. Before that, WatchConnectivity drops anything sent.
    @ObservationIgnored private var isSessionActive = false
    /// Messages sent before the session was activated.
    @ObservationIgnored private var waitingForSession: [WaitingMessage] = []

    override private init() {
        super.init()
    }

    /// Sets up notifications for requests and glucose alerts, registers for the service's pushes, and asks
    /// the phone for the answer key if there isn't one yet.
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let categories = Set([NotificationCategoryFactory.createGlucoseCategory()] + AIRequestIdentifiers.watchCategories())
        // UNUserNotificationCenter and WKApplication methods should be called on main thread
        Task { @MainActor in
            center.setNotificationCategories(categories)
            WKApplication.shared().registerForRemoteNotifications()
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Task { await WatchLogger.shared.log("AI requests: notification authorization failed: \(error)") }
            } else if !granted {
                Task { await WatchLogger.shared.log("AI requests: notifications aren't allowed") }
            }
        }
        if keychain.data(for: Self.keyAccount) == nil {
            requestKey()
        }
    }

    // MARK: Messages from the phone

    /// Handles a message from the phone. Returns `false` if it isn't one of the request messages, so the
    /// caller can handle it.
    func receive(_ message: [String: Any]) -> Bool {
        // A message from the phone means the session is active, so anything held back can go now.
        sessionDidActivate()

        var handled = false
        if let key = message[AIRequestIdentifiers.keyMessage] {
            handled = true
            store(key)
        }
        if let prompt = message[AIRequestIdentifiers.keyPrompt] {
            handled = true
            show(prompt)
        }
        if let id = message[AIRequestIdentifiers.keyWithdraw] as? String {
            handled = true
            withdraw(id)
        }
        return handled
    }

    private func store(_ value: Any) {
        guard let string = value as? String, let key = Data(base64Encoded: string), key.count == 32 else {
            Task { await WatchLogger.shared.log("AI requests: couldn't read the answer key from the phone") }
            return
        }
        guard keychain.set(key, for: Self.keyAccount) else {
            Task { await WatchLogger.shared.log("AI requests: couldn't store the answer key") }
            return
        }
        Task { await WatchLogger.shared.log("AI requests: stored a new answer key") }
    }

    /// Posts a local notification for a request the phone sent over WatchConnectivity, in the category the
    /// service's push would use.
    private func show(_ value: Any) {
        guard let data = value as? Data, let prompt = Self.prompt(from: data) else {
            Task { await WatchLogger.shared.log("AI requests: couldn't read a request from the phone") }
            return
        }
        guard isOpen(prompt) else {
            Task { await WatchLogger.shared.log("AI requests: not showing \(prompt.id): it expired or was withdrawn") }
            return
        }

        let content = UNMutableNotificationContent()
        content.title = prompt.title
        content.body = prompt.body
        content.sound = .default
        content.categoryIdentifier = AIRequestIdentifiers.category(for: prompt.approvalStyle)
        content.interruptionLevel = .timeSensitive
        content.userInfo = [AIRequestIdentifiers.keyPrompt: data]

        let request = UNNotificationRequest(identifier: prompt.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Task { await WatchLogger.shared.log("AI requests: couldn't show \(prompt.id): \(error)") }
            }
        }
    }

    private func withdraw(_ id: String) {
        lock.withLock { _ = withdrawnIDs.insert(id) }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
        DispatchQueue.main.async {
            if self.presented?.id == id {
                self.presented = nil
            }
        }
        Task { await WatchLogger.shared.log("AI requests: \(id) was withdrawn") }
    }

    // MARK: Messages to the phone

    /// Sends the watch's push token to the phone, which passes it on to the service.
    func sendPushToken(_ hex: String) {
        sendToPhone([AIRequestIdentifiers.keyWatchPushToken: hex])
    }

    private func requestKey() {
        sendToPhone([AIRequestIdentifiers.keyRequest: true])
    }

    /// Sends a message to the phone, as `delivery` says. `handedOff` runs once WatchConnectivity has it. A message
    /// sent before the session is active (as at launch, before `WatchState` has activated it) waits for the
    /// activation or the phone's first message.
    func sendToPhone(
        _ message: [String: Any],
        delivery: PhoneDelivery = .queued,
        handedOff: @escaping () -> Void = {}
    ) {
        let item = WaitingMessage(message: message, delivery: delivery, handedOff: handedOff)
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
        let waiting = lock.withLock {
            isSessionActive = true
            defer { waitingForSession = [] }
            return waitingForSession
        }
        waiting.forEach(hand)
    }

    private func hand(_ item: WaitingMessage) {
        let session = WCSession.default
        switch item.delivery {
        case .queued:
            session.transferUserInfo(item.message)
        case .live:
            if session.isReachable {
                session.sendMessage(item.message, replyHandler: nil) { error in
                    Task { await WatchLogger.shared.log("AI requests: couldn't message the phone, so it's queued: \(error)") }
                    session.transferUserInfo(item.message)
                }
            } else {
                session.transferUserInfo(item.message)
            }
        case .liveAndQueued:
            session.transferUserInfo(item.message)
            if session.isReachable {
                session.sendMessage(item.message, replyHandler: nil) { error in
                    Task { await WatchLogger.shared.log("AI requests: couldn't message the phone; it's queued too: \(error)") }
                }
            }
        }
        item.handedOff()
    }

    /// An answer from a notification can launch the app in the background, before `WatchState` exists to
    /// activate the session. Then the center activates it and is its delegate until `WatchState` takes over.
    func activateSessionIfUnowned() {
        // On the main queue, where `WatchState` sets itself up, so the two can't both take the session.
        DispatchQueue.main.async {
            guard WCSession.isSupported() else { return }
            let session = WCSession.default
            guard session.activationState != .activated, session.delegate == nil else { return }
            session.delegate = self
            session.activate()
            Task { await WatchLogger.shared.log("AI requests: activating the session to send an answer") }
        }
    }

    // MARK: Answering

    /// Signs the wearer's answer with the shared key and sends it along the request's answer route. A
    /// decline says how it was declined.
    func answer(_ prompt: AIRequestPrompt, _ decision: AIRequestDecision, declinedBy: AIRequestDeclinedBy?) {
        answer(prompt, decision, declinedBy: declinedBy, inBackground: false, completion: {})
    }

    private func answer(
        _ prompt: AIRequestPrompt,
        _ decision: AIRequestDecision,
        declinedBy: AIRequestDeclinedBy?,
        inBackground: Bool,
        completion: @escaping () -> Void
    ) {
        guard isOpen(prompt) else {
            Task { await WatchLogger.shared.log("AI requests: not answering \(prompt.id): it expired or was withdrawn") }
            completion()
            return
        }
        guard let key = keychain.data(for: Self.keyAccount) else {
            Task { await WatchLogger.shared.log("AI requests: no answer key, so \(prompt.id) isn't answered; asking the phone") }
            requestKey()
            completion()
            return
        }
        let signed = AIRequestSigner.sign(prompt: prompt, decision: decision, declinedBy: declinedBy, at: Date(), key: key)
        Task { await WatchLogger.shared.log("AI requests: answering \(prompt.id): \(decision.rawValue)") }
        AIRequestAnswerSender.send(signed, prompt: prompt, inBackground: inBackground, completion: completion)
    }

    /// A notification action runs in the background, so the watch app asks for time to send the answer. The
    /// answer starts first, so it still goes out if the system grants no time; the activity then keeps the
    /// app running until WatchConnectivity has it and the service has responded.
    private func answerInBackground(_ prompt: AIRequestPrompt, _ decision: AIRequestDecision, declinedBy: AIRequestDeclinedBy?) {
        let sent = DispatchSemaphore(value: 0)
        answer(prompt, decision, declinedBy: declinedBy, inBackground: true) { sent.signal() }
        ProcessInfo.processInfo.performExpiringActivity(withReason: "Send the answer to an AI assistant's request") { expired in
            guard !expired else {
                sent.signal()
                return
            }
            if sent.wait(timeout: .now() + Self.backgroundAnswerTimeout) == .timedOut {
                Task { await WatchLogger.shared.log("AI requests: \(prompt.id)'s answer was still sending when time ran out") }
            }
        }
    }

    /// Posts the request again for review, when its one-gesture Approve couldn't be checked: the wearer opens it to
    /// approve. A request that has expired or was withdrawn isn't posted.
    private func askToOpen(_ prompt: AIRequestPrompt) {
        guard isOpen(prompt) else {
            Task { await WatchLogger.shared.log("AI requests: not reposting \(prompt.id): it expired or was withdrawn") }
            return
        }
        guard let data = try? JSONEncoder().encode(prompt) else {
            Task { await WatchLogger.shared.log("AI requests: couldn't repost \(prompt.id) for review") }
            return
        }
        let content = UNMutableNotificationContent()
        content.title = prompt.title
        content.body = String(
            localized: "Couldn't check this request. Open it to approve.",
            comment: "Watch notification when an AI assistant's request can't be approved from the notification, because its text couldn't be checked as Trio's"
        )
        content.sound = .default
        content.categoryIdentifier = AIRequestIdentifiers.categoryReview
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = AIRequestIdentifiers.threadID
        // The prompt, so Review opens it.
        content.userInfo = [AIRequestIdentifiers.keyPrompt: data]

        let request = UNNotificationRequest(identifier: AIRequestIdentifiers.notificationSlot, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Task { await WatchLogger.shared.log("AI requests: couldn't repost \(prompt.id) for review: \(error)") }
            }
        }
    }

    // MARK: Checks

    /// Whether Trio signed the request's title, body, approval style and context with the shared key, so the
    /// approval screen can show its context rows.
    func isDisplayVerified(_ prompt: AIRequestPrompt) -> Bool {
        isDisplayVerified(prompt, as: prompt.approvalStyle)
    }

    /// Whether Trio signed the request's title, body and context for `style`. `false` without a key.
    private func isDisplayVerified(_ prompt: AIRequestPrompt, as style: AIRequestApprovalStyle) -> Bool {
        guard let key = keychain.data(for: Self.keyAccount) else { return false }
        return AIRequestSigner.isValidDisplayMAC(
            prompt.displayMac,
            id: prompt.id,
            approvalStyle: style,
            title: prompt.title,
            body: prompt.body,
            context: prompt.context,
            key: key
        )
    }

    /// Whether a request can still be shown and answered: it hasn't expired and the phone hasn't withdrawn it.
    private func isOpen(_ prompt: AIRequestPrompt) -> Bool {
        Date() < prompt.expiresAt && !isWithdrawn(prompt.id)
    }

    private func isWithdrawn(_ id: String) -> Bool {
        lock.withLock { withdrawnIDs.contains(id) }
    }

    /// Reads a request from the service's push, or from a local notification the watch posted.
    private static func prompt(in userInfo: [AnyHashable: Any]) -> AIRequestPrompt? {
        if let prompt = AIRequestPrompt.fromPush(userInfo) {
            return prompt
        }
        return (userInfo[AIRequestIdentifiers.keyPrompt] as? Data).flatMap(prompt(from:))
    }

    private static func prompt(from data: Data) -> AIRequestPrompt? {
        try? JSONDecoder().decode(AIRequestPrompt.self, from: data)
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let content = notification.request.content
        let requestCategories = [AIRequestIdentifiers.categoryReview, AIRequestIdentifiers.categoryApprove]
        guard requestCategories.contains(content.categoryIdentifier),
              let prompt = Self.prompt(in: content.userInfo),
              isOpen(prompt)
        else {
            completionHandler([])
            return
        }
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard let prompt = Self.prompt(in: response.notification.request.content.userInfo) else {
            WatchNotificationHandler.shared.userNotificationCenter(
                center,
                didReceive: response,
                withCompletionHandler: completionHandler
            )
            return
        }
        defer { completionHandler() }

        switch response.actionIdentifier {
        case AIRequestIdentifiers.actionApprove:
            // Only the Approve category has this action, so it's checked as one-gesture: a request Trio signed as
            // two-step never approves from the notification, and neither does text Trio didn't write.
            guard isDisplayVerified(prompt, as: .oneGesture) else {
                Task { await WatchLogger.shared.log("AI requests: couldn't check \(prompt.id)'s text, so it isn't approved") }
                if keychain.data(for: Self.keyAccount) == nil {
                    requestKey()
                }
                askToOpen(prompt)
                return
            }
            answerInBackground(prompt, .approve, declinedBy: nil)
        case AIRequestIdentifiers.actionDecline:
            answerInBackground(prompt, .decline, declinedBy: .button)
        case UNNotificationDismissActionIdentifier:
            answerInBackground(prompt, .decline, declinedBy: .dismissed)
        case AIRequestIdentifiers.actionReview,
             UNNotificationDefaultActionIdentifier:
            // The approval screen says so itself if the request has expired by now.
            guard !isWithdrawn(prompt.id) else {
                Task { await WatchLogger.shared.log("AI requests: not opening \(prompt.id): it was withdrawn") }
                return
            }
            DispatchQueue.main.async {
                self.presented = prompt
            }
        default:
            Task { await WatchLogger.shared.log("AI requests: unknown action \(response.actionIdentifier) for \(prompt.id)") }
        }
    }

    // MARK: WCSessionDelegate

    // The center is the session's delegate only after `activateSessionIfUnowned`, until `WatchState` takes over.
    // It handles the request messages and ignores the rest. The other required methods are iOS only.

    func session(_: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else {
            Task { await WatchLogger.shared.log("AI requests: couldn't activate the session: \(String(describing: error))") }
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
}
