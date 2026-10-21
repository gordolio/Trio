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

    @Test func bodyIsTheDoseLineOnly() {
        #expect(display().body == "Bolus 2.10\u{00A0}U · 35\u{00A0}g carbs")
        #expect(display().title == "ChatGPT: slice of pizza")
    }

    @Test func amountsKeepTheirDecimalsAndLoseTrailingZeros() {
        let shown = AIRequestShown(carbs: 12.5, fat: 0, protein: Decimal(string: "7.25")!, units: 0.5)
        #expect(display(shown: shown).body == "Bolus 0.50\u{00A0}U · 12.5\u{00A0}g carbs")
        let whole = AIRequestShown(carbs: 20, fat: 0, protein: 0, units: 1.2)
        #expect(display(shown: whole).body == "Bolus 1.20\u{00A0}U · 20\u{00A0}g carbs")
    }

    @Test func zeroUnitBodyAddsTheReason() {
        #expect(
            display(shown: Self.noDose, noDoseReason: "glucose is low (52 mg/dL)").body == """
            No bolus · 35\u{00A0}g carbs
            Trio suggests no insulin now: glucose is low (52 mg/dL)
            """
        )
    }

    @Test func zeroUnitBodyWithoutAReason() {
        // Trio gave no reason, so the line has no colon and nothing after it.
        #expect(
            display(shown: Self.noDose).body == """
            No bolus · 35\u{00A0}g carbs
            Trio suggests no insulin now
            """
        )
        // An empty reason is no reason.
        #expect(display(shown: Self.noDose, noDoseReason: "").body == display(shown: Self.noDose).body)
    }

    @Test func aDoseHasNoNoInsulinLineWithoutAReason() {
        #expect(!display().body.contains("no insulin"))
    }

    @Test func noContextLinesEver() {
        // However the request looks, the body is the dose line and at most the 0 U line: nothing about the glucose,
        // carbs or insulin given a moment ago, a test or what approving does.
        for shown in [Self.shown, Self.noDose] {
            for reason in [nil, "glucose is forecast to go low"] {
                let body = display(shown: shown, noDoseReason: reason).body
                #expect(body.components(separatedBy: "\n").count <= 2, "\(body)")
                for word in ["mg/dL", "mmol/L", "logged", "given", "ago", "Test", "Approve", "fat", "protein"] {
                    #expect(!body.contains(word), "\(word): \(body)")
                }
            }
        }
        // A dose over 0 U has the dose line and nothing else, a reason or not.
        #expect(display(noDoseReason: nil).body.components(separatedBy: "\n").count == 1)
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
        // including inside "52 mg/dL" and "22 min".
        var cutInTheReason = 0
        for length in 100 ... 170 {
            let reason = String(repeating: "x", count: length) + " 52 mg/dL, 22 min"
            let body = display(shown: Self.noDose, noDoseReason: reason).body
            #expect(body.utf16.count <= AIRequestDisplayText.maxLength)
            guard body.hasSuffix("…") else { continue }
            cutInTheReason += 1
            let kept = String(body.dropLast())
            // Every number that's left still has its whole unit after it.
            for number in kept.matches(of: try Regex("[0-9.]+")) {
                let after = kept[number.range.upperBound...]
                let hasUnit = ["\u{00A0}U", "\u{00A0}g", " min", " mg/dL"].contains { after.hasPrefix($0) }
                #expect(hasUnit, "length \(length), \(kept[number.range]): \(kept)")
            }
        }
        #expect(cutInTheReason > 0)
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
