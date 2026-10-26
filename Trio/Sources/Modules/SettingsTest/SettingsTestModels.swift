import Foundation

/// The core settings a guided test can check.
enum SettingsTestKind: String, JSON, CaseIterable, Identifiable {
    case basal
    case isf
    case carbRatio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .carbRatio: return String(localized: "Carb Ratio")
        case .basal: return String(localized: "Basal Rates")
        case .isf: return String(localized: "Insulin Sensitivity")
        }
    }

    var icon: String {
        switch self {
        case .carbRatio: return "fork.knife"
        case .basal: return "waveform.path.ecg"
        case .isf: return "drop.fill"
        }
    }

    var summary: String {
        switch self {
        case .carbRatio:
            return String(localized: "Take a known amount of fast carbs with a matching bolus and see where glucose ends up.")
        case .basal:
            return String(localized: "Fast without Trio's adjustments and see whether glucose stays steady.")
        case .isf:
            return String(localized: "Give a correction dose from a steady high and see where glucose lands.")
        }
    }

    /// Tests that have a guided wizard today.
    var isAvailable: Bool {
        switch self {
        case .basal,
             .carbRatio: return true
        case .isf: return false
        }
    }
}

/// What a test result says the setting's number should do. Never an amount: the wizard
/// suggests a direction and the user decides what to change.
enum SettingsTestDirection: String, JSON, Equatable {
    case increase
    case decrease
    case keep
}

/// Something a test changed temporarily, and how to put it back.
enum SettingsTestRestoreAction: JSON, Equatable {
    /// The test switched the dosing mode to `testMode`. Put back `previous`, but only if the mode
    /// is still `testMode`, so a mode the user chose on their own is left alone.
    case dosingMode(testMode: DosingMode, previous: DosingMode)
}

/// A running test that has changed something temporarily. Persisted so the change can be undone
/// after a relaunch, or when the test runs past its deadline.
struct SettingsTestSession: JSON, Equatable, Identifiable {
    var id = UUID()
    var kind: SettingsTestKind
    var startedAt = Date()
    /// After this, the temporary changes are undone even if the user never comes back.
    var expiresAt: Date
    var restore: [SettingsTestRestoreAction]
}

/// A finished test, kept so results can be compared over time.
struct SettingsTestRecord: JSON, Equatable, Identifiable {
    var id = UUID()
    var kind: SettingsTestKind
    var startedAt: Date
    var completedAt: Date
    /// Which part of the day the test covered, e.g. "Overnight".
    var timeBlock: String?
    /// mg/dL
    var startGlucose: Int
    /// mg/dL
    var endGlucose: Int
    var direction: SettingsTestDirection
    var summary: String
    /// Whether the user changed the setting after seeing the result.
    var applied: Bool = false
}

// The carb ratio wizard uses the shared step bar.
extension CarbRatioCalibration.Step: SettingsTestStep {
    var order: Int { rawValue }
}
