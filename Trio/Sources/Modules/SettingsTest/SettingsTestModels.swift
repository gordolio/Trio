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
             .carbRatio,
             .isf: return .available
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

    /// What the hub says on the carb ratio row when the newest ISF test doesn't look accurate on an unchanged ISF
    /// schedule, or nil when it does. The same words as the carb ratio test's Check screen (`ISFGate.text`), then a line
    /// saying it is a warning only: the test is never locked.
    static func carbRatioGateNote(
        for gate: SettingsTestSchedule.ISFGate,
        now: Date = Date(),
        locale: Locale = .autoupdatingCurrent
    ) -> String? {
        if case .ready = gate { return nil }
        return String(localized: "\(gate.text(now: now, locale: locale)). You can still start.")
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
        // A ratio that looked too high means glucose ended high: the docs say decrease it.
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

extension SettingsTestSchedule.ISFGate {
    /// What the newest ISF test says, in the carb ratio test's Check screen's words, as `ISFTestEvaluator.basalGateText`
    /// says it of the newest basal test.
    func text(now: Date = Date(), locale: Locale = .autoupdatingCurrent) -> String {
        switch self {
        case let .ready(lastAccurate):
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.dateTimeStyle = .named
            let when = formatter.localizedString(for: lastAccurate, relativeTo: now)
            return String(localized: "Last ISF test looked accurate, \(when)")
        case .noAccurateTest:
            return String(localized: "No accurate ISF test yet")
        case .changedSince:
            return String(localized: "ISF changed since the last test")
        case let .lastWasNot(direction, _):
            switch direction {
            case .increase: return String(localized: "The last ISF test said ISF looks too low")
            case .decrease: return String(localized: "The last ISF test said ISF looks too high")
            case .keep: return String(localized: "No accurate ISF test yet")
            }
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
    /// expiry, ending by kind, and a runner ending a session the service lost.
    func modeToRestore(current: DosingMode) -> DosingMode? {
        switch self {
        case let .dosingMode(testMode, previous):
            return current == testMode && previous != testMode ? previous : nil
        }
    }
}

/// What a test's screen says, and its runner does, about the dosing mode once its session has ended.
enum SettingsTestModeRule {
    /// Whether Basal Testing is on with no test running it, so a Result says so ("Basal Testing is still on…") rather
    /// than that the usual dosing came back.
    static func basalTestingLeftOn(mode: DosingMode, activeSessionID: UUID?) -> Bool {
        mode == .basalTesting && activeSessionID == nil
    }

    /// The dosing mode a test's runner puts back itself as it ends the test, or nil to leave it: only while Basal
    /// Testing is still on and the test's session is lost, with no session running and no end of it kept by the service
    /// (`lastEndSessionID`), so nothing else will bring the usual mode back. A session that runs puts its own back (or,
    /// another test's, owns Basal Testing); one the service ended put it back then, or, once the user had picked a mode
    /// of their own, left it theirs (`SettingsTestEndCause.modeChanged`). A test with no session ID is one whose Begin
    /// didn't save it with its session: only Begin turns Basal Testing on for a test, so with it on and no session
    /// running, the usual mode comes back too.
    static func modeToRestore(
        mode: DosingMode,
        testSessionID: UUID?,
        activeSessionID: UUID?,
        lastEndSessionID: UUID?,
        previousMode: DosingMode
    ) -> DosingMode? {
        guard activeSessionID == nil else { return nil }
        if let testSessionID, lastEndSessionID == testSessionID { return nil }
        // The rule every end path uses: Basal Testing on, the usual mode comes back; any other mode is the user's.
        return SettingsTestRestoreAction.dosingMode(testMode: .basalTesting, previous: previousMode).modeToRestore(current: mode)
    }

    /// Whether a running test is ending, so its step takes none of its actions: its ending is saved (`hasPendingEnd`), or
    /// its session no longer runs, ended by the service, at its expiry or by another test's, while its runner's finish is
    /// still to come. Not a lost session that the runner's own end would put the usual mode back for (`modeToRestore`):
    /// nothing else ends that test soon, and Cancel Test or End Test is the user's way back. `session` is nil while the
    /// screen hasn't read the service's session, which then leaves only the saved ending to go by.
    static func isEnding(
        hasPendingEnd: Bool,
        isRunning: Bool,
        testSessionID: UUID?,
        session: (activeID: UUID?, lastEndID: UUID?)?,
        mode: DosingMode,
        previousMode: DosingMode
    ) -> Bool {
        guard isRunning else { return false }
        if hasPendingEnd { return true }
        guard let session else { return false }
        if let testSessionID, session.activeID == testSessionID { return false }
        return modeToRestore(
            mode: mode,
            testSessionID: testSessionID,
            activeSessionID: session.activeID,
            lastEndSessionID: session.lastEndID,
            previousMode: previousMode
        ) == nil
    }
}

/// A carb entry as the settings tests read it: which one it is, by its Core Data object ID, and when the carbs were
/// eaten.
struct SettingsTestCarbEntry: Equatable {
    let id: String
    let date: Date
}

/// Which carb entries spoil a running test. An entry is dated by when the carbs were eaten, and has no time it was
/// logged, so one logged during the test with an earlier time ("15 minutes earlier", the time picker) can only be told
/// from one that was there at Begin by the entries Begin kept (`keptAtBegin`).
enum SettingsTestCarbRule {
    /// How far before Begin the entries Begin keeps are dated, and so how far before it an entry logged during the test
    /// can be dated and still end it.
    static let lookback: TimeInterval = 24 * 3600

    /// What Begin keeps: the IDs of the entries dated in the `lookback` up to it.
    static func keptAtBegin(_ entries: [SettingsTestCarbEntry]) -> [String] {
        entries.map(\.id).sorted()
    }

    /// Where a check reads carb entries from, for a test begun at `startedAt`: the `lookback` before it, or Begin itself
    /// for a test that kept none (`kept` nil: saved before they were kept).
    static func readFrom(startedAt: Date, kept: [String]?) -> Date {
        kept == nil ? startedAt : startedAt.addingTimeInterval(-lookback)
    }

    /// Whether `entries`, read from `readFrom`, spoil a test begun at `startedAt`: any dated from Begin on, as before,
    /// and any dated in the `lookback` before it that wasn't there at Begin (`kept`).
    static func spoil(_ entries: [SettingsTestCarbEntry], startedAt: Date, kept: [String]?) -> Bool {
        let there = Set(kept ?? [])
        let earliest = startedAt.addingTimeInterval(-lookback)
        return entries.contains { entry in
            entry.date >= startedAt || (kept != nil && entry.date >= earliest && !there.contains(entry.id))
        }
    }
}

/// When a runner ends a test.
enum SettingsTestEndRule {
    /// When a finish ends the test: `endedAt` when a check gave one, now otherwise, never after `limit` (the planned end,
    /// or the no-bolus deadline before the bolus) and never after now, so a test never ends in the future.
    static func endTime(endedAt: Date?, limit: Date, now: Date) -> Date {
        min(endedAt ?? now, limit, now)
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
    /// For an ISF or carb ratio test, when its bolus window began: the end of settling, from which the test bolus is
    /// looked for. Nil while it settles, and in a session saved before this was kept.
    var bolusWindowStart: Date?
    /// True for a session begun with settling: an ISF one, and every carb ratio one its runner begins. Nil for other
    /// tests, and for an ISF session saved before settling was kept, whose bolus window starts at Start.
    var settles: Bool?
    /// The carb entries there at Begin, dated in the day before it (`SettingsTestCarbRule.keptAtBegin`), so one logged
    /// during the test with an earlier time ends it. Nil in a session saved before they were kept, and in one begun
    /// without them, which reads carbs from Begin only.
    var carbsAtBegin: [String]?
    /// How long a test with a bolus runs after it: a carb ratio test's chosen length (`CarbRatioTest.Config.lengths`).
    /// Nil for the ISF test, whose wait is the docs' 4 hours (`ISFTest.Config.docsWait`), for other tests, and in a
    /// session saved before this was kept.
    var waitLength: TimeInterval?

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
    /// The pump was suspended, gave an alarm, or had its site or reservoir changed during the test.
    case pumpInterrupted
    /// A carb ratio test only: the meal's two halves, the tablets' carbs and the bolus, didn't come within
    /// `CarbRatioTest.Config.mealPairing` of each other (`CarbRatioTestEvaluator.mealPairingEnd`). Dated at the end of
    /// the pairing time from the first half. The other tests never get it, and read it as they read `noBolus`.
    case mealUnpaired
}

/// What the service keeps when it ends a test on its own, so the test's runner finishes it for the same reason. By then
/// the usual dosing mode is back, and without this a mode the user changed couldn't be told from a low.
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
    /// The grams of fast carbs taken as tablets: for an ISF test, to raise glucose before the bolus, not logged as carbs;
    /// for a carb ratio test, the tablets' planned grams, which the carbs logged (`testCarbs`) matched. Nil when none
    /// were taken, and for a test saved before this was kept.
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
    /// The grams the carb ratio test's bolus covered: the carb entry logged with it, which the result was judged on
    /// (`CarbRatioTestState.carbs`). Nil for other tests, and for a test saved before this was kept.
    var testCarbs: Decimal? = nil
}

// The carb ratio wizard uses the shared step bar.
extension CarbRatioCalibration.Step: SettingsTestStep {
    var order: Int { rawValue }
}
