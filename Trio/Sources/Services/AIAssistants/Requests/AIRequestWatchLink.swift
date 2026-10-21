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

/// The phone's side of the watch's requests: shows a request on the watch, withdraws it, tells it how a request ended,
/// and reads what the watch sends back, which is a request for the answer key, a signed answer, the ID of the request
/// whose screen it opened, or the watch's push token.
final class AIRequestWatchLink: AIRequestWatchDelivery {
    static let watchPushTokenKey = "AIAssistants.watchPushToken"

    private let session: AIRequestWatchSession
    private let keys: AIRequestKeyStore
    private let defaults: UserDefaults
    private let onAnswer: (AIRequestAnswer) -> Void
    private let onViewing: (String) -> Void
    private let onWatchTokenChanged: () -> Void

    init(
        session: AIRequestWatchSession,
        keys: AIRequestKeyStore,
        defaults: UserDefaults = .standard,
        onAnswer: @escaping (AIRequestAnswer) -> Void,
        onViewing: @escaping (String) -> Void,
        onWatchTokenChanged: @escaping () -> Void
    ) {
        self.session = session
        self.keys = keys
        self.defaults = defaults
        self.onAnswer = onAnswer
        self.onViewing = onViewing
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

    func deliver(_ prompt: AIRequestPrompt) {
        do {
            let data = try JSONEncoder().encode(prompt)
            send([AIRequestIdentifiers.keyPrompt: data])
        } catch {
            debug(.service, "AI requests: couldn't encode \(prompt.id) for the watch: \(error)")
        }
    }

    func withdraw(id: String) {
        send([AIRequestIdentifiers.keyWithdraw: id])
    }

    /// Tells the watch how a request ended. It's always queued as user info, so a watch that is asleep or out of reach
    /// hears it when it wakes, and it's also sent live when the watch is reachable, so an open screen updates at once.
    /// The watch may get it twice, and keeps one result for each request ID.
    func sendResult(_ message: AIRequestResultMessage) {
        do {
            let payload: [String: Any] = [AIRequestIdentifiers.keyResult: try JSONEncoder().encode(message)]
            session.queueUserInfo(payload)
            if session.isReachable {
                session.sendMessage(payload)
            }
        } catch {
            debug(.service, "AI requests: couldn't encode the result of \(message.id) for the watch: \(error)")
        }
    }

    /// Handles a message from the watch. Returns `false` if it isn't one of the request messages, so the
    /// caller can handle it.
    func receive(_ message: [String: Any]) -> Bool {
        var handled = false
        if message[AIRequestIdentifiers.keyRequest] != nil {
            handled = true
            sendNewKey()
        }
        if let answer = message[AIRequestIdentifiers.keyAnswer] {
            handled = true
            forward(answer)
        }
        if let viewed = message[AIRequestIdentifiers.keyViewing] {
            handled = true
            if let id = viewed as? String {
                onViewing(id)
            } else {
                debug(.service, "AI requests: ignored a viewing message without a request ID")
            }
        }
        if let token = message[AIRequestIdentifiers.keyWatchPushToken] as? String {
            handled = true
            store(token)
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

    /// A new key each time, so answers signed by a reinstalled watch's old key no longer verify.
    private func sendNewKey() {
        guard let key = keys.rotate() else {
            debug(.service, "AI requests: couldn't make a new answer key")
            return
        }
        session.queueUserInfo([AIRequestIdentifiers.keyMessage: key.base64EncodedString()])
    }

    // MARK: Receiving

    private func forward(_ value: Any) {
        guard let data = value as? Data, let answer = try? JSONDecoder().decode(AIRequestAnswer.self, from: data) else {
            debug(.service, "AI requests: couldn't read an answer from the watch")
            return
        }
        onAnswer(answer)
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
