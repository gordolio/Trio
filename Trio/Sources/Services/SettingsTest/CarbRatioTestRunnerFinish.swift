import Foundation

extension CarbRatioTestRunner {
    // MARK: - The user's endings

    /// End Test: ending early gives no result, and the user, who ended it, is told nothing.
    func endEarly() async {
        await finish(reason: .endedEarly, byUser: true)
    }

    /// Cancel Test, before the bolus: the usual mode comes back and nothing is kept. Not for a finished test, whose result
    /// only Done clears. With no test at all, a carb ratio session left running still ends, so its mode comes back.
    @MainActor func discard() {
        guard state.test?.phase != .finished else { return }
        if let test = state.test {
            endSession(of: test)
        } else {
            service?.end(kind: .carbRatio)
        }
        storage.remove(CarbRatioTest.Config.statePath)
        subject.send(CarbRatioTestRunnerState())
        notifier.withdraw(.carbRatio, .step)
        notifier.withdrawLegacy()
    }

    /// Done: clears a finished result so the user can start over, and its notice, which would open the cleared result.
    /// Only a finished one: a running test is ended first.
    @MainActor func acknowledgeResult() {
        guard state.test?.phase == .finished else { return }
        storage.remove(CarbRatioTest.Config.statePath)
        subject.send(CarbRatioTestRunnerState())
        notifier.withdraw(.carbRatio, .ended)
        notifier.withdrawLegacy()
    }

    // MARK: - Finish

    /// Ends the test's session, so the service puts the usual mode back, on the main actor, where the service changes the
    /// mode. When the session is lost (no session runs and the service kept no end of it) with Basal Testing still on, the
    /// runner puts the mode Begin saved back itself (`SettingsTestModeRule.modeToRestore`); otherwise nothing it doesn't
    /// own is changed.
    @MainActor func endSession(of test: CarbRatioTestState) {
        guard let service else { return }
        let restore = SettingsTestModeRule.modeToRestore(
            mode: settingsManager.settings.dosingMode,
            testSessionID: test.sessionID,
            activeSessionID: service.activeSession?.id,
            lastEndSessionID: service.lastEnd()?.sessionID,
            previousMode: test.previousMode
        )
        service.end(kind: .carbRatio)
        if let restore {
            debug(.settings, "CarbRatioTestRunner: the test's session was lost, restoring \(restore.rawValue) itself")
            settingsManager.settings.dosingMode = restore
        }
    }

    /// Claims the test for one finish, on the main actor, where Cancel Test and Begin run, so the claim and the saves are
    /// ordered with them. The ending is the one saved (`pendingEnd`) if there is one, whatever this finish was asked for;
    /// otherwise this one, with its end time worked out now, saved before anything else. Nil when the test has finished,
    /// another finish holds it, or it isn't `testID`.
    @MainActor func claimFinish(
        for testID: UUID?,
        reason: CarbRatioTestEndReason,
        at endedAt: Date?,
        note: String?,
        byUser: Bool
    ) -> (test: CarbRatioTestState, ending: CarbRatioTestPendingEnd)? {
        guard var current = state.test, current.phase != .finished, !isFinishing, testID == nil || current.id == testID
        else { return nil }
        isFinishing = true
        if let saved = current.pendingEnd { return (current, saved) }
        // Fixed before normal dosing comes back, so nothing the usual mode does next falls inside the test.
        let ending = CarbRatioTestPendingEnd(
            reason: reason,
            at: SettingsTestEndRule.endTime(endedAt: endedAt, limit: current.plannedEnd ?? current.noBolusDeadline, now: Date()),
            note: note,
            byUser: byUser
        )
        current.pendingEnd = ending
        save(current)
        return (current, ending)
    }

    /// `endedAt` is when a low ended the test, or when the service ended it; without it the test ends now, or at the
    /// planned end (the dose deadline before the bolus) if that came first. `note` says what interrupted it when the
    /// records don't. `reason` is what the caller saw; the history up to the end can still make it a low or an
    /// interruption (`settle`). An ending already saved wins over all of them (`claimFinish`). With `testID`, it finishes
    /// only that test: a check that read the history for one test must not end another that was started while it waited.
    /// `byUser` is End Test, which posts nothing; any other ending posts its notice.
    func finish(
        for testID: UUID? = nil,
        reason: CarbRatioTestEndReason,
        at endedAt: Date? = nil,
        note: String? = nil,
        byUser: Bool = false
    ) async {
        // Normal dosing comes back first, in the same main-actor step as the claim and after it has saved the ending, so a
        // Cancel Test and a new Begin can't come between them and have this finish end the new test's session. The rest is
        // bookkeeping.
        let claimed = await MainActor.run { () -> (test: CarbRatioTestState, ending: CarbRatioTestPendingEnd)? in
            guard let claimed = claimFinish(for: testID, reason: reason, at: endedAt, note: note, byUser: byUser) else {
                return nil
            }
            endSession(of: claimed.test)
            return claimed
        }
        guard let claimed else { return }
        var current = claimed.test
        let decided = claimed.ending
        debug(
            .settings,
            "CarbRatioTestRunner: ending the test (\(decided.reason.rawValue)\(decided.byUser ? ", by the user" : ""))"
        )
        let endedBy = decided.at

        // The history up to the end decides how the test ended, so a suspend the periodic checks hadn't seen yet isn't
        // lost. Read once normal dosing is back, so the read never holds it up.
        let settled = await settle(current, reason: decided.reason, at: endedBy)
        var reason = settled.reason
        let end = settled.at ?? endedBy
        var note = decided.note ?? settled.note

        // What the pump delivered, read again: a bolus cut short is judged per unit delivered, one cancelled before any
        // insulin went in leaves nothing to judge, and an amount that can't be read isn't trusted.
        var bolusUnread = false
        if let bolusAt = current.bolusAt {
            switch await ISFTestEvaluator.bolusAmount(
                saved: current.bolusUnits,
                reread: rereadTestBolus(at: bolusAt),
                bolusAt: bolusAt,
                finishing: true
            ) {
            case let .units(units):
                current.bolusUnits = units
            case .cancelled:
                // Something else that interrupted the test keeps its own words.
                if reason != .interrupted {
                    let cancelled = CarbRatioTestEvaluator.ending(for: .bolusCancelled, doseDeadline: current.noBolusDeadline)
                    reason = cancelled.reason
                    note = cancelled.note
                }
            case .unread:
                bolusUnread = true
            }
            // The units given count the insulin on board at the bolus: read once more if no tick could.
            if CarbRatioTestEvaluator.iobAtBolusUnread(of: current) {
                current.iobAtBolus = await readIOB(before: bolusAt, of: current)
            }
            // A test that ran its length is judged on the insulin that acted in it: what Trio reports still on board at the
            // planned end is left out. Unread, there is no verdict.
            if reason == .completed, let plannedEnd = current.plannedEnd {
                current.iobAtEnd = await readIOB(atEnd: plannedEnd, of: current)
            }
            // Judged only with the formula's bolus, within a docs step, as the amount is now: one cut short since the last
            // check is off it the same way. Something else that interrupted the test keeps its own words.
            if reason != .interrupted, let off = CarbRatioTestEvaluator.bolusOffFormula(of: current) {
                reason = .interrupted
                note = off.note
            }
        }

        // No verdict without the meal's checks: a meal whose halves were first seen together as the test ended (a
        // relaunch after a long gap, say) is judged now, or, unpaired, ends for that. A read that fails leaves it
        // unchecked, so with no verdict.
        var mealUnchecked = false
        if reason != .interrupted, reason != .noBolus, current.mealJudgedAt == nil,
           let bolusAt = current.bolusAt, let carbsAt = current.carbsAt, let logged = current.carbs
        {
            if let unpaired = CarbRatioTestEvaluator.mealPairingEnd(carbsAt: carbsAt, bolusAt: bolusAt, now: .distantFuture) {
                reason = .interrupted
                note = unpaired.note
            } else {
                do {
                    let meal = try await readMeal(carbsAt: carbsAt, bolusAt: bolusAt)
                    current.startGlucose = current.startGlucose ?? meal.start
                    if let failed = CarbRatioTestEvaluator.failedMealCondition(
                        bolusAt: bolusAt,
                        carbsAt: carbsAt,
                        loggedCarbs: logged,
                        plannedCarbs: current.tabletCarbs,
                        startGlucose: meal.start,
                        carbRatio: current.carbRatio,
                        arrow: meal.arrow,
                        determinations: meal.determinations,
                        handling: current.iobHandling
                    ) {
                        reason = .interrupted
                        note = failed.note
                    } else {
                        current.mealJudgedAt = Date()
                    }
                } catch {
                    warning(.settings, "CarbRatioTestRunner: couldn't read what the meal is judged on as it ended", error: error)
                    mealUnchecked = true
                }
            }
        }

        // Ended after the bolus with no carb entry logged from the end of settling: its words say to log the tablets'
        // carbs if they were eaten. Never when one is in, and not when the carbs can't be read.
        if current.bolusAt != nil, current.carbs == nil, let windowStart = current.bolusWindowStart {
            do {
                let entries = try await reads.fetchCarbs(
                    from: windowStart,
                    to: Date().addingTimeInterval(CarbRatioTest.Config.savedDateTolerance)
                )
                current.carbsUnloggedAtEnd = CarbRatioTestEvaluator.mealCarbs(entries, since: windowStart) == nil ? true : nil
            } catch {
                warning(.settings, "CarbRatioTestRunner: couldn't read carbs to say whether to log them", error: error)
            }
        }

        // From the bolus, or from Begin if none came, and from a little before it for the start glucose. A little past
        // the end, which is saved to the millisecond, so a reading at the same moment as it is read.
        let anchor = current.bolusAt ?? current.startedAt
        let fetched: [BasalTestReading]
        do {
            fetched = try await reads.fetchGlucose(
                from: anchor.addingTimeInterval(-Self.startReadingsLookback),
                to: end.addingTimeInterval(CarbRatioTest.Config.savedDateTolerance)
            )
        } catch {
            warning(.settings, "CarbRatioTestRunner: couldn't read the test's glucose", error: error)
            fetched = []
        }
        // A reading at the same moment as the saved bolus counts as at it, for both, and one at the end as at it.
        let readings = ISFTestEvaluator.readings(ISFTestEvaluator.readings(fetched, since: anchor), atOrBefore: end)
        // At the meal, the earlier of the bolus and the tablets' carbs, unless the meal step read it already.
        let startGlucose = current.startGlucose ?? current.mealAt.flatMap { mealAt in
            BasalTestEvaluator.endGlucose(from: ISFTestEvaluator.readings(fetched, atOrBefore: mealAt), endingAt: mealAt)
        }
        // Where the chosen length ended, or, for a low, the glucose at Trio's suspend from readings after the meal.
        let endGlucose = CarbRatioTestEvaluator.endGlucose(
            fetched,
            bolusAt: current.bolusAt,
            carbsAt: current.carbsAt,
            end: end,
            reason: reason
        )
        let checked = await wasInterrupted(current, until: end)
        let interference: String?
        if case let .found(message) = checked {
            interference = message
        } else {
            interference = note
        }
        let interferenceUnread = checked == .unreadable || bolusUnread || mealUnchecked

        // `reason` as the finish decided it, so a test that ran its length needs the insulin left at the end read.
        current.endReason = reason
        let evaluation = CarbRatioTestEvaluator.evaluate(
            startGlucose: startGlucose,
            endGlucose: endGlucose,
            units: CarbRatioTestEvaluator.judgedUnits(of: current),
            elapsed: end.timeIntervalSince(anchor),
            length: current.length,
            reason: reason,
            interference: interference,
            interferenceUnread: interferenceUnread,
            // Insulin on board the units judged rest on couldn't be read: no units to judge by.
            iobUnread: CarbRatioTestEvaluator.iobUnread(of: current),
            // The tablets' planned grams, what was eaten, once logged; a low counts them only when logged by its suspend.
            carbs: CarbRatioTestEvaluator.judgedCarbs(
                current.carbs,
                planned: current.tabletCarbs,
                carbsAt: current.carbsAt,
                reason: reason,
                end: end
            ),
            carbRatio: current.carbRatio,
            isf: current.isf,
            // A low says the CR number is too low only at or below the start and Trio's low threshold, after no more than
            // a docs step lower's dose.
            givenUnits: CarbRatioTestEvaluator.givenUnits(of: current),
            increment: current.bolusIncrement,
            lowThreshold: current.lowThreshold ?? Preferences.basalTestingThreshold
        )

        current.phase = .finished
        current.pendingEnd = nil
        current.doseNoticeDue = nil
        current.endedAt = end
        current.endReason = reason
        current.startGlucose = startGlucose
        current.endGlucose = endGlucose
        current.readings = readings
        current.outcome = evaluation.outcome
        current.interference = interference
        current.interferenceUnread = interferenceUnread

        // Only a verdict on the carb ratio is kept. A low has one whatever the readings were, so it needs only one of them.
        var record: SettingsTestRecord?
        if evaluation.outcome.isConclusive, let direction = evaluation.direction, let bolusAt = current.bolusAt,
           let recordStart = startGlucose ?? endGlucose
        {
            record = SettingsTestRecord(
                kind: .carbRatio,
                startedAt: bolusAt,
                completedAt: end,
                timeBlock: BasalTestEvaluator.timeBlock(for: bolusAt),
                startGlucose: recordStart,
                endGlucose: endGlucose ?? recordStart,
                direction: direction,
                summary: CarbRatioTestEvaluator.summary(for: evaluation.outcome, reason: reason),
                // The carb ratio entry in force at the bolus (`CarbRatioTestEvaluator.atBolus`): the ratio counts at the
                // meal. Not narrowed again here: the calendar now, after a time zone change, would read another minute.
                coveredEntries: current.crEntries,
                bolusUnits: current.bolusUnits,
                // The tablets' planned grams; `testCarbs` are the grams logged, which match them for a verdict.
                tabletCarbs: current.tabletCarbs,
                iobHandling: current.iobHandling?.rawValue,
                // Counted whatever the handling (`CarbRatioTestEvaluator.givenUnits`).
                iobCounted: current.iobAtBolus,
                judgedUnits: CarbRatioTestEvaluator.judgedUnits(of: current),
                testCarbs: current.carbs
            )
        }

        // Kept only if it is still the test shown: a Cancel Test or a new Begin while the history was read owns the saved
        // state now. One step on the main actor, so neither can come in between.
        let ended = current
        let archived = record
        let kept: Bool = await MainActor.run {
            isFinishing = false
            notifier.withdraw(.carbRatio, .step)
            notifier.withdrawLegacy()
            guard let shown = state.test, shown.id == ended.id, shown.phase != .finished else { return false }
            // No check runs once it has finished, so what only a running test reads is cleared here.
            publish {
                $0.settling = nil
                $0.doseIOB = nil
            }
            // A note that says the usual dosing came back says so only when the mode in force now is it.
            var finished = ended
            finished.interference = CarbRatioTestEvaluator.modeWorded(
                ended.interference,
                modeBack: modeIsBack(for: ended),
                usualMode: ended.previousMode
            )
            // Read back before it is shown, archived and posted: a write that didn't last would leave the test running on
            // disk with its ending, so a relaunch would finish, archive and post it again. It stays ending instead, as
            // shown, and the next check finishes it again.
            storage.save(finished, as: CarbRatioTest.Config.statePath)
            let saved = storage.retrieve(CarbRatioTest.Config.statePath, as: CarbRatioTestState.self)
            guard saved?.id == finished.id, saved?.phase == .finished else {
                warning(.settings, "CarbRatioTestRunner: the finished test didn't save, so it stays ending until it does")
                return false
            }
            publish { $0.test = finished }
            if let archived {
                service?.archive(archived)
            }
            if !decided.byUser {
                post(endedNotice(for: finished))
            }
            return true
        }
        if kept {
            debug(.settings, "CarbRatioTestRunner: finished the test, \(evaluation.outcome.rawValue)")
        }
    }

    /// What a finished test's notice says: its result is ready when it has a verdict, otherwise the sentence its Result
    /// gives, with the usual mode being back when it is.
    @MainActor private func endedNotice(for test: CarbRatioTestState) -> SettingsTestNotice {
        if test.outcome?.isConclusive == true { return .finished(.carbRatio) }
        let sentence = CarbRatioTestEvaluator.noVerdictText(CarbRatioTestEvaluator.noVerdict(for: test), test: test)
        return .ended(
            .carbRatio,
            sentence: sentence,
            // Carbs with no bolus say the usual mode is back in their own words.
            modeBack: modeIsBack(for: test)
                && !sentence.hasPrefix(CarbRatioTestEvaluator.carbsWithoutBolusNote(modeBack: false))
        )
    }

    /// Whether the mode in force now is the usual one the test began from.
    @MainActor private func modeIsBack(for test: CarbRatioTestState) -> Bool {
        settingsManager.settings.dosingMode == test.previousMode && test.previousMode != .basalTesting
    }

    /// How the test ends, from what the pump history and Trio's determinations up to `end` say: see
    /// `CarbRatioTestEvaluator.finishing`. A reason already decided needs no read.
    private func settle(
        _ test: CarbRatioTestState,
        reason: CarbRatioTestEndReason,
        at end: Date
    ) async -> CarbRatioTestEvaluator.Ending {
        guard CarbRatioTestEvaluator.rereadsHistory(reason) else {
            return CarbRatioTestEvaluator.Ending(reason: reason, at: end, note: nil)
        }
        let suspend: BasalTestEvaluator.SuspendReading
        do {
            suspend = try await reads.fetchSuspendReading(startedAt: test.startedAt, to: end)
        } catch {
            warning(
                .settings,
                "CarbRatioTestRunner: couldn't read temp basals to check the finished test for a low",
                error: error
            )
            suspend = .unreadable
        }
        return CarbRatioTestEvaluator.finishing(
            reason: reason,
            at: end,
            suspend: suspend,
            bolusAt: test.bolusAt,
            length: test.length,
            doseDeadline: test.noBolusDeadline
        )
    }

    /// What spoiled the test, if anything: carbs other than the tablets' (`CarbRatioTestEvaluator.carbsSpoil`), the pump
    /// suspended, alarmed or changed, a bolus after the test's own, or Trio dosing, which it doesn't in Basal Testing. Each
    /// record is read on its own, so one that can't be read is logged without hiding what the others show; with nothing
    /// found, the test is left unchecked. Carbs count from Begin, and before it when they were logged since
    /// (`SettingsTestCarbRule`), with the test's own entry let through: the one saved, or before it is, the one the
    /// bolus window would take. Trio's dosing only from the end of settling, because what a loop already running at Begin
    /// gave lands while settling, in the insulin on board the test waits for or counts. A test that never settled has no
    /// dosing of Trio's to check.
    func wasInterrupted(_ test: CarbRatioTestState, until end: Date) async -> BasalTestEvaluator.Interference {
        let start = test.startedAt
        let kept = test.carbsAtBegin
        let windowStart = test.bolusWindowStart
        let bolusAt = test.bolusAt
        let carbsID = test.carbsID
        let reads = self.reads
        let dosed = String(localized: "Trio dosed during the test, so Basal Testing wasn't on the whole time.")
        return await BasalTestEvaluator.firstInterference([
            (name: "carbs", read: {
                let entries = try await reads.fetchCarbs(
                    from: SettingsTestCarbRule.readFrom(startedAt: start, kept: kept),
                    to: end
                )
                return CarbRatioTestEvaluator.carbsSpoil(
                    entries.map(\.entry),
                    startedAt: start,
                    kept: kept,
                    windowStart: windowStart,
                    savedID: carbsID
                ) ? CarbRatioTestEvaluator.otherCarbsNote : nil
            }),
            // From Begin: a suspend, an alarm, or a site or reservoir change means basal or the bolus may not have gone in
            // as recorded.
            (name: "pump events", read: {
                try await reads.fetchPumpInterruptions(from: start, to: end).isEmpty
                    ? nil
                    : ISFTestEvaluator.pumpInterruptedNote
            }),
            (name: "boluses", read: {
                // Before the bolus there is no test bolus for another to come after.
                guard let bolusAt else { return nil }
                let boluses = try await reads.fetchBoluses(from: start, to: end)
                return ISFTestEvaluator.hasExtraBolus(boluses, after: bolusAt)
                    ? String(localized: "Another bolus was given during the test.")
                    : nil
            }),
            (name: "Trio's SMBs", read: {
                guard let windowStart else { return nil }
                // The test bolus itself may be flagged as an SMB; any other bolus is the boluses read's to find.
                let smbs = try await ISFTestEvaluator.smbs(
                    reads.fetchSMBs(since: windowStart, until: end),
                    besidesTestBolusAt: bolusAt
                )
                return BasalTestEvaluator.dosedDuringFast(smbs: smbs, temps: [], since: windowStart, until: end)
                    ? dosed
                    : nil
            }),
            (name: "Trio's temp basals", read: {
                guard let windowStart else { return nil }
                let temps = try await reads.fetchTempBasals(from: windowStart, to: end)
                return BasalTestEvaluator.dosedDuringFast(smbs: [], temps: temps, since: windowStart, until: end)
                    ? dosed
                    : nil
            })
        ])
    }
}
