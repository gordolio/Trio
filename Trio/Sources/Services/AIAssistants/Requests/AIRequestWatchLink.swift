import Combine
import Foundation
import WatchConnectivity

/// The part of WatchConnectivity the link uses, so tests can stand in for it.
protocol AIRequestWatchSession: AnyObject {
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }
    var isReachable: Bool { get }
    /// Sends now, and queues the same message as user info if it can't be sent.
    func sendMessage(_ message: [String: Any])
    /// Queues the user info for the watch's next launch or wake. It's the same as `transferUserInfo`, which
    /// returns a transfer that a `Void` requirement can't match.
    func queueUserInfo(_ userInfo: [String: Any])
}

extension WCSession: AIRequestWatchSession {
    func sendMessage(_ message: [String: Any]) {
        sendMessage(message, replyHandler: nil) { [weak self] error in
            debug(.service, "AI requests: couldn't message the watch, queueing it instead: \(error.localizedDescription)")
            self?.queueUserInfo(message)
        }
    }

    func queueUserInfo(_ userInfo: [String: Any]) {
        transferUserInfo(userInfo)
    }
}

/// The phone's side of the watch's requests: reads what the watch sends, which is the request the wearer opened,
/// confirmed or closed on the watch, or the watch's push token. It sends the request's details when the watch opens it,
/// the acknowledgement of a confirmation, the ending of a request whose screen is open there, and whether the wearer
/// allows meal requests.
final class AIRequestWatchLink: AIRequestWatchDelivery {
    static let watchPushTokenKey = "AIAssistants.watchPushToken"

    private let session: AIRequestWatchSession
    private let defaults: UserDefaults
    private let allowsMealRequests: () -> Bool
    private let onOpen: (String) -> Void
    private let onConfirm: (AIRequestWatchConfirm) -> Void
    private let onClose: (AIRequestWatchClose) -> Void
    private let onWatchTokenChanged: () -> Void
    private var preferencesSubscription: AnyCancellable?

    init(
        session: AIRequestWatchSession,
        defaults: UserDefaults = .standard,
        allowsMealRequests: @escaping () -> Bool,
        onOpen: @escaping (String) -> Void,
        onConfirm: @escaping (AIRequestWatchConfirm) -> Void,
        onClose: @escaping (AIRequestWatchClose) -> Void,
        onWatchTokenChanged: @escaping () -> Void
    ) {
        self.session = session
        self.defaults = defaults
        self.allowsMealRequests = allowsMealRequests
        self.onOpen = onOpen
        self.onConfirm = onConfirm
        self.onClose = onClose
        self.onWatchTokenChanged = onWatchTokenChanged
    }

    /// The watch's push token as hex, once the watch has sent it.
    private(set) var watchPushToken: String? {
        get { defaults.string(forKey: Self.watchPushTokenKey) }
        set { defaults.set(newValue, forKey: Self.watchPushTokenKey) }
    }

    /// A watch that has no push token couldn't be reached by the service, so the request is asked on the phone.
    var isWatchAvailable: Bool {
        session.isPaired && session.isWatchAppInstalled && watchPushToken != nil
    }

    /// Tells the watch each time the wearer turns meal requests on or off. The current value isn't sent: the watch hears
    /// it in answer to the push token it sends at each launch.
    func follow(_ preferences: AnyPublisher<AIAssistantsPreferences, Never>) {
        preferencesSubscription = preferences
            .map(\.allowsMealRequests)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] in self?.sendMealRequestsAllowed($0) }
    }

    /// Tells the watch whether the wearer allows meal requests. It asks to show notifications only once they do.
    private func sendMealRequestsAllowed(_ allowed: Bool) {
        send([AIRequestIdentifiers.keyMealRequestsAllowed: allowed])
    }

    /// Answers the watch's open: the request's amounts and Trio's dose for them.
    func sendDetails(_ details: AIRequestWatchDetails) {
        send(encoded: details, key: AIRequestIdentifiers.keyDetails)
    }

    /// Tells the watch the request it may have open left pending, so it closes that screen.
    func sendEnded(_ ended: AIRequestEnded) {
        send(encoded: ended, key: AIRequestIdentifiers.keyEnded)
    }

    /// Tells the watch how its confirmation went, in upstream's own acknowledgement, which the watch shows on its
    /// acknowledgement screen.
    func sendAcknowledgment(success: Bool, message: String) {
        let code = success ? BaseWatchManager.AcknowledgmentCode.genericSuccess : .genericFailure
        send([
            WatchMessageKeys.acknowledged: success,
            WatchMessageKeys.message: message,
            WatchMessageKeys.ackCode: code.rawValue
        ])
    }

    /// Handles a message from the watch. Returns `false` if it isn't one of the request messages, so the
    /// caller can handle it.
    func receive(_ message: [String: Any]) -> Bool {
        var handled = false
        if let opened = message[AIRequestIdentifiers.keyOpen] {
            handled = true
            if let id = opened as? String {
                onOpen(id)
            } else {
                debug(.service, "AI requests: ignored an open message without a request ID")
            }
        }
        if let confirm = message[AIRequestIdentifiers.keyConfirm] {
            handled = true
            if let confirm = decode(AIRequestWatchConfirm.self, from: confirm) {
                onConfirm(confirm)
            } else {
                debug(.service, "AI requests: couldn't read a confirmation from the watch")
            }
        }
        if let close = message[AIRequestIdentifiers.keyClose] {
            handled = true
            if let close = decode(AIRequestWatchClose.self, from: close) {
                onClose(close)
            } else {
                debug(.service, "AI requests: couldn't read a close from the watch")
            }
        }
        if let token = message[AIRequestIdentifiers.keyWatchPushToken] as? String {
            handled = true
            store(token)
            // The watch sends its token each time it launches.
            sendMealRequestsAllowed(allowsMealRequests())
        }
        return handled
    }

    // MARK: Sending

    private func send(_ message: [String: Any]) {
        if session.isReachable {
            session.sendMessage(message)
        } else {
            session.queueUserInfo(message)
        }
    }

    private func send(encoded message: some Encodable, key: String) {
        do {
            send([key: try JSONEncoder().encode(message)])
        } catch {
            debug(.service, "AI requests: couldn't encode a \(key) message for the watch: \(error)")
        }
    }

    // MARK: Receiving

    private func decode<Message: Decodable>(_ type: Message.Type, from value: Any) -> Message? {
        guard let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Keeps the token in lower case. One that isn't 64 to 200 hex digits is dropped: the service refuses the whole
    /// device registration for it, the phone's own push token included.
    private func store(_ token: String) {
        guard (64 ... 200).contains(token.count), token.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            debug(.service, "AI requests: ignored a watch push token that isn't 64 to 200 hex digits")
            return
        }
        let token = token.lowercased()
        guard token != watchPushToken else { return }
        watchPushToken = token
        onWatchTokenChanged()
    }
}
