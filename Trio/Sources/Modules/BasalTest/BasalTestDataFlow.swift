import Foundation

enum BasalTest {
    enum Config {
        /// Net change in glucose over the test that still counts as steady, in mg/dL.
        static let steadyTolerance = 20
        /// The test ends and normal dosing returns if glucose drops below this, in mg/dL.
        static let lowStop = 70
        /// Past this the result is already clear, so the user is offered an early end, in mg/dL.
        static let highSuggestEnd = 250
        /// Start glucose has to sit in this range, in mg/dL.
        static let startRange = 90 ... 180
        /// Carbs this recent mean the fast hasn't started.
        static let fastBeforeStart: TimeInterval = 2 * 3600
        /// Insulin on board above this means a recent dose is still acting, in units.
        static let maxStartIOB: Decimal = 0.3
        /// Length choices for the fast, in hours.
        static let durationChoices = [4, 5, 6]
        /// After the planned end, the test is closed automatically if the app was never opened.
        static let expiryGrace: TimeInterval = 30 * 60
        static let statePath = "trio/basal_test_state.json"
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
