import Foundation
import UserNotifications

/// The names the phone and the watch share for an AI assistant's request: the notification categories
/// and actions, the WatchConnectivity message keys, and the key of the service's push payload.
enum AIRequestIdentifiers {
    // MARK: Notification categories

    static let categoryReview = "trio.request.review"
    static let categoryApprove = "trio.request.approve"
    static let categoryPhone = "trio.request.phone"

    // MARK: Notification actions

    static let actionReview = "AIRequest.review"
    static let actionApprove = "AIRequest.approve"
    static let actionDecline = "AIRequest.decline"

    // MARK: WatchConnectivity keys

    /// The shared answer key, sent from the phone to the watch.
    static let keyMessage = "aiRequestKey"
    /// The watch asks the phone for a (new) answer key.
    static let keyRequest = "aiRequestKeyRequest"
    /// A request for the watch to show, as JSON-encoded `AIRequestPrompt`.
    static let keyPrompt = "aiRequestPrompt"
    /// The ID of a request the watch should stop showing.
    static let keyWithdraw = "aiRequestWithdraw"
    /// The watch's answer, as JSON-encoded `AIRequestAnswer`.
    static let keyAnswer = "aiRequestAnswer"
    /// The watch's push token, as hex, for the service to reach the watch directly.
    static let keyWatchPushToken = "aiWatchPushToken"
    /// How a request ended, as JSON-encoded `AIRequestResultMessage`, sent from the phone to the watch.
    static let keyResult = "aiRequestResult"
    /// The ID of the request whose approval screen the watch has opened, sent from the watch to the phone so its
    /// backup waits.
    static let keyViewing = "aiRequestViewing"

    // MARK: Notification slots

    /// The identifier of a request's notification, so a newer request takes the place of an older one.
    static let notificationSlot = "ai-request"
    /// The identifier of a result's notification.
    static let resultNotificationSlot = "ai-request-result"
    /// The thread that groups the request, backup and result notifications.
    static let threadID = "trio.ai-request"

    // MARK: Push payload

    /// The top-level key of the service's push payload.
    static let pushPayloadKey = "trio-rc"

    static func category(for style: AIRequestApprovalStyle) -> String {
        switch style {
        case .twoStep:
            return categoryReview
        case .oneGesture:
            return categoryApprove
        }
    }

    /// The two categories the watch registers. Double tap runs the first action that isn't destructive, so
    /// the action to take comes first and Decline last.
    static func watchCategories() -> Set<UNNotificationCategory> {
        let review = UNNotificationAction(
            identifier: actionReview,
            title: String(localized: "Review", comment: "Open an AI assistant's request on the watch to review it"),
            options: [.foreground]
        )
        let approve = UNNotificationAction(
            identifier: actionApprove,
            title: String(localized: "Approve", comment: "Approve an AI assistant's request from the notification"),
            options: [.authenticationRequired]
        )
        let decline = UNNotificationAction(
            identifier: actionDecline,
            title: String(localized: "Decline", comment: "Decline an AI assistant's request from the notification"),
            options: [.destructive]
        )

        // `.customDismissAction`, so that swiping a request away reaches the app and counts as a decline.
        return [
            UNNotificationCategory(
                identifier: categoryReview,
                actions: [review, decline],
                intentIdentifiers: [],
                options: [.customDismissAction]
            ),
            UNNotificationCategory(
                identifier: categoryApprove,
                actions: [approve, decline],
                intentIdentifiers: [],
                options: [.customDismissAction]
            )
        ]
    }

    /// The category of the iPhone's backup notification. It has no actions: tapping it opens Trio.
    static func phoneCategory() -> UNNotificationCategory {
        UNNotificationCategory(identifier: categoryPhone, actions: [], intentIdentifiers: [], options: [])
    }
}
