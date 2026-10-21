import Foundation

/// The words for how a request ended: the spec's result and notification wording, the same on the watch, the iPhone
/// sheet and the notifications. The amounts are the ones the request showed: the dose as it was shown, with two
/// decimals, and the carbs with trailing zeros trimmed. A no-break space (U+00A0) joins each number to its unit, so a
/// line never breaks between them. The free-text reason is put in as it is.
enum AIRequestResultText {
    static func message(for outcome: AIRequestOutcome) -> AIRequestResultMessage {
        let words = words(for: outcome)
        return AIRequestResultMessage(
            id: outcome.id,
            title: outcome.title,
            headline: words.headline,
            detail: words.detail,
            tone: words.tone,
            answeredOn: answeredOn(outcome)
        )
    }

    private typealias Words = (headline: String, detail: String, tone: AIRequestResultMessage.Tone)

    private static func words(for outcome: AIRequestOutcome) -> Words {
        let source = outcome.source
        switch outcome.report {
        case let .delivering(shown):
            let units = shown.units
            let carbs = trimmed(shown.carbs)
            return (
                String(localized: "Bolus started: \(units)\u{00A0}U", comment: "Result headline: the pump took the bolus"),
                String(localized: "\(carbs)\u{00A0}g carbs logged.", comment: "Result detail: the carbs were logged"),
                .success
            )
        case let .logged(shown):
            let carbs = trimmed(shown.carbs)
            return (
                String(
                    localized: "\(carbs)\u{00A0}g carbs logged",
                    comment: "Result headline: the carbs were logged and Trio's dose was 0 U"
                ),
                String(
                    localized: "Trio's dose was 0\u{00A0}U, so no bolus.",
                    comment: "Result detail: the carbs were logged and Trio's dose was 0 U"
                ),
                .success
            )
        case let .failed(reason, carbsLogged):
            return failed(reason: reason, carbsLogged: carbsLogged, bolusUnconfirmed: outcome.bolusUnconfirmed)
        case let .declined(declinedOn):
            return (
                declinedOn == .dismissed
                    ? String(localized: "Dismissed", comment: "Result headline: the request's notification was swiped away")
                    : String(localized: "Declined", comment: "Result headline: the wearer declined the request"),
                String(localized: "Nothing was logged.", comment: "Result detail: the request wasn't carried out"),
                .neutral
            )
        case .expired:
            return (
                String(localized: "Expired", comment: "Result headline: the request wasn't answered in time"),
                String(
                    localized: "Nothing was logged. Ask \(source) again if you still want it.",
                    comment: "Result detail: the request expired. The placeholder is the assistant's name"
                ),
                .neutral
            )
        case .replaced:
            return (
                String(localized: "Replaced", comment: "Result headline: a newer request took this one's place"),
                String(
                    localized: "A newer request from \(source) is waiting.",
                    comment: "Result detail: the request was replaced. The placeholder is the assistant's name"
                ),
                .neutral
            )
        case .withdrawn:
            return (
                String(localized: "Canceled", comment: "Result headline: the assistant canceled the request"),
                String(
                    localized: "\(source) canceled it. Nothing was logged.",
                    comment: "Result detail: the assistant canceled the request. The placeholder is the assistant's name"
                ),
                .neutral
            )
        case let .dryRun(shown):
            let units = shown.units
            return (
                String(
                    localized: "Test: would give \(units)\u{00A0}U",
                    comment: "Result headline: a test request passed every check. The placeholder is the dose it would give"
                ),
                String(
                    localized: "Nothing was logged or given.",
                    comment: "Result detail: a test request logs and gives nothing"
                ),
                .success
            )
        case .pending:
            // Only a final report is an outcome.
            assertionFailure("A pending report is not an outcome")
            return ("", "", .neutral)
        }
    }

    /// A check failed, or the pump did. The reason ends the first sentence, and says what to check next.
    private static func failed(reason: String, carbsLogged: Bool, bolusUnconfirmed: Bool) -> Words {
        let reason = sentence(reason)
        // A bolus that may have been given means the carbs were logged too.
        if bolusUnconfirmed || carbsLogged {
            let advice = String(
                localized: "Check Trio before you bolus yourself.",
                comment: "Result detail: the wearer should look at Trio before bolusing by hand"
            )
            return (
                bolusUnconfirmed
                    ? String(localized: "Bolus not confirmed", comment: "Result headline: Trio stopped while starting the bolus")
                    : String(
                        localized: "Carbs logged, no bolus",
                        comment: "Result headline: the carbs were logged but the bolus failed"
                    ),
                reason.isEmpty ? advice : "\(reason) \(advice)",
                .warning
            )
        }
        let nothingLogged = String(localized: "Nothing was logged.", comment: "Result detail: the request wasn't carried out")
        return (
            String(localized: "Not given", comment: "Result headline: the request was refused and nothing was logged"),
            reason.isEmpty ? nothingLogged : "\(reason) \(nothingLogged)",
            .failure
        )
    }

    /// Where the wearer answered: where they approved it, or where they declined it. A swiped-away watch notification
    /// was answered on the watch. `nil` when nobody answered.
    private static func answeredOn(_ outcome: AIRequestOutcome) -> AIRequestAnswerSide? {
        if let approvedOn = outcome.approvedOn { return approvedOn }
        guard case let .declined(declinedOn) = outcome.report else { return nil }
        switch declinedOn {
        case .dismissed,
             .watch:
            return .watch
        case .phone:
            return .phone
        }
    }

    /// The reason as a sentence: no spaces around it, and ending in one full stop whether it came with one or not, so the
    /// detail's own full stop never doubles up. Empty when there's nothing in it.
    private static func sentence(_ reason: String) -> String {
        var text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.isEmpty || text.hasSuffix("!") || text.hasSuffix("?") { return text }
        return text + "."
    }

    /// An amount without the zeros after its point, and without the point if nothing is left: "35.00" is "35", and
    /// "12.50" is "12.5".
    private static func trimmed(_ amount: String) -> String {
        guard amount.contains(".") else { return amount }
        var result = amount
        while result.hasSuffix("0") {
            result.removeLast()
        }
        if result.hasSuffix(".") {
            result.removeLast()
        }
        return result
    }
}
