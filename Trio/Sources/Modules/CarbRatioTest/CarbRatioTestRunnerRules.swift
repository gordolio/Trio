import Foundation

// The rules only the carb ratio test's runner asks, kept apart from the screen's as the ISF test keeps its own
// (`ISFTestRunnerRules`): what a running check ends the test for, the steps that offer only Cancel Test, the Dose step's
// notice, and which carb entries spoil the test. Most are the ISF test's, asked with this test's phase and deadlines.

extension CarbRatioTestCarbs {
    /// The entry as the other tests' carbs rule reads it (`SettingsTestCarbRule`): which one, and when.
    var entry: SettingsTestCarbEntry { SettingsTestCarbEntry(id: id, date: date) }
}

extension CarbRatioTestEvaluator {
    // MARK: - The running check

    /// What a running test's periodic check found that ends it, as the ISF test's (`ISFTestEvaluator.runningCheck`),
    /// asked with this test's phase, its deadline for the bolus (`noBolusDeadline`: while settling, the latest a bolus
    /// window could close) and the end of its chosen length from the bolus (`plannedEnd`). First the service's record of
    /// ending its session, if dated by then; before the bolus, the time for it running out, a mode other than Basal
    /// Testing, then Trio's suspend for a low (a low before the dose) or basal stopped without Trio asking; waiting, the
    /// basal fast's rules to the planned end, with a low dated before the bolus still a low before the dose. Nil to keep
    /// going. The service's record of a meal not paired isn't the ISF test's to read: `serviceMealEnd` reads it first.
    static func runningCheck(
        of test: CarbRatioTestState,
        serviceEnd: SettingsTestEnd?,
        suspend: BasalTestEvaluator.SuspendReading,
        now: Date,
        mode: DosingMode
    ) -> ISFTestEvaluator.RunningCheck? {
        ISFTestEvaluator.runningCheck(
            phase: test.phase.isfPhase,
            sessionID: test.sessionID,
            serviceEnd: serviceEnd?.cause == .mealUnpaired ? nil : serviceEnd,
            suspend: suspend,
            now: now,
            doseDeadline: test.noBolusDeadline,
            bolusAt: test.bolusAt,
            plannedEnd: test.plannedEnd,
            mode: mode
        )
    }

    /// The check a tick acts on, as the ISF test's (`ISFTestEvaluator.decidable`): on a tick whose boluses couldn't be
    /// read, no bolus can't be told from one not seen yet, nor a low before the dose from one after it, so those wait for
    /// a tick that reads them. The others end the test whether or not the bolus came.
    static func decidable(_ check: ISFTestEvaluator.RunningCheck?, bolusesRead: Bool) -> ISFTestEvaluator.RunningCheck? {
        ISFTestEvaluator.decidable(check, bolusesRead: bolusesRead)
    }

    // MARK: - Dead ends

    /// The sentence the Settle step shows once its time is up with no way on but Cancel Test, the ISF test's
    /// (`ISFTestEvaluator.deadEndSentence`): no loop in Basal Testing, too few readings since it, or a temp basal still
    /// running. Nil for any other decision, the time-up question among them.
    static func settlingDeadEnd(_ settling: ISFTestSettling) -> String? {
        ISFTestEvaluator.deadEndSentence(settling: settling)
    }

    /// The sentence of a Dose step that offers only Cancel Test, which the runner ends the test with: a reason it shows no
    /// dose for that no later check can change (`CarbRatioTestNoDose.isWaiting`), so only missing settings. Carbs and
    /// insulin on board only come down while the test runs, Count It's insulin covering the dose among them, so the step
    /// waits for those, up to the dose deadline. Nil while it offers the dose or waits, and on any other step.
    static func doseDeadEnd(of test: CarbRatioTestState, _ inputs: CarbRatioTestDoseInputs) -> String? {
        guard test.phase == .dosing, let noDose = noDoseReason(of: test, inputs), !noDose.isWaiting else { return nil }
        return noDose.sentence
    }

    // MARK: - The meal's two halves

    /// How a test ends whose meal's halves, the tablets' carbs (`carbsAt`) and the bolus (`bolusAt`), didn't come within
    /// `CarbRatioTest.Config.mealPairing` of each other, whichever came first: at once, with no verdict, dated at the end
    /// of the pairing time from the first, so the usual dosing comes back. Carbs with no bolus are carbs Basal Testing
    /// gives no insulin for (`carbsWithoutBolusNote`); a bolus with no carbs is insulin Trio's forecast sees alone, and
    /// the user is told to log the carbs (`bolusWithoutCarbsNote`). A second half that came after the pairing time is the
    /// same ending. Nil while the second half can still come, and once both came in time. `now` is when the halves were
    /// read: a half not seen by then hadn't come.
    static func mealPairingEnd(carbsAt: Date?, bolusAt: Date?, now: Date) -> Ending? {
        let pairing = CarbRatioTest.Config.mealPairing
        switch (carbsAt, bolusAt) {
        case (nil, nil):
            return nil
        case let (carbsAt?, nil):
            let deadline = carbsAt.addingTimeInterval(pairing)
            return now >= deadline ? Ending(reason: .interrupted, at: deadline, note: carbsWithoutBolusNote) : nil
        case let (nil, bolusAt?):
            let deadline = bolusAt.addingTimeInterval(pairing)
            return now >= deadline ? Ending(reason: .interrupted, at: deadline, note: bolusWithoutCarbsNote) : nil
        case let (carbsAt?, bolusAt?):
            let first = min(carbsAt, bolusAt)
            let deadline = first.addingTimeInterval(pairing)
            // Dates saved in the test's state, so the second half at the same moment as the deadline is in time.
            guard ISFTestEvaluator.isAfter(max(carbsAt, bolusAt), deadline) else { return nil }
            return Ending(
                reason: .interrupted,
                at: deadline,
                note: carbsAt <= bolusAt ? carbsWithoutBolusNote : bolusWithoutCarbsNote
            )
        }
    }

    /// The test's ending for the service's record of ending its session for a meal not paired
    /// (`SettingsTestEndCause.mealUnpaired`), dated as the service dated it, if dated by the test's limit (the planned
    /// end, or the bolus deadline before the bolus). Its words come from the half the test saw: carbs with no bolus, a
    /// bolus with no carbs, or, when it saw neither, `mealUnpairedNote`. Nil for any other record, and another session's.
    static func serviceMealEnd(of test: CarbRatioTestState, serviceEnd: SettingsTestEnd?) -> Ending? {
        guard let serviceEnd, serviceEnd.cause == .mealUnpaired, let sessionID = test.sessionID,
              serviceEnd.sessionID == sessionID,
              !ISFTestEvaluator.isAfter(serviceEnd.date, test.plannedEnd ?? test.noBolusDeadline)
        else { return nil }
        let note: String
        switch (test.carbsAt, test.bolusAt) {
        case let (carbsAt?, bolusAt?): note = carbsAt <= bolusAt ? carbsWithoutBolusNote : bolusWithoutCarbsNote
        case (.some, nil): note = carbsWithoutBolusNote
        case (nil, .some): note = bolusWithoutCarbsNote
        case (nil, nil): note = mealUnpairedNote
        }
        return Ending(reason: .interrupted, at: serviceEnd.date, note: note)
    }

    // MARK: - The Dose step's notice

    /// What an owed "Carb Ratio Dose Ready" does as the Dose step is now: it goes once the step offers the dose
    /// (`canDose`: Open Treatments on), since it promises a dose that can be given, and nothing is owed after it.
    /// Otherwise nothing goes, and it stays owed, since what holds the dose back (a reading, the arrow, insulin or carbs
    /// on board) can change by itself. Nothing owed, nothing goes.
    static func doseNotice(due: Bool?, canDose: Bool) -> (post: CarbRatioTestStepNotice?, due: Bool?) {
        guard due == true else { return (nil, nil) }
        return canDose ? (.settledToDose, nil) : (nil, true)
    }

    // MARK: - Carbs that spoil the test

    /// Whether carb entries spoil a running test begun at `startedAt`, by the rule the other tests use
    /// (`SettingsTestCarbRule.spoil`: any dated from Begin on, and any dated in the day before it that wasn't there at
    /// Begin, `kept`), with the test's own entry let through: the one saved (`savedID`), or before one is, the one
    /// `mealCarbs` takes, the first dated from the bolus window's start (`windowStart`). Whether it came close enough to
    /// the bolus is `mealPairingEnd`'s to say. While settling (`windowStart` nil) none is let through. What the service's
    /// watchdog and the runner both ask, so both let the same entry through.
    static func carbsSpoil(
        _ entries: [SettingsTestCarbEntry],
        startedAt: Date,
        kept: [String]?,
        windowStart: Date?,
        savedID: String? = nil
    ) -> Bool {
        // The pick and the rule go by ID and date alone, so entries read without grams stand in with none.
        let carbs = entries.map { CarbRatioTestCarbs(id: $0.id, date: $0.date, grams: 0) }
        let testID = savedID ?? windowStart.flatMap { mealCarbs(carbs, since: $0)?.id }
        return extraCarbs(carbs, besides: testID, startedAt: startedAt, kept: kept)
    }
}
