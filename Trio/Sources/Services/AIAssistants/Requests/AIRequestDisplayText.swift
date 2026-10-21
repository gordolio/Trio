import Foundation

/// The notification text the wearer sees for a request, for example "ChatGPT: slice of pizza" over
///
///     Bolus 2.10 U · 35 g carbs
///
/// and, when Trio's dose is 0 U, over
///
///     No bolus · 35 g carbs
///     Trio suggests no insulin now: glucose is low (52 mg/dL)
///
/// Each amount in grams or units sits next to its unit with a no-break space (U+00A0), so a line never wraps between
/// them. Nothing else about the wearer's glucose, carbs or insulin is in it: the screens the request opens show them.
enum AIRequestDisplayText {
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

    /// The title and body of a request: the dose line, and for a 0 U dose why. `noDoseReason` is a reason Trio knows is
    /// true, for example "glucose is low (52 mg/dL)", or `nil` when it knows none.
    static func display(
        source: String,
        description: String,
        shown: AIRequestShown,
        noDoseReason: String?
    ) -> AIRequestDisplay {
        AIRequestDisplay(
            title: title(source: source, description: description),
            body: body(shown: shown, noDoseReason: noDoseReason)
        )
    }

    private static func body(shown: AIRequestShown, noDoseReason: String?) -> String {
        let givesNoBolus = Self.givesNoBolus(shown)
        let carbs = trimmed(shown.carbs)
        var lines: [String] = []

        lines.append(
            givesNoBolus
                ? String(
                    localized: "No bolus · \(carbs)\u{00A0}g carbs",
                    comment: "Request notification, first line when Trio's dose is 0 U: the carbs. The no-break space keeps the number with its unit."
                )
                : String(
                    localized: "Bolus \(shown.units)\u{00A0}U · \(carbs)\u{00A0}g carbs",
                    comment: "Request notification, first line: Trio's dose, then the carbs. The no-break spaces keep each number with its unit."
                )
        )

        if let reason = noDoseReason, !reason.isEmpty {
            lines.append(String(
                localized: "Trio suggests no insulin now: \(reason)",
                comment: "Request notification: why Trio's dose is 0 U. The placeholder is the reason, for example 'glucose is low (52 mg/dL)'."
            ))
        } else if givesNoBolus {
            // Trio only says a reason it knows is true.
            lines.append(String(
                localized: "Trio suggests no insulin now",
                comment: "Request notification: Trio's dose is 0 U and there's no reason to give"
            ))
        }
        return cappedBody(lines.joined(separator: "\n"))
    }

    /// Whether Trio's dose is 0 U. An amount that can't be read counts as a dose, so nothing says there's none.
    private static func givesNoBolus(_ shown: AIRequestShown) -> Bool {
        (Decimal(string: shown.units, locale: Locale(identifier: "en_US_POSIX")) ?? 1) <= 0
    }

    /// A number as text without trailing zeros: "35.00" is "35", "12.50" is "12.5".
    private static func trimmed(_ amount: String) -> String {
        Decimal(string: amount)?.description ?? amount
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

    /// Like `capped`, but the cut never falls inside a number and its unit ("2.10 U", "35 g", "6 min"): a cut amount
    /// would read as a different one. The cut moves back to the amount's start, and the text left ends clear of the
    /// separator before it.
    private static func cappedBody(_ text: String) -> String {
        guard text.utf16.count > maxLength else { return text }
        let characters = Array(text)
        var count = 0
        var length = 0
        for character in characters {
            // "…" is one UTF-16 unit.
            guard length + character.utf16.count <= maxLength - 1 else { break }
            length += character.utf16.count
            count += 1
        }
        if let amount = amountRanges(in: characters).first(where: { $0.lowerBound < count && count < $0.upperBound }) {
            count = amount.lowerBound
        }
        var kept = characters[..<count]
        while let last = kept.last, last.isWhitespace || last == "·" {
            kept = kept.dropLast()
        }
        return String(kept) + "…"
    }

    /// Where the numbers are, each with the unit word after it when there is one: "2.10 U", "35 g", "142 mg/dL".
    private static func amountRanges(in characters: [Character]) -> [Range<Int>] {
        func isDigit(_ character: Character) -> Bool { ("0" ... "9").contains(character) }
        var ranges: [Range<Int>] = []
        var index = 0
        while index < characters.count {
            guard isDigit(characters[index]) else {
                index += 1
                continue
            }
            var end = index
            while end < characters.count, isDigit(characters[end]) || characters[end] == "." {
                end += 1
            }
            // A full stop after the number ends a sentence, it isn't part of the number.
            while end > index + 1, characters[end - 1] == "." {
                end -= 1
            }
            var unitEnd = end
            if end + 1 < characters.count, characters[end] == " " || characters[end] == "\u{00A0}", characters[end + 1].isLetter {
                unitEnd = end + 1
                while unitEnd < characters.count, characters[unitEnd].isLetter || characters[unitEnd] == "/" {
                    unitEnd += 1
                }
            }
            ranges.append(index ..< unitEnd)
            index = unitEnd
        }
        return ranges
    }

    /// "142 mg/dL", or "7.9 mmol/L" to one decimal. `displayUnits` is a `GlucoseUnits` raw value.
    static func value(mgdl: Int, displayUnits: String) -> String {
        if displayUnits == GlucoseUnits.mmolL.rawValue {
            let mmol = NSDecimalNumber(decimal: mgdl.asMmolL).doubleValue
            return "\(String(format: "%.1f", mmol)) \(GlucoseUnits.mmolL.rawValue)"
        }
        return "\(mgdl) \(GlucoseUnits.mgdL.rawValue)"
    }
}
