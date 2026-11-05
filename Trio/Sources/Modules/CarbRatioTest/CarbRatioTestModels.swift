import Foundation

enum CarbRatioTestEndReason: String, JSON, Equatable {
    /// The chosen length was up.
    case completed
    /// The user ended it before the chosen length was up.
    case endedEarly
    /// Trio suspended insulin for a low, so normal dosing came back.
    case low
    /// Something spoiled the test or left nothing to judge: other carbs or another bolus were logged, carbs couldn't be
    /// read, the tablets' carbs weren't logged with the bolus, Trio suspended insulin for a low before the dose, basal was
    /// stopped without Trio asking, the dosing mode changed, Trio didn't see the bolus in time, or the bolus was cancelled
    /// before any insulin was delivered.
    case interrupted
    /// The chosen length was up, but the pump history couldn't be read to check for a low.
    case unchecked
    /// No bolus came in the time allowed for one, so there was nothing to judge.
    case noBolus

    /// The ISF test's end reason with the same meaning, so the rules both tests share can be asked.
    var isfReason: ISFTestEndReason {
        switch self {
        case .completed: return .completed
        case .endedEarly: return .endedEarly
        case .low: return .low
        case .interrupted: return .interrupted
        case .unchecked: return .unchecked
        case .noBolus: return .noBolus
        }
    }

    init(_ reason: ISFTestEndReason) {
        switch reason {
        case .completed: self = .completed
        case .endedEarly: self = .endedEarly
        case .low: self = .low
        case .interrupted: self = .interrupted
        case .unchecked: self = .unchecked
        case .noBolus: self = .noBolus
        }
    }
}

enum CarbRatioTestOutcome: String, JSON, Equatable {
    /// The ratio the test showed is within the docs' smallest step of the carb ratio: "Return to starting glucose: CR
    /// is accurate".
    case accurate
    /// The ratio the test showed is lower than the carb ratio by a docs step or more: glucose ended higher than the carb
    /// ratio says, so the CR number is too high (too conservative).
    case tooHigh
    /// The ratio the test showed is higher than the carb ratio by a docs step or more, or Trio suspended insulin for a
    /// low the carb ratio accounts for: the CR number is too low (too aggressive).
    case tooLow
    /// Ended too soon, or with too little to say.
    case inconclusive
    /// Something happened that makes the result unusable.
    case invalid

    /// Whether the result says anything about the carb ratio.
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

/// Where a running carb ratio test is. The runner saves it, so a test opened again carries on from the same step.
enum CarbRatioTestPhase: String, JSON {
    /// Begin switched to Basal Testing, so SMBs stopped. The test waits for Trio's first loop in Basal Testing, and for
    /// insulin on board to come under the test's line when it waits for it.
    case settling
    /// Settling is done: the tablets and the bolus are due.
    case dosing
    /// The bolus is in and the chosen length is running.
    case waiting
    /// The result is in, or the test ended with nothing to judge.
    case finished

    /// The ISF test's phase with the same meaning, so its running check (`ISFTestEvaluator.runningCheck`) can be asked.
    var isfPhase: ISFTestPhase {
        switch self {
        case .settling: return .settling
        case .dosing: return .dosing
        case .waiting: return .waiting
        case .finished: return .finished
        }
    }
}

/// Why a finished test says nothing about the carb ratio, for the Result screen and the notice to say.
enum CarbRatioTestNoVerdict: Equatable {
    /// No bolus came in the time allowed for one, so there was nothing to judge.
    case noBolus
    /// Something spoiled the test. The saved note says what, when there is one.
    case interrupted
    /// A record read to check for what spoils the test couldn't be read, so something may have been missed.
    case historyUnread
    /// It ended before the chosen length.
    case tooSoon
    /// The chosen length was up, but the pump history couldn't be read to check for a low.
    case lowUnchecked
    /// There was no reading at the bolus or at the end to compare.
    case noReadings
    /// The pump history gave no amount for the bolus, so there is no ratio to work out.
    case noAmount
    /// The tablets' carbs weren't logged (`CarbRatioTestEvaluator.mealCarbs`), or, for a low, not before Trio's suspend
    /// (`judgedCarbs`), so there are no carbs to judge the bolus against.
    case noCarbs
    /// The carbs were too few for any whole end reading to lie within a docs step of the carb ratio
    /// (`CarbRatioTestEvaluator.accurateEnds` is nil), so CGM noise alone could decide the verdict.
    case carbsTooFew
    /// Trio suspended insulin on its forecast while glucose was still above where it started, so the low says nothing
    /// about the carb ratio.
    case forecastSuspend
    /// Trio suspended insulin for a low after more insulin than a carb ratio a docs step lower gives, so the low can't be
    /// put down to the carb ratio.
    case doseOverDocs
}

/// Why the Dose step doesn't offer the dose (Open Treatments off), for it to say.
enum CarbRatioTestNoDose: Equatable {
    /// Trio counts carbs on board at or over the test's line (`CarbRatioTestEvaluator.cobLine`): the docs test with "Zero
    /// or minimal COB from previous meals".
    case carbsOnBoard
    /// None of Trio's determinations in the last 12 minutes says how many carbs are on board, so the line can't be
    /// checked. The Dose step waits for one.
    case carbsUnread
    /// The CGM has no 3 readings recent enough for the start glucose.
    case noRecentReading
    /// The CGM's arrow isn't flat (`ISFTestEvaluator.isLevel`).
    case notLevel
    /// There is no carb ratio or ISF to work the dose out or judge it with, or no tablets' carbs.
    case noSettings
    /// The test waits for insulin on board, and it is over the line for the dose (`CarbRatioTestEvaluator.iobLine`): the
    /// docs test with "Zero or minimal IOB".
    case iobOverLine
    /// None of Trio's determinations in the last 12 minutes holds insulin on board, so the line can't be checked, or the
    /// counted dose worked out.
    case iobUnread
    /// The test counts insulin on board, and it covers the dose or leaves less than the pump can give.
    case iobCoversDose
    /// The tablets' carbs are logged and the time for the bolus after them is up
    /// (`CarbRatioTestState.bolusDeadline`): the test is ending (`CarbRatioTestEvaluator.mealPairingEnd`).
    case mealTimeUp

    /// Whether the Dose step is waiting for something a later check can bring, rather than at a dead end. Carbs and
    /// insulin on board only come down while the test runs, since other carbs and boluses end it, so each is a wait.
    /// Only missing settings are a dead end, which the runner ends the test at with `sentence`. The meal's time up is
    /// the pairing's ending to make, in its own words, so the step only waits for it.
    var isWaiting: Bool {
        switch self {
        case .carbsOnBoard,
             .carbsUnread,
             .iobCoversDose,
             .iobOverLine,
             .iobUnread,
             .mealTimeUp,
             .noRecentReading,
             .notLevel: return true
        case .noSettings: return false
        }
    }

    /// What the Dose step says about it.
    var sentence: String {
        switch self {
        case .carbsOnBoard:
            return String(
                localized: "Trio counts more carbs on board than the test allows. The dose waits for them to come down."
            )
        case .carbsUnread:
            return String(localized: "Waiting for Trio to count carbs on board.")
        case .noRecentReading:
            return String(localized: "Waiting for recent CGM readings.")
        case .notLevel:
            return String(localized: "Waiting for your glucose to level off.")
        case .noSettings:
            return String(localized: "Trio couldn't read your carb ratio or ISF, so it can't work out the dose.")
        case .iobOverLine:
            return String(
                localized: "Your insulin on board is over the test's line. The dose waits for it to come down."
            )
        case .iobUnread:
            return String(localized: "Waiting for Trio to count insulin on board.")
        case .iobCoversDose:
            return String(localized: "Your insulin on board covers the dose, so there's nothing to give yet.")
        case .mealTimeUp:
            let minutes = Int(CarbRatioTest.Config.mealPairing / 60)
            return String(localized: "The \(minutes) minutes for the bolus are up, so the test is ending.")
        }
    }
}

/// A condition the Dose step holds the dose for that didn't hold when the test bolus went in, which can come from Home,
/// the pump or the Watch as well as from Open Treatments (`CarbRatioTestEvaluator.failedBolusCondition`). The test then
/// ends with no verdict: a spoiled test gives no result.
enum CarbRatioTestBolusCondition: Equatable {
    /// The CGM's arrow at the bolus wasn't flat (`ISFTestEvaluator.isLevel`).
    case glucoseMoving
    /// Trio counted carbs on board at or over the test's line before the meal (`CarbRatioTestEvaluator.cobLine`).
    case carbsOnBoard
    /// In a test that waits for it, insulin on board at the bolus was over the line for the dose then.
    case iobOverLine
    /// The start glucose at the meal (the mean of the newest 3 readings at or before it), or a reading or a
    /// determination needed to check the other conditions then, couldn't be read.
    case unread
    /// The carbs logged (`logged`, grams) were 1 g or more from the tablets' planned grams (`planned`): the test can't
    /// tell what the bolus covered (`CarbRatioTestEvaluator.carbsDiffer`). Both are kept to 1 decimal for the note.
    case carbsDiffer(logged: Decimal, planned: Decimal)
    /// The units the test judges the bolus by (`given`: the bolus, or with Count It, `counted`, the bolus and insulin on
    /// board at it) were more than a docs step from the formula's dose (`formula`), past the pump's rounding
    /// (`CarbRatioTestEvaluator.bolusOffFormula`): "Deliver the full bolus manually". The result would rest on the ISF
    /// instead of the carb ratio.
    case bolusOffFormula(given: Decimal, formula: Decimal, counted: Bool)

    /// What the Result says about it, and the note the runner ends the test with.
    var note: String {
        switch self {
        case let .carbsDiffer(logged, planned):
            let loggedText = CarbRatioTestEvaluator.gramsText(logged)
            let plannedText = CarbRatioTestEvaluator.gramsText(planned)
            return String(
                localized: "The carbs logged (\(loggedText)) weren't the tablets' \(plannedText), so the test can't tell what the bolus covered."
            )
        case let .bolusOffFormula(given, formula, counted):
            let givenText = SettingsTestFormat.keepTogether(ISFTestEvaluator.shownUnits(given), unit: "U")
            let formulaText = SettingsTestFormat.keepTogether(ISFTestEvaluator.shownUnits(formula), unit: "U")
            let sentence = counted
                ? String(
                    localized: "The bolus and the insulin on board came to \(givenText), more than a 1 g/U step from the formula's \(formulaText), so the result would rest on your ISF instead of your carb ratio."
                )
                : String(
                    localized: "The bolus was \(givenText), more than a 1 g/U step from the formula's \(formulaText), so the result would rest on your ISF instead of your carb ratio."
                )
            return sentence + " " + SettingsTestNotice.modeBackSentence
        case .glucoseMoving:
            return ISFTestBolusCondition.glucoseMoving.note
        case .carbsOnBoard:
            return String(
                localized: "The bolus came with more carbs on board than the test allows, so the test can't be judged."
            )
        case .iobOverLine:
            return ISFTestBolusCondition.iobOverLine.note
        case .unread:
            return CarbRatioTestEvaluator.historyUnreadNote
        }
    }
}

/// An ending decided and saved before the usual mode comes back (`CarbRatioTestState.pendingEnd`), as
/// `ISFTestPendingEnd` is for the ISF test: a finish cut short is finished for the same ending at the next check.
struct CarbRatioTestPendingEnd: JSON, Equatable {
    var reason: CarbRatioTestEndReason
    /// When the test ends, worked out once as the ending is decided (`SettingsTestEndRule.endTime`).
    var at: Date
    /// What to say about it when the records don't.
    var note: String?
    /// Whether the user ended it (End Test), which posts no notice.
    var byUser: Bool
}

/// A carb entry as the test reads it: the first dated from the end of settling is the tablets' carbs, the test's
/// (`CarbRatioTestEvaluator.mealCarbs`), and any other spoils it.
struct CarbRatioTestCarbs: Equatable {
    let id: String
    /// When the carbs were eaten, as the entry is dated.
    let date: Date
    let grams: Decimal
}

/// The whole mg/dL end readings the test calls accurate (`CarbRatioTestEvaluator.accurateEnds`).
struct CarbRatioTestBand: Equatable {
    let lowest: Int
    /// Nil when no end reading is too high to be accurate: with a carb ratio at or under the docs' step there is no
    /// ratio a step under it, so no ratio the test can show is that far under it.
    let highest: Int?

    func contains(_ glucose: Int) -> Bool {
        glucose >= lowest && highest.map { glucose <= $0 } ?? true
    }
}

/// The units a bolus can give and still test the carb ratio (`CarbRatioTestEvaluator.bolusRange`), as shown to 2 decimals.
struct CarbRatioTestDoseRange: Equatable {
    let lowest: Decimal
    /// Nil when no bolus is too big: a carb ratio at or under the docs' step has no ratio a step under it.
    let highest: Decimal?

    func contains(_ units: Decimal) -> Bool {
        let shown = rounded(units, scale: 2, roundingMode: .plain)
        return shown >= lowest && highest.map { shown <= $0 } ?? true
    }

    /// The range with `margin` more room either side, never below zero: what the test accepts, since the pump rounds a
    /// bolus to its increment.
    func widened(by margin: Decimal) -> CarbRatioTestDoseRange {
        CarbRatioTestDoseRange(lowest: max(0, lowest - margin), highest: highest.map { $0 + margin })
    }
}

/// Everything the Dose step reads to work out whether the dose can be given, as one value, as `ISFTestDoseInputs` is for
/// the ISF test: the screen builds it from what it has read, and the runner from the same reads.
struct CarbRatioTestDoseInputs: Equatable {
    /// CGM readings, newest first.
    var readings: [BasalTestReading]
    /// The CGM's own arrow on the newest reading. Nil when it gave none.
    var direction: BloodGlucose.Direction?
    /// Insulin on board now, signed. Nil while Trio hasn't worked it out.
    var iob: Decimal?
    /// Insulin on board for a counted dose, from Trio's newest determination of the last 12 minutes
    /// (`ISFTestEvaluator.recentIOB`). Nil when there is none, or in a test that doesn't count it.
    var doseIOB: Decimal?
    /// Carbs on board from Trio's newest determination of the last 12 minutes (`ISFTestEvaluator.recentCOB`), made
    /// before the tablets' carbs were logged. Nil while there is none that recent: unread is not none.
    var cob: Decimal?
    /// The pump's bolus increment, which a counted dose must reach. Zero when it isn't known.
    var increment: Decimal
    /// The moment these are judged at.
    var now: Date

    /// The same inputs as the ISF test reads them, for the rules both tests share (`ISFTestEvaluator.doseGlucose`,
    /// `glucoseIsLevel`).
    var isfInputs: ISFTestDoseInputs {
        ISFTestDoseInputs(
            readings: readings,
            direction: direction,
            iob: iob,
            doseIOB: doseIOB,
            cob: cob,
            increment: increment,
            now: now
        )
    }
}

/// The test's persisted state, so a test opened again, or found after the app was closed, carries on or finishes from
/// what it saved.
struct CarbRatioTestState: JSON, Equatable {
    var id = UUID()
    var phase: CarbRatioTestPhase
    var startedAt: Date
    var previousMode: DosingMode
    /// The settings test session that holds the way back, so the service's record of why it ended the session can be
    /// matched to this test.
    var sessionID: UUID? = nil

    // Fixed at Begin, so neither the dose nor the result depends on what the settings say by then.
    /// The carb ratio in force at Begin, in grams per unit; once the bolus is in, the one in force at the bolus, from the
    /// schedule saved at Begin (`crEntries`), which the result uses.
    var carbRatio: Decimal
    /// The ISF in force at Begin, in mg/dL per unit; once the bolus is in, the one in force at the bolus, which the
    /// result turns the glucose change into units with.
    var isf: Decimal
    /// The glucose target in force at Begin, in mg/dL. Shown only: the result compares with the start glucose.
    var target: Decimal
    /// The carb ratio schedule entries the test can run on, as they were at Begin: those any bolus and its hours could
    /// cover (`CarbRatioTestEvaluator.coveredAtBegin`), narrowed to the entry in force at the bolus once it is in.
    var crEntries: [SettingsTestScheduleEntry]? = nil
    /// The ISF schedule entries, saved and narrowed as `crEntries` are.
    var isfEntries: [SettingsTestScheduleEntry]? = nil
    /// The pump's bolus increment at Begin, in units: a counted dose must reach it, and a low's bolus is held against the
    /// dose a docs step lower rounded up to it (`CarbRatioTestEvaluator.lowNoVerdict`). Zero when it isn't known.
    var bolusIncrement: Decimal
    /// How long the test runs after the bolus, as chosen at Begin (`CarbRatioTest.Config.lengths`).
    var length: TimeInterval
    /// `GlucoseTabletBrand.rawValue`.
    var tabletBrand: String
    var tabletCount: Int
    /// Grams: the count times the brand's carbs per tablet.
    var tabletCarbs: Decimal
    /// The docs' dose for the tablets, carbs ÷ CR, in units, unrounded.
    var expectedDose: Decimal
    /// The line insulin on board must be under, in units: the insulin the docs' smallest CR step changes in the dose
    /// (`CarbRatioTestEvaluator.iobLine`).
    var iobLine: Decimal
    /// The line carbs on board must be under, in grams: the carbs the same step changes (`CarbRatioTestEvaluator.cobLine`).
    var cobLine: Decimal
    /// How the test handles insulin on board over its line at Begin, as chosen then. Nil when there was no choice to
    /// make; a test that finds insulin on board over the line while settling then waits for it, as `.wait` does.
    var iobHandling: ISFTestIOBHandling? = nil
    /// The carb entries there at Begin, dated in the day before it (`SettingsTestCarbRule.keptAtBegin`), so one logged
    /// during the test with an earlier time spoils it.
    var carbsAtBegin: [String]? = nil
    /// When settling ended and the bolus window opened. Nil while settling.
    var settledAt: Date? = nil

    // The test bolus and its carbs, filled in when Trio sees them.
    var bolusAt: Date? = nil
    var bolusUnits: Decimal? = nil
    /// Insulin on board just before the bolus, signed (`ISFTestEvaluator.iobAtBolus`), which the units given count
    /// (`CarbRatioTestEvaluator.givenUnits`). Nil until it has been read.
    var iobAtBolus: Decimal? = nil
    /// mg/dL: the mean of the last 3 readings at or before the bolus. Nil when the CGM had none recent enough.
    var startGlucose: Int? = nil
    /// The grams of the carb entry logged with the bolus (`CarbRatioTestEvaluator.testCarbs`), which the result is judged
    /// on. The user may have changed the tablets' grams in Treatments, so they can differ from `tabletCarbs`. Nil until
    /// it is logged.
    var carbs: Decimal? = nil
    /// When that entry is dated.
    var carbsAt: Date? = nil
    /// That entry's ID, so it isn't taken for other carbs (`CarbRatioTestEvaluator.extraCarbs`).
    var carbsID: String? = nil
    /// When the meal's conditions were judged and held (`CarbRatioTestEvaluator.failedMealCondition`): the grams, the
    /// start glucose, the arrow and carbs on board at the meal, insulin on board at the bolus. No verdict without it: a
    /// finish that finds it nil judges the meal first (`CarbRatioTestRunner.finish`).
    var mealJudgedAt: Date? = nil
    /// Trio's own low threshold in Basal Testing at Begin, in mg/dL: the higher of 72 and the user's
    /// (`Preferences.clamped(for: .basalTesting)`). A low counts as "End up low" only at or under it
    /// (`CarbRatioTestEvaluator.lowNoVerdict`). Nil for a test begun before it was kept, which reads 72.
    var lowThreshold: Decimal? = nil
    /// Whether, as the test ended after the bolus, no carb entry was logged from the end of settling: its words then
    /// say to log the tablets' carbs if they were eaten (`CarbRatioTestEvaluator.noVerdictText`). Never when one is in.
    var carbsUnloggedAtEnd: Bool? = nil

    // Filled in when the test finishes.
    /// Insulin on board Trio reports still left at the planned end (`ISFTestEvaluator.iobAtEnd`), signed: what hadn't
    /// acted in the chosen length, which the units judged leave out. Nil until then, and when it couldn't be read.
    var iobAtEnd: Decimal? = nil
    var endedAt: Date? = nil
    var endReason: CarbRatioTestEndReason? = nil
    var endGlucose: Int? = nil
    /// From the bolus (from Begin if none came) to the end, oldest first.
    var readings: [BasalTestReading] = []
    var outcome: CarbRatioTestOutcome? = nil
    var interference: String? = nil
    /// Whether a record read to check for what spoils the test couldn't be read when it finished.
    var interferenceUnread: Bool? = nil
    /// The ending a check decided, saved before the usual mode comes back, so the next check finishes it for that
    /// ending. Nil while none is, and once the test has finished.
    var pendingEnd: CarbRatioTestPendingEnd? = nil

    // Notices and the dose offer.
    /// Whether "Carb Ratio Dose Ready" is owed: settling moved on to the Dose step and it didn't offer the dose then.
    /// Posted once it does; dropped by the bolus and a finish. Nil otherwise.
    var doseNoticeDue: Bool? = nil
    /// Whether "Carb Ratio Test Waiting" went, for settling's hour up with insulin on board still over the line, so a
    /// later check or a relaunch doesn't post it again. Nil before.
    var timeUpNoticePosted: Bool? = nil
    /// The last moment the Dose step offered the dose (Open Treatments on), saved each check while it does. Nil until
    /// it has.
    var doseOfferedAt: Date? = nil
    /// When a check first found the Dose step no longer offering the dose after `doseOfferedAt`. Nil while the offer
    /// stands, and before any.
    var doseOfferEndedAt: Date? = nil

    /// The tablets' brand. Nil for a raw value no brand has.
    var brand: GlucoseTabletBrand? { GlucoseTabletBrand(rawValue: tabletBrand) }

    /// When the bolus window opened, which the test bolus and its carbs are looked for from: the end of settling. Nil
    /// while settling.
    var bolusWindowStart: Date? { settledAt }

    /// The bolus must come by then (`CarbRatioTest.Config.doseAllowance` from the end of settling).
    var doseDeadline: Date { (settledAt ?? startedAt).addingTimeInterval(CarbRatioTest.Config.doseAllowance) }

    /// When the test ends with no bolus if none came: the dose deadline, or, while settling, the latest a dose deadline
    /// could be, Begin plus the time for settling and the dose.
    var noBolusDeadline: Date {
        guard phase == .settling else { return doseDeadline }
        return startedAt.addingTimeInterval(CarbRatioTest.Config.settleAllowance + CarbRatioTest.Config.doseAllowance)
    }

    /// The end of the chosen length from the bolus. Nil until the bolus is in.
    var plannedEnd: Date? { bolusAt?.addingTimeInterval(length) }

    /// With the bolus in first, the latest the tablets' carbs can be logged (`CarbRatioTest.Config.mealPairing`) before
    /// the test ends with no verdict (`CarbRatioTestEvaluator.mealPairingEnd`). Nil until the bolus is in.
    var carbsDeadline: Date? { bolusAt?.addingTimeInterval(CarbRatioTest.Config.mealPairing) }

    /// Whether the tablets' carbs are logged and the bolus hasn't come: the Dose step then asks only for the bolus, by
    /// `bolusDeadline`, with nothing filled in for the carbs, and the arrow and carbs on board were judged at the carbs.
    var carbsLoggedAwaitingBolus: Bool { carbsAt != nil && bolusAt == nil }

    /// With the tablets' carbs logged first, the latest the bolus can come (`CarbRatioTest.Config.mealPairing`) before the
    /// test ends with no verdict and the usual dosing comes back to cover them. Nil otherwise.
    var bolusDeadline: Date? {
        guard carbsLoggedAwaitingBolus else { return nil }
        return carbsAt?.addingTimeInterval(CarbRatioTest.Config.mealPairing)
    }

    /// The whole minutes left at `now` until `bolusDeadline`, rounded up, never below 0. Nil without one.
    func minutesLeftForBolus(at now: Date) -> Int? {
        guard let deadline = bolusDeadline else { return nil }
        let seconds = max(0, deadline.timeIntervalSince(now))
        return Int((seconds / 60).rounded(.up))
    }

    /// The meal's moment: the earlier of the tablets' carbs and the bolus, once either is in. The start glucose, the arrow
    /// and carbs on board are judged at it, so the tablets' own rise doesn't count against the bolus that follows them.
    var mealAt: Date? {
        switch (carbsAt, bolusAt) {
        case let (carbs?, bolus?): return min(carbs, bolus)
        case let (carbs?, nil): return carbs
        case let (nil, bolus?): return bolus
        case (nil, nil): return nil
        }
    }
}

/// Turns what happened after the tablets and their bolus into a result. Pure, so it can be tested without a loop: every
/// moment is passed in.
enum CarbRatioTestEvaluator {
    struct Evaluation: Equatable {
        let outcome: CarbRatioTestOutcome
        let direction: SettingsTestDirection?
        /// The carb ratio the test showed, carbs ÷ (units + change ÷ ISF), in grams per unit (`shownRatio`). Nil when the
        /// outcome doesn't rest on it, and when glucose fell by at least what the insulin alone explains.
        let shownRatio: Decimal?
        /// The shown ratio less the carb ratio, signed: negative when the test showed a lower ratio. Nil without a shown
        /// ratio.
        let difference: Decimal?
    }

    // MARK: - The dose

    /// The docs' dose before it is rounded: "Calculate insulin: Carbs ÷ Current CR". Nil without carbs or a carb ratio.
    static func unroundedDose(carbs: Decimal, carbRatio: Decimal) -> Decimal? {
        guard carbs > 0, carbRatio > 0 else { return nil }
        return carbs / carbRatio
    }

    /// The docs' dose, carbs ÷ CR, to 2 decimals, rounded half up as the screens show units
    /// (`ISFTestEvaluator.shownUnits`).
    static func dose(carbs: Decimal, carbRatio: Decimal) -> Decimal? {
        unroundedDose(carbs: carbs, carbRatio: carbRatio).map { rounded($0, scale: 2, roundingMode: .plain) }
    }

    /// The dose with insulin on board taken off, as the docs' bolus calculator takes it off ("… + Carbs ÷ CR + … − IOB"),
    /// before it is rounded. Insulin on board is signed, so basal Trio held back adds to the dose, and is taken off as
    /// shown, to 2 decimals, so the formula on screen adds up. Nil when what is left shows as 0.00 U or less, or is under
    /// the pump's bolus `increment`.
    static func unroundedCountedDose(
        carbs: Decimal,
        carbRatio: Decimal,
        iob: Decimal,
        increment: Decimal = 0
    ) -> Decimal? {
        guard let formula = unroundedDose(carbs: carbs, carbRatio: carbRatio) else { return nil }
        let dose = formula - rounded(iob, scale: 2, roundingMode: .plain)
        let shown = rounded(dose, scale: 2, roundingMode: .plain)
        return shown > 0 && shown >= increment ? dose : nil
    }

    /// `unroundedCountedDose` to 2 decimals.
    static func countedDose(carbs: Decimal, carbRatio: Decimal, iob: Decimal, increment: Decimal = 0) -> Decimal? {
        unroundedCountedDose(carbs: carbs, carbRatio: carbRatio, iob: iob, increment: increment)
            .map { rounded($0, scale: 2, roundingMode: .plain) }
    }

    /// The dose the Dose step shows: the docs' dose, or in a test that counts insulin on board (Count It), the counted
    /// dose. Nil when there is none, and with Count It while Trio hasn't read insulin on board recently (`iob` nil).
    static func testDose(
        carbs: Decimal,
        carbRatio: Decimal,
        handling: ISFTestIOBHandling?,
        iob: Decimal?,
        increment: Decimal = 0
    ) -> Decimal? {
        guard handling == .count else { return dose(carbs: carbs, carbRatio: carbRatio) }
        guard let iob else { return nil }
        return countedDose(carbs: carbs, carbRatio: carbRatio, iob: iob, increment: increment)
    }

    // MARK: - Insulin and carbs on board

    /// The line insulin on board must be under: the insulin the docs' smallest CR step changes in the dose ("Make small
    /// changes: Adjust by 1-2 g/U at a time"), the smaller side. The dose at CR + step is carbs ÷ (CR + step), so the
    /// change is dose × step ÷ (CR + step). Less than that sways the ratio the test shows by less than a docs step.
    /// Rounded to 2 decimals, as it is shown. Zero without a dose or a carb ratio.
    static func iobLine(
        dose: Decimal,
        carbRatio: Decimal,
        step: Decimal = CarbRatioTest.Config.docsSmallestStep
    ) -> Decimal {
        guard dose > 0, carbRatio > 0 else { return 0 }
        return rounded(dose * step / (carbRatio + step), scale: 2, roundingMode: .plain)
    }

    /// The line carbs on board must be under: the carbs the docs' smallest CR step changes, the insulin of `iobLine` at
    /// the carb ratio, carbs × step ÷ (CR + step). Rounded to 1 decimal, as grams are shown (`shownGrams`). Zero without
    /// carbs or a carb ratio.
    static func cobLine(
        carbs: Decimal,
        carbRatio: Decimal,
        step: Decimal = CarbRatioTest.Config.docsSmallestStep
    ) -> Decimal {
        guard carbs > 0, carbRatio > 0 else { return 0 }
        return rounded(carbs * step / (carbRatio + step), scale: 1, roundingMode: .plain)
    }

    /// Grams of carbs as the screens show them and the line compares them: to 1 decimal, rounded half up.
    static func shownGrams(_ grams: Decimal) -> Decimal {
        rounded(grams, scale: 1, roundingMode: .plain)
    }

    /// Whether carbs on board hold up Begin and the dose: at or over the line, a docs rule ("Zero or minimal COB from
    /// previous meals"). None never does, so a line that rounds to zero can't block every test. Not read yet, they
    /// don't hold up Begin; the Dose step waits for a read (`CarbRatioTestNoDose.carbsUnread`).
    static func cobBlocks(cob: Decimal?, line: Decimal) -> Bool {
        guard let cob else { return false }
        let shown = shownGrams(cob)
        return shown > 0 && shown >= line
    }

    /// What insulin on board at Begin means for the test, by its size either way, as for the ISF test
    /// (`ISFTestEvaluator.iobDecision`): at or under the line it is fine, over it the user chooses to wait for it or count
    /// it, and more than the whole dose holds Begin up. Nil without a dose, and while Trio hasn't read insulin on board.
    static func iobDecision(
        iob: Decimal?,
        expectedDose: Decimal?,
        carbRatio: Decimal?,
        step: Decimal = CarbRatioTest.Config.docsSmallestStep
    ) -> ISFTestIOBDecision? {
        guard let iob, let expectedDose, expectedDose > 0, let carbRatio, carbRatio > 0 else { return nil }
        let line = iobLine(dose: expectedDose, carbRatio: carbRatio, step: step)
        let size = ISFTestEvaluator.shownSize(of: iob)
        if size <= line { return .fine }
        return size <= rounded(expectedDose, scale: 2, roundingMode: .plain) ? .choice(line: line) : .blocked
    }

    /// The handling Begin saves: the user's choice when there was one to make, nil when there wasn't.
    static func iobHandling(for decision: ISFTestIOBDecision?, chosen: ISFTestIOBHandling) -> ISFTestIOBHandling? {
        ISFTestEvaluator.iobHandling(for: decision, chosen: chosen)
    }

    /// Carbs on board just before `moment`, the earlier of the bolus and the tablets' carbs: from the newest determination
    /// that holds them, dated before it by at least the tolerance (`ISFTestEvaluator.isBefore`), so a determination that
    /// already counts the tablets isn't read, and no more than `maxAge` before it. Nil when there is none that recent.
    static func cobBefore(
        _ determinations: [ISFTestDetermination],
        moment: Date,
        maxAge: TimeInterval = BasalTest.Config.endReadingMaxAge
    ) -> Decimal? {
        let oldest = moment.addingTimeInterval(-maxAge)
        return determinations
            .filter {
                $0.cob != nil && ISFTestEvaluator.isBefore($0.date, moment) && !ISFTestEvaluator.isBefore($0.date, oldest)
            }
            .max { $0.date < $1.date }?
            .cob
    }

    // MARK: - Tablets

    /// The most tablets of `brand` the test offers: up to `cap`, while their carbs stay within Max Carbs and their dose
    /// (`dose`) within Max Bolus. Zero when not even one fits, or without a carb ratio.
    static func maxTablets(
        brand: GlucoseTabletBrand,
        carbRatio: Decimal,
        maxBolus: Decimal,
        maxCarbs: Decimal,
        cap: Int = CarbRatioTest.Config.maxTabletCount
    ) -> Int {
        guard carbRatio > 0, brand.carbsPerTablet > 0 else { return 0 }
        for count in stride(from: cap, to: 0, by: -1) {
            let carbs = brand.totalCarbs(for: count)
            if carbs <= maxCarbs, let dose = dose(carbs: carbs, carbRatio: carbRatio), dose <= maxBolus { return count }
        }
        return 0
    }

    /// The tablet count the Check screen shows: `wanted` kept between 1 and `maxTablets`. Nil when not even one tablet
    /// fits, so Begin can't go ahead.
    static func tabletCount(
        _ wanted: Int = CarbRatioTest.Config.defaultTabletCount,
        brand: GlucoseTabletBrand,
        carbRatio: Decimal,
        maxBolus: Decimal,
        maxCarbs: Decimal
    ) -> Int? {
        let most = maxTablets(brand: brand, carbRatio: carbRatio, maxBolus: maxBolus, maxCarbs: maxCarbs)
        guard most >= 1 else { return nil }
        return min(max(wanted, 1), most)
    }

    // MARK: - The result

    /// The whole mg/dL end readings `evaluate` calls accurate: those whose ratio (`shownRatio`) is strictly within the
    /// docs' smallest step of the carb ratio. Solving carbs ÷ (units + change ÷ ISF) = CR ± step for the change gives the
    /// band's edges, start + ISF × (carbs ÷ (CR + step) − units) and start + ISF × (carbs ÷ (CR − step) − units). With a
    /// carb ratio at or under the step there is no ratio a step under it, so the band has no top. Nil when no whole
    /// reading lies inside: too few carbs for CGM noise not to decide the verdict. Nil without carbs, units, a carb ratio
    /// or an ISF.
    static func accurateEnds(
        startGlucose: Int,
        carbs: Decimal,
        units: Decimal,
        carbRatio: Decimal,
        isf: Decimal,
        step: Decimal = CarbRatioTest.Config.docsSmallestStep
    ) -> CarbRatioTestBand? {
        guard carbs > 0, units > 0, carbRatio > 0, isf > 0 else { return nil }
        func end(at ratio: Decimal) -> Decimal { Decimal(startGlucose) + isf * (carbs / ratio - units) }
        // The whole numbers strictly between the edges. `.down` and `.up` are floor and ceiling.
        let lowest = NSDecimalNumber(decimal: rounded(end(at: carbRatio + step), scale: 0, roundingMode: .down)).intValue + 1
        guard carbRatio > step else { return CarbRatioTestBand(lowest: lowest, highest: nil) }
        let highest = NSDecimalNumber(decimal: rounded(end(at: carbRatio - step), scale: 0, roundingMode: .up)).intValue - 1
        return lowest <= highest ? CarbRatioTestBand(lowest: lowest, highest: highest) : nil
    }

    /// The carb ratio the test showed: the carbs over the insulin that covered them. That insulin is the `units` that
    /// acted, plus the glucose `change` (end − start, mg/dL) turned into units by the ISF: glucose that ended higher
    /// means the carbs needed more insulin than was given. Nil when the insulin comes to zero or less (glucose fell by at
    /// least what the insulin alone explains), and without carbs or an ISF.
    static func shownRatio(carbs: Decimal, units: Decimal, change: Int, isf: Decimal) -> Decimal? {
        guard carbs > 0, isf > 0 else { return nil }
        let insulin = units + Decimal(change) / isf
        guard insulin > 0 else { return nil }
        return carbs / insulin
    }

    /// The result comes from the docs' smallest CR step: a ratio shown within that much of the carb ratio, after the
    /// chosen length, is accurate ("Return to starting glucose: CR is accurate"). It is judged per unit that acted
    /// (`units`, `judgedUnits`) and on the carbs logged with the bolus, so a dose other than the formula's still tests
    /// the ratio. A lower ratio means glucose ended high: "End up high: CR is too high". A higher one, or glucose that
    /// fell by at least what the insulin alone explains, means it ended low: "End up low: CR is too low". Exactly a step
    /// off is a change.
    ///
    /// An interference or an interrupted test, or a bolus that never came, is invalid. A test whose records couldn't all
    /// be read for what spoils it is inconclusive, a low among them. A low ends the test early, so it isn't judged on the
    /// ratio: it says the CR number is too low only when the docs' words and the carb ratio account for it
    /// (`lowNoVerdict` nil). Otherwise, insulin on board that couldn't be read, ending early, a pump history that couldn't
    /// be read, less than the chosen `length`, a missing reading, amount or carbs, or carbs too few for any whole reading
    /// to lie within a step (`accurateEnds` nil) says nothing.
    static func evaluate(
        startGlucose: Int?,
        endGlucose: Int?,
        units: Decimal?,
        elapsed: TimeInterval,
        length: TimeInterval,
        reason: CarbRatioTestEndReason,
        interference: String?,
        interferenceUnread: Bool = false,
        iobUnread: Bool = false,
        carbs: Decimal?,
        carbRatio: Decimal?,
        isf: Decimal?,
        givenUnits: Decimal? = nil,
        increment: Decimal = 0,
        lowThreshold: Decimal = Preferences.basalTestingThreshold,
        step: Decimal = CarbRatioTest.Config.docsSmallestStep
    ) -> Evaluation {
        func result(
            _ outcome: CarbRatioTestOutcome,
            _ direction: SettingsTestDirection?,
            shownRatio: Decimal? = nil,
            difference: Decimal? = nil
        ) -> Evaluation {
            Evaluation(outcome: outcome, direction: direction, shownRatio: shownRatio, difference: difference)
        }

        if interference != nil || reason == .interrupted || reason == .noBolus {
            return result(.invalid, nil)
        }

        // Something that spoils the test may have been missed.
        if interferenceUnread {
            return result(.inconclusive, nil)
        }

        if reason == .low {
            return lowNoVerdict(
                glucoseAtSuspend: endGlucose,
                startGlucose: startGlucose,
                givenUnits: givenUnits,
                carbs: carbs,
                carbRatio: carbRatio,
                increment: increment,
                lowThreshold: lowThreshold,
                step: step
            ) == nil ? result(.tooLow, .increase) : result(.inconclusive, nil)
        }

        if iobUnread {
            return result(.inconclusive, nil)
        }

        // An unread pump history can't rule out a low.
        if reason == .endedEarly || reason == .unchecked || elapsed < length {
            return result(.inconclusive, nil)
        }

        guard let startGlucose, let endGlucose, let units, units > 0, let carbs, carbs > 0, let carbRatio, carbRatio > 0,
              let isf, isf > 0
        else {
            return result(.inconclusive, nil)
        }

        // No whole reading could count as accurate, so a reading or two of CGM noise would decide the verdict.
        guard accurateEnds(
            startGlucose: startGlucose,
            carbs: carbs,
            units: units,
            carbRatio: carbRatio,
            isf: isf,
            step: step
        ) != nil else {
            return result(.inconclusive, nil)
        }

        guard let shown = shownRatio(carbs: carbs, units: units, change: endGlucose - startGlucose, isf: isf) else {
            // Glucose fell by at least what the insulin alone explains: more insulin than the carbs needed.
            return result(.tooLow, .increase)
        }
        let difference = shown - carbRatio
        if abs(difference) < step {
            return result(.accurate, .keep, shownRatio: shown, difference: difference)
        }
        return difference < 0
            ? result(.tooHigh, .decrease, shownRatio: shown, difference: difference)
            : result(.tooLow, .increase, shownRatio: shown, difference: difference)
    }

    /// Why Trio's suspend for a low says nothing about the carb ratio, nil when it says the number is too low. The docs'
    /// rule is "End up low: CR is too low", so the low counts only with glucose at the suspend (`glucoseAtSuspend`, the
    /// mean of the readings after the meal at or before it, `endGlucose`) both at or below Trio's own low threshold in
    /// Basal Testing (`lowThreshold`, `CarbRatioTestState.lowThreshold`: lows use Trio's own threshold) and at or below
    /// the start glucose. Trio also suspends on its forecast, with glucose still above either (`forecastSuspend`). And
    /// only when what went in, `givenUnits` (the bolus, plus insulin on board at it), was no more than the dose a carb
    /// ratio a docs step lower gives, carbs ÷ (CR − step), rounded up to the pump's bolus `increment`: a bigger bolus
    /// brings on a low whatever the ratio (`doseOverDocs`). A carb ratio at or under the step has no ratio a step lower,
    /// so no bolus is too big for it. Without a reading, the units or the carbs to tell, the reason is the one missing.
    static func lowNoVerdict(
        glucoseAtSuspend: Int?,
        startGlucose: Int?,
        givenUnits: Decimal?,
        carbs: Decimal?,
        carbRatio: Decimal?,
        increment: Decimal,
        lowThreshold: Decimal = Preferences.basalTestingThreshold,
        step: Decimal = CarbRatioTest.Config.docsSmallestStep
    ) -> CarbRatioTestNoVerdict? {
        guard let glucoseAtSuspend, let startGlucose else { return .noReadings }
        guard glucoseAtSuspend <= startGlucose, Decimal(glucoseAtSuspend) <= lowThreshold else { return .forecastSuspend }
        guard let givenUnits else { return .noAmount }
        guard let carbs, carbs > 0 else { return .noCarbs }
        guard let carbRatio, carbRatio > 0 else { return .noAmount }
        guard carbRatio > step, let lowerDose = dose(carbs: carbs, carbRatio: carbRatio - step) else { return nil }
        return givenUnits > ISFTestEvaluator.roundedUp(lowerDose, to: increment) ? .doseOverDocs : nil
    }

    /// The units that went in: the bolus as the pump history holds it, plus the insulin on board at it, signed, as the
    /// ISF test counts them (`ISFTestEvaluator.givenUnits`). Nil without a bolus amount, and when the insulin on board at
    /// it couldn't be read.
    static func givenUnits(of test: CarbRatioTestState) -> Decimal? {
        guard let bolus = test.bolusUnits else { return nil }
        return test.iobAtBolus.map { bolus + $0 }
    }

    /// The units the result is judged by: those that acted in the chosen length, the units given less the insulin on
    /// board Trio reports still left at the planned end (`ISFTestEvaluator.judgedUnits`). Nil without units given, and
    /// while the insulin left at the end hasn't been read.
    static func judgedUnits(of test: CarbRatioTestState) -> Decimal? {
        guard let given = givenUnits(of: test), let left = test.iobAtEnd else { return nil }
        return given - left
    }

    /// Whether the insulin on board at the test's bolus, which the units given count, couldn't be read.
    static func iobAtBolusUnread(of test: CarbRatioTestState) -> Bool {
        test.bolusAt != nil && test.iobAtBolus == nil
    }

    /// Whether a test that ran its length couldn't read the insulin on board left at the planned end.
    static func iobAtEndUnread(of test: CarbRatioTestState) -> Bool {
        test.bolusAt != nil && test.endReason == .completed && test.iobAtEnd == nil
    }

    /// Whether insulin on board the units judged rest on couldn't be read, at the bolus or left at the planned end.
    static func iobUnread(of test: CarbRatioTestState) -> Bool {
        iobAtBolusUnread(of: test) || iobAtEndUnread(of: test)
    }

    /// The glucose the test ended at, in mg/dL: the mean of the last 3 readings at or before `end` (a saved date, so a
    /// reading at the same moment is at it), from the bolus on (`BasalTestEvaluator.endGlucose`). For a low, the glucose
    /// at Trio's suspend, from readings dated after the later half of the meal only (the bolus, or the tablets' carbs,
    /// `carbsAt`, logged after it): the tablets are taken after the bolus, so a suspend before the CGM had 3 readings
    /// since then has none, and isn't read as "End up low" from glucose the tablets hadn't touched. Nil without a bolus,
    /// and without a reading recent enough at the end.
    static func endGlucose(
        _ fetched: [BasalTestReading],
        bolusAt: Date?,
        carbsAt: Date?,
        end: Date,
        reason: CarbRatioTestEndReason
    ) -> Int? {
        guard let bolusAt else { return nil }
        let atEnd = ISFTestEvaluator.readings(fetched, atOrBefore: end)
        let counted: [BasalTestReading]
        if reason == .low {
            let laterHalf = carbsAt.map { max($0, bolusAt) } ?? bolusAt
            counted = atEnd.filter { ISFTestEvaluator.isAfter($0.date, laterHalf) }
        } else {
            counted = ISFTestEvaluator.readings(atEnd, since: bolusAt)
        }
        return BasalTestEvaluator.endGlucose(from: counted, endingAt: end)
    }

    /// The carbs a test that ended at `end` for `reason` is judged on: the tablets' planned grams (`planned`), what was
    /// eaten, once their entry is logged (`carbs`, dated `carbsAt`), since a logged amount within a gram of them is the
    /// entry field's rounding (`carbsDiffer`). A low counts them only when logged at or before Trio's suspend (`end`): a
    /// suspend before them came from a forecast that saw the bolus without the carbs, which says nothing about the carb
    /// ratio (`lowNoVerdict` then gives `.noCarbs`). Nil without them.
    static func judgedCarbs(
        _ carbs: Decimal?,
        planned: Decimal,
        carbsAt: Date?,
        reason: CarbRatioTestEndReason?,
        end: Date?
    ) -> Decimal? {
        guard carbs != nil else { return nil }
        guard reason == .low else { return planned }
        guard let carbsAt, let end, !ISFTestEvaluator.isAfter(carbsAt, end) else { return nil }
        return planned
    }

    /// `judgedCarbs` for a finished test, from what it saved.
    static func judgedCarbs(of test: CarbRatioTestState) -> Decimal? {
        judgedCarbs(test.carbs, planned: test.tabletCarbs, carbsAt: test.carbsAt, reason: test.endReason, end: test.endedAt)
    }

    // MARK: - The meal: the tablets' carbs and the bolus

    /// The test's carbs: the first carb entry dated from `windowStart` (the end of settling). The window start is exact,
    /// as the test bolus's is (`ISFTestEvaluator.testBolus`): an entry before it was logged while settling, which spoils
    /// the test. Whether it came close enough to the bolus is `mealPairingEnd`'s to say; any other entry is extra
    /// (`extraCarbs`).
    static func mealCarbs(_ entries: [CarbRatioTestCarbs], since windowStart: Date) -> CarbRatioTestCarbs? {
        entries.filter { $0.date >= windowStart }.min { $0.date < $1.date }
    }

    /// Whether the carbs logged aren't the tablets' planned grams: 1 g or more apart. The test then can't tell what the
    /// bolus covered. Less than a gram apart they are the tablets': Treatments' carbs field shows whole grams, and
    /// TruePlus tablets are 3.75 g, so 10 of them, 37.5 g, are logged as 37 or 38 g once the field is retyped.
    static func carbsDiffer(logged: Decimal, planned: Decimal) -> Bool {
        abs(logged - planned) >= 1
    }

    /// Grams as the notes word them, "40 g", the unit kept with the number.
    static func gramsText(_ grams: Decimal, locale: Locale = .autoupdatingCurrent) -> String {
        SettingsTestFormat.keepTogether(shownGrams(grams).formatted(.number.locale(locale)), unit: "g")
    }

    /// Whether carb entries other than the test's spoil it, by the rule the other tests use (`SettingsTestCarbRule.spoil`):
    /// any dated from Begin on, and any dated in the day before it that wasn't there at Begin (`kept`). `entries` are read
    /// from `SettingsTestCarbRule.readFrom`; the one whose ID is `testCarbsID` is left out.
    static func extraCarbs(
        _ entries: [CarbRatioTestCarbs],
        besides testCarbsID: String?,
        startedAt: Date,
        kept: [String]?
    ) -> Bool {
        let others = entries
            .filter { $0.id != testCarbsID }
            .map { SettingsTestCarbEntry(id: $0.id, date: $0.date) }
        return SettingsTestCarbRule.spoil(others, startedAt: startedAt, kept: kept)
    }

    // MARK: - The bolus

    /// The first condition the Dose step holds the dose for that didn't hold at the meal, the earlier of the bolus
    /// (`bolusAt`) and the tablets' carbs (`testCarbsAt`), in the Dose step's order, or nil when they all held. A bolus
    /// can come from Home, the pump or the Watch, so a spoiled one is caught here and not judged.
    /// - the start glucose is read (`startGlucose`, the mean of the last 3 readings at or before the meal);
    /// - the CGM's arrow on the newest reading at or before the meal, no more than `maxAge` before it, is flat or absent
    ///   (`ISFTestEvaluator.isLevel`), so the tablets' own rise after them doesn't count against the bolus;
    /// - carbs on board before the meal are under the line (`cobBefore`, `cobBlocks`), so the tablets themselves aren't
    ///   counted;
    /// - unless the test counts it, insulin on board just before the bolus (`ISFTestEvaluator.iobAtBolus`) is at or under
    ///   the line for the dose then (`iobLine`, from `carbs` and the `carbRatio` in force at the bolus).
    /// A reading or determination that couldn't be read, or isn't recent enough, is `unread`: nothing can be judged that
    /// can't be checked.
    static func failedBolusCondition(
        bolusAt: Date,
        startGlucose: Int?,
        carbs: Decimal,
        carbRatio: Decimal,
        arrow: ISFTestArrowReading?,
        determinations: [ISFTestDetermination]?,
        testCarbsAt: Date?,
        handling: ISFTestIOBHandling?,
        maxAge: TimeInterval = BasalTest.Config.endReadingMaxAge,
        step: Decimal = CarbRatioTest.Config.docsSmallestStep
    ) -> CarbRatioTestBolusCondition? {
        guard startGlucose != nil else { return .unread }
        let mealAt = testCarbsAt.map { min($0, bolusAt) } ?? bolusAt
        guard let arrow, !ISFTestEvaluator.isAfter(arrow.date, mealAt),
              !ISFTestEvaluator.isBefore(arrow.date, mealAt.addingTimeInterval(-maxAge))
        else { return .unread }
        guard ISFTestEvaluator.isLevel(direction: arrow.direction, hasRecentReading: true) else { return .glucoseMoving }
        guard let determinations else { return .unread }
        guard let cob = cobBefore(determinations, moment: mealAt, maxAge: maxAge) else { return .unread }
        if cobBlocks(cob: cob, line: cobLine(carbs: carbs, carbRatio: carbRatio, step: step)) { return .carbsOnBoard }
        // No line in a test that counts insulin on board, which takes it off the dose instead.
        if handling != .count, let dose = dose(carbs: carbs, carbRatio: carbRatio) {
            let line = iobLine(dose: dose, carbRatio: carbRatio, step: step)
            guard let iob = ISFTestEvaluator.iobAtBolus(determinations, bolusAt: bolusAt, maxAge: maxAge) else {
                return .unread
            }
            if ISFTestEvaluator.waitsForIOB(iob: iob, line: line, handling: handling) { return .iobOverLine }
        }
        return nil
    }

    /// The first condition that didn't hold once the meal's two halves are in, the tablets' carbs (`loggedCarbs`, dated
    /// `carbsAt`) and the bolus (`bolusAt`): the carbs logged aren't the tablets' planned grams (`carbsDiffer`), then
    /// `failedBolusCondition` at the meal, with the lines from the tablets' planned grams. Nil when they all held.
    static func failedMealCondition(
        bolusAt: Date,
        carbsAt: Date,
        loggedCarbs: Decimal,
        plannedCarbs: Decimal,
        startGlucose: Int?,
        carbRatio: Decimal,
        arrow: ISFTestArrowReading?,
        determinations: [ISFTestDetermination]?,
        handling: ISFTestIOBHandling?
    ) -> CarbRatioTestBolusCondition? {
        if carbsDiffer(logged: loggedCarbs, planned: plannedCarbs) {
            return .carbsDiffer(logged: shownGrams(loggedCarbs), planned: shownGrams(plannedCarbs))
        }
        return failedBolusCondition(
            bolusAt: bolusAt,
            startGlucose: startGlucose,
            carbs: plannedCarbs,
            carbRatio: carbRatio,
            arrow: arrow,
            determinations: determinations,
            testCarbsAt: carbsAt,
            handling: handling
        )
    }

    // MARK: - The bolus against the formula

    /// The units a bolus for `carbs` can give and still test the carb ratio, "Deliver the full bolus manually": from the
    /// dose a carb ratio a docs step higher gives, carbs ÷ (CR + step), rounded down to the pump's `increment`, to the
    /// dose a step lower gives, carbs ÷ (CR − step), rounded up to it. No top for a carb ratio at or under the step. Past
    /// it, the glucose change the bolus leaves is turned into units by the ISF, so the result would rest on the ISF. Nil
    /// without carbs or a carb ratio.
    static func bolusRange(
        carbs: Decimal,
        carbRatio: Decimal,
        increment: Decimal,
        step: Decimal = CarbRatioTest.Config.docsSmallestStep
    ) -> CarbRatioTestDoseRange? {
        guard let higherRatioDose = dose(carbs: carbs, carbRatio: carbRatio + step) else { return nil }
        let lowest = increment > 0
            ? rounded(higherRatioDose / increment, scale: 0, roundingMode: .down) * increment
            : higherRatioDose
        let highest = carbRatio > step
            ? dose(carbs: carbs, carbRatio: carbRatio - step).map { ISFTestEvaluator.roundedUp($0, to: increment) }
            : nil
        return CarbRatioTestDoseRange(lowest: lowest, highest: highest)
    }

    /// A bolus off the formula's dose by more than a docs step, for the tablets' planned grams and the carb ratio in
    /// force at it: outside `bolusRange` widened by one pump `increment` either side, since the pump rounds what it gives
    /// (`CarbRatioTestDoseRange.widened`). The units judged are the bolus alone in a test that waited for insulin on board
    /// (Wait for It, or no choice to make: it was under the line), and the bolus with insulin on board at it with Count
    /// It, whose dose took it off (`counted`). Nil when the bolus is in range, and while there is nothing to judge: no
    /// bolus, no amount, or Count It before the insulin on board at the bolus is read: checked as soon as it is.
    static func bolusOffFormula(of test: CarbRatioTestState) -> CarbRatioTestBolusCondition? {
        guard test.bolusAt != nil, let bolus = test.bolusUnits else { return nil }
        let counted = test.iobHandling == .count
        let units: Decimal
        if counted {
            guard let iob = test.iobAtBolus else { return nil }
            units = bolus + iob
        } else {
            units = bolus
        }
        guard let range = bolusRange(carbs: test.tabletCarbs, carbRatio: test.carbRatio, increment: test.bolusIncrement),
              let formula = dose(carbs: test.tabletCarbs, carbRatio: test.carbRatio),
              !range.widened(by: test.bolusIncrement).contains(units)
        else { return nil }
        return .bolusOffFormula(given: rounded(units, scale: 2, roundingMode: .plain), formula: formula, counted: counted)
    }

    /// Whether Trio's `suggestion` for the bolus sits inside the range the test accepts by at least one pump increment,
    /// that is, in `bolusRange` itself: only then does the Dose step say "Either is fine"; otherwise it says to enter the
    /// formula's dose. `iob` is the insulin on board the units count, with Count It only (zero otherwise: the bolus alone
    /// is judged). False without carbs or a carb ratio.
    static func suggestionInRange(
        _ suggestion: Decimal,
        iob: Decimal = 0,
        carbs: Decimal,
        carbRatio: Decimal,
        increment: Decimal
    ) -> Bool {
        bolusRange(carbs: carbs, carbRatio: carbRatio, increment: increment)?.contains(suggestion + iob) ?? false
    }

    /// How far a docs step (1 g/U) higher carb ratio moves where glucose ends with these tablets, in whole mg/dL: the ISF
    /// times the insulin the step changes, ISF × (carbs ÷ CR − carbs ÷ (CR + step)). The Check screen's precision line:
    /// more carbs move it further, so CGM noise matters less. Nil without carbs, a carb ratio or an ISF.
    static func endShiftPerStep(
        carbs: Decimal,
        carbRatio: Decimal,
        isf: Decimal,
        step: Decimal = CarbRatioTest.Config.docsSmallestStep
    ) -> Int? {
        guard carbs > 0, carbRatio > 0, isf > 0 else { return nil }
        let shift = isf * (carbs / carbRatio - carbs / (carbRatio + step))
        return NSDecimalNumber(decimal: rounded(shift, scale: 0, roundingMode: .plain)).intValue
    }

    /// How far glucose had still to move at the end from the insulin Trio reported still on board then (`iobAtEnd`), in
    /// whole mg/dL: IOB × ISF, signed (down for insulin left, up for basal held back). The Result's line beside the band.
    /// Nil without either.
    static func stillToComeOff(iobAtEnd: Decimal?, isf: Decimal) -> Int? {
        guard let iobAtEnd, isf > 0 else { return nil }
        return NSDecimalNumber(decimal: rounded(iobAtEnd * isf, scale: 0, roundingMode: .plain)).intValue
    }

    // MARK: - Schedules

    /// The carb ratio and ISF schedule entries a test begun at `startedAt` can run on, saved at Begin: every hour its
    /// chosen `length` can reach, as the ISF test saves its own (`ISFTestEvaluator.coveredAtBegin`). The latest end is
    /// settling's bound (the time for settling and the dose), then a whole bolus window from there and the length after it.
    static func coveredAtBegin(
        _ entries: [SettingsTestScheduleEntry],
        startedAt: Date,
        length: TimeInterval,
        calendar: Calendar = .current
    ) -> [SettingsTestScheduleEntry]? {
        ISFTestEvaluator.coveredEntries(
            entries,
            from: startedAt,
            to: startedAt.addingTimeInterval(
                CarbRatioTest.Config.settleAllowance + 2 * CarbRatioTest.Config.doseAllowance + length
            ),
            calendar: calendar
        )
    }

    /// The carb ratio and ISF in force at `date`: from the schedules saved at Begin, or the ones saved at Begin without
    /// them.
    static func doseSettings(
        of test: CarbRatioTestState,
        at date: Date,
        calendar: Calendar = .current
    ) -> (carbRatio: Decimal, isf: Decimal) {
        (
            carbRatio: ISFTestEvaluator.scheduleValue(in: test.crEntries, at: date, calendar: calendar) ?? test.carbRatio,
            isf: ISFTestEvaluator.scheduleValue(in: test.isfEntries, at: date, calendar: calendar) ?? test.isf
        )
    }

    /// The test as it moves on to the wait with its bolus at `bolusAt`: the carb ratio and ISF the result uses become
    /// those in force at the bolus (`doseSettings`), and each schedule narrows to the entry in force then. The ratio
    /// counts at the meal, so a change in the hours after it doesn't matter ("Test one meal at a time" is about changing
    /// settings), and the record covers that one entry.
    static func atBolus(_ test: CarbRatioTestState, bolusAt: Date, calendar: Calendar = .current) -> CarbRatioTestState {
        var moved = test
        let settings = doseSettings(of: test, at: bolusAt, calendar: calendar)
        moved.carbRatio = settings.carbRatio
        moved.isf = settings.isf
        moved.crEntries = ISFTestEvaluator.coveredEntries(test.crEntries ?? [], from: bolusAt, to: bolusAt, calendar: calendar)
        moved.isfEntries = ISFTestEvaluator.coveredEntries(
            test.isfEntries ?? [],
            from: bolusAt,
            to: bolusAt,
            calendar: calendar
        )
        return moved
    }

    // MARK: - The Dose step

    /// The dose the Dose step shows: the docs' dose for the tablets with the carb ratio in force at `inputs.now`, or in a
    /// test that counts insulin on board, the counted dose (`testDose`). It can show while the step doesn't offer it
    /// (`canDose`).
    static func doseShown(of test: CarbRatioTestState, _ inputs: CarbRatioTestDoseInputs) -> Decimal? {
        testDose(
            carbs: test.tabletCarbs,
            carbRatio: doseSettings(of: test, at: inputs.now).carbRatio,
            handling: test.iobHandling,
            iob: inputs.doseIOB,
            increment: inputs.increment
        )
    }

    /// Why the Dose step doesn't offer the dose, nil when it does. Missing settings come first, since waiting wouldn't
    /// help; then carbs on board, unread or at or over the line (`cobBlocks`, the line from the carb ratio now); then 3
    /// recent readings for the start glucose (`ISFTestEvaluator.doseGlucose`); then a level arrow
    /// (`ISFTestEvaluator.glucoseIsLevel`); then insulin on board: with Count It, read recently and leaving a dose
    /// (`countedDose`); otherwise read and at or under the line for the dose (`iobLine`). Once the tablets' carbs are
    /// logged ahead of the bolus (`CarbRatioTestState.carbsLoggedAwaitingBolus`), the start glucose, the arrow and carbs on
    /// board are judged at the carbs, the meal's moment (`failedMealCondition`), so only the settings and insulin on
    /// board can hold the bolus back: the tablets' own rise mustn't. Once the time for the bolus after them is up,
    /// nothing is offered (`.mealTimeUp`).
    static func noDoseReason(of test: CarbRatioTestState, _ inputs: CarbRatioTestDoseInputs) -> CarbRatioTestNoDose? {
        let settings = doseSettings(of: test, at: inputs.now)
        guard settings.isf > 0, let dose = dose(carbs: test.tabletCarbs, carbRatio: settings.carbRatio) else {
            return .noSettings
        }
        // Past the time for the bolus after the tablets' carbs, the test is ending: nothing is offered.
        if let deadline = test.bolusDeadline, inputs.now >= deadline { return .mealTimeUp }
        if !test.carbsLoggedAwaitingBolus {
            guard let cob = inputs.cob else { return .carbsUnread }
            if cobBlocks(cob: cob, line: cobLine(carbs: test.tabletCarbs, carbRatio: settings.carbRatio)) {
                return .carbsOnBoard
            }
            let isfInputs = inputs.isfInputs
            guard ISFTestEvaluator.doseGlucose(isfInputs) != nil else { return .noRecentReading }
            guard ISFTestEvaluator.glucoseIsLevel(isfInputs) else { return .notLevel }
        }
        if test.iobHandling == .count {
            guard let doseIOB = inputs.doseIOB else { return .iobUnread }
            let counted = countedDose(
                carbs: test.tabletCarbs,
                carbRatio: settings.carbRatio,
                iob: doseIOB,
                increment: inputs.increment
            )
            return counted == nil ? .iobCoversDose : nil
        }
        guard let iob = inputs.iob else { return .iobUnread }
        let line = iobLine(dose: dose, carbRatio: settings.carbRatio)
        return ISFTestEvaluator.waitsForIOB(iob: iob, line: line, handling: test.iobHandling) ? .iobOverLine : nil
    }

    /// Whether the Dose step offers the dose (Open Treatments on): only while dosing, with a dose to show and nothing
    /// holding it (`noDoseReason`). Never once the bolus is in.
    static func canDose(of test: CarbRatioTestState, _ inputs: CarbRatioTestDoseInputs) -> Bool {
        test.phase == .dosing && noDoseReason(of: test, inputs) == nil && doseShown(of: test, inputs) != nil
    }

    // MARK: - Endings

    /// How a running check ends the test: the reason, the time to end it at (nil for now), and what to say when the
    /// records don't. The ISF test's (`ISFTestEvaluator.Ending`), with this test's end reason.
    struct Ending: Equatable {
        let reason: CarbRatioTestEndReason
        let at: Date?
        let note: String?

        init(reason: CarbRatioTestEndReason, at: Date?, note: String?) {
            self.reason = reason
            self.at = at
            self.note = note
        }

        init(_ ending: ISFTestEvaluator.Ending) {
            self.init(reason: CarbRatioTestEndReason(ending.reason), at: ending.at, note: ending.note)
        }
    }

    /// How the ISF test's running check (`ISFTestEvaluator.runningCheck`, asked with `CarbRatioTestPhase.isfPhase`) ends
    /// this test: as it ends the ISF test, with its own words for carbs logged, since the tablets' carbs are logged too.
    static func ending(for check: ISFTestEvaluator.RunningCheck, doseDeadline: Date) -> Ending {
        if case let .carbsLogged(at) = check {
            return Ending(reason: .interrupted, at: at, note: otherCarbsNote)
        }
        return Ending(ISFTestEvaluator.ending(for: check, doseDeadline: doseDeadline))
    }

    /// Whether a finish for `reason` reads the suspend history once more after normal dosing is back
    /// (`ISFTestEvaluator.rereadsHistory`).
    static func rereadsHistory(_ reason: CarbRatioTestEndReason) -> Bool {
        ISFTestEvaluator.rereadsHistory(reason.isfReason)
    }

    /// How a test the screen finishes for `reason` at `end` ends, once the history is read again, as the ISF test's
    /// (`ISFTestEvaluator.finishing`), with the chosen `length` in place of its 4 hours: End Test tapped once the length
    /// was up, before a check finished the test, completes it, or leaves it unchecked without a readable history.
    static func finishing(
        reason: CarbRatioTestEndReason,
        at end: Date,
        suspend: BasalTestEvaluator.SuspendReading,
        bolusAt: Date?,
        length: TimeInterval,
        doseDeadline: Date
    ) -> Ending {
        var reason = reason
        if reason == .endedEarly, let bolusAt, end >= bolusAt.addingTimeInterval(length) {
            reason = suspend == .unreadable ? .unchecked : .completed
        }
        return Ending(ISFTestEvaluator.finishing(
            reason: reason.isfReason,
            at: end,
            suspend: suspend,
            bolusAt: bolusAt,
            doseDeadline: doseDeadline
        ))
    }

    /// The note a finished test keeps and its notice says, worded from the mode in force once it ended
    /// (`ISFTestEvaluator.modeWorded`), with this test's words for a record that couldn't be read. A note of this test's
    /// that says the usual dosing came back (carbs with no bolus, a bolus off the formula, halves apart) says so only
    /// when it did, and carbs with no bolus say the usual mode covers them only when it is Closed Loop (`usualMode`):
    /// the others never add insulin.
    static func modeWorded(_ note: String?, modeBack: Bool, usualMode: DosingMode = .closed) -> String? {
        let worded = ISFTestEvaluator.modeWorded(note, modeBack: modeBack)
        if worded == ISFTestEvaluator.historyUnreadNote { return historyUnreadNote }
        guard let worded else { return worded }
        if worded.hasPrefix(carbsWithoutBolusNote(modeBack: false)) {
            return carbsWithoutBolusNote(modeBack: modeBack, usualMode: usualMode)
        }
        guard !modeBack else { return worded }
        let modeBackSuffix = " " + SettingsTestNotice.modeBackSentence
        return worded.hasSuffix(modeBackSuffix) ? String(worded.dropLast(modeBackSuffix.count)) : worded
    }

    // MARK: - Notes

    /// What the Result says when a record read to check the test couldn't be read.
    static var historyUnreadNote: String {
        String(
            localized: "Trio couldn't read part of the history to check the test, so it can't say what your carb ratio did."
        )
    }

    /// What the Result says when a test that ran without the tablets' carbs has no verdict for it (`.noCarbs`).
    static var noCarbsNote: String {
        String(localized: "The tablets' carbs weren't logged with the bolus, so the test can't be judged.")
    }

    /// What the Result says when Trio suspended insulin for a low before the tablets' carbs were logged
    /// (`judgedCarbs`): its forecast saw the bolus without them.
    static var lowBeforeCarbsNote: String {
        String(
            localized: "Trio suspended insulin for a low before the tablets' carbs were logged, so the low says nothing about your carb ratio."
        )
    }

    /// The note the test ends with when the tablets' carbs were logged and no bolus came within
    /// `CarbRatioTest.Config.mealPairing` (`mealPairingEnd`), as decided: worded for Closed Loop, the usual mode the
    /// finish words it from (`modeWorded`).
    static var carbsWithoutBolusNote: String { carbsWithoutBolusNote(modeBack: true) }

    /// The same, saying the usual dosing came back only when it did, and that it covers the carbs only when it is Closed
    /// Loop: Open Loop and Low Glucose Suspend never add insulin, so the user covers them as usual.
    static func carbsWithoutBolusNote(modeBack: Bool, usualMode: DosingMode = .closed) -> String {
        let minutes = Int(CarbRatioTest.Config.mealPairing / 60)
        let logged = String(
            localized: "The tablets' carbs were logged, but no bolus came within \(minutes) minutes."
        )
        guard modeBack else { return logged }
        return logged + " " + (
            usualMode == .closed
                ? String(localized: "Your usual dosing mode is back to cover them.")
                : String(
                    localized: "Your usual dosing mode is back, and it doesn't bolus for carbs: cover them as you usually would."
                )
        )
    }

    /// The note the test ends with when the bolus came and no carb entry was logged within
    /// `CarbRatioTest.Config.mealPairing` (`mealPairingEnd`). Whether to say to log them is the finish's to add
    /// (`logCarbsSentence`), from a read of the carbs as it ends: never when they are in.
    static var bolusWithoutCarbsNote: String {
        let minutes = Int(CarbRatioTest.Config.mealPairing / 60)
        return String(localized: "The bolus came, but the tablets' carbs weren't logged within \(minutes) minutes.")
    }

    /// The note the test ends with when both halves of the meal came, more than `CarbRatioTest.Config.mealPairing`
    /// apart, in either order (`mealPairingEnd`): both are logged, so it never says to log either again.
    static var mealApartNote: String {
        let minutes = Int(CarbRatioTest.Config.mealPairing / 60)
        return String(
            localized: "The tablets' carbs and the bolus came more than \(minutes) minutes apart, so the test can't judge them."
        ) + " " + SettingsTestNotice.modeBackSentence
    }

    /// The note the test ends with when the tablets' carbs were logged more than `CarbRatioTest.Config.mealPairing` ago
    /// and the boluses couldn't be read, so no bolus could be paired with them (`bolusesUnreadEnd`): the safe way is to
    /// end it, and if no bolus was given, the carbs are the user's to cover.
    static var bolusesUnreadNote: String {
        let minutes = Int(CarbRatioTest.Config.mealPairing / 60)
        return String(
            localized: "Trio couldn't read your boluses to pair one with the tablets' carbs within \(minutes) minutes, so the test can't be judged. If you didn't give the bolus, cover the carbs as you usually would."
        )
    }

    /// What a test that ended after its bolus with no carb entry logged adds to its words
    /// (`CarbRatioTestState.carbsUnloggedAtEnd`).
    static var logCarbsSentence: String {
        String(localized: "If you ate the tablets, log their carbs so Trio counts them.")
    }

    /// The note for the service's record of a meal not paired (`SettingsTestEndCause.mealUnpaired`) when the test itself
    /// saw neither half.
    static var mealUnpairedNote: String {
        let minutes = Int(CarbRatioTest.Config.mealPairing / 60)
        return String(
            localized: "The tablets' carbs and the bolus didn't come within \(minutes) minutes of each other, so the test can't be judged."
        )
    }

    /// What the Result says when carbs other than the tablets' were logged.
    static var otherCarbsNote: String {
        String(localized: "Carbs other than the tablets were logged during the test.")
    }

    // MARK: - The Result's words

    /// The finished test's result worked out again from what it saved, as the finish worked it out. Nil for a test that
    /// hasn't finished.
    static func evaluation(of test: CarbRatioTestState) -> Evaluation? {
        guard let end = test.endedAt, let reason = test.endReason else { return nil }
        return evaluate(
            startGlucose: test.startGlucose,
            endGlucose: test.endGlucose,
            units: judgedUnits(of: test),
            // From the bolus, or from Begin if none came, as the finish times it.
            elapsed: end.timeIntervalSince(test.bolusAt ?? test.startedAt),
            length: test.length,
            reason: reason,
            interference: test.interference,
            interferenceUnread: test.interferenceUnread ?? false,
            iobUnread: iobUnread(of: test),
            carbs: judgedCarbs(of: test),
            carbRatio: test.carbRatio,
            isf: test.isf,
            givenUnits: givenUnits(of: test),
            increment: test.bolusIncrement,
            lowThreshold: test.lowThreshold ?? Preferences.basalTestingThreshold
        )
    }

    /// The re-derived evaluation when it gives the verdict the finish saved, which the headline shows. Nil when it
    /// doesn't, so the working and the band never contradict the headline.
    static func matchingEvaluation(of test: CarbRatioTestState) -> Evaluation? {
        guard let evaluation = evaluation(of: test), evaluation.outcome == test.outcome else { return nil }
        return evaluation
    }

    /// The band the result chart shades (`accurateEnds`), for a verdict judged on where glucose ended
    /// (`matchingEvaluation`, not a low). Nil otherwise, and when no whole reading lies inside.
    static func resultBand(of test: CarbRatioTestState) -> CarbRatioTestBand? {
        guard test.endReason != .low, matchingEvaluation(of: test)?.outcome.isConclusive == true,
              let start = test.startGlucose, let carbs = judgedCarbs(of: test), let units = judgedUnits(of: test)
        else { return nil }
        return accurateEnds(startGlucose: start, carbs: carbs, units: units, carbRatio: test.carbRatio, isf: test.isf)
    }

    /// Why a finished test says nothing about the carb ratio, in the order `evaluate` decides it. Nil for one with a
    /// verdict, a low among them, and for a test that hasn't finished. No bolus comes before the other interruptions: it
    /// is what ended the test.
    static func noVerdict(for test: CarbRatioTestState) -> CarbRatioTestNoVerdict? {
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
                carbs: judgedCarbs(of: test),
                carbRatio: test.carbRatio,
                increment: test.bolusIncrement,
                lowThreshold: test.lowThreshold ?? Preferences.basalTestingThreshold
            )
        }
        if iobUnread(of: test) { return .historyUnread }
        if reason == .unchecked { return .lowUnchecked }
        if reason == .endedEarly || end.timeIntervalSince(test.bolusAt ?? test.startedAt) < test.length {
            return .tooSoon
        }
        guard let start = test.startGlucose, test.endGlucose != nil else { return .noReadings }
        guard let carbs = judgedCarbs(of: test), carbs > 0 else { return .noCarbs }
        guard let units = judgedUnits(of: test), units > 0, test.carbRatio > 0, test.isf > 0 else { return .noAmount }
        if accurateEnds(startGlucose: start, carbs: carbs, units: units, carbRatio: test.carbRatio, isf: test.isf) == nil {
            return .carbsTooFew
        }
        return nil
    }

    /// What a result with no verdict says about why, for the Result and for the notice that the test ended. `noVerdict`
    /// is `noVerdict(for:)`; `test` gives the wording what it needs (its note, how long it ran). A test that ended after
    /// its bolus with no carb entry logged adds that the tablets' carbs, if eaten, are the user's to log
    /// (`logCarbsSentence`); never when one is in.
    static func noVerdictText(_ noVerdict: CarbRatioTestNoVerdict?, test: CarbRatioTestState) -> String {
        let text = reasonText(noVerdict, test: test)
        return test.carbsUnloggedAtEnd == true ? text + " " + logCarbsSentence : text
    }

    private static func reasonText(_ noVerdict: CarbRatioTestNoVerdict?, test: CarbRatioTestState) -> String {
        switch noVerdict {
        case .noBolus:
            let minutes = Int(CarbRatioTest.Config.doseAllowance / 60)
            return String(
                localized: "The test needs your bolus within \(minutes) minutes of starting. Trio didn't see one, so there was nothing to judge."
            )
        case .interrupted:
            return test.interference
                ?? String(localized: "Something changed during the test, so the result can't be trusted. Try again.")
        case .historyUnread:
            return historyUnreadNote
        case .tooSoon:
            return String(
                localized: "This test ended after \(elapsedText(for: test)), so it's too soon to tell what your carb ratio did."
            )
        case .lowUnchecked:
            return String(localized: "Trio couldn't read the pump history to check for a low, so it can't judge this test.")
        case .noReadings:
            // "None recorded" only when none were since the bolus: with some, too few, too old or with a gap gave no mean.
            return test.readings.isEmpty
                ? String(
                    localized: "No CGM readings were recorded at the bolus or at the end of the test, so there is nothing to compare."
                )
                : String(
                    localized: "Trio didn't have 3 CGM readings close together at the bolus or at the end, so there is nothing to compare."
                )
        case .noAmount:
            return String(
                localized: "The pump didn't record how much insulin the bolus gave, so there is no carb ratio to work out."
            )
        case .noCarbs:
            return test.endReason == .low ? lowBeforeCarbsNote : noCarbsNote
        case .carbsTooFew:
            return String(localized: "The carbs were too few for this test to tell your carb ratio apart from CGM noise.")
        case .forecastSuspend:
            return String(
                localized: "Trio suspended insulin on its forecast, with your glucose not yet low or still above where it started, so the test can't tell."
            )
        case .doseOverDocs:
            return String(
                localized: "The bolus was more than the formula's dose, so the low can't be put down to your carb ratio."
            )
        case nil:
            return String(localized: "Trio couldn't tell what your carb ratio did from this test.")
        }
    }

    /// How long the test ran, "3 h", or "2 h 10 m" when it isn't whole hours: from the bolus, or from Begin if none came,
    /// to its end, or to the planned end, or the dose deadline, if it hasn't ended.
    static func elapsedText(for test: CarbRatioTestState) -> String {
        let end = test.endedAt ?? test.plannedEnd ?? test.doseDeadline
        let elapsed = max(0, end.timeIntervalSince(test.bolusAt ?? test.startedAt))
        let minutes = Int(elapsed) / 60
        return minutes % 60 == 0 && minutes > 0 ? "\(minutes / 60) h" : SettingsTestFormat.duration(elapsed)
    }

    /// What the archived record says about a result. A low ends the test as too low a carb ratio whatever the readings
    /// were, so for a low it says what Trio did. The others say where glucose ended against where the carb ratio says it
    /// would: with a bolus other than the formula's, that isn't where it started.
    static func summary(for outcome: CarbRatioTestOutcome, reason: CarbRatioTestEndReason) -> String {
        switch outcome {
        case .accurate: return String(localized: "Glucose ended about where your carb ratio says")
        case .tooHigh: return String(localized: "Glucose ended higher than your carb ratio says")
        case .tooLow:
            return reason == .low
                ? String(localized: "Trio suspended insulin for a low")
                : String(localized: "Glucose ended lower than your carb ratio says")
        case .inconclusive: return String(localized: "Ended too soon to tell")
        case .invalid: return String(localized: "Test was interrupted")
        }
    }

    /// The Result's headline for an outcome. A test with no verdict that ran its length wasn't too short.
    static func headline(for outcome: CarbRatioTestOutcome, noVerdict: CarbRatioTestNoVerdict?) -> String {
        switch outcome {
        case .accurate: return String(localized: "Carb ratio looks accurate")
        case .tooHigh: return String(localized: "Carb ratio looks too high")
        case .tooLow: return String(localized: "Carb ratio looks too low")
        case .inconclusive:
            return noVerdict == .tooSoon
                ? String(localized: "Too soon to tell")
                : String(localized: "Can't tell from this test")
        case .invalid: return String(localized: "Test was interrupted")
        }
    }

    /// The docs' line for what the test showed. A test that ended before its length gets the docs' monitoring time
    /// instead. Nil for one interrupted, or with no verdict for another reason.
    static func docsLine(for outcome: CarbRatioTestOutcome, noVerdict: CarbRatioTestNoVerdict?) -> String? {
        switch outcome {
        case .accurate: return CarbRatioTest.Docs.returnToStart
        case .tooHigh: return CarbRatioTest.Docs.endUpHigh
        case .tooLow: return CarbRatioTest.Docs.endUpLow
        case .inconclusive: return noVerdict == .tooSoon ? CarbRatioTest.Docs.monitor : nil
        case .invalid: return nil
        }
    }
}
