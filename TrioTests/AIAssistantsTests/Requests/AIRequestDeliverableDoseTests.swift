import Foundation
import Testing

@testable import Trio

@Suite("AI request deliverable dose") struct AIRequestDeliverableDoseTests {
    @Test(arguments: [
        // (calculated dose, pump increment, deliverable dose)
        ("0.275", "0.05", "0.25"),
        ("0.275", "0.025", "0.25"),
        ("0.275", "0.1", "0.2"),
        ("1.2", "0.05", "1.2"),
        ("1.2", "0.025", "1.2"),
        ("1.2", "0.1", "1.2"),
        ("0", "0.05", "0"),
        ("0", "0.025", "0"),
        ("0", "0.1", "0"),
        ("0.05", "0.05", "0.05"),
        ("0.05", "0.025", "0.05"),
        ("0.05", "0.1", "0"),
        // 0.075 is a multiple of 0.025 below 0.08 but has three decimals, so it steps down again.
        ("0.08", "0.025", "0.05"),
        // Unrounded, as when no pump is paired.
        ("1.23456", "0.1", "1.2")
    ]) func floorsToTwoDecimalsAndTheIncrement(units: String, increment: String, expected: String) {
        #expect(
            BaseAIRequestTreatments.deliverableDose(Decimal(string: units)!, increment: Decimal(string: increment)!)
                == Decimal(string: expected)!
        )
    }

    @Test func noisyIncrementFromADoubleStillGivesTheDose() {
        // The pump's increment arrives as a Double. This one is 0.04999999999999999, and no multiple of it has two
        // decimals.
        let increment = Decimal(0.15 - 0.1)
        #expect(increment != Decimal(string: "0.05")!)
        #expect(BaseAIRequestTreatments.deliverableDose(Decimal(string: "1.2")!, increment: increment) == Decimal(string: "1.2")!)
        #expect(
            BaseAIRequestTreatments.deliverableDose(Decimal(string: "0.275")!, increment: increment) == Decimal(string: "0.25")!
        )
    }
}
