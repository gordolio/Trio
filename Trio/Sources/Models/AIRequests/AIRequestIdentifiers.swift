import Foundation
import UserNotifications

/// The names the phone and the watch share for an AI assistant's request: the notification categories
/// and actions, the WatchConnectivity message keys, and the key of the service's push payload.
enum AIRequestIdentifiers {
    // MARK: Notification categories

    static let categoryReview = "trio.request.review"
    static let categoryPhone = "trio.request.phone"
    /// The iPhone's notice that the request its Treatments sheet had open ended elsewhere, such as "Logged on your
    /// watch". It shows as a banner while Trio is open.
    static let categoryNotice = "trio.request.notice"

    // MARK: Notification actions

    static let actionReview = "AIRequest.review"

    // MARK: WatchConnectivity keys

    /// The watch's push token, as hex, for the service to reach the watch directly.
    static let keyWatchPushToken = "aiWatchPushToken"
    /// The ID of the request the wearer opened on the watch, as a `String`, sent from the watch to the phone. The
    /// phone answers with `keyDetails`.
    static let keyOpen = "aiRequestOpen"
    /// The request's amounts and Trio's dose for them, as JSON-encoded `AIRequestWatchDetails`, sent from the phone to
    /// the watch.
    static let keyDetails = "aiRequestDetails"
    /// What the wearer confirmed on the watch, as JSON-encoded `AIRequestWatchConfirm`, sent from the watch to the
    /// phone.
    static let keyConfirm = "aiRequestConfirm"
    /// The watch left the request without confirming it, as JSON-encoded `AIRequestWatchClose`, sent from the watch to
    /// the phone.
    static let keyClose = "aiRequestClose"
    /// The request left pending, so the watch closes its screen, as JSON-encoded `AIRequestEnded`, sent from the phone
    /// to the watch.
    static let keyEnded = "aiRequestEnded"
    /// Whether the wearer allows meal requests, as a `Bool`, sent from the phone to the watch. The watch asks to show
    /// notifications only once they're allowed.
    static let keyMealRequestsAllowed = "aiMealRequestsAllowed"

    // MARK: Notification slots

    /// The identifier of the watch's request notification, so a newer request takes the place of an older one there. The
    /// iPhone's backup is still one per request: its identifier adds the request's ID to this.
    static let notificationSlot = "ai-request"
    /// The identifier of the iPhone's notice that a request ended elsewhere (`categoryNotice`). It adds the request's ID.
    static let resultNotificationSlot = "ai-request-result"
    /// The thread that groups the request, backup and notice notifications.
    static let threadID = "trio.ai-request"

    // MARK: Notification payloads

    /// The top-level key of the service's push payload.
    static let pushPayloadKey = "trio-rc"
    /// The `userInfo` key of the iPhone's backup notification that holds the request's ID. The watch reads it when the
    /// backup is forwarded to the wrist.
    static let backupRequestIDKey = "aiRequestId"

    /// The ID of the request the service's push is for, at `trio-rc.request.id`. `nil` for any other notification.
    static func requestID(in userInfo: [AnyHashable: Any]) -> String? {
        guard let payload = userInfo[pushPayloadKey] as? [String: Any],
              let request = payload["request"] as? [String: Any]
        else { return nil }
        return request["id"] as? String
    }

    /// The categories the watch registers: a request's, whose Review opens it on the watch's Confirm screen, and the
    /// iPhone's backup, which the watch opens the same way when it's forwarded to the wrist.
    static func watchCategories() -> Set<UNNotificationCategory> {
        let review = UNNotificationAction(
            identifier: actionReview,
            title: String(localized: "Review", comment: "Open an AI assistant's request on the watch to review it"),
            options: [.foreground]
        )

        // `.customDismissAction`, so that swiping a request away reaches the app and counts as a decline.
        return [
            UNNotificationCategory(
                identifier: categoryReview,
                actions: [review],
                intentIdentifiers: [],
                options: [.customDismissAction]
            ),
            phoneCategory()
        ]
    }

    /// The category of the iPhone's backup notification. It has no actions: tapping it opens Trio.
    static func phoneCategory() -> UNNotificationCategory {
        UNNotificationCategory(identifier: categoryPhone, actions: [], intentIdentifiers: [], options: [])
    }
}
