import Combine
import Foundation

/// Which kind of push wakes Trio for an AI assistant's request.
enum AIWakePushType: String, Codable, CaseIterable {
    case passive
    case timeSensitive
    case background
}

/// Whether, and how soon, the wearer is asked about an AI assistant's request.
struct AIAssistantsPreferences: Equatable {
    /// Whether Trio asks about an assistant's meal requests. When it's off, it refuses them without asking.
    var allowsMealRequests: Bool = false
    /// Seconds before Trio also asks on the iPhone. One of `phoneBackupDelays`.
    var phoneBackupDelay: TimeInterval = 15
    var wakePushType: AIWakePushType = .passive

    static let phoneBackupDelays: [TimeInterval] = [0, 15, 30, 60]
}

/// Keeps the request preferences in `UserDefaults` and publishes every change. A stored value that isn't
/// one of the known choices reads as its default. What an earlier build saved for settings that are gone stays where it
/// is, unread.
final class AIAssistantsPreferencesStore {
    private enum Key {
        static let allowsMealRequests = "AIAssistants.allowsMealRequests"
        static let phoneBackupDelay = "AIAssistants.phoneBackupDelay"
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
            defaults.set(newValue.allowsMealRequests, forKey: Key.allowsMealRequests)
            defaults.set(newValue.phoneBackupDelay, forKey: Key.phoneBackupDelay)
            defaults.set(newValue.wakePushType.rawValue, forKey: Key.wakePushType)
            changes.send(value)
        }
    }

    var defaultsForTests: UserDefaults { defaults }

    private static func read(from defaults: UserDefaults) -> AIAssistantsPreferences {
        var preferences = AIAssistantsPreferences()
        if let allows = defaults.object(forKey: Key.allowsMealRequests) as? Bool {
            preferences.allowsMealRequests = allows
        }
        // `double(forKey:)` reads a missing key as 0, which is one of the choices, so check for the object.
        if let delay = defaults.object(forKey: Key.phoneBackupDelay) as? Double,
           AIAssistantsPreferences.phoneBackupDelays.contains(delay)
        {
            preferences.phoneBackupDelay = delay
        }
        if let raw = defaults.string(forKey: Key.wakePushType), let type = AIWakePushType(rawValue: raw) {
            preferences.wakePushType = type
        }
        return preferences
    }
}
