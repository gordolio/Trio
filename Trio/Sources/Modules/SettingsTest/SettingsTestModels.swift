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
        case .basal,
             .isf: return .available
        case .carbRatio: return .beingRebuilt
        }
    }
}

extension SettingsTestKind {
    /// What the hub says on the sensitivity row when the newest basal test doesn't show steady basal, or nil when it
    /// does. The same words as the ISF test's Check screen (`ISFTestEvaluator.basalGateText`), then a line saying it is
    /// a warning only: the test is never locked.
    static func isfGateNote(
        for gate: SettingsTestSchedule.BasalGate,
        now: Date = Date(),
        locale: Locale = .autoupdatingCurrent
    ) -> String? {
        if case .ready = gate { return nil }
        let text = ISFTestEvaluator.basalGateText(gate, now: now, locale: locale)
        return String(localized: "\(text). You can still start.")
    }

    /// An insulin sensitivity in mg/dL per unit as the hub lists it, in the user's units, e.g. "50 mg/dL/U". The unit
    /// never breaks across lines.
    static func isfText(_ mgdl: Decimal, units: GlucoseUnits, locale: Locale = .autoupdatingCurrent) -> String {
        SettingsTestFormat.keepTogether(mgdl.formattedISF(for: units, locale: locale), unit: "\(units.rawValue)/U")
    }

    /// What a time period row says about the newest test of this kind over it. Basal reads as it always has; for
    /// sensitivity, a drop that fell short of the ISF means the number is too high, and one that overshot means it is
    /// too low. `relative` words a date, e.g. "3 days ago".
    func periodStatusText(
        for period: SettingsTestPeriod,
        relative: (Date) -> String = { $0.formatted(.relative(presentation: .named)) }
    ) -> String {
        guard let lastTest = period.lastTest, let direction = period.lastDirection else {
            return String(localized: "Not tested yet")
        }
        if period.changedSince { return String(localized: "Changed since the last test") }
        let when = relative(lastTest)
        switch (self, direction) {
        case (.basal, .keep): return String(localized: "Steady \(when)")
        case (.basal, .increase): return String(localized: "Basal looked too low \(when)")
        case (.basal, .decrease): return String(localized: "Basal looked too high \(when)")
        case (.isf, .keep): return String(localized: "Looked accurate \(when)")
        case (.isf, .increase): return String(localized: "ISF looked too low \(when)")
        case (.isf, .decrease): return String(localized: "ISF looked too high \(when)")
        // The carb ratio test is being rebuilt and lists no periods, so these are never shown.
        case (.carbRatio, .keep): return String(localized: "Looked accurate \(when)")
        case (.carbRatio, .increase): return String(localized: "Carb ratio looked too low \(when)")
        case (.carbRatio, .decrease): return String(localized: "Carb ratio looked too high \(when)")
        }
    }

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

    /// The dosing mode to put back as this action's session ends, with `current` the mode in force then: the previous
    /// mode while the test's mode is on, however it got there (never left, or left and picked again before the end), and
    /// nil while any other mode is on, because the user chose it. Every end path uses it: the service's watchdog, its
    /// expiry, ending by kind, and a screen ending a session the service lost.
    func modeToRestore(current: DosingMode) -> DosingMode? {
        switch self {
        case let .dosingMode(testMode, previous):
            return current == testMode && previous != testMode ? previous : nil
        }
    }
}

/// What a test's screens say about the dosing mode once its session has ended.
enum SettingsTestModeRule {
    /// Whether Basal Testing is on with no test running it, so a Result says so ("Basal Testing is still on…") rather
    /// than that the usual dosing came back.
    static func basalTestingLeftOn(mode: DosingMode, activeSessionID: UUID?) -> Bool {
        mode == .basalTesting && activeSessionID == nil
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
    /// For an ISF test, when its bolus window began: the end of settling, from which the test bolus is looked for. Nil
    /// while it settles, and in a session saved before this was kept.
    var bolusWindowStart: Date?
    /// True for an ISF session begun with settling. Nil for other tests, and for an ISF session saved before settling
    /// was kept, whose bolus window starts at Start.
    var settles: Bool?

    /// Where the bolus window starts in effect: the end of settling once it is kept, nil while a session that settles
    /// still does, and Start for a session from before settling was kept.
    var bolusWindowStartInEffect: Date? {
        bolusWindowStart ?? (settles == true ? nil : startedAt)
    }
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
    /// A bolus was given that the test did not ask for.
    case extraBolus
    /// No bolus came in the time allowed for one. An ISF test only: a basal test asks for none.
    case noBolus
    /// The user picked another dosing mode during the test, with no low before it. The session's end put the usual mode
    /// back only if Basal Testing was on again by then (`SettingsTestEnd.modeRestored`).
    case modeChanged
    /// The pump was suspended, gave an alarm, or had its site or reservoir changed during the test. An ISF test only for
    /// now.
    case pumpInterrupted
}

/// What the service keeps when it ends a test on its own, so the test's screen, opened later, finishes it for the same
/// reason. By then the usual dosing mode is back, and without this a mode the user changed couldn't be told from a low.
struct SettingsTestEnd: JSON, Equatable {
    var sessionID: UUID
    var cause: SettingsTestEndCause
    /// For a low, when Trio first suspended; for a second bolus, when it was given; for no bolus, when the time for
    /// one ran out; for carbs, logged or unreadable, when the service found that and brought the usual dosing back; for
    /// basal stopped, when it was stopped; for a mode changed, when another mode was first picked; for the pump, when it
    /// was first suspended, alarmed or changed.
    var date: Date
    /// For a mode change, whether ending the session put the usual mode back, because Basal Testing was on again by then
    /// (`SettingsTestRestoreAction.modeToRestore`). Nil for other causes, and in a record saved before this was kept.
    var modeRestored: Bool? = nil
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
    /// The bolus the test gave, in units. Nil for a test with no bolus, and for one saved before this was kept.
    var bolusUnits: Decimal? = nil
    /// The grams of fast carbs taken as tablets to raise glucose before the bolus. Nil when none were taken, and for a
    /// test saved before this was kept. Not logged as carbs.
    var tabletCarbs: Decimal? = nil
    /// How an ISF test handled insulin on board over its line at Begin, `ISFTestIOBHandling.rawValue` ("wait" or
    /// "count"). Nil when there was no choice to make, for other tests, and for a test saved before this was kept.
    var iobHandling: String? = nil
    /// The insulin on board at the bolus that an ISF test added to the units it judged by, signed. Nil when it counted
    /// none, and for a test saved before this was kept.
    var iobCounted: Decimal? = nil
    /// The units an ISF test judged by (`ISFTestEvaluator.judgedUnits`): the bolus, with any insulin on board it
    /// counted, less what Trio reported still on board at the end of the 4 hours. Nil for a low, which isn't judged on
    /// them, for other tests, and for a test saved before this was kept.
    var judgedUnits: Decimal? = nil
}

// The carb ratio wizard uses the shared step bar.
extension CarbRatioCalibration.Step: SettingsTestStep {
    var order: Int { rawValue }
}
