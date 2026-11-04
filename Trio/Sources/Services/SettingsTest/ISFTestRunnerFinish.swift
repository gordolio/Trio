import Foundation

extension ISFTestRunner {
    // MARK: - The user's endings

    /// End Test: ending early gives no result, and the user, who ended it, is told nothing.
    func endEarly() async {
        await finish(reason: .endedEarly, byUser: true)
    }

    /// Cancel Test, before the bolus: the usual mode comes back and nothing is kept. Not for a finished test, whose result
    /// only Done clears. With no test at all, an ISF session left running still ends, so its mode comes back.
    @MainActor func discard() {
        guard state.test?.phase != .finished else { return }
        if let test = state.test {
            endSession(of: test)
        } else {
            service?.end(kind: .isf)
        }
        storage.remove(ISFTest.Config.statePath)
        subject.send(ISFTestRunnerState())
        notifier.withdraw(.isf, .step)
        // A test begun before the update may have one waiting for its planned end.
        notifier.withdrawLegacy()
    }

    /// Done: clears a finished result so the user can start over, and its notice, which would open the cleared result.
    /// Only a finished one: a running test is ended first.
    @MainActor func acknowledgeResult() {
        guard state.test?.phase == .finished else { return }
        storage.remove(ISFTest.Config.statePath)
        subject.send(ISFTestRunnerState())
        notifier.withdraw(.isf, .ended)
        notifier.withdrawLegacy()
    }

    // MARK: - Finish

    /// Ends the test's session, so the service puts the usual mode back, on the main actor, where the service changes the
    /// mode. When the session is lost (no session runs and the service kept no end of it) with Basal Testing still on, the
    /// runner puts the mode Begin saved back itself (`SettingsTestModeRule.modeToRestore`); otherwise nothing it doesn't own is
    /// changed.
    @MainActor func endSession(of test: ISFTestState) {
        guard let service else { return }
        let restore = SettingsTestModeRule.modeToRestore(
            mode: settingsManager.settings.dosingMode,
            testSessionID: test.sessionID,
            activeSessionID: service.activeSession?.id,
            lastEndSessionID: service.lastEnd()?.sessionID,
            previousMode: test.previousMode
        )
        service.end(kind: .isf)
        if let restore {
            debug(.settings, "ISFTestRunner: the test's session was lost, restoring \(restore.rawValue) itself")
            settingsManager.settings.dosingMode = restore
        }
    }

    /// Claims the test for one finish, on the main actor, where Cancel Test and Begin run, so the claim and the saves are
    /// ordered with them. The ending is the one saved (`pendingEnd`) if there is one, whatever this finish was asked for;
    /// otherwise this one, with its end time worked out now, saved before anything else. Nil when the test has finished,
    /// another finish holds it, or it isn't `testID`.
    @MainActor func claimFinish(
        for testID: UUID?,
        reason: ISFTestEndReason,
        at endedAt: Date?,
        note: String?,
        byUser: Bool
    ) -> (test: ISFTestState, ending: ISFTestPendingEnd)? {
        guard var current = state.test, current.phase != .finished, !isFinishing, testID == nil || current.id == testID
        else { return nil }
        isFinishing = true
        if let saved = current.pendingEnd { return (current, saved) }
        // Fixed before normal dosing comes back, so nothing the usual mode does next falls inside the test.
        let ending = ISFTestPendingEnd(
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
        reason: ISFTestEndReason,
        at endedAt: Date? = nil,
        note: String? = nil,
        byUser: Bool = false
    ) async {
        // Normal dosing comes back first, in the same main-actor step as the claim and after it has saved the ending, so a
        // Cancel Test and a new Begin can't come between them and have this finish end the new test's session. The rest is
        // bookkeeping.
        let claimed = await MainActor.run { () -> (test: ISFTestState, ending: ISFTestPendingEnd)? in
            guard let claimed = claimFinish(for: testID, reason: reason, at: endedAt, note: note, byUser: byUser) else {
                return nil
            }
            endSession(of: claimed.test)
            return claimed
        }
        guard let claimed else { return }
        var current = claimed.test
        let decided = claimed.ending
        debug(.settings, "ISFTestRunner: ending the test (\(decided.reason.rawValue)\(decided.byUser ? ", by the user" : ""))")
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
                    let cancelled = ISFTestEvaluator.ending(for: .bolusCancelled, doseDeadline: current.noBolusDeadline)
                    reason = cancelled.reason
                    note = cancelled.note
                }
            case .unread:
                bolusUnread = true
            }
            // Counting insulin on board needs it at the bolus, read once more if no tick could.
            if ISFTestEvaluator.iobAtBolusUnread(of: current) {
                current.iobAtBolus = await readIOB(before: bolusAt, of: current)
            }
            // A test that ran its 4 hours is judged on the insulin that acted in them: what Trio reports still on board at
            // the planned end is left out. Unread, there is no verdict.
            if reason == .completed, let plannedEnd = current.plannedEnd {
                current.iobAtEnd = await readIOB(atEnd: plannedEnd, of: current)
            }
        }

        // From the bolus, or from Start if none came, and from a little before it for the start glucose. A little past
        // the end, which is saved to the millisecond, so a reading at the same moment as it is read.
        let anchor = current.bolusAt ?? current.startedAt
        let fetched: [BasalTestReading]
        do {
            fetched = try await reads.fetchGlucose(
                from: anchor.addingTimeInterval(-Self.startReadingsLookback),
                to: end.addingTimeInterval(ISFTest.Config.savedDateTolerance)
            )
        } catch {
            warning(.settings, "ISFTestRunner: couldn't read the test's glucose", error: error)
            fetched = []
        }
        // A reading at the same moment as the saved bolus counts as at it, for both, and one at the end as at it.
        let readings = ISFTestEvaluator.readings(ISFTestEvaluator.readings(fetched, since: anchor), atOrBefore: end)
        let startGlucose = current.startGlucose ?? current.bolusAt.flatMap { bolusAt in
            BasalTestEvaluator.endGlucose(from: ISFTestEvaluator.readings(fetched, atOrBefore: bolusAt), endingAt: bolusAt)
        }
        // Where the 4 hours ended, or, for a low, the glucose at Trio's suspend.
        let endGlucose = ISFTestEvaluator.endGlucose(fetched, bolusAt: current.bolusAt, end: end, reason: reason)
        let checked = await wasInterrupted(current, until: end)
        let interference: String?
        if case let .found(message) = checked {
            interference = message
        } else {
            interference = note
        }
        let interferenceUnread = checked == .unreadable || bolusUnread

        // `reason` as the finish decided it, so a test that ran its 4 hours needs the insulin left at the end read.
        current.endReason = reason
        let evaluation = ISFTestEvaluator.evaluate(
            startGlucose: startGlucose,
            endGlucose: endGlucose,
            units: ISFTestEvaluator.judgedUnits(of: current),
            elapsed: end.timeIntervalSince(anchor),
            reason: reason,
            interference: interference,
            interferenceUnread: interferenceUnread,
            // Insulin on board the units judged rest on couldn't be read: no units to judge by.
            iobUnread: ISFTestEvaluator.iobUnread(of: current),
            isf: current.isf,
            // A low says the ISF number is too low only at or below the target, after no more than the docs' dose.
            target: current.target,
            givenUnits: ISFTestEvaluator.givenUnits(of: current),
            increment: current.bolusIncrement ?? 0
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

        // Only a verdict on the ISF is kept. A low has one whatever the readings were, so it needs only one of them.
        var record: SettingsTestRecord?
        if evaluation.outcome.isConclusive, let direction = evaluation.direction, let bolusAt = current.bolusAt,
           let recordStart = startGlucose ?? endGlucose
        {
            record = SettingsTestRecord(
                kind: .isf,
                startedAt: bolusAt,
                completedAt: end,
                timeBlock: BasalTestEvaluator.timeBlock(for: bolusAt),
                startGlucose: recordStart,
                endGlucose: endGlucose ?? recordStart,
                direction: direction,
                summary: ISFTestEvaluator.summary(
                    for: evaluation.outcome,
                    reason: reason,
                    startGlucose: startGlucose,
                    endGlucose: endGlucose
                ),
                // Only what the hours it ran covered, so a test ended by a low doesn't vouch for the rest.
                coveredEntries: ISFTestEvaluator.coveredEntries(current.coveredEntries ?? [], from: bolusAt, to: end),
                bolusUnits: current.bolusUnits,
                tabletCarbs: current.tabletCarbs,
                iobHandling: current.iobHandling?.rawValue,
                iobCounted: current.iobHandling == .count ? current.iobAtBolus : nil,
                judgedUnits: ISFTestEvaluator.judgedUnits(of: current)
            )
        }

        // Kept only if it is still the test shown: a Cancel Test or a new Begin while the history was read owns the saved
        // state now. One step on the main actor, so neither can come in between.
        let finished = current
        let archived = record
        let kept: Bool = await MainActor.run {
            isFinishing = false
            notifier.withdraw(.isf, .step)
            // Whether or not anything is posted: a test begun before the update may have one waiting for its planned end.
            notifier.withdrawLegacy()
            guard let shown = state.test, shown.id == finished.id, shown.phase != .finished else { return false }
            // No check runs once it has finished, so what only a running test reads is cleared here.
            publish {
                $0.settling = nil
                $0.doseIOB = nil
            }
            save(finished)
            if let archived {
                service?.archive(archived)
            }
            if !decided.byUser {
                post(endedNotice(for: finished))
            }
            return true
        }
        if kept {
            debug(.settings, "ISFTestRunner: finished the test, \(evaluation.outcome.rawValue)")
        }
    }

    /// What a finished test's notice says: its result is ready when it has a verdict, otherwise the sentence its Result
    /// gives, with the usual mode being back when it is.
    @MainActor private func endedNotice(for test: ISFTestState) -> SettingsTestNotice {
        if test.outcome?.isConclusive == true { return .finished(.isf) }
        let mode = settingsManager.settings.dosingMode
        return .ended(
            .isf,
            sentence: ISFTestEvaluator.noVerdictText(ISFTestEvaluator.noVerdict(for: test), test: test),
            modeBack: mode == test.previousMode && test.previousMode != .basalTesting
        )
    }

    /// How the test ends, from what the pump history and Trio's determinations up to `end` say: see
    /// `ISFTestEvaluator.finishing`. A reason already decided needs no read.
    private func settle(
        _ test: ISFTestState,
        reason: ISFTestEndReason,
        at end: Date
    ) async -> ISFTestEvaluator.Ending {
        guard ISFTestEvaluator.rereadsHistory(reason) else {
            return ISFTestEvaluator.Ending(reason: reason, at: end, note: nil)
        }
        let suspend: BasalTestEvaluator.SuspendReading
        do {
            suspend = try await reads.fetchSuspendReading(startedAt: test.startedAt, to: end)
        } catch {
            warning(.settings, "ISFTestRunner: couldn't read temp basals to check the finished test for a low", error: error)
            suspend = .unreadable
        }
        return ISFTestEvaluator.finishing(
            reason: reason,
            at: end,
            suspend: suspend,
            bolusAt: test.bolusAt,
            doseDeadline: test.noBolusDeadline
        )
    }

    /// What spoiled the test, if anything: carbs, the pump suspended, alarmed or changed, a bolus after the test's own, or
    /// Trio dosing, which it doesn't in Basal Testing. Each record is read on its own, so one that can't be read is logged
    /// without hiding what the others show; with nothing found, the test is left unchecked. Trio's SMBs and its temp
    /// basals are read apart, so one that can't be read doesn't hide what the other shows. Carbs count from Begin; Trio's
    /// dosing only from the end of settling, because what a loop already running at Begin gave lands while settling, in
    /// the insulin on board the test waits for or counts. A test that never settled has no dosing of Trio's to check.
    func wasInterrupted(_ test: ISFTestState, until end: Date) async -> BasalTestEvaluator.Interference {
        let start = test.startedAt
        let windowStart = test.bolusWindowStart
        let bolusAt = test.bolusAt
        let reads = self.reads
        let dosed = String(localized: "Trio dosed during the test, so Basal Testing wasn't on the whole time.")
        return await BasalTestEvaluator.firstInterference([
            (name: "carbs", read: {
                try await reads.hasCarbEntries(from: start, to: end)
                    ? String(localized: "Carbs were logged during the test.")
                    : nil
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
