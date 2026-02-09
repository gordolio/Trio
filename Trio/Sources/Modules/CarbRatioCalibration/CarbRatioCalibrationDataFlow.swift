import Foundation

enum CarbRatioCalibration {
    /// Wizard steps for the calibration flow
    enum Step: Int, CaseIterable, Identifiable {
        case preflight = 0
        case prep
        case test
        case observation
        case results

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .preflight: return String(localized: "Check")
            case .prep: return String(localized: "Prep")
            case .test: return String(localized: "Test")
            case .observation: return String(localized: "Watch")
            case .results: return String(localized: "Result")
            }
        }

        var description: String {
            switch self {
            case .preflight:
                return String(localized: "Checking if conditions are right for calibration")
            case .prep:
                return String(localized: "Preparing for the test")
            case .test:
                return String(localized: "Take glucose tablets and deliver bolus")
            case .observation:
                return String(localized: "Monitoring glucose response")
            case .results:
                return String(localized: "Review your results")
            }
        }

        var iconName: String {
            switch self {
            case .preflight: return "checklist"
            case .prep: return "gearshape"
            case .test: return "pill.fill"
            case .observation: return "timer"
            case .results: return "chart.line.uptrend.xyaxis"
            }
        }
    }

    /// Options for applying ratio changes
    enum RatioUpdateOption: Identifiable {
        case currentSlotOnly(timeRange: String)
        case allSlots
        case selectSlots

        var id: String {
            switch self {
            case .currentSlotOnly: return "current"
            case .allSlots: return "all"
            case .selectSlots: return "select"
            }
        }

        var title: String {
            switch self {
            case let .currentSlotOnly(timeRange):
                return String(localized: "Current time slot only (\(timeRange))")
            case .allSlots:
                return String(localized: "All time slots (adjust proportionally)")
            case .selectSlots:
                return String(localized: "Select specific slots...")
            }
        }
    }
}

protocol CarbRatioCalibrationProvider: Provider {}
