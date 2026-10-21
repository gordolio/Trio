import Foundation
import Testing

@testable import Trio

@Suite("AI request display text") struct AIRequestDisplayTextTests {
    // MARK: Body

    /// A 2.10 U dose for 35 g carbs, 10 g fat and 12 g protein, as the request would show it.
    private static let shown = AIRequestShown(carbs: 35, fat: 10, protein: 12, units: 2.1)
    private static let noDose = AIRequestShown(carbs: 35, fat: 10, protein: 12, units: 0)

    private func display(shown: AIRequestShown = Self.shown, noDoseReason: String? = nil) -> AIRequestDisplay {
        AIRequestDisplayText.display(
            source: "ChatGPT",
            description: "slice of pizza",
            shown: shown,
            noDoseReason: noDoseReason
        )
    }

    @Test func bodyIsTheDoseLineThenTheFatAndProtein() {
        #expect(display().body == "Bolus 2.10\u{00A0}U · 35\u{00A0}g carbs\n10\u{00A0}g fat · 12\u{00A0}g protein")
        #expect(display().title == "ChatGPT: slice of pizza")
    }

    @Test func amountsKeepTheirDecimalsAndLoseTrailingZeros() {
        let shown = AIRequestShown(carbs: 12.5, fat: 0, protein: Decimal(string: "7.25")!, units: 0.5)
        #expect(display(shown: shown).body == "Bolus 0.50\u{00A0}U · 12.5\u{00A0}g carbs\n7.25\u{00A0}g protein")
        let fatOnly = AIRequestShown(carbs: 20, fat: Decimal(string: "3.5")!, protein: 0, units: 1.2)
        #expect(display(shown: fatOnly).body == "Bolus 1.20\u{00A0}U · 20\u{00A0}g carbs\n3.5\u{00A0}g fat")
    }

    @Test func bodyHasNoFatProteinLineWithoutFatOrProtein() {
        let carbsOnly = AIRequestShown(carbs: 20, fat: 0, protein: 0, units: 1.2)
        #expect(display(shown: carbsOnly).body == "Bolus 1.20\u{00A0}U · 20\u{00A0}g carbs")
        // A part that rounds to nothing is not shown either.
        let tiny = AIRequestShown(carbs: 20, fat: Decimal(string: "0.004")!, protein: 0, units: 1.2)
        #expect(display(shown: tiny).body == "Bolus 1.20\u{00A0}U · 20\u{00A0}g carbs")
        // With no dose and no fat or protein the 0 U line follows the dose line directly.
        let none = AIRequestShown(carbs: 35, fat: 0, protein: 0, units: 0)
        #expect(display(shown: none, noDoseReason: "glucose is low (52 mg/dL)").body == """
        No bolus · 35\u{00A0}g carbs
        Trio suggests no insulin now: glucose is low (52 mg/dL)
        """)
    }

    @Test func zeroUnitBodyAddsTheReason() {
        #expect(
            display(shown: Self.noDose, noDoseReason: "glucose is low (52 mg/dL)").body == """
            No bolus · 35\u{00A0}g carbs
            10\u{00A0}g fat · 12\u{00A0}g protein
            Trio suggests no insulin now: glucose is low (52 mg/dL)
            """
        )
    }

    @Test func zeroUnitBodyWithoutAReason() {
        // Trio gave no reason, so the line has no colon and nothing after it.
        #expect(
            display(shown: Self.noDose).body == """
            No bolus · 35\u{00A0}g carbs
            10\u{00A0}g fat · 12\u{00A0}g protein
            Trio suggests no insulin now
            """
        )
        // An empty reason is no reason.
        #expect(display(shown: Self.noDose, noDoseReason: "").body == display(shown: Self.noDose).body)
    }

    @Test func noContextLinesEver() {
        // However the request looks, the body is the dose line, the fat and protein, and at most the 0 U line: nothing
        // about the glucose, carbs or insulin given a moment ago, a test or what approving does.
        #expect(display().body.components(separatedBy: "\n") == [
            "Bolus 2.10\u{00A0}U · 35\u{00A0}g carbs",
            "10\u{00A0}g fat · 12\u{00A0}g protein"
        ])
        // A dose over 0 U with no reason has no 0 U line.
        #expect(!display().body.contains("no insulin"))
        #expect(display(shown: Self.noDose, noDoseReason: "glucose is forecast to go low").body.components(separatedBy: "\n") == [
            "No bolus · 35\u{00A0}g carbs",
            "10\u{00A0}g fat · 12\u{00A0}g protein",
            "Trio suggests no insulin now: glucose is forecast to go low"
        ])
    }

    @Test func bodyStaysWithinTheServiceLimit() {
        let body = display(shown: Self.noDose, noDoseReason: String(repeating: "x", count: 300)).body
        #expect(body.utf16.count <= AIRequestDisplayText.maxLength)
        #expect(body.hasSuffix("…"))
        // The dose is first, so it is whole.
        #expect(body.hasPrefix("No bolus · 35\u{00A0}g carbs\n"))
    }

    @Test func aLongBodyIsCutByUTF16UnitsWithoutBreakingACharacter() {
        let body = display(shown: Self.noDose, noDoseReason: String(repeating: "🍕", count: 100)).body
        #expect(body.utf16.count <= AIRequestDisplayText.maxLength)
        #expect(body.hasSuffix("🍕…"))
        // As many whole pizzas as fit: the next one would not.
        #expect(body.utf16.count >= AIRequestDisplayText.maxLength - 1)
    }

    @Test func theCutNeverLandsInsideAnAmount() throws {
        // Slide a reason with amounts at its end through every length, so the cut falls at every point of them,
        // including inside "52 mg/dL" and "22 min". The first two lines and their breaks are 46 units, and "Trio
        // suggests no insulin now: " is 30 more, so the reason starts at unit 76 and the cut is at unit 199.
        var movedBeforeTheGlucose = 0
        var movedBeforeTheMinutes = 0
        for length in 100 ... 170 {
            let reason = String(repeating: "x", count: length) + " 52 mg/dL, 22 min"
            let body = display(shown: Self.noDose, noDoseReason: reason).body
            #expect(body.utf16.count <= AIRequestDisplayText.maxLength)
            guard body.hasSuffix("…") else { continue }
            let kept = String(body.dropLast())
            // Every number that's left still has its whole unit after it.
            for number in kept.matches(of: try Regex("[0-9.]+")) {
                let after = kept[number.range.upperBound...]
                let hasUnit = ["\u{00A0}U", "\u{00A0}g", " min", " mg/dL"].contains { after.hasPrefix($0) }
                #expect(hasUnit, "length \(length), \(kept[number.range]): \(kept)")
            }
            // Where a plain cut would have split an amount, the cut moved back to before it.
            let full =
                "No bolus · 35\u{00A0}g carbs\n10\u{00A0}g fat · 12\u{00A0}g protein\nTrio suggests no insulin now: \(reason)"
            guard kept != String(full.prefix(AIRequestDisplayText.maxLength - 1)) else { continue }
            if kept.hasSuffix("x") { movedBeforeTheGlucose += 1 }
            if kept.hasSuffix("mg/dL,") { movedBeforeTheMinutes += 1 }
        }
        #expect(movedBeforeTheGlucose > 0 && movedBeforeTheMinutes > 0)
    }

    @Test func title() {
        #expect(AIRequestDisplayText.title(source: "ChatGPT", description: "slice of pizza") == "ChatGPT: slice of pizza")
    }

    @Test func titleKeepsTheDescriptionOnOneLine() {
        // A description that tries to put its own amounts on a line of their own.
        #expect(
            AIRequestDisplayText.title(source: "ChatGPT", description: "slice of pizza\n5 g carbs · 0.3 U")
                == "ChatGPT: slice of pizza 5 g carbs · 0.3 U"
        )
        // Each run of control characters, with the spaces next to it, is one space; none at the start or the end.
        #expect(
            AIRequestDisplayText.title(source: "ChatGPT", description: "\r\npizza \r\n\u{2028}\t and\u{0007}salad\u{2029}\n")
                == "ChatGPT: pizza and salad"
        )
        // Spaces elsewhere, and the joiners inside an emoji, stay.
        #expect(
            AIRequestDisplayText.title(source: "ChatGPT", description: "👨‍👩‍👧  family pizza")
                == "ChatGPT: 👨‍👩‍👧  family pizza"
        )
    }

    @Test func longTitleIsCutToTheServicesLimit() {
        // The service allows a description of 200 characters; with the source in front the title is longer.
        let title = AIRequestDisplayText.title(source: "ChatGPT", description: String(repeating: "x", count: 200))
        #expect(title.count == 200)
        #expect(title.hasSuffix("…"))
        #expect(title.hasPrefix("ChatGPT: xxx"))
    }

    @Test func longTitleIsCutByUTF16UnitsWithoutBreakingACharacter() {
        // 150 pizzas are 150 characters but 300 UTF-16 units, which is what the service counts.
        let title = AIRequestDisplayText.title(source: "ChatGPT", description: String(repeating: "🍕", count: 150))
        #expect(title.utf16.count <= 200)
        #expect(title.hasSuffix("…"))
        #expect(title.dropLast().last == "🍕")
        // As many whole pizzas as fit: 9 units of source, 2 per pizza, 1 for the ellipsis.
        #expect(title.utf16.count == 9 + 95 * 2 + 1)
    }

    @Test func titleAtTheLimitIsUnchanged() {
        let atLimit = String(repeating: "x", count: 200 - "ChatGPT: ".count)
        #expect(AIRequestDisplayText.title(source: "ChatGPT", description: atLimit) == "ChatGPT: " + atLimit)
        let over = AIRequestDisplayText.title(source: "ChatGPT", description: atLimit + "x")
        #expect(over.count == 200 && over.hasSuffix("…"))
    }
}
