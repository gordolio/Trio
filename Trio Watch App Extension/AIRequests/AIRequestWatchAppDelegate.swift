import Foundation
import WatchKit

/// Hands the watch's push token to the phone, so the service can send a request straight to the watch.
final class AIRequestWatchAppDelegate: NSObject, WKApplicationDelegate {
    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        AIRequestWatchCenter.shared.sendPushToken(hex)
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        Task { await WatchLogger.shared.log("AI requests: couldn't register for pushes: \(error)") }
    }
}
