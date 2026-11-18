import Foundation
import Testing

@testable import Trio

// The carb ratio test's rules. The worked example most tests use: 10 Dex4 tablets (40 g), a carb ratio of 10 g/U and
// an ISF of 50 mg/dL/U, so the docs' dose is 40 ÷ 10 = 4 U. A carb ratio a docs step (1 g/U) higher gives 40 ÷ 11 =
// 3.6364 U and one a step lower 40 ÷ 9 = 4.4444 U, so with 4 U acting the accurate end readings lie between
// start + 50 × (3.6364 − 4) = start − 18.18 and start + 50 × (4.4444 − 4) = start + 22.22.

/// An exact decimal. A Decimal written as a literal goes through a Double, which makes 2.24 a hair more than 2.24.
private func dec(_ string: String) -> Decimal { Decimal(string: string)! }

private let hour: TimeInterval = 3600
private let minute: TimeInterval = 60

/// A fixed moment, so dates round-trip through the state file's milliseconds.
private let testStart = Date(timeIntervalSinceReferenceDate: 815_000_000)

private func at(_ seconds: TimeInterval) -> Date { testStart.addingTimeInterval(seconds) }

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func entry(_ start: Int, _ end: Int, _ value: Decimal) -> SettingsTestScheduleEntry {
    SettingsTestScheduleEntry(startMinutes: start, endMinutes: end, value: value)
}

/// A test as Begin saves it for the worked example, dosing from an hour after Begin.
private func makeTest(
    phase: CarbRatioTestPhase = .dosing,
    carbRatio: Decimal = 10,
    isf: Decimal = 50,
    tabletCarbs: Decimal = 40,
    length: TimeInterval = 4 * hour,
    handling: ISFTestIOBHandling? = nil
) -> CarbRatioTestState {
    let expectedDose = CarbRatioTestEvaluator.unroundedDose(carbs: tabletCarbs, carbRatio: carbRatio) ?? 0
    return CarbRatioTestState(
        phase: phase,
        startedAt: testStart,
        previousMode: .closed,
        carbRatio: carbRatio,
        isf: isf,
        target: 100,
        bolusIncrement: dec("0.05"),
        length: length,
        tabletBrand: GlucoseTabletBrand.dex4.rawValue,
        tabletCount: 10,
        tabletCarbs: tabletCarbs,
        expectedDose: expectedDose,
        iobLine: CarbRatioTestEvaluator.iobLine(dose: expectedDose, carbRatio: carbRatio),
        cobLine: CarbRatioTestEvaluator.cobLine(carbs: tabletCarbs, carbRatio: carbRatio),
        iobHandling: handling,
        settledAt: phase == .settling ? nil : at(hour)
    )
}

/// The worked example finished after its 4 hours: bolus 4 U with 0.3 U on board at it and 0.3 U left at the end, so 4 U
/// judged, 40 g logged, glucose from 100 to 110.
private func finishedTest(
    reason: CarbRatioTestEndReason = .completed,
    ranFor elapsed: TimeInterval = 4 * hour,
    start: Int? = 100,
    end: Int? = 110,
    bolus: Decimal? = 4,
    iobAtBolus: Decimal? = dec("0.3"),
    iobAtEnd: Decimal? = dec("0.3"),
    carbs: Decimal? = 40
) -> CarbRatioTestState {
    var test = makeTest(phase: .finished)
    test.bolusAt = at(hour + 10 * minute)
    test.bolusUnits = bolus
    test.iobAtBolus = iobAtBolus
    test.iobAtEnd = iobAtEnd
    test.startGlucose = start
    test.endGlucose = end
    test.carbs = carbs
    test.carbsAt = test.bolusAt
    test.endedAt = test.bolusAt?.addingTimeInterval(elapsed)
    test.endReason = reason
    test.outcome = CarbRatioTestEvaluator.evaluation(of: test)?.outcome
    return test
}

// MARK: - The docs' numbers and the steps

@Suite("Carb ratio test config and docs") struct CarbRatioTestConfigTests {
    @Test("The docs' numbers: a 1 g/U step and 3 or 4 hours, 4 to start with") func docsNumbers() {
        #expect(CarbRatioTest.Config.docsSmallestStep == 1)
        #expect(CarbRatioTest.Config.lengths == [3 * hour, 4 * hour])
        #expect(CarbRatioTest.Config.defaultLength == 4 * hour)
        #expect(CarbRatioTest.Config.statePath == "trio/carb_ratio_test_state.json")
    }

    @Test("The app's numbers: 10 tablets to start with, 20 at most, carbs up to 15 minutes after the bolus") func appNumbers() {
        #expect(CarbRatioTest.Config.defaultTabletCount == 10)
        #expect(CarbRatioTest.Config.maxTabletCount == 20)
        #expect(CarbRatioTest.Config.mealPairing == 15 * minute)
    }

    @Test("Settling, the dose allowance, the mean, the grace and the tolerance are the ISF test's") func sharedLimits() {
        #expect(CarbRatioTest.Config.doseAllowance == ISFTest.Config.doseAllowance)
        #expect(CarbRatioTest.Config.settleLoopMargin == ISFTest.Config.settleLoopMargin)
        #expect(CarbRatioTest.Config.settleAllowance == ISFTest.Config.settleAllowance)
        #expect(CarbRatioTest.Config.meanReadings == ISFTest.Config.meanReadings)
        #expect(CarbRatioTest.Config.settleReadings == ISFTest.Config.settleReadings)
        #expect(CarbRatioTest.Config.expiryGrace == ISFTest.Config.expiryGrace)
        #expect(CarbRatioTest.Config.savedDateTolerance == ISFTest.Config.savedDateTolerance)
    }

    @Test("The steps run check, settle, dose, wait, result, with the ISF test's icons") func steps() {
        #expect(CarbRatioTest.Step.allCases.map(\.title) == ["Check", "Settle", "Dose", "Wait", "Result"])
        #expect(CarbRatioTest.Step.allCases.map(\.iconName) == [
            "checklist", "hourglass", "syringe", "timer", "chart.line.uptrend.xyaxis"
        ])
        #expect(CarbRatioTest.Step.allCases.map(\.order) == [0, 1, 2, 3, 4])
    }

    @Test("The docs' lines keep their arrows and hyphens, and the links go to carb-ratios.md") func docsQuotes() {
        // U+2192, as carb-ratios.md writes it.
        #expect(CarbRatioTest.Docs.endUpHigh == "End up high: CR is too high (too conservative) \u{2192} DECREASE the CR value")
        #expect(CarbRatioTest.Docs.endUpLow == "End up low: CR is too low (too aggressive) \u{2192} INCREASE the CR value")
        // ASCII hyphens.
        #expect(CarbRatioTest.Docs.monitor == "Monitor for 3-4 hours")
        #expect(CarbRatioTest.Docs.smallChanges == "Make small changes: Adjust by 1-2 g/U at a time")
        #expect(CarbRatioTest.Docs.calculateInsulin == "Calculate insulin: Carbs ÷ Current CR")
        #expect(
            CarbRatioTest.Docs.testingMethod.absoluteString
                == "https://triodocs.org/usage/concepts/carb-ratios/#testing-method-meal-experiment"
        )
        #expect(
            CarbRatioTest.Docs.bestPractices
                .absoluteString == "https://triodocs.org/usage/concepts/carb-ratios/#best-practices"
        )
        #expect(CarbRatioTest.Docs.recommendedBolusPercentage == ISFTest.Docs.recommendedBolusPercentage)
    }

    @Test("Phases and end reasons map to the ISF test's, both ways") func isfMapping() {
        #expect([CarbRatioTestPhase.settling, .dosing, .waiting, .finished].map(\.isfPhase) == [
            .settling, .dosing, .waiting, .finished
        ])
        let reasons: [CarbRatioTestEndReason] = [.completed, .endedEarly, .low, .interrupted, .unchecked, .noBolus]
        #expect(reasons.map { CarbRatioTestEndReason($0.isfReason) } == reasons)
        #expect(reasons.map(\.isfReason.rawValue) == reasons.map(\.rawValue))
    }
}

// MARK: - The dose

@Suite("Carb ratio test dose") struct CarbRatioTestDoseTests {
    @Test("The dose is the docs' formula, carbs over the carb ratio, to 2 decimals") func doseFromDocsFormula() {
        // 40 ÷ 10 = 4.
        #expect(CarbRatioTestEvaluator.dose(carbs: 40, carbRatio: 10) == 4)
        // 40 ÷ 15 = 2.6666…, rounded half up to 2.67.
        #expect(CarbRatioTestEvaluator.dose(carbs: 40, carbRatio: 15) == dec("2.67"))
        // 10 TruePlus tablets, 37.5 g ÷ 12 = 3.125, which rounds half up to 3.13.
        #expect(CarbRatioTestEvaluator.dose(carbs: dec("37.5"), carbRatio: 12) == dec("3.13"))
        // Unrounded, 37.5 ÷ 12 is exactly 3.125.
        #expect(CarbRatioTestEvaluator.unroundedDose(carbs: dec("37.5"), carbRatio: 12) == dec("3.125"))
    }

    @Test("No carbs, or no carb ratio, gives no dose") func noDoseWithoutSettings() {
        #expect(CarbRatioTestEvaluator.dose(carbs: 0, carbRatio: 10) == nil)
        #expect(CarbRatioTestEvaluator.dose(carbs: 40, carbRatio: 0) == nil)
        #expect(CarbRatioTestEvaluator.dose(carbs: 40, carbRatio: -5) == nil)
    }

    @Test("Count It takes insulin on board off the dose, as shown to 2 decimals") func countedDose() {
        // 4 − 0.5 = 3.5.
        #expect(CarbRatioTestEvaluator.countedDose(carbs: 40, carbRatio: 10, iob: dec("0.5")) == dec("3.5"))
        // 0.333 U on board shows as 0.33, so 4 − 0.33 = 3.67.
        #expect(CarbRatioTestEvaluator.countedDose(carbs: 40, carbRatio: 10, iob: dec("0.333")) == dec("3.67"))
        // Basal Trio held back, −0.3 U, adds to it: 4 + 0.3 = 4.3.
        #expect(CarbRatioTestEvaluator.countedDose(carbs: 40, carbRatio: 10, iob: dec("-0.3")) == dec("4.3"))
        // 40 ÷ 15 = 2.6667 less 0.5 = 2.1667, shown 2.17.
        #expect(CarbRatioTestEvaluator.countedDose(carbs: 40, carbRatio: 15, iob: dec("0.5")) == dec("2.17"))
    }

    @Test("Insulin on board that covers the dose, or leaves less than the pump gives, leaves none") func countedDoseCovered() {
        // 4 − 4 = 0.
        #expect(CarbRatioTestEvaluator.countedDose(carbs: 40, carbRatio: 10, iob: 4) == nil)
        // 3.996 U shows as 4.00, so 4 − 4.00 = 0.
        #expect(CarbRatioTestEvaluator.countedDose(carbs: 40, carbRatio: 10, iob: dec("3.996")) == nil)
        // 4 − 3.99 = 0.01: under a 0.05 U increment, none; with no increment known, 0.01.
        #expect(CarbRatioTestEvaluator.countedDose(carbs: 40, carbRatio: 10, iob: dec("3.99"), increment: dec("0.05")) == nil)
        #expect(CarbRatioTestEvaluator.countedDose(carbs: 40, carbRatio: 10, iob: dec("3.99")) == dec("0.01"))
        // 4 − 3.95 = 0.05, exactly the increment.
        #expect(
            CarbRatioTestEvaluator.countedDose(carbs: 40, carbRatio: 10, iob: dec("3.95"), increment: dec("0.05")) ==
                dec("0.05")
        )
    }

    @Test("The test's dose is the formula's, or with Count It the counted one once insulin on board is read") func testDose() {
        #expect(CarbRatioTestEvaluator.testDose(carbs: 40, carbRatio: 10, handling: nil, iob: nil) == 4)
        #expect(CarbRatioTestEvaluator.testDose(carbs: 40, carbRatio: 10, handling: .wait, iob: dec("0.5")) == 4)
        // 4 − 0.5.
        #expect(CarbRatioTestEvaluator.testDose(carbs: 40, carbRatio: 10, handling: .count, iob: dec("0.5")) == dec("3.5"))
        #expect(CarbRatioTestEvaluator.testDose(carbs: 40, carbRatio: 10, handling: .count, iob: nil) == nil)
    }
}

// MARK: - Insulin and carbs on board

@Suite("Carb ratio test lines") struct CarbRatioTestLineTests {
    @Test("The insulin line is what a 1 g/U step changes in the dose") func iobLine() {
        // 4 × 1 ÷ 11 = 0.3636, shown 0.36: 40 ÷ 10 − 40 ÷ 11 = 4 − 3.6364.
        #expect(CarbRatioTestEvaluator.iobLine(dose: 4, carbRatio: 10) == dec("0.36"))
        // 2 × 1 ÷ 21 = 0.0952, shown 0.10: 40 ÷ 20 − 40 ÷ 21 = 2 − 1.9048.
        #expect(CarbRatioTestEvaluator.iobLine(dose: 2, carbRatio: 20) == dec("0.1"))
        // A 2 g/U step: 4 × 2 ÷ 12 = 0.6667, shown 0.67.
        #expect(CarbRatioTestEvaluator.iobLine(dose: 4, carbRatio: 10, step: 2) == dec("0.67"))
        #expect(CarbRatioTestEvaluator.iobLine(dose: 0, carbRatio: 10) == 0)
        #expect(CarbRatioTestEvaluator.iobLine(dose: 4, carbRatio: 0) == 0)
    }

    @Test("The carbs line is the carbs a 1 g/U step changes, to 1 decimal") func cobLine() {
        // 40 × 1 ÷ 11 = 3.636, shown 3.6: the 0.3636 U of the insulin line at 10 g/U.
        #expect(CarbRatioTestEvaluator.cobLine(carbs: 40, carbRatio: 10) == dec("3.6"))
        // 40 ÷ 21 = 1.905, shown 1.9.
        #expect(CarbRatioTestEvaluator.cobLine(carbs: 40, carbRatio: 20) == dec("1.9"))
        // 37.5 ÷ 13 = 2.885, shown 2.9.
        #expect(CarbRatioTestEvaluator.cobLine(carbs: dec("37.5"), carbRatio: 12) == dec("2.9"))
        #expect(CarbRatioTestEvaluator.cobLine(carbs: 0, carbRatio: 10) == 0)
    }

    @Test("Carbs on board at or over the line block, as shown to 1 decimal; none and unread never do") func cobBlocks() {
        #expect(CarbRatioTestEvaluator.cobBlocks(cob: dec("3.6"), line: dec("3.6")))
        // 3.55 g shows as 3.6.
        #expect(CarbRatioTestEvaluator.cobBlocks(cob: dec("3.55"), line: dec("3.6")))
        // 3.54 g shows as 3.5.
        #expect(!CarbRatioTestEvaluator.cobBlocks(cob: dec("3.54"), line: dec("3.6")))
        #expect(!CarbRatioTestEvaluator.cobBlocks(cob: nil, line: dec("3.6")))
        // A line that rounds to zero doesn't block a test with none on board, nor with 0.04 g, shown 0.0.
        #expect(!CarbRatioTestEvaluator.cobBlocks(cob: 0, line: 0))
        #expect(!CarbRatioTestEvaluator.cobBlocks(cob: dec("0.04"), line: 0))
    }

    @Test("Insulin on board at Begin: fine to the line, a choice to the whole dose, blocked past it") func iobDecision() {
        func decide(_ iob: Decimal?) -> ISFTestIOBDecision? {
            CarbRatioTestEvaluator.iobDecision(iob: iob, expectedDose: 4, carbRatio: 10)
        }
        // The line for 4 U at 10 g/U is 0.36 U.
        #expect(decide(dec("0.36")) == .fine)
        // 0.364 shows as 0.36.
        #expect(decide(dec("0.364")) == .fine)
        // 0.365 shows as 0.37.
        #expect(decide(dec("0.365")) == .choice(line: dec("0.36")))
        // Held back counts by its size.
        #expect(decide(dec("-0.5")) == .choice(line: dec("0.36")))
        #expect(decide(4) == .choice(line: dec("0.36")))
        // 4.004 shows as 4.00, the whole dose.
        #expect(decide(dec("4.004")) == .choice(line: dec("0.36")))
        #expect(decide(dec("4.01")) == .blocked)
        #expect(decide(nil) == nil)
        #expect(CarbRatioTestEvaluator.iobDecision(iob: 1, expectedDose: nil, carbRatio: 10) == nil)
        #expect(CarbRatioTestEvaluator.iobDecision(iob: 1, expectedDose: 4, carbRatio: nil) == nil)
    }

    @Test("Begin saves the user's choice only when there was one") func iobHandling() {
        #expect(CarbRatioTestEvaluator.iobHandling(for: .choice(line: 1), chosen: .count) == .count)
        #expect(CarbRatioTestEvaluator.iobHandling(for: .fine, chosen: .count) == nil)
        #expect(CarbRatioTestEvaluator.iobHandling(for: nil, chosen: .wait) == nil)
    }

    @Test("Carbs on board before the meal are read strictly before it, no more than 12 minutes back") func cobBefore() {
        let meal = at(2 * hour)
        let determinations = [
            ISFTestDetermination(date: meal.addingTimeInterval(-9 * minute), iob: 0, cob: 2),
            // Made at the meal, already counting the tablets.
            ISFTestDetermination(date: meal, iob: 0, cob: 40)
        ]
        #expect(CarbRatioTestEvaluator.cobBefore(determinations, moment: meal) == 2)
        // A read 13 minutes before is too old.
        let old = [ISFTestDetermination(date: meal.addingTimeInterval(-13 * minute), iob: 0, cob: 2)]
        #expect(CarbRatioTestEvaluator.cobBefore(old, moment: meal) == nil)
    }
}

// MARK: - Tablets

@Suite("Carb ratio test tablets") struct CarbRatioTestTabletTests {
    @Test("Up to 20 tablets while their dose fits Max Bolus and their carbs Max Carbs") func maxTablets() {
        // 20 Dex4 tablets, 80 g ÷ 10 = 8 U, within a 10 U Max Bolus.
        #expect(CarbRatioTestEvaluator.maxTablets(brand: .dex4, carbRatio: 10, maxBolus: 10, maxCarbs: 250) == 20)
        // 7 tablets give 28 g ÷ 10 = 2.8 U; 8 would give 3.2 U, over a 3 U Max Bolus.
        #expect(CarbRatioTestEvaluator.maxTablets(brand: .dex4, carbRatio: 10, maxBolus: 3, maxCarbs: 250) == 7)
        // 7 tablets are 28 g; 8 would be 32 g, over a 30 g Max Carbs.
        #expect(CarbRatioTestEvaluator.maxTablets(brand: .dex4, carbRatio: 10, maxBolus: 10, maxCarbs: 30) == 7)
        // 8 TruePlus tablets are 30 g ÷ 10 = exactly 3 U.
        #expect(CarbRatioTestEvaluator.maxTablets(brand: .trueplus, carbRatio: 10, maxBolus: 3, maxCarbs: 250) == 8)
        // One tablet, 4 g ÷ 10 = 0.4 U, is over a 0.3 U Max Bolus.
        #expect(CarbRatioTestEvaluator.maxTablets(brand: .dex4, carbRatio: 10, maxBolus: dec("0.3"), maxCarbs: 250) == 0)
        #expect(CarbRatioTestEvaluator.maxTablets(brand: .dex4, carbRatio: 0, maxBolus: 10, maxCarbs: 250) == 0)
    }

    @Test("The count stays between 1 and the most allowed; with none allowed there is none") func tabletCount() {
        func count(_ wanted: Int, maxBolus: Decimal = 10) -> Int? {
            CarbRatioTestEvaluator.tabletCount(wanted, brand: .dex4, carbRatio: 10, maxBolus: maxBolus, maxCarbs: 250)
        }
        #expect(CarbRatioTestEvaluator.tabletCount(brand: .dex4, carbRatio: 10, maxBolus: 10, maxCarbs: 250) == 10)
        #expect(count(25) == 20)
        #expect(count(0) == 1)
        #expect(count(-3) == 1)
        // The most for a 3 U Max Bolus is 7 (above).
        #expect(count(10, maxBolus: 3) == 7)
        #expect(count(10, maxBolus: dec("0.3")) == nil)
    }
}

// MARK: - The band and the ratio

@Suite("Carb ratio test band") struct CarbRatioTestBandTests {
    @Test("The worked example's band: about 18 below to 22 above the start") func workedBand() {
        // 100 + 50 × (40 ÷ 11 − 4) = 81.82, so from 82; 100 + 50 × (40 ÷ 9 − 4) = 122.22, so to 122.
        #expect(
            CarbRatioTestEvaluator.accurateEnds(startGlucose: 100, carbs: 40, units: 4, carbRatio: 10, isf: 50)
                == CarbRatioTestBand(lowest: 82, highest: 122)
        )
    }

    @Test("A carb ratio of 20 and an ISF of 100") func band20And100() {
        // 40 g at 20 g/U is 2 U. 120 + 100 × (40 ÷ 21 − 2) = 110.48, so from 111; 120 + 100 × (40 ÷ 19 − 2) = 130.53, so
        // to 130.
        #expect(
            CarbRatioTestEvaluator.accurateEnds(startGlucose: 120, carbs: 40, units: 2, carbRatio: 20, isf: 100)
                == CarbRatioTestBand(lowest: 111, highest: 130)
        )
    }

    @Test("An ISF in mmol/L, already converted to mg/dL, gives its own band") func bandFromMmol() {
        // 3 mmol/L/U ÷ 0.0555 = 54.054 mg/dL/U. 100 − 54.054 × 0.3636 = 80.34, so from 81; 100 + 54.054 × 0.4444 =
        // 124.02, so to 124. An ISF of 50 would stop at 122.
        let isf = 3 / GlucoseUnits.exchangeRate
        #expect(
            CarbRatioTestEvaluator.accurateEnds(startGlucose: 100, carbs: 40, units: 4, carbRatio: 10, isf: isf)
                == CarbRatioTestBand(lowest: 81, highest: 124)
        )
    }

    @Test("A carb ratio at or under the docs' step has no top to its band") func bandWithoutTop() {
        // 1 tablet, 4 g, at 1 g/U is 4 U. 100 + 50 × (4 ÷ 2 − 4) = 0, so from 1, and no ratio a step under 1 g/U.
        let band = CarbRatioTestEvaluator.accurateEnds(startGlucose: 100, carbs: 4, units: 4, carbRatio: 1, isf: 50)
        #expect(band == CarbRatioTestBand(lowest: 1, highest: nil))
        #expect(band?.contains(400) == true)
        #expect(band?.contains(0) == false)
        // At 0.8 g/U, 100 + 50 × (4 ÷ 1.8 − 5) = −38.9, so from −38 (floor −39, plus one), and again no top.
        #expect(
            CarbRatioTestEvaluator.accurateEnds(startGlucose: 100, carbs: 4, units: 5, carbRatio: dec("0.8"), isf: 50)
                == CarbRatioTestBand(lowest: -38, highest: nil)
        )
    }

    @Test("An edge that falls on a whole reading is outside the band") func bandEdgesExact() {
        // 44 g at 10 g/U with 4 U: 44 ÷ 11 = 4, so the low edge is the start itself, 100, and the band starts at 101;
        // 100 + 55 × (44 ÷ 9 − 4) = 148.89, so it ends at 148.
        #expect(
            CarbRatioTestEvaluator.accurateEnds(startGlucose: 100, carbs: 44, units: 4, carbRatio: 10, isf: 55)
                == CarbRatioTestBand(lowest: 101, highest: 148)
        )
        // 45 g at 10 g/U with 5 U: 45 ÷ 9 = 5, so the high edge is 100 and the band ends at 99; 100 + 50 × (45 ÷ 11 − 5)
        // = 54.55, so it starts at 55.
        #expect(
            CarbRatioTestEvaluator.accurateEnds(startGlucose: 100, carbs: 45, units: 5, carbRatio: 10, isf: 50)
                == CarbRatioTestBand(lowest: 55, highest: 99)
        )
    }

    @Test("Too few carbs leave no whole reading inside the band") func emptyBand() {
        // 1 tablet at 30 g/U with 0.12 U and an ISF of 20: 100 + 20 × (4 ÷ 31 − 0.12) = 100.18 and
        // 100 + 20 × (4 ÷ 29 − 0.12) = 100.36. No whole number lies between.
        #expect(
            CarbRatioTestEvaluator.accurateEnds(startGlucose: 100, carbs: 4, units: dec("0.12"), carbRatio: 30, isf: 20)
                == nil
        )
    }

    @Test("Without carbs, units, a carb ratio or an ISF there is no band") func bandNeedsInputs() {
        #expect(CarbRatioTestEvaluator.accurateEnds(startGlucose: 100, carbs: 0, units: 4, carbRatio: 10, isf: 50) == nil)
        #expect(CarbRatioTestEvaluator.accurateEnds(startGlucose: 100, carbs: 40, units: 0, carbRatio: 10, isf: 50) == nil)
        #expect(CarbRatioTestEvaluator.accurateEnds(startGlucose: 100, carbs: 40, units: 4, carbRatio: 0, isf: 50) == nil)
        #expect(CarbRatioTestEvaluator.accurateEnds(startGlucose: 100, carbs: 40, units: 4, carbRatio: 10, isf: 0) == nil)
    }

    @Test("The shown ratio is the carbs over the units plus the change turned into units") func shownRatio() {
        // 40 ÷ (4 + 0 ÷ 50) = 10.
        #expect(CarbRatioTestEvaluator.shownRatio(carbs: 40, units: 4, change: 0, isf: 50) == 10)
        // 40 ÷ (4 + 20 ÷ 50) = 40 ÷ 4.4 = 9.0909.
        let rose = CarbRatioTestEvaluator.shownRatio(carbs: 40, units: 4, change: 20, isf: 50)
        #expect(rose.map { rounded($0, scale: 4, roundingMode: .plain) } == dec("9.0909"))
        // 40 ÷ (4 − 25 ÷ 50) = 40 ÷ 3.5 = 11.4286.
        let fell = CarbRatioTestEvaluator.shownRatio(carbs: 40, units: 4, change: -25, isf: 50)
        #expect(fell.map { rounded($0, scale: 4, roundingMode: .plain) } == dec("11.4286"))
        // 40 ÷ (4 − 199 ÷ 50) = 40 ÷ 0.02 = 2000.
        #expect(CarbRatioTestEvaluator.shownRatio(carbs: 40, units: 4, change: -199, isf: 50) == 2000)
    }

    @Test("A fall of all the insulin explains, or more, has no shown ratio") func shownRatioDenominator() {
        // 4 − 200 ÷ 50 = 0, and 4 − 250 ÷ 50 = −1.
        #expect(CarbRatioTestEvaluator.shownRatio(carbs: 40, units: 4, change: -200, isf: 50) == nil)
        #expect(CarbRatioTestEvaluator.shownRatio(carbs: 40, units: 4, change: -250, isf: 50) == nil)
        #expect(CarbRatioTestEvaluator.shownRatio(carbs: 40, units: 4, change: 0, isf: 0) == nil)
        #expect(CarbRatioTestEvaluator.shownRatio(carbs: 0, units: 4, change: 0, isf: 50) == nil)
    }
}

// MARK: - The result

@Suite("Carb ratio test evaluate") struct CarbRatioTestEvaluateTests {
    /// The worked example, 4 hours after the bolus, judged on 4 U.
    private func evaluate(
        start: Int? = 100,
        end: Int?,
        units: Decimal? = 4,
        elapsed: TimeInterval = 4 * hour,
        length: TimeInterval = 4 * hour,
        reason: CarbRatioTestEndReason = .completed,
        interference: String? = nil,
        interferenceUnread: Bool = false,
        iobUnread: Bool = false,
        carbs: Decimal? = 40,
        carbRatio: Decimal? = 10,
        isf: Decimal? = 50,
        givenUnits: Decimal? = 4,
        lowThreshold: Decimal = Preferences.basalTestingThreshold
    ) -> CarbRatioTestEvaluator.Evaluation {
        CarbRatioTestEvaluator.evaluate(
            startGlucose: start,
            endGlucose: end,
            units: units,
            elapsed: elapsed,
            length: length,
            reason: reason,
            interference: interference,
            interferenceUnread: interferenceUnread,
            iobUnread: iobUnread,
            carbs: carbs,
            carbRatio: carbRatio,
            isf: isf,
            givenUnits: givenUnits,
            increment: dec("0.05"),
            lowThreshold: lowThreshold
        )
    }

    @Test("Back where it started: the carb ratio is accurate") func backToStart() {
        // 40 ÷ (4 + 0) = 10, the carb ratio.
        let result = evaluate(end: 100)
        #expect(result.outcome == .accurate)
        #expect(result.direction == .keep)
        #expect(result.shownRatio == 10)
        #expect(result.difference == 0)
    }

    @Test("Inside the band is accurate, at either end") func insideBand() {
        // 122: 40 ÷ (4 + 22 ÷ 50) = 40 ÷ 4.44 = 9.009, 0.991 under the carb ratio.
        #expect(evaluate(end: 122).outcome == .accurate)
        // 82: 40 ÷ (4 − 18 ÷ 50) = 40 ÷ 3.64 = 10.989, 0.989 over it.
        #expect(evaluate(end: 82).outcome == .accurate)
    }

    @Test("Ending high past the band says the CR is too high: decrease it") func endUpHigh() throws {
        // 123: 40 ÷ (4 + 23 ÷ 50) = 40 ÷ 4.46 = 8.9686, 1.0314 under.
        let result = evaluate(end: 123)
        #expect(result.outcome == .tooHigh)
        #expect(result.direction == .decrease)
        let difference = try #require(result.difference)
        #expect(rounded(difference, scale: 4, roundingMode: .plain) == dec("-1.0314"))
        let shown = try #require(result.shownRatio)
        #expect(rounded(shown, scale: 4, roundingMode: .plain) == dec("8.9686"))
    }

    @Test("Ending low past the band says the CR is too low: increase it") func endUpLow() throws {
        // 81: 40 ÷ (4 − 19 ÷ 50) = 40 ÷ 3.62 = 11.0497, 1.0497 over.
        let result = evaluate(end: 81)
        #expect(result.outcome == .tooLow)
        #expect(result.direction == .increase)
        let difference = try #require(result.difference)
        #expect(rounded(difference, scale: 4, roundingMode: .plain) == dec("1.0497"))
    }

    @Test("Exactly 1 g/U off is a change, not accurate, either way") func exactlyOneStep() {
        // 44 g, 4 U, ISF 55: back at 100, 44 ÷ 4 = 11, exactly 1 over a carb ratio of 10.
        let over = evaluate(end: 100, units: 4, carbs: 44, isf: 55, givenUnits: 4)
        #expect(over.outcome == .tooLow)
        #expect(over.difference == 1)
        // At 101, 44 ÷ (4 + 1 ÷ 55) = 10.95: inside.
        #expect(evaluate(end: 101, units: 4, carbs: 44, isf: 55, givenUnits: 4).outcome == .accurate)
        // 45 g, 5 U, ISF 50: back at 100, 45 ÷ 5 = 9, exactly 1 under.
        let under = evaluate(end: 100, units: 5, carbs: 45, givenUnits: 5)
        #expect(under.outcome == .tooHigh)
        #expect(under.difference == -1)
        // At 99, 45 ÷ (5 − 1 ÷ 50) = 9.036: inside.
        #expect(evaluate(end: 99, units: 5, carbs: 45, givenUnits: 5).outcome == .accurate)
    }

    @Test("Glucose that fell by all the insulin explains, or more, says the CR is too low") func denominatorAtZero() {
        // From 250 to 50: 4 − 200 ÷ 50 = 0 units covered the carbs. The band, 232 to 272, has readings in it.
        let result = evaluate(start: 250, end: 50)
        #expect(result.outcome == .tooLow)
        #expect(result.direction == .increase)
        #expect(result.shownRatio == nil)
        #expect(result.difference == nil)
    }

    @Test("A converted mmol/L ISF judges by its own band") func mmolISF() {
        // ISF 54.054: 124 gives 40 ÷ (4 + 24 ÷ 54.054) = 40 ÷ 4.444 = 9.0009, inside; 125 gives 40 ÷ 4.4625 = 8.9636.
        let isf = 3 / GlucoseUnits.exchangeRate
        #expect(evaluate(end: 124, isf: isf).outcome == .accurate)
        #expect(evaluate(end: 125, isf: isf).outcome == .tooHigh)
        // With an ISF of 50, 124 gives 40 ÷ 4.48 = 8.93: too high.
        #expect(evaluate(end: 124).outcome == .tooHigh)
    }

    @Test("A carb ratio at or under the step is never too high") func smallCarbRatio() {
        // 4 g at 1 g/U, 4 U: 300 gives 4 ÷ (4 + 200 ÷ 50) = 0.5, 0.5 under: accurate.
        #expect(evaluate(end: 300, units: 4, carbs: 4, carbRatio: 1).outcome == .accurate)
        // 50 gives 4 ÷ (4 − 50 ÷ 50) = 1.333, 0.333 over: accurate.
        #expect(evaluate(end: 50, units: 4, carbs: 4, carbRatio: 1).outcome == .accurate)
        // From 300 to 50, 4 − 250 ÷ 50 = −1 units covered the carbs: too low. (The band, from 201, has readings in it.)
        #expect(evaluate(start: 300, end: 50, units: 4, carbs: 4, carbRatio: 1).outcome == .tooLow)
    }

    @Test("Something that spoiled the test, or no bolus, is invalid") func invalid() {
        #expect(evaluate(end: 100, interference: "Carbs were logged during the test.").outcome == .invalid)
        #expect(evaluate(end: 100, reason: .interrupted).outcome == .invalid)
        #expect(evaluate(end: 100, reason: .noBolus).outcome == .invalid)
        #expect(evaluate(end: 100, reason: .noBolus).direction == nil)
    }

    @Test("Records that couldn't be read say nothing, a low among them") func unread() {
        #expect(evaluate(end: 100, interferenceUnread: true).outcome == .inconclusive)
        #expect(evaluate(end: 70, reason: .low, interferenceUnread: true).outcome == .inconclusive)
        #expect(evaluate(end: 100, iobUnread: true).outcome == .inconclusive)
    }

    @Test("Ending early, unchecked, or short of the chosen length says nothing") func tooSoon() {
        #expect(evaluate(end: 100, reason: .endedEarly).outcome == .inconclusive)
        #expect(evaluate(end: 100, reason: .unchecked).outcome == .inconclusive)
        #expect(evaluate(end: 100, elapsed: 3.5 * hour).outcome == .inconclusive)
        // 3 hours is enough when 3 hours were chosen.
        #expect(evaluate(end: 100, elapsed: 3 * hour, length: 3 * hour).outcome == .accurate)
    }

    @Test("A missing reading, amount, carbs or setting says nothing") func missing() {
        #expect(evaluate(start: nil, end: 100).outcome == .inconclusive)
        #expect(evaluate(end: nil).outcome == .inconclusive)
        #expect(evaluate(end: 100, units: nil).outcome == .inconclusive)
        #expect(evaluate(end: 100, units: 0).outcome == .inconclusive)
        #expect(evaluate(end: 100, carbs: nil).outcome == .inconclusive)
        #expect(evaluate(end: 100, carbRatio: 0).outcome == .inconclusive)
        #expect(evaluate(end: 100, isf: nil).outcome == .inconclusive)
    }

    @Test("Too few carbs for any whole reading to be accurate says nothing") func carbsTooFew() {
        // The empty band above: 4 g at 30 g/U with 0.12 U and an ISF of 20.
        let result = evaluate(end: 100, units: dec("0.12"), carbs: 4, carbRatio: 30, isf: 20, givenUnits: dec("0.12"))
        #expect(result.outcome == .inconclusive)
        #expect(result.shownRatio == nil)
    }

    @Test("A low the carb ratio accounts for says it is too low; others say nothing") func low() {
        // At or below the start and Trio's 72 mg/dL low line, after no more than 40 ÷ 9 = 4.44 U, rounded up to 4.45.
        #expect(evaluate(end: 70, reason: .low, givenUnits: 4).outcome == .tooLow)
        #expect(evaluate(end: 70, reason: .low, givenUnits: 4).direction == .increase)
        #expect(evaluate(end: 70, reason: .low, givenUnits: dec("4.5")).outcome == .inconclusive)
        // Still above the start.
        #expect(evaluate(end: 105, reason: .low).outcome == .inconclusive)
        // R2-1: under the start but above the low line: Trio's forecast, not a low.
        #expect(evaluate(end: 80, reason: .low).outcome == .inconclusive)
        // With the user's own threshold over 72, that line.
        #expect(evaluate(end: 80, reason: .low, lowThreshold: 85).outcome == .tooLow)
        // A low ends the test, so it isn't judged on the ratio, and comes before insulin on board left unread.
        #expect(evaluate(end: 70, elapsed: hour, reason: .low, iobUnread: true).outcome == .tooLow)
        #expect(evaluate(end: 70, reason: .low).shownRatio == nil)
    }
}

@Suite("Carb ratio test low") struct CarbRatioTestLowTests {
    private func noVerdict(
        suspend: Int? = 70,
        start: Int? = 100,
        given: Decimal? = 4,
        carbs: Decimal? = 40,
        carbRatio: Decimal? = 10,
        increment: Decimal = dec("0.05"),
        lowThreshold: Decimal = Preferences.basalTestingThreshold
    ) -> CarbRatioTestNoVerdict? {
        CarbRatioTestEvaluator.lowNoVerdict(
            glucoseAtSuspend: suspend,
            startGlucose: start,
            givenUnits: given,
            carbs: carbs,
            carbRatio: carbRatio,
            increment: increment,
            lowThreshold: lowThreshold
        )
    }

    @Test(
        "A low at or below the start and Trio's low line, after no more than a 1 g/U lower ratio's dose, counts"
    ) func counts() {
        #expect(noVerdict() == nil)
        // At the line, and at the start.
        #expect(noVerdict(suspend: 72) == nil)
        #expect(noVerdict(suspend: 65, start: 65) == nil)
        // 40 ÷ 9 = 4.44, rounded up to 0.05 U: 4.45.
        #expect(noVerdict(given: dec("4.45")) == nil)
    }

    @Test("A bolus over a 1 g/U lower ratio's dose gives no verdict, rounded up to the pump's increment") func doseOver() {
        #expect(noVerdict(given: dec("4.46")) == .doseOverDocs)
        // No increment known: 4.44 itself.
        #expect(noVerdict(given: dec("4.44"), increment: 0) == nil)
        #expect(noVerdict(given: dec("4.45"), increment: 0) == .doseOverDocs)
        // A 0.1 U pump: 4.5.
        #expect(noVerdict(given: dec("4.5"), increment: dec("0.1")) == nil)
        #expect(noVerdict(given: dec("4.55"), increment: dec("0.1")) == .doseOverDocs)
    }

    @Test("A suspend still above the start, or above Trio's low line, is Trio's forecast") func forecast() {
        #expect(noVerdict(suspend: 101) == .forecastSuspend)
        // R2-1: under the start, over the line.
        #expect(noVerdict(suspend: 73) == .forecastSuspend)
        #expect(noVerdict(suspend: 90) == .forecastSuspend)
        // Under the line but over the start.
        #expect(noVerdict(suspend: 70, start: 65) == .forecastSuspend)
        // The user's threshold over 72 is the line.
        #expect(noVerdict(suspend: 80, lowThreshold: 80) == nil)
        #expect(noVerdict(suspend: 81, lowThreshold: 80) == .forecastSuspend)
    }

    @Test("Without a reading, the units, the carbs or a carb ratio, the reason is the one missing") func missing() {
        #expect(noVerdict(suspend: nil) == .noReadings)
        #expect(noVerdict(start: nil) == .noReadings)
        #expect(noVerdict(given: nil) == .noAmount)
        #expect(noVerdict(carbs: nil) == .noCarbs)
        #expect(noVerdict(carbRatio: 0) == .noAmount)
    }

    @Test("A carb ratio at or under the step has no lower ratio, so no bolus is too big") func smallCarbRatio() {
        #expect(noVerdict(given: 100, carbRatio: 1) == nil)
    }
}

// MARK: - The carbs logged with the bolus

@Suite("Carb ratio test carbs") struct CarbRatioTestCarbsTests {
    private let settled = at(hour)
    private let bolus = at(hour + 20 * minute)

    private func carbs(_ id: String, _ date: Date, _ grams: Decimal = 40) -> CarbRatioTestCarbs {
        CarbRatioTestCarbs(id: id, date: date, grams: grams)
    }

    @Test("The test's carbs start at the end of settling, exactly") func windowStart() {
        let before = carbs("a", settled.addingTimeInterval(-1))
        let atStart = carbs("b", settled)
        #expect(CarbRatioTestEvaluator.mealCarbs([before], since: settled) == nil)
        #expect(CarbRatioTestEvaluator.mealCarbs([before, atStart], since: settled) == atStart)
    }

    @Test("The first entry from then on is the test's, however late: whether it came in time is the pairing's") func anyTime() {
        let late = carbs("a", bolus.addingTimeInterval(40 * minute))
        #expect(CarbRatioTestEvaluator.mealCarbs([late], since: settled) == late)
        #expect(CarbRatioTestEvaluator.mealPairingEnd(carbsAt: late.date, bolusAt: bolus, now: late.date) != nil)
    }

    @Test("Of two entries, the earlier is the test's") func twoEntries() {
        let later = carbs("later", settled.addingTimeInterval(25 * minute), 10)
        let earlier = carbs("earlier", settled.addingTimeInterval(10 * minute))
        #expect(CarbRatioTestEvaluator.mealCarbs([later, earlier], since: settled) == earlier)
    }

    @Test("The grams logged must be within 1 g of the tablets'") func gramsMatch() {
        #expect(!CarbRatioTestEvaluator.carbsDiffer(logged: 40, planned: 40))
        // 37.5 g of TruePlus, left as the prefill set it, or retyped in Treatments' whole-gram field as 37 or 38.
        #expect(!CarbRatioTestEvaluator.carbsDiffer(logged: dec("37.5"), planned: dec("37.5")))
        #expect(!CarbRatioTestEvaluator.carbsDiffer(logged: 38, planned: dec("37.5")))
        #expect(!CarbRatioTestEvaluator.carbsDiffer(logged: 37, planned: dec("37.5")))
        #expect(!CarbRatioTestEvaluator.carbsDiffer(logged: dec("39.5"), planned: 40))
        // 1 g apart or more: not the tablets'.
        #expect(CarbRatioTestEvaluator.carbsDiffer(logged: 39, planned: 40))
        #expect(CarbRatioTestEvaluator.carbsDiffer(logged: 41, planned: 40))
        #expect(CarbRatioTestEvaluator.carbsDiffer(logged: dec("38.5"), planned: dec("37.5")))
        #expect(CarbRatioTestEvaluator.carbsDiffer(logged: dec("36.5"), planned: dec("37.5")))
        #expect(CarbRatioTestEvaluator.carbsDiffer(logged: 30, planned: 40))
        #expect(
            CarbRatioTestBolusCondition.carbsDiffer(logged: 30, planned: 40).note
                ==
                "The carbs logged (30\u{00A0}g) weren't the tablets' 40\u{00A0}g, so the test can't tell what the bolus covered."
        )
    }

    @Test("Any carbs besides the test's spoil it, by the other tests' rule") func extraCarbs() {
        let test = carbs("test", bolus)
        let other = carbs("other", bolus.addingTimeInterval(30 * minute))
        // There at Begin, dated before it.
        let old = carbs("old", testStart.addingTimeInterval(-2 * hour))
        // Logged during the test with an earlier time.
        let backdated = carbs("backdated", testStart.addingTimeInterval(-hour))
        func spoils(_ entries: [CarbRatioTestCarbs], besides id: String? = "test") -> Bool {
            CarbRatioTestEvaluator.extraCarbs(entries, besides: id, startedAt: testStart, kept: ["old"])
        }
        #expect(!spoils([test]))
        #expect(!spoils([test, old]))
        #expect(spoils([test, other]))
        #expect(spoils([test, backdated]))
        // Until it is known as the test's, the test's own entry counts.
        #expect(spoils([test], besides: nil))
    }
}

// MARK: - The bolus

@Suite("Carb ratio test bolus conditions") struct CarbRatioTestBolusConditionTests {
    private let bolus = at(2 * hour)

    private func failed(
        start: Int? = 100,
        carbRatio: Decimal = 10,
        arrow: ISFTestArrowReading?? = nil,
        determinations: [ISFTestDetermination]?? = nil,
        testCarbsAt: Date? = nil,
        handling: ISFTestIOBHandling? = nil
    ) -> CarbRatioTestBolusCondition? {
        CarbRatioTestEvaluator.failedBolusCondition(
            bolusAt: bolus,
            startGlucose: start,
            carbs: 40,
            carbRatio: carbRatio,
            arrow: arrow ?? ISFTestArrowReading(date: bolus.addingTimeInterval(-2 * minute), direction: .flat),
            determinations: determinations ?? [ISFTestDetermination(
                date: bolus.addingTimeInterval(-4 * minute),
                iob: dec("0.2"),
                cob: 0
            )],
            testCarbsAt: testCarbsAt,
            handling: handling
        )
    }

    private func determination(_ minutesBefore: Double, iob: Decimal? = 0, cob: Decimal?) -> ISFTestDetermination {
        ISFTestDetermination(date: bolus.addingTimeInterval(-minutesBefore * minute), iob: iob, cob: cob)
    }

    @Test("A flat arrow, carbs and insulin on board under their lines: the bolus is judged") func allHeld() {
        #expect(failed() == nil)
        // A CGM without arrows doesn't hold it up.
        #expect(failed(arrow: ISFTestArrowReading(date: bolus.addingTimeInterval(-2 * minute), direction: nil)) == nil)
    }

    @Test("A start glucose, arrow or determination that couldn't be read is unread") func unread() {
        #expect(failed(start: nil) == .unread)
        #expect(failed(arrow: .some(nil)) == .unread)
        // An arrow after the bolus, or 13 minutes before it.
        #expect(failed(arrow: ISFTestArrowReading(date: bolus.addingTimeInterval(2 * minute), direction: .flat)) == .unread)
        #expect(failed(arrow: ISFTestArrowReading(date: bolus.addingTimeInterval(-13 * minute), direction: .flat)) == .unread)
        #expect(failed(determinations: .some(nil)) == .unread)
        // Carbs on board only from 13 minutes before.
        #expect(failed(determinations: [determination(13, cob: 0)]) == .unread)
        // Carbs on board read, insulin on board not.
        #expect(failed(determinations: [determination(4, iob: nil, cob: 0)]) == .unread)
        #expect(CarbRatioTestBolusCondition.unread.note == CarbRatioTestEvaluator.historyUnreadNote)
    }

    @Test("A moving arrow spoils it") func moving() {
        #expect(
            failed(arrow: ISFTestArrowReading(date: bolus.addingTimeInterval(-2 * minute), direction: .singleUp)) ==
                .glucoseMoving
        )
        #expect(CarbRatioTestBolusCondition.glucoseMoving.note == ISFTestBolusCondition.glucoseMoving.note)
    }

    @Test("Carbs on board at or over the line before the meal spoil it") func carbsOnBoard() {
        // The line for 40 g at 10 g/U is 3.6 g.
        #expect(failed(determinations: [determination(4, cob: dec("3.6"))]) == .carbsOnBoard)
        #expect(failed(determinations: [determination(4, cob: dec("3.5"))]) == nil)
        // At 20 g/U in force at the bolus, the line is 40 ÷ 21 = 1.9 g.
        #expect(failed(carbRatio: 20, determinations: [determination(4, iob: 0, cob: 2)]) == .carbsOnBoard)
    }

    @Test("Carbs logged before the bolus are read from before them, so the tablets aren't counted") func carbsFirst() {
        // Logged 6 minutes before the bolus; a determination 4 minutes before already counts the 40 g. The arrow is read
        // at the carbs, the meal's moment.
        let reads = [determination(8, cob: 0), determination(4, cob: 40)]
        let arrowAt = { (minutesBefore: Double) in
            ISFTestArrowReading(date: self.bolus.addingTimeInterval(-minutesBefore * minute), direction: .flat)
        }
        #expect(failed(arrow: arrowAt(7), determinations: reads, testCarbsAt: bolus.addingTimeInterval(-6 * minute)) == nil)
        // Without them logged first, the determination before the bolus is read.
        #expect(failed(determinations: reads) == .carbsOnBoard)
        // One made at the carbs' own moment may count them, so it isn't read.
        let atCarbs = [determination(9, cob: 0), determination(4, cob: 40)]
        #expect(failed(arrow: arrowAt(5), determinations: atCarbs, testCarbsAt: bolus.addingTimeInterval(-4 * minute)) == nil)
        // Logged after the bolus, the bolus is the meal's moment.
        #expect(
            failed(determinations: [determination(4, cob: 0)], testCarbsAt: bolus.addingTimeInterval(5 * minute)) ==
                nil
        )
    }

    @Test("Insulin on board over the dose's line spoils a test that waits for it; one that counts it has no line") func iob() {
        // The line for 4 U at 10 g/U is 0.36 U.
        #expect(failed(determinations: [determination(4, iob: dec("0.37"), cob: 0)]) == .iobOverLine)
        #expect(failed(determinations: [determination(4, iob: dec("0.36"), cob: 0)]) == nil)
        #expect(failed(determinations: [determination(4, iob: 2, cob: 0)], handling: .count) == nil)
        // At 20 g/U in force at the bolus: 2 U, and a line of 2 ÷ 21 = 0.10 U.
        #expect(failed(carbRatio: 20, determinations: [determination(4, iob: dec("0.2"), cob: 0)]) == .iobOverLine)
        #expect(CarbRatioTestBolusCondition.iobOverLine.note == ISFTestBolusCondition.iobOverLine.note)
    }
}

// MARK: - The Dose step

@Suite("Carb ratio test dose step") struct CarbRatioTestDoseStepTests {
    private let now = at(90 * minute)

    /// 3 level readings, the newest a minute old, with 0.2 U and no carbs on board.
    private var inputs: CarbRatioTestDoseInputs {
        CarbRatioTestDoseInputs(
            readings: [1, 6, 11].map { BasalTestReading(date: now.addingTimeInterval(-$0 * minute), glucose: 100) },
            direction: .flat,
            iob: dec("0.2"),
            doseIOB: dec("0.2"),
            cob: 0,
            increment: dec("0.05"),
            now: now
        )
    }

    private func with(_ change: (inout CarbRatioTestDoseInputs) -> Void) -> CarbRatioTestDoseInputs {
        var copy = inputs
        change(&copy)
        return copy
    }

    @Test("With everything under its line, the step offers the formula's dose") func offers() {
        let test = makeTest()
        #expect(CarbRatioTestEvaluator.noDoseReason(of: test, inputs) == nil)
        #expect(CarbRatioTestEvaluator.canDose(of: test, inputs))
        // 40 ÷ 10.
        #expect(CarbRatioTestEvaluator.doseShown(of: test, inputs) == 4)
        // Not while settling, nor once the bolus is in.
        #expect(!CarbRatioTestEvaluator.canDose(of: makeTest(phase: .settling), inputs))
        #expect(!CarbRatioTestEvaluator.canDose(of: makeTest(phase: .waiting), inputs))
    }

    @Test("Carbs on board unread, or at or over the line, hold it") func carbs() {
        let test = makeTest()
        #expect(CarbRatioTestEvaluator.noDoseReason(of: test, with { $0.cob = nil }) == .carbsUnread)
        // The line is 3.6 g.
        #expect(CarbRatioTestEvaluator.noDoseReason(of: test, with { $0.cob = dec("3.6") }) == .carbsOnBoard)
        #expect(CarbRatioTestEvaluator.noDoseReason(of: test, with { $0.cob = dec("3.5") }) == nil)
        // The dose still shows.
        #expect(CarbRatioTestEvaluator.doseShown(of: test, with { $0.cob = dec("3.6") }) == 4)
        #expect(!CarbRatioTestEvaluator.canDose(of: test, with { $0.cob = dec("3.6") }))
    }

    @Test("No 3 recent readings, or a moving arrow, hold it") func glucose() {
        let test = makeTest()
        // The newest 13 minutes old.
        let stale = with { inputs in
            inputs.readings = [13, 18, 23].map { BasalTestReading(date: now.addingTimeInterval(-$0 * minute), glucose: 100) }
        }
        #expect(CarbRatioTestEvaluator.noDoseReason(of: test, stale) == .noRecentReading)
        #expect(CarbRatioTestEvaluator.noDoseReason(of: test, with { $0.direction = .singleUp }) == .notLevel)
        // No arrow for a recent reading is level.
        #expect(CarbRatioTestEvaluator.noDoseReason(of: test, with { $0.direction = nil }) == nil)
    }

    @Test("Waiting for insulin on board: unread or over the dose's line holds it") func waitsForIOB() {
        let test = makeTest()
        #expect(CarbRatioTestEvaluator.noDoseReason(of: test, with { $0.iob = nil }) == .iobUnread)
        // The line is 0.36 U, by size either way.
        #expect(CarbRatioTestEvaluator.noDoseReason(of: test, with { $0.iob = dec("0.37") }) == .iobOverLine)
        #expect(CarbRatioTestEvaluator.noDoseReason(of: test, with { $0.iob = dec("-0.37") }) == .iobOverLine)
        #expect(
            CarbRatioTestEvaluator.noDoseReason(of: makeTest(handling: .wait), with { $0.iob = dec("0.37") }) ==
                .iobOverLine
        )
    }

    @Test("Counting insulin on board: the dose less it, once read, while some is left") func countsIOB() {
        let test = makeTest(handling: .count)
        // 4 − 0.5 = 3.5, and no line: 0.9 U now doesn't hold it.
        let counted = with { inputs in
            inputs.doseIOB = dec("0.5")
            inputs.iob = dec("0.9")
        }
        #expect(CarbRatioTestEvaluator.doseShown(of: test, counted) == dec("3.5"))
        #expect(CarbRatioTestEvaluator.canDose(of: test, counted))
        #expect(CarbRatioTestEvaluator.noDoseReason(of: test, with { $0.doseIOB = nil }) == .iobUnread)
        #expect(CarbRatioTestEvaluator.doseShown(of: test, with { $0.doseIOB = nil }) == nil)
        #expect(CarbRatioTestEvaluator.noDoseReason(of: test, with { $0.doseIOB = 4 }) == .iobCoversDose)
    }

    @Test("No carb ratio, ISF or carbs is a dead end; every other reason waits") func settings() {
        #expect(CarbRatioTestEvaluator.noDoseReason(of: makeTest(carbRatio: 0), inputs) == .noSettings)
        #expect(CarbRatioTestEvaluator.noDoseReason(of: makeTest(isf: 0), inputs) == .noSettings)
        #expect(CarbRatioTestEvaluator.noDoseReason(of: makeTest(tabletCarbs: 0), inputs) == .noSettings)
        let waits: [CarbRatioTestNoDose] = [
            .carbsOnBoard, .carbsUnread, .noRecentReading, .notLevel, .iobOverLine, .iobUnread, .iobCoversDose
        ]
        #expect(waits.allSatisfy { $0.isWaiting })
        #expect(!CarbRatioTestNoDose.noSettings.isWaiting)
    }

    @Test("The dose and its lines use the carb ratio in force now") func scheduleNow() throws {
        let calendar = Calendar.current
        let onePM = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 13)))
        var test = makeTest()
        test.crEntries = [entry(0, 720, 10), entry(720, 1440, 20)]
        let afternoon = with { inputs in
            inputs.now = onePM
            inputs.readings = [1, 6, 11].map { BasalTestReading(date: onePM.addingTimeInterval(-$0 * minute), glucose: 100) }
        }
        // 40 ÷ 20 = 2, with a line of 2 ÷ 21 = 0.10 U, which 0.2 U is over.
        #expect(CarbRatioTestEvaluator.doseShown(of: test, afternoon) == 2)
        #expect(CarbRatioTestEvaluator.noDoseReason(of: test, afternoon) == .iobOverLine)
    }

    @Test("The inputs read as the ISF test's for the rules both share") func isfInputs() {
        let shared = inputs.isfInputs
        #expect(shared.readings == inputs.readings)
        #expect(shared.direction == inputs.direction)
        #expect(shared.iob == inputs.iob)
        #expect(shared.doseIOB == inputs.doseIOB)
        #expect(shared.cob == inputs.cob)
        #expect(shared.increment == inputs.increment)
        #expect(shared.now == inputs.now)
    }
}

// MARK: - The state

@Suite("Carb ratio test state") struct CarbRatioTestStateTests {
    @Test("The state survives the state file") func roundTrip() throws {
        var test = makeTest(phase: .waiting, length: 3 * hour, handling: .count)
        test.sessionID = UUID()
        test.crEntries = [entry(0, 360, 10)]
        test.isfEntries = [entry(0, 360, 50)]
        test.carbsAtBegin = ["a"]
        test.bolusAt = at(hour + 20 * minute)
        test.bolusUnits = dec("3.65")
        test.iobAtBolus = dec("0.35")
        test.startGlucose = 104
        test.carbs = dec("38.5")
        test.carbsAt = at(hour + 21 * minute)
        test.carbsID = "carbs"
        test.readings = [BasalTestReading(date: at(2 * hour), glucose: 110, direction: .flat)]
        test.pendingEnd = CarbRatioTestPendingEnd(reason: .completed, at: at(5 * hour), note: nil, byUser: false)
        test.doseNoticeDue = true
        test.timeUpNoticePosted = true
        test.doseOfferedAt = at(hour + 15 * minute)
        test.doseOfferEndedAt = at(hour + 20 * minute)
        let decoded = try JSONCoding.decoder.decode(CarbRatioTestState.self, from: JSONCoding.encoder.encode(test))
        #expect(decoded == test)
        // An unrounded dose with many digits, 40 ÷ 15 = 2.6666…, comes back the same too.
        let thirds = makeTest(carbRatio: 15)
        let reloaded = try JSONCoding.decoder.decode(CarbRatioTestState.self, from: JSONCoding.encoder.encode(thirds))
        #expect(reloaded.expectedDose == thirds.expectedDose)
    }

    @Test(
        "Deadlines: the dose 90 minutes after settling, the end after the chosen length, the carbs 15 minutes after"
    ) func deadlines() {
        let settling = makeTest(phase: .settling, length: 3 * hour)
        #expect(settling.bolusWindowStart == nil)
        // Settling's hour and the dose's 90 minutes.
        #expect(settling.noBolusDeadline == at(150 * minute))
        #expect(settling.plannedEnd == nil)
        #expect(settling.carbsDeadline == nil)

        var waiting = makeTest(phase: .waiting, length: 3 * hour)
        waiting.bolusAt = at(hour + 20 * minute)
        // Settled an hour after Begin.
        #expect(waiting.bolusWindowStart == at(hour))
        #expect(waiting.doseDeadline == at(hour + 90 * minute))
        #expect(waiting.noBolusDeadline == waiting.doseDeadline)
        // 1:20 plus 3 hours.
        #expect(waiting.plannedEnd == at(4 * hour + 20 * minute))
        #expect(waiting.carbsDeadline == at(hour + 35 * minute))
        #expect(waiting.brand == .dex4)
    }

    @Test("Begin saves the schedule entries the chosen length can reach") func coveredAtBegin() throws {
        let entries = [entry(0, 360, 10), entry(360, 720, 12), entry(720, 1440, 15)]
        let five = try #require(utc.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 5)))
        // 5:00 plus settling's hour, two 90-minute windows and 3 hours is 12:00: the first two entries.
        #expect(
            CarbRatioTestEvaluator.coveredAtBegin(entries, startedAt: five, length: 3 * hour, calendar: utc)
                == Array(entries.prefix(2))
        )
        // With 4 hours, 13:00: all three.
        #expect(CarbRatioTestEvaluator.coveredAtBegin(entries, startedAt: five, length: 4 * hour, calendar: utc) == entries)
    }

    @Test("At the bolus the carb ratio and ISF become those in force then, and the schedules narrow to them") func atBolus() throws {
        var test = makeTest()
        test.crEntries = [entry(0, 720, 10), entry(720, 1440, 20)]
        test.isfEntries = [entry(0, 720, 50), entry(720, 1440, 40)]
        let onePM = try #require(utc.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 13)))
        let moved = CarbRatioTestEvaluator.atBolus(test, bolusAt: onePM, calendar: utc)
        #expect(moved.carbRatio == 20)
        #expect(moved.isf == 40)
        #expect(moved.crEntries == [entry(720, 1440, 20)])
        #expect(moved.isfEntries == [entry(720, 1440, 40)])
        // Without schedules, the values saved at Begin.
        let plain = CarbRatioTestEvaluator.doseSettings(of: makeTest(), at: onePM, calendar: utc)
        #expect(plain.carbRatio == 10)
        #expect(plain.isf == 50)
    }

    @Test("The record keeps the carbs the bolus covered; one saved before it was kept reads nil") func recordCarbs() throws {
        var record = SettingsTestRecord(
            kind: .carbRatio,
            startedAt: testStart,
            completedAt: at(4 * hour),
            startGlucose: 100,
            endGlucose: 110,
            direction: .keep,
            summary: "x"
        )
        #expect(record.testCarbs == nil)
        record.testCarbs = dec("38.5")
        let decoded = try JSONCoding.decoder.decode(SettingsTestRecord.self, from: JSONCoding.encoder.encode(record))
        #expect(decoded.testCarbs == dec("38.5"))
        var old = try #require(
            JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(record)) as? [String: Any]
        )
        old.removeValue(forKey: "testCarbs")
        let legacy = try JSONCoding.decoder.decode(SettingsTestRecord.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(legacy.testCarbs == nil)
    }
}

// MARK: - The finished test

@Suite("Carb ratio test finished result") struct CarbRatioTestResultTests {
    @Test("The units judged are the bolus and insulin on board at it, less what was left at the end") func units() {
        let test = finishedTest()
        // 4 + 0.3.
        #expect(CarbRatioTestEvaluator.givenUnits(of: test) == dec("4.3"))
        // 4.3 − 0.3.
        #expect(CarbRatioTestEvaluator.judgedUnits(of: test) == 4)
        #expect(CarbRatioTestEvaluator.judgedUnits(of: finishedTest(iobAtEnd: nil)) == nil)
        #expect(CarbRatioTestEvaluator.givenUnits(of: finishedTest(iobAtBolus: nil)) == nil)
    }

    @Test("A finished test's result is worked out again from what it saved") func evaluation() throws {
        let test = finishedTest()
        // 40 ÷ (4 + 10 ÷ 50) = 9.52, 0.48 under: accurate.
        let evaluation = try #require(CarbRatioTestEvaluator.evaluation(of: test))
        #expect(evaluation.outcome == .accurate)
        #expect(CarbRatioTestEvaluator.matchingEvaluation(of: test) == evaluation)
        #expect(CarbRatioTestEvaluator.noVerdict(for: test) == nil)
        // The worked example's band.
        #expect(CarbRatioTestEvaluator.resultBand(of: test) == CarbRatioTestBand(lowest: 82, highest: 122))
        // A saved verdict the working doesn't give shows neither.
        var other = test
        other.outcome = .tooLow
        #expect(CarbRatioTestEvaluator.matchingEvaluation(of: other) == nil)
        #expect(CarbRatioTestEvaluator.resultBand(of: other) == nil)
        var running = test
        running.endedAt = nil
        #expect(CarbRatioTestEvaluator.evaluation(of: running) == nil)
        #expect(CarbRatioTestEvaluator.noVerdict(for: running) == nil)
    }

    @Test("The record's words, the headline and the docs line") func words() {
        #expect(
            CarbRatioTestEvaluator
                .summary(for: .accurate, reason: .completed) == "Glucose ended about where your carb ratio says"
        )
        #expect(
            CarbRatioTestEvaluator
                .summary(for: .tooHigh, reason: .completed) == "Glucose ended higher than your carb ratio says"
        )
        #expect(
            CarbRatioTestEvaluator
                .summary(for: .tooLow, reason: .completed) == "Glucose ended lower than your carb ratio says"
        )
        #expect(CarbRatioTestEvaluator.summary(for: .tooLow, reason: .low) == "Trio suspended insulin for a low")
        #expect(CarbRatioTestEvaluator.headline(for: .tooHigh, noVerdict: nil) == "Carb ratio looks too high")
        #expect(CarbRatioTestEvaluator.headline(for: .inconclusive, noVerdict: .tooSoon) == "Too soon to tell")
        #expect(CarbRatioTestEvaluator.headline(for: .inconclusive, noVerdict: .carbsTooFew) == "Can't tell from this test")
        #expect(CarbRatioTestEvaluator.docsLine(for: .accurate, noVerdict: nil) == CarbRatioTest.Docs.returnToStart)
        #expect(CarbRatioTestEvaluator.docsLine(for: .tooHigh, noVerdict: nil) == CarbRatioTest.Docs.endUpHigh)
        #expect(CarbRatioTestEvaluator.docsLine(for: .tooLow, noVerdict: nil) == CarbRatioTest.Docs.endUpLow)
        #expect(CarbRatioTestEvaluator.docsLine(for: .inconclusive, noVerdict: .tooSoon) == CarbRatioTest.Docs.monitor)
        #expect(CarbRatioTestEvaluator.docsLine(for: .invalid, noVerdict: .interrupted) == nil)
    }

    @Test("No bolus, an interruption, and an unread record each say why") func interrupted() {
        let noBolus = finishedTest(reason: .noBolus)
        #expect(CarbRatioTestEvaluator.noVerdict(for: noBolus) == .noBolus)
        #expect(
            CarbRatioTestEvaluator.noVerdictText(.noBolus, test: noBolus)
                ==
                "The test needs your bolus within 90 minutes after settling. Trio didn't see one, so there was nothing to judge."
        )
        var spoiled = finishedTest(reason: .interrupted)
        spoiled.interference = CarbRatioTestEvaluator.noCarbsNote
        #expect(CarbRatioTestEvaluator.noVerdict(for: spoiled) == .interrupted)
        #expect(CarbRatioTestEvaluator.noVerdictText(.interrupted, test: spoiled) == CarbRatioTestEvaluator.noCarbsNote)
        var unread = finishedTest()
        unread.interferenceUnread = true
        #expect(CarbRatioTestEvaluator.noVerdict(for: unread) == .historyUnread)
        #expect(CarbRatioTestEvaluator.noVerdict(for: finishedTest(iobAtBolus: nil)) == .historyUnread)
        #expect(CarbRatioTestEvaluator.noVerdict(for: finishedTest(iobAtEnd: nil)) == .historyUnread)
        #expect(CarbRatioTestEvaluator.evaluation(of: finishedTest(iobAtEnd: nil))?.outcome == .inconclusive)
    }

    @Test("Ending early, short of the length, or unchecked say so") func tooSoon() {
        let early = finishedTest(reason: .endedEarly, ranFor: 2 * hour + 10 * minute)
        #expect(CarbRatioTestEvaluator.noVerdict(for: early) == .tooSoon)
        #expect(
            CarbRatioTestEvaluator.noVerdictText(.tooSoon, test: early)
                == "This test ended after 2 h 10 m, so it's too soon to tell what your carb ratio did."
        )
        #expect(CarbRatioTestEvaluator.noVerdict(for: finishedTest(ranFor: 3 * hour)) == .tooSoon)
        #expect(CarbRatioTestEvaluator.noVerdict(for: finishedTest(reason: .unchecked)) == .lowUnchecked)
        #expect(CarbRatioTestEvaluator.elapsedText(for: finishedTest()) == "4 h")
    }

    @Test("Missing readings, carbs or units, or too few carbs, say so") func missing() {
        let noEnd = finishedTest(end: nil)
        #expect(CarbRatioTestEvaluator.noVerdict(for: noEnd) == .noReadings)
        #expect(
            CarbRatioTestEvaluator.noVerdictText(.noReadings, test: noEnd)
                == "No CGM readings were recorded at the bolus or at the end of the test, so there is nothing to compare."
        )
        let noCarbs = finishedTest(carbs: nil)
        #expect(CarbRatioTestEvaluator.noVerdict(for: noCarbs) == .noCarbs)
        #expect(CarbRatioTestEvaluator.noVerdictText(.noCarbs, test: noCarbs) == CarbRatioTestEvaluator.noCarbsNote)
        // 0.2 U + 0 on board − 0.3 U left = −0.1 U judged.
        #expect(CarbRatioTestEvaluator.noVerdict(for: finishedTest(bolus: dec("0.2"), iobAtBolus: 0)) == .noAmount)
        // The empty band: 4 g at 30 g/U with 0.12 U and an ISF of 20.
        var few = finishedTest(end: 100, bolus: dec("0.12"), iobAtBolus: 0, iobAtEnd: 0, carbs: 4)
        few.tabletCarbs = 4
        few.carbRatio = 30
        few.isf = 20
        #expect(CarbRatioTestEvaluator.noVerdict(for: few) == .carbsTooFew)
        #expect(CarbRatioTestEvaluator.evaluation(of: few)?.outcome == .inconclusive)
    }

    @Test("A low says it is too low, or why it can't, with no band") func low() {
        // At 70, at or under Trio's 72 mg/dL low line, after 4.3 U, no more than 4.45.
        let low = finishedTest(reason: .low, ranFor: 2 * hour, end: 70)
        #expect(CarbRatioTestEvaluator.noVerdict(for: low) == nil)
        #expect(low.outcome == .tooLow)
        #expect(CarbRatioTestEvaluator.resultBand(of: low) == nil)
        #expect(CarbRatioTestEvaluator.noVerdict(for: finishedTest(reason: .low, end: 105)) == .forecastSuspend)
        // R2-1: at 80, under the start but over the line Begin saved, Trio's forecast; under a higher line saved, a low.
        #expect(CarbRatioTestEvaluator.noVerdict(for: finishedTest(reason: .low, end: 80)) == .forecastSuspend)
        var higherLine = finishedTest(reason: .low, ranFor: 2 * hour, end: 80)
        higherLine.lowThreshold = 85
        #expect(CarbRatioTestEvaluator.noVerdict(for: higherLine) == nil)
        #expect(CarbRatioTestEvaluator.evaluation(of: higherLine)?.outcome == .tooLow)
        // 4.4 + 0.3 = 4.7 U, over 4.45.
        #expect(CarbRatioTestEvaluator.noVerdict(for: finishedTest(reason: .low, end: 70, bolus: dec("4.4"))) == .doseOverDocs)
        #expect(CarbRatioTestEvaluator.noVerdict(for: finishedTest(reason: .low, end: 70, iobAtBolus: nil)) == .historyUnread)
        #expect(CarbRatioTestEvaluator.noVerdict(for: finishedTest(reason: .low, end: 70, carbs: nil)) == .noCarbs)
    }

    @Test("The end glucose is from the bolus on; a low's only from readings after the later half of the meal") func endGlucose() {
        let bolus = at(hour)
        let readings = [-10.0, -5, 0, 5, 10, 15]
            .map { BasalTestReading(date: bolus.addingTimeInterval($0 * minute), glucose: 100 + Int($0)) }
        func end(_ minutes: Double, carbsAt: Date? = nil, _ reason: CarbRatioTestEndReason) -> Int? {
            CarbRatioTestEvaluator.endGlucose(
                readings,
                bolusAt: bolus,
                carbsAt: carbsAt,
                end: bolus.addingTimeInterval(minutes * minute),
                reason: reason
            )
        }
        // At 2 minutes after the bolus only the reading at it is from it on, so there is no mean of 3.
        #expect(end(2, .completed) == nil)
        // A low 2 minutes after the bolus has no reading after the meal: none, not the start glucose's own readings.
        #expect(end(2, .low) == nil)
        // A low at 16 minutes: the 3 readings after the bolus, 105, 110 and 115, average 110; not the one at it.
        #expect(end(16, .low) == 110)
        // R2-1: carbs logged 6 minutes before the bolus leave the bolus the later half, so only 105 and 110 are after
        // it at 11 minutes: no mean of 3, where readings from the carbs on gave 105.
        #expect(end(11, carbsAt: bolus.addingTimeInterval(-6 * minute), .low) == nil)
        #expect(end(16, carbsAt: bolus.addingTimeInterval(-6 * minute), .low) == 110)
        // Carbs logged 6 minutes after the bolus are the later half: only 110 and 115 are after them at 16 minutes.
        #expect(end(16, carbsAt: bolus.addingTimeInterval(6 * minute), .low) == nil)
        #expect(end(16, carbsAt: bolus.addingTimeInterval(4 * minute), .low) == 110)
        #expect(CarbRatioTestEvaluator.endGlucose(readings, bolusAt: nil, carbsAt: nil, end: bolus, reason: .low) == nil)
    }

    @Test("A low counts the carbs only when they were logged by Trio's suspend") func lowCarbs() {
        let suspend = at(2 * hour)
        #expect(CarbRatioTestEvaluator.judgedCarbs(40, planned: 40, carbsAt: suspend, reason: .low, end: suspend) == 40)
        #expect(
            CarbRatioTestEvaluator.judgedCarbs(
                40,
                planned: 40,
                carbsAt: suspend.addingTimeInterval(minute),
                reason: .low,
                end: suspend
            )
                == nil
        )
        #expect(CarbRatioTestEvaluator.judgedCarbs(40, planned: 40, carbsAt: nil, reason: .low, end: suspend) == nil)
        // Any other ending judges the carbs logged.
        #expect(
            CarbRatioTestEvaluator.judgedCarbs(
                40,
                planned: 40,
                carbsAt: suspend.addingTimeInterval(minute),
                reason: .completed,
                end: suspend
            ) == 40
        )
        // So a low before them gives no verdict, and says why.
        var early = finishedTest(reason: .low, ranFor: 5 * minute, end: 70)
        early.carbsAt = early.endedAt?.addingTimeInterval(2 * minute)
        #expect(CarbRatioTestEvaluator.noVerdict(for: early) == .noCarbs)
        #expect(CarbRatioTestEvaluator.noVerdictText(.noCarbs, test: early) == CarbRatioTestEvaluator.lowBeforeCarbsNote)
        #expect(CarbRatioTestEvaluator.evaluation(of: early)?.outcome == .inconclusive)
    }

    @Test("Grams logged within a gram of the tablets' are judged as the tablets' planned grams") func judgedOnPlanned() {
        // R2-3: 1 TruePlus tablet (3.75 g) logged as 3 g, which the 1 g rule lets through. CR 10 and ISF 50 right:
        // 0.35 U given, 0.049 U left at 4 hours, so 0.301 U acted; glucose 100 to 104.
        #expect(!CarbRatioTestEvaluator.carbsDiffer(logged: 3, planned: dec("3.75")))
        #expect(
            CarbRatioTestEvaluator.judgedCarbs(3, planned: dec("3.75"), carbsAt: at(hour), reason: .completed, end: at(5 * hour))
                == dec("3.75")
        )
        var test = makeTest(phase: .finished, tabletCarbs: dec("3.75"))
        test.bolusAt = at(hour + 10 * minute)
        test.bolusUnits = dec("0.35")
        test.iobAtBolus = 0
        test.iobAtEnd = dec("0.049")
        test.startGlucose = 100
        test.endGlucose = 104
        test.carbs = 3
        test.carbsAt = test.bolusAt
        test.endedAt = test.bolusAt?.addingTimeInterval(4 * hour)
        test.endReason = .completed
        // On the 3 g logged: 3 ÷ 0.381 = 7.9 g/U, "too high". On the 3.75 g eaten: 9.8 g/U, accurate.
        #expect(CarbRatioTestEvaluator.judgedCarbs(of: test) == dec("3.75"))
        #expect(CarbRatioTestEvaluator.evaluation(of: test)?.outcome == .accurate)
        // The chart's band too.
        test.outcome = .accurate
        let band = CarbRatioTestEvaluator.accurateEnds(
            startGlucose: 100,
            carbs: dec("3.75"),
            units: dec("0.301"),
            carbRatio: 10,
            isf: 50
        )
        #expect(band != nil)
        #expect(CarbRatioTestEvaluator.resultBand(of: test) == band)
    }
}

@Suite("Carb ratio test endings") struct CarbRatioTestEndingTests {
    private let deadline = at(150 * minute)

    @Test("The ISF test's running check ends this test, with its own words for other carbs") func ending() {
        let carbs = CarbRatioTestEvaluator.ending(for: .carbsLogged(at: at(hour)), doseDeadline: deadline)
        #expect(
            carbs == CarbRatioTestEvaluator
                .Ending(reason: .interrupted, at: at(hour), note: CarbRatioTestEvaluator.otherCarbsNote)
        )
        #expect(CarbRatioTestEvaluator.ending(for: .low(at: at(hour)), doseDeadline: deadline).reason == .low)
        #expect(
            CarbRatioTestEvaluator.ending(for: .noBolus, doseDeadline: deadline)
                == CarbRatioTestEvaluator.Ending(reason: .noBolus, at: deadline, note: nil)
        )
        #expect(CarbRatioTestEvaluator.ending(for: .completedUnchecked, doseDeadline: deadline).reason == .unchecked)
        let extra = CarbRatioTestEvaluator.ending(for: .extraBolus(at: at(hour)), doseDeadline: deadline)
        #expect(
            extra == CarbRatioTestEvaluator
                .Ending(ISFTestEvaluator.ending(for: .extraBolus(at: at(hour)), doseDeadline: deadline))
        )
    }

    @Test("End Test once the chosen length is up completes the test") func finishing() {
        let bolus = at(hour)
        func finish(after elapsed: TimeInterval, _ suspend: BasalTestEvaluator.SuspendReading) -> CarbRatioTestEvaluator.Ending {
            CarbRatioTestEvaluator.finishing(
                reason: .endedEarly,
                at: bolus.addingTimeInterval(elapsed),
                suspend: suspend,
                bolusAt: bolus,
                length: 3 * hour,
                doseDeadline: deadline
            )
        }
        // 3 hours of a 3-hour test: completed, or unchecked without a readable history.
        #expect(finish(after: 3 * hour, .none).reason == .completed)
        #expect(finish(after: 3.5 * hour, .unreadable).reason == .unchecked)
        // 2 hours: still ended early.
        #expect(finish(after: 2 * hour, .none).reason == .endedEarly)
        // A suspend an hour after the bolus that a check hadn't seen: a low.
        let low = finish(after: 2 * hour, .suspended(at: bolus.addingTimeInterval(hour)))
        #expect(low.reason == .low)
        #expect(low.at == bolus.addingTimeInterval(hour))
        #expect(CarbRatioTestEvaluator.rereadsHistory(.completed))
        #expect(!CarbRatioTestEvaluator.rereadsHistory(.low))
    }

    @Test("A note about unread carbs, with the usual mode not back, says this test couldn't be checked") func modeWorded() {
        #expect(
            CarbRatioTestEvaluator.modeWorded(ISFTestEvaluator.carbsUnreadableNote, modeBack: false)
                == CarbRatioTestEvaluator.historyUnreadNote
        )
        #expect(
            CarbRatioTestEvaluator.modeWorded(ISFTestEvaluator.carbsUnreadableNote, modeBack: true)
                == ISFTestEvaluator.carbsUnreadableNote
        )
        #expect(CarbRatioTestEvaluator.modeWorded(nil, modeBack: false) == nil)
    }
}

// MARK: - The runner's rules

@Suite("Carb ratio test runner rules") struct CarbRatioTestRunnerRuleTests {
    /// The worked example waiting out `length` from its bolus 10 minutes after settling, in its own session.
    private func waiting(length: TimeInterval = 3 * hour) -> CarbRatioTestState {
        var test = makeTest(phase: .waiting, length: length)
        test.sessionID = UUID()
        test.bolusAt = at(hour + 10 * minute)
        return test
    }

    private func check(
        _ test: CarbRatioTestState,
        at now: Date,
        suspend: BasalTestEvaluator.SuspendReading = .none,
        serviceEnd: SettingsTestEnd? = nil,
        mode: DosingMode = .basalTesting
    ) -> ISFTestEvaluator.RunningCheck? {
        CarbRatioTestEvaluator.runningCheck(of: test, serviceEnd: serviceEnd, suspend: suspend, now: now, mode: mode)
    }

    @Test("A waiting test completes at the end of its chosen length, not the ISF test's 4 hours") func plannedEnd() {
        let test = waiting(length: 3 * hour)
        let bolus = at(hour + 10 * minute)
        #expect(check(test, at: bolus.addingTimeInterval(3 * hour - minute)) == nil)
        #expect(check(test, at: bolus.addingTimeInterval(3 * hour)) == .completed)
        // With the pump history unread at the end, a low can't be ruled out.
        #expect(check(test, at: bolus.addingTimeInterval(3 * hour), suspend: .unreadable) == .completedUnchecked)
        // The 4-hour test still runs then.
        #expect(check(waiting(length: 4 * hour), at: bolus.addingTimeInterval(3 * hour)) == nil)
    }

    @Test("Trio's suspend for a low is a low before the dose until the bolus is in, and a low after it") func lows() {
        let test = waiting()
        let bolus = at(hour + 10 * minute)
        #expect(
            check(test, at: bolus.addingTimeInterval(hour), suspend: .suspended(at: bolus.addingTimeInterval(-minute)))
                == .lowBeforeDose(at: bolus.addingTimeInterval(-minute))
        )
        #expect(
            check(test, at: bolus.addingTimeInterval(hour), suspend: .suspended(at: bolus.addingTimeInterval(minute)))
                == .low(at: bolus.addingTimeInterval(minute))
        )
        let dosing = makeTest()
        #expect(
            check(dosing, at: at(hour + 5 * minute), suspend: .suspended(at: at(hour + 2 * minute)))
                == .lowBeforeDose(at: at(hour + 2 * minute))
        )
    }

    @Test("Before the bolus, the time for it running out and a mode change end the test") func beforeTheBolus() {
        let dosing = makeTest()
        // Settled at 1 h, so the bolus must come by 2 h 30 min.
        #expect(check(dosing, at: at(2.5 * hour)) == .noBolus)
        #expect(check(dosing, at: at(2.5 * hour - minute)) == nil)
        #expect(check(dosing, at: at(hour + minute), mode: .closed) == .modeChanged)
        // Still settling at Begin plus the hour for it and the 90 minutes for the dose.
        let settling = makeTest(phase: .settling)
        #expect(check(settling, at: at(hour + 90 * minute)) == .settlingTimedOut)
        #expect(check(settling, at: at(hour + 89 * minute)) == nil)
    }

    @Test("The service's record of ending this test's session comes first; another session's says nothing") func serviceEnd() {
        let test = waiting()
        let later = at(2 * hour)
        let own = SettingsTestEnd(sessionID: test.sessionID!, cause: .carbsLogged, date: later)
        #expect(check(test, at: later, serviceEnd: own, mode: .closed) == .carbsLogged(at: later))
        let other = SettingsTestEnd(sessionID: UUID(), cause: .carbsLogged, date: later)
        #expect(check(test, at: later, serviceEnd: other) == nil)
        // Before the bolus too.
        var dosing = makeTest()
        dosing.sessionID = test.sessionID
        let low = SettingsTestEnd(sessionID: test.sessionID!, cause: .low, date: at(hour + minute))
        #expect(check(dosing, at: at(hour + 2 * minute), serviceEnd: low, mode: .closed) == .lowBeforeDose(at: at(hour + minute)))
    }

    @Test("With the boluses unread, no bolus and a low before the dose wait for a tick that reads them") func decidable() {
        #expect(CarbRatioTestEvaluator.decidable(.noBolus, bolusesRead: false) == nil)
        #expect(CarbRatioTestEvaluator.decidable(.lowBeforeDose(at: at(hour)), bolusesRead: false) == nil)
        #expect(CarbRatioTestEvaluator.decidable(.noBolus, bolusesRead: true) == .noBolus)
        #expect(CarbRatioTestEvaluator.decidable(.modeChanged, bolusesRead: false) == .modeChanged)
    }

    @Test("Settling's dead ends are the ISF test's; the time-up question isn't one") func settlingDeadEnd() {
        #expect(CarbRatioTestEvaluator.settlingDeadEnd(.noLoop) == ISFTestEvaluator.deadEndSentence(settling: .noLoop))
        #expect(CarbRatioTestEvaluator.settlingDeadEnd(.noLoop) != nil)
        #expect(CarbRatioTestEvaluator.settlingDeadEnd(.timeUp(loopedAt: at(minute))) == nil)
        #expect(CarbRatioTestEvaluator.settlingDeadEnd(.settled) == nil)
    }

    /// 3 level readings, the newest a minute old, with nothing on board.
    private var inputs: CarbRatioTestDoseInputs {
        let now = at(90 * minute)
        return CarbRatioTestDoseInputs(
            readings: [1, 6, 11].map { BasalTestReading(date: now.addingTimeInterval(-$0 * minute), glucose: 110) },
            direction: .flat,
            iob: 0,
            doseIOB: 0,
            cob: 0,
            increment: dec("0.05"),
            now: now
        )
    }

    @Test("The Dose step's only dead end is missing settings; Count It with insulin covering the dose waits") func doseDeadEnd() {
        #expect(CarbRatioTestEvaluator.doseDeadEnd(of: makeTest(isf: 0), inputs) == CarbRatioTestNoDose.noSettings.sentence)
        var covered = inputs
        covered.doseIOB = 4
        #expect(CarbRatioTestEvaluator.noDoseReason(of: makeTest(handling: .count), covered) == .iobCoversDose)
        #expect(CarbRatioTestEvaluator.doseDeadEnd(of: makeTest(handling: .count), covered) == nil)
        var carbs = inputs
        carbs.cob = 5
        #expect(CarbRatioTestEvaluator.doseDeadEnd(of: makeTest(), carbs) == nil)
        #expect(CarbRatioTestEvaluator.doseDeadEnd(of: makeTest(), inputs) == nil)
        // Only on the Dose step.
        #expect(CarbRatioTestEvaluator.doseDeadEnd(of: makeTest(phase: .settling, isf: 0), inputs) == nil)
    }

    @Test("A bolus with no carbs ends the test 15 minutes after it, in words that don't ask for carbs") func bolusWithoutCarbs() {
        let bolus = at(hour + 10 * minute)
        let deadline = bolus.addingTimeInterval(15 * minute)
        func ending(at now: Date) -> CarbRatioTestEvaluator.Ending? {
            CarbRatioTestEvaluator.mealPairingEnd(carbsAt: nil, bolusAt: bolus, now: now)
        }
        #expect(ending(at: deadline.addingTimeInterval(-1)) == nil)
        let ended = CarbRatioTestEvaluator.Ending(
            reason: .interrupted,
            at: deadline,
            note: CarbRatioTestEvaluator.bolusWithoutCarbsNote
        )
        #expect(ending(at: deadline) == ended)
        #expect(ending(at: deadline.addingTimeInterval(hour)) == ended)
        // R2-6: whether to log them is the finish's to add, from a read of the carbs as the test ends.
        #expect(
            CarbRatioTestEvaluator.bolusWithoutCarbsNote
                == "The bolus came, but the tablets' carbs weren't logged within 15 minutes."
        )
        #expect(
            CarbRatioTestEvaluator.logCarbsSentence == "If you ate the tablets, log their carbs so Trio counts them."
        )
    }

    @Test("Carbs with no bolus end the test 15 minutes after them, so the usual dosing covers them") func carbsWithoutBolus() {
        let carbs = at(hour + 10 * minute)
        let deadline = carbs.addingTimeInterval(15 * minute)
        #expect(CarbRatioTestEvaluator.mealPairingEnd(carbsAt: carbs, bolusAt: nil, now: deadline.addingTimeInterval(-1)) == nil)
        #expect(
            CarbRatioTestEvaluator.mealPairingEnd(carbsAt: carbs, bolusAt: nil, now: deadline)
                == CarbRatioTestEvaluator.Ending(
                    reason: .interrupted,
                    at: deadline,
                    note: CarbRatioTestEvaluator.carbsWithoutBolusNote
                )
        )
        #expect(
            CarbRatioTestEvaluator.carbsWithoutBolusNote
                ==
                "The tablets' carbs were logged, but no bolus came within 15 minutes. Your usual dosing mode is back to cover them."
        )
        // Said without the mode sentence when the usual mode isn't back.
        #expect(
            CarbRatioTestEvaluator.modeWorded(CarbRatioTestEvaluator.carbsWithoutBolusNote, modeBack: false)
                == "The tablets' carbs were logged, but no bolus came within 15 minutes."
        )
    }

    @Test(
        "Carbs with no bolus say the usual mode covers them only for Closed Loop: the others don't bolus for carbs"
    ) func carbsWithoutBolusModes() {
        // A2: Open Loop and Low Glucose Suspend never add insulin.
        let other =
            "The tablets' carbs were logged, but no bolus came within 15 minutes. Your usual dosing mode is back, and it doesn't bolus for carbs: cover them as you usually would."
        for mode in [DosingMode.open, .lowGlucoseSuspend] {
            #expect(
                CarbRatioTestEvaluator
                    .modeWorded(CarbRatioTestEvaluator.carbsWithoutBolusNote, modeBack: true, usualMode: mode) == other
            )
            #expect(CarbRatioTestEvaluator.carbsWithoutBolusNote(modeBack: true, usualMode: mode) == other)
        }
        #expect(
            CarbRatioTestEvaluator.modeWorded(CarbRatioTestEvaluator.carbsWithoutBolusNote, modeBack: true, usualMode: .closed)
                == CarbRatioTestEvaluator.carbsWithoutBolusNote
        )
        #expect(
            CarbRatioTestEvaluator.modeWorded(CarbRatioTestEvaluator.carbsWithoutBolusNote, modeBack: false, usualMode: .open)
                == "The tablets' carbs were logged, but no bolus came within 15 minutes."
        )
    }

    @Test(
        "Both halves within 15 minutes of each other, either way round, pair; further apart, both are logged and too far apart"
    ) func bothHalves() {
        let first = at(hour + 10 * minute)
        let late = first.addingTimeInterval(16 * minute)
        let farFuture = at(10 * hour)
        // In time, either order, the second at the deadline itself included.
        for second in [first.addingTimeInterval(5 * minute), first.addingTimeInterval(15 * minute)] {
            #expect(CarbRatioTestEvaluator.mealPairingEnd(carbsAt: first, bolusAt: second, now: farFuture) == nil)
            #expect(CarbRatioTestEvaluator.mealPairingEnd(carbsAt: second, bolusAt: first, now: farFuture) == nil)
        }
        // A1: the bolus 16 minutes after the carbs, or the carbs 16 minutes after the bolus: both are logged, so the
        // ending says they came too far apart, and never to log the carbs.
        let apart = CarbRatioTestEvaluator.Ending(
            reason: .interrupted,
            at: first.addingTimeInterval(15 * minute),
            note: CarbRatioTestEvaluator.mealApartNote
        )
        #expect(CarbRatioTestEvaluator.mealPairingEnd(carbsAt: first, bolusAt: late, now: farFuture) == apart)
        #expect(CarbRatioTestEvaluator.mealPairingEnd(carbsAt: late, bolusAt: first, now: farFuture) == apart)
        #expect(
            CarbRatioTestEvaluator.mealApartNote
                ==
                "The tablets' carbs and the bolus came more than 15 minutes apart, so the test can't judge them. Your usual dosing mode is back."
        )
        #expect(CarbRatioTestEvaluator.mealPairingEnd(carbsAt: nil, bolusAt: nil, now: farFuture) == nil)
    }

    @Test(
        "Carbs logged past 15 minutes with the boluses unreadable end the test then, in words for that"
    ) func bolusesUnread() {
        // M1: no bolus can be seen, so none can be paired with the carbs.
        let carbs = at(hour + 10 * minute)
        let deadline = carbs.addingTimeInterval(15 * minute)
        // Dated now: a bolus may have come, so when the test should have ended can't be told.
        #expect(
            CarbRatioTestEvaluator.bolusesUnreadEnd(carbsAt: carbs, bolusAt: nil, bolusesRead: false, now: deadline)
                == CarbRatioTestEvaluator.Ending(
                    reason: .interrupted,
                    at: nil,
                    note: CarbRatioTestEvaluator.bolusesUnreadNote
                )
        )
        #expect(
            CarbRatioTestEvaluator.bolusesUnreadEnd(
                carbsAt: carbs,
                bolusAt: nil,
                bolusesRead: false,
                now: deadline.addingTimeInterval(-1)
            ) == nil
        )
        // Read, a bolus already in, or no carbs: not this ending.
        #expect(CarbRatioTestEvaluator.bolusesUnreadEnd(carbsAt: carbs, bolusAt: nil, bolusesRead: true, now: deadline) == nil)
        #expect(CarbRatioTestEvaluator.bolusesUnreadEnd(carbsAt: carbs, bolusAt: carbs, bolusesRead: false, now: deadline) == nil)
        #expect(CarbRatioTestEvaluator.bolusesUnreadEnd(carbsAt: nil, bolusAt: nil, bolusesRead: false, now: deadline) == nil)
        #expect(
            CarbRatioTestEvaluator.bolusesUnreadNote
                ==
                "Trio couldn't read your boluses to pair one with the tablets' carbs within 15 minutes, so the test can't be judged. If you didn't give the bolus, cover the carbs as you usually would."
        )
    }

    @Test("The service's record of a meal not paired ends the test in the words of what it saw") func serviceMealEnd() {
        var test = makeTest()
        test.sessionID = UUID()
        let at15 = at(hour + 30 * minute)
        let record = SettingsTestEnd(sessionID: test.sessionID!, cause: .mealUnpaired, date: at15)
        #expect(
            CarbRatioTestEvaluator.serviceMealEnd(of: test, serviceEnd: record, bolusesRead: true)
                == CarbRatioTestEvaluator.Ending(reason: .interrupted, at: at15, note: CarbRatioTestEvaluator.mealUnpairedNote)
        )
        test.carbsAt = at(hour + 15 * minute)
        #expect(
            CarbRatioTestEvaluator.serviceMealEnd(of: test, serviceEnd: record, bolusesRead: true)?.note
                == CarbRatioTestEvaluator.carbsWithoutBolusNote
        )
        // M1: with the boluses unread, no bolus can be said not to have come.
        #expect(
            CarbRatioTestEvaluator.serviceMealEnd(of: test, serviceEnd: record, bolusesRead: false)?.note
                == CarbRatioTestEvaluator.bolusesUnreadNote
        )
        // A1: both halves in, one late.
        var both = test
        both.bolusAt = at(hour + 31 * minute)
        #expect(
            CarbRatioTestEvaluator.serviceMealEnd(of: both, serviceEnd: record, bolusesRead: true)?.note
                == CarbRatioTestEvaluator.mealApartNote
        )
        // In time: the service's ending came from boluses it couldn't read, so no half is called late or missing.
        var paired = both
        paired.bolusAt = at(hour + 20 * minute)
        #expect(
            CarbRatioTestEvaluator.serviceMealEnd(of: paired, serviceEnd: record, bolusesRead: true)?.note
                == CarbRatioTestEvaluator.historyUnreadNote
        )
        var bolusOnly = both
        bolusOnly.carbsAt = nil
        #expect(
            CarbRatioTestEvaluator.serviceMealEnd(of: bolusOnly, serviceEnd: record, bolusesRead: true)?.note
                == CarbRatioTestEvaluator.bolusWithoutCarbsNote
        )
        // Another session's, or another cause, isn't one.
        let other = SettingsTestEnd(sessionID: UUID(), cause: .mealUnpaired, date: at15)
        #expect(CarbRatioTestEvaluator.serviceMealEnd(of: test, serviceEnd: other, bolusesRead: true) == nil)
        let noBolus = SettingsTestEnd(sessionID: test.sessionID!, cause: .noBolus, date: at15)
        #expect(CarbRatioTestEvaluator.serviceMealEnd(of: test, serviceEnd: noBolus, bolusesRead: true) == nil)
        // And the ISF test's rules never read it.
        #expect(
            CarbRatioTestEvaluator
                .runningCheck(of: test, serviceEnd: record, suspend: .none, now: at15, mode: .closed) == .modeChanged
        )
    }

    @Test(
        "Once the tablets' carbs are logged ahead of the bolus, the step asks for the bolus alone"
    ) func carbsLoggedAwaitingBolus() {
        var test = makeTest()
        #expect(!test.carbsLoggedAwaitingBolus)
        #expect(test.bolusDeadline == nil)
        test.carbsAt = at(80 * minute)
        test.carbs = 40
        #expect(test.carbsLoggedAwaitingBolus)
        #expect(test.bolusDeadline == at(95 * minute))
        #expect(test.mealAt == at(80 * minute))
        #expect(test.minutesLeftForBolus(at: at(85 * minute)) == 10)
        #expect(test.minutesLeftForBolus(at: at(85 * minute + 1)) == 10)
        #expect(test.minutesLeftForBolus(at: at(100 * minute)) == 0)
        // The arrow moving and carbs on board (the tablets' own, counted) no longer hold the bolus back.
        var rising = inputs
        rising.direction = .singleUp
        rising.cob = 40
        rising.readings = []
        #expect(CarbRatioTestEvaluator.noDoseReason(of: test, rising) == nil)
        #expect(CarbRatioTestEvaluator.canDose(of: test, rising))
        // Insulin on board still does.
        rising.iob = 1
        #expect(CarbRatioTestEvaluator.noDoseReason(of: test, rising) == .iobOverLine)
        // Before the carbs, the arrow holds it.
        #expect(CarbRatioTestEvaluator.noDoseReason(of: makeTest(), rising) == .carbsOnBoard)
        // Once the bolus is in, the meal's moment is the earlier half.
        test.bolusAt = at(84 * minute)
        #expect(!test.carbsLoggedAwaitingBolus)
        #expect(test.mealAt == at(80 * minute))
    }

    @Test("An owed \"Carb Ratio Dose Ready\" goes once the step offers the dose, then nothing is owed") func doseNotice() {
        let ready = CarbRatioTestEvaluator.doseNotice(due: true, canDose: true)
        #expect(ready.post == .settledToDose)
        #expect(ready.due == nil)
        let held = CarbRatioTestEvaluator.doseNotice(due: true, canDose: false)
        #expect(held.post == nil)
        #expect(held.due == true)
        for due in [nil, false] as [Bool?] {
            let none = CarbRatioTestEvaluator.doseNotice(due: due, canDose: true)
            #expect(none.post == nil)
            #expect(none.due == nil)
        }
    }

    private func carbEntry(_ id: String, _ date: Date) -> SettingsTestCarbEntry {
        SettingsTestCarbEntry(id: id, date: date)
    }

    @Test("Carbs spoil the test except its own entry, once the bolus window is open") func carbsSpoil() {
        let windowStart = at(hour)
        let bolusAt = at(hour + 10 * minute)
        func spoil(_ entries: [SettingsTestCarbEntry], window: Date? = windowStart, saved: String? = nil) -> Bool {
            CarbRatioTestEvaluator.carbsSpoil(entries, startedAt: testStart, kept: [], windowStart: window, savedID: saved)
        }
        let tablets = carbEntry("tablets", at(hour + 5 * minute))
        // While settling, none is let through.
        #expect(spoil([tablets], window: nil))
        // After it, the first entry is the test's, however late: the pairing ends a late one (`mealPairingEnd`).
        #expect(!spoil([tablets]))
        #expect(!spoil([carbEntry("late", bolusAt.addingTimeInterval(40 * minute))]))
        // A second entry spoils it.
        #expect(spoil([tablets, carbEntry("more", at(hour + 20 * minute))]))
        // One logged while settling, dated before the window, isn't the test's.
        #expect(spoil([carbEntry("early", at(50 * minute))]))
        // One from before Begin that wasn't there then spoils it, as for the other tests.
        #expect(spoil([carbEntry("backdated", testStart.addingTimeInterval(-hour)), tablets]))
        // The entry saved as the test's is the one let through, whatever is first.
        #expect(!spoil([tablets], saved: "tablets"))
        #expect(spoil([carbEntry("early", at(50 * minute)), tablets], saved: "tablets"))
    }

    @Test("A carb ratio schedule reads in grams per unit, an exchange as 12 g, each entry to the next") func scheduleEntries() {
        func ratio(_ start: String, _ offset: Int, _ value: Decimal) -> CarbRatioEntry {
            CarbRatioEntry(start: start, offset: offset, ratio: value)
        }
        let grams = CarbRatios(units: .grams, schedule: [ratio("06:00", 360, 12), ratio("00:00", 0, 10)])
        #expect(CarbRatioTest.Provider.entries(in: grams) == [entry(0, 360, 10), entry(360, 1440, 12)])
        let exchanges = CarbRatios(units: .exchanges, schedule: [ratio("00:00", 0, dec("1.5"))])
        #expect(CarbRatioTest.Provider.entries(in: exchanges) == [entry(0, 1440, 8)])
        // A ratio of 0 has no ratio in it, as Trio's own lookup finds.
        let zero = CarbRatios(units: .grams, schedule: [ratio("00:00", 0, 0), ratio("12:00", 720, 15)])
        #expect(CarbRatioTest.Provider.entries(in: zero) == [entry(720, 1440, 15)])
    }

    @Test("The carb ratio test's notices and Begin's refusals say what they are") func copy() {
        #expect(SettingsTestNotice.carbRatioStep(.settledToDose).title == "Carb Ratio Dose Ready")
        #expect(SettingsTestNotice.carbRatioStep(.settledToDose).body == "Settling is done. Tap to see your tablets and dose.")
        #expect(SettingsTestNotice.carbRatioStep(.settledToDose).identifier == "Trio.settingsTest.carbRatio.step")
        #expect(SettingsTestNotice.carbRatioStep(.timeUp).title == "Carb Ratio Test Waiting")
        #expect(SettingsTestNotice.carbRatioStep(.timeUp).body == SettingsTestNotice.isfStep(.timeUp).body)
        #expect(
            SettingsTestBeginError.carbsOnBoard.message
                == "Trio counts more carbs on board than the test allows. Wait for them to come down, then try again."
        )
        #expect(
            SettingsTestBeginError.iobOverDose.message
                == "Your insulin on board is more than the test's whole dose. Wait for it to come down, then try again."
        )
        #expect(
            SettingsTestBeginError.tabletsOverLimits.message
                == "That many tablets needs more than your Max Bolus or Max Carbs allows. Choose fewer, then try again."
        )
        #expect(
            SettingsTestBeginError.carbRatioUnderMinimum.message
                == "A carb ratio under 2 g/U can't be tested in 1 g/U steps: the docs' minimum is 1.0 g/U."
        )
        #expect(CarbRatioTest.Docs.minimumCarbRatio == "Minimum: 1.0 g/U")
        #expect(CarbRatioTest.Config.minimumTestedCarbRatio == 2)
    }
}

// MARK: - Fix wave 1: the bolus against the formula, and the meal

@Suite("Carb ratio test bolus against the formula") struct CarbRatioTestBolusRangeTests {
    @Test("A bolus may give from a 1 g/U higher ratio's dose, rounded down, to a 1 g/U lower one's, rounded up") func range() {
        // 40 g at 10 g/U: 40 ÷ 11 = 3.64, down to 3.60; 40 ÷ 9 = 4.44, up to 4.45.
        let range = CarbRatioTestEvaluator.bolusRange(carbs: 40, carbRatio: 10, increment: dec("0.05"))
        #expect(range == CarbRatioTestDoseRange(lowest: dec("3.6"), highest: dec("4.45")))
        #expect(range?.contains(dec("3.6")) == true)
        #expect(range?.contains(dec("3.59")) == false)
        #expect(range?.contains(dec("4.45")) == true)
        #expect(range?.contains(dec("4.46")) == false)
        // A 0.1 U pump: 3.6 to 4.5.
        #expect(
            CarbRatioTestEvaluator.bolusRange(carbs: 40, carbRatio: 10, increment: dec("0.1"))
                == CarbRatioTestDoseRange(lowest: dec("3.6"), highest: dec("4.5"))
        )
        // At or under the step, no top.
        #expect(CarbRatioTestEvaluator.bolusRange(carbs: 4, carbRatio: 1, increment: 0)?.highest == nil)
        #expect(CarbRatioTestEvaluator.bolusRange(carbs: 0, carbRatio: 10, increment: 0) == nil)
    }

    /// The worked example waiting from a bolus of `bolus` with `iob` on board at it.
    private func waiting(bolus: Decimal?, iob: Decimal?, handling: ISFTestIOBHandling? = nil) -> CarbRatioTestState {
        var test = makeTest(phase: .waiting, handling: handling)
        test.bolusAt = at(hour + 10 * minute)
        test.bolusUnits = bolus
        test.iobAtBolus = iob
        return test
    }

    @Test("A bolus outside the range widened by a pump increment is off the formula") func offFormula() {
        #expect(CarbRatioTestEvaluator.bolusOffFormula(of: waiting(bolus: 4, iob: 0)) == nil)
        // Trio's 80% suggestion: 3.2 U.
        #expect(
            CarbRatioTestEvaluator.bolusOffFormula(of: waiting(bolus: dec("3.2"), iob: 0))
                == .bolusOffFormula(given: dec("3.2"), formula: 4, counted: false)
        )
        // 3.60 to 4.45 widened by the 0.05 U increment: 3.55 to 4.50.
        #expect(CarbRatioTestEvaluator.bolusOffFormula(of: waiting(bolus: dec("3.55"), iob: 0)) == nil)
        #expect(CarbRatioTestEvaluator.bolusOffFormula(of: waiting(bolus: dec("4.5"), iob: 0)) == nil)
        #expect(
            CarbRatioTestEvaluator.bolusOffFormula(of: waiting(bolus: dec("3.5"), iob: 0))
                == .bolusOffFormula(given: dec("3.5"), formula: 4, counted: false)
        )
        #expect(
            CarbRatioTestEvaluator.bolusOffFormula(of: waiting(bolus: dec("4.55"), iob: 0))
                == .bolusOffFormula(given: dec("4.55"), formula: 4, counted: false)
        )
        // Insulin on board unread: the bolus alone, unless the test counts it.
        #expect(CarbRatioTestEvaluator.bolusOffFormula(of: waiting(bolus: dec("3.2"), iob: nil)) != nil)
        #expect(CarbRatioTestEvaluator.bolusOffFormula(of: waiting(bolus: 3, iob: nil, handling: .count)) == nil)
        // Count It: 3 U for 4 U less 1 U on board is the formula's.
        #expect(CarbRatioTestEvaluator.bolusOffFormula(of: waiting(bolus: 3, iob: 1, handling: .count)) == nil)
        // No amount, nothing to judge.
        #expect(CarbRatioTestEvaluator.bolusOffFormula(of: waiting(bolus: nil, iob: 0)) == nil)
        #expect(
            CarbRatioTestBolusCondition.bolusOffFormula(given: dec("3.2"), formula: 4, counted: false).note
                ==
                "The bolus was 3.20\u{00A0}U, more than a 1 g/U step from the formula's 4.00\u{00A0}U, so the result would rest on your ISF instead of your carb ratio. Your usual dosing mode is back."
        )
        // Without the mode sentence when the usual mode isn't back.
        #expect(
            CarbRatioTestEvaluator.modeWorded(
                CarbRatioTestBolusCondition.bolusOffFormula(given: dec("3.2"), formula: 4, counted: false).note,
                modeBack: false
            )?.hasSuffix("instead of your carb ratio.") == true
        )
    }

    @Test(
        "Waiting for insulin on board, or with no choice, judges the bolus alone; Count It judges it with insulin on board"
    ) func offFormulaUnits() {
        // R2-4: 40 g at 12 g/U, 3.33 U; range 3.05 to 3.65. The dose shown with 0.26 U under zero, given as 3.30 U: the
        // bolus alone is in range, where with insulin on board it came to 3.04 U.
        func atTwelve(handling: ISFTestIOBHandling?) -> CarbRatioTestState {
            var test = makeTest(phase: .waiting, carbRatio: 12, handling: handling)
            test.bolusAt = at(hour + 10 * minute)
            test.bolusUnits = dec("3.3")
            test.iobAtBolus = dec("-0.26")
            return test
        }
        #expect(CarbRatioTestEvaluator.bolusOffFormula(of: atTwelve(handling: nil)) == nil)
        #expect(CarbRatioTestEvaluator.bolusOffFormula(of: atTwelve(handling: .wait)) == nil)
        // Count It: 3.04 U is under 3.05 but within the increment, 3.00; 3.3 − 0.31 = 2.99 U isn't.
        #expect(CarbRatioTestEvaluator.bolusOffFormula(of: atTwelve(handling: .count)) == nil)
        var counted = atTwelve(handling: .count)
        counted.iobAtBolus = dec("-0.31")
        #expect(
            CarbRatioTestEvaluator.bolusOffFormula(of: counted)
                == .bolusOffFormula(given: dec("2.99"), formula: dec("3.33"), counted: true)
        )
        // A Wait for It bolus of 4.2 U with 0.35 U on board is judged at 4.2 U; with Count It, at 4.55 U, off.
        #expect(CarbRatioTestEvaluator.bolusOffFormula(of: waiting(bolus: dec("4.2"), iob: dec("0.35"), handling: .wait)) == nil)
        let countIt = CarbRatioTestEvaluator.bolusOffFormula(of: waiting(bolus: dec("4.2"), iob: dec("0.35"), handling: .count))
        #expect(countIt == .bolusOffFormula(given: dec("4.55"), formula: 4, counted: true))
        #expect(
            countIt?.note
                ==
                "The bolus and the insulin on board came to 4.55\u{00A0}U, more than a 1 g/U step from the formula's 4.00\u{00A0}U, so the result would rest on your ISF instead of your carb ratio. Your usual dosing mode is back."
        )
    }

    @Test("Trio's suggestion is in range by a pump increment or not, with insulin on board counted") func suggestion() {
        // 80% of 4 U.
        #expect(!CarbRatioTestEvaluator.suggestionInRange(dec("3.2"), carbs: 40, carbRatio: 10, increment: dec("0.05")))
        // 90%, and 110%.
        #expect(CarbRatioTestEvaluator.suggestionInRange(dec("3.6"), carbs: 40, carbRatio: 10, increment: dec("0.05")))
        #expect(CarbRatioTestEvaluator.suggestionInRange(dec("4.4"), carbs: 40, carbRatio: 10, increment: dec("0.05")))
        // R2-4: inside the range the bolus may take (3.55 to 4.50), but not by an increment: "Enter 4.00 U".
        #expect(!CarbRatioTestEvaluator.suggestionInRange(dec("3.55"), carbs: 40, carbRatio: 10, increment: dec("0.05")))
        #expect(!CarbRatioTestEvaluator.suggestionInRange(dec("4.5"), carbs: 40, carbRatio: 10, increment: dec("0.05")))
        // 3.2 U with 0.5 U on board gives 3.7.
        #expect(
            CarbRatioTestEvaluator.suggestionInRange(
                dec("3.2"),
                iob: dec("0.5"),
                carbs: 40,
                carbRatio: 10,
                increment: dec("0.05")
            )
        )
    }

    @Test("How far a 1 g/U change moves the end, and how much insulin on board was still to act") func screenLines() {
        // 50 × (40 ÷ 10 − 40 ÷ 11) = 50 × 0.3636 = 18.
        #expect(CarbRatioTestEvaluator.endShiftPerStep(carbs: 40, carbRatio: 10, isf: 50) == 18)
        // 1 tablet: 50 × (4 ÷ 10 − 4 ÷ 11) = 1.8, 2.
        #expect(CarbRatioTestEvaluator.endShiftPerStep(carbs: 4, carbRatio: 10, isf: 50) == 2)
        #expect(CarbRatioTestEvaluator.endShiftPerStep(carbs: 40, carbRatio: 0, isf: 50) == nil)
        // 0.56 U at 50: 28 mg/dL still to come off.
        #expect(CarbRatioTestEvaluator.stillToComeOff(iobAtEnd: dec("0.56"), isf: 50) == 28)
        #expect(CarbRatioTestEvaluator.stillToComeOff(iobAtEnd: nil, isf: 50) == nil)
    }

    @Test("The meal is judged at its moment: the grams first, then the arrow and carbs on board at the carbs") func meal() {
        let bolus = at(2 * hour)
        let carbsAt = bolus.addingTimeInterval(-10 * minute)
        func failed(
            logged: Decimal = 40,
            arrow: ISFTestArrowReading,
            determinations: [ISFTestDetermination]
        ) -> CarbRatioTestBolusCondition? {
            CarbRatioTestEvaluator.failedMealCondition(
                bolusAt: bolus,
                carbsAt: carbsAt,
                loggedCarbs: logged,
                plannedCarbs: 40,
                startGlucose: 110,
                carbRatio: 10,
                arrow: arrow,
                determinations: determinations,
                handling: nil
            )
        }
        let flatAtCarbs = ISFTestArrowReading(date: carbsAt.addingTimeInterval(-minute), direction: .flat)
        // Before the carbs: none on board; just before the bolus, the tablets' 40 g counted, and nothing on board.
        let reads = [
            ISFTestDetermination(date: carbsAt.addingTimeInterval(-3 * minute), iob: 0, cob: 0),
            ISFTestDetermination(date: bolus.addingTimeInterval(-minute), iob: 0, cob: 40)
        ]
        #expect(failed(arrow: flatAtCarbs, determinations: reads) == nil)
        #expect(failed(logged: 30, arrow: flatAtCarbs, determinations: reads) == .carbsDiffer(logged: 30, planned: 40))
        // The arrow read at the bolus, after the tablets acted, isn't the meal's: it must be from before the carbs.
        let risingAtBolus = ISFTestArrowReading(date: bolus.addingTimeInterval(-minute), direction: .singleUp)
        #expect(failed(arrow: risingAtBolus, determinations: reads) == .unread)
        #expect(
            failed(
                arrow: ISFTestArrowReading(date: carbsAt.addingTimeInterval(-minute), direction: .singleUp),
                determinations: reads
            )
                == .glucoseMoving
        )
    }
}

@Suite("Carb ratio test Treatments fill refusal") @MainActor struct CarbRatioTestPrefillRefusalTests {
    @Test("No carbs are filled in while the test shows its tablets' carbs logged ahead of the bolus") func refuses() {
        let logged = SettingsTestTreatmentsPrefill(
            router: { SettingsTestFakeRouter() },
            aiRequestFills: { false },
            testCarbsLogged: { true }
        )
        logged.prepare(carbs: 40)
        #expect(!logged.isPending)
        let fresh = SettingsTestTreatmentsPrefill(
            router: { SettingsTestFakeRouter() },
            aiRequestFills: { false },
            testCarbsLogged: { false }
        )
        fresh.prepare(carbs: 40)
        #expect(fresh.isPending)
    }
}
