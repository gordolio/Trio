import Foundation
import UserNotifications

/// The part of the notification center the phone backup uses, so tests can stand in for it.
protocol AIRequestNotificationScheduling: AnyObject {
    func add(_ request: UNNotificationRequest)
    func removePending(_ ids: [String])
    func removeDelivered(_ ids: [String])
    func getNotificationCategories(completionHandler: @escaping @Sendable(Set<UNNotificationCategory>) -> Void)
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    /// The identifiers of the notifications in Notification Center.
    func deliveredIDs() async -> [String]
}

extension UNUserNotificationCenter: AIRequestNotificationScheduling {
    func add(_ request: UNNotificationRequest) {
        add(request) { error in
            if let error {
                debug(.service, "AI requests: couldn't schedule the iPhone request: \(error.localizedDescription)")
            }
        }
    }

    func removePending(_ ids: [String]) {
        removePendingNotificationRequests(withIdentifiers: ids)
    }

    func removeDelivered(_ ids: [String]) {
        removeDeliveredNotifications(withIdentifiers: ids)
    }

    func deliveredIDs() async -> [String] {
        await deliveredNotifications().map(\.request.identifier)
    }
}

/// The iPhone's backup for a request: a time-sensitive notification that opens Trio's approval screen, which
/// asks for Face ID before it approves.
final class AIRequestPhoneBackup: AIRequestPhoneBackupScheduling {
    /// The `userInfo` key that holds the request's ID.
    static let requestIDKey = "aiRequestId"

    private let center: AIRequestNotificationScheduling

    init(center: AIRequestNotificationScheduling = UNUserNotificationCenter.current()) {
        self.center = center
    }

    func schedule(_ prompt: AIRequestPrompt, after delay: TimeInterval) {
        registerCategory()

        let content = UNMutableNotificationContent()
        content.title = prompt.title
        content.body = String(
            localized: "\(prompt.body) · Tap to approve with Face ID",
            comment: "The body of the iPhone notification that asks to approve an AI assistant's request"
        )
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = AIRequestIdentifiers.categoryPhone
        content.userInfo = [Self.requestIDKey: prompt.id]

        // A trigger needs an interval above 0, and no trigger delivers right away.
        let trigger = delay > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false) : nil
        center.add(UNNotificationRequest(identifier: Self.identifier(for: prompt.id), content: content, trigger: trigger))
        debug(.service, "AI requests: scheduled the iPhone request for \(prompt.id) after \(delay) s")
    }

    func cancel(id: String) {
        center.removePending([Self.identifier(for: id)])
        center.removeDelivered([Self.identifier(for: id)])
    }

    /// Whether the iPhone is asking for the request now, so opening Trio may show it: it was asked on the iPhone,
    /// or its notification has been delivered. Before that, the watch is still asking alone.
    func isDue(_ pending: PendingAIRequest) async -> Bool {
        if pending.askedOn == .phone { return true }
        return await center.deliveredIDs().contains(Self.identifier(for: pending.request.id))
    }

    private static func identifier(for requestID: String) -> String {
        "ai-request-\(requestID)"
    }

    /// Adds the phone category to the categories Trio has already registered. It's done when a request is
    /// scheduled rather than at launch: Trio registers its own categories at launch in the same way, by reading
    /// them and writing them back, and two of those running together would lose one of the changes.
    private func registerCategory() {
        center.getNotificationCategories { [center] existing in
            var categories = existing.filter { $0.identifier != AIRequestIdentifiers.categoryPhone }
            categories.insert(AIRequestIdentifiers.phoneCategory())
            center.setNotificationCategories(categories)
        }
    }
}
