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

    /// Whether the hub can open this test.
    var availability: SettingsTestAvailability {
        switch self {
        case .basal: return .available
        case .isf: return .comingSoon
        case .carbRatio: return .beingRebuilt
        }
    }
}

extension SettingsTestKind {
    /// Whether the old carb ratio wizard has a test under way that only its own screen can finish: from its prep, when
    /// its SMB-off override goes on, until the result is completed. A cancelled or timed-out test left on disk counts
    /// too, because opening the screen is what turns the override off and clears it.
    static func carbRatioTestInProgress(_ phase: CalibrationPhase?) -> Bool {
        switch phase {
        case .awaitingTabletConfirmation,
             .bolusDelivered,
             .cancelled,
             .observing,
             .prepping,
             .readyToTest,
             .resultsReady,
             .timedOut:
            return true
        case .completed,
             nil,
             .notStarted,
             .preflightChecking,
             .preflightFailed,
             .preflightPassed:
            return false
        }
    }
}

/// Whether a test can be opened from the hub, and if not, why.
enum SettingsTestAvailability: Equatable {
    case available
    /// There is no wizard for it yet.
    case comingSoon
    /// It had a wizard that is being rebuilt.
    case beingRebuilt
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

    /// Whether this is the switch to Basal Testing, the change a low or logged carbs undo.
    var switchesToBasalTesting: Bool {
        switch self {
        case let .dosingMode(testMode, _): return testMode == .basalTesting
        }
    }
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
    /// When a session that switched to Basal Testing first saw another mode picked. Nil while it hasn't, and in a
    /// session saved before this was kept.
    var leftTestModeAt: Date?
}

/// Why the service ended a running test on its own.
enum SettingsTestEndCause: String, JSON, Equatable {
    /// Trio suspended insulin for a low.
    case low
    /// Carbs were logged.
    case carbsLogged
    /// Basal was stopped, and none of Trio's determinations asked for it, so it wasn't Trio's suspend for a low.
    case basalStopped
    /// Carbs couldn't be read, so it couldn't be told whether food was eaten.
    case carbsUnreadable
}

/// What the service keeps when it ends a test on its own, so the test's screen, opened later, finishes it for the same
/// reason. By then the usual dosing mode is back, and without this a mode the user changed couldn't be told from a low.
struct SettingsTestEnd: JSON, Equatable {
    var sessionID: UUID
    var cause: SettingsTestEndCause
    /// For a low, when Trio first suspended; for carbs, logged or unreadable, when the service found that and brought the
    /// usual dosing back; for basal stopped, when it was stopped.
    var date: Date
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
    /// The schedule entries the test's time window covered, as they were when the test ran. Nil for a
    /// test saved before this was kept, and for tests of settings that aren't a schedule.
    var coveredEntries: [SettingsTestScheduleEntry]? = nil
}

// The carb ratio wizard uses the shared step bar.
extension CarbRatioCalibration.Step: SettingsTestStep {
    var order: Int { rawValue }
}
