import Foundation

/// Represents the current state of a carb ratio calibration test
struct CalibrationTestState: JSON, Equatable {
    var id = UUID()
    var phase: CalibrationPhase = .notStarted
    var preflightStartDate: Date?
    var startDate: Date?
    var prepStartDate: Date?
    var testStartDate: Date?
    var observationEndDate: Date?

    // Override created during calibration (persisted in Core Data)
    var calibrationOverrideID: String?

    // Test parameters
    var tabletBrand: String = GlucoseTabletBrand.dex4.rawValue
    var tabletCount: Int = GlucoseTabletBrand.dex4.recommendedCount
    var totalCarbs: Decimal = GlucoseTabletBrand.dex4.totalCarbs(for: GlucoseTabletBrand.dex4.recommendedCount)
    var carbRatioAtTestTime: Decimal = 0
    var bolusAmount: Decimal = 0
    var startingGlucose: Int = 0
    var startingIOB: Decimal = 0

    // Collected glucose readings during test
    var glucoseReadings: [CalibrationGlucoseReading] = []

    // Results
    var endingGlucose: Int?
    var resultInterpretation: CalibrationResult?
    var suggestedNewRatio: Decimal?

    /// Whether the user applied the suggested ratio change (vs. dismissing)
    var ratioWasApplied: Bool = false
}

/// Individual glucose reading captured during calibration test
struct CalibrationGlucoseReading: JSON, Equatable, Identifiable {
    var id = UUID()
    let date: Date
    let glucose: Int
}

/// Current phase of the calibration test workflow
enum CalibrationPhase: String, JSON, CaseIterable, Equatable {
    case notStarted
    case preflightChecking
    case preflightFailed
    case preflightPassed
    case prepping
    case readyToTest
    case awaitingTabletConfirmation
    case bolusDelivered
    case observing
    case resultsReady
    case completed
    case cancelled
    case timedOut

    var displayName: String {
        switch self {
        case .notStarted: return String(localized: "Not Started")
        case .preflightChecking: return String(localized: "Checking Conditions")
        case .preflightFailed: return String(localized: "Conditions Not Met")
        case .preflightPassed: return String(localized: "Ready to Begin")
        case .prepping: return String(localized: "Preparing")
        case .readyToTest: return String(localized: "Ready to Test")
        case .awaitingTabletConfirmation: return String(localized: "Take Tablets")
        case .bolusDelivered: return String(localized: "Bolus Delivered")
        case .observing: return String(localized: "Observing")
        case .resultsReady: return String(localized: "Results Ready")
        case .completed: return String(localized: "Completed")
        case .cancelled: return String(localized: "Cancelled")
        case .timedOut: return String(localized: "Timed Out")
        }
    }

    var isActive: Bool {
        switch self {
        case .awaitingTabletConfirmation,
             .bolusDelivered,
             .observing,
             .prepping,
             .readyToTest:
            return true
        default:
            return false
        }
    }
}

/// Result interpretation after calibration test completes
enum CalibrationResult: String, JSON, Equatable {
    case ratioCorrect
    case ratioTooWeak
    case ratioTooStrong

    var displayName: String {
        switch self {
        case .ratioCorrect:
            return String(localized: "Your carb ratio is correct!")
        case .ratioTooWeak:
            return String(localized: "Ratio too weak (need more insulin per gram)")
        case .ratioTooStrong:
            return String(localized: "Ratio too strong (need less insulin per gram)")
        }
    }

    var explanation: String {
        switch self {
        case .ratioCorrect:
            return String(
                localized: "Your blood glucose stayed within the expected range. No adjustment needed."
            )
        case .ratioTooWeak:
            return String(
                localized: "Your blood glucose rose more than expected. Consider lowering your carb ratio (g/U) to deliver more insulin per gram of carbs."
            )
        case .ratioTooStrong:
            return String(
                localized: "Your blood glucose dropped more than expected. Consider raising your carb ratio (g/U) to deliver less insulin per gram of carbs."
            )
        }
    }
}

// MARK: - Codable

extension CalibrationTestState {
    private enum CodingKeys: String, CodingKey {
        case id
        case phase
        case preflightStartDate
        case startDate
        case prepStartDate
        case testStartDate
        case observationEndDate
        case calibrationOverrideID
        case tabletBrand
        case tabletCount
        case totalCarbs
        case carbRatioAtTestTime
        case bolusAmount
        case startingGlucose
        case startingIOB
        case glucoseReadings
        case endingGlucose
        case resultInterpretation
        case suggestedNewRatio
        case ratioWasApplied
    }
}

extension CalibrationGlucoseReading {
    private enum CodingKeys: String, CodingKey {
        case id
        case date
        case glucose
    }
}
