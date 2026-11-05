import Foundation
import UserNotifications

/// A notification a settings test posts: its result is ready, it ended with none, or a step waits on the user. One per
/// kind and slot at a time, so a newer one replaces the older.
struct SettingsTestNotice: Equatable {
    enum Slot: String {
        /// The test is over: a result is ready, or it ended with no verdict.
        case ended
        /// A step of a running test waits on the user.
        case step
    }

    let kind: SettingsTestKind
    let slot: Slot
    let title: String
    let body: String

    var identifier: String { Self.identifier(kind, slot) }

    static func identifier(_ kind: SettingsTestKind, _ slot: Slot) -> String {
        "Trio.settingsTest.\(kind.rawValue).\(slot.rawValue)"
    }

    /// The category of every settings test notification, so a tap on one can be told from any other.
    static let category = "Trio.settingsTest"
    /// The userInfo key holding the `SettingsTestKind` a tap opens.
    static let kindKey = "settingsTestKind"
    /// Said once a test that ended with no verdict has put the usual mode back.
    static let modeBackSentence = String(localized: "Your usual dosing mode is back.")

    /// The test has a result with a verdict.
    static func finished(_ kind: SettingsTestKind) -> SettingsTestNotice {
        switch kind {
        case .isf:
            return SettingsTestNotice(
                kind: kind,
                slot: .ended,
                title: String(localized: "ISF Test Finished"),
                body: String(localized: "Your result is ready. Tap to see what your ISF did.")
            )
        case .basal:
            return SettingsTestNotice(
                kind: kind,
                slot: .ended,
                title: String(localized: "Basal Test Finished"),
                body: String(localized: "Your result is ready. Tap to see how your basal held up.")
            )
        case .carbRatio:
            return SettingsTestNotice(
                kind: kind,
                slot: .ended,
                title: String(localized: "Carb Ratio Test Finished"),
                body: String(localized: "Your result is ready. Tap to see what your carb ratio did.")
            )
        }
    }

    /// The test ended with no verdict. The body is the sentence the Result screen shows, then the usual mode being
    /// back when it is and the sentence doesn't already say so.
    static func ended(_ kind: SettingsTestKind, sentence: String, modeBack: Bool) -> SettingsTestNotice {
        let title: String
        switch kind {
        case .isf: title = String(localized: "ISF Test Ended")
        case .basal: title = String(localized: "Basal Test Ended")
        case .carbRatio: title = String(localized: "Carb Ratio Test Ended")
        }
        let body = modeBack && !sentence.contains(modeBackSentence) ? sentence + " " + modeBackSentence : sentence
        return SettingsTestNotice(kind: kind, slot: .ended, title: title, body: body)
    }

    /// A step of a running ISF test that waits on the user.
    static func isfStep(_ step: ISFTestStepNotice) -> SettingsTestNotice {
        switch step {
        case .settledToDose:
            return SettingsTestNotice(
                kind: .isf,
                slot: .step,
                title: String(localized: "ISF Dose Ready"),
                body: String(localized: "Settling is done. Tap to see your dose.")
            )
        case .settledToRaise:
            return SettingsTestNotice(
                kind: .isf,
                slot: .step,
                title: String(localized: "ISF Test Settled"),
                body: String(localized: "Settling is done. Tap to see how many tablets to take.")
            )
        case .tabletsActed:
            return SettingsTestNotice(
                kind: .isf,
                slot: .step,
                title: String(localized: "ISF Dose Ready"),
                body: String(localized: "Your glucose rose from the tablets and leveled off. Tap to see your dose.")
            )
        case .timeUp:
            return SettingsTestNotice(
                kind: .isf,
                slot: .step,
                title: String(localized: "ISF Test Waiting"),
                body: String(
                    localized: "Insulin on board is still over the line after an hour. Tap to count it and go on, or cancel."
                )
            )
        }
    }
}

/// What a runner posts its notices through.
protocol SettingsTestNotifying: AnyObject {
    func post(_ notice: SettingsTestNotice)
    func withdraw(_ kind: SettingsTestKind, _ slot: SettingsTestNotice.Slot)
    /// Withdraws, pending and delivered, the fixed-time notifications the screens scheduled before the update
    /// (`SettingsTestNotifier.legacyIdentifiers`), posting nothing: for every ending, including those that post no notice.
    func withdrawLegacy()
}

/// The calls the notifier makes, so tests can record them. `UNUserNotificationCenter` conforms in an empty extension.
protocol SettingsTestNotificationCenter: AnyObject {
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable(Error?) -> Void)?)
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: SettingsTestNotificationCenter {}

/// Posts each notice at once (no trigger), with the category and kind a tap reads (`SettingsTestHooks`).
final class SettingsTestNotifier: SettingsTestNotifying {
    private let center: SettingsTestNotificationCenter

    init(center: SettingsTestNotificationCenter = UNUserNotificationCenter.current()) {
        self.center = center
    }

    /// The fixed-time notifications the screens used to schedule. Withdrawn (pending and delivered) on every post and on
    /// every ending (`withdrawLegacy`), so one still waiting from before the update can't fire after the test is over.
    static let legacyIdentifiers = ["Trio.isfTestFinished", "Trio.basalTestFinished"]

    static func content(for notice: SettingsTestNotice) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        content.categoryIdentifier = SettingsTestNotice.category
        content.userInfo = [SettingsTestNotice.kindKey: notice.kind.rawValue]
        return content
    }

    func post(_ notice: SettingsTestNotice) {
        withdrawLegacy()
        let identifier = notice.identifier
        center.add(
            UNNotificationRequest(identifier: identifier, content: Self.content(for: notice), trigger: nil),
            withCompletionHandler: { error in
                // Refused, with notifications turned off, say: kept as a trace, since nothing else shows it.
                if let error {
                    warning(.settings, "SettingsTest: couldn't post the \(identifier) notification", error: error)
                }
            }
        )
    }

    func withdraw(_ kind: SettingsTestKind, _ slot: SettingsTestNotice.Slot) {
        let identifier = SettingsTestNotice.identifier(kind, slot)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func withdrawLegacy() {
        center.removePendingNotificationRequests(withIdentifiers: Self.legacyIdentifiers)
        center.removeDeliveredNotifications(withIdentifiers: Self.legacyIdentifiers)
    }
}
