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

    // MARK: Notification slots

    /// The identifier of the watch's request notification, so a newer request takes the place of an older one there. The
    /// iPhone's backup is still one per request: its identifier adds the request's ID to this.
    static let notificationSlot = "ai-request"
    /// The identifier of a result's notification.
    static let resultNotificationSlot = "ai-request-result"
    /// The thread that groups the request, backup and result notifications.
    static let threadID = "trio.ai-request"

    // MARK: Notification payloads

    /// The top-level key of the service's push payload.
    static let pushPayloadKey = "trio-rc"
    /// The `userInfo` key of the iPhone's backup notification that holds the request's ID. The watch reads it when the
    /// backup is forwarded to the wrist.
    static let backupRequestIDKey = "aiRequestId"

    /// The ID of the request a request notification is for, from either payload: the watch's own notification holds
    /// the JSON prompt under `keyPrompt`, and the service's push holds the ID at `trio-rc.request.id`. `nil` for any
    /// other notification.
    static func requestID(in userInfo: [AnyHashable: Any]) -> String? {
        if let data = userInfo[keyPrompt] as? Data {
            return (try? JSONDecoder().decode(RequestID.self, from: data))?.id
        }
        guard let payload = userInfo[pushPayloadKey] as? [String: Any],
              let request = payload["request"] as? [String: Any]
        else { return nil }
        return request["id"] as? String
    }

    /// Just the ID of a JSON prompt, so a prompt that no longer decodes in full still says which request it is.
    private struct RequestID: Decodable {
        let id: String
    }

    static func category(for style: AIRequestApprovalStyle) -> String {
        switch style {
        case .twoStep:
            return categoryReview
        case .oneGesture:
            return categoryApprove
        }
    }

    /// The categories the watch registers: a request's two, and the iPhone's backup, which the watch opens when it's
    /// forwarded to the wrist. Double tap runs the first action that isn't destructive, so the action to take comes
    /// first and Decline last.
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
            ),
            phoneCategory()
        ]
    }

    /// The category of the iPhone's backup notification. It has no actions: tapping it opens Trio.
    static func phoneCategory() -> UNNotificationCategory {
        UNNotificationCategory(identifier: categoryPhone, actions: [], intentIdentifiers: [], options: [])
    }
}
