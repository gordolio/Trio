import Combine
import Foundation

/// Runs the carb ratio test from Begin to its prepared result in `SettingsTestService`, with nothing waiting for its
/// screen, as the ISF test's runner does (`ISFTestRunner`): settling, the test bolus and the tablets' carbs logged with
/// it, the conditions at the bolus, the checks while it waits, the ending, the archive, the mode restore and the notices.
/// It owns `trio/carb_ratio_test_state.json`; every change is saved on the main actor (`save`) and published.
final class CarbRatioTestRunner: SettingsTestRunner, CarbRatioTestRunning {
    /// How far before the bolus to read glucose for the start glucose: the newest 3 readings at or before it are all it
    /// uses.
    static let startReadingsLookback: TimeInterval = 3600
    /// How far back the Dose step's readings go: the newest 3 are all it uses, for the glucose and the arrow.
    static let recentReadingsMinutes = 60

    let kind: SettingsTestKind = .carbRatio
    private(set) weak var service: SettingsTestService?
    let reads: CarbRatioTestReads
    let storage: FileStorage
    let settingsManager: SettingsManager
    let notifier: SettingsTestNotifying

    /// Sent on the main actor only (`save`, `publish`); read anywhere.
    let subject: CurrentValueSubject<CarbRatioTestRunnerState, Never>
    /// Whether a finish has claimed the test (`claimFinish`), so no check or other ending moves it meanwhile. Main actor
    /// only.
    var isFinishing = false

    /// One check at a time (`check()`).
    let checks = SettingsTestCheckCoalescer()

    /// `service` is held weak: it holds the runner.
    init(
        service: SettingsTestService,
        reads: CarbRatioTestReads,
        storage: FileStorage,
        settingsManager: SettingsManager,
        notifier: SettingsTestNotifying
    ) {
        self.service = service
        self.reads = reads
        self.storage = storage
        self.settingsManager = settingsManager
        self.notifier = notifier
        subject = CurrentValueSubject(CarbRatioTestRunnerState(
            test: storage.retrieve(CarbRatioTest.Config.statePath, as: CarbRatioTestState.self)
        ))
    }

    var state: CarbRatioTestRunnerState { subject.value }
    var statePublisher: AnyPublisher<CarbRatioTestRunnerState, Never> { subject.eraseToAnyPublisher() }

    var isRunning: Bool {
        guard let test = state.test else { return false }
        return test.phase != .finished
    }

    /// Writes the test and publishes it.
    @MainActor func save(_ test: CarbRatioTestState) {
        storage.save(test, as: CarbRatioTest.Config.statePath)
        var next = subject.value
        next.test = test
        subject.send(next)
    }

    /// Publishes what isn't saved, when it changed.
    @MainActor func publish(_ change: (inout CarbRatioTestRunnerState) -> Void) {
        var next = subject.value
        change(&next)
        guard next != subject.value else { return }
        subject.send(next)
    }

    func post(_ notice: SettingsTestNotice) {
        debug(.settings, "CarbRatioTestRunner: posting the \(notice.identifier) notice, \"\(notice.title)\"")
        notifier.post(notice)
    }

    // MARK: - Begin

    /// Why Begin is refused now, or nil: another test runs, this one included (one whose session was lost would otherwise
    /// hand the new test Basal Testing as its usual mode), or Basal Testing is on (kept as the usual mode, nothing would
    /// ever turn it off).
    @MainActor private func beginRefusal() -> SettingsTestBeginError? {
        guard !isRunning, service?.activeSession == nil else { return .otherTestRunning }
        guard settingsManager.settings.dosingMode != .basalTesting else { return .basalTestingOn }
        return nil
    }

    /// Saves the test from the settings in force now, with the carb entries there now (`SettingsTestCarbRule`), starts its
    /// session and switches to Basal Testing. Refused, changing nothing, for `beginRefusal`, when those entries can't be
    /// read, when an override or a temp target is running or that can't be read, without an ISF and a target, without a
    /// carb ratio to count the tablets from, for tablets over what Max Bolus and Max Carbs allow, for insulin on board
    /// over the whole dose, for carbs on board at or over the test's line (each read again here, since the Check screen
    /// last read it), and when the test or its session didn't save: read back before the mode changes, so a relaunch
    /// always finds the way back. A new test withdraws the last one's ended notice.
    @MainActor func begin(_ begin: CarbRatioTestBegin) async -> SettingsTestBeginError? {
        if let refusal = beginRefusal() { return refusal }
        let now = Date()
        let carbsAtBegin: [String]
        do {
            carbsAtBegin = SettingsTestCarbRule.keptAtBegin(
                try await reads.fetchCarbs(from: now.addingTimeInterval(-SettingsTestCarbRule.lookback), to: now)
                    .map(\.entry)
            )
        } catch {
            warning(.settings, "CarbRatioTestRunner: couldn't read the carb entries there at Begin", error: error)
            return .dataUnreadable(error.localizedDescription)
        }
        // One started after the Check screen last read it would run through the test.
        do {
            if try await reads.hasActiveAdjustment() {
                warning(.settings, "CarbRatioTestRunner: an override or temp target is running, so the test doesn't begin")
                return .adjustmentActive
            }
        } catch {
            warning(.settings, "CarbRatioTestRunner: couldn't read whether an override or temp target is running", error: error)
            return .dataUnreadable(error.localizedDescription)
        }
        // Not read yet, or a read that failed, doesn't hold Begin up; the Dose step waits for a read.
        let cob = (try? await reads.currentCOB()) ?? nil
        // The reads took time.
        if let refusal = beginRefusal() { return refusal }
        // What the dose and the result use, kept so neither depends on what the settings say by then.
        guard let isf = reads.isf(at: now), isf > 0, let target = reads.target(at: now) else { return .settingsUnreadable }
        guard let carbRatio = reads.carbRatio(at: now), carbRatio > 0 else { return .carbRatioUnreadable }
        // The docs' 3 to 4 hours, whatever the screen sent.
        let lengths = CarbRatioTest.Config.lengths
        let length = min(
            max(begin.length, lengths.min() ?? CarbRatioTest.Config.defaultLength),
            lengths.max() ?? CarbRatioTest.Config.defaultLength
        )
        // The schedule as it is at Begin, over every hour a bolus in the time allowed could come at, so a ratio edited
        // before the bolus is found doesn't become what the test ran on.
        let crEntries = CarbRatioTestEvaluator.coveredAtBegin(reads.carbRatioEntries(), startedAt: now, length: length)
        // A ratio a docs step under it must still be one the docs allow ("Minimum: 1.0 g/U"), now and at any bolus.
        let minimum = CarbRatioTest.Config.minimumTestedCarbRatio
        guard carbRatio >= minimum, (crEntries ?? []).allSatisfy({ $0.value >= minimum }) else {
            return .carbRatioUnderMinimum
        }
        // Never past what Max Bolus and Max Carbs allow, as the Check screen's count; unread, Treatments still holds the
        // bolus and the carbs to them.
        if let maxBolus = reads.maxBolus(), let maxCarbs = reads.maxCarbs(),
           CarbRatioTestEvaluator.tabletCount(
               begin.count,
               brand: begin.brand,
               carbRatio: carbRatio,
               maxBolus: maxBolus,
               maxCarbs: maxCarbs
           ) != begin.count
        {
            return .tabletsOverLimits
        }
        let tabletCarbs = begin.brand.totalCarbs(for: begin.count)
        guard begin.count >= 1, let expected = CarbRatioTestEvaluator.unroundedDose(carbs: tabletCarbs, carbRatio: carbRatio)
        else { return .tabletsOverLimits }
        let decision = CarbRatioTestEvaluator.iobDecision(iob: begin.iob, expectedDose: expected, carbRatio: carbRatio)
        if decision == .blocked { return .iobOverDose }
        let cobLine = CarbRatioTestEvaluator.cobLine(carbs: tabletCarbs, carbRatio: carbRatio)
        if CarbRatioTestEvaluator.cobBlocks(cob: cob, line: cobLine) { return .carbsOnBoard }

        let prior = subject.value
        let previous = settingsManager.settings.dosingMode
        var test = CarbRatioTestState(
            phase: .settling,
            startedAt: now,
            previousMode: previous,
            carbRatio: carbRatio,
            isf: isf,
            target: target,
            // The docs' dose is rounded up to it before a low's bolus is held against it.
            bolusIncrement: settingsManager.preferences.bolusIncrement,
            length: length,
            tabletBrand: begin.brand.rawValue,
            tabletCount: begin.count,
            tabletCarbs: tabletCarbs,
            expectedDose: expected,
            iobLine: CarbRatioTestEvaluator.iobLine(dose: expected, carbRatio: carbRatio),
            cobLine: cobLine
        )
        test.iobHandling = CarbRatioTestEvaluator.iobHandling(for: decision, chosen: begin.iobChoice)
        test.crEntries = crEntries
        // The ISF schedule over the same hours.
        test.isfEntries = CarbRatioTestEvaluator.coveredAtBegin(reads.isfEntries(), startedAt: now, length: length)
        test.carbsAtBegin = carbsAtBegin

        // Saved first, so a crash from here on leaves a test that can be finished: one that never reached Basal Testing
        // ends as interrupted. Nothing from a test before it is shown with it.
        publish {
            $0.settling = nil
            $0.doseIOB = nil
        }
        save(test)
        // Register the way back before changing anything, so an interruption can't leave the user in Basal Testing with
        // nobody watching it.
        guard let service, let session = service.begin(
            kind: .carbRatio,
            expiresIn: CarbRatioTest.Config.settleAllowance + CarbRatioTest.Config.doseAllowance + length
                + CarbRatioTest.Config.expiryGrace,
            restoring: [.dosingMode(testMode: .basalTesting, previous: previous)],
            settles: true,
            carbsAtBegin: carbsAtBegin,
            waitLength: length
        ) else {
            putBack(prior)
            return .otherTestRunning
        }
        // Saved again with its session, before the mode changes, so the service's record of ending it can be matched to
        // this test.
        test.sessionID = session.id
        save(test)
        // Both read back before the mode changes: a write that didn't last would leave a relaunch in Basal Testing with
        // no session, or with a test that can't be matched to one.
        let savedTest = storage.retrieve(CarbRatioTest.Config.statePath, as: CarbRatioTestState.self)
        guard savedTest?.id == test.id, savedTest?.sessionID == session.id, service.savedSession()?.id == session.id else {
            warning(.settings, "CarbRatioTestRunner: the test or its session didn't save, so it doesn't begin")
            service.end(kind: .carbRatio)
            putBack(prior)
            return .notSaved
        }
        settingsManager.settings.dosingMode = .basalTesting
        // "Your result is ready" from the test before would open this one, and the old wizard's would come mid-test.
        notifier.withdraw(.carbRatio, .ended)
        notifier.withdrawOldCarbRatioWizard()
        debug(
            .settings,
            "CarbRatioTestRunner: began the test at \(begin.glucose) mg/dL, \(begin.count) tablets, settling"
        )
        return nil
    }

    /// What was there before a Begin that didn't go ahead stays.
    @MainActor private func putBack(_ prior: CarbRatioTestRunnerState) {
        if let shown = prior.test {
            storage.save(shown, as: CarbRatioTest.Config.statePath)
        } else {
            storage.remove(CarbRatioTest.Config.statePath)
        }
        subject.send(prior)
    }

    // MARK: - Settle

    /// After the settling allowance, with insulin on board still over the line: count it and go on.
    @MainActor func countAndGoOn() {
        guard var current = state.test, current.phase == .settling, case .timeUp = state.settling?.decision else { return }
        current.iobHandling = .count
        save(current)
        // "Carb Ratio Test Waiting" asked this.
        notifier.withdraw(.carbRatio, .step)
        Task { await check() }
    }

    // MARK: - Running

    /// Coalesced (`SettingsTestCheckCoalescer`): one runs at a time, and a call during one waits for it and for one more
    /// run, shared by every call made meanwhile, so a change that came in after the reads started is never missed.
    func check() async {
        await checks.run { await checkRunningTest() }
    }

    /// The test as it is now, unless it has finished or a finish has claimed it.
    private func runningTest(_ testID: UUID? = nil) async -> CarbRatioTestState? {
        await MainActor.run {
            guard let test = state.test, test.phase != .finished, !isFinishing, testID == nil || test.id == testID
            else { return nil }
            return test
        }
    }

    /// While settling, sees whether the real test can start. Until the meal is in, looks for its two halves, the test
    /// bolus and the tablets' carbs, and judges it once both are (`lookForMeal`). Waiting, ends the test for a bolus off
    /// the formula's by more than a docs step (`bolusOffFormula`). Then ends it if the service ended it, Trio suspended
    /// insulin for a low, the time for the bolus or the chosen length ran out, the dosing mode was changed, or something
    /// spoiled it; then if the meal's halves didn't come within the pairing time of each other
    /// (`CarbRatioTestEvaluator.mealPairingEnd`), and a step that offers only Cancel Test ends the test with the sentence
    /// it shows (`deadEnd`). Last, the Dose step's offer and notice.
    private func checkRunningTest() async {
        guard let test = await runningTest() else { return }
        // An ending decided before Trio was closed is finished for that ending, never another.
        if let pending = test.pendingEnd {
            await finish(for: test.id, reason: pending.reason)
            return
        }
        // What the check finishes below is this test, and only this one: the reads in between give the user time to
        // discard it and start another, which this check knows nothing about.
        let testID = test.id
        let now = Date()

        // Settling's decision this check, nil when it couldn't decide.
        var settling: ISFTestSettling?
        if test.phase == .settling {
            settling = await checkSettling(of: testID)
        }
        await shareBolusWindowStart(of: testID)
        // Insulin on board for a counted dose grows old between loops too.
        await refreshDoseIOB(of: testID)

        // Until both of the meal's halves are in. What could be read this check, so a tick that couldn't doesn't decide
        // there was no bolus, a low before the dose, or a half that didn't come.
        let meal = await lookForMeal(of: testID)
        // Settling may have ended, and the bolus may have moved it on to the wait.
        guard var current = await runningTest(testID) else { return }

        // The units given count insulin on board at the bolus; a tick that couldn't read it tries again.
        if current.phase == .waiting, CarbRatioTestEvaluator.iobAtBolusUnread(of: current), let bolusAt = current.bolusAt,
           let iob = await readIOB(before: bolusAt, of: current)
        {
            await updateIOBAtBolus(iob, of: testID)
        }

        // Judged on what the pump delivered: the amount first seen can be the one programmed, and a bolus cut short is
        // written with less once the pump reports it.
        if current.phase == .waiting, let bolusAt = current.bolusAt {
            switch await ISFTestEvaluator.bolusAmount(
                saved: current.bolusUnits,
                reread: rereadTestBolus(at: bolusAt),
                bolusAt: bolusAt,
                finishing: false
            ) {
            case .cancelled:
                let ending = CarbRatioTestEvaluator.ending(for: .bolusCancelled, doseDeadline: current.noBolusDeadline)
                await finish(for: testID, reason: ending.reason, at: ending.at, note: ending.note)
                return
            case let .units(units):
                if units != current.bolusUnits {
                    await updateBolusUnits(units, of: testID)
                }
            case .unread:
                break
            }
            // The units given, as now saved, must be the formula's within a docs step ("Deliver the full bolus
            // manually"): at the bolus, and again whenever the amount is read again (a bolus cut short).
            guard let latest = await runningTest(testID) else { return }
            current = latest
            if let off = CarbRatioTestEvaluator.bolusOffFormula(of: current) {
                debug(.settings, "CarbRatioTestRunner: the bolus was more than a docs step from the formula's, ending the test")
                await finish(for: testID, reason: .interrupted, note: off.note)
                return
            }
        }

        // Only the test itself: a zero temp after the planned end isn't this test's low. From Begin, so a low before the
        // bolus, settling's among them, is seen as one.
        let end = min(now, current.plannedEnd ?? current.noBolusDeadline)
        // Trio's determinations say whether a zero temp was its suspend for a low or one set on the pump.
        let suspend: BasalTestEvaluator.SuspendReading
        do {
            // A zero temp only Closed Loop asked for as the test began is settling's, not a low.
            suspend = try await reads.fetchSuspendReading(startedAt: current.startedAt, to: end)
        } catch {
            // Without them a low can't be told from a test that ran its course. Before the end nothing is decided on them
            // this time; at it, the test still ends, without a verdict.
            warning(.settings, "CarbRatioTestRunner: couldn't read temp basals to check for a low", error: error)
            suspend = .unreadable
        }

        // Read together on the main actor, where the service keeps its record before it brings the usual mode back, so a
        // mode changed by the service is never seen without the reason.
        let (mode, serviceEnd) = await MainActor.run { (settingsManager.settings.dosingMode, service?.lastEnd()) }
        // The service's record of a meal not paired: it ended the session before the ISF test's rules could read it.
        if let ending = CarbRatioTestEvaluator.serviceMealEnd(of: current, serviceEnd: serviceEnd) {
            await finish(for: testID, reason: ending.reason, at: ending.at, note: ending.note)
            return
        }
        let found = CarbRatioTestEvaluator.runningCheck(
            of: current,
            serviceEnd: serviceEnd,
            suspend: suspend,
            now: now,
            mode: mode
        )
        if let check = CarbRatioTestEvaluator.decidable(found, bolusesRead: meal.boluses) {
            let ending = CarbRatioTestEvaluator.ending(for: check, doseDeadline: current.noBolusDeadline)
            await finish(for: testID, reason: ending.reason, at: ending.at, note: ending.note)
            return
        } else if case .found = await wasInterrupted(current, until: end) {
            await finish(for: testID, reason: .interrupted)
            return
        }
        // Only once nothing above ended the test, so a low or the service's ending keeps its own words, and only from a
        // check that read both halves.
        if meal.boluses, meal.carbs, let ending = await mealPairingEnd(of: testID, now: now) {
            debug(.settings, "CarbRatioTestRunner: the meal's carbs and bolus didn't come together, ending the test")
            await finish(for: testID, reason: ending.reason, at: ending.at, note: ending.note)
            return
        }
        // Only once nothing ended the test, so a step notice never comes just before it ends, and a dead end never stands
        // in for what did. The Dose step's inputs are read once, for both.
        var doseInputs: CarbRatioTestDoseInputs?
        if let latest = state.test, latest.id == testID, latest.phase == .dosing {
            doseInputs = await readDoseInputs(of: latest)
        }
        // A temp basal settling found running at its time-up is its dead end only when the pump history shows one that
        // isn't Basal Testing's own suspend for a low.
        var tempBasalDeadEnd = false
        if case .tempBasalRunning = settling {
            tempBasalDeadEnd = await tempBasalIsDeadEnd(current, now: now)
        }
        if let deadEnd = await deadEnd(
            of: testID,
            settling: settling,
            tempBasalDeadEnd: tempBasalDeadEnd,
            doseInputs: doseInputs
        ) {
            debug(.settings, "CarbRatioTestRunner: the step offers only Cancel Test, ending the test")
            await finish(for: testID, reason: .interrupted, note: deadEnd)
            return
        }
        if let doseInputs {
            await noteDoseOffer(of: testID, inputs: doseInputs)
            await postDueDoseNotice(of: testID, inputs: doseInputs)
        }
    }

    /// The sentence of the step the test is on, when that step offers only Cancel Test: settling's once its time is up with
    /// no loop in Basal Testing, too few readings since it, or a temp basal still running that the history shows isn't
    /// Basal Testing's own suspend (`settling`, this check's decision, and `tempBasalDeadEnd`), and the Dose step's
    /// without the settings to work the dose out (`doseInputs`, as the step reads them). Nil otherwise, for a test that
    /// moved on or a finish claimed meanwhile, and once the service ended its session or another runs (`sessionEnded`):
    /// the service's ending, read by the next check, says why instead.
    private func deadEnd(
        of testID: UUID,
        settling: ISFTestSettling?,
        tempBasalDeadEnd: Bool,
        doseInputs: CarbRatioTestDoseInputs?
    ) async -> String? {
        await MainActor.run {
            guard let test = state.test, test.id == testID, test.pendingEnd == nil, !isFinishing,
                  !sessionEnded(for: test)
            else { return nil }
            switch test.phase {
            case .settling:
                if case .tempBasalRunning = settling, !tempBasalDeadEnd { return nil }
                return settling.flatMap(CarbRatioTestEvaluator.settlingDeadEnd)
            case .dosing:
                return doseInputs.flatMap { CarbRatioTestEvaluator.doseDeadEnd(of: test, $0) }
            case .finished,
                 .waiting:
                return nil
            }
        }
    }

    /// How a test whose meal's halves didn't come within the pairing time of each other ends
    /// (`CarbRatioTestEvaluator.mealPairingEnd`), with the same guards as a dead end: nil for a test that moved on, an
    /// ending saved or a finish claimed meanwhile, and once the service ended its session or another runs (the service's
    /// own record says why then, `serviceMealEnd`).
    private func mealPairingEnd(of testID: UUID, now: Date) async -> CarbRatioTestEvaluator.Ending? {
        await MainActor.run {
            guard let test = state.test, test.id == testID, test.pendingEnd == nil, !isFinishing,
                  !sessionEnded(for: test)
            else { return nil }
            return CarbRatioTestEvaluator.mealPairingEnd(carbsAt: test.carbsAt, bolusAt: test.bolusAt, now: now)
        }
    }

    /// Whether the test's own session is the one the service runs, so a step acts for it: a check that read the service
    /// before it ended the session mustn't post or move on.
    @MainActor private func sessionIsLive(for test: CarbRatioTestState) -> Bool {
        service?.activeSession?.id == test.sessionID
    }

    /// Whether the service ended the test's session, or another session runs (`SettingsTestModeRule.isEnding`), so a
    /// dead end leaves the test to the service's ending. A lost session, with none running and no end of it kept, isn't
    /// one: nothing else ends that test before its deadline, so its dead end does.
    @MainActor private func sessionEnded(for test: CarbRatioTestState) -> Bool {
        SettingsTestModeRule.isEnding(
            hasPendingEnd: false,
            isRunning: true,
            testSessionID: test.sessionID,
            session: (activeID: service?.activeSession?.id, lastEndID: service?.lastEnd()?.sessionID),
            mode: settingsManager.settings.dosingMode,
            previousMode: test.previousMode
        )
    }

    /// Whether the temp basal settling found running is a dead end (`ISFTestEvaluator.tempBasalIsDeadEnd`), from the pump
    /// history's temp basals, from `runningTempLookback` before Begin so one set on the pump before it is read too, and
    /// the determinations that asked for a zero temp. A read that fails decides nothing: no dead end this time.
    private func tempBasalIsDeadEnd(_ test: CarbRatioTestState, now: Date) async -> Bool {
        do {
            let temps = try await reads.fetchTempBasals(
                from: test.startedAt.addingTimeInterval(-ISFTestEvaluator.runningTempLookback),
                to: now
            )
            let asked = try await reads.zeroTempDeterminations(
                from: test.startedAt.addingTimeInterval(-BasalTestEvaluator.zeroTempAskedBefore),
                to: now.addingTimeInterval(BasalTestEvaluator.zeroTempAskedAfter)
            )
            return ISFTestEvaluator.tempBasalIsDeadEnd(
                temps: temps,
                zeroTempDeterminations: asked,
                startedAt: test.startedAt,
                now: now
            )
        } catch {
            warning(.settings, "CarbRatioTestRunner: couldn't read the temp basals to judge settling's dead end", error: error)
            return false
        }
    }

    /// On the Dose step, while it offers the dose (Open Treatments on, `CarbRatioTestEvaluator.canDose`): saves the
    /// moment (`doseOfferedAt`). The first check that finds the offer gone saves that too (`doseOfferEndedAt`). Each check,
    /// only for the live session.
    private func noteDoseOffer(of testID: UUID, inputs: CarbRatioTestDoseInputs) async {
        await MainActor.run {
            guard var latest = state.test, latest.id == testID, latest.phase == .dosing, latest.pendingEnd == nil,
                  !isFinishing, sessionIsLive(for: latest)
            else { return }
            if CarbRatioTestEvaluator.canDose(of: latest, inputs) {
                latest.doseOfferedAt = inputs.now
                latest.doseOfferEndedAt = nil
            } else if latest.doseOfferedAt != nil, latest.doseOfferEndedAt == nil {
                latest.doseOfferEndedAt = inputs.now
            } else {
                return
            }
            save(latest)
        }
    }

    /// What the Dose step reads, as the screen reads it: the recent readings and the CGM's arrow on the newest, from the
    /// same row, insulin on board, carbs on board from before the tablets' carbs (`fetchDoseCOB`), and insulin on board
    /// for a counted dose (`refreshDoseIOB`). Nil when the readings couldn't be read, so nothing is decided on them this
    /// time.
    private func readDoseInputs(of test: CarbRatioTestState) async -> CarbRatioTestDoseInputs? {
        let readings: [BasalTestReading]
        do {
            readings = try await reads.fetchRecentGlucose(minutes: Self.recentReadingsMinutes)
        } catch {
            warning(.settings, "CarbRatioTestRunner: couldn't read glucose to see what the Dose step offers", error: error)
            return nil
        }
        let iob = reads.currentIOB()
        let cob = await reads.fetchDoseCOB(windowStart: test.bolusWindowStart)
        return await MainActor.run {
            CarbRatioTestDoseInputs(
                readings: readings,
                direction: readings.first?.direction,
                iob: iob,
                doseIOB: state.doseIOB,
                cob: cob,
                increment: settingsManager.preferences.bolusIncrement,
                now: Date()
            )
        }
    }

    /// Reads Trio's determinations and the boluses since Begin, and insulin on board now, and ends settling when
    /// `ISFTestEvaluator.settling` says it has, with the test's line: the Dose step comes next, and the service learns
    /// where the bolus window starts. Its notice waits until the step offers the dose (`postDueDoseNotice`).
    /// Determinations that can't be read leave it settling. Returns the decision, nil when there was none: one that
    /// couldn't read, or a test that moved on.
    private func checkSettling(of testID: UUID) async -> ISFTestSettling? {
        guard let test = state.test, test.id == testID, test.phase == .settling else { return nil }
        let now = Date()
        let determinations: [Date]
        do {
            determinations = try await reads.fetchDeterminations(from: test.startedAt, to: now).map(\.date)
        } catch {
            warning(.settings, "CarbRatioTestRunner: couldn't read Trio's determinations to settle the test", error: error)
            return nil
        }
        let boluses: [ISFTestBolus]?
        do {
            boluses = try await reads.fetchBoluses(from: test.startedAt, to: now)
        } catch {
            warning(.settings, "CarbRatioTestRunner: couldn't read boluses given while the test settles", error: error)
            boluses = nil
        }
        // Which of them the pump history flags as SMBs, to say which Trio gave. Unread, none is called one.
        let smbs = try? await reads.fetchSMBs(since: test.startedAt, until: now)
        // The CGM readings since Begin, of which those after Trio's first loop in Basal Testing count. Unread, settling
        // waits for a tick that reads them.
        let readings: [BasalTestReading]
        do {
            readings = try await reads.fetchGlucose(from: test.startedAt, to: now)
        } catch {
            warning(.settings, "CarbRatioTestRunner: couldn't read glucose to settle the test", error: error)
            return nil
        }
        let readingDates = readings.map(\.date)
        let iob = reads.currentIOB()
        // A temp basal still running at the end of settling would change the basal the test runs on. Unread, it doesn't
        // hold settling up.
        let tempBasalRunning = reads.pumpDelivery().map { $0 == .tempBasal }

        return await MainActor.run { () -> ISFTestSettling? in
            guard var latest = state.test, latest.id == testID, latest.phase == .settling, !isFinishing else { return nil }
            let decision = ISFTestEvaluator.settling(
                startedAt: latest.startedAt,
                determinations: determinations,
                readings: readingDates,
                tempBasalRunning: tempBasalRunning,
                iob: iob,
                line: latest.iobLine,
                handling: latest.iobHandling,
                now: now
            )
            let progress = ISFTestSettlingProgress(
                decision: decision,
                boluses: boluses.map {
                    ISFTestEvaluator.settlingBoluses($0, smbs: smbs, startedAt: latest.startedAt, settledAt: nil)
                } ?? state.settling?.boluses ?? [],
                readingsAfterLoop: ISFTestEvaluator.firstLoopInTestMode(determinations, startedAt: latest.startedAt)
                    .map { ISFTestEvaluator.readingsAfterLoop(readingDates, loopedAt: $0) },
                tempBasalRunning: tempBasalRunning == true,
                iob: iob
            )
            publish { $0.settling = progress }
            // The hour is up with insulin on board still over the line, and the screen asks whether to count it and go on,
            // or cancel: "Carb Ratio Test Waiting", once, saved with it so a relaunch doesn't say it again. Only for the
            // live session, as the other step notices.
            if case .timeUp = decision, latest.timeUpNoticePosted != true, latest.pendingEnd == nil,
               sessionIsLive(for: latest)
            {
                latest.timeUpNoticePosted = true
                save(latest)
                post(.carbRatioStep(.timeUp))
            }
            // A test whose session the service ended, or ran out of time, is ended by the running check instead.
            guard decision == .settled,
                  ISFTestEvaluator.canSettle(
                      sessionID: latest.sessionID,
                      activeSessionID: service?.activeSession?.id,
                      mode: settingsManager.settings.dosingMode,
                      now: Date(),
                      noBolusDeadline: latest.noBolusDeadline
                  )
            else { return decision }
            // A bolus from here on can be the test's; one before it was given while settling.
            let settledAt = Date()
            latest.settledAt = settledAt
            latest.phase = .dosing
            // The Dose step's notice waits for the end of this check, which reads what the step offers.
            latest.doseNoticeDue = true
            save(latest)
            // Settling moved on by itself: "Carb Ratio Test Waiting", if it went, asks what no step asks now.
            if latest.timeUpNoticePosted == true {
                notifier.withdraw(.carbRatio, .step)
            }
            service?.setBolusWindowStart(kind: .carbRatio, at: settledAt)
            publish { $0.settling = nil }
            debug(.settings, "CarbRatioTestRunner: settled, moving on to the dose")
            return decision
        }
    }

    /// Makes sure the service knows where the bolus window starts, for a test past settling whose session doesn't: one
    /// the app closed on as it settled.
    private func shareBolusWindowStart(of testID: UUID) async {
        await MainActor.run {
            guard let test = state.test, test.id == testID, test.phase != .finished, let start = test.bolusWindowStart,
                  let service, let session = service.activeSession, session.kind == .carbRatio,
                  session.id == test.sessionID, session.bolusWindowStart == nil
            else { return }
            service.setBolusWindowStart(kind: .carbRatio, at: start)
        }
    }

    /// Reads insulin on board for a counted dose, dosing in a test that counts it, from Trio's newest determination of the
    /// last 12 minutes. Cleared otherwise, and when it can't be read.
    private func refreshDoseIOB(of testID: UUID) async {
        guard let test = state.test, test.id == testID, test.iobHandling == .count, test.phase == .dosing else {
            await MainActor.run { publish { $0.doseIOB = nil } }
            return
        }
        let iob: Decimal?
        do {
            iob = try await reads.fetchDoseIOB(at: Date())
        } catch {
            warning(.settings, "CarbRatioTestRunner: couldn't read insulin on board for the dose", error: error)
            iob = nil
        }
        await MainActor.run {
            // Not onto a test that moved on, or that a finish has claimed and cleared, while it was read.
            guard let latest = state.test, latest.id == testID, latest.iobHandling == .count, latest.phase == .dosing,
                  !isFinishing
            else { return }
            publish { $0.doseIOB = iob }
        }
    }

    /// Insulin on board just before the bolus, from Trio's determinations in the 12 minutes before it
    /// (`ISFTestEvaluator.iobAtBolus`). Nil when there is none that recent, or they couldn't be read.
    func readIOB(before bolusAt: Date, of test: CarbRatioTestState) async -> Decimal? {
        do {
            let oldest = bolusAt.addingTimeInterval(-BasalTest.Config.endReadingMaxAge - CarbRatioTest.Config.savedDateTolerance)
            let determinations = try await reads.fetchDeterminations(from: max(test.startedAt, oldest), to: bolusAt)
            return ISFTestEvaluator.iobAtBolus(determinations, bolusAt: bolusAt)
        } catch {
            warning(.settings, "CarbRatioTestRunner: couldn't read insulin on board at the bolus", error: error)
            return nil
        }
    }

    /// Insulin on board Trio reports still left at the planned end, from its determinations in the 12 minutes up to it
    /// (`ISFTestEvaluator.iobAtEnd`), the same source and age as at the bolus. Nil when there is none that recent, or they
    /// couldn't be read.
    func readIOB(atEnd plannedEnd: Date, of test: CarbRatioTestState) async -> Decimal? {
        do {
            let oldest = plannedEnd.addingTimeInterval(
                -BasalTest.Config.endReadingMaxAge - CarbRatioTest.Config.savedDateTolerance
            )
            let determinations = try await reads.fetchDeterminations(
                from: max(test.startedAt, oldest),
                to: plannedEnd.addingTimeInterval(CarbRatioTest.Config.savedDateTolerance)
            )
            return ISFTestEvaluator.iobAtEnd(determinations, plannedEnd: plannedEnd)
        } catch {
            warning(.settings, "CarbRatioTestRunner: couldn't read insulin on board at the end of the test", error: error)
            return nil
        }
    }

    /// Saves the insulin on board at the bolus.
    private func updateIOBAtBolus(_ iob: Decimal, of testID: UUID) async {
        await MainActor.run {
            guard var latest = state.test, latest.id == testID, latest.phase == .waiting, !isFinishing else { return }
            latest.iobAtBolus = iob
            save(latest)
        }
    }

    /// What the meal step could read this check (`lookForMeal`), so a tick that couldn't doesn't decide there was no
    /// bolus, a low before the dose, or a half of the meal that didn't come.
    struct MealReads {
        var boluses = true
        var carbs = true
    }

    /// Looks for the meal's two halves from the end of settling, while either is still to come: the test bolus, the
    /// first bolus from any source up to the deadline, and the tablets' carbs, the first carb entry from then on
    /// (`CarbRatioTestEvaluator.mealCarbs`). Each is saved as it is found. The bolus moves the test on to the wait, with
    /// the carb ratio and ISF in force at it and the insulin on board just before it. Carbs logged first keep the test on
    /// the Dose step, which then asks only for the bolus (`CarbRatioTestState.carbsLoggedAwaitingBolus`).
    ///
    /// Once both are in, within the pairing time of each other, the meal is judged at its moment, the earlier of the two
    /// (`CarbRatioTestEvaluator.failedMealCondition`): the grams logged against the tablets', the start glucose and the
    /// CGM's arrow at it, carbs on board from before it, and insulin on board just before the bolus. A meal that fails
    /// ends the test with no verdict: the ending is saved with it first (`pendingEnd`), then finished. Halves too far
    /// apart are `mealPairingEnd`'s to end. A read that throws decides nothing, and the next check reads again.
    private func lookForMeal(of testID: UUID) async -> MealReads {
        var read = MealReads()
        guard let test = state.test, test.id == testID, let windowStart = test.bolusWindowStart,
              test.phase == .dosing || (test.phase == .waiting && test.carbs == nil)
        else { return read }

        var bolus: ISFTestBolus?
        if test.bolusAt == nil {
            do {
                // Read a little past the deadline, which is saved to the millisecond, so a bolus at the same moment as it
                // reaches `testBolus`, which counts it as inside. One before the end of settling isn't the test's.
                let boluses = try await reads.fetchBoluses(
                    from: windowStart,
                    to: test.doseDeadline.addingTimeInterval(CarbRatioTest.Config.savedDateTolerance)
                )
                bolus = ISFTestEvaluator.testBolus(boluses, since: windowStart, deadline: test.doseDeadline)
            } catch {
                warning(.settings, "CarbRatioTestRunner: couldn't read boluses to look for the test bolus", error: error)
                read.boluses = false
            }
        }
        var carbs: CarbRatioTestCarbs?
        if test.carbs == nil {
            do {
                let entries = try await reads.fetchCarbs(
                    from: windowStart,
                    to: Date().addingTimeInterval(CarbRatioTest.Config.savedDateTolerance)
                )
                carbs = CarbRatioTestEvaluator.mealCarbs(entries, since: windowStart)
            } catch {
                warning(.settings, "CarbRatioTestRunner: couldn't read carbs to look for the tablets' carbs", error: error)
                read.carbs = false
            }
        }
        guard bolus != nil || carbs != nil else { return read }
        let bolusAt = bolus?.date ?? test.bolusAt
        let carbsAt = carbs?.date ?? test.carbsAt

        // What the meal is judged on, once both halves are in, in time. A read that throws decides nothing; only one that
        // works and finds nothing recent enough leaves its condition unread, which ends the test.
        var judged: (start: Int?, arrow: ISFTestArrowReading?, determinations: [ISFTestDetermination])?
        if let bolusAt, let carbsAt,
           CarbRatioTestEvaluator.mealPairingEnd(carbsAt: carbsAt, bolusAt: bolusAt, now: .distantFuture) == nil
        {
            let mealAt = min(carbsAt, bolusAt)
            do {
                let readings = try await reads.fetchGlucose(
                    from: mealAt.addingTimeInterval(-Self.startReadingsLookback),
                    to: mealAt
                )
                let arrow = try await reads.fetchArrowReading(atOrBefore: mealAt)
                let determinations = try await reads.fetchDeterminations(
                    from: mealAt.addingTimeInterval(
                        -BasalTest.Config.endReadingMaxAge - CarbRatioTest.Config.savedDateTolerance
                    ),
                    to: bolusAt.addingTimeInterval(CarbRatioTest.Config.savedDateTolerance)
                )
                judged = (BasalTestEvaluator.endGlucose(from: readings, endingAt: mealAt), arrow, determinations)
            } catch {
                warning(
                    .settings,
                    "CarbRatioTestRunner: couldn't read what the meal is judged on, reading it again on the next check",
                    error: error
                )
                return MealReads(boluses: false, carbs: false)
            }
        }
        // A bolus found ahead of the carbs: its insulin on board, which the units given count. Unread, a later tick reads
        // it again.
        var iobAtNewBolus: Decimal?
        if let bolus, judged == nil {
            iobAtNewBolus = await readIOB(before: bolus.date, of: test)
        }

        // On the main actor, from the state as it is now, so a test discarded or finished in the meantime isn't brought
        // back.
        let outcome: (moved: Bool, failed: CarbRatioTestBolusCondition?) = await MainActor.run {
            guard var latest = state.test, latest.id == testID, !isFinishing,
                  latest.phase == .dosing || (latest.phase == .waiting && latest.carbs == nil)
            else { return (false, nil) }
            let newBolus = bolus != nil && latest.bolusAt == nil
            if let bolus, latest.bolusAt == nil {
                // The carb ratio and ISF the result uses become those in force at the bolus, from the schedules saved at
                // Begin, and each schedule narrows to the entry in force then.
                latest = CarbRatioTestEvaluator.atBolus(latest, bolusAt: bolus.date)
                latest.bolusAt = bolus.date
                // A bolus with no amount recorded still started the test, but there is no amount to judge it by.
                latest.bolusUnits = bolus.units > 0 ? bolus.units : nil
                latest.iobAtBolus = judged.map { ISFTestEvaluator.iobAtBolus($0.determinations, bolusAt: bolus.date) }
                    ?? iobAtNewBolus
                latest.phase = .waiting
            }
            if let carbs, latest.carbs == nil {
                latest.carbs = carbs.grams
                latest.carbsAt = carbs.date
                latest.carbsID = carbs.id
            }
            // The meal has begun: the Dose step's notice is no longer owed.
            latest.doseNoticeDue = nil
            var failed: CarbRatioTestBolusCondition?
            if let judged, let mealBolusAt = latest.bolusAt, let mealCarbsAt = latest.carbsAt, let logged = latest.carbs {
                latest.startGlucose = judged.start
                failed = CarbRatioTestEvaluator.failedMealCondition(
                    bolusAt: mealBolusAt,
                    carbsAt: mealCarbsAt,
                    loggedCarbs: logged,
                    plannedCarbs: latest.tabletCarbs,
                    startGlucose: judged.start,
                    carbRatio: latest.carbRatio,
                    arrow: judged.arrow,
                    determinations: judged.determinations,
                    handling: latest.iobHandling
                )
            }
            if let failed {
                // Saved with the meal before anything else, so a relaunch finishes this ending.
                latest.pendingEnd = CarbRatioTestPendingEnd(
                    reason: .interrupted,
                    at: SettingsTestEndRule.endTime(
                        endedAt: nil,
                        limit: latest.plannedEnd ?? latest.noBolusDeadline,
                        now: Date()
                    ),
                    note: failed.note,
                    byUser: false
                )
            }
            save(latest)
            if newBolus, failed == nil {
                debug(.settings, "CarbRatioTestRunner: found the test bolus, waiting out the test")
                // With the save, as the step notices are posted with theirs.
                notifier.withdraw(.carbRatio, .step)
            }
            return (true, failed)
        }
        guard outcome.moved else { return read }
        // A meal the Dose step would have held: the test ends with no verdict, and the usual mode comes back.
        if let failed = outcome.failed {
            debug(.settings, "CarbRatioTestRunner: the meal came while a condition failed (\(failed)), ending the test")
            await finish(for: testID, reason: .interrupted, note: failed.note)
        }
        return read
    }

    /// The bolus rows around the saved bolus time, read again, so the test bolus's amount is the one the pump history holds
    /// now. Any bolus row, because the history can flag the test bolus as an SMB when it writes the amount delivered. Nil
    /// when they couldn't be read.
    func rereadTestBolus(at bolusAt: Date) async -> [ISFTestBolusRecord]? {
        do {
            return try await reads.fetchBolusRecords(
                from: bolusAt.addingTimeInterval(-CarbRatioTest.Config.savedDateTolerance),
                to: bolusAt.addingTimeInterval(CarbRatioTest.Config.savedDateTolerance)
            )
        } catch {
            warning(.settings, "CarbRatioTestRunner: couldn't read the test bolus again", error: error)
            return nil
        }
    }

    /// Saves the amount the pump history now holds for the test bolus, so the Wait step shows what was delivered.
    private func updateBolusUnits(_ units: Decimal?, of testID: UUID) async {
        await MainActor.run {
            guard var latest = state.test, latest.id == testID, latest.phase == .waiting, !isFinishing else { return }
            latest.bolusUnits = units
            save(latest)
        }
    }

    /// On the Dose step with its notice still owed (`CarbRatioTestState.doseNoticeDue`): from what the step reads
    /// (`inputs`, as the screen reads them), posts "Carb Ratio Dose Ready" once Open Treatments would turn on
    /// (`CarbRatioTestEvaluator.doseNotice`). Otherwise it stays owed, since what holds the dose back can change by
    /// itself.
    private func postDueDoseNotice(of testID: UUID, inputs: CarbRatioTestDoseInputs) async {
        await MainActor.run {
            guard var latest = state.test, latest.id == testID, latest.phase == .dosing, latest.pendingEnd == nil,
                  !isFinishing, sessionIsLive(for: latest), latest.doseNoticeDue == true
            else { return }
            let next = CarbRatioTestEvaluator.doseNotice(
                due: latest.doseNoticeDue,
                canDose: CarbRatioTestEvaluator.canDose(of: latest, inputs)
            )
            guard let notice = next.post else { return }
            latest.doseNoticeDue = next.due
            save(latest)
            debug(.settings, "CarbRatioTestRunner: the Dose step offers the dose")
            // In the same main-actor step as the save, so a Cancel Test can't come between them and leave it behind.
            post(.carbRatioStep(notice))
        }
    }
}
