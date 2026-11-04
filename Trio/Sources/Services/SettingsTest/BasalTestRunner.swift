import Combine
import Foundation

// What the basal test's runner and its screen share: the reads, what Begin starts from, and the actions the screen passes
// on (`BasalTestRunner`).

/// What the basal test reads, by its screen and by its runner with the screen closed. `BasalTest.Provider` conforms, so each
/// read has one implementation.
protocol BasalTestReads: AnyObject {
    func basalEntries() -> [SettingsTestScheduleEntry]
    func isf(at date: Date) -> Decimal?
    func fetchGlucose(from start: Date, to end: Date) async throws -> [BasalTestReading]
    func fetchSuspendReading(from start: Date, to end: Date) async throws -> BasalTestEvaluator.SuspendReading
    func fetchCarbEntries(from start: Date, to end: Date) async throws -> [SettingsTestCarbEntry]
    func fetchPumpInterruptions(from start: Date, to end: Date) async throws -> [Date]
    func hasManualBolus(from start: Date, to end: Date) async throws -> Bool
    func fetchSMBs(since start: Date, until end: Date) async throws -> [BasalTestSMB]
    func fetchTempBasals(from start: Date, to end: Date) async throws -> [BasalTestTempBasal]
}

/// What Begin starts the fast from, as the Check step read it.
struct BasalTestBegin: Equatable {
    /// Glucose at Begin, in mg/dL.
    var glucose: Int
    /// Insulin on board at Begin.
    var iob: Decimal
    /// The hours the user picked for the fast.
    var hours: Int
}

/// What the basal screen asks of its runner.
protocol BasalTestRunning: AnyObject {
    /// The fast in progress or just finished, as saved. Nil with none.
    var state: BasalTestState? { get }
    var statePublisher: AnyPublisher<BasalTestState?, Never> { get }
    @MainActor func begin(_ begin: BasalTestBegin) async -> SettingsTestBeginError?
    /// End Now.
    func endEarly() async
    /// Discard.
    @MainActor func discard()
    /// Done.
    @MainActor func acknowledgeResult()
    func check() async
}

extension SettingsTestService {
    /// The basal test's runner, while the service has one.
    var basalRunner: BasalTestRunning? { runner(for: .basal) as? BasalTestRunning }
}

/// Runs the basal test from Begin to its prepared result in `SettingsTestService`, with nothing waiting for its screen: the
/// checks while the fast runs, the ending, the archive, the mode restore and the notices. It owns
/// `trio/basal_test_state.json`; every change is saved on the main actor (`save`) and published.
final class BasalTestRunner: SettingsTestRunner, BasalTestRunning {
    let kind: SettingsTestKind = .basal
    private weak var service: SettingsTestService?
    private let reads: BasalTestReads
    private let storage: FileStorage
    private let settingsManager: SettingsManager
    private let notifier: SettingsTestNotifying

    /// Sent on the main actor only (`save`, `discard`, `acknowledgeResult`, `begin`); read anywhere.
    private let subject: CurrentValueSubject<BasalTestState?, Never>
    /// Whether a finish has claimed the fast (`claimFinish`), so no check or other ending moves it meanwhile. Main actor
    /// only.
    private var isFinishing = false

    /// One check at a time (`check()`).
    let checks = SettingsTestCheckCoalescer()

    /// `service` is held weak: it holds the runner.
    init(
        service: SettingsTestService,
        reads: BasalTestReads,
        storage: FileStorage,
        settingsManager: SettingsManager,
        notifier: SettingsTestNotifying
    ) {
        self.service = service
        self.reads = reads
        self.storage = storage
        self.settingsManager = settingsManager
        self.notifier = notifier
        subject = CurrentValueSubject(storage.retrieve(BasalTest.Config.statePath, as: BasalTestState.self))
    }

    var state: BasalTestState? { subject.value }
    var statePublisher: AnyPublisher<BasalTestState?, Never> { subject.eraseToAnyPublisher() }

    var isRunning: Bool { state?.phase == .running }

    /// Writes the fast and publishes it.
    @MainActor func save(_ test: BasalTestState) {
        storage.save(test, as: BasalTest.Config.statePath)
        subject.send(test)
    }

    private func post(_ notice: SettingsTestNotice) {
        debug(.settings, "BasalTestRunner: posting the \(notice.identifier) notice, \"\(notice.title)\"")
        notifier.post(notice)
    }

    // MARK: - Begin

    /// Why Begin is refused now, or nil: another test runs, this one included (a fast whose session was lost would
    /// otherwise hand the new one Basal Testing as its usual mode), or Basal Testing is on (kept as the usual mode,
    /// nothing would ever turn it off).
    @MainActor private func beginRefusal() -> SettingsTestBeginError? {
        guard !isRunning, service?.activeSession == nil else { return .otherTestRunning }
        guard settingsManager.settings.dosingMode != .basalTesting else { return .basalTestingOn }
        return nil
    }

    /// Saves the fast from the settings in force now, with the carb entries there now (`SettingsTestCarbRule`), starts
    /// its session and switches to Basal Testing. Refused, changing nothing, for `beginRefusal`, when those entries can't
    /// be read, and when the fast or its session didn't save: read back before the mode changes, so a relaunch always
    /// finds the way back. A new fast withdraws the last one's ended notice.
    @MainActor func begin(_ begin: BasalTestBegin) async -> SettingsTestBeginError? {
        if let refusal = beginRefusal() { return refusal }
        let now = Date()
        let carbsAtBegin: [String]
        do {
            carbsAtBegin = SettingsTestCarbRule.keptAtBegin(
                try await reads.fetchCarbEntries(from: now.addingTimeInterval(-SettingsTestCarbRule.lookback), to: now)
            )
        } catch {
            warning(.settings, "BasalTestRunner: couldn't read the carb entries there at Start", error: error)
            return .dataUnreadable(error.localizedDescription)
        }
        // The read took time.
        if let refusal = beginRefusal() { return refusal }
        let duration = TimeInterval(begin.hours) * 3600
        let previous = settingsManager.settings.dosingMode
        // What the test runs on, kept so the result and a later check of the schedule don't depend on what the settings say
        // by then.
        let snapshot = BasalTestEvaluator.snapshot(of: reads.basalEntries(), startingAt: now, for: duration)
        var test = BasalTestState(
            startedAt: now,
            plannedDuration: duration,
            startGlucose: begin.glucose,
            startIOB: begin.iob,
            previousMode: previous,
            timeBlock: BasalTestEvaluator.timeBlock(for: now),
            isf: reads.isf(at: now),
            scheduledBasal: snapshot.scheduledBasal,
            coveredEntries: snapshot.covered
        )
        test.carbsAtBegin = carbsAtBegin
        let prior = subject.value

        // Saved first, so a crash from here on leaves a fast that can be finished: one that never reached Basal Testing
        // ends as interrupted.
        save(test)
        // Register the way back before changing anything, so an interruption can't leave the user in Basal Testing with
        // nobody watching it.
        guard let service, let session = service.begin(
            kind: .basal,
            expiresIn: duration + BasalTest.Config.expiryGrace,
            restoring: [.dosingMode(testMode: .basalTesting, previous: previous)],
            settles: false,
            carbsAtBegin: carbsAtBegin
        ) else {
            putBack(prior)
            return .otherTestRunning
        }
        // Saved again with its session, before the mode changes, so the service's record of ending it for a low or for
        // carbs can be matched to this fast.
        test.sessionID = session.id
        save(test)
        // Both read back before the mode changes: a write that didn't last would leave a relaunch in Basal Testing with
        // no session, or with a fast that can't be matched to one.
        let savedTest = storage.retrieve(BasalTest.Config.statePath, as: BasalTestState.self)
        guard savedTest?.id == test.id, savedTest?.sessionID == session.id, service.savedSession()?.id == session.id else {
            warning(.settings, "BasalTestRunner: the fast or its session didn't save, so it doesn't begin")
            service.end(kind: .basal)
            putBack(prior)
            return .notSaved
        }
        settingsManager.settings.dosingMode = .basalTesting
        // The notice of the fast before would open this one.
        notifier.withdraw(.basal, .ended)
        debug(.settings, "BasalTestRunner: began the fast, \(begin.hours) h")
        return nil
    }

    /// What was there before a Begin that didn't go ahead stays.
    @MainActor private func putBack(_ prior: BasalTestState?) {
        if let prior {
            storage.save(prior, as: BasalTest.Config.statePath)
        } else {
            storage.remove(BasalTest.Config.statePath)
        }
        subject.send(prior)
    }

    // MARK: - Running

    /// Coalesced (`SettingsTestCheckCoalescer`): one runs at a time, and a call during one waits for it and for one more
    /// run, shared by every call made meanwhile, so a change that came in after the reads started is never missed.
    func check() async {
        await checks.run { await checkRunningTest() }
    }

    /// The fast as it is now, unless it has finished or a finish has claimed it.
    private func runningTest() async -> BasalTestState? {
        await MainActor.run {
            guard let test = state, test.phase == .running, !isFinishing else { return nil }
            return test
        }
    }

    /// Ends the fast if the service ended it for a low or for carbs, Trio suspended insulin for a low, its time is up, the
    /// dosing mode was changed, or something spoiled it.
    private func checkRunningTest() async {
        guard let test = await runningTest() else { return }
        // An ending decided before Trio was closed is finished for that ending, never another.
        if let pending = test.pendingEnd {
            await finish(for: test.id, reason: pending.reason)
            return
        }
        // What the check finishes below is this fast, and only this one: the reads in between give the user time to discard
        // it and start another, which this check knows nothing about.
        let testID = test.id

        let now = Date()
        // Only the fast itself: a zero temp after the planned end isn't this test's low.
        let end = min(now, test.plannedEnd)
        let suspend: BasalTestEvaluator.SuspendReading
        do {
            suspend = try await reads.fetchSuspendReading(from: test.startedAt, to: end)
        } catch {
            // Without them a low can't be told from a fast that ran its course. Before the planned end nothing is decided
            // on them this time; at it, the fast still ends, without a verdict.
            warning(.settings, "BasalTestRunner: couldn't read temp basals to check for a low", error: error)
            suspend = .unreadable
        }

        // Read together on the main actor, where the service keeps its record before it brings the usual mode back, so a
        // mode changed by the service is never seen without the reason.
        let (mode, serviceEnd) = await MainActor.run { (settingsManager.settings.dosingMode, service?.lastEnd()) }
        if let check = BasalTestEvaluator.runningCheck(
            sessionID: test.sessionID,
            serviceEnd: serviceEnd,
            suspend: suspend,
            now: now,
            plannedEnd: test.plannedEnd,
            mode: mode
        ) {
            let ending = BasalTestEvaluator.ending(for: check)
            await finish(for: testID, reason: ending.reason, at: ending.at, note: ending.note)
        } else if case .found = await wasInterrupted(test, until: now) {
            await finish(for: testID, reason: .interrupted)
        }
    }

    // MARK: - The user's endings

    /// End Now: ending early gives a result only if the fast ran its hours, and the user, who ended it, is told nothing.
    func endEarly() async {
        await finish(reason: .endedEarly, byUser: true)
    }

    /// Discard: the usual mode comes back and nothing is kept. Not for a finished fast, whose result only Done clears. With
    /// no fast at all, a basal session left running still ends, so its mode comes back.
    @MainActor func discard() {
        guard state?.phase != .finished else { return }
        endSession(of: state)
        storage.remove(BasalTest.Config.statePath)
        subject.send(nil)
        // A fast begun before the update may have a notification waiting for its planned end.
        notifier.withdrawLegacy()
    }

    /// Done: clears a finished result so the user can start over, and its notice, which would open the cleared result.
    /// Only a finished one: a running fast is ended first.
    @MainActor func acknowledgeResult() {
        guard state?.phase == .finished else { return }
        storage.remove(BasalTest.Config.statePath)
        subject.send(nil)
        notifier.withdraw(.basal, .ended)
        notifier.withdrawLegacy()
    }

    // MARK: - Finish

    /// Ends the fast's session, so the service puts the usual mode back, on the main actor, where the service changes the
    /// mode. With no fast, a basal session left running still ends. When the session is lost (no session runs and the
    /// service kept no end of it) with Basal Testing still on, the runner puts the mode Begin saved back itself
    /// (`SettingsTestModeRule.modeToRestore`); otherwise nothing it doesn't own is changed.
    @MainActor private func endSession(of test: BasalTestState?) {
        guard let service else { return }
        let restore = test.flatMap { test in
            SettingsTestModeRule.modeToRestore(
                mode: settingsManager.settings.dosingMode,
                testSessionID: test.sessionID,
                activeSessionID: service.activeSession?.id,
                lastEndSessionID: service.lastEnd()?.sessionID,
                previousMode: test.previousMode
            )
        }
        service.end(kind: .basal)
        if let restore {
            debug(.settings, "BasalTestRunner: the fast's session was lost, restoring \(restore.rawValue) itself")
            settingsManager.settings.dosingMode = restore
        }
    }

    /// Claims the fast for one finish, on the main actor, where Discard and Begin run, so the claim and the saves are
    /// ordered with them. The ending is the one saved (`pendingEnd`) if there is one, whatever this finish was asked for;
    /// otherwise this one, with its end time worked out now, saved before anything else. Nil when the fast has finished,
    /// another finish holds it, or it isn't `testID`.
    @MainActor private func claimFinish(
        for testID: UUID?,
        reason: BasalTestEndReason,
        at endedAt: Date?,
        note: String?,
        byUser: Bool
    ) -> (test: BasalTestState, ending: BasalTestPendingEnd)? {
        guard var current = state, current.phase == .running, !isFinishing, testID == nil || current.id == testID
        else { return nil }
        isFinishing = true
        if let saved = current.pendingEnd { return (current, saved) }
        // Fixed before normal dosing comes back, so nothing the usual mode does next falls inside the fast. A fast that ran
        // out while the app was closed covers only its planned window, and a low only up to the suspend.
        let ending = BasalTestPendingEnd(
            reason: reason,
            at: SettingsTestEndRule.endTime(endedAt: endedAt, limit: current.plannedEnd, now: Date()),
            note: note,
            byUser: byUser
        )
        current.pendingEnd = ending
        save(current)
        return (current, ending)
    }

    /// `endedAt` is when a low ended the fast, when basal was stopped in a way Trio can't put down to a low, or when the
    /// service ended it for carbs; without it the fast ends now, or at the planned end if that came first. `note` says what
    /// interrupted it when the records don't. `reason` is what the caller saw; the history up to the end can still make it
    /// a low or an interruption (`settle`). An ending already saved wins over all of them (`claimFinish`). With `testID`,
    /// it finishes only that fast: a check that read the history for one fast must not end another that was started while
    /// it waited. `byUser` is End Now, which posts nothing; any other ending posts its notice.
    private func finish(
        for testID: UUID? = nil,
        reason: BasalTestEndReason,
        at endedAt: Date? = nil,
        note: String? = nil,
        byUser: Bool = false
    ) async {
        // Normal dosing comes back first, in the same main-actor step as the claim and after it has saved the ending, so a
        // Discard and a new Begin can't come between them and have this finish end the new fast's session. The rest is
        // bookkeeping.
        let claimed = await MainActor.run { () -> (test: BasalTestState, ending: BasalTestPendingEnd)? in
            guard let claimed = claimFinish(for: testID, reason: reason, at: endedAt, note: note, byUser: byUser) else {
                return nil
            }
            endSession(of: claimed.test)
            return claimed
        }
        guard let claimed else { return }
        var current = claimed.test
        let decided = claimed.ending
        debug(.settings, "BasalTestRunner: ending the fast (\(decided.reason.rawValue)\(decided.byUser ? ", by the user" : ""))")

        // The history up to the end decides how the fast ends, so a low the periodic checks hadn't seen yet isn't lost.
        // Read once normal dosing is back, so the read never holds it up.
        let settled = await settle(current, reason: decided.reason, at: decided.at)
        let reason = settled.reason
        let end = settled.end
        let note = decided.note ?? settled.note

        let readings: [BasalTestReading]
        do {
            readings = try await reads.fetchGlucose(from: current.startedAt, to: end)
        } catch {
            warning(.settings, "BasalTestRunner: couldn't read the fast's glucose", error: error)
            readings = []
        }
        let endGlucose = BasalTestEvaluator.endGlucose(from: readings, endingAt: end)
        let checked = await wasInterrupted(current, until: end)
        let interference: String?
        if case let .found(message) = checked {
            interference = message
        } else {
            interference = note
        }
        let interferenceUnread = checked == .unreadable

        let evaluation = BasalTestEvaluator.evaluate(
            startGlucose: current.startGlucose,
            endGlucose: endGlucose,
            elapsed: end.timeIntervalSince(current.startedAt),
            reason: reason,
            interference: interference,
            interferenceUnread: interferenceUnread,
            isf: current.isf,
            scheduledBasal: BasalTestEvaluator.scheduledBasal(for: current, endingAt: end)
        )

        current.phase = .finished
        current.pendingEnd = nil
        current.endedAt = end
        current.endReason = reason
        current.endGlucose = endGlucose
        current.readings = readings
        current.outcome = evaluation.outcome
        current.interference = interference
        current.interferenceUnread = interferenceUnread

        // Only a verdict on the basal is kept.
        var record: SettingsTestRecord?
        if evaluation.outcome.isConclusive, let direction = evaluation.direction {
            record = SettingsTestRecord(
                kind: .basal,
                startedAt: current.startedAt,
                completedAt: end,
                timeBlock: current.timeBlock,
                startGlucose: current.startGlucose,
                // Only a low can get here without one: it says falling whatever the readings were.
                endGlucose: endGlucose ?? current.startGlucose,
                direction: direction,
                summary: BasalTestEvaluator.summary(for: evaluation.outcome, reason: reason),
                // Only what the hours it ran covered, so a fast ended early doesn't vouch for the rest.
                coveredEntries: BasalTestEvaluator.coveredEntries(for: current, endingAt: end)
            )
        }

        // Kept only if it is still the fast shown: a Discard or a new Begin while the history was read owns the saved state
        // now. One step on the main actor, so neither can come in between, and the notice goes with the save it reports.
        let ended = current
        let archived = record
        let kept: Bool = await MainActor.run {
            isFinishing = false
            // Whether or not anything is posted: a fast begun before the update may have a notification waiting for its
            // planned end.
            notifier.withdrawLegacy()
            guard let shown = state, shown.id == ended.id, shown.phase == .running else { return false }
            // A note that says the usual dosing came back says so only when the mode in force now is it.
            var finished = ended
            finished.interference = BasalTestEvaluator.modeWorded(ended.interference, modeBack: modeIsBack(for: ended))
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
            debug(.settings, "BasalTestRunner: finished the fast, \(evaluation.outcome.rawValue)")
        }
    }

    /// What a finished fast's notice says: its result is ready when it has a verdict, otherwise the sentence its Result
    /// gives, with the usual mode being back when it is.
    @MainActor private func endedNotice(for test: BasalTestState) -> SettingsTestNotice {
        if test.outcome?.isConclusive == true { return .finished(.basal) }
        let paragraphs = BasalTestEvaluator.resultParagraphs(
            for: test.outcome ?? .invalid,
            test: test,
            evaluation: BasalTestEvaluator.evaluation(of: test)
        )
        return .ended(
            .basal,
            sentence: paragraphs.first
                ?? String(localized: "Something changed during the fast, so the result can't be trusted. Try again."),
            modeBack: modeIsBack(for: test)
        )
    }

    /// Whether the mode in force now is the usual one the fast began from.
    @MainActor private func modeIsBack(for test: BasalTestState) -> Bool {
        settingsManager.settings.dosingMode == test.previousMode && test.previousMode != .basalTesting
    }

    /// How the fast ends, from what the pump history and Trio's determinations up to `end` say: see
    /// `BasalTestEvaluator.finishing`. A low or an interruption already decided needs no read.
    private func settle(
        _ test: BasalTestState,
        reason: BasalTestEndReason,
        at end: Date
    ) async -> (reason: BasalTestEndReason, end: Date, note: String?) {
        guard reason != .low, reason != .interrupted else { return (reason, end, nil) }
        let suspend: BasalTestEvaluator.SuspendReading
        do {
            suspend = try await reads.fetchSuspendReading(from: test.startedAt, to: end)
        } catch {
            warning(.settings, "BasalTestRunner: couldn't read temp basals to check the finished fast for a low", error: error)
            suspend = .unreadable
        }
        return BasalTestEvaluator.finishing(reason: reason, at: end, suspend: suspend)
    }

    /// What spoiled the fast, if anything: carbs (from Start on, or dated before it and logged since,
    /// `SettingsTestCarbRule`), the pump suspended, alarmed or changed, a bolus, or Trio dosing, which it doesn't in Basal
    /// Testing. Each record is read on its own, so one that can't be read is logged without hiding what the others show;
    /// with nothing found, the fast is left unchecked.
    private func wasInterrupted(_ test: BasalTestState, until end: Date) async -> BasalTestEvaluator.Interference {
        let start = test.startedAt
        let kept = test.carbsAtBegin
        let reads = self.reads
        return await BasalTestEvaluator.firstInterference(BasalTestEvaluator.interferenceChecks(
            hasCarbs: {
                let entries = try await reads.fetchCarbEntries(
                    from: SettingsTestCarbRule.readFrom(startedAt: start, kept: kept),
                    to: end
                )
                return SettingsTestCarbRule.spoil(entries, startedAt: start, kept: kept)
            },
            pumpInterruptions: { try await reads.fetchPumpInterruptions(from: start, to: end) },
            hasManualBolus: { try await reads.hasManualBolus(from: start, to: end) },
            smbs: { try await reads.fetchSMBs(since: start, until: end) },
            temps: { try await reads.fetchTempBasals(from: start, to: end) },
            since: start,
            until: end
        ))
    }
}
