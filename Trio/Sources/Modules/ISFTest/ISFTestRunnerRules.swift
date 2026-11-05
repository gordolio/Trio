import Foundation

// The rules the Dose step and the Result read, kept apart from the screen so the ISF test's runner can ask them the same
// questions with the screen closed (`ISFTestEvaluator.failedBolusCondition` is the other half, in `ISFTestModels`).

/// Everything the Dose step reads to work out whether the dose can be given, as one value: the screen builds it from what
/// it has read, and a runner builds it from the same reads, so both judge the same thing.
struct ISFTestDoseInputs: Equatable {
    /// CGM readings, newest first.
    var readings: [BasalTestReading]
    /// The CGM's own arrow on the newest reading. Nil when it gave none.
    var direction: BloodGlucose.Direction?
    /// Insulin on board now, signed. Nil while Trio hasn't worked it out.
    var iob: Decimal?
    /// Insulin on board for a counted dose, from Trio's newest determination of the last 12 minutes
    /// (`ISFTestEvaluator.recentIOB`). Nil when there is none, or in a test that doesn't count it.
    var doseIOB: Decimal?
    /// Carbs on board from Trio's newest determination of the last 12 minutes (`ISFTestEvaluator.recentCOB`). Nil while
    /// there is none that recent: unread is not none.
    var cob: Decimal?
    /// The pump's bolus increment, which a counted dose must reach. Zero when it isn't known.
    var increment: Decimal
    /// The moment these are judged at.
    var now: Date
}

/// An ending decided and saved before the usual mode comes back (`ISFTestState.pendingEnd`), so a finish cut short, with
/// Trio killed between the two, is finished for the same ending at the next check: never a verdict it didn't have, never
/// another reason, and one notice.
struct ISFTestPendingEnd: JSON, Equatable {
    var reason: ISFTestEndReason
    /// When the test ends, worked out once as the ending is decided (`SettingsTestEndRule.endTime`).
    var at: Date
    /// What to say about it when the records don't.
    var note: String?
    /// Whether the user ended it (End Test), which posts no notice.
    var byUser: Bool
}

/// The Dose step's notice a running test still owes (`ISFTestState.doseNoticeDue`): "ISF Dose Ready", once the step shows
/// a dose that Open Treatments would give. Owed through a step that waits (for a reading, a flat arrow, insulin on board
/// under the line) or offers tablets, since those can change by themselves; dropped only when it goes, or when the bolus,
/// a move to another step, a finish (a dead end's among them) or Cancel Test makes it moot.
enum ISFTestDoseNoticeDue: String, JSON {
    /// Settling moved on to the Dose step. If the step offers more tablets before it shows a dose, "ISF Test Settled"
    /// goes first, once (`settledTabletsSaid`).
    case settled
    /// The same, with "ISF Test Settled" already said for a step that offered more tablets: only "ISF Dose Ready" is left.
    case settledTabletsSaid
    /// The tablets acted and moved the test on to the Dose step. A step that offers more tablets gets no notice of its
    /// own.
    case tabletsActed

    /// The notice that goes once the Dose step shows a dose.
    var doseReady: ISFTestStepNotice {
        self == .tabletsActed ? .tabletsActed : .settledToDose
    }
}

/// What the Result offers to do about a verdict that says to change the ISF (`ISFTestEvaluator.resultAction`).
enum ISFTestResultAction: Equatable {
    /// Open Insulin Sensitivities, where the profile ISF is.
    case openSensitivities
    /// With Logarithmic Dynamic ISF on, the docs' line for it instead, which opens its desmos graphs: "Re-evaluate your
    /// Adjustment Factor and other Dynamic Settings" (isf.md, "Common ISF Mistakes"). The profile ISF all but cancels
    /// out of that formula, so changing it does little.
    case reevaluateDynamicSettings
}

/// What the Dose step offers now, for its notice (`ISFTestEvaluator.doseStepOffer`).
enum ISFTestDoseStepOffer: Equatable {
    /// A dose (`docsDose`).
    case dose
    /// No dose, with glucose at or below the target, and Take Glucose Tablets (`canRaise`).
    case tablets
    /// Neither: it waits for a reading, or it is a dead end that offers only Cancel Test, which the runner ends the test
    /// at (`doseDeadEnd`).
    case neither
}

extension ISFTestEvaluator {
    /// How old the newest reading can be for the CGM's arrow to still be shown and counted: 15 minutes.
    static let arrowMaxAge: TimeInterval = 15 * 60

    // MARK: - The Dose step's readiness

    /// The glucose the dose and the tablets are worked out from: the mean of the newest 3 readings, nil when the newest
    /// is older than `BasalTest.Config.endReadingMaxAge`, or any of them that much older than the next
    /// (`BasalTestEvaluator.endGlucose`).
    static func doseGlucose(_ inputs: ISFTestDoseInputs) -> Int? {
        BasalTestEvaluator.endGlucose(from: Array(inputs.readings.prefix(3)), endingAt: inputs.now)
    }

    /// The CGM's own arrow for a recent reading: nil when it gave none, and when the newest reading is more than
    /// `arrowMaxAge` old or there is none.
    static func shownDirection(_ inputs: ISFTestDoseInputs) -> BloodGlucose.Direction? {
        guard let latest = inputs.readings.first?.date, inputs.now.timeIntervalSince(latest) <= arrowMaxAge else {
            return nil
        }
        return inputs.direction
    }

    /// Whether the tablets taken have acted (`tabletsActed(_:tabletsTakenAt:glucoseAtTablets:at:)`), as of the newest
    /// reading: a CGM gap since doesn't undo it, and the dose needs a recent reading of its own (`doseGlucose`). False
    /// before they are taken.
    static func tabletsActed(of test: ISFTestState, _ inputs: ISFTestDoseInputs) -> Bool {
        guard let takenAt = test.tabletsTakenAt else { return false }
        return tabletsActed(inputs.readings, tabletsTakenAt: takenAt, glucoseAtTablets: test.tabletsGlucose)
    }

    /// Whether glucose rose from the tablets taken and then stopped rising
    /// (`tabletsLeveledOff(_:tabletsTakenAt:glucoseAtTablets:at:)`), as of the newest reading, as `tabletsActed(of:_:)`;
    /// on the Dose step, true once latched there (`ISFTestState.tabletsLeveledAt`), so plateau noise after the step first
    /// offered the dose doesn't take it back (N3). False before they are taken.
    static func tabletsLeveledOff(of test: ISFTestState, _ inputs: ISFTestDoseInputs) -> Bool {
        guard let takenAt = test.tabletsTakenAt else { return false }
        if test.phase == .dosing, test.tabletsLeveledAt != nil { return true }
        return tabletsLeveledOff(inputs.readings, tabletsTakenAt: takenAt, glucoseAtTablets: test.tabletsGlucose)
    }

    /// Whether the ISF schedule holds up Begin, a docs rule ("Test one time period at a time"): no bolus moment from
    /// settling's earliest end (Trio's first loop in Basal Testing, `settleLoopMargin` after Begin) to the dose deadline
    /// from then (`doseAllowance` after it) has its 4 hours on one ISF value (`clearsISFChange`), so the Raise and Dose
    /// steps could only end at their dead ends (N1, M1).
    static func isfChangeBlocksBegin(
        _ entries: [SettingsTestScheduleEntry],
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        let earliest = now.addingTimeInterval(ISFTest.Config.settleLoopMargin)
        return !clearsISFChange(
            entries,
            from: earliest,
            to: earliest.addingTimeInterval(ISFTest.Config.doseAllowance),
            calendar: calendar
        )
    }

    /// Whether some moment from `start` to `end` has its docs' 4 hours on one ISF value of `entries`: `start` itself, or
    /// one of the times an entry starts in between, the first moment past a change. At the entries' times of day in
    /// `calendar`, set by the clock, so they hold on a day the clocks change (L4).
    static func clearsISFChange(
        _ entries: [SettingsTestScheduleEntry],
        from start: Date,
        to end: Date,
        calendar: Calendar = .current
    ) -> Bool {
        let firstDay = calendar.startOfDay(for: start)
        let changes = (0 ... 1).flatMap { day -> [Date] in
            guard let dayStart = calendar.date(byAdding: .day, value: day, to: firstDay) else { return [] }
            return Set(entries.map(\.startMinutes)).compactMap {
                calendar.date(bySettingHour: $0 / 60, minute: $0 % 60, second: 0, of: dayStart)
            }
        }
        let moments = [start] + changes.filter { $0 > start && $0 <= end }.sorted()
        return moments.contains {
            !crossesISFChange(entries, from: $0, for: ISFTest.Config.docsWait, calendar: calendar)
        }
    }

    /// How far before Begin the temp basals are read to find the one running at settling's time-up
    /// (`tempBasalIsDeadEnd`): a day, past the 12 hours Omnipod runs a temp for at most.
    static let runningTempLookback: TimeInterval = 24 * 3600

    /// Whether a temp basal settling found running at its time-up is the dead end it says (P3): only when the pump history
    /// shows one running now (`temps`, read from before Begin: the newest at or before `now`, with its time not yet up), so
    /// one set on the pump before Begin counts and one that has ended doesn't (L3), and it isn't a zero temp a Basal
    /// Testing determination asked for (`zeroTempDeterminations`, from `settleLoopMargin` after Begin, as `suspendReading`
    /// reads them): that one is Basal Testing's suspend for a low, which the running check ends the test for. None running
    /// in the history is one the pump is still enacting, Basal Testing's among them, so the next check decides (N2).
    static func tempBasalIsDeadEnd(
        temps: [BasalTestTempBasal],
        zeroTempDeterminations: [Date],
        startedAt: Date,
        now: Date
    ) -> Bool {
        guard let newest = temps.filter({ $0.date <= now }).max(by: { $0.date < $1.date }),
              now < newest.date.addingTimeInterval(Double(newest.minutes) * 60)
        else { return false }
        guard newest.rate == 0 else { return true }
        return suspendReading(
            [newest],
            zeroTempDeterminations: zeroTempDeterminations,
            startedAt: startedAt,
            until: now
        ) != .suspended(at: newest.date)
    }

    /// Whether the docs' 4 hours from `date` cover more than one ISF value of the schedule Begin saved
    /// (`crossesISFChange`): "Test one time period at a time". False without one.
    static func crossesISFChange(of test: ISFTestState, from date: Date, calendar: Calendar = .current) -> Bool {
        crossesISFChange(test.coveredEntries ?? [], from: date, for: ISFTest.Config.docsWait, calendar: calendar)
    }

    /// The dose the Dose step shows (`testDose`): the docs' correction with the ISF and target in force at `inputs.now`
    /// (`doseSettings`), less the insulin on board in a test that counts it. Nil without a recent reading, at or below
    /// the target, with carbs on board or unread, with counting when insulin on board covers the correction or hasn't
    /// been read recently, and while the 4 hours from now cover more than one ISF value (`crossesISFChange`).
    static func docsDose(of test: ISFTestState, _ inputs: ISFTestDoseInputs) -> Decimal? {
        guard !crossesISFChange(of: test, from: inputs.now), let glucose = doseGlucose(inputs) else { return nil }
        let settings = doseSettings(of: test, at: inputs.now)
        return testDose(
            glucose: glucose,
            target: settings.target,
            isf: settings.isf,
            handling: test.iobHandling,
            iob: inputs.doseIOB,
            increment: inputs.increment,
            carbsOnBoard: inputs.cob
        )
    }

    /// Why the Dose step shows no dose (`docsDose`), from the same inputs (`noDoseReason(glucose:…)`), as the step says
    /// it. Nil when it shows one.
    static func noDoseReason(of test: ISFTestState, _ inputs: ISFTestDoseInputs) -> ISFTestNoDose? {
        let settings = doseSettings(of: test, at: inputs.now)
        return noDoseReason(
            glucose: doseGlucose(inputs),
            target: settings.target,
            isf: settings.isf,
            handling: test.iobHandling,
            iob: inputs.doseIOB,
            increment: inputs.increment,
            carbsOnBoard: inputs.cob,
            crossesISFChange: crossesISFChange(of: test, from: inputs.now),
            isfChangeClearsBeforeDeadline: clearsISFChange(
                test.coveredEntries ?? [],
                from: inputs.now,
                to: test.doseDeadline
            )
        )
    }

    /// What the Dose step offers now, from the same inputs and rules as the step: a dose (`docsDose`), Take Glucose
    /// Tablets (glucose at or below the target, `canRaise`), or neither.
    static func doseStepOffer(of test: ISFTestState, _ inputs: ISFTestDoseInputs) -> ISFTestDoseStepOffer {
        if docsDose(of: test, inputs) != nil { return .dose }
        guard noDoseReason(of: test, inputs) == .atOrBelowTarget,
              canRaise(target: doseSettings(of: test, at: inputs.now).target)
        else { return .neither }
        return .tablets
    }

    /// What an owed Dose step notice does as the step is now: the notice to post, if any, and what is owed after it.
    /// "ISF Dose Ready" goes once the step shows a dose and Open Treatments would turn on (`canDose`: the CGM's arrow
    /// flat, insulin on board under the dose's line), since it promises a dose that can be given, and nothing is owed
    /// after it. After settling, a step that offers more tablets first gets "ISF Test Settled", the copy for the tablets,
    /// once, and "ISF Dose Ready" stays owed. Otherwise nothing goes, and the notice stays owed.
    static func doseNotice(
        due: ISFTestDoseNoticeDue,
        offer: ISFTestDoseStepOffer,
        canDose: Bool
    ) -> (post: ISFTestStepNotice?, due: ISFTestDoseNoticeDue?) {
        switch offer {
        case .dose:
            return canDose ? (due.doseReady, nil) : (nil, due)
        case .tablets:
            return due == .settled ? (.settledToRaise, .settledTabletsSaid) : (nil, due)
        case .neither:
            return (nil, due)
        }
    }

    /// Whether the dose can be worked out now (`canDose(phase:…)`): dosing, when the docs' formula gives one, the CGM's
    /// arrow is flat (or there is none for a recent reading, R6), insulin on board is under the line for the dose shown,
    /// and after tablets glucose hasn't started rising again; raising, once the tablets were taken, glucose has risen from
    /// them and then stopped rising (`tabletsLeveledOff`) under a level arrow, with a reading recent enough to work the
    /// dose out from (`doseGlucose`): a flat arrow still shows for a reading up to 15 minutes old. Raising needs no dose:
    /// the Dose step it moves on to can show none (glucose leveled off at or below a target of 150 or more, which the
    /// schedule reached during the Raise step), and then it is a dead end the runner ends the test at with its sentence
    /// (`doseDeadEnd`), rather than a Raise step left waiting to its deadline.
    static func canDose(of test: ISFTestState, _ inputs: ISFTestDoseInputs) -> Bool {
        if test.phase == .raising, doseGlucose(inputs) == nil { return false }
        return canDose(
            phase: test.phase,
            tabletsTaken: test.tabletsTakenAt != nil,
            tabletsActed: tabletsActed(of: test, inputs),
            tabletsLeveledOff: tabletsLeveledOff(of: test, inputs),
            isLevel: glucoseIsLevel(inputs),
            dose: docsDose(of: test, inputs),
            iobAllowsDose: doseIOBAllows(of: test, inputs),
            carbsOnBoard: inputs.cob
        )
    }

    /// Whether the CGM shows glucose leveled off (`isLevel`): a flat arrow, or none for a recent reading (R6).
    static func glucoseIsLevel(_ inputs: ISFTestDoseInputs) -> Bool {
        isLevel(direction: shownDirection(inputs), hasRecentReading: doseGlucose(inputs) != nil)
    }

    /// Whether insulin on board lets the dose the Dose step shows (`docsDose`) go ahead (`iobAllowsDose`). Without a test
    /// there is no dose to hold back.
    static func doseIOBAllows(of test: ISFTestState?, _ inputs: ISFTestDoseInputs) -> Bool {
        iobAllowsDose(iob: inputs.iob, dose: test.flatMap { docsDose(of: $0, inputs) }, handling: test?.iobHandling)
    }

    // MARK: - Dead ends

    /// The sentence the Settle step shows once its time is up with no way on but Cancel Test: no loop in Basal Testing,
    /// too few readings since it, or a temp basal still running. Counting insulin on board can't help, so the runner ends
    /// the test with it. Nil for any other decision, the time-up question among them.
    static func deadEndSentence(settling: ISFTestSettling) -> String? {
        switch settling {
        case .noLoop:
            return String(
                localized: "Trio hasn't looped in Basal Testing yet, so the test can't start. Check your CGM and pump, then begin again."
            )
        case .tooFewReadings:
            return String(
                localized: "Trio hasn't had enough CGM readings since you began to start the test. Check your CGM, then begin again."
            )
        case .tempBasalRunning:
            return String(
                localized: "A temp basal is still running on your pump, so the test can't start. Cancel it on the pump, then begin again."
            )
        case .settled,
             .timeUp,
             .waiting:
            return nil
        }
    }

    /// The sentence the Dose step's card gives for why there is no dose, when it is a sentence rather than a wait for a
    /// reading (those show a waiting row). Nil for those.
    static func noDoseSentence(_ noDose: ISFTestNoDose) -> String? {
        switch noDose {
        case .carbsOnBoard:
            return String(localized: "Carbs are on board, so the test can't be judged. The docs test ISF with no carbs on board.")
        case .atOrBelowTarget:
            return String(localized: "Your glucose is at or below your target, so the formula gives no dose.")
        case .iobCoversDose:
            return String(localized: "Your insulin on board already covers the formula's correction, so there's no dose to give.")
        case .noSettings:
            return String(localized: "Trio couldn't read your ISF or target, so it can't work out the dose.")
        case .isfChanges,
             .isfChangesUntilDeadline:
            // The Check screen's sentence for its ISF-change row, the first of its info sheet's.
            return String(localized: "The 4 hours from now cover more than one ISF.")
        case .carbsUnread,
             .iobUnread,
             .noRecentReading:
            return nil
        }
    }

    /// The sentence of a Dose step that offers only Cancel Test, as it shows it, which the runner ends the test with:
    /// carbs on board, insulin on board covering the correction, no settings, or glucose at or below a target tablets
    /// can't raise it past (`canRaise`). The same dead ends as the step's footer and its deadline line
    /// (`showsDoseDeadline`). Nil while it shows a dose, waits for a reading, or offers Take Glucose Tablets.
    static func doseDeadEnd(of test: ISFTestState, _ inputs: ISFTestDoseInputs) -> String? {
        guard let noDose = noDoseReason(of: test, inputs) else { return nil }
        let raises = canRaise(target: doseSettings(of: test, at: inputs.now).target)
        guard !showsDoseDeadline(noDose: noDose, canRaise: raises) else { return nil }
        return noDoseSentence(noDose)
    }

    /// The sentence the runner ends a Raise step with before the tablets: the Dose step's ISF-change dead end
    /// (`isfChangesUntilDeadline`), when no moment from `now` to the dose deadline has its 4 hours on one ISF value
    /// (`clearsISFChange`), so no tablets are asked for a dose that can't come (M1). Nil once they are taken, and
    /// otherwise.
    static func raiseDeadEnd(of test: ISFTestState, now: Date) -> String? {
        guard test.phase == .raising, test.tabletsTakenAt == nil,
              !clearsISFChange(test.coveredEntries ?? [], from: now, to: test.doseDeadline)
        else { return nil }
        return noDoseSentence(.isfChangesUntilDeadline)
    }

    // MARK: - The Result's words

    /// What a result with no verdict says about why, for the Result and for the notice that the test ended. `noVerdict`
    /// is `noVerdict(for:)`; `test` gives the wording what it needs (its note, how long it ran).
    static func noVerdictText(_ noVerdict: ISFTestNoVerdict?, test: ISFTestState) -> String {
        switch noVerdict {
        case .noBolus:
            let minutes = Int(ISFTest.Config.doseAllowance / 60)
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
                localized: "This test ended after \(elapsedText(for: test)), so it's too soon to tell what your ISF did."
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
                localized: "The pump didn't record how much insulin the bolus gave, so there is no drop per unit to work out."
            )
        case .doseTooSmall:
            return String(localized: "The dose was too small for this test to tell your ISF apart from CGM noise.")
        case .forecastSuspend:
            return String(
                localized: "Trio suspended insulin on its forecast while your glucose was still above your target, so the test can't tell."
            )
        case .doseOverDocs:
            return String(localized: "The bolus was more than the formula's dose, so the low can't be put down to your ISF.")
        case nil:
            return String(localized: "Trio couldn't tell what your ISF did from this test.")
        }
    }

    /// How long the test ran, "4 h", or "2 h 10 m" when it isn't whole hours: from the bolus, or from Start if none came,
    /// to its end, or to the planned end, or the dose deadline, if it hasn't ended.
    static func elapsedText(for test: ISFTestState) -> String {
        let end = test.endedAt ?? test.plannedEnd ?? test.doseDeadline
        let elapsed = max(0, end.timeIntervalSince(test.bolusAt ?? test.startedAt))
        let minutes = Int(elapsed) / 60
        return minutes % 60 == 0 && minutes > 0 ? "\(minutes / 60) h" : SettingsTestFormat.duration(elapsed)
    }

    // MARK: - What the screens show

    /// What the Result offers for a verdict that says to change the ISF (too high or too low), nil for any other: Open
    /// Insulin Sensitivities, or, with Logarithmic Dynamic ISF on (`useNewFormula` without `sigmoid`), the docs' line for
    /// it (`ISFTestResultAction.reevaluateDynamicSettings`). The verdict's own words stay as they are.
    static func resultAction(outcome: ISFTestOutcome, logarithmicDynamicISF: Bool) -> ISFTestResultAction? {
        switch outcome {
        case .tooHigh,
             .tooLow:
            return logarithmicDynamicISF ? .reevaluateDynamicSettings : .openSensitivities
        case .accurate,
             .inconclusive,
             .invalid:
            return nil
        }
    }

    /// Whether a finished test ended on Trio's suspend on its forecast with glucose still above the target
    /// (`ISFTestNoVerdict.forecastSuspend`), which isn't a low: the Result words it that way everywhere (`showsLowCard`,
    /// `endedEarlyCaption`, `lowSuspendObservation`).
    static func isForecastSuspend(for test: ISFTestState) -> Bool {
        test.endReason == .low && noVerdict(for: test) == .forecastSuspend
    }

    /// Whether the Result shows the low card, "Treat the low as usual": only for a low that is one, so not for a forecast
    /// suspend (`isForecastSuspend`).
    static func showsLowCard(for test: ISFTestState) -> Bool {
        test.endReason == .low && !isForecastSuspend(for: test)
    }

    /// The Result header's line for a test that ended on Trio's suspend for a low, "Trio suspended insulin for a low at
    /// 5:58 AM". Nil for a forecast suspend (not a low, so the header gives it the line of any test with no verdict), for
    /// any other end reason, and when there is no end time.
    static func lowSuspendObservation(for test: ISFTestState) -> String? {
        guard test.endReason == .low, !isForecastSuspend(for: test), let suspendedAt = test.endedAt else { return nil }
        return String(
            localized: "Trio suspended insulin for a low at \(suspendedAt.formatted(date: .omitted, time: .shortened))"
        )
    }

    /// The end of the chart caption under the hours it covers, for why the test ended early: Trio's suspend, which is
    /// said to be on its forecast when it was (`isForecastSuspend`), the user ending it, or something interrupting it.
    /// Empty for the other end reasons: the 4 hours were up (completed, or unchecked), no bolus came, and none yet.
    static func endedEarlyCaption(for test: ISFTestState) -> String {
        switch test.endReason {
        case .low:
            return isForecastSuspend(for: test)
                ? String(localized: ". Ended early: Trio suspended insulin on its forecast.")
                : String(localized: ". Ended early: Trio suspended insulin for a low.")
        case .endedEarly: return String(localized: ". You ended it early.")
        case .interrupted: return String(localized: ". Ended early: it was interrupted.")
        case .completed,
             nil,
             .noBolus,
             .unchecked: return ""
        }
    }

    /// Whether the Dose step shows the line saying when the bolus must come by. Not on a dead end that only offers
    /// Cancel Test, where there is no bolus to give: carbs on board, insulin on board covering the correction, no
    /// settings, and glucose at or below the target when tablets can't be offered (`canRaise`). Shown with a dose, while
    /// a reading is awaited, and at or below the target when Take Glucose Tablets is offered: when the footer offers a way
    /// on. A switch over every case, so a new one has to say which it is. The footer chooses its button from the same
    /// facts (`ISFTestNoDose.isWaiting`, `.atOrBelowTarget` with `canRaise`).
    static func showsDoseDeadline(noDose: ISFTestNoDose?, canRaise: Bool) -> Bool {
        guard let noDose else { return true }
        switch noDose {
        case .carbsUnread,
             .iobUnread,
             .isfChanges,
             .noRecentReading: return true
        case .atOrBelowTarget: return canRaise
        case .carbsOnBoard,
             .iobCoversDose,
             .isfChangesUntilDeadline,
             .noSettings: return false
        }
    }

    /// The `duration` from `start`, as the parts of the day it covers: each ISF entry clipped to those hours, in the
    /// order they are reached (across midnight too), with adjacent parts of the same ISF made one. A part that runs past
    /// midnight, one ISF either side of it, ends before it starts, as a window does (`SettingsTestTimeWindow`). Empty
    /// without entries that touch the hours, and for under a minute.
    static func coveredSpans(
        _ entries: [SettingsTestScheduleEntry],
        from start: Date,
        for duration: TimeInterval,
        calendar: Calendar = .current
    ) -> [SettingsTestScheduleEntry] {
        guard duration >= 60 else { return [] }
        // The end is read from its own date, as `coveredEntries` does, so both agree on which entries the hours reach.
        let window = SettingsTestTimeWindow(from: start, to: start.addingTimeInterval(duration), calendar: calendar)
        let days = window.endMinutes > window.startMinutes
            ? [window.startMinutes ..< window.endMinutes]
            : [window.startMinutes ..< 1440, 0 ..< window.endMinutes]
        let ordered = entries.sorted { $0.startMinutes < $1.startMinutes }
        var spans: [SettingsTestScheduleEntry] = []
        for day in days {
            for entry in ordered {
                let from = max(entry.startMinutes, day.lowerBound)
                let to = min(entry.endMinutes, day.upperBound)
                guard to > from else { continue }
                if let last = spans.last, last.value == entry.value,
                   last.endMinutes == from || (last.endMinutes == 1440 && from == 0)
                {
                    spans[spans.count - 1] = SettingsTestScheduleEntry(
                        startMinutes: last.startMinutes,
                        endMinutes: to,
                        value: last.value
                    )
                } else {
                    spans.append(SettingsTestScheduleEntry(startMinutes: from, endMinutes: to, value: entry.value))
                }
            }
        }
        return spans
    }

    /// The parts of the test's hours (`coveredSpans`) as the ISF-change sheet lists them: "6:30 AM–8:06 AM: 50 mg/dL/U,
    /// 8:06 AM–10:30 AM: 40 mg/dL/U", the ISF in the user's units. Each part is one unbreakable word: no-break spaces, a
    /// word joiner after the dash and a no-break space after the colon (the ISF keeps its unit together already), so a
    /// line can only break at the ", " between parts, where the ISF changes, and never inside one. What a reader sees is
    /// the same characters.
    static func isfChangeReading(
        _ spans: [SettingsTestScheduleEntry],
        units: GlucoseUnits,
        formatter: DateFormatter = SettingsTestSchedule.timeFormatter
    ) -> String {
        spans.map { span in
            let hours = SettingsTestSchedule.spanText(of: span, inSentence: true, formatter: formatter)
                .replacingOccurrences(of: " ", with: "\u{00A0}")
                .replacingOccurrences(of: "–", with: "–\u{2060}")
            return "\(hours):\u{00A0}\(SettingsTestKind.isfText(span.value, units: units))"
        }
        .joined(separator: ", ")
    }

    /// The title of the card the Raise and Dose steps show while glucose settles before the dose: "Waiting for the
    /// tablets to act" on Raise until they have, otherwise "Waiting for your glucose to level off".
    static func levelingTitle(phase: ISFTestPhase, tabletsActed: Bool) -> String {
        phase == .raising && !tabletsActed
            ? String(localized: "Waiting for the tablets to act")
            : String(localized: "Waiting for your glucose to level off")
    }
}
