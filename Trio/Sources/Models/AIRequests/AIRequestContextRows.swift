import Foundation

/// One of Trio's context rows for a request, as the notification body and the watch's approval screen show it.
struct AIRequestContextRow: Equatable {
    enum Kind: Equatable {
        /// The latest glucose with its trend, and its age once it's a couple of minutes old.
        case glucose
        /// Why Trio's dose is 0 U, or only that it is.
        case noDose
        /// Carbs logged a moment ago.
        case recentCarbs
        /// A bolus given a moment ago.
        case recentBolus
    }

    let kind: Kind
    let text: String
    /// Something to stop and check before approving: carbs or insulin given a moment ago. The watch shows it as a
    /// warning.
    let isWarning: Bool
}

/// Trio's context rows for a request, in the one order the notification body and the watch's approval screen both
/// show: the glucose, why the dose is 0 U, and carbs and insulin given a moment ago. A row appears only when it
/// applies. Grams and units sit next to their number with a no-break space (U+00A0); the glucose and the
/// minutes use plain spaces.
enum AIRequestContextRows {
    /// A reading is shown with its age from this many minutes old. A younger one is current.
    static let glucoseAgeShownFrom = 2

    /// The rows for a request. No context and an empty one give the same rows: only the 0 U row, when the dose is 0 U.
    /// No row is made up from a value that's missing.
    static func rows(context: AIRequestContext?, shown: AIRequestShown) -> [AIRequestContextRow] {
        let context = context ?? AIRequestContext()
        var rows: [AIRequestContextRow] = []

        if let glucose = nonEmpty(context.glucose) {
            var parts = [glucose]
            if let age = context.glucoseAgeMinutes, age >= glucoseAgeShownFrom {
                parts.append(String(
                    localized: "\(String(age)) min ago",
                    comment: "Request notification and watch approval: how old the glucose reading is, in minutes"
                ))
            }
            rows.append(AIRequestContextRow(kind: .glucose, text: parts.joined(separator: " · "), isWarning: false))
        }

        if let reason = nonEmpty(context.noDoseReason) {
            rows.append(AIRequestContextRow(
                kind: .noDose,
                text: String(
                    localized: "Trio suggests no insulin now: \(reason)",
                    comment: "Request notification and watch approval: why Trio's dose is 0 U. The placeholder is the reason, for example 'glucose is low (52 mg/dL)'."
                ),
                isWarning: false
            ))
        } else if givesNoBolus(shown) {
            // Trio only says a reason it knows is true.
            rows.append(AIRequestContextRow(
                kind: .noDose,
                text: String(
                    localized: "Trio suggests no insulin now",
                    comment: "Request notification and watch approval: Trio's dose is 0 U and there's no reason to give"
                ),
                isWarning: false
            ))
        }

        if let carbs = context.recentCarbs {
            rows.append(AIRequestContextRow(
                kind: .recentCarbs,
                text: String(
                    localized: "Carbs \(carbs.amount)\u{00A0}g logged \(String(carbs.minutesAgo)) min ago",
                    comment: "Request notification and watch approval: carbs logged a few minutes ago. The no-break space keeps the number with its unit."
                ),
                isWarning: true
            ))
        }
        if let bolus = context.recentBolus {
            rows.append(AIRequestContextRow(
                kind: .recentBolus,
                text: String(
                    localized: "Bolus \(bolus.amount)\u{00A0}U given \(String(bolus.minutesAgo)) min ago",
                    comment: "Request notification and watch approval: a bolus given a few minutes ago. The no-break space keeps the number with its unit."
                ),
                isWarning: true
            ))
        }
        return rows
    }

    /// The same rows with the warnings first, each group in the order it had. The watch shows them so where the crown
    /// fills a pinned bar while the rows scroll.
    static func warningsFirst(_ rows: [AIRequestContextRow]) -> [AIRequestContextRow] {
        rows.filter(\.isWarning) + rows.filter { !$0.isWarning }
    }

    /// Whether Trio's dose is 0 U. An amount that can't be read counts as a dose, so nothing says there's none.
    static func givesNoBolus(_ shown: AIRequestShown) -> Bool {
        (Decimal(string: shown.units, locale: Locale(identifier: "en_US_POSIX")) ?? 1) <= 0
    }

    private static func nonEmpty(_ text: String?) -> String? {
        text.flatMap { $0.isEmpty ? nil : $0 }
    }
}
