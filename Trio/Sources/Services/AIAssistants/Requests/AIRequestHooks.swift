import Foundation
import UIKit
import UserNotifications

/// The one-line hooks that upstream files call. A message or notification that isn't an AI request is left to
/// the file it's called from, which carries on as before.
enum AIRequestHooks {
    /// The watch's messages wait here while the runtime is being built, because the watch manager starts
    /// receiving them before the service that builds the runtime exists.
    static let watchMessages = AIRequestMessageHolder()

    /// Reads a message the watch sent to the phone. Returns `true` if it was a request message, so the watch
    /// manager must not handle it.
    static func phoneReceivedFromWatch(_ message: [String: Any]) -> Bool {
        watchMessages.handle(message)
    }

    /// Chooses how the iPhone shows a notification while Trio is open. Returns `true` if it was an AI request
    /// notification, so the notifications manager must not handle it: the iPhone backup shows as a banner, and
    /// the service's check-in push shows nothing.
    static func willPresent(
        _ notification: UNNotification,
        _ completion: @escaping (UNNotificationPresentationOptions) -> Void
    ) -> Bool {
        let content = notification.request.content
        guard let options = presentationOptions(category: content.categoryIdentifier, userInfo: content.userInfo) else {
            return false
        }
        completion(options)
        return true
    }

    /// Opens the approval screen when the wearer taps the iPhone backup. Returns `true` if it was one, so the
    /// notifications manager must not handle it. Any other notification is left alone, and the completion handler
    /// is called once for the ones it takes.
    static func didReceive(_ response: UNNotificationResponse, _ completion: @escaping () -> Void) -> Bool {
        let content = response.notification.request.content
        guard content.categoryIdentifier == AIRequestIdentifiers.categoryPhone else { return false }
        if let id = content.userInfo[AIRequestPhoneBackup.requestIDKey] as? String {
            Task { @MainActor in AIRequestPhoneApprovalPresenter.shared.open(requestID: id) }
        }
        completion()
        return true
    }

    /// `nil` if Trio's notifications manager decides.
    static func presentationOptions(
        category: String,
        userInfo: [AnyHashable: Any]
    ) -> UNNotificationPresentationOptions? {
        if category == AIRequestIdentifiers.categoryPhone { return [.banner, .sound, .list] }
        if isCheckIn(userInfo) { return [] }
        return nil
    }

    /// Whether the service's push is a check-in: it asks Trio to check in with the service, and shows nothing.
    static func isCheckIn(_ userInfo: [AnyHashable: Any]) -> Bool {
        let payload = userInfo[AIRequestIdentifiers.pushPayloadKey] as? [String: Any]
        return payload?["type"] as? String == "check-in"
    }

    /// Checks in for the service's check-in push. Returns `true` if it was one, so the app delegate must not
    /// handle it; the completion handler is then called once, when the check-in finishes.
    static func handleRemoteNotification(
        _ userInfo: [AnyHashable: Any],
        _ completion: @escaping (UIBackgroundFetchResult) -> Void
    ) -> Bool {
        handleRemoteNotification(userInfo, checkIn: AIRequestsRuntime.shared?.checkIn, completion)
    }

    /// `checkIn` is `nil` until the runtime is built. A push before then is left to the next loop's check-in.
    static func handleRemoteNotification(
        _ userInfo: [AnyHashable: Any],
        checkIn: AIAssistantsCheckIn?,
        _ completion: @escaping (UIBackgroundFetchResult) -> Void
    ) -> Bool {
        guard isCheckIn(userInfo) else { return false }
        guard let checkIn else {
            debug(.service, "AI requests: a check-in push arrived before the runtime, the next loop checks in")
            completion(.noData)
            return true
        }
        Task {
            await checkIn.checkIn(reason: .push)
            completion(.newData)
        }
        return true
    }
}

/// Passes the watch's request messages to a receiver. Until there is one, it holds them and passes them on, in
/// the order they came, once the receiver is set. A queued answer or key request is delivered right after
/// launch, before the runtime exists, and would otherwise be lost.
final class AIRequestMessageHolder {
    typealias Receiver = ([String: Any]) -> Bool

    private static let requestKeys = [
        AIRequestIdentifiers.keyRequest,
        AIRequestIdentifiers.keyAnswer,
        AIRequestIdentifiers.keyWatchPushToken
    ]

    private let lock = NSLock()
    private var receiver: Receiver?
    private var held: [[String: Any]] = []
    /// While the held messages are passed on, a new one waits behind them.
    private var isReplaying = false

    /// Returns `true` if the message is a request message: the receiver handled it, or it's held for the
    /// receiver. Any other message is left to the caller.
    func handle(_ message: [String: Any]) -> Bool {
        enum Action {
            case receive(Receiver)
            case hold
            case leave
        }
        let action = lock.withLock { () -> Action in
            if let receiver, !isReplaying {
                return .receive(receiver)
            }
            guard Self.requestKeys.contains(where: { message[$0] != nil }) else { return .leave }
            held.append(message)
            return .hold
        }
        switch action {
        case let .receive(receiver):
            return receiver(message)
        case .hold:
            debug(.service, "AI requests: held a watch message until the runtime is ready")
            return true
        case .leave:
            return false
        }
    }

    /// Sets the receiver, and passes it the messages held so far. `nil` holds messages again.
    func install(_ newReceiver: Receiver?) {
        lock.withLock { receiver = newReceiver }
        replayHeld()
    }

    private func replayHeld() {
        while true {
            let next = lock.withLock { () -> (Receiver, [String: Any])? in
                guard let receiver, !held.isEmpty else {
                    isReplaying = false
                    return nil
                }
                isReplaying = true
                return (receiver, held.removeFirst())
            }
            guard let (receiver, message) = next else { return }
            _ = receiver(message)
        }
    }
}
