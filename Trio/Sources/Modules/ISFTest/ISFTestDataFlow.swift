import Foundation

enum ISFTest {
    enum Config {
        /// The docs' smallest ISF change, as a share of the ISF: "Make small changes: Adjust by 5-10% at a time". A
        /// drop per unit within this much of the ISF counts as accurate.
        static let docsSmallestStep: Decimal = 0.05
        /// The docs' wait after the correction bolus: "Wait 4 hours without eating or exercising". Ending sooner can't
        /// say anything.
        static let docsWait: TimeInterval = 4 * 3600
        /// The glucose the docs say to start from, in mg/dL: "When you're "stuck" above target (around 150 mg/dL or
        /// 8.3 mmol/L) or by bringing yourself to a higher glucose with glucose tabs".
        static let docsStartAim = 150
        /// How long after starting the bolus may come, long enough for glucose tablets to raise glucose and level off.
        /// An app limit, not a treatment rule. If no bolus comes in time, the test ends with nothing saved.
        static let doseAllowance: TimeInterval = 90 * 60
        /// How long after Begin a determination must be for Trio to have made it in Basal Testing: a loop already running
        /// when Begin switched the mode read the settings from before. An app limit, not a treatment rule.
        static let settleLoopMargin: TimeInterval = 60
        /// How long settling waits for insulin on board to come under the test's line before it asks whether to count it
        /// and go on, or cancel. An app limit, not a treatment rule. It never ends the test on its own.
        static let settleAllowance: TimeInterval = 60 * 60
        /// How many CGM readings the dose glucose averages (`BasalTestEvaluator.endGlucose`): also what the tablets are
        /// judged to have acted on (`ISFTestEvaluator.tabletsActed`).
        static let meanReadings = 3
        /// How many CGM readings settling waits for after Trio's first loop in Basal Testing: the 3 the dose glucose
        /// averages, so it and the CGM's arrow come from readings with SMBs off. Not a new number: the mean the dose
        /// already uses.
        static let settleReadings = meanReadings
        /// After the planned end, the test is closed automatically if the app was never opened.
        static let expiryGrace: TimeInterval = 30 * 60
        /// How much of the chart before the 4 hours are up the Result screen shades with the expected end, so the band
        /// sits where the expected end applies. Display only.
        static let expectedEndShading: TimeInterval = 30 * 60
        /// How far apart a date saved in the test's state and a timestamp from the history can be and still be the same
        /// moment. The state file keeps whole milliseconds and the pump history microseconds, so the test bolus read
        /// back can be a fraction of a millisecond either side of the `bolusAt` saved for it. Two manual boluses can't
        /// be this close.
        static let savedDateTolerance: TimeInterval = 1
        static let statePath = "trio/isf_test_state.json"
    }

    /// The Trio docs passages the screens rest on, copied word for word (the docs' arrows and punctuation
    /// included), and the pages they come from.
    enum Docs {
        static let testingMethod = URL(string: "https://triodocs.org/usage/concepts/isf/#testing-method")!
        static let bestPractices = URL(string: "https://triodocs.org/usage/concepts/isf/#best-practices")!
        static let recommendedBolusPercentage = URL(
            string: "https://triodocs.org/configuration/settings/features/bolus-calculator/#recommended-bolus-percentage"
        )!
        static let whyBasalRatesMatter = URL(string: "https://triodocs.org/usage/concepts/basal-rates/#why-basal-rates-matter")!
        static let bolusCalculator = URL(string: "https://triodocs.org/usage/concepts/isf/#bolus-calculator")!

        // Each link is named for its page, so two on one screen can be told apart.
        static var testingMethodLink: SettingsTestDocsLink {
            SettingsTestDocsLink(title: String(localized: "ISF testing method in Trio docs"), url: testingMethod)
        }

        static var bestPracticesLink: SettingsTestDocsLink {
            SettingsTestDocsLink(title: String(localized: "ISF best practices in Trio docs"), url: bestPractices)
        }

        static var recommendedBolusPercentageLink: SettingsTestDocsLink {
            SettingsTestDocsLink(
                title: String(localized: "Recommended Bolus Percentage in Trio docs"),
                url: recommendedBolusPercentage
            )
        }

        static var bolusCalculatorLink: SettingsTestDocsLink {
            SettingsTestDocsLink(title: String(localized: "ISF in the bolus calculator in Trio docs"), url: bolusCalculator)
        }

        static var whyBasalRatesMatterLink: SettingsTestDocsLink {
            SettingsTestDocsLink(title: String(localized: "Why basal rates matter in Trio docs"), url: whyBasalRatesMatter)
        }

        // Testing method (isf.md)
        static let chooseTestingTime =
            "When you're \"stuck\" above target (around 150 mg/dL or 8.3 mmol/L) or by bringing yourself to a higher glucose with glucose tabs"
        static let correctionBolus = "Give a correction bolus based on your current ISF"
        static let waitFourHours = "Wait 4 hours without eating or exercising"
        static let stillAboveTarget =
            "Still above target after 4 hours: ISF is too high (too conservative) → DECREASE the ISF value"
        static let belowTarget = "Below target after 4 hours: ISF is too low (too aggressive) → INCREASE the ISF value"
        static let atTarget = "At target after 4 hours: ISF is accurate"

        // Bolus calculator (isf.md), the formula written out in text
        static let bolusCalculatorFormula =
            "Total Insulin = (Current BG − Target BG) ÷ ISF + Carbs ÷ CR + Trend Correction − IOB"

        // Best practices (isf.md)
        static let smallChanges = "Make small changes: Adjust by 5-10% at a time"
        static let waitBetweenChanges = "Wait between changes: Give each adjustment 2-3 days to see the full effect"
        static let testSystematically = "Test systematically: Test one time period at a time"

        // Carb ratios (carb-ratios.md)
        static let testISFWhenFasting = "Test ISF with correction boluses when fasting (no COB)"

        // Basal rates (basal-rates.md, "Basal is Key")
        static let basalFirst =
            "Basal rates are the foundation of the Trio algorithm. Before testing any other core settings, ensure your basal rates are set appropriately."
    }

    enum Step: Int, CaseIterable, SettingsTestStep {
        case check
        case settle
        case raise
        case dose
        case wait
        case result

        var order: Int { rawValue }

        var title: String {
            switch self {
            case .check: return String(localized: "Check")
            case .settle: return String(localized: "Settle")
            case .raise: return String(localized: "Raise")
            case .dose: return String(localized: "Dose")
            case .wait: return String(localized: "Wait")
            case .result: return String(localized: "Result")
            }
        }

        var iconName: String {
            switch self {
            case .check: return "checklist"
            case .settle: return "hourglass"
            case .raise: return "arrow.up.circle"
            case .dose: return "syringe"
            case .wait: return "timer"
            case .result: return "chart.line.uptrend.xyaxis"
            }
        }
    }
}

/// What the ISF screen reads for its steps, beside the runner's state (`StateModel.refresh`). `ISFTest.Provider` conforms;
/// a test gives the state model its own (`StateModel.screenReads`).
protocol ISFTestProvider: AnyObject {
    func isfEntries() -> [SettingsTestScheduleEntry]
    func basalEntries() -> [SettingsTestScheduleEntry]
    func isf(at date: Date) -> Decimal?
    func target(at date: Date) -> Decimal?
    /// Newest first.
    func fetchRecentGlucose(minutes: Int) async throws -> [BasalTestReading]
    func currentIOB() -> Decimal?
    func currentCOB() async throws -> Decimal?
    func hasActiveAdjustment() async throws -> Bool
    func hasPumpSetTempBasal() -> Bool
    func pumpDelivery() -> ISFTestPumpDelivery?
    func hasCgmAndPump() -> Bool
    func fetchNewestDirection() async throws -> BloodGlucose.Direction?
}
