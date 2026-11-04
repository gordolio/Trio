import Foundation
import UserNotifications

/// The notification center's delegate from launch, until `BaseUserNotificationsManager` takes its place.
///
/// iOS hands a tap on a notification to the app's `UNUserNotificationCenter` delegate as the app starts, and answers
/// "response not possible" when there is none. Trio sets its delegate in `BaseUserNotificationsManager.init`, which the app
/// resolves only after its Core Data stack has loaded, so a tap that launches Trio from closed arrived with nobody to take
/// it and opened Home. This delegate is set in `application(_:didFinishLaunchingWithOptions:)`, so the tap on a settings
/// test's notice reaches the opener; any other response is answered and dropped, as it was. When the notifications manager
/// sets itself as the delegate it replaces this one.
///
/// It has no `willPresent`: nothing was shown in that window before and nothing is now.
final class SettingsTestLaunchNotifications: NSObject, UNUserNotificationCenterDelegate {
    /// The center keeps its delegate weakly, so this one is held here.
    static let shared = SettingsTestLaunchNotifications()

    /// Makes this the center's delegate when it has none yet. Returns whether it did.
    @discardableResult static func install(
        on center: some SettingsTestDelegateHolder = UNUserNotificationCenter
            .current()
    ) -> Bool {
        guard center.delegate == nil else { return false }
        center.delegate = shared
        return true
    }

    /// A settings test's notice opens its screen; any other response only gets its completion handler, once.
    @discardableResult static func handle(
        category: String,
        userInfo: [AnyHashable: Any],
        completion: @escaping () -> Void,
        open: @escaping @MainActor(SettingsTestKind) -> Void = { kind in _ = SettingsTestScreenOpener.shared.open(kind) }
    ) -> Bool {
        if SettingsTestHooks.didReceive(category: category, userInfo: userInfo, completion, open: open) { return true }
        completion()
        return false
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        Self.handle(category: content.categoryIdentifier, userInfo: content.userInfo, completion: completionHandler)
    }
}

/// What the launch delegate needs of the notification center, so a test can hold the delegate in its own object.
protocol SettingsTestDelegateHolder: AnyObject {
    var delegate: UNUserNotificationCenterDelegate? { get set }
}

extension UNUserNotificationCenter: SettingsTestDelegateHolder {}

extension SettingsTestHooks {
    /// The one-line hook `AppDelegate` calls at launch: sets the early delegate (`SettingsTestLaunchNotifications`) so a tap on
    /// a test's notice that starts Trio from closed isn't lost. Leaves a delegate that is already set.
    static func installLaunchDelegate() {
        SettingsTestLaunchNotifications.install()
    }
}
