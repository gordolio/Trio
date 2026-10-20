import Combine
import Foundation

/// Which kind of push wakes Trio for an AI assistant's request.
enum AIWakePushType: String, Codable, CaseIterable {
    case passive
    case timeSensitive
    case background
}

/// How the wearer is asked to answer an AI assistant's request.
struct AIAssistantsPreferences: Equatable {
    var approvalStyle: AIRequestApprovalStyle = .twoStep
    /// Seconds before Trio also asks on the iPhone. One of `phoneBackupDelays`.
    var phoneBackupDelay: TimeInterval = 15
    var answerRoute: AIRequestAnswerRoute = .both
    var wakePushType: AIWakePushType = .passive

    static let phoneBackupDelays: [TimeInterval] = [0, 15, 30, 60]
}

/// Keeps the request preferences in `UserDefaults` and publishes every change. A stored value that isn't
/// one of the known choices reads as its default.
final class AIAssistantsPreferencesStore {
    private enum Key {
        static let approvalStyle = "AIAssistants.approvalStyle"
        static let phoneBackupDelay = "AIAssistants.phoneBackupDelay"
        static let answerRoute = "AIAssistants.answerRoute"
        static let wakePushType = "AIAssistants.wakePushType"
    }

    private let defaults: UserDefaults
    let changes: CurrentValueSubject<AIAssistantsPreferences, Never>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        changes = CurrentValueSubject(Self.read(from: defaults))
    }

    var value: AIAssistantsPreferences {
        get { Self.read(from: defaults) }
        set {
            defaults.set(newValue.approvalStyle.rawValue, forKey: Key.approvalStyle)
            defaults.set(newValue.phoneBackupDelay, forKey: Key.phoneBackupDelay)
            defaults.set(newValue.answerRoute.rawValue, forKey: Key.answerRoute)
            defaults.set(newValue.wakePushType.rawValue, forKey: Key.wakePushType)
            changes.send(value)
        }
    }

    var defaultsForTests: UserDefaults { defaults }

    private static func read(from defaults: UserDefaults) -> AIAssistantsPreferences {
        var preferences = AIAssistantsPreferences()
        if let raw = defaults.string(forKey: Key.approvalStyle), let style = AIRequestApprovalStyle(rawValue: raw) {
            preferences.approvalStyle = style
        }
        // `double(forKey:)` reads a missing key as 0, which is one of the choices, so check for the object.
        if let delay = defaults.object(forKey: Key.phoneBackupDelay) as? Double,
           AIAssistantsPreferences.phoneBackupDelays.contains(delay)
        {
            preferences.phoneBackupDelay = delay
        }
        if let raw = defaults.string(forKey: Key.answerRoute), let route = AIRequestAnswerRoute(rawValue: raw) {
            preferences.answerRoute = route
        }
        if let raw = defaults.string(forKey: Key.wakePushType), let type = AIWakePushType(rawValue: raw) {
            preferences.wakePushType = type
        }
        return preferences
    }
}
