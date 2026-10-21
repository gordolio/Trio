import Foundation
import Testing

@testable import Trio

@Suite("AI request context rows") struct AIRequestContextRowsTests {
    private static let dose = AIRequestShown(carbs: "35.00", fat: "0.00", protein: "0.00", units: "2.10")
    private static let noDose = AIRequestShown(carbs: "35.00", fat: "0.00", protein: "0.00", units: "0.00")

    private static func rows(
        _ context: AIRequestContext?,
        shown: AIRequestShown = dose,
        testKind: AIRequestTestKind? = nil
    ) -> [AIRequestContextRow] {
        AIRequestContextRows.rows(context: context, shown: shown, testKind: testKind)
    }

    @Test("Every row, in the one order both screens use, with the warnings marked") func everyRowInOrder() {
        let context = AIRequestContext(
            glucose: "61 mg/dL ↘",
            glucoseAgeMinutes: 4,
            recentCarbs: .init(amount: "20", minutesAgo: 6),
            recentBolus: .init(amount: "3.00", minutesAgo: 8),
            noDoseReason: "glucose is forecast to go low"
        )
        #expect(Self.rows(context, shown: Self.noDose, testKind: .real) == [
            AIRequestContextRow(kind: .glucose, text: "61 mg/dL ↘ · 4 min ago", isWarning: false),
            AIRequestContextRow(
                kind: .noDose,
                text: "Trio suggests no insulin now: glucose is forecast to go low",
                isWarning: false
            ),
            AIRequestContextRow(kind: .recentCarbs, text: "Carbs 20\u{00A0}g logged 6 min ago", isWarning: true),
            AIRequestContextRow(kind: .recentBolus, text: "Bolus 3.00\u{00A0}U given 8 min ago", isWarning: true),
            AIRequestContextRow(kind: .test, text: "Real dose. Decline unless you're eating this.", isWarning: true)
        ])
    }

    @Test("No context and an empty one give the same rows, and nothing is made up from a missing value") func noContext() {
        #expect(Self.rows(nil).isEmpty)
        #expect(Self.rows(AIRequestContext()).isEmpty)
        #expect(Self.rows(nil, shown: Self.noDose) == Self.rows(AIRequestContext(), shown: Self.noDose))
        #expect(Self.rows(nil, testKind: .dryRun) == Self.rows(AIRequestContext(), testKind: .dryRun))

        // An age without a reading, and empty strings, add nothing.
        #expect(Self.rows(AIRequestContext(glucoseAgeMinutes: 30)).isEmpty)
        #expect(Self.rows(AIRequestContext(glucose: "")).isEmpty)
        #expect(Self.rows(AIRequestContext(noDoseReason: "")).isEmpty)
    }

    @Test("A 0 U dose says why when Trio knows, and says only that it's 0 U when it doesn't") func zeroDose() {
        let reason = AIRequestContext(noDoseReason: "glucose is low (52 mg/dL)")
        #expect(Self.rows(reason, shown: Self.noDose).map(\.text) == ["Trio suggests no insulin now: glucose is low (52 mg/dL)"])
        #expect(Self.rows(nil, shown: Self.noDose).map(\.text) == ["Trio suggests no insulin now"])
        #expect(Self.rows(AIRequestContext(noDoseReason: ""), shown: Self.noDose).map(\.text) == ["Trio suggests no insulin now"])
        #expect(Self.rows(nil, shown: Self.noDose).allSatisfy { $0.kind == .noDose && !$0.isWarning })

        // A dose has no 0 U row without a reason.
        #expect(Self.rows(nil).isEmpty)

        #expect(AIRequestContextRows.givesNoBolus(Self.noDose))
        #expect(!AIRequestContextRows.givesNoBolus(Self.dose))
        // An amount that can't be read counts as a dose, so nothing says there's none.
        #expect(!AIRequestContextRows.givesNoBolus(AIRequestShown(carbs: "35.00", fat: "0.00", protein: "0.00", units: "")))
    }

    @Test("The glucose shows its age from 2 minutes old") func glucoseAge() {
        func text(age: Int?) -> String? {
            Self.rows(AIRequestContext(glucose: "142 mg/dL ↗", glucoseAgeMinutes: age)).first?.text
        }
        #expect(AIRequestContextRows.glucoseAgeShownFrom == 2)
        #expect(text(age: nil) == "142 mg/dL ↗")
        #expect(text(age: 0) == "142 mg/dL ↗")
        #expect(text(age: 1) == "142 mg/dL ↗")
        #expect(text(age: 2) == "142 mg/dL ↗ · 2 min ago")
        #expect(text(age: 25) == "142 mg/dL ↗ · 25 min ago")
    }

    @Test("A test says what it does, and only the real one is a warning") func testRows() {
        #expect(Self.rows(nil, testKind: .dryRun) == [
            AIRequestContextRow(kind: .test, text: "Test only: nothing is logged or given", isWarning: false)
        ])
        #expect(Self.rows(nil, testKind: .real) == [
            AIRequestContextRow(kind: .test, text: "Real dose. Decline unless you're eating this.", isWarning: true)
        ])
        #expect(Self.rows(nil, testKind: nil).isEmpty)
    }
}
