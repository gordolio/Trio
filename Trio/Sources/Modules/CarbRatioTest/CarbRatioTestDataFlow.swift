import Foundation

enum CarbRatioTest {
    enum Config {
        /// The docs' smallest carb ratio change, in grams per unit: "Make small changes: Adjust by 1-2 g/U at a time". A
        /// ratio the test shows within this much of the carb ratio counts as accurate.
        static let docsSmallestStep: Decimal = 1
        /// The lengths the test can run after the bolus, from the docs' "Monitor for 3-4 hours". Ending sooner can't say
        /// anything.
        static let lengths: [TimeInterval] = [3 * 3600, 4 * 3600]
        /// The length the Check screen starts with: the docs' longer one, so more of the meal has acted by the end.
        static let defaultLength: TimeInterval = 4 * 3600
        /// How many glucose tablets the Check screen starts with. The docs give no number ("Use a meal with known,
        /// accurately counted carbs"), so this is an app choice: more tablets widen the band of accurate end readings
        /// (`CarbRatioTestEvaluator.accurateEnds`), so CGM noise matters less.
        static let defaultTabletCount = 10
        /// The most tablets the Check screen offers. An app limit, not a treatment rule; Max Bolus and Max Carbs can
        /// lower it (`CarbRatioTestEvaluator.maxTablets`).
        static let maxTabletCount = 20
        /// The meal's two halves, the tablets' carbs and the test bolus, must come within this of each other, whichever
        /// comes first (`CarbRatioTestEvaluator.mealPairingEnd`). An app limit, not a treatment rule: carbs with no bolus
        /// are carbs Basal Testing gives no insulin for, and a bolus with no carbs is insulin Trio's forecast sees alone, so
        /// past it the test ends at once with no verdict and the usual dosing comes back.
        static let mealPairing: TimeInterval = 15 * 60
        /// The lowest carb ratio the docs allow: "Minimum: 1.0 g/U".
        static let docsMinimumCarbRatio: Decimal = 1
        /// The lowest carb ratio the test can judge: a ratio a docs step (`docsSmallestStep`) under it must still be one
        /// the docs allow (`docsMinimumCarbRatio`), so 2 g/U. Begin refuses one under it.
        static let minimumTestedCarbRatio: Decimal = docsMinimumCarbRatio + docsSmallestStep

        // The same app limits as the ISF test's, from one source.
        /// How long after the end of settling the bolus may come (`ISFTest.Config.doseAllowance`).
        static let doseAllowance = ISFTest.Config.doseAllowance
        /// How long after Begin a determination must be for Trio to have made it in Basal Testing
        /// (`ISFTest.Config.settleLoopMargin`).
        static let settleLoopMargin = ISFTest.Config.settleLoopMargin
        /// How long settling waits for insulin on board to come under the test's line (`ISFTest.Config.settleAllowance`).
        static let settleAllowance = ISFTest.Config.settleAllowance
        /// How many CGM readings the start and end glucose average (`ISFTest.Config.meanReadings`).
        static let meanReadings = ISFTest.Config.meanReadings
        /// How many CGM readings settling waits for after Trio's first loop in Basal Testing
        /// (`ISFTest.Config.settleReadings`).
        static let settleReadings = ISFTest.Config.settleReadings
        /// After the planned end, the test is closed automatically if the app was never opened
        /// (`ISFTest.Config.expiryGrace`).
        static let expiryGrace = ISFTest.Config.expiryGrace
        /// How far apart a date saved in the test's state and a timestamp from the history can be and still be the same
        /// moment (`ISFTest.Config.savedDateTolerance`).
        static let savedDateTolerance = ISFTest.Config.savedDateTolerance
        /// How much of the chart before the end the Result screen shades with the band (`ISFTest.Config.expectedEndShading`).
        /// Display only.
        static let expectedEndShading = ISFTest.Config.expectedEndShading
        static let statePath = "trio/carb_ratio_test_state.json"
    }

    /// The Trio docs passages the screens rest on, copied word for word (the docs' arrows and punctuation included),
    /// and the pages they come from.
    enum Docs {
        static let testingMethod = URL(
            string: "https://triodocs.org/usage/concepts/carb-ratios/#testing-method-meal-experiment"
        )!
        static let bestPractices = URL(string: "https://triodocs.org/usage/concepts/carb-ratios/#best-practices")!
        /// The same page the ISF test links for Trio's suggested bolus.
        static let recommendedBolusPercentage = ISFTest.Docs.recommendedBolusPercentage

        // Each link is named for its page, so two on one screen can be told apart.
        static var testingMethodLink: SettingsTestDocsLink {
            SettingsTestDocsLink(title: String(localized: "Carb ratio testing method in Trio docs"), url: testingMethod)
        }

        static let bolusCalculator = URL(string: "https://triodocs.org/usage/concepts/carb-ratios/#in-the-bolus-calculator")!

        static var bolusCalculatorLink: SettingsTestDocsLink {
            SettingsTestDocsLink(
                title: String(localized: "Carb ratio in the bolus calculator in Trio docs"),
                url: bolusCalculator
            )
        }

        static var bestPracticesLink: SettingsTestDocsLink {
            SettingsTestDocsLink(title: String(localized: "Carb ratio best practices in Trio docs"), url: bestPractices)
        }

        static var recommendedBolusPercentageLink: SettingsTestDocsLink {
            ISFTest.Docs.recommendedBolusPercentageLink
        }

        // Testing method: meal experiment (carb-ratios.md), "Choose testing conditions"
        static let startInRange = "Start with glucose in range (near target)"
        static let minimalIOB = "Zero or minimal IOB"
        static let minimalCOB = "Zero or minimal COB from previous meals"
        static let noRecentExercise = "No recent exercise"
        static let countedCarbs = "Use a meal with known, accurately counted carbs"

        // "Perform the meal bolus". The docs write the formula as a fraction; this is it written out in text.
        static let calculateInsulin = "Calculate insulin: Carbs ÷ Current CR"
        static let fullBolus = "Deliver the full bolus manually"

        // "Monitor for 3-4 hours"
        static let monitor = "Monitor for 3-4 hours"
        static let avoidFood = "Avoid additional food or corrections during this time"

        // "Evaluate the result"
        static let returnToStart = "Return to starting glucose: CR is accurate"
        static let endUpHigh = "End up high: CR is too high (too conservative) → DECREASE the CR value"
        static let endUpLow = "End up low: CR is too low (too aggressive) → INCREASE the CR value"

        // "In the Bolus Calculator" (carb-ratios.md). The docs write the formula with fractions; this is it written out in
        // text.
        static let bolusCalculatorFormula = "Total Insulin = (Current BG − Target) ÷ ISF + Carbs ÷ CR + Trend − IOB"

        // "Confusing CR with ISF Issues" (carb-ratios.md), the sentence after its "Important" label
        static let crOrISF = "High post-meal glucose can be caused by incorrect CR, incorrect ISF, or a combination of both"

        // CR value ranges (carb-ratios.md)
        static let minimumCarbRatio = "Minimum: 1.0 g/U"

        // Best practices (carb-ratios.md)
        static let smallChanges = "Make small changes: Adjust by 1-2 g/U at a time"
        static let oneMealAtATime = "Test one meal at a time: Don't change multiple CR entries simultaneously"
        static let waitBetweenChanges =
            "Wait between changes: Give each adjustment several days and multiple meals to evaluate"
    }

    enum Step: Int, CaseIterable, SettingsTestStep {
        case check
        case settle
        case dose
        case wait
        case result

        var order: Int { rawValue }

        var title: String {
            switch self {
            case .check: return String(localized: "Check")
            case .settle: return String(localized: "Settle")
            case .dose: return String(localized: "Dose")
            case .wait: return String(localized: "Wait")
            case .result: return String(localized: "Result")
            }
        }

        /// The ISF test's icons, so the two tests' step bars match.
        var iconName: String {
            switch self {
            case .check: return ISFTest.Step.check.iconName
            case .settle: return ISFTest.Step.settle.iconName
            case .dose: return ISFTest.Step.dose.iconName
            case .wait: return ISFTest.Step.wait.iconName
            case .result: return ISFTest.Step.result.iconName
            }
        }
    }
}
