import Foundation
import Testing

@testable import Trio

@Suite("AI request display text") struct AIRequestDisplayTextTests {
    // MARK: Body

    /// A 2.10 U dose for 35 g carbs, 10 g fat and 12 g protein, as the request would show it.
    private static let shown = AIRequestShown(carbs: 35, fat: 10, protein: 12, units: 2.1)

    private func display(
        shown: AIRequestShown = Self.shown,
        context: AIRequestContext = AIRequestContext(glucose: "142 mg/dL ↗")
    ) -> AIRequestDisplay {
        AIRequestDisplayText.display(
            source: "ChatGPT",
            description: "slice of pizza",
            shown: shown,
            context: context
        )
    }

    @Test func bodyPutsTheDoseFirst() {
        #expect(display().body == "Bolus 2.10\u{00A0}U · 35\u{00A0}g carbs\n10\u{00A0}g fat · 12\u{00A0}g protein · 142 mg/dL ↗")
        #expect(display().title == "ChatGPT: slice of pizza")
    }

    @Test func amountsKeepTheirDecimalsAndLoseTrailingZeros() {
        let shown = AIRequestShown(carbs: 12.5, fat: 0, protein: Decimal(string: "7.25")!, units: 0.5)
        #expect(
            display(shown: shown, context: AIRequestContext()).body
                == "Bolus 0.50\u{00A0}U · 12.5\u{00A0}g carbs\n7.25\u{00A0}g protein"
        )
    }

    @Test func linesThatDoNotApplyAreLeftOut() {
        let shown = AIRequestShown(carbs: 20, fat: 0, protein: 0, units: 1.2)
        // No fat, protein or glucose: just the dose line.
        #expect(display(shown: shown, context: AIRequestContext()).body == "Bolus 1.20\u{00A0}U · 20\u{00A0}g carbs")
        // Glucose alone is the second line.
        #expect(
            display(shown: shown, context: AIRequestContext(glucose: "7.9 mmol/L →")).body
                == "Bolus 1.20\u{00A0}U · 20\u{00A0}g carbs\n7.9 mmol/L →"
        )
    }

    @Test func bodyAddsRecentCarbsAndBolus() {
        let context = AIRequestContext(
            glucose: "142 mg/dL ↗",
            recentCarbs: .init(amount: "20", minutesAgo: 6),
            recentBolus: .init(amount: "3.00", minutesAgo: 8)
        )
        #expect(
            display(context: context).body == """
            Bolus 2.10\u{00A0}U · 35\u{00A0}g carbs
            10\u{00A0}g fat · 12\u{00A0}g protein · 142 mg/dL ↗
            Carbs 20\u{00A0}g logged 6 min ago
            Bolus 3.00\u{00A0}U given 8 min ago
            """
        )
        // Each one on its own.
        #expect(display(context: AIRequestContext(recentBolus: .init(amount: "3.00", minutesAgo: 8))).body.hasSuffix(
            "\n10\u{00A0}g fat · 12\u{00A0}g protein\nBolus 3.00\u{00A0}U given 8 min ago"
        ))
        #expect(display(context: AIRequestContext(recentCarbs: .init(amount: "12.5", minutesAgo: 0))).body.hasSuffix(
            "\nCarbs 12.5\u{00A0}g logged 0 min ago"
        ))
    }

    @Test func zeroDoseBodySaysWhy() {
        let shown = AIRequestShown(carbs: 35, fat: 10, protein: 12, units: 0)
        let context = AIRequestContext(
            glucose: "52 mg/dL ↓",
            noDoseReason: "glucose is low (52 mg/dL)"
        )
        #expect(
            display(shown: shown, context: context).body == """
            No bolus · 35\u{00A0}g carbs
            10\u{00A0}g fat · 12\u{00A0}g protein · 52 mg/dL ↓
            Trio suggests no insulin now: glucose is low (52 mg/dL)
            """
        )
    }

    @Test func zeroDoseWithoutAKnownReasonSaysSoPlainly() {
        // Trio gave no reason, so the line has no colon and nothing after it.
        let shown = AIRequestShown(carbs: 35, fat: 0, protein: 0, units: 0)
        #expect(
            display(shown: shown, context: AIRequestContext()).body == """
            No bolus · 35\u{00A0}g carbs
            Trio suggests no insulin now
            """
        )
        // It sits where the reason does: after the food and glucose, before the recent carbs and insulin.
        let context = AIRequestContext(
            glucose: "142 mg/dL ↗",
            recentCarbs: .init(amount: "20", minutesAgo: 6),
            recentBolus: .init(amount: "3.00", minutesAgo: 8)
        )
        #expect(
            display(shown: shown, context: context).body == """
            No bolus · 35\u{00A0}g carbs
            142 mg/dL ↗
            Trio suggests no insulin now
            Carbs 20\u{00A0}g logged 6 min ago
            Bolus 3.00\u{00A0}U given 8 min ago
            """
        )
        // An empty reason is no reason.
        #expect(
            display(shown: shown, context: AIRequestContext(noDoseReason: "")).body
                == "No bolus · 35\u{00A0}g carbs\nTrio suggests no insulin now"
        )
    }

    @Test func aDoseHasNoNoInsulinLineWithoutAReason() {
        #expect(!display(context: AIRequestContext()).body.contains("no insulin"))
    }

    @Test func bodyHasNoLineAboutApproving() {
        // The wearer approves on the screens the request opens, not from the notification, so the body never says what
        // approving does.
        let none = AIRequestShown(carbs: 35, fat: 0, protein: 0, units: 0)
        #expect(!display(context: AIRequestContext()).body.contains("Approve"))
        #expect(!display(shown: none, context: AIRequestContext()).body.contains("Approve"))
    }

    @Test func glucoseAgeShownFromTwoMinutes() {
        func body(age: Int?) -> String {
            display(context: AIRequestContext(glucose: "142 mg/dL ↗", glucoseAgeMinutes: age)).body
        }
        #expect(body(age: 3).hasSuffix("142 mg/dL ↗ · 3 min ago"))
        #expect(body(age: 2).hasSuffix("142 mg/dL ↗ · 2 min ago"))
        #expect(body(age: 25).hasSuffix("142 mg/dL ↗ · 25 min ago"))
        // A reading under two minutes old is current, and so is one of an unknown age.
        #expect(body(age: 1).hasSuffix("142 mg/dL ↗"))
        #expect(body(age: 0).hasSuffix("142 mg/dL ↗"))
        #expect(body(age: nil).hasSuffix("142 mg/dL ↗"))
        // An age without a reading says nothing.
        let noReading = display(context: AIRequestContext(glucoseAgeMinutes: 30)).body
        #expect(noReading == "Bolus 2.10\u{00A0}U · 35\u{00A0}g carbs\n10\u{00A0}g fat · 12\u{00A0}g protein")
    }

    @Test func displayCarriesTheContextForTheService() {
        let context = AIRequestContext(
            glucose: "142 mg/dL ↗",
            glucoseAgeMinutes: 3,
            recentCarbs: .init(amount: "20", minutesAgo: 6),
            recentBolus: .init(amount: "3.00", minutesAgo: 8),
            noDoseReason: nil
        )
        #expect(display(context: context).context == context)
    }

    @Test func bodyStaysWithinTheServiceLimit() {
        let context = AIRequestContext(
            glucose: "142 mg/dL ↗",
            glucoseAgeMinutes: 3,
            recentCarbs: .init(amount: "20", minutesAgo: 6),
            recentBolus: .init(amount: "2.10", minutesAgo: 8),
            noDoseReason: String(repeating: "x", count: 120)
        )
        let body = display(context: context).body
        #expect(body.utf16.count <= AIRequestDisplayText.maxLength)
        #expect(body.hasSuffix("…"))
        // The dose is first, so it is whole.
        #expect(body.hasPrefix("Bolus 2.10\u{00A0}U · 35\u{00A0}g carbs\n"))
    }

    @Test func aLongBodyIsCutByUTF16UnitsWithoutBreakingACharacter() {
        let context = AIRequestContext(noDoseReason: String(repeating: "🍕", count: 100))
        let body = display(context: context).body
        #expect(body.utf16.count <= AIRequestDisplayText.maxLength)
        #expect(body.hasSuffix("🍕…"))
        // As many whole pizzas as fit: the next one would not.
        #expect(body.utf16.count >= AIRequestDisplayText.maxLength - 1)
    }

    @Test func theCutNeverLandsInsideAnAmount() throws {
        // Slide a long reason through every length, so the cut falls at every point of the lines after it, including
        // inside "20 g", "6 min" and "2.10 U".
        var cutInTheCarbsLine = 0
        var cutInTheBolusLine = 0
        for length in 1 ... 120 {
            let context = AIRequestContext(
                glucose: "142 mg/dL ↗",
                recentCarbs: .init(amount: "20", minutesAgo: 6),
                recentBolus: .init(amount: "2.10", minutesAgo: 8),
                noDoseReason: String(repeating: "x", count: length)
            )
            let body = display(context: context).body
            #expect(body.utf16.count <= AIRequestDisplayText.maxLength)
            guard body.hasSuffix("…") else { continue }
            let kept = String(body.dropLast())
            // Every number that's left still has its whole unit after it.
            for number in kept.matches(of: try Regex("[0-9.]+")) {
                let after = kept[number.range.upperBound...]
                let hasUnit = ["\u{00A0}U", "\u{00A0}g", " min", " mg/dL"].contains { after.hasPrefix($0) }
                #expect(hasUnit, "length \(length), \(kept[number.range]): \(kept)")
            }
            let lines = kept.components(separatedBy: "\n")
            if lines.count == 4 { cutInTheCarbsLine += 1 }
            if lines.count == 5 { cutInTheBolusLine += 1 }
        }
        #expect(cutInTheCarbsLine > 0 && cutInTheBolusLine > 0)
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

    @Test(arguments: [
        ("TripleUp", "⇈"), ("DoubleUp", "⇈"), ("SingleUp", "↑"), ("FortyFiveUp", "↗"), ("Flat", "→"),
        ("FortyFiveDown", "↘"), ("SingleDown", "↓"), ("DoubleDown", "⇊"), ("TripleDown", "⇊"),
        ("NONE", ""), ("NOT COMPUTABLE", ""), ("RATE OUT OF RANGE", "")
    ]) func arrow(direction: String, arrow: String) {
        #expect(AIRequestDisplayText.arrow(direction) == arrow)
    }

    @Test func noDirectionHasNoArrow() {
        #expect(AIRequestDisplayText.arrow(nil) == "")
    }
}
