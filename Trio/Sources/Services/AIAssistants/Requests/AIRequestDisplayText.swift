import Foundation

/// The notification text the wearer sees for a request, for example
/// "ChatGPT: slice of pizza" over "20 g carbs · 1.2 U · 142 mg/dL ↗ · last carbs 35 g, 4 min ago".
enum AIRequestDisplayText {
    /// Carbs entered more recently than this are shown, so a meal that's already logged stands out.
    private static let recentCarbsWindow: TimeInterval = 15 * 60

    /// The service refuses notification text longer than this many UTF-16 code units, which is what its
    /// JavaScript string length counts, so an emoji takes two.
    static let maxLength = 200

    static func title(source: String, description: String) -> String {
        capped("\(source): \(singleLine(description))")
    }

    /// The assistant's text on one line: each run of newlines and other control characters, with the spaces next to
    /// it, becomes one space, so the text can't add lines of its own, such as made-up amounts, above Trio's. A run at
    /// the start or the end is dropped.
    private static func singleLine(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var inRun = false
        for scalar in text.unicodeScalars {
            if isLineBreaking(scalar) {
                inRun = true
                while result.last?.properties.isWhitespace == true {
                    result.removeLast()
                }
                continue
            }
            if inRun {
                if scalar.properties.isWhitespace { continue }
                if !result.isEmpty { result.append(" ") }
                inRun = false
            }
            result.append(scalar)
        }
        return String(result)
    }

    /// Control characters (newlines, tabs, escapes) and the Unicode line and paragraph separators. Format
    /// characters such as the joiner inside 👨‍👩‍👧 stay.
    private static func isLineBreaking(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control,
             .lineSeparator,
             .paragraphSeparator:
            return true
        default:
            return false
        }
    }

    /// The food, the dose, the latest glucose if there is one, and the last carbs if they're recent.
    /// `displayUnits` is a `GlucoseUnits` raw value.
    static func body(
        carbs: Decimal,
        fat: Decimal,
        protein: Decimal,
        units: Decimal,
        glucose: StatusSnapshot.LatestGlucose?,
        displayUnits: String,
        lastCarbs: (grams: Decimal, at: Date)?,
        now: Date
    ) -> String {
        var food = "\(amount(carbs)) g carbs"
        if fat > 0 { food += ", \(amount(fat)) g fat" }
        if protein > 0 { food += ", \(amount(protein)) g protein" }

        var parts = [food, "\(amount(units)) U"]
        if let glucose {
            parts.append(reading(glucose, displayUnits: displayUnits))
        }
        if let lastCarbs {
            let age = now.timeIntervalSince(lastCarbs.at)
            if age >= 0, age < recentCarbsWindow {
                parts.append("last carbs \(amount(lastCarbs.grams)) g, \(Int(age / 60)) min ago")
            }
        }
        return capped(parts.joined(separator: " · "))
    }

    /// Text over `maxLength` is cut short, at a whole character, and ends with "…".
    private static func capped(_ text: String) -> String {
        guard text.utf16.count > maxLength else { return text }
        var result = ""
        var length = 0
        for character in text {
            // "…" is one UTF-16 unit.
            guard length + character.utf16.count <= maxLength - 1 else { break }
            result.append(character)
            length += character.utf16.count
        }
        return result + "…"
    }

    /// The arrow for a `BloodGlucose.Direction` raw value, or "" when there's no trend.
    static func arrow(_ direction: String?) -> String {
        guard let direction = direction.flatMap(BloodGlucose.Direction.init(rawValue:)) else { return "" }
        switch direction {
        case .doubleUp,
             .tripleUp:
            return "⇈"
        case .singleUp:
            return "↑"
        case .fortyFiveUp:
            return "↗"
        case .flat:
            return "→"
        case .fortyFiveDown:
            return "↘"
        case .singleDown:
            return "↓"
        case .doubleDown,
             .tripleDown:
            return "⇊"
        case .none,
             .notComputable,
             .rateOutOfRange:
            return ""
        }
    }

    /// "142 mg/dL ↗", or "7.9 mmol/L ↗" to one decimal.
    private static func reading(_ glucose: StatusSnapshot.LatestGlucose, displayUnits: String) -> String {
        let mmol = NSDecimalNumber(decimal: glucose.mgdl.asMmolL).doubleValue
        let value = displayUnits == GlucoseUnits.mmolL.rawValue
            ? "\(String(format: "%.1f", mmol)) \(GlucoseUnits.mmolL.rawValue)"
            : "\(glucose.mgdl) \(GlucoseUnits.mgdL.rawValue)"
        return [value, arrow(glucose.direction)].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Up to two decimals, rounded down so a dose never reads higher than what's delivered, with trailing zeros
    /// trimmed and a "." whatever the locale, like the rest of this English text.
    private static func amount(_ value: Decimal) -> String {
        rounded(value, scale: 2, roundingMode: .down).description
    }
}
