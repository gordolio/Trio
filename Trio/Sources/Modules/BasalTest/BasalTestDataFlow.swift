import Foundation

enum BasalTest {
    enum Config {
        /// The docs' smallest basal change, as a share of the scheduled basal: "Make gradual adjustments
        /// (typically 10-20% changes)". Glucose drift worth less than this over the fast counts as steady.
        static let docsSmallestStep: Decimal = 0.10
        /// The docs' shortest fast: "Fast for 4-6 hours". Ending sooner can't say anything.
        static let docsShortestFast: TimeInterval = 4 * 3600
        /// Carbs this recent mean the fast hasn't started.
        static let fastBeforeStart: TimeInterval = 2 * 3600
        /// Length choices for the fast, in hours.
        static let durationChoices = [4, 5, 6]
        /// After the planned end, the test is closed automatically if the app was never opened.
        static let expiryGrace: TimeInterval = 30 * 60
        /// How far back to count SMBs given with no carbs on board: the Stats screen's "Week" period.
        static let smbLookback: TimeInterval = 7 * 24 * 3600
        /// How far back the trend row looks for the change in glucose.
        static let trendWindow: TimeInterval = 30 * 60
        /// How far from that point the reading it compares with may be: a CGM reads about every 5 minutes.
        static let trendTolerance: TimeInterval = 5 * 60
        static let statePath = "trio/basal_test_state.json"
    }

    /// The Trio docs passages the screens rest on, copied word for word (the docs' arrows and punctuation
    /// included), and the pages they come from.
    enum Docs {
        static let fastingTests = URL(string: "https://triodocs.org/usage/concepts/basal-rates/#1-fasting-tests")!
        static let iobPatterns = URL(string: "https://triodocs.org/usage/concepts/basal-rates/#2-monitor-your-iob-patterns")!
        static let adjustmentSize = URL(
            string: "https://triodocs.org/usage/concepts/basal-rates/#starting-point-for-new-users"
        )!
        static let overrides = URL(string: "https://triodocs.org/usage/features/overrides/")!
        static let tempTargets = URL(string: "https://triodocs.org/usage/features/temp-targets/")!

        // Each link is named for its page, so two on one screen can be told apart.
        static var fastingTestsLink: SettingsTestDocsLink {
            SettingsTestDocsLink(title: String(localized: "Fasting tests in Trio docs"), url: fastingTests)
        }

        static var iobPatternsLink: SettingsTestDocsLink {
            SettingsTestDocsLink(title: String(localized: "IOB patterns in Trio docs"), url: iobPatterns)
        }

        static var adjustingBasalLink: SettingsTestDocsLink {
            SettingsTestDocsLink(title: String(localized: "Adjusting basal in Trio docs"), url: adjustmentSize)
        }

        static var overridesLink: SettingsTestDocsLink {
            SettingsTestDocsLink(title: String(localized: "Overrides in Trio docs"), url: overrides)
        }

        static var tempTargetsLink: SettingsTestDocsLink {
            SettingsTestDocsLink(title: String(localized: "Temp Targets in Trio docs"), url: tempTargets)
        }

        // Fasting tests
        static let fastingRule = "Fast for 4-6 hours (no food at least 2 hours before starting)"
        static let steadyGlucose = "Steady glucose: Basal rate is accurate"
        static let risingGlucose = "Rising glucose: Basal rate is too low (increase it)"
        static let fallingGlucose = "Falling glucose: Basal rate is too high (decrease it)"
        static let testTimesOfDaySeparately =
            "Test different times of day separately, as your basal needs vary throughout the day."

        // Monitor your IOB patterns
        static let iobNotEating =
            "Review your insulin on board (IOB) throughout the day when you're not eating and have no residual COB"
        static let iobAroundZero = "IOB hovering around zero → Basal rate is appropriate"
        static let iobPositive = "Consistently positive IOB at certain times → Basal rate may be too low for those hours"

        // Starting point for new users
        static let gradualAdjustments = "Make gradual adjustments (typically 10-20% changes)"
        static let waitBetweenAdjustments = "Wait several days between adjustments to see the full effect"

        // Overrides and temp targets
        static let overridesChangeSettings = "Overrides adjust your core profile settings."
        static let tempTargetsChangeInsulin = "Temp targets can be used to increase or decrease insulin delivery."
    }

    enum Step: Int, CaseIterable, SettingsTestStep {
        case check
        case fast
        case result

        var order: Int { rawValue }

        var title: String {
            switch self {
            case .check: return String(localized: "Check")
            case .fast: return String(localized: "Fast")
            case .result: return String(localized: "Result")
            }
        }

        var iconName: String {
            switch self {
            case .check: return "checklist"
            case .fast: return "timer"
            case .result: return "chart.line.uptrend.xyaxis"
            }
        }
    }
}

protocol BasalTestProvider {}
