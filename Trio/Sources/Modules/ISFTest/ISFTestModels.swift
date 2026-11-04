import Foundation

enum ISFTestEndReason: String, JSON, Equatable {
    /// The 4 hours were up.
    case completed
    /// The user ended it before the 4 hours were up.
    case endedEarly
    /// Trio suspended insulin for a low, so normal dosing came back.
    case low
    /// Something spoiled the test or left nothing to judge: carbs or another bolus were logged, carbs couldn't be read,
    /// Trio suspended insulin for a low before the dose, basal was stopped without Trio asking, the dosing mode changed,
    /// Trio didn't see the bolus in time, or the bolus was cancelled before any insulin was delivered.
    case interrupted
    /// The 4 hours were up, but the pump history couldn't be read to check for a low.
    case unchecked
    /// No bolus came in the time allowed for one, so there was nothing to judge.
    case noBolus
}

enum ISFTestOutcome: String, JSON, Equatable {
    /// Glucose came down by about what the ISF says: within the docs' smallest step.
    case accurate
    /// Glucose came down less than the ISF says, or rose: the ISF number is too high (too conservative).
    case tooHigh
    /// Glucose came down more than the ISF says: the ISF number is too low (too aggressive).
    case tooLow
    /// Ended too soon to say.
    case inconclusive
    /// Something happened after the bolus that makes the result unusable.
    case invalid

    /// Whether the result says anything about the ISF.
    var isConclusive: Bool {
        switch self {
        case .accurate,
             .tooHigh,
             .tooLow: return true
        case .inconclusive,
             .invalid: return false
        }
    }
}

/// A bolus from the pump history, whatever its SMB flag (`SettingsTestEvents.allBoluses`): what the test bolus is picked
/// from, and what makes a second one.
struct ISFTestBolus: Equatable {
    let date: Date
    /// Units. Zero when the history gave no amount.
    let units: Decimal
}

extension ISFTestBolus {
    /// A bolus as the pump history records it, or nil for one recorded at exactly 0 U: a bolus cancelled before
    /// anything was delivered gave no insulin, so it isn't one for the test, and cancelling a mistyped bolus and giving
    /// the right one mustn't count as two. One with no amount recorded still happened, so it still counts.
    init?(date: Date, amount: Decimal?) {
        if let amount, amount == 0 { return nil }
        self.init(date: date, units: amount ?? 0)
    }
}

/// A bolus row from the pump history as the test bolus is read again: any bolus, manual or flagged as an SMB, with the
/// amount it holds, 0 U included. The pump history can flag a manual bolus as an SMB when it writes the amount delivered
/// (a driver that leaves `automatic` unset), and Basal Testing gives no SMBs, so a bolus at the test bolus's moment is the
/// test bolus.
struct ISFTestBolusRecord: Equatable {
    let date: Date
    /// Units. Nil when the history records no amount.
    let amount: Decimal?
}

/// One of Trio's determinations, as settling and the count of insulin on board at the bolus read them: dated by when it
/// was due, or when it was made if that is missing, as the other reads of them are.
struct ISFTestDetermination: Equatable {
    let date: Date
    /// Insulin on board when Trio made it, in units. Nil when it holds none.
    let iob: Decimal?
    /// Carbs on board when Trio made it, in grams. Nil when it wasn't read with it.
    var cob: Decimal? = nil
}

/// The newest CGM reading at or before a moment, with the CGM's own arrow for it, as the conditions at the bolus read it.
struct ISFTestArrowReading: Equatable {
    let date: Date
    /// Nil when the CGM gave none.
    let direction: BloodGlucose.Direction?
}

/// A condition the Dose step holds the dose for that didn't hold when the test bolus went in, which can come from Home,
/// the pump or the Watch as well as from Open Treatments (`ISFTestEvaluator.failedBolusCondition`). The test then ends
/// with no verdict: a spoiled test gives no result.
enum ISFTestBolusCondition: Equatable {
    /// Glucose at the bolus was at or below the target, so the docs' formula gives no dose to judge it by
    /// (`ISFTestEvaluator.dose`).
    case atOrBelowTarget
    /// Tablets were taken, and glucose hadn't risen from them yet (`ISFTestEvaluator.tabletsActed`).
    case tabletsNotActed
    /// The CGM's arrow at the bolus wasn't flat (`ISFTestEvaluator.isLevel`).
    case glucoseMoving
    /// Trio counted carbs on board at the bolus.
    case carbsOnBoard
    /// In a test that waits for it, insulin on board at the bolus was over the line for the docs' dose then.
    case iobOverLine
    /// The docs' 4 hours from the bolus covered more than one ISF value (`crossesISFChange`): "Test one time period at a
    /// time".
    case isfChanges
    /// The start glucose at the bolus (the mean of the newest 3 readings at or before it, checked first), or a reading or
    /// a determination needed to check the other conditions then, couldn't be read.
    case unread

    /// What the Result says about it.
    var note: String {
        switch self {
        case .atOrBelowTarget:
            return String(localized: "The bolus came with your glucose at or below your target, so the test can't be judged.")
        case .tabletsNotActed:
            return String(localized: "The bolus came before the tablets raised your glucose, so the test can't be judged.")
        case .glucoseMoving:
            return String(localized: "The bolus came while your glucose was still moving, so the test can't be judged.")
        case .carbsOnBoard:
            return String(localized: "The bolus came with carbs on board, so the test can't be judged.")
        case .iobOverLine:
            return String(
                localized: "The bolus came with more insulin on board than the test allows, so the test can't be judged."
            )
        case .isfChanges:
            // The Result's own words for a test something changed in: there are none yet for this one.
            return String(localized: "Something changed during the test, so the result can't be trusted. Try again.")
        case .unread:
            return ISFTestEvaluator.historyUnreadNote
        }
    }
}

/// A bolus given while the test settles, as the Settle step shows it.
struct ISFTestSettlingBolus: Equatable {
    let date: Date
    let units: Decimal
    /// Whether the pump history flags it as an SMB, which is what Trio gave from the mode before Begin. Any other bolus
    /// was given by hand.
    let isSMB: Bool
}

/// How the test handles insulin on board over its line at Begin, as the user chose on the Check screen.
enum ISFTestIOBHandling: String, JSON, Equatable {
    /// The docs' way: settling waits for it to come under the line, up to `ISFTest.Config.settleAllowance`.
    case wait
    /// Begin now: the result adds what is still on board at the bolus to the units it judges by.
    case count
}

/// What insulin on board at Begin means for the test (`ISFTestEvaluator.iobDecision`).
enum ISFTestIOBDecision: Equatable {
    /// At or under the line: too little to sway the result, so there is nothing to choose.
    case fine
    /// Over the line, and no more than the test's dose: the user chooses to wait for it or count it.
    case choice(line: Decimal)
    /// More than the test's whole dose: Begin waits until it has come down.
    case blocked
}

/// Where settling is (`ISFTestEvaluator.settling`).
enum ISFTestSettling: Equatable {
    /// Still settling. `loopedAt` is when Trio first looped in Basal Testing, nil until it has; `waitsForIOB`, whether
    /// insulin on board is still over the line in a test that waits for it.
    case waiting(loopedAt: Date?, waitsForIOB: Bool)
    /// The time for settling is up with insulin on board still over the line: the screen asks whether to count it and go
    /// on, or cancel. It never ends the test on its own.
    case timeUp(loopedAt: Date)
    /// The time for settling is up and Trio hasn't looped in Basal Testing: counting insulin on board wouldn't help, so
    /// the screen only offers to cancel, and the runner ends the test with its sentence (`deadEndSentence`).
    case noLoop
    /// The time for settling is up: Trio looped in Basal Testing at `loopedAt`, but the CGM hasn't had the readings
    /// since then that the dose glucose averages (`ISFTest.Config.settleReadings`). As with no loop, counting insulin on
    /// board wouldn't help, so the screen only offers to cancel, and the runner ends the test.
    case tooFewReadings(loopedAt: Date)
    /// The time for settling is up with a temp basal still running on the pump: one Closed Loop set before Begin that
    /// Basal Testing couldn't cancel, or one set on the pump. Counting insulin on board wouldn't help, so the screen only
    /// offers to cancel, and the runner ends the test.
    case tempBasalRunning(loopedAt: Date)
    /// The real test can start.
    case settled
}

/// Where a running ISF test is. The runner saves it, so a test opened again carries on from the same step.
enum ISFTestPhase: String, JSON {
    /// Begin switched to Basal Testing, so SMBs stopped. The test waits for Trio's first loop in Basal Testing, and for
    /// insulin on board to come under the test's line when it waits for it, before the real test starts.
    case settling
    /// Glucose is below the docs' start, so tablets are being taken to raise it.
    case raising
    /// Glucose is ready (or the tablets were skipped) and the correction bolus is due.
    case dosing
    /// The bolus is in and the 4 hours are running.
    case waiting
    /// The result is in, or the test ended with nothing to judge.
    case finished
}

/// Why the docs' formula gives no dose on the Dose step.
enum ISFTestNoDose: Equatable {
    /// Trio counts carbs on board, so the test can't be judged: the docs test ISF "when fasting (no COB)".
    case carbsOnBoard
    /// None of Trio's determinations in the last 12 minutes says how many carbs are on board, so none can't be told
    /// from some. The Dose step waits for one.
    case carbsUnread
    /// The CGM has no reading recent enough to work the dose out from.
    case noRecentReading
    /// Glucose is at or below the target, so (glucose − target) ÷ ISF gives nothing to dose.
    case atOrBelowTarget
    /// There is no target or ISF to work it out with.
    case noSettings
    /// The test counts insulin on board, and it already covers the docs' correction, or leaves less than the pump can
    /// give, so there is nothing to give.
    case iobCoversDose
    /// The test counts insulin on board, and none of Trio's determinations in the last 12 minutes holds it.
    case iobUnread
    /// The docs' 4 hours from now cover more than one ISF value (`crossesISFChange`), so a bolus now wouldn't test one
    /// time period: "Test one time period at a time". Time moves the 4 hours past the change, so the step waits.
    case isfChanges
    /// The same, and no moment from now to the dose deadline has its 4 hours on one ISF value, so waiting can't help:
    /// a dead end, which the runner ends the test at with the step's sentence.
    case isfChangesUntilDeadline

    /// Whether the Dose step is waiting for a reading or for time, which a later tick can bring, rather than at a dead
    /// end: then it shows Open Treatments turned off.
    var isWaiting: Bool {
        switch self {
        case .carbsUnread,
             .iobUnread,
             .isfChanges,
             .noRecentReading: return true
        case .atOrBelowTarget,
             .carbsOnBoard,
             .iobCoversDose,
             .isfChangesUntilDeadline,
             .noSettings: return false
        }
    }
}

/// The test bolus as the pump history holds it when read again. Trio stores a bolus being delivered with the amount
/// programmed and writes the amount delivered when the pump reports it, so a bolus cut short (cancelled, an occlusion, a
/// pod fault) holds less than was first seen, and one cancelled before any insulin went in holds 0 U.
enum ISFTestBolusAmount: Equatable {
    /// The units to judge on. Nil when none were ever recorded.
    case units(Decimal?)
    /// The bolus holds 0 U: no insulin was delivered.
    case cancelled
    /// At the finish, the history couldn't be read or no longer shows the bolus, so the amount can't be trusted.
    case unread
}

/// What the pump is doing with basal now, from its status (`ISFTest.Provider.pumpDelivery`).
enum ISFTestPumpDelivery: Equatable {
    /// Scheduled basal is running.
    case delivering
    /// A temp basal is running.
    case tempBasal
    /// A temp basal is being set or cancelled: a moment, which settling doesn't count as a temp basal running. Basal
    /// Testing's own suspend for a low shows as this while the pump enacts it.
    case tempBasalChanging
    /// Insulin is suspended, or being suspended or resumed, or the pump isn't working, so no basal is going in.
    case suspended
}

/// What the test does first from the glucose now, for the Check screen to say.
enum ISFTestStartPath: Equatable {
    /// Below the docs' 150, with a target under it: glucose tablets raise it first.
    case raise
    /// Above the target and ready for the docs' dose.
    case dose
    /// At or below a target of the docs' 150 or more: the formula gives no dose, and tablets have no glucose above the
    /// target to aim for.
    case noDose
}

/// A reading on the Check screen that is easy to miss, so its row warns. Each still only informs.
enum ISFTestWarning: Hashable {
    /// The newest basal test isn't steady, or the basal schedule changed since it.
    case basalNotSteady
    /// The docs' 4 hours from now cover more than one ISF value.
    case isfChanges
    /// The low threshold Basal Testing suspends at is at or above the target, so Trio may suspend right after the dose.
    case lowThreshold
}

/// Why the Raise step has no tablets to count.
enum ISFTestNoTablets: Equatable {
    /// The CGM has no reading recent enough to count them from.
    case noRecentReading
    /// There is no carb ratio to turn the rise into grams.
    case noCarbRatio
    /// Glucose is already at or above the docs' 150.
    case atOrAboveAim
}

/// How Trio's suggested bolus compares with the docs' dose, from the Recommended Bolus Percentage, for the Dose step's
/// note.
enum ISFTestSuggestion: Equatable {
    /// Below 100%: Trio suggests less than the docs' dose, and SMBs would normally give the rest.
    case less
    /// 100%: Trio suggests the docs' dose.
    case same
    /// Above 100%: Trio suggests more than the docs' dose.
    case more
}

/// Why a finished test says nothing about the ISF, for the Result screen to say.
enum ISFTestNoVerdict: Equatable {
    /// No bolus came in the time allowed for one, so there was nothing to judge.
    case noBolus
    /// Something spoiled the test. The saved note says what, when there is one.
    case interrupted
    /// A record read to check for what spoils the test couldn't be read, so something may have been missed.
    case historyUnread
    /// It ended before the docs' 4 hours.
    case tooSoon
    /// The 4 hours were up, but the pump history couldn't be read to check for a low.
    case lowUnchecked
    /// There was no reading at the bolus or at the end to compare.
    case noReadings
    /// The pump history gave no amount for the bolus, so there is no drop per unit to work out. (A saved ISF of zero
    /// would say the same, but Start doesn't allow one.)
    case noAmount
    /// The dose was too small for any whole reading to lie within a docs step of where it would take glucose
    /// (`ISFTestEvaluator.accurateEnds` is nil), so CGM noise alone could decide the verdict.
    case doseTooSmall
    /// Trio suspended insulin on its forecast while glucose was still above the target, so the low says nothing about
    /// the ISF.
    case forecastSuspend
    /// Trio suspended insulin for a low after a bolus more than a docs step over the docs' dose, so the low can't be put
    /// down to the ISF.
    case doseOverDocs
}

/// The glucose tablets taken before the dose, as the Result screen shows them.
struct ISFTestTablets: Equatable {
    /// Whole tablets of the brand saved. Nil when the grams aren't a whole number of them (tablets of another brand
    /// were taken first) or the brand isn't known.
    let count: Int?
    let grams: Decimal
}

/// The wizard's persisted state, so a test opened again, or found after the app was closed, carries on or finishes
/// from what it saved.
struct ISFTestState: JSON, Equatable {
    var id = UUID()
    var phase: ISFTestPhase
    var startedAt: Date
    var previousMode: DosingMode
    /// The settings test session that holds the way back, so the service's record of why it ended the session can be
    /// matched to this test.
    var sessionID: UUID? = nil

    // What the dose and the result use, saved at Start so neither depends on what the settings say by then.
    /// The ISF in force at Start, in mg/dL per unit; once the bolus is in, the one in force at the bolus, from the
    /// schedule saved at Begin (`coveredEntries`), which the result uses.
    var isf: Decimal
    /// The glucose target in force at Start, in mg/dL; once the bolus is in, the one in force at the bolus, from the
    /// schedule saved at Begin (`targetEntries`), which the result uses.
    var target: Decimal
    /// The carb ratio in force at Start, in grams per unit, for the tablets. Nil when there was none to read.
    var carbRatio: Decimal? = nil
    /// The pump's bolus increment at Begin, in units: the docs' dose is rounded up to it before a low's bolus is held
    /// against it (`ISFTestEvaluator.lowNoVerdict`). Nil in a state saved before it was kept, which rounds nothing.
    var bolusIncrement: Decimal? = nil

    // Insulin on board and settling, fixed at Begin. Nil in a state saved before they were kept.
    /// The docs' dose the test expects, in units, from the start path at Begin (`ISFTestEvaluator.expectedDose`). Nil
    /// when there was none to work out.
    var expectedDose: Decimal? = nil
    /// The line insulin on board must be under, in units, either way: the docs' smallest ISF change of the expected dose
    /// (`ISFTestEvaluator.iobLine`). Nil without an expected dose.
    var iobLine: Decimal? = nil
    /// How the test handles insulin on board, as chosen at Begin. Nil when there was no choice to make; a test that
    /// finds insulin on board over the line while settling then waits for it, as `.wait` does.
    var iobHandling: ISFTestIOBHandling? = nil
    /// Where Begin planned the test to go, from the glucose then (`ISFTestEvaluator.startPhase`). Settling moves on from
    /// the glucose as it ends, and uses this only when there is no recent reading then (`phaseAfterSettling`).
    var plannedPhase: ISFTestPhase? = nil
    /// When settling ended and the real test started. Nil while settling, and in a test begun before settling was kept,
    /// which started at Start (`bolusWindowStart`).
    var settledAt: Date? = nil

    // The tablets taken to raise glucose before the dose. Not logged as carbs.
    /// `GlucoseTabletBrand.rawValue`.
    var tabletBrand: String? = nil
    /// Grams taken, over every time tablets were taken.
    var tabletCarbs: Decimal? = nil
    var tabletsTakenAt: Date? = nil
    /// mg/dL: the glucose the tablets were counted from, the mean of the last 3 readings when they were taken, which
    /// glucose has to rise above before the dose (`ISFTestEvaluator.tabletsActed`). Nil until they are taken, and in a
    /// state saved before it was kept.
    var tabletsGlucose: Int? = nil

    // The test bolus, filled in when Trio sees it.
    var bolusAt: Date? = nil
    var bolusUnits: Decimal? = nil
    /// Insulin on board just before the bolus, from the newest determination before it (`ISFTestEvaluator.iobAtBolus`),
    /// signed, which the units given count whether the test waited for it or counts it (`givenUnits`), so they match the
    /// remainder of it left out at the planned end (`iobAtEnd`). Nil until it has been read.
    var iobAtBolus: Decimal? = nil
    /// Insulin on board Trio reports still left at the planned end, from the newest determination at or before it
    /// (`ISFTestEvaluator.iobAtEnd`), signed: what hadn't acted by the docs' 4 hours, which the units judged leave out.
    /// Read when a test that ran its 4 hours finishes. Nil until then, and when it couldn't be read.
    var iobAtEnd: Decimal? = nil
    /// mg/dL: the mean of the last 3 readings at or before the bolus. Nil when the CGM had none recent enough.
    var startGlucose: Int? = nil
    /// The ISF schedule entries the test runs on, as they were at Start: those any bolus in the time allowed and its 4
    /// hours could cover, narrowed to the 4 hours from the bolus once it is in. Nil when there were none to save.
    var coveredEntries: [SettingsTestScheduleEntry]? = nil
    /// The glucose target schedule in mg/dL, as it was at Begin, over the same hours as `coveredEntries` were then: what
    /// the Dose step and the bolus read their target from. Nil when there was none to save, and in a state saved before
    /// it was kept, which keeps the target saved at Start.
    var targetEntries: [SettingsTestScheduleEntry]? = nil

    // Filled in when the test finishes.
    var endedAt: Date? = nil
    var endReason: ISFTestEndReason? = nil
    var endGlucose: Int? = nil
    /// From the bolus (from Start if none came) to the end, oldest first.
    var readings: [BasalTestReading] = []
    var outcome: ISFTestOutcome? = nil
    var interference: String? = nil
    /// Whether a record read to check for what spoils the test couldn't be read when it finished, so something may have
    /// been missed. Nil in a state saved before it was kept.
    var interferenceUnread: Bool? = nil
    /// The ending a check decided, saved before the usual mode comes back, so the next check finishes it for that ending
    /// (`ISFTestRunner`). Nil while none is, once the test has finished, and in a state saved before it was kept.
    var pendingEnd: ISFTestPendingEnd? = nil
    /// The Dose step's notice, "ISF Dose Ready", while it is owed: the step came next, after settling or the tablets,
    /// and didn't show a dose then. Posted once it shows one (`ISFTestEvaluator.doseNotice`); dropped by the bolus, a move
    /// to another step and a finish. Nil otherwise, and in a state saved before it was kept.
    var doseNoticeDue: ISFTestDoseNoticeDue? = nil
    /// The carb entries there at Begin, dated in the day before it (`SettingsTestCarbRule.keptAtBegin`), so one logged
    /// during the test with an earlier time spoils it. Nil in a state saved before they were kept, which reads carbs from
    /// Begin only.
    var carbsAtBegin: [String]? = nil
    /// When the Dose step after tablets first offered the dose, with glucose risen from them and leveled off
    /// (`ISFTestEvaluator.tabletsLeveledOff`): the latch, so plateau noise after it doesn't take the dose back, and the
    /// bolus check needs it and a flat arrow. Nil before, without tablets, and in a state saved before it was kept.
    var tabletsLeveledAt: Date? = nil
    /// The last moment the Dose step offered the dose (Open Treatments on), saved each check while it does: the bolus's
    /// ISF-change check is judged from it. Nil until it has, and in a state saved before it was kept.
    var doseOfferedAt: Date? = nil
    /// When a check first found the Dose step no longer offering the dose after `doseOfferedAt`. Nil while the offer
    /// stands, before any, and in a state saved before it was kept.
    var doseOfferEndedAt: Date? = nil
    /// "ISF Test Settled" while it is owed: settling moved on to the Raise step without a reading recent enough to count
    /// the tablets from, so the notice that says how many to take waits until the step can count them. True while owed;
    /// dropped by the tablets taken, a move to the Dose step, the bolus and a finish. Nil otherwise, and in a state saved
    /// before it was kept.
    var raiseNoticeDue: Bool? = nil
    /// Whether "ISF Test Waiting" went, for settling's hour up with insulin on board still over the line
    /// (`ISFTestSettling.timeUp`): saved as it is posted, so a later check or a relaunch doesn't post it again. Nil
    /// before, and in a state saved before it was kept.
    var timeUpNoticePosted: Bool? = nil

    /// When the real test started, which the bolus window runs from: the end of settling. A test begun before settling
    /// was kept carries on from Start, as it did then. Nil while settling.
    var bolusWindowStart: Date? {
        settledAt ?? (phase == .settling ? nil : startedAt)
    }

    /// The bolus must come by then (`ISFTest.Config.doseAllowance`), from the end of settling: from Start in a test
    /// begun before settling was kept.
    var doseDeadline: Date { (settledAt ?? startedAt).addingTimeInterval(ISFTest.Config.doseAllowance) }

    /// When the test ends with no bolus if none came: the dose deadline, or, while settling, the latest a dose deadline
    /// could be, Start plus the time for settling and the dose. The service ends a test still settling then
    /// (`SettingsTestService`).
    var noBolusDeadline: Date {
        guard phase == .settling else { return doseDeadline }
        return startedAt.addingTimeInterval(ISFTest.Config.settleAllowance + ISFTest.Config.doseAllowance)
    }

    /// The end of the docs' 4 hours from the bolus. Nil until the bolus is in.
    var plannedEnd: Date? { bolusAt?.addingTimeInterval(ISFTest.Config.docsWait) }
}

/// Turns what happened after a correction bolus into a result. Pure, so it can be tested without a loop.
enum ISFTestEvaluator {
    struct Evaluation: Equatable {
        let outcome: ISFTestOutcome
        let direction: SettingsTestDirection?
        /// Glucose fall ÷ units given, in mg/dL per unit: the ISF the test actually measured. Negative when glucose
        /// rose. Nil when the outcome doesn't rest on it.
        let dropPerUnit: Decimal?
        /// That drop per unit against the ISF, as a share of the ISF: positive when glucose fell more than the ISF
        /// says, negative when it fell less. Nil when the outcome doesn't rest on it.
        let share: Decimal?
    }

    // MARK: - Saved dates against the history

    /// Whether history timestamp `date` comes after `saved`, a date saved in the test's state, by at least
    /// `ISFTest.Config.savedDateTolerance`. Closer than that they are the same moment: the state keeps whole
    /// milliseconds and the history microseconds, so the test bolus read back can be a fraction of a millisecond after the
    /// `bolusAt` saved for it.
    static func isAfter(_ date: Date, _ saved: Date) -> Bool {
        date.timeIntervalSince(saved) >= ISFTest.Config.savedDateTolerance
    }

    /// Whether history timestamp `date` comes before `saved` by at least the tolerance (`isAfter`).
    static func isBefore(_ date: Date, _ saved: Date) -> Bool {
        saved.timeIntervalSince(date) >= ISFTest.Config.savedDateTolerance
    }

    /// Whether history timestamp `date` and `saved` are the same moment, closer than the tolerance (`isAfter`).
    static func isSameMoment(_ date: Date, _ saved: Date) -> Bool {
        !isAfter(date, saved) && !isBefore(date, saved)
    }

    /// The readings at or before `saved`, a moment saved in the test's state, such as the bolus: one at the same moment
    /// (`isSameMoment`) counts as at it.
    static func readings(_ readings: [BasalTestReading], atOrBefore saved: Date) -> [BasalTestReading] {
        readings.filter { !isAfter($0.date, saved) }
    }

    /// The readings at or after `saved`, a moment saved in the test's state, such as the bolus: one at the same moment
    /// (`isSameMoment`) counts as at it.
    static func readings(_ readings: [BasalTestReading], since saved: Date) -> [BasalTestReading] {
        readings.filter { !isBefore($0.date, saved) }
    }

    /// The test bolus: the first bolus from `start`, the end of settling (`bolusWindowStart`), to `deadline` inclusive,
    /// from any source (Treatments, the pump, the Watch). Later ones in the window are extra boluses, which the watchdog
    /// and the screen end the test for. The deadline is a date saved in the test's state or the service's session, so a
    /// bolus at the same moment as it (`isSameMoment`) is inside. A bolus before the start is one given while settling
    /// (`settlingBoluses`), never the test's, so the start edge is exact.
    static func testBolus(_ boluses: [ISFTestBolus], since start: Date, deadline: Date) -> ISFTestBolus? {
        boluses.filter { $0.date >= start && !isAfter($0.date, deadline) }.min { $0.date < $1.date }
    }

    /// The units the test bolus is judged on, from `reread`, the bolus rows read again around the saved `bolusAt` (nil
    /// when they couldn't be read): the amount the one at the same moment holds now (`isSameMoment`), so a bolus cut short
    /// is judged per unit delivered. At 0 U it was cancelled before any insulin went in. A row with no amount keeps the
    /// `saved` one. With no row there, or none read, a running check keeps the `saved` amount and goes on; the finish
    /// can't trust it (`finishing`).
    static func bolusAmount(
        saved: Decimal?,
        reread: [ISFTestBolusRecord]?,
        bolusAt: Date,
        finishing: Bool
    ) -> ISFTestBolusAmount {
        guard let row = reread?.first(where: { isSameMoment($0.date, bolusAt) }) else {
            return finishing ? .unread : .units(saved)
        }
        guard let amount = row.amount else { return .units(saved) }
        return amount == 0 ? .cancelled : .units(amount)
    }

    /// What a running test's periodic check found that ends it.
    enum RunningCheck: Equatable {
        /// Trio suspended insulin for a low at this time, before the bolus: there is nothing to judge.
        case lowBeforeDose(at: Date)
        /// Trio suspended insulin for a low at this time, after the bolus.
        case low(at: Date)
        /// The service ended the test at this time because carbs were logged.
        case carbsLogged(at: Date)
        /// The service ended the test at this time because carbs couldn't be read.
        case carbsUnreadable(at: Date)
        /// The service ended the test at this time because a second bolus was given.
        case extraBolus(at: Date)
        /// The time for the bolus is up and none came.
        case noBolus
        /// The test was still settling when the latest a bolus window could close came (`noBolusDeadline`), so the
        /// service ended it, or would, and brought the usual mode back.
        case settlingTimedOut
        /// The planned time is up.
        case completed
        /// The planned time is up, but the pump history couldn't be read, so a low can't be ruled out.
        case completedUnchecked
        /// The dosing mode was changed before the test was over, so the rest of it didn't run in Basal Testing.
        case modeChanged
        /// The same, and the service's end of the session put the usual mode back, because Basal Testing was on again by
        /// then (`SettingsTestEnd.modeRestored`).
        case modeChangedRestored
        /// Basal was stopped inside the test at this time, and it can't be told that was Basal Testing's suspend for a
        /// low: none of Trio's determinations asked for it, or Basal Testing was off by the time of the check and the
        /// service didn't end the test for it.
        case unexplainedSuspend(at: Date)
        /// The service ended the test for no bolus before it saw the one the runner found, and brought the usual mode
        /// back.
        case bolusNotSeen
        /// The test bolus was cancelled before any insulin was delivered (`bolusAmount`).
        case bolusCancelled
        /// The pump was suspended, gave an alarm, or had its site or reservoir changed at this time
        /// (`SettingsTestEvents.pumpInterruptions`): basal or the bolus may not have gone in as recorded.
        case pumpInterrupted(at: Date)
    }

    /// What a running test's periodic check decides. Nil to keep going.
    ///
    /// First, the service's record of ending this test's session for a low, for carbs logged or unreadable, for basal
    /// stopped without Trio asking, for a second bolus or for no bolus, if it is dated at or before `plannedEnd` (the
    /// dose deadline until the bolus sets one): the service brought the usual mode back then, so the record, not the
    /// mode, says why. A low is a low before the bolus until the bolus is in.
    ///
    /// Before the bolus (settling, raising, dosing), the time for it running out ends the test with no bolus, then a mode
    /// other than Basal Testing, then a zero temp. `doseDeadline` is the test's `noBolusDeadline`, so while settling it is
    /// the service's own. Only while Basal Testing is on is a zero temp that Trio asked for its
    /// suspend for a low; one it didn't ask for (`SuspendReading.unexplained`) stops the test as interrupted. A pump
    /// history that can't be read says nothing yet, so the test goes on.
    ///
    /// Waiting, it is the basal fast's rules, which `BasalTestEvaluator.runningCheck` holds, to the planned end. A low
    /// dated before `bolusAt` (the service's record, or a zero temp) is still a low before the dose: the bolus went in
    /// after it, perhaps from Home with the test's screen closed, and there was nothing to judge. A test found waiting with
    /// no planned end can't be timed or judged, so it closes with no verdict at the dose deadline.
    static func runningCheck(
        phase: ISFTestPhase,
        sessionID: UUID?,
        serviceEnd: SettingsTestEnd?,
        suspend: BasalTestEvaluator.SuspendReading,
        now: Date,
        doseDeadline: Date,
        bolusAt: Date?,
        plannedEnd: Date?,
        mode: DosingMode
    ) -> RunningCheck? {
        let limit = plannedEnd ?? doseDeadline
        switch phase {
        case .finished:
            return nil
        case .waiting:
            // The service's watchdog looked before the bolus was in the pump history. The basal rules would read the mode
            // it brought back as changed.
            if let serviceEnd, let sessionID, serviceEnd.sessionID == sessionID, !isAfter(serviceEnd.date, limit) {
                switch serviceEnd.cause {
                case .noBolus: return .bolusNotSeen
                // With its own words; the basal rules would read it as basal stopped.
                case .pumpInterrupted: return .pumpInterrupted(at: serviceEnd.date)
                case .basalStopped,
                     .carbsLogged,
                     .carbsUnreadable,
                     .extraBolus,
                     .low,
                     .modeChanged:
                    break
                }
            }
            let check = BasalTestEvaluator.runningCheck(
                sessionID: sessionID,
                serviceEnd: serviceEnd,
                suspend: suspend,
                now: now,
                plannedEnd: limit,
                mode: mode
            )
            switch check {
            case nil: return nil
            case let .low(at):
                // One at the same moment as the saved bolus is at it, so after it, as one at the bolus is.
                if let bolusAt, isBefore(at, bolusAt) { return .lowBeforeDose(at: at) }
                return .low(at: at)
            case let .carbsLogged(at): return .carbsLogged(at: at)
            case let .carbsUnreadable(at): return .carbsUnreadable(at: at)
            case let .bolusGiven(at): return .extraBolus(at: at)
            // Without a planned end there is no 4 hours to have run, so time up is not a result.
            case .completed: return plannedEnd == nil ? .completedUnchecked : .completed
            case .completedUnchecked: return .completedUnchecked
            case .modeChanged: return .modeChanged
            case .modeChangedRestored: return .modeChangedRestored
            case let .unexplainedSuspend(at): return .unexplainedSuspend(at: at)
            // Taken above, with the service's record.
            case let .pumpInterrupted(at): return .pumpInterrupted(at: at)
            }
        case .dosing,
             .raising,
             .settling:
            // While settling, running out of time is settling not finishing, not a bolus that didn't come.
            let outOfTime: RunningCheck = phase == .settling ? .settlingTimedOut : .noBolus
            // The service dates a record from its own session, which began a few milliseconds after the saved Start, so
            // one at the same moment as the limit is inside it.
            if let serviceEnd, let sessionID, serviceEnd.sessionID == sessionID, !isAfter(serviceEnd.date, limit) {
                switch serviceEnd.cause {
                case .low: return .lowBeforeDose(at: serviceEnd.date)
                case .carbsLogged: return .carbsLogged(at: serviceEnd.date)
                case .carbsUnreadable: return .carbsUnreadable(at: serviceEnd.date)
                case .basalStopped: return .unexplainedSuspend(at: serviceEnd.date)
                case .extraBolus: return .extraBolus(at: serviceEnd.date)
                case .noBolus: return outOfTime
                case .modeChanged: return serviceEnd.modeRestored == true ? .modeChangedRestored : .modeChanged
                case .pumpInterrupted: return .pumpInterrupted(at: serviceEnd.date)
                }
            }
            if now >= doseDeadline { return outOfTime }
            if mode != .basalTesting { return .modeChanged }
            switch suspend {
            case let .suspended(at): return .lowBeforeDose(at: at)
            case let .unexplained(at): return .unexplainedSuspend(at: at)
            case .none,
                 .unreadable: return nil
            }
        }
    }

    /// What the pump history and Trio's determinations say about a suspend in an ISF test, from Begin (`startedAt`) to
    /// `end` inclusive. A zero temp with time on it is Trio's suspend for a low when a determination made at least
    /// `margin` after Begin asked for it (`settleLoopMargin`: a loop already running at Begin read the settings from
    /// before). One that only a determination from before then asked for is Closed Loop's, landing while the test
    /// settles as its SMBs do: it is in the insulin on board settling waits for or counts, and settling also waits until
    /// no temp basal runs (`settling`), so it isn't the test's low and doesn't stop it. One none of them asked for
    /// stops the test (`unexplained`). Each zero temp is looked at in turn, so one Closed Loop set doesn't hide what
    /// follows; otherwise the first decides, as for the basal fast (`BasalTestEvaluator.suspendReading`).
    static func suspendReading(
        _ temps: [BasalTestTempBasal],
        zeroTempDeterminations: [Date],
        startedAt: Date,
        until end: Date,
        margin: TimeInterval = ISFTest.Config.settleLoopMargin
    ) -> BasalTestEvaluator.SuspendReading {
        let earliest = startedAt.addingTimeInterval(margin)
        let zeroTemps = temps
            .filter { $0.date >= startedAt && $0.date <= end && $0.rate == 0 && $0.minutes > 0 }
            .sorted { $0.date < $1.date }
        for temp in zeroTemps {
            let from = temp.date.addingTimeInterval(-BasalTestEvaluator.zeroTempAskedBefore)
            let to = temp.date.addingTimeInterval(BasalTestEvaluator.zeroTempAskedAfter)
            let asked = zeroTempDeterminations.filter { $0 >= from && $0 <= to }
            if asked.contains(where: { !isBefore($0, earliest) }) { return .suspended(at: temp.date) }
            if asked.isEmpty { return .unexplained(at: temp.date) }
        }
        return .none
    }

    /// The docs' dose: (current glucose − target glucose) ÷ ISF, to 2 decimals. Nil when glucose isn't above target,
    /// because the formula then gives nothing to dose, or when there is no ISF to divide by.
    static func dose(glucose: Int, target: Decimal, isf: Decimal) -> Decimal? {
        unroundedDose(glucose: glucose, target: target, isf: isf).map { rounded($0, scale: 2, roundingMode: .plain) }
    }

    /// The docs' dose before it is rounded to 2 decimals, so the Dose step can tell whether the dose it shows is exact.
    static func unroundedDose(glucose: Int, target: Decimal, isf: Decimal) -> Decimal? {
        let rise = Decimal(glucose) - target
        guard isf > 0, rise > 0 else { return nil }
        return rise / isf
    }

    /// Grams of carbohydrate that raise glucose from `glucose` to the docs' starting `aim`: the rise needed ÷ ISF is
    /// the units of insulin it takes to cover, and the carb ratio turns those units into grams. Zero at or above
    /// the aim, and without an ISF or carb ratio to work from.
    static func tabletCarbs(
        glucose: Int,
        carbRatio: Decimal,
        isf: Decimal,
        aim: Int = ISFTest.Config.docsStartAim
    ) -> Decimal {
        guard glucose < aim, isf > 0, carbRatio > 0 else { return 0 }
        return Decimal(aim - glucose) * carbRatio / isf
    }

    /// Whole tablets of `brand` that give at least `carbs`, so glucose reaches the aim rather than stopping short.
    static func tablets(for carbs: Decimal, brand: GlucoseTabletBrand) -> Int {
        guard carbs > 0 else { return 0 }
        let count = rounded(carbs / brand.carbsPerTablet, scale: 0, roundingMode: .up)
        return NSDecimalNumber(decimal: count).intValue
    }

    /// The whole mg/dL end readings `evaluate` calls accurate: those closer than one docs step of the drop to the start
    /// less units × ISF. Nil when none is: the drop is too small for a whole reading to lie that close (one step of it
    /// is under about 1 mg/dL), or there is no drop at all.
    static func accurateEnds(
        startGlucose: Int,
        units: Decimal,
        isf: Decimal,
        step: Decimal = ISFTest.Config.docsSmallestStep
    ) -> ClosedRange<Int>? {
        let drop = units * isf
        let centre = Decimal(startGlucose) - drop
        let limit = max(0, drop * step)
        // The whole numbers strictly between centre − limit and centre + limit. `.down` and `.up` are floor and ceiling.
        let low = NSDecimalNumber(decimal: rounded(centre - limit, scale: 0, roundingMode: .down)).intValue + 1
        let high = NSDecimalNumber(decimal: rounded(centre + limit, scale: 0, roundingMode: .up)).intValue - 1
        return low <= high ? low ... high : nil
    }

    /// The result comes from the docs' smallest ISF change: a drop per unit within that much of the ISF, after the
    /// docs' wait, is accurate. It is judged per unit that acted (`units`, `judgedUnits`), so a dose that was smaller or
    /// larger than the formula's, or glucose that didn't start at the target, still tests the ISF.
    ///
    /// An interference or an interrupted test, or a bolus that never came, is invalid. A test whose records couldn't
    /// all be read for what spoils it (`interferenceUnread`) is inconclusive, a low among them.
    ///
    /// A low ends the test early, so it isn't judged on the drop. It says the ISF number is too low only when it is one
    /// the docs' words and the ISF account for (`lowNoVerdict` nil); otherwise there is no verdict.
    ///
    /// Otherwise, insulin on board that couldn't be read (`iobUnread`: at the bolus, or left at
    /// the planned end) leaves no units to judge by. Ending early, a pump history that couldn't be read, or less than the
    /// docs' wait says nothing, and so does a missing reading or setting, or a dose too small for any whole reading to lie
    /// within a docs step of where it would take glucose (`accurateEnds` nil): CGM noise would decide it.
    static func evaluate(
        startGlucose: Int?,
        endGlucose: Int?,
        units: Decimal?,
        elapsed: TimeInterval,
        reason: ISFTestEndReason,
        interference: String?,
        interferenceUnread: Bool = false,
        iobUnread: Bool = false,
        isf: Decimal?,
        target: Decimal? = nil,
        givenUnits: Decimal? = nil,
        increment: Decimal = 0,
        step: Decimal = ISFTest.Config.docsSmallestStep
    ) -> Evaluation {
        func result(
            _ outcome: ISFTestOutcome,
            _ direction: SettingsTestDirection?,
            dropPerUnit: Decimal? = nil,
            share: Decimal? = nil
        ) -> Evaluation {
            Evaluation(outcome: outcome, direction: direction, dropPerUnit: dropPerUnit, share: share)
        }

        if interference != nil || reason == .interrupted || reason == .noBolus {
            return result(.invalid, nil)
        }

        // Something that spoils the test may have been missed, carbs that held glucose up or a bolus that brought on a
        // low among them.
        if interferenceUnread {
            return result(.inconclusive, nil)
        }

        // A low ends the test, and it points the same way as any other fall past the ISF.
        if reason == .low {
            return lowNoVerdict(
                glucoseAtSuspend: endGlucose,
                startGlucose: startGlucose,
                givenUnits: givenUnits,
                target: target,
                isf: isf,
                increment: increment,
                step: step
            ) == nil ? result(.tooLow, .increase) : result(.inconclusive, nil)
        }

        // Insulin on board at the bolus, or the insulin left at the end, couldn't be read: no units to
        // judge by.
        if iobUnread {
            return result(.inconclusive, nil)
        }

        // An unread pump history can't rule out a low, so whatever glucose did says nothing about the ISF.
        if reason == .endedEarly || reason == .unchecked || elapsed < ISFTest.Config.docsWait {
            return result(.inconclusive, nil)
        }

        guard let startGlucose, let endGlucose, let units, units > 0, let isf, isf > 0 else {
            return result(.inconclusive, nil)
        }

        // No whole reading could count as accurate, so a reading or two of CGM noise would decide the verdict.
        guard accurateEnds(startGlucose: startGlucose, units: units, isf: isf, step: step) != nil else {
            return result(.inconclusive, nil)
        }

        let dropPerUnit = Decimal(startGlucose - endGlucose) / units
        let share = (dropPerUnit - isf) / isf

        if abs(share) < step {
            return result(.accurate, .keep, dropPerUnit: dropPerUnit, share: share)
        }
        return share > 0
            ? result(.tooLow, .increase, dropPerUnit: dropPerUnit, share: share)
            : result(.tooHigh, .decrease, dropPerUnit: dropPerUnit, share: share)
    }

    /// Why Trio's suspend for a low says nothing about the ISF, nil when it says the number is too low. The docs' rule
    /// is "Below target after 4 hours: ISF is too low", so the low counts only with glucose at the suspend
    /// (`glucoseAtSuspend`, the mean of the readings at or before it) at or below the `target`: Trio also suspends on its
    /// forecast, with glucose still above it (`forecastSuspend`). And only when what went in, `givenUnits` (the bolus,
    /// plus insulin on board at it), was no more than a docs step over the docs' dose at the bolus,
    /// (start − target) ÷ ISF, nothing when glucose had come down to the target: a bigger bolus brings on a low whatever
    /// the ISF (`doseOverDocs`). Without a reading or the units to tell, the reason is the reading or the units missing.
    ///
    /// The docs' dose is first rounded up to the pump's bolus `increment` (zero rounds nothing), so a small dose the pump
    /// can only give rounded up (0.47 U as 0.50 U) keeps its verdict.
    static func lowNoVerdict(
        glucoseAtSuspend: Int?,
        startGlucose: Int?,
        givenUnits: Decimal?,
        target: Decimal?,
        isf: Decimal?,
        increment: Decimal,
        step: Decimal = ISFTest.Config.docsSmallestStep
    ) -> ISFTestNoVerdict? {
        guard let glucoseAtSuspend, let target else { return .noReadings }
        guard Decimal(glucoseAtSuspend) <= target else { return .forecastSuspend }
        guard let givenUnits else { return .noAmount }
        guard let startGlucose else { return .noReadings }
        guard let isf, isf > 0 else { return .noAmount }
        let docsDose = roundedUp(dose(glucose: startGlucose, target: target, isf: isf) ?? 0, to: increment)
        return givenUnits > docsDose * (1 + step) ? .doseOverDocs : nil
    }

    /// `units` rounded up to a whole number of the pump's bolus `increment`; as it is without one.
    static func roundedUp(_ units: Decimal, to increment: Decimal) -> Decimal {
        guard increment > 0 else { return units }
        return rounded(units / increment, scale: 0, roundingMode: .up) * increment
    }

    // MARK: - The screen's decisions

    /// The dose the Dose step shows: the docs' correction, (glucose − target) ÷ ISF, and in a test that counts insulin on
    /// board, less the insulin on board now (`countedDose`), as the docs' bolus calculator takes it off. To 2 decimals.
    /// Nil when it gives nothing to dose, and in a test that counts insulin on board Trio hasn't read recently (`iob` nil).
    /// `increment` is the pump's bolus increment, which a counted dose must reach.
    ///
    /// Carbs on board give none, and so do carbs on board Trio hasn't read recently (`carbsOnBoard` nil): the docs test
    /// ISF "when fasting (no COB)" (`carbsAllowDose`).
    static func testDose(
        glucose: Int,
        target: Decimal,
        isf: Decimal,
        handling: ISFTestIOBHandling?,
        iob: Decimal?,
        increment: Decimal = 0,
        carbsOnBoard: Decimal?
    ) -> Decimal? {
        guard carbsAllowDose(carbsOnBoard) else { return nil }
        return unroundedTestDose(glucose: glucose, target: target, isf: isf, handling: handling, iob: iob, increment: increment)
            .map { rounded($0, scale: 2, roundingMode: .plain) }
    }

    /// Whether carbs on board let the dose go ahead: only when Trio has read them, from a determination at most 12
    /// minutes old (`recentCOB`), and they are none. Unread is not none.
    static func carbsAllowDose(_ carbsOnBoard: Decimal?) -> Bool {
        guard let carbsOnBoard else { return false }
        return carbsOnBoard <= 0
    }

    /// The dose the Dose step shows before it is rounded to 2 decimals (`testDose`).
    static func unroundedTestDose(
        glucose: Int,
        target: Decimal,
        isf: Decimal,
        handling: ISFTestIOBHandling?,
        iob: Decimal?,
        increment: Decimal = 0
    ) -> Decimal? {
        guard handling == .count else { return unroundedDose(glucose: glucose, target: target, isf: isf) }
        guard let iob else { return nil }
        return unroundedCountedDose(glucose: glucose, target: target, isf: isf, iob: iob, increment: increment)
    }

    /// The docs' bolus calculator without carbs or a trend: "Total Insulin = (Current BG − Target BG) ÷ ISF + Carbs ÷ CR
    /// + Trend Correction − IOB", to 2 decimals. Insulin on board is signed, so basal Trio held back adds to the dose.
    /// Nil when glucose isn't above target, and when insulin on board leaves less than the pump can give: a dose that
    /// shows as 0.00 U, or one under the pump's bolus `increment`.
    static func countedDose(
        glucose: Int,
        target: Decimal,
        isf: Decimal,
        iob: Decimal,
        increment: Decimal = 0
    ) -> Decimal? {
        unroundedCountedDose(glucose: glucose, target: target, isf: isf, iob: iob, increment: increment)
            .map { rounded($0, scale: 2, roundingMode: .plain) }
    }

    /// `countedDose` before it is rounded. Insulin on board is taken off as shown, to 2 decimals, so the formula on screen
    /// adds up; whether there is a dose is decided on the dose as shown, so 0.004 U, shown as 0.00, is none.
    static func unroundedCountedDose(
        glucose: Int,
        target: Decimal,
        isf: Decimal,
        iob: Decimal,
        increment: Decimal = 0
    ) -> Decimal? {
        guard let correction = unroundedDose(glucose: glucose, target: target, isf: isf) else { return nil }
        let dose = correction - rounded(iob, scale: 2, roundingMode: .plain)
        let shown = rounded(dose, scale: 2, roundingMode: .plain)
        return shown > 0 && shown >= increment ? dose : nil
    }

    /// Insulin on board now for a counted dose: from the newest of Trio's determinations that holds an amount and is no
    /// more than `maxAge` old, as for the insulin on board at the bolus (`iobAtBolus`). Nil when there is none that
    /// recent, so the Dose step waits rather than take off an old amount.
    static func recentIOB(
        _ determinations: [ISFTestDetermination],
        now: Date,
        maxAge: TimeInterval = BasalTest.Config.endReadingMaxAge
    ) -> Decimal? {
        let oldest = now.addingTimeInterval(-maxAge)
        return determinations
            .filter { $0.iob != nil && !isBefore($0.date, oldest) }
            .max { $0.date < $1.date }?
            .iob
    }

    /// Insulin units as the screens show them, to 2 decimals, rounded half up as every comparison with them is
    /// (`shownSize`, `iobLine`, `countedDose`), so 2.245 U shows as 2.25, not 2.24.
    static func shownUnits(_ units: Decimal, locale: Locale = .autoupdatingCurrent) -> String {
        rounded(units, scale: 2, roundingMode: .plain).formatted(.number.precision(.fractionLength(2)).locale(locale))
    }

    /// Whether tablets can raise glucose before the dose: only with a target below the docs' starting glucose, the one
    /// number the docs give to raise it to. With a target at or above it, tablets would aim at or under the target, where
    /// the formula gives no dose.
    static func canRaise(target: Decimal, aim: Int = ISFTest.Config.docsStartAim) -> Bool {
        target < Decimal(aim)
    }

    /// Where a test starts: below the docs' starting glucose it raises glucose with tablets first, at or above it goes
    /// straight to the dose, and so does a test that can't raise it (`canRaise`).
    static func startPhase(glucose: Int, target: Decimal, aim: Int = ISFTest.Config.docsStartAim) -> ISFTestPhase {
        glucose < aim && canRaise(target: target, aim: aim) ? .raising : .dosing
    }

    /// What the test does first from `glucose`, as `startPhase` decides it, for the Check screen to say before Start. Nil
    /// without a reading or a target. Going straight to the dose with glucose at or below the target is a dead end: the
    /// formula gives no dose and tablets can't help, which happens only with a target of the docs' 150 or more.
    static func startPath(glucose: Int?, target: Decimal?, aim: Int = ISFTest.Config.docsStartAim) -> ISFTestStartPath? {
        guard let glucose, let target else { return nil }
        if startPhase(glucose: glucose, target: target, aim: aim) == .raising { return .raise }
        return Decimal(glucose) > target ? .dose : .noDose
    }

    // MARK: - Insulin on board and settling

    /// The docs' dose the test expects, which insulin on board is measured against: at the glucose now on the way
    /// straight to the dose, or, on the way through tablets, at the docs' starting glucose they aim for, (150 − target)
    /// ÷ ISF. Nil on a start path that leads to no dose, and without the settings or the reading to work it out.
    static func expectedDose(
        startPath: ISFTestStartPath?,
        glucose: Int?,
        target: Decimal?,
        isf: Decimal?,
        aim: Int = ISFTest.Config.docsStartAim
    ) -> Decimal? {
        guard let target, let isf else { return nil }
        switch startPath {
        case .dose: return glucose.flatMap { dose(glucose: $0, target: target, isf: isf) }
        case .raise: return dose(glucose: aim, target: target, isf: isf)
        case nil,
             .noDose: return nil
        }
    }

    /// The line insulin on board must be under, either way: the docs' smallest ISF change of the test's dose ("Make
    /// small changes: Adjust by 5-10% at a time"). Less than that sways the drop per unit by less than a docs step.
    /// Rounded to 2 decimals, as it is shown, so the line on screen is the one the test compares with.
    static func iobLine(expectedDose: Decimal, step: Decimal = ISFTest.Config.docsSmallestStep) -> Decimal {
        rounded(expectedDose * step, scale: 2, roundingMode: .plain)
    }

    /// What insulin on board at Begin means for the test, by its size either way (negative insulin on board is basal
    /// Trio held back): at or under the line it is fine, over it the user chooses, and more than the whole dose holds
    /// Begin up. Nil without an expected dose, and while Trio hasn't read insulin on board (`iob` nil): the rows say what
    /// there is to say, and settling waits for it.
    static func iobDecision(
        iob: Decimal?,
        expectedDose: Decimal?,
        step: Decimal = ISFTest.Config.docsSmallestStep
    ) -> ISFTestIOBDecision? {
        guard let iob, let expectedDose, expectedDose > 0 else { return nil }
        let line = iobLine(expectedDose: expectedDose, step: step)
        let size = shownSize(of: iob)
        if size <= line { return .fine }
        return size <= expectedDose ? .choice(line: line) : .blocked
    }

    /// The handling Begin saves: the user's choice when there was one to make, nil when there wasn't.
    static func iobHandling(for decision: ISFTestIOBDecision?, chosen: ISFTestIOBHandling) -> ISFTestIOBHandling? {
        if case .choice = decision { return chosen }
        return nil
    }

    /// When Trio first looped in Basal Testing: the first of its determinations at least `margin` after Begin, which is
    /// saved as `startedAt`. A loop already running at Begin read the settings from before. Nil until there is one.
    static func firstLoopInTestMode(
        _ determinations: [Date],
        startedAt: Date,
        margin: TimeInterval = ISFTest.Config.settleLoopMargin
    ) -> Date? {
        let earliest = startedAt.addingTimeInterval(margin)
        return determinations.filter { !isBefore($0, earliest) }.min()
    }

    /// Whether settling waits for insulin on board to come under the line: unless the test counts it. A test with no
    /// choice at Begin waits too, when an SMB given as it began pushed insulin on board over the line. Insulin on board
    /// Trio hasn't read (`iob` nil) isn't known to be under it, so it waits.
    static func waitsForIOB(iob: Decimal?, line: Decimal?, handling: ISFTestIOBHandling?) -> Bool {
        guard handling != .count, let line else { return false }
        guard let iob else { return true }
        return shownSize(of: iob) > line
    }

    /// Insulin on board's size either way, rounded to 2 decimals as the screens show it, so what is shown is what is
    /// compared with the line: 0.114 U shows and counts as 0.11.
    static func shownSize(of iob: Decimal) -> Decimal {
        rounded(abs(iob), scale: 2, roundingMode: .plain)
    }

    /// How many of the CGM `readings` (their dates) come after Trio's first loop in Basal Testing, `loopedAt`: those
    /// dated after it by at least the tolerance (`isAfter`). A reading from before the loop, or at it, came while Trio
    /// still dosed as it did before Begin.
    static func readingsAfterLoop(_ readings: [Date], loopedAt: Date) -> Int {
        readings.filter { isAfter($0, loopedAt) }.count
    }

    /// Where settling is. It ends once Trio has looped in Basal Testing (`firstLoopInTestMode`), the CGM has had
    /// `readingsNeeded` readings since that loop (`readingsAfterLoop`: the 3 the dose glucose averages, so it and the
    /// CGM's arrow no longer reflect the mode before Begin), and, unless the test counts it, insulin on board is at or
    /// under the line (`waitsForIOB`). Once `allowance` from Begin is up with insulin on board still over the line, the
    /// screen asks whether to count it; with no loop in Basal Testing yet (`noLoop`), or too few readings since it
    /// (`tooFewReadings`), counting can't help, so it says so.
    ///
    /// It also waits while a temp basal runs on the pump (`tempBasalRunning`): Basal Testing cancels Trio's own when it
    /// is switched on, and one still running then (a cancel that failed, or one set on the pump) would change the basal
    /// the test runs on. Nil when the pump's state can't be read, which doesn't hold settling up. Once the time is up
    /// with one still running, it says so (`tempBasalRunning`), and counting can't help either.
    static func settling(
        startedAt: Date,
        determinations: [Date],
        readings: [Date],
        tempBasalRunning: Bool?,
        iob: Decimal?,
        line: Decimal?,
        handling: ISFTestIOBHandling?,
        now: Date,
        margin: TimeInterval = ISFTest.Config.settleLoopMargin,
        allowance: TimeInterval = ISFTest.Config.settleAllowance,
        readingsNeeded: Int = ISFTest.Config.settleReadings
    ) -> ISFTestSettling {
        let loopedAt = firstLoopInTestMode(determinations, startedAt: startedAt, margin: margin)
        let waits = waitsForIOB(iob: iob, line: line, handling: handling)
        let timeUp = now >= startedAt.addingTimeInterval(allowance)
        guard let loopedAt else { return timeUp ? .noLoop : .waiting(loopedAt: nil, waitsForIOB: waits) }
        guard readingsAfterLoop(readings, loopedAt: loopedAt) >= readingsNeeded else {
            return timeUp ? .tooFewReadings(loopedAt: loopedAt) : .waiting(loopedAt: loopedAt, waitsForIOB: waits)
        }
        guard tempBasalRunning != true else {
            return timeUp ? .tempBasalRunning(loopedAt: loopedAt) : .waiting(loopedAt: loopedAt, waitsForIOB: waits)
        }
        guard waits else { return .settled }
        return timeUp ? .timeUp(loopedAt: loopedAt) : .waiting(loopedAt: loopedAt, waitsForIOB: true)
    }

    /// Whether a tick may end settling: only while this test's session is still the running one, Basal Testing is on,
    /// and the latest a bolus window could close hasn't come (`noBolusDeadline`). Otherwise the running check ends the
    /// test as settling not finishing (`settlingTimedOut`), or for what changed, and a test opened after the service
    /// ended it isn't started again.
    static func canSettle(
        sessionID: UUID?,
        activeSessionID: UUID?,
        mode: DosingMode,
        now: Date,
        noBolusDeadline: Date
    ) -> Bool {
        guard let sessionID, activeSessionID == sessionID else { return false }
        return mode == .basalTesting && now < noBolusDeadline
    }

    /// The ISF schedule entries a test begun at `startedAt` can run on, saved at Begin: every hour its 4 hours can reach,
    /// so an ISF edited before the bolus is found doesn't become what the test ran on. The latest end is settling's
    /// bound (`noBolusDeadline`, the time for settling and the dose), then a whole bolus window from there and the docs'
    /// 4 hours after it.
    static func coveredAtBegin(
        _ entries: [SettingsTestScheduleEntry],
        startedAt: Date,
        calendar: Calendar = .current
    ) -> [SettingsTestScheduleEntry]? {
        coveredEntries(
            entries,
            from: startedAt,
            to: startedAt.addingTimeInterval(
                ISFTest.Config.settleAllowance + 2 * ISFTest.Config.doseAllowance + ISFTest.Config.docsWait
            ),
            calendar: calendar
        )
    }

    /// Whole minutes left of the time settling waits for insulin on board, at `now`, rounded down, so a minute isn't
    /// counted that has started to run.
    static func settleMinutesLeft(
        startedAt: Date,
        now: Date,
        allowance: TimeInterval = ISFTest.Config.settleAllowance
    ) -> Int {
        Int((settleTimeLeft(startedAt: startedAt, now: now, allowance: allowance) / 60).rounded(.down))
    }

    /// What is left of the time settling waits for insulin on board, never below zero.
    static func settleTimeLeft(
        startedAt: Date,
        now: Date,
        allowance: TimeInterval = ISFTest.Config.settleAllowance
    ) -> TimeInterval {
        max(0, startedAt.addingTimeInterval(allowance).timeIntervalSince(now))
    }

    /// Where settling moves on to, from the glucose as it ends (`startPhase`), since glucose can move in up to an hour of
    /// settling: below the docs' 150, with a target under it, tablets first, otherwise the dose. Without a recent
    /// reading, the phase Begin planned from the glucose then, and the dose without one. The expected dose and the line
    /// stay as Begin fixed them. The target is the one in force at `date`, as the Dose step works the dose out with it
    /// (`doseSettings`).
    static func phaseAfterSettling(
        _ test: ISFTestState,
        glucose: Int?,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) -> ISFTestPhase {
        if let glucose {
            return startPhase(glucose: glucose, target: doseSettings(of: test, at: date, calendar: calendar).target)
        }
        return test.plannedPhase == .raising ? .raising : .dosing
    }

    /// The boluses given while settling, oldest first: from Begin to the end of settling, to now while it runs. An SMB
    /// Trio decided before Begin and gave after it can't be told from any other bolus, so each one is shown and none is
    /// the test bolus, which is looked for from the end of settling (`testBolus`). Both edges are exact: Begin, as the
    /// test bolus's start edge was, and the end of settling, so a bolus is either here or a candidate for the test bolus.
    ///
    /// `smbs` are the rows the pump history flags as SMBs, the same rows read with their flag; a bolus at one's
    /// timestamp is that SMB. Nil when they couldn't be read, so none is called one.
    static func settlingBoluses(
        _ boluses: [ISFTestBolus],
        smbs: [BasalTestSMB]?,
        startedAt: Date,
        settledAt: Date?
    ) -> [ISFTestSettlingBolus] {
        let smbDates = Set((smbs ?? []).map(\.date))
        return boluses
            .filter { bolus in bolus.date >= startedAt && settledAt.map { bolus.date < $0 } ?? true }
            .sorted { $0.date < $1.date }
            .map { ISFTestSettlingBolus(date: $0.date, units: $0.units, isSMB: smbDates.contains($0.date)) }
    }

    /// Insulin on board just before the bolus, signed: from the newest determination that holds an amount and is dated
    /// before the bolus by at least the tolerance (`isBefore`), so the bolus itself isn't in it, and no more than
    /// `maxAge` before it, the age at which Trio's own loop calls glucose too old (`BasalTest.Config.endReadingMaxAge`).
    /// Nil when there is none that recent, so a count of it isn't trusted (`iobUnread`).
    static func iobAtBolus(
        _ determinations: [ISFTestDetermination],
        bolusAt: Date,
        maxAge: TimeInterval = BasalTest.Config.endReadingMaxAge
    ) -> Decimal? {
        let oldest = bolusAt.addingTimeInterval(-maxAge)
        return determinations
            .filter { $0.iob != nil && isBefore($0.date, bolusAt) && !isBefore($0.date, oldest) }
            .max { $0.date < $1.date }?
            .iob
    }

    /// The units given, as the Result screen words them: the bolus, then the insulin on board at it the units count
    /// (`shownIOBAtBolus`), "2.00 U plus 0.24 U on board", or for negative insulin on board "2.00 U less 0.30 U Trio held
    /// back". Each amount keeps its unit beside it. Nil without units given (`givenUnits`).
    static func unitsText(of test: ISFTestState, format: (Decimal) -> String) -> String? {
        guard ISFTestEvaluator.givenUnits(of: test) != nil, let bolus = test.bolusUnits else { return nil }
        let bolusText = SettingsTestFormat.keepTogether(format(bolus), unit: "U")
        guard let iob = shownIOBAtBolus(of: test) else { return bolusText }
        let iobText = SettingsTestFormat.keepTogether(format(abs(iob)), unit: "U")
        return iob < 0
            ? String(localized: "\(bolusText) less \(iobText) Trio held back")
            : String(localized: "\(bolusText) plus \(iobText) on board")
    }

    /// The units that went in: the bolus as the pump history holds it (`bolusAmount`), plus the insulin on board at it,
    /// signed, so basal Trio held back takes from it. Counted whether the test waited for it or counts it: its remainder
    /// at the planned end is left out of the units judged either way (`judgedUnits`), so leaving it out here would judge
    /// fewer units than acted. The line then only limits how much there is. Nil without a bolus amount, and when the
    /// insulin on board at it couldn't be read (`iobAtBolusUnread`).
    static func givenUnits(of test: ISFTestState) -> Decimal? {
        guard let bolus = test.bolusUnits else { return nil }
        return test.iobAtBolus.map { bolus + $0 }
    }

    /// The insulin on board at the bolus the Result shows beside it, signed: in a test that counts it, whatever it was;
    /// otherwise when it shows as more than 0.00 U, since a test that waited for it has it under the line. Nil when there
    /// is none to show.
    static func shownIOBAtBolus(of test: ISFTestState) -> Decimal? {
        guard let iob = test.iobAtBolus else { return nil }
        return test.iobHandling == .count || shownSize(of: iob) != 0 ? iob : nil
    }

    /// The units the result is judged by: those that acted by the docs' 4 hours, the units given (`givenUnits`) less the
    /// insulin on board Trio reports still left at the planned end (`iobAtEnd`), signed. Trio's insulin curve leaves part
    /// of a bolus working after 4 hours, more than the docs' 5% step, so judging on the whole bolus would read an
    /// accurate ISF as too high. Nil without units given, and while the insulin left at the end hasn't been read.
    static func judgedUnits(of test: ISFTestState) -> Decimal? {
        guard let given = givenUnits(of: test), let left = test.iobAtEnd else { return nil }
        return given - left
    }

    /// Whether the insulin on board at the test's bolus, which the units given count (`givenUnits`), couldn't be read.
    static func iobAtBolusUnread(of test: ISFTestState) -> Bool {
        test.bolusAt != nil && test.iobAtBolus == nil
    }

    /// Whether a test that ran its 4 hours couldn't read the insulin on board left at the planned end.
    static func iobAtEndUnread(of test: ISFTestState) -> Bool {
        test.bolusAt != nil && test.endReason == .completed && test.iobAtEnd == nil
    }

    /// Whether insulin on board the units judged rest on couldn't be read, at the bolus or left at
    /// the planned end, so there is no verdict but a low's, with the words for a record that couldn't be read.
    static func iobUnread(of test: ISFTestState) -> Bool {
        iobAtBolusUnread(of: test) || iobAtEndUnread(of: test)
    }

    /// Insulin on board left at the planned end, signed: from the newest determination that holds an amount and is dated
    /// at or before `plannedEnd` (a date worked out from the saved bolus, so one at the same moment is at it,
    /// `isAfter`), and no more than `maxAge` before it, the same source and age as the insulin on board at the bolus
    /// (`iobAtBolus`). Nil when there is none that recent, so the units judged aren't trusted (`iobUnread`).
    static func iobAtEnd(
        _ determinations: [ISFTestDetermination],
        plannedEnd: Date,
        maxAge: TimeInterval = BasalTest.Config.endReadingMaxAge
    ) -> Decimal? {
        let oldest = plannedEnd.addingTimeInterval(-maxAge)
        return determinations
            .filter { $0.iob != nil && !isAfter($0.date, plannedEnd) && !isBefore($0.date, oldest) }
            .max { $0.date < $1.date }?
            .iob
    }

    /// The glucose the test ended at, in mg/dL, from `fetched`, the readings from an hour before the bolus to `end`: the
    /// mean of the last 3 at or before `end` (`BasalTestEvaluator.endGlucose`), which is a date saved in the test's state
    /// or worked out from one, so a reading at the same moment is at it. For a low, the readings at Trio's suspend
    /// whenever they came, so a suspend soon after the bolus still has a glucose to hold against the target
    /// (`lowNoVerdict`). Otherwise only readings from the bolus on: one from before it is not where the 4 hours ended.
    /// Nil without a bolus, and without a reading recent enough at the end.
    static func endGlucose(
        _ fetched: [BasalTestReading],
        bolusAt: Date?,
        end: Date,
        reason: ISFTestEndReason
    ) -> Int? {
        guard let bolusAt else { return nil }
        let atEnd = readings(fetched, atOrBefore: end)
        let counted = reason == .low ? atEnd : readings(atEnd, since: bolusAt)
        return BasalTestEvaluator.endGlucose(from: counted, endingAt: end)
    }

    /// Why the Raise step has no tablets to count, nil when it has (`tabletCarbs` is above zero for an ISF above zero).
    /// A missing reading comes first, then a missing carb ratio, then glucose already at or above the aim.
    static func noTabletsReason(
        glucose: Int?,
        carbRatio: Decimal?,
        aim: Int = ISFTest.Config.docsStartAim
    ) -> ISFTestNoTablets? {
        guard let glucose else { return .noRecentReading }
        guard let carbRatio, carbRatio > 0 else { return .noCarbRatio }
        return glucose >= aim ? .atOrAboveAim : nil
    }

    /// What the Check screen says about the newest basal test, which ISF is tested on. `.lastWasNot` with `.keep`
    /// doesn't happen (a steady test is `.ready` or `.changedSince`), so it reads as no steady test.
    static func basalGateText(
        _ gate: SettingsTestSchedule.BasalGate,
        now: Date = Date(),
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        switch gate {
        case let .ready(lastSteady):
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.dateTimeStyle = .named
            let when = formatter.localizedString(for: lastSteady, relativeTo: now)
            return String(localized: "Last basal test was steady, \(when)")
        case .noSteadyTest:
            return String(localized: "No steady basal test yet")
        case .changedSince:
            return String(localized: "Basal rates changed since the last test")
        case let .lastWasNot(direction, _):
            switch direction {
            case .increase: return String(localized: "The last basal test said basal looks too low")
            case .decrease: return String(localized: "The last basal test said basal looks too high")
            case .keep: return String(localized: "No steady basal test yet")
            }
        }
    }

    /// Which of the Check screen's readings warn rather than only inform: a basal gate that isn't ready (the hub's note
    /// shows for the same gates, `SettingsTestKind.isfGateNote`), 4 hours that cover more than one ISF, and a low
    /// threshold at or above the target. None of them blocks the start. (The dead end at a high target does:
    /// `noDoseBlocksBegin`.)
    static func warnings(
        basalGate: SettingsTestSchedule.BasalGate,
        crossesISFChange: Bool,
        lowThresholdAtTarget: Bool
    ) -> Set<ISFTestWarning> {
        var warnings: Set<ISFTestWarning> = []
        switch basalGate {
        case .ready: break
        case .changedSince,
             .lastWasNot,
             .noSteadyTest: warnings.insert(.basalNotSteady)
        }
        if crossesISFChange { warnings.insert(.isfChanges) }
        if lowThresholdAtTarget { warnings.insert(.lowThreshold) }
        return warnings
    }

    /// Whether the start path holds up Begin: at or below a target of the docs' 150 or more (`.noDose`), the docs'
    /// formula gives no dose and tablets have nothing above the target to aim for, so a test begun there could only
    /// dose later with none of insulin on board's checks behind it.
    static func noDoseBlocksBegin(startPath: ISFTestStartPath?) -> Bool {
        startPath == .noDose
    }

    /// Whether the pump's basal delivery holds up Begin: suspended (or suspending, resuming, or not working). A pump
    /// state that can't be read doesn't: the devices check covers a missing pump, and the pump history then shows a
    /// suspend during the test (`ISFTestEvaluator.ending(for: .pumpInterrupted)`).
    static func pumpBlocksBegin(_ delivery: ISFTestPumpDelivery?) -> Bool {
        delivery == .suspended
    }

    /// Whether carbs on board hold up Begin: any at all. The docs test ISF with no carbs on board ("Test ISF with
    /// correction boluses when fasting (no COB)"), a docs rule, so it blocks rather than informs; the Dose step gives no
    /// dose for the same reason (`noDoseReason`). Not read yet, they don't hold it up, as insulin on board doesn't: the
    /// Dose step waits for a read that says none (`carbsAllowDose`).
    static func carbsOnBoardBlockBegin(_ carbsOnBoard: Decimal?) -> Bool {
        (carbsOnBoard ?? 0) > 0
    }

    /// Carbs on board now: from the newest of Trio's determinations that holds them and is no more than `maxAge` old,
    /// the same source and age as insulin on board for the dose (`recentIOB`). Nil when there is none that recent, so
    /// carbs that weren't read never pass as none.
    static func recentCOB(
        _ determinations: [ISFTestDetermination],
        now: Date,
        maxAge: TimeInterval = BasalTest.Config.endReadingMaxAge
    ) -> Decimal? {
        let oldest = now.addingTimeInterval(-maxAge)
        return determinations
            .filter { $0.cob != nil && !isBefore($0.date, oldest) }
            .max { $0.date < $1.date }?
            .cob
    }

    /// Carbs on board at the bolus: from the newest determination that holds them, dated at or before the bolus and no
    /// more than `maxAge` before it. Nil when there is none that recent.
    static func cobAtBolus(
        _ determinations: [ISFTestDetermination],
        bolusAt: Date,
        maxAge: TimeInterval = BasalTest.Config.endReadingMaxAge
    ) -> Decimal? {
        let oldest = bolusAt.addingTimeInterval(-maxAge)
        return determinations
            .filter { $0.cob != nil && !isAfter($0.date, bolusAt) && !isBefore($0.date, oldest) }
            .max { $0.date < $1.date }?
            .cob
    }

    /// The first condition the Dose step holds the dose for that didn't hold at the test bolus, at `bolusAt`, in the
    /// Dose step's order, or nil when they all held. A bolus can come from Home, the pump or the Watch (R2), so a spoiled
    /// one is caught here and not judged. Everything is judged from the bolus moment: the start glucose then
    /// (`startGlucose`, the mean of the last 3 readings at or before the bolus), and the target and ISF in force then.
    /// - the start glucose is read (`startGlucose`), and above the `target`: the docs' formula, (glucose − target) ÷ ISF,
    ///   gives a dose only above it;
    /// - the tablets, when taken (`tabletsTakenAt`), had acted and glucose had leveled off: latched when the Dose step first
    ///   offered the dose (`tabletsLeveledAt`), so plateau noise since doesn't refuse it; without the latch (a state saved
    ///   before it was kept, a bolus before the step offered one), on the readings at or before the bolus (`tabletsActed`,
    ///   then `tabletsLeveledOff`; still rising, it was still moving, `glucoseMoving`);
    /// - the CGM's arrow on the newest reading at or before the bolus, no more than `maxAge` before it, is flat or absent
    ///   (`isLevel`, R6);
    /// - carbs on board from the newest determination at most `maxAge` before the bolus are none (`cobAtBolus`);
    /// - unless the test counts it, insulin on board just before the bolus (`iobAtBolus`) is at or under the line, the
    ///   docs' smallest ISF change of the docs' dose at the bolus (`doseIOBLine`, from `startGlucose`, `target`, `isf`);
    /// - the docs' 4 hours cover one ISF value of `isfEntries`, the schedule Begin saved (`crossesISFChange`): "Test one
    ///   time period at a time". From `doseOfferedAt`, the last moment the Dose step offered the dose, when that is at or
    ///   before the bolus and the offer still stood at it, no check before the bolus having found it gone
    ///   (`doseOfferEndedAt`) (N4: a bolus a minute after the offer, given from Treatments, isn't refused for that
    ///   minute); from the bolus otherwise, so a bolus long after the offer went away is judged on its own 4 hours.
    /// A reading or determination that couldn't be read, or isn't recent enough, is `unread`: nothing can be judged
    /// that can't be checked.
    static func failedBolusCondition(
        bolusAt: Date,
        startGlucose: Int?,
        target: Decimal,
        isf: Decimal,
        readings: [BasalTestReading]?,
        tabletsTakenAt: Date?,
        tabletsGlucose: Int?,
        arrow: ISFTestArrowReading?,
        determinations: [ISFTestDetermination]?,
        handling: ISFTestIOBHandling?,
        isfEntries: [SettingsTestScheduleEntry]? = nil,
        tabletsLeveledAt: Date? = nil,
        doseOfferedAt: Date? = nil,
        doseOfferEndedAt: Date? = nil,
        maxAge: TimeInterval = BasalTest.Config.endReadingMaxAge,
        calendar: Calendar = .current
    ) -> ISFTestBolusCondition? {
        guard let startGlucose else { return .unread }
        guard Decimal(startGlucose) > target else { return .atOrBelowTarget }
        let latched = tabletsLeveledAt.map { !isAfter($0, bolusAt) } ?? false
        if let tabletsTakenAt, !latched {
            guard let readings else { return .unread }
            let atBolus = Self.readings(readings, atOrBefore: bolusAt)
            guard tabletsActed(atBolus, tabletsTakenAt: tabletsTakenAt, glucoseAtTablets: tabletsGlucose, at: bolusAt) else {
                return .tabletsNotActed
            }
            guard tabletsLeveledOff(atBolus, tabletsTakenAt: tabletsTakenAt, glucoseAtTablets: tabletsGlucose, at: bolusAt)
            else { return .glucoseMoving }
        }
        guard let arrow, !isAfter(arrow.date, bolusAt), !isBefore(arrow.date, bolusAt.addingTimeInterval(-maxAge)) else {
            return .unread
        }
        guard isLevel(direction: arrow.direction, hasRecentReading: true) else { return .glucoseMoving }
        guard let determinations, let cob = cobAtBolus(determinations, bolusAt: bolusAt, maxAge: maxAge) else {
            return .unread
        }
        guard cob <= 0 else { return .carbsOnBoard }
        // No line in a test that counts insulin on board, which takes it off the dose instead (`doseIOBLine`).
        let docsDose = dose(glucose: startGlucose, target: target, isf: isf)
        if let line = doseIOBLine(dose: docsDose, handling: handling) {
            guard let iob = iobAtBolus(determinations, bolusAt: bolusAt, maxAge: maxAge) else { return .unread }
            if waitsForIOB(iob: iob, line: line, handling: handling) { return .iobOverLine }
        }
        let offerStood = doseOfferEndedAt.map { isAfter($0, bolusAt) } ?? true
        let offeredAt = doseOfferedAt.flatMap { isAfter($0, bolusAt) || !offerStood ? nil : $0 } ?? bolusAt
        if let isfEntries,
           crossesISFChange(isfEntries, from: offeredAt, for: ISFTest.Config.docsWait, calendar: calendar)
        {
            return .isfChanges
        }
        return nil
    }

    /// What the Result says when a record read to check the test couldn't be read.
    static var historyUnreadNote: String {
        String(localized: "Trio couldn't read part of the history to check the test, so it can't say what your ISF did.")
    }

    /// Whether the low threshold Basal Testing suspends at, `threshold` (the user's, or 72 mg/dL if that is higher), is at
    /// or above the `target`: after the dose Trio's forecast heads for the target, so it may suspend right after it, and
    /// a suspend with glucose still above the target gives no verdict (`lowNoVerdict`). False without a target.
    static func lowThresholdAtTarget(threshold: Decimal, target: Decimal?) -> Bool {
        guard let target else { return false }
        return threshold >= target
    }

    /// The steps the step bar shows as skipped rather than done: Raise once the test is past it with no tablets taken,
    /// and Dose and Wait when it finished without a bolus. Nothing before Begin. Settle never: it runs from Begin, and a
    /// test begun before it was kept started straight away. Tablets taken before going back from the Dose step count, as
    /// the Result screen's record of them does (`takenTablets`).
    static func skippedSteps(of test: ISFTestState?) -> Set<ISFTest.Step> {
        guard let test else { return [] }
        var skipped: Set<ISFTest.Step> = []
        if test.phase != .settling, test.phase != .raising,
           takenTablets(carbs: test.tabletCarbs, brand: test.tabletBrand) == nil
        {
            skipped.insert(.raise)
        }
        if test.phase == .finished, test.bolusAt == nil {
            skipped.formUnion([.dose, .wait])
        }
        return skipped
    }

    /// Whether a formula's result follows "≈" instead of "=": when showing it to `fractionDigits` rounds it, or when
    /// glucose shows in mmol/L, whose rounded values don't reproduce a result worked out in mg/dL.
    static func isApproximate(_ exact: Decimal, fractionDigits: Int, units: GlucoseUnits) -> Bool {
        units == .mmolL || rounded(exact, scale: fractionDigits, roundingMode: .plain) != exact
    }

    /// Whether the CGM shows glucose leveled off: a flat arrow, or no arrow for a recent reading (`hasRecentReading`), so
    /// a CGM without arrows (R6) doesn't hold the test up but one that stopped reading doesn't pass for level. A rate
    /// beyond the CGM's arrows is moving.
    static func isLevel(direction: BloodGlucose.Direction?, hasRecentReading: Bool) -> Bool {
        // No arrow at all. (`.none` below is the CGM's own "no direction", not a missing one.)
        guard let direction else { return hasRecentReading }
        switch direction {
        case .flat:
            return true
        case .none,
             .notComputable:
            return hasRecentReading
        case .doubleDown,
             .doubleUp,
             .fortyFiveDown,
             .fortyFiveUp,
             .rateOutOfRange,
             .singleDown,
             .singleUp,
             .tripleDown,
             .tripleUp:
            return false
        }
    }

    /// Whether the tablets have acted: the mean of the newest 3 readings, all dated after `tabletsTakenAt` (a date saved
    /// in the test's state, so one at the same moment is at it, `isAfter`), is above the glucose they were counted from,
    /// the same 3-reading mean (`BasalTestEvaluator.endGlucose`, read at `moment`, or at the newest reading without one),
    /// so a reading or two from before they acted, or a small blip on one reading, can't unlock the dose; and the CGM's own
    /// arrow showed glucose rising on a reading after them that is above the base (`roseByArrow`), since a mean a mg/dL
    /// over the base is noise as often as a rise (R1, L1). Whether glucose has then leveled off is
    /// `tabletsLeveledOff`. `glucoseAtTablets` is the glucose saved when they were taken; a state saved before it was kept
    /// uses the same mean at or before then. False without a glucose to rise from, and with fewer than 3 readings after
    /// them.
    static func tabletsActed(
        _ readings: [BasalTestReading],
        tabletsTakenAt: Date,
        glucoseAtTablets: Int?,
        at moment: Date? = nil
    ) -> Bool {
        let base = glucoseAtTablets ?? BasalTestEvaluator.endGlucose(
            from: Self.readings(readings, atOrBefore: tabletsTakenAt),
            endingAt: tabletsTakenAt
        )
        guard let base else { return false }
        let count = ISFTest.Config.meanReadings
        let after = readings.filter { isAfter($0.date, tabletsTakenAt) }.sorted { $0.date < $1.date }
        guard after.count >= count, let newest = after.last,
              let mean = BasalTestEvaluator.endGlucose(from: Array(after.suffix(count)), endingAt: moment ?? newest.date)
        else { return false }
        return mean > base && roseByArrow(after, above: base)
    }

    /// Whether the CGM's own arrow showed glucose rising (any up arrow) on one of `readings`, those after the tablets, on a
    /// reading above `base`, the glucose they were counted from, so an arrow carried from the trend before them on a
    /// reading at or below the base doesn't count (L1). A CGM that gives no arrows on them (none, or only "none" and "not
    /// computable") keeps R6: the readings alone say it rose.
    static func roseByArrow(_ readings: [BasalTestReading], above base: Int) -> Bool {
        let arrows = readings.compactMap(\.direction).filter { $0 != .none && $0 != .notComputable }
        guard !arrows.isEmpty else { return true }
        let up: [BloodGlucose.Direction] = [.fortyFiveUp, .singleUp, .doubleUp, .tripleUp]
        return readings.contains { reading in
            reading.glucose > base && reading.direction.map { up.contains($0) } == true
        }
    }

    /// Whether glucose has leveled off after the tablets: they acted, so it rose from the glucose they were counted from
    /// (`tabletsActed`), and then it stopped rising, the newest 3-reading mean no higher than the 3-reading mean of the 3
    /// readings before those (`BasalTestEvaluator.endGlucose`). A flat arrow alone shows before the rise does, so it can't
    /// say the rise is over (C1). Easing back down from the rise has stopped rising too; the CGM's arrow, read beside this
    /// (`isLevel`), says whether glucose is level. False without 3 readings before the newest 3, since then it can't be
    /// told that glucose stopped rising.
    static func tabletsLeveledOff(
        _ readings: [BasalTestReading],
        tabletsTakenAt: Date,
        glucoseAtTablets: Int?,
        at moment: Date? = nil
    ) -> Bool {
        guard tabletsActed(readings, tabletsTakenAt: tabletsTakenAt, glucoseAtTablets: glucoseAtTablets, at: moment)
        else { return false }
        let count = ISFTest.Config.meanReadings
        let sorted = readings.sorted { $0.date < $1.date }
        let newest = Array(sorted.suffix(count))
        let before = Array(sorted.dropLast(count).suffix(count))
        guard let first = newest.first, let last = newest.last,
              let mean = BasalTestEvaluator.endGlucose(from: newest, endingAt: moment ?? last.date),
              let previous = BasalTestEvaluator.endGlucose(from: before, endingAt: first.date)
        else { return false }
        return mean <= previous
    }

    /// Whether the dose can be worked out. Dosing, when the docs' formula gives one, glucose has leveled off (`isLevel`,
    /// as `isLevel(direction:hasRecentReading:)` says) and insulin on board doesn't hold it up (`iobAllowsDose`); after
    /// tablets, also while glucose hasn't started rising again (`tabletsLeveledOff`), as the bolus check holds it
    /// (`failedBolusCondition`). Raising, once tablets were taken, glucose has risen from them (`tabletsActed`) and
    /// stopped rising (`tabletsLeveledOff`) with a level arrow, so a flat reading from before the tablets acted, or from
    /// the start of their rise, can't unlock the dose. Either way only with carbs on board read and none
    /// (`carbsAllowDose`). Never once the bolus is in.
    static func canDose(
        phase: ISFTestPhase,
        tabletsTaken: Bool,
        tabletsActed: Bool,
        tabletsLeveledOff: Bool,
        isLevel: Bool,
        dose: Decimal?,
        iobAllowsDose: Bool,
        carbsOnBoard: Decimal?
    ) -> Bool {
        guard carbsAllowDose(carbsOnBoard) else { return false }
        switch phase {
        case .dosing:
            return dose != nil && isLevel && iobAllowsDose && (!tabletsTaken || tabletsLeveledOff)
        case .raising:
            return tabletsTaken && tabletsActed && tabletsLeveledOff && isLevel
        case .finished,
             .settling,
             .waiting:
            return false
        }
    }

    /// The line insulin on board must be under before the dose, in a test that doesn't count it, recomputed from the
    /// `dose` the Dose step shows (`iobLine`), so a dose smaller than Begin expected gets a line to match: the docs'
    /// smallest ISF change of it. Nil when there is no dose, and in a test that counts insulin on board, which takes it
    /// off the dose instead.
    static func doseIOBLine(dose: Decimal?, handling: ISFTestIOBHandling?) -> Decimal? {
        guard handling != .count, let dose, dose > 0 else { return nil }
        return iobLine(expectedDose: dose)
    }

    /// Whether insulin on board lets the dose go ahead: always in a test that counts it; otherwise once it is at or under
    /// the line from the dose shown (`doseIOBLine`, `waitsForIOB`). Insulin on board Trio hasn't read isn't known to be
    /// under it.
    static func iobAllowsDose(iob: Decimal?, dose: Decimal?, handling: ISFTestIOBHandling?) -> Bool {
        guard let line = doseIOBLine(dose: dose, handling: handling) else { return true }
        return !waitsForIOB(iob: iob, line: line, handling: handling)
    }

    /// The value in force at `date` in a schedule saved in the test's state (`coveredEntries`, `targetEntries`): the
    /// entry whose minutes of the day hold it. Nil without a schedule or an entry there, so the caller keeps the value
    /// saved at Start.
    static func scheduleValue(
        in entries: [SettingsTestScheduleEntry]?,
        at date: Date,
        calendar: Calendar = .current
    ) -> Decimal? {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return entries?.first { $0.startMinutes <= minute && minute < $0.endMinutes }?.value
    }

    /// The ISF and target the Dose step works the dose out with at `date`: those in force then, from the schedules saved
    /// at Begin, or the ones saved at Start without them.
    static func doseSettings(
        of test: ISFTestState,
        at date: Date,
        calendar: Calendar = .current
    ) -> (isf: Decimal, target: Decimal) {
        (
            isf: scheduleValue(in: test.coveredEntries, at: date, calendar: calendar) ?? test.isf,
            target: scheduleValue(in: test.targetEntries, at: date, calendar: calendar) ?? test.target
        )
    }

    /// The test as it moves on to the 4 hours with its bolus at `bolusAt`: the ISF and target the result uses become
    /// those in force at the bolus (`doseSettings`), from the schedules saved at Begin, and the ISF schedule narrows to the
    /// 4 hours from the bolus.
    static func atBolus(_ test: ISFTestState, bolusAt: Date, calendar: Calendar = .current) -> ISFTestState {
        var moved = test
        let settings = doseSettings(of: test, at: bolusAt, calendar: calendar)
        moved.isf = settings.isf
        moved.target = settings.target
        moved.coveredEntries = coveredEntries(
            test.coveredEntries ?? [],
            from: bolusAt,
            to: bolusAt.addingTimeInterval(ISFTest.Config.docsWait),
            calendar: calendar
        )
        return moved
    }

    /// Why the Dose step has no dose, for it to say. Nil when it has one (`testDose`). Missing settings come first,
    /// because waiting for a reading wouldn't help, then carbs on board, which the docs test ISF without ("Test ISF with
    /// correction boluses when fasting (no COB)"), so no dose is offered whatever glucose is, and carbs on board Trio
    /// hasn't read recently, which can't be told from none (`carbsUnread`), then the reading, then
    /// glucose at or below the target; then, in a test that counts insulin on board, insulin on board not read yet, or
    /// covering the correction; and last, the 4 hours from now covering more than one ISF value (`crossesISFChange`),
    /// which time moves past, so a dead end or a reading to wait for says what it says first: a wait while a moment before
    /// the dose deadline has its 4 hours on one value (`isfChangeClearsBeforeDeadline`), a dead end otherwise (N1).
    static func noDoseReason(
        glucose: Int?,
        target: Decimal?,
        isf: Decimal?,
        handling: ISFTestIOBHandling? = nil,
        iob: Decimal? = nil,
        increment: Decimal = 0,
        carbsOnBoard: Decimal?,
        crossesISFChange: Bool = false,
        isfChangeClearsBeforeDeadline: Bool = true
    ) -> ISFTestNoDose? {
        guard let target, let isf, isf > 0 else { return .noSettings }
        // Read and above none, a dead end; not read, a wait.
        guard let carbsOnBoard else { return .carbsUnread }
        guard carbsAllowDose(carbsOnBoard) else { return .carbsOnBoard }
        guard let glucose else { return .noRecentReading }
        guard dose(glucose: glucose, target: target, isf: isf) != nil else { return .atOrBelowTarget }
        if handling == .count {
            guard let iob else { return .iobUnread }
            let counted = countedDose(glucose: glucose, target: target, isf: isf, iob: iob, increment: increment)
            if counted == nil { return .iobCoversDose }
        }
        guard crossesISFChange else { return nil }
        return isfChangeClearsBeforeDeadline ? .isfChanges : .isfChangesUntilDeadline
    }

    /// The check a tick acts on. Before the bolus, on a tick where the boluses couldn't be read, no bolus can't be told
    /// from one not seen yet, nor a low before the dose from one after it, so those wait for a tick that reads them. The
    /// service's watchdog still ends a test that really had no bolus, and its own read brings the usual mode back for a
    /// low. The other checks end the test whether or not the bolus came.
    static func decidable(_ check: RunningCheck?, bolusesRead: Bool) -> RunningCheck? {
        guard !bolusesRead, let check else { return check }
        switch check {
        case .lowBeforeDose,
             .noBolus:
            return nil
        case .bolusCancelled,
             .bolusNotSeen,
             .carbsLogged,
             .carbsUnreadable,
             .completed,
             .completedUnchecked,
             .extraBolus,
             .low,
             .modeChanged,
             .modeChangedRestored,
             .pumpInterrupted,
             .settlingTimedOut,
             .unexplainedSuspend:
            return check
        }
    }

    /// About what Trio's bolus calculator suggests for the docs' dose: the dose times the Recommended Bolus Percentage
    /// (`percentage`, 0.8 for 80%), to 2 decimals. Trio's own suggestion also counts insulin on board and the trend, so
    /// this is only about it.
    static func suggestion(for dose: Decimal, percentage: Decimal) -> Decimal {
        rounded(dose * percentage, scale: 2, roundingMode: .plain)
    }

    /// How Trio's suggestion compares with the docs' dose at a Recommended Bolus Percentage of `percent` (80 for 80%),
    /// the whole percent the note shows.
    static func suggestionComparison(percent: Int) -> ISFTestSuggestion {
        percent < 100 ? .less : percent == 100 ? .same : .more
    }

    /// Whether a bolus came after the test's own, which spoils the drop the test measures per unit. The test
    /// bolus itself doesn't count, though the `bolusAt` saved for it can be a fraction of a millisecond before or after
    /// it (`isAfter`).
    static func hasExtraBolus(_ boluses: [ISFTestBolus], after bolusAt: Date) -> Bool {
        boluses.contains { isAfter($0.date, bolusAt) }
    }

    /// The SMBs Trio's own dosing check counts, without the test bolus: the pump history can flag it as an SMB when it
    /// writes the amount delivered (`ISFTestBolusRecord`), and it isn't Trio dosing. A bolus at another moment is left in.
    /// Before the bolus, all of them.
    static func smbs(_ smbs: [BasalTestSMB], besidesTestBolusAt bolusAt: Date?) -> [BasalTestSMB] {
        guard let bolusAt else { return smbs }
        return smbs.filter { !isSameMoment($0.date, bolusAt) }
    }

    /// The schedule entries the hours from `start` to `end` touch: what a test over them ran on. Under a minute is the
    /// entry it started in, not the whole day. Nil when they touch none, so an empty list can't read as "unchanged".
    static func coveredEntries(
        _ entries: [SettingsTestScheduleEntry],
        from start: Date,
        to end: Date,
        calendar: Calendar = .current
    ) -> [SettingsTestScheduleEntry]? {
        let window = SettingsTestTimeWindow(from: start, to: end, calendar: calendar)
        let covered = window.startMinutes == window.endMinutes
            ? entries.filter { $0.startMinutes <= window.startMinutes && window.startMinutes < $0.endMinutes }
            : SettingsTestSchedule.covered(by: window, in: entries)
        return covered.isEmpty ? nil : covered
    }

    /// Whether the hours from `start` for `duration` cover more than one ISF value, so the test wouldn't test one time
    /// period: "Test systematically: Test one time period at a time". Entries with the same number are one ISF.
    static func crossesISFChange(
        _ entries: [SettingsTestScheduleEntry],
        from start: Date,
        for duration: TimeInterval,
        calendar: Calendar = .current
    ) -> Bool {
        let covered = coveredEntries(entries, from: start, to: start.addingTimeInterval(duration), calendar: calendar)
        return Set((covered ?? []).map(\.value)).count > 1
    }

    /// How a running check ends the test: the reason, the time to end it at (nil for now, or the planned end if that
    /// came first), and what to say when the records don't.
    struct Ending: Equatable {
        let reason: ISFTestEndReason
        let at: Date?
        let note: String?
    }

    static func ending(for check: RunningCheck, doseDeadline: Date) -> Ending {
        switch check {
        case let .lowBeforeDose(at):
            return Ending(
                reason: .interrupted,
                at: at,
                note: String(localized: "Trio suspended insulin for a low before the dose.")
            )
        case let .low(at):
            return Ending(reason: .low, at: at, note: nil)
        case let .carbsLogged(at):
            return Ending(reason: .interrupted, at: at, note: String(localized: "Carbs were logged during the test."))
        case let .carbsUnreadable(at):
            return Ending(reason: .interrupted, at: at, note: carbsUnreadableNote)
        case let .extraBolus(at):
            return Ending(reason: .interrupted, at: at, note: String(localized: "Another bolus was given during the test."))
        case .modeChanged:
            return Ending(reason: .interrupted, at: nil, note: modeChangedNote)
        case .modeChangedRestored:
            return Ending(reason: .interrupted, at: nil, note: modeChangedRestoredNote)
        case let .unexplainedSuspend(at):
            return Ending(
                reason: .interrupted,
                at: at,
                note: String(localized: "Basal was stopped during the test, and Trio can't tell whether it was for a low.")
            )
        case .noBolus:
            return Ending(reason: .noBolus, at: doseDeadline, note: nil)
        case .settlingTimedOut:
            return Ending(reason: .interrupted, at: doseDeadline, note: settlingTimedOutNote)
        case .bolusNotSeen:
            return Ending(reason: .interrupted, at: nil, note: bolusNotSeenNote)
        case .bolusCancelled:
            return Ending(
                reason: .interrupted,
                at: nil,
                note: String(localized: "The bolus was cancelled before any insulin was delivered, so there's nothing to judge.")
            )
        case let .pumpInterrupted(at):
            return Ending(reason: .interrupted, at: at, note: pumpInterruptedNote)
        case .completed:
            return Ending(reason: .completed, at: nil, note: nil)
        case .completedUnchecked:
            return Ending(reason: .unchecked, at: nil, note: nil)
        }
    }

    /// What the Result says when the pump was suspended, gave an alarm, or had its site or reservoir changed.
    static var pumpInterruptedNote: String {
        String(localized: "Your pump was suspended, gave an alarm, or had its site or reservoir changed during the test.")
    }

    /// What the Result says when the service ended the test because carbs couldn't be read.
    static var carbsUnreadableNote: String {
        String(localized: "Trio couldn't read your carbs to check the test, so it brought your usual dosing back.")
    }

    /// What the Result says when settling didn't finish in the time for it and the dose.
    static var settlingTimedOutNote: String {
        String(localized: "Settling didn't finish in time, so Trio brought your usual dosing back. Nothing was saved.")
    }

    /// What the Result says when the service ended the test for no bolus before it saw the one the runner found.
    static var bolusNotSeenNote: String {
        String(localized: "Trio didn't see the bolus in time, so it brought your usual dosing back. Nothing was saved.")
    }

    /// The note a finished test keeps and its notice says, worded from the mode in force once it ended: one that says the
    /// usual dosing came back says so only when it did (`modeBack`); otherwise it has the same ending's words without
    /// that: another note of the test's, or for settling and the bolus not seen in time the same sentence without the
    /// clause that says it came back. Any other note is unchanged.
    static func modeWorded(_ note: String?, modeBack: Bool) -> String? {
        guard !modeBack, let note else { return note }
        if note == carbsUnreadableNote { return historyUnreadNote }
        if note == modeChangedRestoredNote { return modeChangedNote }
        if note == settlingTimedOutNote { return String(localized: "Settling didn't finish in time. Nothing was saved.") }
        if note == bolusNotSeenNote { return String(localized: "Trio didn't see the bolus in time. Nothing was saved.") }
        return note
    }

    /// What the Result says when another mode was picked during the test.
    static var modeChangedNote: String {
        String(localized: "The dosing mode changed during the test.")
    }

    /// The same, when the session's end put the usual mode back, because Basal Testing was on again by then.
    static var modeChangedRestoredNote: String {
        String(localized: "The dosing mode changed during the test, so it has no result. Your usual dosing mode is back.")
    }

    /// Whether a finish for `reason` reads the suspend history once more after normal dosing is back (`finishing`). A
    /// low, an interruption or no bolus is already decided.
    static func rereadsHistory(_ reason: ISFTestEndReason) -> Bool {
        switch reason {
        case .completed,
             .endedEarly,
             .unchecked: return true
        case .interrupted,
             .low,
             .noBolus: return false
        }
    }

    /// How a test the screen finishes for `reason` at `end` ends, once the pump history and Trio's determinations up to
    /// then are read again with normal dosing back, as the basal fast does (`BasalTestEvaluator.finishing`). The periodic
    /// checks run every half minute, so a suspend may not have been seen yet. One Trio asked for before the bolus left
    /// nothing to judge, so the test is interrupted; after it, the test ends as a low, judged up to the suspend. Basal
    /// stopped without Trio asking interrupts it at the stop. Each says what the running checks would have said
    /// (`ending(for:)`). A test whose history couldn't be read at the end of its 4 hours, read now with nothing in it,
    /// completed. End Test tapped once the 4 hours were up, before a check finished the test, is not ended early: `finish`
    /// ends it at the planned end, and it completes, or is unchecked without a readable history, as the running check
    /// would have said. Otherwise an unreadable history, or a reason already decided (`rereadsHistory`), changes nothing.
    static func finishing(
        reason: ISFTestEndReason,
        at end: Date,
        suspend: BasalTestEvaluator.SuspendReading,
        bolusAt: Date?,
        doseDeadline: Date
    ) -> Ending {
        var reason = reason
        if reason == .endedEarly, let bolusAt, end >= bolusAt.addingTimeInterval(ISFTest.Config.docsWait) {
            reason = suspend == .unreadable ? .unchecked : .completed
        }
        let unchanged = Ending(reason: reason, at: end, note: nil)
        guard rereadsHistory(reason) else { return unchanged }
        switch suspend {
        case let .suspended(at):
            // At the bolus or after it, as the running check splits them.
            if let bolusAt, !isBefore(at, bolusAt) {
                return ending(for: .low(at: at), doseDeadline: doseDeadline)
            }
            return ending(for: .lowBeforeDose(at: at), doseDeadline: doseDeadline)
        case let .unexplained(at):
            return ending(for: .unexplainedSuspend(at: at), doseDeadline: doseDeadline)
        case .none:
            // Only a test with a bolus has 4 hours to have completed.
            return reason == .unchecked && bolusAt != nil ? Ending(reason: .completed, at: end, note: nil) : unchanged
        case .unreadable:
            return unchanged
        }
    }

    /// What the archived record says about a result. A low ends the test as too low an ISF whatever the readings were,
    /// so for a low it says what Trio did and not that glucose fell.
    /// A too high ISF whose glucose rose (`endGlucose` above `startGlucose`) says glucose rose, not that it fell less.
    static func summary(
        for outcome: ISFTestOutcome,
        reason: ISFTestEndReason,
        startGlucose: Int? = nil,
        endGlucose: Int? = nil
    ) -> String {
        switch outcome {
        case .accurate: return String(localized: "Glucose fell by about your ISF")
        case .tooHigh:
            if let startGlucose, let endGlucose, endGlucose > startGlucose {
                return String(localized: "Glucose rose instead of falling")
            }
            return String(localized: "Glucose fell less than your ISF")
        case .tooLow:
            return reason == .low
                ? String(localized: "Trio suspended insulin for a low")
                : String(localized: "Glucose fell more than your ISF")
        case .inconclusive: return String(localized: "Ended too soon to tell")
        case .invalid: return String(localized: "Test was interrupted")
        }
    }

    // MARK: - The result

    /// The finished test's result worked out again from what it saved, as `finish` worked it out, with the drop per
    /// unit and the share behind it. Nil for a test that hasn't finished.
    static func evaluation(of test: ISFTestState, step: Decimal = ISFTest.Config.docsSmallestStep) -> Evaluation? {
        guard let end = test.endedAt, let reason = test.endReason else { return nil }
        return evaluate(
            startGlucose: test.startGlucose,
            endGlucose: test.endGlucose,
            units: judgedUnits(of: test),
            // From the bolus, or from Start if none came, as `finish` times it.
            elapsed: end.timeIntervalSince(test.bolusAt ?? test.startedAt),
            reason: reason,
            interference: test.interference,
            interferenceUnread: test.interferenceUnread ?? false,
            iobUnread: iobUnread(of: test),
            isf: test.isf,
            target: test.target,
            givenUnits: givenUnits(of: test),
            increment: test.bolusIncrement ?? 0,
            step: step
        )
    }

    /// The re-derived evaluation (`evaluation(of:)`) when it gives the verdict `finish` saved, which the headline shows.
    /// Nil when it doesn't, so the working and the band never contradict the headline.
    static func matchingEvaluation(of test: ISFTestState, step: Decimal = ISFTest.Config.docsSmallestStep) -> Evaluation? {
        guard let evaluation = evaluation(of: test, step: step), evaluation.outcome == test.outcome else { return nil }
        return evaluation
    }

    /// The band the result chart shades: the end readings `evaluate` calls accurate (`accurateEnds`), for a result
    /// judged on the drop per unit (`matchingEvaluation`). Nil for one that isn't (a low, or no verdict), and when no
    /// whole reading lies close enough, so the chart never shades a reading the verdict calls a change.
    static func resultBand(of test: ISFTestState, step: Decimal = ISFTest.Config.docsSmallestStep) -> ClosedRange<Int>? {
        guard matchingEvaluation(of: test, step: step)?.dropPerUnit != nil,
              let start = test.startGlucose,
              let units = judgedUnits(of: test)
        else { return nil }
        return accurateEnds(startGlucose: start, units: units, isf: test.isf, step: step)
    }

    /// When the result chart shades the band: the last `ISFTest.Config.expectedEndShading` before the planned end (the
    /// bolus and the docs' 4 hours), where the expected end applies. Nil without a bolus.
    static func resultBandTimes(of test: ISFTestState) -> ClosedRange<Date>? {
        guard let end = test.plannedEnd else { return nil }
        return end.addingTimeInterval(-ISFTest.Config.expectedEndShading) ... end
    }

    /// Where glucose would end if the ISF were right, the start less units × ISF in mg/dL, when the result rests on the
    /// drop per unit (`matchingEvaluation`) and that is further from the target than the band's half-width (one docs
    /// step of the drop). Then the docs' words about the target and the target line on the chart need the per-unit
    /// point beside them: a dose other than the docs' doesn't aim at the target. Nil otherwise.
    static func expectedEndAwayFromTarget(
        of test: ISFTestState,
        step: Decimal = ISFTest.Config.docsSmallestStep
    ) -> Decimal? {
        guard matchingEvaluation(of: test, step: step)?.dropPerUnit != nil,
              let start = test.startGlucose,
              let units = judgedUnits(of: test)
        else { return nil }
        let drop = units * test.isf
        let expected = Decimal(start) - drop
        return abs(expected - test.target) > drop * step ? expected : nil
    }

    /// A drop per unit, in mg/dL per unit, as the formula card shows it: in `units`, rounded as the ISF beside it is (up
    /// to 1 decimal in mg/dL, 1 in mmol/L), so a drop of exactly the ISF reads as the same number. A minus sign when
    /// glucose rose, unless it rounds to zero.
    static func perUnitText(
        _ mgdlPerUnit: Decimal,
        units: GlucoseUnits,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let value = units == .mmolL ? mgdlPerUnit * GlucoseUnits.exchangeRate : mgdlPerUnit
        let rose = value < 0 && rounded(abs(value), scale: 1, roundingMode: .plain) != 0
        return (rose ? "-" : "") + abs(mgdlPerUnit).formattedISF(for: units, locale: locale)
    }

    /// A share of the ISF as a whole percent with its sign, e.g. "−12%". Rounded toward zero
    /// (`BasalTestEvaluator.wholePercent`), so it never reads as the docs' step before it has reached it: an accurate
    /// result never shows 5%.
    static func percentText(_ share: Decimal) -> String {
        let percent = BasalTestEvaluator.wholePercent(share)
        // A minus sign, as the formulas write it, not a hyphen.
        return (percent > 0 ? "+" : percent < 0 ? "\u{2212}" : "") + String(abs(percent)) + "%"
    }

    /// Why a finished test says nothing about the ISF, in the order `evaluate` decides it. Nil for one with a verdict,
    /// a low among them, and for a test that hasn't finished. No bolus comes before the other interruptions: it is
    /// what ended the test.
    static func noVerdict(for test: ISFTestState) -> ISFTestNoVerdict? {
        guard let end = test.endedAt, let reason = test.endReason else { return nil }
        if reason == .noBolus { return .noBolus }
        if test.interference != nil || reason == .interrupted { return .interrupted }
        if test.interferenceUnread == true { return .historyUnread }
        if reason == .low {
            // The units given rest on insulin on board at the bolus, which couldn't be read.
            if iobAtBolusUnread(of: test) { return .historyUnread }
            return lowNoVerdict(
                glucoseAtSuspend: test.endGlucose,
                startGlucose: test.startGlucose,
                givenUnits: givenUnits(of: test),
                target: test.target,
                isf: test.isf,
                increment: test.bolusIncrement ?? 0
            )
        }
        if iobUnread(of: test) { return .historyUnread }
        if reason == .unchecked { return .lowUnchecked }
        if reason == .endedEarly || end.timeIntervalSince(test.bolusAt ?? test.startedAt) < ISFTest.Config.docsWait {
            return .tooSoon
        }
        guard let start = test.startGlucose, test.endGlucose != nil else { return .noReadings }
        guard let units = judgedUnits(of: test), units > 0, test.isf > 0 else { return .noAmount }
        if accurateEnds(startGlucose: start, units: units, isf: test.isf) == nil { return .doseTooSmall }
        return nil
    }

    /// The tablets taken before the dose: the grams saved and, when they make a whole number of tablets of the brand
    /// saved, how many. Nil when none were taken.
    static func takenTablets(carbs: Decimal?, brand: String?) -> ISFTestTablets? {
        guard let carbs, carbs > 0 else { return nil }
        guard let brand = brand.flatMap(GlucoseTabletBrand.init(rawValue:)), brand.carbsPerTablet > 0 else {
            return ISFTestTablets(count: nil, grams: carbs)
        }
        let count = carbs / brand.carbsPerTablet
        let whole = rounded(count, scale: 0, roundingMode: .plain)
        return ISFTestTablets(count: whole == count ? NSDecimalNumber(decimal: whole).intValue : nil, grams: carbs)
    }
}
