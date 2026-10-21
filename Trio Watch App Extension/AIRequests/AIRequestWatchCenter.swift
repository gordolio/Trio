import Foundation
import Observation
import UserNotifications
import WatchConnectivity
import WatchKit

/// The watch's side of an AI assistant's request: keeps the answer key, shows a request as a notification,
/// signs and sends the wearer's answer, and keeps the phone's receipts and results for the approval screen. It's the
/// notification center's delegate, and passes every notification that isn't a request on to `WatchNotificationHandler`.
///
/// Threads: `presented`, `receipts` and `results` change on the main queue only, since the screen observes them.
/// WatchConnectivity and the notification center call in on their own queues, so everything else they share is behind
/// `lock`, and changes to the request notification's slot go through `slotQueue`.
@Observable final class AIRequestWatchCenter: NSObject, UNUserNotificationCenterDelegate, WCSessionDelegate {
    /// How a message goes to the phone.
    enum PhoneDelivery {
        /// Queued as user info, which the system delivers when it can.
        case queued
        /// Sent now if the phone is reachable, otherwise queued.
        case live
        /// Sent now if the phone is reachable, otherwise dropped. For a message that's only worth anything now.
        case liveOnly
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
    /// How long a change to the request notification's slot waits for the notification center.
    private static let slotTimeout: TimeInterval = 5

    /// The request the approval screen shows.
    var presented: AIRequestPrompt?
    /// Requests the wearer answered here that the phone has since withdrawn: the phone has taken the answer, or the
    /// request ended another way. Its result follows.
    private(set) var receipts: Set<String> = []
    /// How each request ended, as the phone says. The phone sends each result more than once, and a copy changes
    /// nothing.
    private(set) var results: [String: AIRequestResultMessage] = [:]

    @ObservationIgnored private let keychain = SystemAIRequestKeychain()
    @ObservationIgnored private let lock = NSLock()
    /// Runs the changes to the request notification's slot one at a time, so a withdraw that reads the slot can't then
    /// remove a newer request posted into it in between.
    @ObservationIgnored private let slotQueue = DispatchQueue(label: "AIRequestWatchCenter.slot", qos: .userInitiated)
    /// Requests the phone withdrew. A prompt queued as user info can arrive after its withdraw.
    @ObservationIgnored private var withdrawnIDs: Set<String> = []
    /// Requests the wearer answered on the watch, from the screen or a notification. A withdraw of one of these is the
    /// phone's receipt, and doesn't close the screen.
    @ObservationIgnored private var answeredIDs: Set<String> = []
    /// Requests the wearer approved from a notification action, with no screen to show the result. The result is
    /// posted as a notification.
    @ObservationIgnored private var approvedFromNotificationIDs: Set<String> = []
    /// The requests the watch has seen, by ID, so the iPhone's backup can open one. Only unexpired ones are kept.
    @ObservationIgnored private var knownPrompts: [String: AIRequestPrompt] = [:]
    /// Whether the session has been activated. Before that, WatchConnectivity drops anything sent.
    @ObservationIgnored private var isSessionActive = false
    /// Messages sent before the session was activated.
    @ObservationIgnored private var waitingForSession: [WaitingMessage] = []

    override private init() {
        super.init()
    }

    /// Sets up notifications for requests on top of upstream's glucose alerts, registers for the service's pushes,
    /// and asks the phone for the answer key if there isn't one yet.
    func configure() {
        // Upstream's setup first: it registers the glucose category. The center then takes over as the delegate, and
        // passes every notification that isn't a request on to `WatchNotificationHandler`.
        WatchNotificationHandler.shared.configure()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // UNUserNotificationCenter and WKApplication methods should be called on main thread
        Task { @MainActor in
            WKApplication.shared().registerForRemoteNotifications()
            // Upstream's handler reads and writes the categories the same way, a moment earlier, and its write may not
            // have landed when this reads. So the glucose category goes in again, or this write could drop it. An older
            // version of one of these categories is replaced.
            let existing = await center.notificationCategories()
            let ours = AIRequestIdentifiers.watchCategories().union([NotificationCategoryFactory.createGlucoseCategory()])
            let ourIDs = Set(ours.map(\.identifier))
            center.setNotificationCategories(existing.filter { !ourIDs.contains($0.identifier) }.union(ours))
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
        if let result = message[AIRequestIdentifiers.keyResult] {
            handled = true
            receiveResult(result)
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

        remember(prompt)

        let content = UNMutableNotificationContent()
        content.title = prompt.title
        content.body = prompt.body
        content.sound = .default
        content.categoryIdentifier = AIRequestIdentifiers.category(for: prompt.approvalStyle)
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = AIRequestIdentifiers.threadID
        content.userInfo = [AIRequestIdentifiers.keyPrompt: data]

        postInSlot(content, for: prompt.id)
    }

    /// The phone has stopped asking for the request. If the wearer answered it here, that's the phone's receipt, and
    /// the screen stays for the result. Otherwise the screen closes, if it shows this request.
    private func withdraw(_ id: String) {
        lock.withLock {
            _ = withdrawnIDs.insert(id)
            knownPrompts[id] = nil
        }
        removeNotifications(of: id)
        // On the main queue, where the screen answers, so an answer given before this runs counts.
        DispatchQueue.main.async {
            if self.isAnswered(id) {
                if !self.receipts.contains(id) {
                    self.receipts.insert(id)
                }
            } else if self.presented?.id == id {
                self.presented = nil
            }
        }
        Task { await WatchLogger.shared.log("AI requests: \(id) was withdrawn") }
    }

    /// Reads the phone's result, and keeps one for each request.
    private func receiveResult(_ value: Any) {
        guard let data = value as? Data, let message = try? JSONDecoder().decode(AIRequestResultMessage.self, from: data) else {
            Task { await WatchLogger.shared.log("AI requests: couldn't read a result from the phone") }
            return
        }
        DispatchQueue.main.async {
            self.record(message)
        }
    }

    /// Keeps the result for the screen. A copy of a result already kept changes nothing, and posts nothing. A result
    /// for a request that isn't on screen is posted as a notification when there's no other way for the wearer to hear
    /// it: the request was approved from a notification, or the watch approved it and it failed.
    private func record(_ message: AIRequestResultMessage) {
        guard results[message.id] != message else { return }
        results[message.id] = message
        Task { await WatchLogger.shared.log("AI requests: \(message.id) ended: \(message.tone.rawValue)") }

        guard presented?.id != message.id else { return }
        let approvedFromNotification = lock.withLock { approvedFromNotificationIDs.contains(message.id) }
        let failedAfterWatchApproval: Bool
        switch message.tone {
        case .neutral,
             .success:
            failedAfterWatchApproval = false
        case .failure,
             .warning:
            // Only an approval can fail, so a failure answered on the watch is one the watch approved.
            failedAfterWatchApproval = message.answeredOn == .watch
        }
        if approvedFromNotification || failedAfterWatchApproval {
            notify(message)
        }
    }

    /// Posts a result in its own slot, in the requests' thread. A failure breaks through Focus, as the request did.
    private func notify(_ message: AIRequestResultMessage) {
        let content = UNMutableNotificationContent()
        content.title = message.headline
        content.subtitle = message.title
        content.body = message.detail
        content.sound = .default
        content.threadIdentifier = AIRequestIdentifiers.threadID
        switch message.tone {
        case .neutral,
             .success:
            content.interruptionLevel = .active
        case .failure,
             .warning:
            content.interruptionLevel = .timeSensitive
        }

        let request = UNNotificationRequest(
            identifier: AIRequestIdentifiers.resultNotificationSlot,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Task { await WatchLogger.shared.log("AI requests: couldn't post the result of \(message.id): \(error)") }
            }
        }
    }

    // MARK: The request notification's slot

    /// Posts a request's notification in the slot, where it takes the place of whichever request was there.
    private func postInSlot(_ content: UNNotificationContent, for id: String) {
        let request = UNNotificationRequest(identifier: AIRequestIdentifiers.notificationSlot, content: content, trigger: nil)
        inSlotQueue { done in
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    Task { await WatchLogger.shared.log("AI requests: couldn't post \(id): \(error)") }
                }
                done()
            }
        }
    }

    /// Removes a request's notifications: the one in the slot only while it's still this request's, and any under the
    /// request's own ID, which a watch build from before the slot posted, or a service without it pushed.
    private func removeNotifications(of id: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])

        let slot = AIRequestIdentifiers.notificationSlot
        func isThisRequest(_ request: UNNotificationRequest) -> Bool {
            request.identifier == slot && AIRequestIdentifiers.requestID(in: request.content.userInfo) == id
        }
        // Pending first: a notification that is delivered in between is still found among the delivered ones.
        inSlotQueue { done in
            center.getPendingNotificationRequests { pending in
                if pending.contains(where: isThisRequest) {
                    center.removePendingNotificationRequests(withIdentifiers: [slot])
                }
                center.getDeliveredNotifications { delivered in
                    if delivered.contains(where: { isThisRequest($0.request) }) {
                        center.removeDeliveredNotifications(withIdentifiers: [slot])
                    }
                    done()
                }
            }
        }
    }

    /// Runs `work` on the slot queue, which waits until `work` calls `done`, or for `slotTimeout`.
    private func inSlotQueue(_ work: @escaping (_ done: @escaping () -> Void) -> Void) {
        slotQueue.async {
            let finished = DispatchSemaphore(value: 0)
            work { finished.signal() }
            if finished.wait(timeout: .now() + Self.slotTimeout) == .timedOut {
                Task { await WatchLogger.shared.log("AI requests: the notification center didn't answer in time") }
            }
        }
    }

    // MARK: Messages to the phone

    /// Sends the watch's push token to the phone, which passes it on to the service.
    func sendPushToken(_ hex: String) {
        sendToPhone([AIRequestIdentifiers.keyWatchPushToken: hex])
    }

    private func requestKey() {
        sendToPhone([AIRequestIdentifiers.keyRequest: true])
    }

    /// Tells the phone the approval screen for `id` is open, so its backup waits. Only now is it worth anything: a
    /// copy that reached the phone later would put off a backup that may already be asking.
    func screenDidOpen(_ id: String) {
        sendToPhone([AIRequestIdentifiers.keyViewing: id], delivery: .liveOnly)
    }

    /// Sends a message to the phone, as `delivery` says. `handedOff` runs once WatchConnectivity has it. A message
    /// sent before the session is active (as at launch, before `WatchState` has activated it) waits for the
    /// activation or the phone's first message. Returns whether it went to the phone live now: the session was active,
    /// the phone was reachable, and `delivery` sends live.
    @discardableResult func sendToPhone(
        _ message: [String: Any],
        delivery: PhoneDelivery = .queued,
        handedOff: @escaping () -> Void = {}
    ) -> Bool {
        let item = WaitingMessage(message: message, delivery: delivery, handedOff: handedOff)
        let isActive = lock.withLock {
            if !isSessionActive {
                waitingForSession.append(item)
            }
            return isSessionActive
        }
        return isActive && hand(item)
    }

    /// Marks the session active and sends the messages held back until now. Safe to call more than once.
    func sessionDidActivate() {
        let waiting = lock.withLock {
            isSessionActive = true
            defer { waitingForSession = [] }
            return waitingForSession
        }
        for item in waiting {
            hand(item)
        }
    }

    /// Hands the message to WatchConnectivity. Returns whether it was sent live, because the phone was reachable.
    @discardableResult private func hand(_ item: WaitingMessage) -> Bool {
        let session = WCSession.default
        let isReachable = session.isReachable
        switch item.delivery {
        case .queued:
            session.transferUserInfo(item.message)
        case .live:
            if isReachable {
                session.sendMessage(item.message, replyHandler: nil) { error in
                    Task { await WatchLogger.shared.log("AI requests: couldn't message the phone, so it's queued: \(error)") }
                    session.transferUserInfo(item.message)
                }
            } else {
                session.transferUserInfo(item.message)
            }
        case .liveOnly:
            if isReachable {
                session.sendMessage(item.message, replyHandler: nil) { error in
                    Task { await WatchLogger.shared.log("AI requests: couldn't message the phone, so it isn't sent: \(error)") }
                }
            } else {
                Task { await WatchLogger.shared.log("AI requests: the phone isn't reachable, so a message isn't sent") }
            }
        case .liveAndQueued:
            session.transferUserInfo(item.message)
            if isReachable {
                session.sendMessage(item.message, replyHandler: nil) { error in
                    Task { await WatchLogger.shared.log("AI requests: couldn't message the phone; it's queued too: \(error)") }
                }
            }
        }
        item.handedOff()
        return isReachable && item.delivery != .queued
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

    /// Signs the wearer's answer with the shared key and sends it along the request's answer route, and says what
    /// became of it: `.notSent` when there's no key to sign it with (or the request has expired or was withdrawn),
    /// `.queued` when the phone isn't reachable and the route doesn't use the service, and `.sent` otherwise. A
    /// decline says how it was declined. On the main queue, where the screen's phases are, so the result applies to
    /// the phase that was asking.
    @MainActor func answer(
        _ prompt: AIRequestPrompt,
        _ decision: AIRequestDecision,
        declinedBy: AIRequestDeclinedBy?
    ) -> AIRequestSendResult {
        answer(prompt, decision, declinedBy: declinedBy, inBackground: false, completion: {})
    }

    @discardableResult private func answer(
        _ prompt: AIRequestPrompt,
        _ decision: AIRequestDecision,
        declinedBy: AIRequestDeclinedBy?,
        inBackground: Bool,
        completion: @escaping () -> Void
    ) -> AIRequestSendResult {
        guard isOpen(prompt) else {
            Task { await WatchLogger.shared.log("AI requests: not answering \(prompt.id): it expired or was withdrawn") }
            completion()
            return .notSent
        }
        // Recorded even if it can't be sent: the phone's withdraw then leaves the screen up for the result.
        lock.withLock {
            _ = answeredIDs.insert(prompt.id)
            if inBackground, decision == .approve {
                _ = approvedFromNotificationIDs.insert(prompt.id)
            }
        }
        guard let key = keychain.data(for: Self.keyAccount) else {
            Task { await WatchLogger.shared.log("AI requests: no answer key, so \(prompt.id) isn't answered; asking the phone") }
            requestKey()
            completion()
            return .notSent
        }
        let signed = AIRequestSigner.sign(prompt: prompt, decision: decision, declinedBy: declinedBy, at: Date(), key: key)
        Task { await WatchLogger.shared.log("AI requests: answering \(prompt.id): \(decision.rawValue)") }
        return AIRequestAnswerSender.send(signed, prompt: prompt, inBackground: inBackground, completion: completion)
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

        postInSlot(content, for: prompt.id)
    }

    // MARK: Checks

    /// Whether Trio signed the request's amounts, title, body, approval style and context with the shared key, and its
    /// notification showed nothing else, so the approval screen can show its context rows.
    func isDisplayVerified(_ prompt: AIRequestPrompt) -> Bool {
        isDisplayVerified(prompt, as: prompt.approvalStyle)
    }

    /// Whether Trio signed the request's amounts, title, body and context for `style`, and its notification showed
    /// no other text. `false` without a key.
    private func isDisplayVerified(_ prompt: AIRequestPrompt, as style: AIRequestApprovalStyle) -> Bool {
        guard !prompt.hasUncheckedAlertText, let key = keychain.data(for: Self.keyAccount) else { return false }
        return AIRequestSigner.isValidDisplayMAC(
            prompt.displayMac,
            id: prompt.id,
            approvalStyle: style,
            shown: prompt.shown,
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

    private func isAnswered(_ id: String) -> Bool {
        lock.withLock { answeredIDs.contains(id) }
    }

    /// Keeps a request the watch has seen, and forgets the ones that have expired.
    private func remember(_ prompt: AIRequestPrompt) {
        let now = Date()
        lock.withLock {
            knownPrompts = knownPrompts.filter { $0.value.expiresAt > now }
            if prompt.expiresAt > now {
                knownPrompts[prompt.id] = prompt
            }
        }
    }

    private func knownPrompt(_ id: String) -> AIRequestPrompt? {
        lock.withLock { knownPrompts[id] }
    }

    /// Reads a request from a delivered notification. A subtitle is text the display MAC doesn't cover, so the request
    /// is marked as having unchecked text, as a push with other alert keys is.
    private static func prompt(in content: UNNotificationContent) -> AIRequestPrompt? {
        guard var prompt = prompt(in: content.userInfo) else { return nil }
        if !content.subtitle.isEmpty {
            prompt.hasUncheckedAlertText = true
        }
        return prompt
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
        // A result is posted only when its request isn't on screen, so it shows over the app too.
        if notification.request.identifier == AIRequestIdentifiers.resultNotificationSlot {
            completionHandler([.banner, .sound])
            return
        }
        let content = notification.request.content
        let requestCategories = [AIRequestIdentifiers.categoryReview, AIRequestIdentifiers.categoryApprove]
        guard requestCategories.contains(content.categoryIdentifier),
              let prompt = Self.prompt(in: content),
              isOpen(prompt)
        else {
            completionHandler([])
            return
        }
        remember(prompt)
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.content.categoryIdentifier == AIRequestIdentifiers.categoryPhone {
            openFromPhoneBackup(response, completionHandler: completionHandler)
            return
        }
        guard let prompt = Self.prompt(in: response.notification.request.content) else {
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
            // two-step never approves from the notification, and neither does text or amounts Trio didn't sign.
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
            remember(prompt)
            DispatchQueue.main.async {
                self.presented = prompt
            }
        default:
            Task { await WatchLogger.shared.log("AI requests: unknown action \(response.actionIdentifier) for \(prompt.id)") }
        }
    }

    /// The iPhone's backup, forwarded to the wrist, opens the watch's own approval screen for its request while that
    /// request is still open. A request the service pushed while the app wasn't in front never reached the app, so
    /// it's looked for among the delivered notifications too.
    private func openFromPhoneBackup(_ response: UNNotificationResponse, completionHandler: @escaping () -> Void) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let id = response.notification.request.content.userInfo[AIRequestIdentifiers.backupRequestIDKey] as? String
        else {
            let action = response.actionIdentifier
            Task { await WatchLogger.shared.log("AI requests: ignored \(action) on the iPhone's notification") }
            completionHandler()
            return
        }
        if let prompt = knownPrompt(id) {
            openIfStillOpen(prompt)
            completionHandler()
            return
        }
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let prompt = notifications.lazy
                .map(\.request.content)
                .filter { AIRequestIdentifiers.requestID(in: $0.userInfo) == id }
                .compactMap { Self.prompt(in: $0) }
                .first
            if let prompt {
                self.remember(prompt)
                self.openIfStillOpen(prompt)
            } else {
                Self.logNotOpening(id, because: "the watch hasn't seen it")
            }
            completionHandler()
        }
    }

    private func openIfStillOpen(_ prompt: AIRequestPrompt) {
        guard isOpen(prompt) else {
            Self.logNotOpening(prompt.id, because: "it expired or was withdrawn")
            return
        }
        DispatchQueue.main.async {
            self.presented = prompt
        }
    }

    private static func logNotOpening(_ id: String, because reason: String) {
        Task { await WatchLogger.shared.log("AI requests: not opening \(id) from the iPhone's notification: \(reason)") }
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
