import Foundation
import Testing

@testable import Trio

@Suite("AI request display text") struct AIRequestDisplayTextTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func mgdlWithRecentCarbs() {
        let g = StatusSnapshot.LatestGlucose(date: now, mgdl: 142, direction: "FortyFiveUp", deltaMgdl: 3)
        #expect(AIRequestDisplayText.body(
            carbs: 20, fat: 0, protein: 0, units: 1.2, glucose: g, displayUnits: "mg/dL",
            lastCarbs: (35, now - 240), now: now
        ) == "20 g carbs · 1.2 U · 142 mg/dL ↗ · last carbs 35 g, 4 min ago")
    }

    @Test func mmolAndOldCarbsLeftOut() {
        let g = StatusSnapshot.LatestGlucose(date: now, mgdl: 142, direction: "Flat", deltaMgdl: nil)
        #expect(AIRequestDisplayText.body(
            carbs: 20, fat: 10, protein: 8, units: 0, glucose: g, displayUnits: "mmol/L",
            lastCarbs: (35, now - 16 * 60), now: now
        ) == "20 g carbs, 10 g fat, 8 g protein · 0 U · 7.9 mmol/L →")
    }

    @Test func noGlucose() {
        #expect(AIRequestDisplayText.body(
            carbs: 20, fat: 0, protein: 0, units: 1.25, glucose: nil, displayUnits: "mg/dL", lastCarbs: nil, now: now
        ) == "20 g carbs · 1.25 U")
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

    @Test func wholeMmolKeepsItsDecimalAndUnknownDirectionHasNoArrow() {
        // 126 mg/dL is 6.993 mmol/L, which rounds to 7.0.
        let g = StatusSnapshot.LatestGlucose(date: now, mgdl: 126, direction: nil, deltaMgdl: nil)
        #expect(AIRequestDisplayText.body(
            carbs: 12.5, fat: 0, protein: 3, units: 0.5, glucose: g, displayUnits: "mmol/L", lastCarbs: nil, now: now
        ) == "12.5 g carbs, 3 g protein · 0.5 U · 7.0 mmol/L")
    }

    @Test func lastCarbsAreShownUnderFifteenMinutesOnly() {
        let almost = AIRequestDisplayText.body(
            carbs: 20, fat: 0, protein: 0, units: 1, glucose: nil, displayUnits: "mg/dL",
            lastCarbs: (35, now - (15 * 60 - 1)), now: now
        )
        let exactly = AIRequestDisplayText.body(
            carbs: 20, fat: 0, protein: 0, units: 1, glucose: nil, displayUnits: "mg/dL",
            lastCarbs: (35, now - 15 * 60), now: now
        )
        #expect(almost == "20 g carbs · 1 U · last carbs 35 g, 14 min ago")
        #expect(exactly == "20 g carbs · 1 U")
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
