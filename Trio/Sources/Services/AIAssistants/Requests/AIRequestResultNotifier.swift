import Foundation
import UserNotifications

/// The iPhone's notification for a request that failed after the wearer approved it, wherever it was approved. A
/// success gets none: the screen the wearer answered on already said so. A request that failed without an approval
/// gets none either: nobody was waiting for it. Nor does a failure whose Treatments sheet is up.
final class AIRequestResultNotifier {
    private let center: AIRequestNotificationScheduling
    /// Whether the Treatments sheet of the request with this ID is up, which takes Trio being in front. It's
    /// called on the main queue.
    private let isShowing: (String) -> Bool

    init(center: AIRequestNotificationScheduling, isShowing: @escaping (String) -> Bool) {
        self.center = center
        self.isShowing = isShowing
    }

    func notify(_ outcome: AIRequestOutcome) {
        guard case .failed = outcome.report, outcome.approvedOn != nil, !isShowing(outcome.id) else { return }

        let message = AIRequestResultText.message(for: outcome)
        let content = UNMutableNotificationContent()
        content.title = message.headline
        content.subtitle = message.title
        content.body = message.detail
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = AIRequestIdentifiers.threadID

        // No trigger: it's delivered right away.
        center.add(UNNotificationRequest(
            identifier: "\(AIRequestIdentifiers.resultNotificationSlot)-\(outcome.id)",
            content: content,
            trigger: nil
        ))
        debug(.service, "AI requests: notified the iPhone that \(outcome.id) failed")
    }
}
