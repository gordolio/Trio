import Foundation
import LocalAuthentication
import Testing

@testable import Trio

@Suite("AI request unlock") struct AIRequestUnlockTests {
    private static let dose = AIRequestShown(carbs: "35.00", fat: "0.00", protein: "0.00", units: "2.10")
    private static let noDose = AIRequestShown(carbs: "35.00", fat: "0.00", protein: "0.00", units: "0.00")

    // MARK: The Face ID prompt

    @Test("The prompt names the dose and the carbs") func reasonNamesTheDose() {
        #expect(AIRequestUnlock.reason(shown: Self.dose) == "Approve a 2.10\u{00A0}U bolus for 35\u{00A0}g of carbs")
    }

    @Test("A 0 U request names only the carbs") func reasonForNoDose() {
        #expect(AIRequestUnlock.reason(shown: Self.noDose) == "Log 35\u{00A0}g of carbs")
    }

    @Test("Carbs with decimals keep them, and the dose keeps its two") func reasonKeepsTheAmounts() {
        let shown = AIRequestShown(carbs: "12.50", fat: "0.00", protein: "0.00", units: "0.90")
        #expect(AIRequestUnlock.reason(shown: shown) == "Approve a 0.90\u{00A0}U bolus for 12.5\u{00A0}g of carbs")
    }

    // MARK: The Approve button

    @Test("The icon follows what the device unlocks with", arguments: [
        (LABiometryType.faceID, "faceid"),
        (LABiometryType.touchID, "touchid"),
        (LABiometryType.opticID, "opticid"),
        (LABiometryType.none, "lock")
    ]) func iconFollowsTheBiometry(biometryType: LABiometryType, symbol: String) {
        #expect(AIRequestUnlock.symbol(for: biometryType) == symbol)
        #expect(AIRequestUnlock.approveLabel(shown: Self.dose, biometryType: biometryType).symbol == symbol)
    }

    @Test("The title is the dose") func titleIsTheDose() {
        #expect(AIRequestUnlock.approveLabel(shown: Self.dose, biometryType: .faceID).title == "Approve 2.10\u{00A0}U")
    }

    @Test("The title for a 0 U request logs the carbs") func titleForNoDose() {
        #expect(AIRequestUnlock.approveLabel(shown: Self.noDose, biometryType: .touchID).title == "Log 35\u{00A0}g carbs")
    }

    // MARK: The amounts

    @Test("The dose reads as shown, with two decimals") func unitsText() {
        #expect(Self.dose.unitsText == "2.10\u{00A0}U")
        #expect(Self.noDose.unitsText == "0.00\u{00A0}U")
    }

    @Test("The carbs lose their trailing zeros") func carbsText() {
        #expect(Self.dose.carbsText == "35\u{00A0}g")
        #expect(AIRequestShown(carbs: "12.50", fat: "0.00", protein: "0.00", units: "1.00").carbsText == "12.5\u{00A0}g")
        #expect(AIRequestShown(carbs: "100.00", fat: "0.00", protein: "0.00", units: "1.00").carbsText == "100\u{00A0}g")
    }

    @Test("Fat and protein show only when there is some") func fatAndProteinText() {
        #expect(Self.dose.fatAndProteinText == nil)
        let both = AIRequestShown(carbs: "35.00", fat: "10.00", protein: "12.50", units: "2.10")
        #expect(both.fatAndProteinText == "10\u{00A0}g fat · 12.5\u{00A0}g protein")
        let fatOnly = AIRequestShown(carbs: "35.00", fat: "10.00", protein: "0.00", units: "2.10")
        #expect(fatOnly.fatAndProteinText == "10\u{00A0}g fat")
        let proteinOnly = AIRequestShown(carbs: "35.00", fat: "0.00", protein: "8.00", units: "2.10")
        #expect(proteinOnly.fatAndProteinText == "8\u{00A0}g protein")
    }
}
