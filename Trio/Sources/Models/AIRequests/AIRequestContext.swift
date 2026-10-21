import Foundation

/// Which test request the iPhone sent, so the approval says it's a test.
enum AIRequestTestKind: String, Codable {
    /// Goes through every check, then reports the dose it would give. Nothing is logged or given.
    case dryRun
    /// Logs the carbs and gives Trio's real dose, like an assistant's request.
    case real
}

/// The facts Trio itself adds to a request, so the wearer sees them whatever the assistant said: the latest
/// glucose, carbs or insulin given a moment ago, and why the dose is 0 U. The approval screens show them as fixed rows.
///
/// trio-rc refuses the whole pending report if one value is outside its limits, and the request then never reaches
/// the watch. So a value is left out, never sent out of range: see `Limit`.
struct AIRequestContext: Codable, Equatable {
    /// The latest glucose with its trend, for example "142 mg/dL ↗".
    var glucose: String?
    /// How old the glucose is. Left out when it's unknown.
    var glucoseAgeMinutes: Int?
    /// The newest carbs entry from the last 15 minutes.
    var recentCarbs: Recent?
    /// The newest bolus that wasn't an automatic microbolus, from the last 30 minutes.
    var recentBolus: Recent?
    /// Why Trio's dose is 0 U, for example "glucose is low (52 mg/dL)". Set only when the dose is 0 U.
    var noDoseReason: String?

    /// A recent entry: its amount, as grams or units, and how long ago it was.
    struct Recent: Codable, Equatable {
        /// Grams with trailing zeros trimmed ("20", "12.5"), or units with two decimals ("3.00").
        let amount: String
        let minutesAgo: Int
    }
}

extension AIRequestContext {
    /// trio-rc's limits. Strings count UTF-16 code units, as the service's JavaScript does.
    enum Limit {
        static let glucose = 32
        static let amount = 16
        static let noDoseReason = 120
        /// Every minutes field is a whole number from 0 to this: a day.
        static let minutes = 1440
    }

    /// Whole minutes from `date` to `now`, or `nil` when `date` is in the future or more than a day ago.
    static func minutes(from date: Date, to now: Date) -> Int? {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 0, seconds <= TimeInterval(Limit.minutes * 60) else { return nil }
        return Int(seconds / 60)
    }

    /// `text` cut to at most `limit` UTF-16 units at a whole character, or `nil` when nothing is left: the service
    /// refuses an empty string, so the field is left out instead.
    static func fitted(_ text: String, toUTF16Units limit: Int) -> String? {
        var result = ""
        var length = 0
        for character in text {
            guard length + character.utf16.count <= limit else { break }
            result.append(character)
            length += character.utf16.count
        }
        return result.isEmpty ? nil : result
    }
}
