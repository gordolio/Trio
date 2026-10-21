import Foundation
import Testing

@testable import Trio

@Suite("AI request result text") struct AIRequestResultTextTests {
    /// The amounts a request showed. `units` is as `AIRequestShown` formats it: two decimals.
    private static func shown(_ carbs: String, units: String) -> AIRequestShown {
        AIRequestShown(carbs: carbs, fat: "0.00", protein: "0.00", units: units)
    }

    private static func outcome(
        _ report: AIRequestReport,
        source: String = "ChatGPT",
        bolusUnconfirmed: Bool = false
    ) -> AIRequestOutcome {
        AIRequestOutcome(
            id: "r1",
            title: "ChatGPT: slice of pizza",
            source: source,
            shown: nil,
            report: report,
            askedOn: .watch,
            approvedOn: nil,
            declinedOn: nil,
            bolusUnconfirmed: bolusUnconfirmed
        )
    }

    /// Every row of the spec's Q12 table. A no-break space is U+00A0, written out so a plain space can't pass.
    private static let rows: [(AIRequestReport, String, String, AIRequestResultMessage.Tone)] = [
        (
            .delivering(shown: shown("35.00", units: "2.10")),
            "Bolus started: 2.10\u{00A0}U",
            "35\u{00A0}g carbs logged.",
            .success
        ),
        (
            .delivering(shown: shown("12.50", units: "0.05")),
            "Bolus started: 0.05\u{00A0}U",
            "12.5\u{00A0}g carbs logged.",
            .success
        ),
        (
            .logged(shown: shown("10.00", units: "0.00")),
            "10\u{00A0}g carbs logged",
            "Trio's dose was 0\u{00A0}U, so no bolus.",
            .success
        ),
        (
            .failed(reason: "Over your max IOB", carbsLogged: false),
            "Not given",
            "Over your max IOB. Nothing was logged.",
            .failure
        ),
        (
            .failed(reason: "Over your max IOB", carbsLogged: true),
            "Carbs logged, no bolus",
            "Over your max IOB. Check Trio before you bolus yourself.",
            .warning
        ),
        (
            // The reason's own full stop isn't doubled. Its plain spaces stay as they are.
            .failed(reason: "Trio gave 1.50 U after working out this dose. Ask again in a few minutes.", carbsLogged: false),
            "Not given",
            "Trio gave 1.50 U after working out this dose. Ask again in a few minutes. Nothing was logged.",
            .failure
        ),
        (
            .failed(reason: "Pump timed out.", carbsLogged: true),
            "Carbs logged, no bolus",
            "Pump timed out. Check Trio before you bolus yourself.",
            .warning
        ),
        (
            .failed(reason: "Is the pump on?", carbsLogged: false),
            "Not given",
            "Is the pump on? Nothing was logged.",
            .failure
        ),
        (
            .declined(on: .watch),
            "Declined",
            "Nothing was logged.",
            .neutral
        ),
        (
            .declined(on: .phone),
            "Declined",
            "Nothing was logged.",
            .neutral
        ),
        (
            .declined(on: .dismissed),
            "Dismissed",
            "Nothing was logged.",
            .neutral
        ),
        (
            .expired,
            "Expired",
            "Nothing was logged. Ask ChatGPT again if you still want it.",
            .neutral
        ),
        (
            .replaced,
            "Replaced",
            "A newer request from ChatGPT is waiting.",
            .neutral
        ),
        (
            .withdrawn,
            "Canceled",
            "ChatGPT canceled it. Nothing was logged.",
            .neutral
        )
    ]

    @Test(arguments: rows) func everyOutcomeHasItsWording(
        report: AIRequestReport,
        headline: String,
        detail: String,
        tone: AIRequestResultMessage.Tone
    ) {
        let message = AIRequestResultText.message(for: Self.outcome(report))
        #expect(message.headline == headline)
        #expect(message.detail == detail)
        #expect(message.tone == tone)
        #expect(message.id == "r1")
        #expect(message.title == "ChatGPT: slice of pizza")
    }

    @Test func aBolusThatMayHaveBeenGivenIsNotConfirmed() {
        let report = AIRequestReport.failed(
            reason: "Trio stopped while starting the bolus. It may have been given",
            carbsLogged: true
        )
        let message = AIRequestResultText.message(for: Self.outcome(report, bolusUnconfirmed: true))
        #expect(message.headline == "Bolus not confirmed")
        #expect(
            message
                .detail == "Trio stopped while starting the bolus. It may have been given. Check Trio before you bolus yourself."
        )
        #expect(message.tone == .warning)
    }

    @Test func theAssistantNamedIsTheRequestsSource() {
        let expired = AIRequestResultText.message(for: Self.outcome(.expired, source: "Claude"))
        #expect(expired.detail == "Nothing was logged. Ask Claude again if you still want it.")
        let withdrawn = AIRequestResultText.message(for: Self.outcome(.withdrawn, source: "Grok"))
        #expect(withdrawn.detail == "Grok canceled it. Nothing was logged.")
    }

    @Test func amountsAreJoinedToTheirUnitsByNoBreakSpaces() {
        let message = AIRequestResultText.message(for: Self.outcome(.delivering(shown: Self.shown("100.00", units: "12.34"))))
        #expect(message.headline == "Bolus started: 12.34\u{00A0}U")
        #expect(message.detail == "100\u{00A0}g carbs logged.") // the zeros before the point stay
        #expect(!message.headline.contains("\u{0020}U"))
        #expect(!message.detail.contains("\u{0020}g"))
    }

    @Test func aReasonWithNothingInItLeavesOnlyTheRest() {
        let notGiven = AIRequestResultText.message(for: Self.outcome(.failed(reason: "", carbsLogged: false)))
        #expect(notGiven.detail == "Nothing was logged.")
        let logged = AIRequestResultText.message(for: Self.outcome(.failed(reason: " . ", carbsLogged: true)))
        #expect(logged.detail == "Check Trio before you bolus yourself.")
    }

    @Test(arguments: [
        (AIRequestAnswerSide.watch, AIRequestAnswerSide.watch),
        (.phone, .phone)
    ]) func anApprovedRequestSaysWhereItWasApproved(approvedOn: AIRequestAnswerSide, side: AIRequestAnswerSide) {
        let outcome = AIRequestOutcome(
            id: "r1",
            title: "t",
            source: "ChatGPT",
            shown: nil,
            report: .failed(reason: "Over your max IOB", carbsLogged: true),
            askedOn: .watch,
            approvedOn: approvedOn,
            declinedOn: nil
        )
        #expect(AIRequestResultText.message(for: outcome).answeredOn == side)
    }

    @Test(arguments: [
        (AIRequestDeclinedOn.watch, AIRequestAnswerSide.watch),
        (.phone, .phone),
        (.dismissed, .watch) // the watch's notification was swiped away
    ]) func aDeclinedRequestSaysWhereItWasDeclined(declinedOn: AIRequestDeclinedOn, side: AIRequestAnswerSide) {
        let outcome = AIRequestOutcome(
            id: "r1",
            title: "t",
            source: "ChatGPT",
            shown: nil,
            report: .declined(on: declinedOn),
            askedOn: .watch,
            approvedOn: nil,
            declinedOn: declinedOn
        )
        #expect(AIRequestResultText.message(for: outcome).answeredOn == side)
    }

    @Test func aRequestNobodyAnsweredHasNoAnswerSide() {
        for report in [AIRequestReport.expired, .replaced, .withdrawn, .failed(reason: "Over your max IOB", carbsLogged: false)] {
            #expect(AIRequestResultText.message(for: Self.outcome(report)).answeredOn == nil)
        }
    }

    @Test func theMessageSurvivesTheTripToTheWatch() throws {
        let message = AIRequestResultText.message(for: Self.outcome(.withdrawn))
        let decoded = try JSONDecoder().decode(AIRequestResultMessage.self, from: JSONEncoder().encode(message))
        #expect(decoded == message)
    }
}
