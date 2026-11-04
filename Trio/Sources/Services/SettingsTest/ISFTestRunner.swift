import Combine
import Foundation

/// Runs the ISF test from Begin to its prepared result in `SettingsTestService`, with nothing waiting for its screen:
/// settling, the test bolus and its conditions, the checks while it waits, the ending, the archive, the mode restore and
/// the notices. It owns `trio/isf_test_state.json`; every change is saved on the main actor (`save`) and published.
final class ISFTestRunner: SettingsTestRunner, ISFTestRunning {
    /// How far before the bolus to read glucose for the start glucose: the newest 3 readings at or before it are all it
    /// uses.
    static let startReadingsLookback: TimeInterval = 3600
    /// How far back the Raise step's readings go: the longest a test runs, 90 minutes for the bolus and 4 hours after it,
    /// with time to spare.
    static let recentReadingsMinutes = 6 * 60

    let kind: SettingsTestKind = .isf
    private(set) weak var service: SettingsTestService?
    let reads: ISFTestReads
    let storage: FileStorage
    let settingsManager: SettingsManager
    let notifier: SettingsTestNotifying

    /// Sent on the main actor only (`save`, `publish`); read anywhere.
    let subject: CurrentValueSubject<ISFTestRunnerState, Never>
    /// Whether a finish has claimed the test (`claimFinish`), so no check or other ending moves it meanwhile. Main actor
    /// only.
    var isFinishing = false

    /// One check at a time (`check()`).
    let checks = SettingsTestCheckCoalescer()

    /// `service` is held weak: it holds the runner.
    init(
        service: SettingsTestService,
        reads: ISFTestReads,
        storage: FileStorage,
        settingsManager: SettingsManager,
        notifier: SettingsTestNotifying
    ) {
        self.service = service
        self.reads = reads
        self.storage = storage
        self.settingsManager = settingsManager
        self.notifier = notifier
        subject = CurrentValueSubject(ISFTestRunnerState(test: storage.retrieve(ISFTest.Config.statePath, as: ISFTestState.self)))
    }

    var state: ISFTestRunnerState { subject.value }
    var statePublisher: AnyPublisher<ISFTestRunnerState, Never> { subject.eraseToAnyPublisher() }

    var isRunning: Bool {
        guard let test = state.test else { return false }
        return test.phase != .finished
    }

    /// Writes the test and publishes it.
    @MainActor func save(_ test: ISFTestState) {
        storage.save(test, as: ISFTest.Config.statePath)
        var next = subject.value
        next.test = test
        subject.send(next)
    }

    /// Publishes what isn't saved, when it changed.
    @MainActor func publish(_ change: (inout ISFTestRunnerState) -> Void) {
        var next = subject.value
        change(&next)
        guard next != subject.value else { return }
        subject.send(next)
    }

    func post(_ notice: SettingsTestNotice) {
        debug(.settings, "ISFTestRunner: posting the \(notice.identifier) notice, \"\(notice.title)\"")
        notifier.post(notice)
    }

    // MARK: - Begin

    /// Saves the test from the settings in force now, starts its session and switches to Basal Testing. Refused, changing
    /// nothing, while another test runs, this one included (one whose session was lost would otherwise hand the new test
    /// Basal Testing as its usual mode), while Basal Testing is on (kept as the usual mode, nothing would ever turn it
    /// off), or without an ISF and a target to work from. A new test withdraws the last one's ended notice.
    @MainActor func begin(_ begin: ISFTestBegin) -> SettingsTestBeginError? {
        guard !isRunning, service?.activeSession == nil else { return .otherTestRunning }
        guard settingsManager.settings.dosingMode != .basalTesting else { return .basalTestingOn }
        let now = Date()
        // What the dose and the result use, kept so neither depends on what the settings say by then.
        guard let isf = reads.isf(at: now), isf > 0, let target = reads.target(at: now) else { return .settingsUnreadable }
        let prior = subject.value
        let previous = settingsManager.settings.dosingMode
        var test = ISFTestState(
            phase: .settling,
            startedAt: now,
            previousMode: previous,
            isf: isf,
            target: target,
            carbRatio: reads.carbRatio(at: now)
        )
        // What insulin on board is measured against, fixed for the test, from the same glucose and settings.
        let path = ISFTestEvaluator.startPath(glucose: begin.glucose, target: target)
        let expected = ISFTestEvaluator.expectedDose(startPath: path, glucose: begin.glucose, target: target, isf: isf)
        test.expectedDose = expected
        test.iobLine = expected.map { ISFTestEvaluator.iobLine(expectedDose: $0) }
        test.iobHandling = ISFTestEvaluator.iobHandling(
            for: ISFTestEvaluator.iobDecision(iob: begin.iob, expectedDose: expected),
            chosen: begin.iobChoice
        )
        test.plannedPhase = ISFTestEvaluator.startPhase(glucose: begin.glucose, target: target)
        // The schedule as it is at Begin, over every hour settling, a bolus in the time allowed and its 4 hours could
        // reach, so an ISF edited before the bolus is found doesn't become what the test ran on.
        test.coveredEntries = ISFTestEvaluator.coveredAtBegin(reads.isfEntries(), startedAt: now)
        // The target schedule over the same hours, so the dose and the result use the target in force at the time.
        test.targetEntries = ISFTestEvaluator.coveredAtBegin(reads.targetEntries(), startedAt: now)
        // The docs' dose is rounded up to it before a low's bolus is held against it.
        test.bolusIncrement = settingsManager.preferences.bolusIncrement

        // Saved first, so a crash from here on leaves a test that can be finished: one that never reached Basal Testing
        // ends as interrupted. Nothing from a test before it is shown with it.
        publish {
            $0.settling = nil
            $0.doseIOB = nil
        }
        save(test)
        // Register the way back before changing anything, so an interruption can't leave the user in Basal Testing with
        // nobody watching it.
        guard let session = service?.begin(
            kind: .isf,
            expiresIn: ISFTest.Config.settleAllowance + ISFTest.Config.doseAllowance + ISFTest.Config.docsWait
                + ISFTest.Config.expiryGrace,
            restoring: [.dosingMode(testMode: .basalTesting, previous: previous)],
            settles: true
        ) else {
            // What was there before stays.
            if let shown = prior.test {
                storage.save(shown, as: ISFTest.Config.statePath)
            } else {
                storage.remove(ISFTest.Config.statePath)
            }
            subject.send(prior)
            return .otherTestRunning
        }
        // Saved again with its session, before the mode changes, so the service's record of ending it can be matched to
        // this test.
        test.sessionID = session.id
        save(test)
        settingsManager.settings.dosingMode = .basalTesting
        // "Your result is ready" from the test before would open this one.
        notifier.withdraw(.isf, .ended)
        debug(.settings, "ISFTestRunner: began the test, settling")
        return nil
    }

    // MARK: - Settle

    /// After the settling allowance, with insulin on board still over the line: count it and go on.
    @MainActor func countAndGoOn() {
        guard var current = state.test, current.phase == .settling, case .timeUp = state.settling?.decision else { return }
        current.iobHandling = .count
        save(current)
        Task { await check() }
    }

    // MARK: - Raise and dose

    /// The user took the tablets the Raise step counted. They are kept for the record, not logged as carbs, and the step
    /// then waits for glucose to level off. Without a count there is nothing to have taken; once they are marked taken,
    /// another tap does nothing.
    @MainActor func tabletsTaken(_ tablets: ISFTestTabletsTaken) {
        // `>= 1`, not `> 0`: swiftformat's isEmpty rule rewrites a `count > 0` to `isEmpty`, which this type doesn't have.
        guard var current = state.test, current.phase == .raising, current.tabletsTakenAt == nil, tablets.count >= 1
        else { return }
        current.tabletBrand = tablets.brand.rawValue
        // Added to tablets taken before going back from the Dose step, so the record holds all of them.
        current.tabletCarbs = (current.tabletCarbs ?? 0) + Decimal(tablets.count) * tablets.brand.carbsPerTablet
        current.tabletsTakenAt = Date()
        // What glucose has to rise above before the dose, so a reading from before they acted can't unlock it.
        current.tabletsGlucose = tablets.glucose
        save(current)
    }

    /// From the Raise step to the Dose step: Work Out the Dose, which the screen offers once glucose leveled off after the
    /// tablets, and Skip, Dose Now. The user is on the screen, so a notice that the Raise step waits on them is done
    /// with.
    @MainActor func moveToDose() {
        guard var current = state.test, current.phase == .raising else { return }
        current.phase = .dosing
        current.doseNoticeDue = nil
        save(current)
        notifier.withdraw(.isf, .step)
    }

    /// Back from the Dose step to the Raise step, which the screen offers only when the docs' formula gives no dose and
    /// tablets can raise glucose. Tablets already taken stay in the record.
    @MainActor func raiseFirst() {
        guard var current = state.test, current.phase == .dosing else { return }
        current.phase = .raising
        current.tabletsTakenAt = nil
        current.tabletsGlucose = nil
        current.doseNoticeDue = nil
        save(current)
    }

    // MARK: - Running

    /// Coalesced (`SettingsTestCheckCoalescer`): one runs at a time, and a call during one waits for it and for one more
    /// run, shared by every call made meanwhile, so a change that came in after the reads started is never missed.
    func check() async {
        await checks.run { await checkRunningTest() }
    }

    /// The test as it is now, unless it has finished or a finish has claimed it.
    private func runningTest(_ testID: UUID? = nil) async -> ISFTestState? {
        await MainActor.run {
            guard let test = state.test, test.phase != .finished, !isFinishing, testID == nil || test.id == testID
            else { return nil }
            return test
        }
    }

    /// While settling, sees whether the real test can start. Before the bolus, looks for it, then ends the test if the
    /// service ended it, Trio suspended insulin for a low, the time for the bolus or the 4 hours ran out, the dosing mode
    /// was changed, or something spoiled it. Raising, moves on to the dose once the tablets acted.
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

        if test.phase == .settling {
            await checkSettling(of: testID)
        }
        await shareBolusWindowStart(of: testID)
        // Insulin on board for a counted dose grows old between loops too.
        await refreshDoseIOB(of: testID)

        // Waiting, the bolus is known, so nothing below waits on reading it.
        var bolusesRead = true
        if let latest = state.test, latest.id == testID, latest.phase == .raising || latest.phase == .dosing {
            bolusesRead = await lookForTestBolus(of: testID)
        }
        // Settling may have ended, and the bolus may have moved it on to the 4 hours.
        guard let current = await runningTest(testID) else { return }

        // Counting insulin on board needs it at the bolus; a tick that couldn't read it tries again.
        if current.phase == .waiting, ISFTestEvaluator.iobAtBolusUnread(of: current), let bolusAt = current.bolusAt,
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
                let ending = ISFTestEvaluator.ending(for: .bolusCancelled, doseDeadline: current.noBolusDeadline)
                await finish(for: testID, reason: ending.reason, at: ending.at, note: ending.note)
                return
            case let .units(units):
                if units != current.bolusUnits {
                    await updateBolusUnits(units, of: testID)
                }
            case .unread:
                break
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
            warning(.settings, "ISFTestRunner: couldn't read temp basals to check for a low", error: error)
            suspend = .unreadable
        }

        // Read together on the main actor, where the service keeps its record before it brings the usual mode back, so a
        // mode changed by the service is never seen without the reason.
        let (mode, serviceEnd) = await MainActor.run { (settingsManager.settings.dosingMode, service?.lastEnd()) }
        let found = ISFTestEvaluator.runningCheck(
            phase: current.phase,
            sessionID: current.sessionID,
            serviceEnd: serviceEnd,
            suspend: suspend,
            now: now,
            doseDeadline: current.noBolusDeadline,
            // Both always while waiting: without the bolus time a low before the dose can't be told from one after.
            bolusAt: current.bolusAt,
            plannedEnd: current.plannedEnd,
            mode: mode
        )
        if let check = ISFTestEvaluator.decidable(found, bolusesRead: bolusesRead) {
            let ending = ISFTestEvaluator.ending(for: check, doseDeadline: current.noBolusDeadline)
            await finish(for: testID, reason: ending.reason, at: ending.at, note: ending.note)
            return
        } else if case .found = await wasInterrupted(current, until: end) {
            await finish(for: testID, reason: .interrupted)
            return
        }
        // Only once nothing ended the test, so a step notice never comes just before it ends.
        await postDueDoseNotice(of: testID)
        await moveOnIfTabletsActed(of: testID)
    }

    /// Reads Trio's determinations and the boluses since Begin, and insulin on board now, and ends settling when
    /// `ISFTestEvaluator.settling` says it has: the real test starts now, on the step the glucose now leads to
    /// (`phaseAfterSettling`), and the service learns where the bolus window starts. A notice says the Raise step is
    /// ready; the Dose step's waits until the step shows a dose (`postDueDoseNotice`). Determinations that can't be read
    /// leave it settling.
    private func checkSettling(of testID: UUID) async {
        guard let test = state.test, test.id == testID, test.phase == .settling else { return }
        let now = Date()
        let determinations: [Date]
        do {
            determinations = try await reads.fetchDeterminations(from: test.startedAt, to: now).map(\.date)
        } catch {
            warning(.settings, "ISFTestRunner: couldn't read Trio's determinations to settle the test", error: error)
            return
        }
        let boluses: [ISFTestBolus]?
        do {
            boluses = try await reads.fetchBoluses(from: test.startedAt, to: now)
        } catch {
            warning(.settings, "ISFTestRunner: couldn't read boluses given while the test settles", error: error)
            boluses = nil
        }
        // Which of them the pump history flags as SMBs, to say which Trio gave. Unread, none is called one.
        let smbs = try? await reads.fetchSMBs(since: test.startedAt, until: now)
        // The CGM readings since Begin, of which those after Trio's first loop in Basal Testing count, and whose newest 3
        // give the glucose settling moves on from. Unread, settling waits for a tick that reads them.
        let readings: [BasalTestReading]
        do {
            readings = try await reads.fetchGlucose(from: test.startedAt, to: now)
        } catch {
            warning(.settings, "ISFTestRunner: couldn't read glucose to settle the test", error: error)
            return
        }
        let readingDates = readings.map(\.date)
        let iob = reads.currentIOB()
        // A temp basal still running at the end of settling would change the basal the test runs on. Unread, it doesn't
        // hold settling up.
        let tempBasalRunning = reads.pumpDelivery().map { $0 == .tempBasal }

        await MainActor.run {
            guard var latest = state.test, latest.id == testID, latest.phase == .settling, !isFinishing else { return }
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
            // A test whose session the service ended, or ran out of time, is ended by the running check instead.
            guard decision == .settled,
                  ISFTestEvaluator.canSettle(
                      sessionID: latest.sessionID,
                      activeSessionID: service?.activeSession?.id,
                      mode: settingsManager.settings.dosingMode,
                      now: Date(),
                      noBolusDeadline: latest.noBolusDeadline
                  )
            else { return }
            // A bolus from here on can be the test's; one before it was given while settling.
            let settledAt = Date()
            let glucose = ISFTestEvaluator.doseGlucose(ISFTestDoseInputs(
                readings: readings.sorted { $0.date > $1.date },
                direction: nil,
                iob: iob,
                doseIOB: nil,
                cob: nil,
                increment: 0,
                now: settledAt
            ))
            latest.settledAt = settledAt
            latest.phase = ISFTestEvaluator.phaseAfterSettling(latest, glucose: glucose, at: settledAt)
            // The Dose step's notice waits for the end of this check, which reads what the step offers.
            latest.doseNoticeDue = latest.phase == .dosing ? .settled : nil
            save(latest)
            service?.setBolusWindowStart(kind: .isf, at: settledAt)
            publish { $0.settling = nil }
            debug(.settings, "ISFTestRunner: settled, moving on to \(latest.phase.rawValue)")
            // In the same main-actor step as the save, so a Cancel Test can't come between them and leave it behind.
            if latest.phase == .raising {
                post(.isfStep(.settledToRaise))
            }
        }
    }

    /// Makes sure the service knows where the bolus window starts, for a test past settling whose session doesn't: one
    /// begun before settling was kept, whose window starts at Start, or one the app closed on as it settled.
    private func shareBolusWindowStart(of testID: UUID) async {
        await MainActor.run {
            guard let test = state.test, test.id == testID, test.phase != .finished, let start = test.bolusWindowStart,
                  let service, let session = service.activeSession, session.kind == .isf, session.id == test.sessionID,
                  session.bolusWindowStart == nil
            else { return }
            service.setBolusWindowStart(kind: .isf, at: start)
        }
    }

    /// Reads insulin on board for a counted dose, raising or dosing in a test that counts it, from Trio's newest
    /// determination of the last 12 minutes. Cleared otherwise, and when it can't be read.
    private func refreshDoseIOB(of testID: UUID) async {
        guard let test = state.test, test.id == testID, test.iobHandling == .count,
              test.phase == .raising || test.phase == .dosing
        else {
            await MainActor.run { publish { $0.doseIOB = nil } }
            return
        }
        let iob: Decimal?
        do {
            iob = try await reads.fetchDoseIOB(at: Date())
        } catch {
            warning(.settings, "ISFTestRunner: couldn't read insulin on board for the dose", error: error)
            iob = nil
        }
        await MainActor.run {
            // Not onto a test that moved on, or that a finish has claimed and cleared, while it was read.
            guard let latest = state.test, latest.id == testID, latest.iobHandling == .count,
                  latest.phase == .raising || latest.phase == .dosing, !isFinishing
            else { return }
            publish { $0.doseIOB = iob }
        }
    }

    /// Insulin on board just before the bolus, from Trio's determinations in the 12 minutes before it
    /// (`ISFTestEvaluator.iobAtBolus`). Nil when there is none that recent, or they couldn't be read.
    func readIOB(before bolusAt: Date, of test: ISFTestState) async -> Decimal? {
        do {
            let oldest = bolusAt.addingTimeInterval(-BasalTest.Config.endReadingMaxAge - ISFTest.Config.savedDateTolerance)
            let determinations = try await reads.fetchDeterminations(from: max(test.startedAt, oldest), to: bolusAt)
            return ISFTestEvaluator.iobAtBolus(determinations, bolusAt: bolusAt)
        } catch {
            warning(.settings, "ISFTestRunner: couldn't read insulin on board at the bolus", error: error)
            return nil
        }
    }

    /// Insulin on board Trio reports still left at the planned end, from its determinations in the 12 minutes up to it
    /// (`ISFTestEvaluator.iobAtEnd`), the same source and age as at the bolus. Nil when there is none that recent, or they
    /// couldn't be read.
    func readIOB(atEnd plannedEnd: Date, of test: ISFTestState) async -> Decimal? {
        do {
            let oldest = plannedEnd.addingTimeInterval(-BasalTest.Config.endReadingMaxAge - ISFTest.Config.savedDateTolerance)
            let determinations = try await reads.fetchDeterminations(
                from: max(test.startedAt, oldest),
                to: plannedEnd.addingTimeInterval(ISFTest.Config.savedDateTolerance)
            )
            return ISFTestEvaluator.iobAtEnd(determinations, plannedEnd: plannedEnd)
        } catch {
            warning(.settings, "ISFTestRunner: couldn't read insulin on board at the end of the 4 hours", error: error)
            return nil
        }
    }

    /// Saves the insulin on board at the bolus, for a test that counts it.
    private func updateIOBAtBolus(_ iob: Decimal, of testID: UUID) async {
        await MainActor.run {
            guard var latest = state.test, latest.id == testID, latest.phase == .waiting, !isFinishing else { return }
            latest.iobAtBolus = iob
            save(latest)
        }
    }

    /// Finds the test bolus, the first bolus from the end of settling to the deadline from any source, and moves the test
    /// on to the 4 hours with the bolus, the glucose it was given at, the ISF entries the 4 hours cover and, in a test that
    /// counts it, the insulin on board just before it. A bolus given while a condition the Dose step holds the dose for
    /// didn't hold, or with a start glucose that wasn't read or wasn't above the target
    /// (`ISFTestEvaluator.failedBolusCondition`), ends the test with no verdict: the ending is saved with the bolus first
    /// (`pendingEnd`), then finished. Returns whether the boluses could be read and the bolus found judged, so a tick that
    /// couldn't doesn't decide there was none, or that a low after the bolus came before it.
    private func lookForTestBolus(of testID: UUID) async -> Bool {
        guard let test = state.test, test.id == testID, let windowStart = test.bolusWindowStart else { return true }
        let bolus: ISFTestBolus?
        do {
            // Read a little past the deadline, which is saved to the millisecond, so a bolus at the same moment as it
            // reaches `testBolus`, which counts it as inside. One before the end of settling isn't the test's.
            let boluses = try await reads.fetchBoluses(
                from: windowStart,
                to: test.doseDeadline.addingTimeInterval(ISFTest.Config.savedDateTolerance)
            )
            bolus = ISFTestEvaluator.testBolus(boluses, since: windowStart, deadline: test.doseDeadline)
        } catch {
            warning(.settings, "ISFTestRunner: couldn't read boluses to look for the test bolus", error: error)
            return false
        }
        guard let bolus else { return true }

        // The mean of the last 3 readings at or before the bolus. None recent enough is unread, and the conditions below
        // end the test for it (`failedBolusCondition`); a read that failed decides nothing, and the next check reads again.
        let startGlucose: Int?
        do {
            let readings = try await reads.fetchGlucose(
                from: bolus.date.addingTimeInterval(-Self.startReadingsLookback),
                to: bolus.date
            )
            startGlucose = BasalTestEvaluator.endGlucose(from: readings, endingAt: bolus.date)
        } catch {
            warning(
                .settings,
                "ISFTestRunner: couldn't read glucose at the bolus, reading it again on the next check",
                error: error
            )
            return false
        }
        // Only a test that counts it needs it; if it can't be read now, the next tick and finishing try again.
        let iobAtBolus = test.iobHandling == .count ? await readIOB(before: bolus.date, of: test) : nil

        // What the Dose step holds the dose for, as it was at the bolus, which can come from Home, the pump or the Watch
        // as well as from Open Treatments. As for the start glucose, a read that throws decides nothing and the next
        // check reads again; only one that works and finds nothing recent enough leaves its condition unread, which ends
        // the test.
        let conditionReadings: [BasalTestReading]
        let arrow: ISFTestArrowReading?
        let atBolusDeterminations: [ISFTestDetermination]
        do {
            if let takenAt = test.tabletsTakenAt {
                conditionReadings = try await reads.fetchGlucose(
                    from: min(takenAt, bolus.date).addingTimeInterval(-Self.startReadingsLookback),
                    to: bolus.date.addingTimeInterval(ISFTest.Config.savedDateTolerance)
                )
            } else {
                conditionReadings = []
            }
            arrow = try await reads.fetchArrowReading(atOrBefore: bolus.date)
            atBolusDeterminations = try await reads.fetchDeterminations(
                from: bolus.date.addingTimeInterval(-BasalTest.Config.endReadingMaxAge - ISFTest.Config.savedDateTolerance),
                to: bolus.date.addingTimeInterval(ISFTest.Config.savedDateTolerance)
            )
        } catch {
            warning(
                .settings,
                "ISFTestRunner: couldn't read what the bolus is judged on, reading it again on the next check",
                error: error
            )
            return false
        }

        // On the main actor, from the state as it is now, so a tap on the Raise or Dose step in the meantime isn't lost
        // and a test discarded or finished in the meantime isn't brought back.
        let judged: (moved: Bool, failed: ISFTestBolusCondition?) = await MainActor.run {
            guard let shown = state.test, shown.id == testID, !isFinishing, shown.phase == .raising || shown.phase == .dosing
            else { return (false, nil) }
            // The ISF and target the result uses become those in force at the bolus, from the schedules saved at Begin, so
            // an ISF edited since doesn't become what the test ran on, and the ISF schedule narrows to its 4 hours.
            var latest = ISFTestEvaluator.atBolus(shown, bolusAt: bolus.date)
            latest.bolusAt = bolus.date
            // The dose is given: its notice is no longer owed.
            latest.doseNoticeDue = nil
            // A bolus with no amount recorded still started the test, but there is no amount to judge it by.
            latest.bolusUnits = bolus.units > 0 ? bolus.units : nil
            latest.startGlucose = startGlucose
            latest.iobAtBolus = iobAtBolus
            // Judged from the bolus moment: the start glucose, and the target and ISF in force then, which give the docs'
            // dose at the bolus and the line for insulin on board.
            let failed = ISFTestEvaluator.failedBolusCondition(
                bolusAt: bolus.date,
                startGlucose: startGlucose,
                target: latest.target,
                isf: latest.isf,
                readings: conditionReadings,
                tabletsTakenAt: latest.tabletsTakenAt,
                tabletsGlucose: latest.tabletsGlucose,
                arrow: arrow,
                determinations: atBolusDeterminations,
                handling: latest.iobHandling
            )
            if let failed {
                // Saved with the bolus before anything else, on the step it was on, so a relaunch finishes this ending.
                latest.pendingEnd = ISFTestPendingEnd(
                    reason: .interrupted,
                    at: SettingsTestEndRule.endTime(
                        endedAt: nil,
                        limit: latest.plannedEnd ?? latest.noBolusDeadline,
                        now: Date()
                    ),
                    note: failed.note,
                    byUser: false
                )
            } else {
                latest.phase = .waiting
            }
            save(latest)
            if failed == nil {
                debug(.settings, "ISFTestRunner: found the test bolus, waiting out the 4 hours")
                // With the save, as the step notices are posted with theirs.
                notifier.withdraw(.isf, .step)
            }
            return (true, failed)
        }
        guard judged.moved else { return true }
        // A bolus the Dose step would have held: the test ends with no verdict, and the usual mode comes back.
        if let failed = judged.failed {
            debug(.settings, "ISFTestRunner: the test bolus came while a condition failed (\(failed)), ending the test")
            await finish(for: testID, reason: .interrupted, note: failed.note)
        }
        return true
    }

    /// The bolus rows around the saved bolus time, read again, so the test bolus's amount is the one the pump history holds
    /// now. Any bolus row, because the history can flag the test bolus as an SMB when it writes the amount delivered. Nil
    /// when they couldn't be read.
    func rereadTestBolus(at bolusAt: Date) async -> [ISFTestBolusRecord]? {
        do {
            return try await reads.fetchBolusRecords(
                from: bolusAt.addingTimeInterval(-ISFTest.Config.savedDateTolerance),
                to: bolusAt.addingTimeInterval(ISFTest.Config.savedDateTolerance)
            )
        } catch {
            warning(.settings, "ISFTestRunner: couldn't read the test bolus again", error: error)
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

    /// On the Dose step with its notice still owed (`ISFTestState.doseNoticeDue`): reads what the step offers, as the
    /// screen does, and posts "ISF Dose Ready" once it shows a dose. After settling, a step that offers more tablets first
    /// gets "ISF Test Settled", once. A step with neither keeps the notice owed, since what holds the dose back (a
    /// reading, insulin or carbs on board, glucose under the target) can change by itself (`ISFTestEvaluator.doseNotice`).
    private func postDueDoseNotice(of testID: UUID) async {
        guard let test = state.test, test.id == testID, test.phase == .dosing, test.doseNoticeDue != nil else { return }
        let readings: [BasalTestReading]
        do {
            readings = try await reads.fetchRecentGlucose(minutes: Self.recentReadingsMinutes)
        } catch {
            warning(
                .settings,
                "ISFTestRunner: couldn't read glucose to see whether the Dose step shows a dose",
                error: error
            )
            return
        }
        let iob = reads.currentIOB()
        // From a determination at most 12 minutes old; none, or a read that failed, is unread, not none.
        let cob = (try? await reads.currentCOB()) ?? nil
        await MainActor.run {
            guard var latest = state.test, latest.id == testID, latest.phase == .dosing, latest.pendingEnd == nil,
                  !isFinishing, let due = latest.doseNoticeDue
            else { return }
            let inputs = ISFTestDoseInputs(
                readings: readings,
                direction: nil,
                iob: iob,
                doseIOB: state.doseIOB,
                cob: cob,
                increment: settingsManager.preferences.bolusIncrement,
                now: Date()
            )
            let next = ISFTestEvaluator.doseNotice(due: due, offer: ISFTestEvaluator.doseStepOffer(of: latest, inputs))
            guard let notice = next.post else { return }
            latest.doseNoticeDue = next.due
            save(latest)
            debug(.settings, "ISFTestRunner: the Dose step offers \(notice == .settledToRaise ? "more tablets" : "a dose")")
            // In the same main-actor step as the save, so a Cancel Test can't come between them and leave it behind.
            post(.isfStep(notice))
        }
    }

    /// Raising with the tablets taken: moves on to the Dose step by itself once they acted and glucose leveled off, the
    /// same gate as Work Out the Dose (`ISFTestEvaluator.canDose`), and says so once the Dose step shows a dose
    /// (`ISFTestEvaluator.doseNotice`): now, or later, when it does (`postDueDoseNotice`). A step that offers more tablets
    /// gets no notice of its own.
    private func moveOnIfTabletsActed(of testID: UUID) async {
        guard let test = state.test, test.id == testID, test.phase == .raising, test.tabletsTakenAt != nil else { return }
        let readings: [BasalTestReading]
        let direction: BloodGlucose.Direction?
        do {
            readings = try await reads.fetchRecentGlucose(minutes: Self.recentReadingsMinutes)
            direction = try await reads.fetchNewestDirection()
        } catch {
            warning(.settings, "ISFTestRunner: couldn't read glucose to see whether the tablets acted", error: error)
            return
        }
        let iob = reads.currentIOB()
        // From a determination at most 12 minutes old; none, or a read that failed, is unread, not none.
        let cob = (try? await reads.currentCOB()) ?? nil
        await MainActor.run {
            guard var latest = state.test, latest.id == testID, latest.phase == .raising, !isFinishing else { return }
            let inputs = ISFTestDoseInputs(
                readings: readings,
                direction: direction,
                iob: iob,
                doseIOB: state.doseIOB,
                cob: cob,
                increment: settingsManager.preferences.bolusIncrement,
                now: Date()
            )
            guard ISFTestEvaluator.canDose(of: latest, inputs) else { return }
            latest.phase = .dosing
            let next = ISFTestEvaluator.doseNotice(
                due: .tabletsActed,
                offer: ISFTestEvaluator.doseStepOffer(of: latest, inputs)
            )
            latest.doseNoticeDue = next.due
            save(latest)
            debug(.settings, "ISFTestRunner: the tablets acted, moving on to the dose")
            // In the same main-actor step as the save, so a Cancel Test can't come between them and leave it behind.
            if let notice = next.post {
                post(.isfStep(notice))
            }
        }
    }
}
