import Combine
import Foundation
import LoopKit
import Swinject
import Testing

@testable import Trio

// MARK: - Basal test evaluation

@Suite("Basal test evaluator") struct BasalTestEvaluatorTests {
    private let hour: TimeInterval = 3600

    /// Start 100 with ISF 50 and a scheduled 0.8 U/h: one docs step (10%) over 4 hours moves glucose 16 mg/dL.
    private func evaluate(
        start: Int = 100,
        end: Int?,
        elapsedHours: Double = 4,
        reason: BasalTestEndReason = .completed,
        interference: String? = nil,
        isf: Decimal? = 50,
        scheduledBasal: Decimal? = 0.8,
        step: Decimal = BasalTest.Config.docsSmallestStep
    ) -> BasalTestEvaluator.Evaluation {
        BasalTestEvaluator.evaluate(
            startGlucose: start,
            endGlucose: end,
            elapsed: elapsedHours * hour,
            reason: reason,
            interference: interference,
            isf: isf,
            scheduledBasal: scheduledBasal,
            step: step
        )
    }

    @Test("The docs' smallest basal change is 10% and a fast runs at least 4 hours") func docsNumbers() {
        #expect(BasalTest.Config.docsSmallestStep == 0.10)
        #expect(BasalTest.Config.docsShortestFast == 4 * hour)
    }

    @Test("A rise worth more than one docs step says basal is too low") func risingPastStep() {
        let result = evaluate(end: 130)
        #expect(result.outcome == .rising)
        #expect(result.direction == .increase)
        #expect(result.netChange == 30)
        // 30 mg/dL ÷ ISF 50 = 0.6 U, over 4 hours = 0.15 U/h, which is 18.75% of 0.8 U/h.
        #expect(result.ratePerHour == 0.15)
        #expect(result.share == 0.1875)
    }

    @Test("A change smaller than one docs step is steady") func steadyUnderStep() {
        let result = evaluate(end: 112)
        #expect(result.outcome == .steady)
        #expect(result.direction == .keep)
        #expect(result.netChange == 12)
        #expect(result.ratePerHour == 0.06)
        #expect(result.share == 0.075)
    }

    @Test("A fall worth more than one docs step says basal is too high") func fallingPastStep() {
        let result = evaluate(end: 70)
        #expect(result.outcome == .falling)
        #expect(result.direction == .decrease)
        #expect(result.netChange == -30)
        #expect(result.ratePerHour == -0.15)
        #expect(result.share == -0.1875)
    }

    @Test("A change of exactly one docs step is past it, on either side") func stepBoundary() {
        // 16 mg/dL is the band, so 115 is just inside it and 116 is exactly one step.
        #expect(evaluate(end: 115).outcome == .steady)
        #expect(evaluate(end: 85).outcome == .steady)
        let up = evaluate(end: 116)
        #expect(up.share == 0.1)
        #expect(up.outcome == .rising)
        let down = evaluate(end: 84)
        #expect(down.share == -0.1)
        #expect(down.outcome == .falling)
    }

    @Test("A different step moves the line") func stepParameter() {
        #expect(evaluate(end: 130, step: 0.2).outcome == .steady)
        #expect(evaluate(end: 130, step: 0.05).outcome == .rising)
    }

    @Test("A longer fast spreads the same change over more hours") func longerFast() {
        // 30 mg/dL over 6 hours is 0.1 U/h, 12.5% of the scheduled basal.
        let result = evaluate(end: 130, elapsedHours: 6)
        #expect(result.ratePerHour == 0.1)
        #expect(result.share == 0.125)
        #expect(result.outcome == .rising)
    }

    @Test("Ending before the docs' shortest fast is inconclusive, however far glucose went") func shortFastIsInconclusive() {
        let result = evaluate(end: 140, elapsedHours: 3, reason: .endedEarly)
        #expect(result.outcome == .inconclusive)
        #expect(result.direction == nil)
        // The working is still there for the result screen.
        #expect(result.ratePerHour != nil)
        #expect(result.share != nil)
    }

    @Test("A low ends the test and counts as a fall, however soon it came") func lowStillCounts() {
        let result = evaluate(start: 95, end: 68, elapsedHours: 2, reason: .low)
        #expect(result.outcome == .falling)
        #expect(result.direction == .decrease)
        #expect(evaluate(start: 95, end: 68, elapsedHours: 0, reason: .low).outcome == .falling)
        #expect(evaluate(start: 95, end: 68, elapsedHours: 0, reason: .low).ratePerHour == nil)
    }

    @Test("Without a usable ISF or scheduled basal there is no result") func zeroBasalIsInconclusive() {
        let noBasal = evaluate(end: 130, scheduledBasal: 0)
        #expect(noBasal.outcome == .inconclusive)
        #expect(noBasal.direction == nil)
        // The rate only needs the ISF.
        #expect(noBasal.ratePerHour == 0.15)
        #expect(noBasal.share == nil)

        let noISF = evaluate(end: 130, isf: nil)
        #expect(noISF.outcome == .inconclusive)
        #expect(noISF.ratePerHour == nil)
        #expect(noISF.share == nil)

        #expect(evaluate(end: 130, isf: 0).outcome == .inconclusive)
        #expect(evaluate(end: 130, scheduledBasal: nil).outcome == .inconclusive)
        #expect(evaluate(end: 130, scheduledBasal: -0.8).outcome == .inconclusive)
    }

    @Test(
        "A fast whose pump history couldn't be checked for a low says nothing, however far glucose went"
    ) func uncheckedIsInconclusive() {
        for end in [60, 100, 140] {
            let result = evaluate(end: end, reason: .unchecked)
            #expect(result.outcome == .inconclusive, "\(end)")
            #expect(result.direction == nil, "\(end)")
        }
        // Something that spoiled it still says so.
        #expect(evaluate(end: 140, reason: .unchecked, interference: "Carbs").outcome == .invalid)
    }

    @Test("Carbs or a bolus during the fast invalidate it, whatever glucose did") func interrupted() {
        let result = evaluate(end: 200, interference: "Carbs were logged during the fast.")
        #expect(result.outcome == .invalid)
        #expect(result.direction == nil)
        #expect(evaluate(end: 200, reason: .interrupted).outcome == .invalid)
        // Invalid beats a low, and a short fast.
        #expect(evaluate(end: 60, reason: .low, interference: "Carbs").outcome == .invalid)
        #expect(evaluate(end: 200, elapsedHours: 1, reason: .interrupted).outcome == .invalid)
    }

    @Test("The steady band is what one docs step moves glucose over the fast") func bandForFast() {
        #expect(BasalTestEvaluator.steadyBand(isf: 50, scheduledBasal: 0.8, hours: 4) == 16)
        // 45 × 0.75 × 0.1 × 6 = 20.25
        #expect(BasalTestEvaluator.steadyBand(isf: 45, scheduledBasal: 0.75, hours: 6) == 20)
        // 52 × 0.75 × 0.1 × 4 = 15.6
        #expect(BasalTestEvaluator.steadyBand(isf: 52, scheduledBasal: 0.75, hours: 4) == 16)
        #expect(BasalTestEvaluator.steadyBand(isf: 50, scheduledBasal: 0.8, hours: 4, step: 0.2) == 32)
    }

    @Test("A change at the edge of the band agrees with the evaluation") func bandMatchesEvaluation() {
        let band = BasalTestEvaluator.steadyBand(isf: 50, scheduledBasal: 0.8, hours: 4)
        #expect(evaluate(end: 100 + band - 1).outcome == .steady)
        #expect(evaluate(end: 100 + band).outcome == .rising)
    }

    @Test("Only steady, rising and falling say anything about basal") func conclusive() {
        #expect(BasalTestOutcome.steady.isConclusive)
        #expect(BasalTestOutcome.rising.isConclusive)
        #expect(BasalTestOutcome.falling.isConclusive)
        #expect(!BasalTestOutcome.inconclusive.isConclusive)
        #expect(!BasalTestOutcome.invalid.isConclusive)
    }

    @Test("End glucose averages the last three readings") func endGlucoseAverages() {
        let now = Date()
        let readings = (0 ..< 6).map { BasalTestReading(date: now.addingTimeInterval(Double($0) * 300), glucose: 100 + $0 * 10) }
        // Last three are 130, 140, 150.
        #expect(BasalTestEvaluator.endGlucose(from: readings) == 140)
    }

    @Test("There is no end glucose when the CGM recorded nothing") func noEndGlucoseWithoutReadings() {
        #expect(BasalTestEvaluator.endGlucose(from: []) == nil)
    }

    @Test("A fast with no readings is inconclusive, never steady") func noReadingsIsInconclusive() {
        let result = evaluate(end: nil)
        #expect(result.outcome == .inconclusive)
        #expect(result.direction == nil)
        #expect(result.netChange == 0)
        #expect(result.ratePerHour == nil)
        #expect(result.share == nil)

        // Whatever the length: a full fast with no readings still has nothing to compare.
        #expect(evaluate(end: nil, elapsedHours: 6).outcome == .inconclusive)

        // An interruption and a low still win, in the usual order.
        #expect(evaluate(end: nil, interference: "Carbs were logged during the fast.").outcome == .invalid)
        #expect(evaluate(end: nil, reason: .interrupted).outcome == .invalid)
        let low = evaluate(end: nil, elapsedHours: 1, reason: .low)
        #expect(low.outcome == .falling)
        #expect(low.direction == .decrease)
        #expect(low.ratePerHour == nil)
        #expect(low.share == nil)
    }

    @Test(
        "A share shows as a whole percent rounded toward zero, so one under the docs' step never reads as the step"
    ) func wholePercentTowardZero() {
        #expect(BasalTestEvaluator.wholePercent(0.0999) == 9)
        #expect(BasalTestEvaluator.wholePercent(-0.0999) == -9)
        #expect(BasalTestEvaluator.wholePercent(0.1875) == 18)
        #expect(BasalTestEvaluator.wholePercent(-0.1875) == -18)
        #expect(BasalTestEvaluator.wholePercent(0.10) == 10)
        #expect(BasalTestEvaluator.wholePercent(-0.10) == -10)
        #expect(BasalTestEvaluator.wholePercent(0) == 0)
        #expect(BasalTestEvaluator.wholePercent(0.004) == 0)
    }

    @Test("Insulin on board is positive, negative or none at the two decimals shown") func iobSign() {
        #expect(BasalTestIOB(0.3) == .positive)
        #expect(BasalTestIOB(-0.3) == .negative)
        #expect(BasalTestIOB(0) == .none)
        // These all show as 0.00, so they say nothing either way.
        #expect(BasalTestIOB(0.004) == .none)
        #expect(BasalTestIOB(-0.004) == .none)
        #expect(BasalTestIOB(0.005) == .none)
        #expect(BasalTestIOB(-0.005) == .none)
        #expect(BasalTestIOB(0.006) == .positive)
        #expect(BasalTestIOB(-0.006) == .negative)
    }

    @Test("Time blocks follow the hour a test starts") func timeBlocks() {
        let calendar = Calendar(identifier: .gregorian)
        func block(_ hour: Int) -> String {
            let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: hour))!
            return BasalTestEvaluator.timeBlock(for: date, calendar: calendar)
        }
        #expect(block(2) == String(localized: "Overnight"))
        #expect(block(6) == String(localized: "Morning"))
        #expect(block(12) == String(localized: "Afternoon"))
        #expect(block(19) == String(localized: "Evening"))
        #expect(block(23) == String(localized: "Overnight"))
    }

    @Test("State survives a round trip through JSON") func stateRoundTrip() throws {
        var state = BasalTestState(
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            plannedDuration: 4 * hour,
            startGlucose: 105,
            startIOB: 0.1,
            previousMode: .closed,
            timeBlock: "Overnight"
        )
        state.phase = .finished
        state.endReason = .completed
        state.outcome = .steady
        state.readings = [BasalTestReading(date: Date(timeIntervalSince1970: 1_000_300), glucose: 108)]

        let data = try JSONCoding.encoder.encode(state)
        let decoded = try JSONCoding.decoder.decode(BasalTestState.self, from: data)
        #expect(decoded == state)
        #expect(decoded.plannedEnd == state.startedAt.addingTimeInterval(4 * hour))
    }

    // MARK: What the test runs on

    private func scheduleEntry(_ start: Int, _ end: Int, _ value: Decimal) -> SettingsTestScheduleEntry {
        SettingsTestScheduleEntry(startMinutes: start, endMinutes: end, value: value)
    }

    /// 00:00 to 06:00 at 0.8, 06:00 to 22:00 at 1.0, 22:00 to midnight at 0.7.
    private var basalSchedule: [SettingsTestScheduleEntry] {
        [scheduleEntry(0, 360, 0.8), scheduleEntry(360, 1320, 1.0), scheduleEntry(1320, 1440, 0.7)]
    }

    private func sensitivities(
        _ values: [(offset: Int, value: Decimal)],
        units: GlucoseUnits = .mgdL
    ) -> InsulinSensitivities {
        InsulinSensitivities(
            units: units,
            userPreferredUnits: units,
            sensitivities: values.map {
                InsulinSensitivityEntry(sensitivity: $0.value, offset: $0.offset, start: "\($0.offset / 60):00:00")
            }
        )
    }

    /// A test started at 04:00 that planned four hours, with the schedule it covered.
    private func runningTest(covered: [SettingsTestScheduleEntry]?, scheduledBasal: Decimal?) -> BasalTestState {
        var state = BasalTestState(
            startedAt: at(4),
            plannedDuration: 4 * hour,
            startGlucose: 100,
            startIOB: 0,
            previousMode: .closed,
            timeBlock: "Morning"
        )
        state.coveredEntries = covered
        state.scheduledBasal = scheduledBasal
        return state
    }

    @Test("State saved before the ISF and schedule were kept decodes with none and gives no result") func decodesOldState() throws {
        let json = """
        {
          "id": "6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D",
          "phase": "finished",
          "startedAt": "2026-10-25T02:00:00Z",
          "plannedDuration": 14400,
          "startGlucose": 100,
          "startIOB": 0.1,
          "previousMode": "closed",
          "timeBlock": "Overnight",
          "endedAt": "2026-10-25T06:00:00Z",
          "endReason": "completed",
          "endGlucose": 135,
          "readings": [],
          "outcome": "inconclusive"
        }
        """
        let state = try JSONCoding.decoder.decode(BasalTestState.self, from: Data(json.utf8))
        #expect(state.isf == nil)
        #expect(state.scheduledBasal == nil)
        #expect(state.coveredEntries == nil)
        #expect(state.sessionID == nil)
        #expect(state.endGlucose == 135)

        let evaluation = BasalTestEvaluator.evaluate(
            startGlucose: state.startGlucose,
            endGlucose: 135,
            elapsed: 4 * hour,
            reason: .completed,
            interference: nil,
            isf: state.isf,
            scheduledBasal: BasalTestEvaluator.scheduledBasal(for: state, endingAt: state.plannedEnd, calendar: utc)
        )
        #expect(evaluation.outcome == .inconclusive)
        #expect(evaluation.share == nil)
    }

    @Test("ISF, scheduled basal and covered entries survive a round trip through JSON") func stateWithScheduleRoundTrip() throws {
        var state = runningTest(covered: [scheduleEntry(0, 360, 0.8), scheduleEntry(360, 1320, 1.0)], scheduledBasal: 0.9)
        state.isf = 52.5
        state.sessionID = UUID()
        let decoded = try JSONCoding.decoder.decode(BasalTestState.self, from: JSONCoding.encoder.encode(state))
        #expect(decoded == state)
        #expect(decoded.sessionID == state.sessionID)
        #expect(decoded.isf == 52.5)
        #expect(decoded.scheduledBasal == 0.9)
        #expect(decoded.coveredEntries == state.coveredEntries)
    }

    @Test("The ISF is the entry that started most recently, and a new one takes over on its minute") func isfEntryInForce() {
        let profile = sensitivities([(0, 50), (360, 45), (1320, 55)])
        func isf(_ hour: Int, _ minute: Int = 0) -> Decimal? {
            BasalTestEvaluator.isf(in: profile, at: at(hour, minute), calendar: utc)
        }
        #expect(isf(0) == 50)
        #expect(isf(5, 59) == 50)
        #expect(isf(6) == 45)
        #expect(isf(21, 59) == 45)
        #expect(isf(22) == 55)
        #expect(isf(23, 59) == 55)
    }

    @Test("Entries can come in any order") func isfUnsortedEntries() {
        let profile = sensitivities([(1320, 55), (0, 50), (360, 45)])
        #expect(BasalTestEvaluator.isf(in: profile, at: at(12), calendar: utc) == 45)
    }

    @Test("There is no ISF without an entry in force") func isfMissing() {
        #expect(BasalTestEvaluator.isf(in: sensitivities([]), at: at(12), calendar: utc) == nil)
        // Nothing has started yet at 01:00.
        #expect(BasalTestEvaluator.isf(in: sensitivities([(120, 50)]), at: at(1), calendar: utc) == nil)
    }

    @Test("An ISF saved in mmol/L comes back in mg/dL, one saved in mg/dL as it is") func isfUnits() {
        let mmol = sensitivities([(0, 2.8)], units: .mmolL)
        #expect(BasalTestEvaluator.isf(in: mmol, at: at(12), calendar: utc) == Decimal(2.8).asMgdL)
        #expect(BasalTestEvaluator.isf(in: mmol, at: at(12), calendar: utc) == 50)
        #expect(BasalTestEvaluator.isf(in: sensitivities([(0, 52.5)]), at: at(12), calendar: utc) == 52.5)
    }

    @Test("A test records the schedule it covers and the average basal over its hours") func snapshotCoversPlannedWindow() {
        // 01:00 to 05:00 sits inside the first entry.
        let inside = BasalTestEvaluator.snapshot(of: basalSchedule, startingAt: at(1), for: 4 * hour, calendar: utc)
        #expect(inside.covered == [scheduleEntry(0, 360, 0.8)])
        #expect(inside.scheduledBasal == 0.8)

        // 04:00 to 08:00 is two hours of 0.8 and two of 1.0.
        let across = BasalTestEvaluator.snapshot(of: basalSchedule, startingAt: at(4), for: 4 * hour, calendar: utc)
        #expect(across.covered == [scheduleEntry(0, 360, 0.8), scheduleEntry(360, 1320, 1.0)])
        #expect(across.scheduledBasal == 0.9)
    }

    @Test("A test that runs past midnight covers entries on both sides of it") func snapshotWrapsMidnight() {
        let snapshot = BasalTestEvaluator.snapshot(of: basalSchedule, startingAt: at(23), for: 4 * hour, calendar: utc)
        #expect(snapshot.covered == [scheduleEntry(0, 360, 0.8), scheduleEntry(1320, 1440, 0.7)])
        // One hour of 0.7 and three of 0.8.
        #expect(snapshot.scheduledBasal == 0.775)
    }

    @Test("Nothing is saved when no entry covers the test, so it can't read as unchanged") func snapshotWithoutCoverage() {
        let none = BasalTestEvaluator.snapshot(of: [], startingAt: at(1), for: 4 * hour, calendar: utc)
        #expect(none.covered == nil)
        #expect(none.scheduledBasal == nil)

        // The profile starts after the test is over.
        let late = BasalTestEvaluator.snapshot(
            of: [scheduleEntry(600, 1440, 0.8)],
            startingAt: at(1),
            for: 4 * hour,
            calendar: utc
        )
        #expect(late.covered == nil)
        #expect(late.scheduledBasal == nil)
    }

    @Test("A schedule that delivers nothing is kept but gives no basal to judge against") func snapshotZeroBasal() {
        let snapshot = BasalTestEvaluator.snapshot(
            of: [scheduleEntry(0, 1440, 0)],
            startingAt: at(1),
            for: 4 * hour,
            calendar: utc
        )
        #expect(snapshot.covered == [scheduleEntry(0, 1440, 0)])
        #expect(snapshot.scheduledBasal == nil)
    }

    @Test("A test that ran its whole window is judged on the average it saved") func scheduledBasalWholeWindow() {
        let test = runningTest(covered: [scheduleEntry(0, 360, 0.8), scheduleEntry(360, 1320, 1.0)], scheduledBasal: 0.9)
        #expect(BasalTestEvaluator.scheduledBasal(for: test, endingAt: test.plannedEnd, calendar: utc) == 0.9)
    }

    @Test("A test ended early is judged only on the hours it ran") func scheduledBasalEndedEarly() {
        let test = runningTest(covered: [scheduleEntry(0, 360, 0.8), scheduleEntry(360, 1320, 1.0)], scheduledBasal: 0.9)
        // 04:00 to 06:00 never reached the 1.0 entry.
        #expect(BasalTestEvaluator.scheduledBasal(for: test, endingAt: at(6), calendar: utc) == 0.8)
        // 04:00 to 07:00 is two hours of 0.8 and one of 1.0.
        let threeHours = BasalTestEvaluator.scheduledBasal(for: test, endingAt: at(7), calendar: utc)
        #expect(threeHours.map { abs($0 - Decimal(string: "0.8666667")!) < 0.0001 } == true)
    }

    @Test("Without a saved schedule the average saved at the start is used") func scheduledBasalFallback() {
        let saved = runningTest(covered: nil, scheduledBasal: 0.9)
        #expect(BasalTestEvaluator.scheduledBasal(for: saved, endingAt: at(6), calendar: utc) == 0.9)
        let none = runningTest(covered: nil, scheduledBasal: nil)
        #expect(BasalTestEvaluator.scheduledBasal(for: none, endingAt: at(6), calendar: utc) == nil)
    }

    @Test("A test that ends the moment it starts doesn't turn its window into a whole day") func scheduledBasalNoTimeElapsed() {
        let test = runningTest(covered: [scheduleEntry(0, 360, 0.8), scheduleEntry(360, 1320, 1.0)], scheduledBasal: 0.9)
        #expect(BasalTestEvaluator.scheduledBasal(for: test, endingAt: test.startedAt, calendar: utc) == 0.9)
        #expect(BasalTestEvaluator.scheduledBasal(for: test, endingAt: at(4).addingTimeInterval(30), calendar: utc) == 0.9)
    }

    @Test("A saved schedule none of the ran hours touch gives no basal") func scheduledBasalNoOverlap() {
        let test = runningTest(covered: [scheduleEntry(600, 1320, 1.0)], scheduledBasal: 1.0)
        #expect(BasalTestEvaluator.scheduledBasal(for: test, endingAt: at(6), calendar: utc) == nil)
    }

    @Test("What a test saved at the start is enough to read its result") func savedSnapshotGivesResult() {
        let snapshot = BasalTestEvaluator.snapshot(of: basalSchedule, startingAt: at(1), for: 4 * hour, calendar: utc)
        var test = runningTest(covered: snapshot.covered, scheduledBasal: snapshot.scheduledBasal)
        test.isf = BasalTestEvaluator.isf(in: sensitivities([(0, 50)]), at: test.startedAt, calendar: utc)

        // 100 to 130 over four hours at ISF 50 and 0.8 U/h is 18.75% of the basal.
        let evaluation = BasalTestEvaluator.evaluate(
            startGlucose: 100,
            endGlucose: 130,
            elapsed: 4 * hour,
            reason: .completed,
            interference: nil,
            isf: test.isf,
            scheduledBasal: BasalTestEvaluator.scheduledBasal(for: test, endingAt: test.plannedEnd, calendar: utc)
        )
        #expect(evaluation.outcome == .rising)
        #expect(evaluation.direction == .increase)
        #expect(evaluation.share == 0.1875)
    }

    @Test(
        "A finished test gives its result again from what it saved, for the screen that shows the working"
    ) func evaluationOfFinishedTest() {
        var test = runningTest(covered: [scheduleEntry(0, 1440, 0.8)], scheduledBasal: 0.8)
        test.isf = 50
        // Still running: no end glucose or reason yet.
        #expect(BasalTestEvaluator.evaluation(of: test, calendar: utc) == nil)

        test.phase = .finished
        test.endedAt = test.plannedEnd
        test.endReason = .completed
        test.endGlucose = 130
        let evaluation = BasalTestEvaluator.evaluation(of: test, calendar: utc)
        #expect(evaluation?.outcome == .rising)
        #expect(evaluation?.netChange == 30)
        #expect(evaluation?.ratePerHour == 0.15)
        #expect(evaluation?.share == 0.1875)

        // Saved with no end glucose (no readings): nothing to compare, so no rate or share.
        test.endGlucose = nil
        let empty = BasalTestEvaluator.evaluation(of: test, calendar: utc)
        #expect(empty?.outcome == .inconclusive)
        #expect(empty?.netChange == 0)
        #expect(empty?.share == nil)
    }

    // MARK: Fasting SMBs

    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 20) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func smb(_ hour: Int, _ minute: Int = 0, day: Int = 20, units: Decimal = 0.2) -> BasalTestSMB {
        BasalTestSMB(date: at(hour, minute, day: day), units: units)
    }

    private func cob(_ grams: Decimal, _ hour: Int, _ minute: Int = 0, day: Int = 20) -> BasalTestCOBSample {
        BasalTestCOBSample(date: at(hour, minute, day: day), cob: grams)
    }

    /// 01:00 to 05:00.
    private let earlyMorning = SettingsTestTimeWindow(startMinutes: 60, endMinutes: 300)

    private func fastingSMBs(
        _ smbs: [BasalTestSMB],
        cob: [BasalTestCOBSample],
        window: SettingsTestTimeWindow
    ) -> (count: Int, units: Decimal) {
        BasalTestEvaluator.fastingSMBs(smbs, cob: cob, window: window, calendar: utc)
    }

    @Test("An SMB counts when it is inside the window and no carbs were on board") func fastingSMBsCounting() {
        // Inside the window with COB 0.
        let counted = fastingSMBs([smb(2, units: 0.3)], cob: [cob(0, 1, 30)], window: earlyMorning)
        #expect(counted.count == 1)
        #expect(counted.units == 0.3)

        // Carbs were still on board.
        let eating = fastingSMBs([smb(2)], cob: [cob(12, 1, 30)], window: earlyMorning)
        #expect(eating == (count: 0, units: 0))

        // Outside the window, whatever the COB.
        let outside = fastingSMBs([smb(6)], cob: [cob(0, 5, 30)], window: earlyMorning)
        #expect(outside == (count: 0, units: 0))

        // The only COB sample comes after the SMB, so nothing says there were no carbs on board.
        #expect(fastingSMBs([smb(2)], cob: [cob(0, 2, 30)], window: earlyMorning) == (count: 0, units: 0))
        #expect(fastingSMBs([smb(2)], cob: [], window: earlyMorning) == (count: 0, units: 0))
        #expect(fastingSMBs([], cob: [cob(0, 1)], window: earlyMorning) == (count: 0, units: 0))
    }

    @Test("A window that runs past midnight counts SMBs on both sides of it") func wrapsMidnight() {
        let overnight = SettingsTestTimeWindow(startMinutes: 22 * 60, endMinutes: 4 * 60)
        let samples = [cob(0, 0)]
        let result = fastingSMBs(
            [smb(1, units: 0.1), smb(23, 30, units: 0.2), smb(12, units: 0.4), smb(4, units: 0.8)],
            cob: samples,
            window: overnight
        )
        // 01:00 and 23:30 are in; noon is out; 04:00 is the end, which is exclusive.
        #expect(result.count == 2)
        #expect(result.units == 0.3)
    }

    @Test("Each SMB goes by the newest COB sample at or before it") func fastingSMBsNewestSample() {
        let samples = [cob(0, 0), cob(15, 1, 30), cob(0, 3)]
        let result = fastingSMBs(
            [
                smb(1, 15, units: 0.1), // newest sample is the 00:00 zero
                smb(1, 45, units: 0.2), // newest is 15 g at 01:30
                smb(2, 59, units: 0.4), // still the 15 g
                smb(3, units: 0.8), // a sample at exactly this time counts
                smb(3, 30, units: 1.6)
            ],
            cob: samples,
            window: earlyMorning
        )
        #expect(result.count == 3)
        #expect(result.units == 2.5)
    }

    @Test("The input can come in any order") func fastingSMBsUnsortedInput() {
        let smbs = [smb(3, 30), smb(1, 15), smb(2, 45), smb(2, 10)]
        let samples = [cob(0, 3), cob(20, 2), cob(0, 0)]
        let inOrder = fastingSMBs(
            smbs.sorted { $0.date < $1.date },
            cob: samples.sorted { $0.date < $1.date },
            window: earlyMorning
        )
        let shuffled = fastingSMBs(smbs, cob: samples, window: earlyMorning)
        // 01:15 and 03:30 are fasting; 02:10 and 02:45 follow the 20 g.
        #expect(inOrder.count == 2)
        #expect(shuffled.count == inOrder.count)
        #expect(shuffled.units == inOrder.units)
    }

    @Test("A window's edges are minutes of the day: the start is in and the end is out") func fastingSMBsWindowEdges() {
        let result = fastingSMBs(
            [smb(0, 59), smb(1, 0), smb(4, 59), smb(5, 0)],
            cob: [cob(0, 0)],
            window: earlyMorning
        )
        #expect(result.count == 2)
    }

    @Test("A week of days each use their own COB, and units add up") func fastingSMBsAcrossDays() {
        let result = fastingSMBs(
            [smb(2, day: 18, units: 0.25), smb(2, day: 19, units: 0.5), smb(2, day: 20, units: 0.75)],
            // A meal late on the 18th was still on board at 02:00 on the 19th.
            cob: [cob(0, 20, day: 17), cob(30, 23, day: 18), cob(0, 3, day: 19), cob(0, 22, day: 19)],
            window: earlyMorning
        )
        #expect(result.count == 2)
        #expect(result.units == 1.0)
    }

    @Test("The SMB lookback is the Stats screen's week") func smbLookback() {
        #expect(BasalTest.Config.smbLookback == 7 * 24 * hour)
    }

    // MARK: Trio's own suspend

    private let testStart = Date(timeIntervalSince1970: 1_000_000)
    /// The planned end of a 4 hour fast.
    private var testEnd: Date { testStart.addingTimeInterval(4 * hour) }

    private func temp(_ rate: Decimal, minutes: Int, after seconds: TimeInterval) -> BasalTestTempBasal {
        BasalTestTempBasal(date: testStart.addingTimeInterval(seconds), rate: rate, minutes: minutes)
    }

    private func suspended(_ temps: [BasalTestTempBasal]) -> Bool {
        BasalTestEvaluator.trioSuspended(temps, since: testStart, until: testEnd)
    }

    @Test("A zero temp basal after the start means Trio suspended for a low") func zeroTempMeansSuspend() {
        let suspend = temp(0, minutes: 30, after: 600)
        #expect(BasalTestEvaluator.trioSuspended([suspend], since: testStart, until: testEnd))
    }

    @Test("A zero temp at the very start counts, a moment before it doesn't") func suspendAtStartEdge() {
        #expect(suspended([temp(0, minutes: 30, after: 0)]))
        #expect(!suspended([temp(0, minutes: 30, after: -1)]))
    }

    @Test("A zero rate for no time is a cancelled temp, not a suspend") func ignoresCancelAtStart() {
        #expect(!BasalTestEvaluator.trioSuspended([temp(0, minutes: 0, after: 600)], since: testStart, until: testEnd))
    }

    @Test("A temp that still delivers is not a suspend") func ignoresNonZero() {
        #expect(!BasalTestEvaluator.trioSuspended([temp(0.4, minutes: 30, after: 600)], since: testStart, until: testEnd))
    }

    @Test("A suspend from before the test began is not this test's low") func ignoresBeforeStart() {
        #expect(!BasalTestEvaluator.trioSuspended([temp(0, minutes: 30, after: -3600)], since: testStart, until: testEnd))
    }

    @Test("A suspend after the planned end is not this test's low; one at it is") func ignoresSuspendAfterPlannedEnd() {
        let atEnd = temp(0, minutes: 30, after: 4 * hour)
        let afterEnd = temp(0, minutes: 30, after: 4 * hour + 60)
        #expect(BasalTestEvaluator.trioSuspended([atEnd], since: testStart, until: testEnd))
        #expect(!BasalTestEvaluator.trioSuspended([afterEnd], since: testStart, until: testEnd))
    }

    @Test("Any one suspend among other temps is enough, whatever the order") func suspendAmongOthers() {
        let temps = [
            temp(0.4, minutes: 30, after: 300),
            temp(0, minutes: 0, after: 600),
            temp(0, minutes: 30, after: 900),
            temp(0, minutes: 30, after: -60),
            temp(0, minutes: 30, after: 4 * hour + 60)
        ]
        #expect(suspended(temps))
        #expect(suspended(temps.reversed()))

        // Without the one inside the window, the rest don't add up to a suspend.
        let outside = [temps[0], temps[1], temps[3], temps[4]]
        #expect(!suspended(outside))
    }

    @Test("No temp basals means no suspend") func noTempsNoSuspend() {
        #expect(!suspended([]))
    }

    // MARK: The low's window

    private func firstSuspend(_ temps: [BasalTestTempBasal]) -> Date? {
        BasalTestEvaluator.firstSuspend(temps, since: testStart, until: testEnd)
    }

    @Test("The first suspend is the earliest one inside the fast, whatever the order") func firstSuspendIsEarliest() {
        let temps = [
            temp(0, minutes: 30, after: 5400),
            temp(0.4, minutes: 30, after: 300),
            temp(0, minutes: 30, after: 1800),
            temp(0, minutes: 0, after: 600),
            temp(0, minutes: 30, after: -60)
        ]
        #expect(firstSuspend(temps) == testStart.addingTimeInterval(1800))
        #expect(firstSuspend(temps.reversed()) == testStart.addingTimeInterval(1800))
    }

    @Test("There is no first suspend without one inside the fast") func firstSuspendNone() {
        #expect(firstSuspend([]) == nil)
        #expect(firstSuspend([temp(0, minutes: 0, after: 600), temp(0.4, minutes: 30, after: 900)]) == nil)
        #expect(firstSuspend([temp(0, minutes: 30, after: -1), temp(0, minutes: 30, after: 4 * hour + 1)]) == nil)
        // Its edges are in, the same as `trioSuspended`.
        #expect(firstSuspend([temp(0, minutes: 30, after: 0)]) == testStart)
        #expect(firstSuspend([temp(0, minutes: 30, after: 4 * hour)]) == testEnd)
    }

    @Test("A low is judged over the fast up to the suspend, not to the planned end") func lowWindowEndsAtSuspend() {
        // 04:00 to 08:00 planned, over 0.8 then 1.0 U/h; Trio suspended at 06:00, when glucose had fallen 16.
        var test = runningTest(covered: [scheduleEntry(0, 360, 0.8), scheduleEntry(360, 1320, 1.0)], scheduledBasal: 0.9)
        test.isf = 50
        test.phase = .finished
        test.endedAt = at(6)
        test.endReason = .low
        test.endGlucose = 84
        let evaluation = BasalTestEvaluator.evaluation(of: test, calendar: utc)
        #expect(evaluation?.outcome == .falling)
        // -16 ÷ 50 ÷ 2 h = -0.16 U/h, against the 0.8 U/h of the two hours it ran.
        #expect(evaluation?.ratePerHour == -0.16)
        #expect(evaluation?.share == -0.2)
    }

    @Test("A test records only the entries the hours it ran covered") func coveredByActualWindow() {
        let saved = [scheduleEntry(0, 360, 0.8), scheduleEntry(360, 1320, 1.0)]
        let test = runningTest(covered: saved, scheduledBasal: 0.9)
        // 04:00 to 06:00 never reached the 1.0 entry.
        #expect(BasalTestEvaluator.coveredEntries(for: test, endingAt: at(6), calendar: utc) == [scheduleEntry(0, 360, 0.8)])
        // The whole planned window covers both.
        #expect(BasalTestEvaluator.coveredEntries(for: test, endingAt: test.plannedEnd, calendar: utc) == saved)
        // Under a minute is the entry it started in, not the whole day.
        #expect(
            BasalTestEvaluator.coveredEntries(for: test, endingAt: test.startedAt.addingTimeInterval(20), calendar: utc)
                == [scheduleEntry(0, 360, 0.8)]
        )
    }

    @Test("Nothing is recorded without a saved schedule, or when the hours ran touch none of it") func coveredByActualWindowNone() {
        #expect(BasalTestEvaluator.coveredEntries(for: runningTest(covered: nil, scheduledBasal: nil), endingAt: at(6)) == nil)
        let later = runningTest(covered: [scheduleEntry(600, 1320, 1.0)], scheduledBasal: 1.0)
        #expect(BasalTestEvaluator.coveredEntries(for: later, endingAt: at(6), calendar: utc) == nil)
    }

    // MARK: Basal Testing left during the fast

    private func smbAfter(_ seconds: TimeInterval, units: Decimal = 0.2) -> BasalTestSMB {
        BasalTestSMB(date: testStart.addingTimeInterval(seconds), units: units)
    }

    private func dosed(smbs: [BasalTestSMB] = [], temps: [BasalTestTempBasal] = []) -> Bool {
        BasalTestEvaluator.dosedDuringFast(smbs: smbs, temps: temps, since: testStart, until: testEnd)
    }

    @Test("An SMB inside the fast means Trio dosed, so Basal Testing wasn't on the whole time") func smbMeansDosed() {
        #expect(dosed(smbs: [smbAfter(600)]))
        #expect(dosed(smbs: [smbAfter(0)]))
        #expect(dosed(smbs: [smbAfter(4 * hour)]))
        #expect(!dosed(smbs: [smbAfter(-60), smbAfter(4 * hour + 60)]))
        // An SMB of nothing gave nothing.
        #expect(!dosed(smbs: [smbAfter(600, units: 0)]))
    }

    @Test("A temp basal that delivers for some time means Trio dosed; a suspend or a cancel doesn't") func tempMeansDosed() {
        #expect(dosed(temps: [temp(0.4, minutes: 30, after: 600)]))
        #expect(!dosed(temps: [temp(0, minutes: 30, after: 600)]))
        #expect(!dosed(temps: [temp(0.4, minutes: 0, after: 600)]))
        #expect(!dosed(temps: [temp(0, minutes: 0, after: 0)]))
        #expect(!dosed(temps: [temp(0.4, minutes: 30, after: -60), temp(0.4, minutes: 30, after: 4 * hour + 60)]))
        #expect(!dosed())
    }

    /// The session the running test started with.
    private let testSession = UUID(uuidString: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!

    private func serviceEnd(
        _ cause: SettingsTestEndCause,
        after seconds: TimeInterval,
        session: UUID? = nil
    ) -> SettingsTestEnd {
        SettingsTestEnd(sessionID: session ?? testSession, cause: cause, date: testStart.addingTimeInterval(seconds))
    }

    private func check(
        sessionID: UUID? = nil,
        ended: SettingsTestEnd? = nil,
        suspend: TimeInterval? = nil,
        unreadable: Bool = false,
        now: TimeInterval,
        mode: DosingMode = .basalTesting
    ) -> BasalTestEvaluator.RunningCheck? {
        let reading: BasalTestEvaluator.SuspendReading = unreadable
            ? .unreadable
            : suspend.map { .suspended(at: testStart.addingTimeInterval($0)) } ?? .none
        return BasalTestEvaluator.runningCheck(
            sessionID: sessionID ?? testSession,
            serviceEnd: ended,
            suspend: reading,
            now: testStart.addingTimeInterval(now),
            plannedEnd: testEnd,
            mode: mode
        )
    }

    private func at(seconds: TimeInterval) -> Date { testStart.addingTimeInterval(seconds) }

    @Test("A running fast keeps going while Basal Testing is on and time is left") func runningKeepsGoing() {
        #expect(check(now: 3600) == nil)
    }

    @Test(
        "The service's record of ending this test for a low or carbs decides, whatever the mode is now"
    ) func runningServiceEndWins() {
        // The service brought the usual mode back when it ended the test.
        #expect(check(ended: serviceEnd(.low, after: 1800), now: 3600, mode: .closed) == .low(at: at(seconds: 1800)))
        #expect(
            check(ended: serviceEnd(.carbsLogged, after: 2400), now: 3600, mode: .closed)
                == .carbsLogged(at: at(seconds: 2400))
        )
        // It needs no pump history, and it still holds once the planned time is up.
        #expect(
            check(ended: serviceEnd(.low, after: 1800), unreadable: true, now: 3600, mode: .closed)
                == .low(at: at(seconds: 1800))
        )
        #expect(check(ended: serviceEnd(.low, after: 1800), now: 5 * hour, mode: .closed) == .low(at: at(seconds: 1800)))
        // The record's time beats a zero temp the next mode set later.
        #expect(
            check(ended: serviceEnd(.low, after: 1800), suspend: 2400, now: 3600, mode: .closed)
                == .low(at: at(seconds: 1800))
        )
        // One at the planned end is still inside the fast, as a suspend there is.
        #expect(check(ended: serviceEnd(.low, after: 4 * hour), now: 5 * hour, mode: .closed) == .low(at: testEnd))
    }

    @Test(
        "A record of another session, from after the planned end, or with no session to match isn't this fast's"
    ) func runningServiceEndOtherSession() {
        let other = serviceEnd(.low, after: 1800, session: UUID())
        #expect(check(ended: other, now: 3600, mode: .closed) == .modeChanged)
        #expect(check(ended: other, suspend: 1800, now: 3600) == .low(at: at(seconds: 1800)))

        // A state saved before the session was kept can't be matched to a record.
        let unmatched = BasalTestEvaluator.runningCheck(
            sessionID: nil,
            serviceEnd: serviceEnd(.low, after: 1800),
            suspend: .none,
            now: at(seconds: 3600),
            plannedEnd: testEnd,
            mode: .closed
        )
        #expect(unmatched == .modeChanged)

        // Ended after the fast was over: the fast itself ran its course.
        #expect(check(ended: serviceEnd(.low, after: 4 * hour + 60), now: 5 * hour, mode: .closed) == .completed)
        #expect(check(ended: serviceEnd(.carbsLogged, after: 4 * hour + 60), now: 5 * hour, mode: .closed) == .completed)
    }

    @Test("A mode changed before the planned end interrupts the fast, even with a zero temp in it") func runningModeChanged() {
        #expect(check(now: 3600, mode: .closed) == .modeChanged)
        #expect(check(now: 3600, mode: .open) == .modeChanged)
        #expect(check(now: 3600, mode: .lowGlucoseSuspend) == .modeChanged)
        // A zero temp the new mode set is not a low.
        #expect(check(suspend: 1800, now: 3600, mode: .closed) == .modeChanged)
        #expect(check(suspend: 1800, now: 3600, mode: .lowGlucoseSuspend) == .modeChanged)
    }

    @Test("Only while Basal Testing is still on is a zero temp in the fast a low") func runningLowInBasalTesting() {
        #expect(check(suspend: 1800, now: 3600) == .low(at: at(seconds: 1800)))
        // Inside the grace after the planned end, Basal Testing is still on.
        #expect(check(suspend: 1800, now: 5 * hour) == .low(at: at(seconds: 1800)))
        // Off by now, with no record from the service: it can't be told whose zero temp it was.
        #expect(check(suspend: 1800, now: 5 * hour, mode: .closed) == .unexplainedSuspend)
    }

    @Test("Time up completes the fast, whatever the mode is by then") func runningCompletes() {
        #expect(check(now: 4 * hour) == .completed)
        #expect(check(now: 5 * hour, mode: .closed) == .completed)
    }

    @Test("Time up ends the fast even when the pump history can't be read, without a verdict") func runningUnreadable() {
        #expect(check(unreadable: true, now: 4 * hour) == .completedUnchecked)
        #expect(check(unreadable: true, now: 5 * hour, mode: .closed) == .completedUnchecked)
        // Before then nothing is decided, so a low isn't missed; a changed mode needs no history.
        #expect(check(unreadable: true, now: 3600) == nil)
        #expect(check(unreadable: true, now: 3600, mode: .closed) == .modeChanged)
    }

    // MARK: Numbers as shown

    @Test("A rate is shown rounded toward zero, so it never reads as more than it is") func rateTowardZero() {
        #expect(BasalTestEvaluator.towardZero(Decimal(string: "0.0799")!, scale: 2) == Decimal(string: "0.07")!)
        #expect(BasalTestEvaluator.towardZero(Decimal(string: "-0.0799")!, scale: 2) == Decimal(string: "-0.07")!)
        #expect(BasalTestEvaluator.towardZero(Decimal(string: "0.155")!, scale: 2) == Decimal(string: "0.15")!)
        #expect(BasalTestEvaluator.towardZero(Decimal(string: "-0.155")!, scale: 2) == Decimal(string: "-0.15")!)
        #expect(BasalTestEvaluator.towardZero(Decimal(string: "0.15")!, scale: 2) == Decimal(string: "0.15")!)
        #expect(BasalTestEvaluator.towardZero(Decimal(string: "-0.004")!, scale: 2) == 0)
    }

    @Test("Rate and share round the same way, so a share under the step has a rate under the step's") func rateAndShareAgree() {
        // 0.0799 U/h of 0.8 U/h is 9.99%: shown as 0.07 and 9%, both under one step (0.08 and 10%).
        let rate = Decimal(string: "0.0799")!
        #expect(BasalTestEvaluator.towardZero(rate, scale: 2) < Decimal(string: "0.08")!)
        #expect(BasalTestEvaluator.wholePercent(rate / Decimal(string: "0.8")!) == 9)
    }
}

// MARK: - Settings test service

/// A settings manager that keeps everything in memory.
private final class FakeSettingsManager: SettingsManager {
    var settings = TrioSettings() {
        didSet { onSettingsChange?() }
    }

    /// Called each time the settings change, so a test can look at what else was true at that moment.
    var onSettingsChange: (() -> Void)?
    var preferences = Preferences()
    var pumpSettings = PumpSettings(insulinActionCurve: 10, maxBolus: 10, maxBasal: 2)
    func updateInsulinCurve(_: InsulinType?) {}
}

/// Pump history and carbs as a test sets them, with how often the service asked.
private final class FakeSettingsTestEvents: SettingsTestEvents {
    var temps: [BasalTestTempBasal] = []
    var carbs: [Date] = []
    var failing = false
    private(set) var reads = 0

    struct Failure: Error {}

    func tempBasals(from start: Date, to end: Date) async throws -> [BasalTestTempBasal] {
        reads += 1
        if failing { throw Failure() }
        return temps.filter { $0.date >= start && $0.date <= end }
    }

    func hasCarbEntries(from start: Date, to end: Date) async throws -> Bool {
        reads += 1
        if failing { throw Failure() }
        return carbs.contains { $0 >= start && $0 <= end }
    }
}

@Suite("Settings test service", .serialized) struct SettingsTestServiceTests {
    private let sessionPath = "trio/settings_test_session.json"
    private let historyPath = "trio/settings_test_history.json"
    private let lastEndPath = "trio/settings_test_last_end.json"

    private func makeService(
        mode: DosingMode,
        existing: SettingsTestSession? = nil,
        events: FakeSettingsTestEvents = FakeSettingsTestEvents(),
        keepingFiles: Bool = false
    ) -> (BaseSettingsTestService, FakeSettingsManager, FileStorage) {
        let storage = BaseFileStorage()
        if !keepingFiles {
            storage.remove(sessionPath)
            storage.remove(historyPath)
            storage.remove(lastEndPath)
        }
        if let existing { storage.save(existing, as: sessionPath) }

        let settings = FakeSettingsManager()
        settings.settings.dosingMode = mode

        let container = Container()
        container.register(FileStorage.self) { _ in storage }
        container.register(SettingsManager.self) { _ in settings }
        return (BaseSettingsTestService(resolver: container, events: events), settings, storage)
    }

    /// A basal test running in Basal Testing, from Closed Loop.
    private func startBasalTest(
        events: FakeSettingsTestEvents
    ) -> (BaseSettingsTestService, FakeSettingsManager, FileStorage, SettingsTestSession) {
        let (service, settings, storage) = makeService(mode: .closed, events: events)
        let session = service.begin(
            kind: .basal,
            expiresIn: 3600,
            restoring: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )!
        settings.settings.dosingMode = .basalTesting
        return (service, settings, storage, session)
    }

    @Test("Ending by kind ends only a session of that kind") func endByKind() {
        let (service, settings, storage) = makeService(mode: .closed)
        defer { cleanUp(storage) }

        service.begin(kind: .basal, expiresIn: 3600, restoring: [.dosingMode(testMode: .basalTesting, previous: .closed)])
        settings.settings.dosingMode = .basalTesting

        service.end(kind: .isf)
        #expect(service.activeSession?.kind == .basal)
        #expect(settings.settings.dosingMode == .basalTesting)

        service.end(kind: .basal)
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
        #expect(storage.retrieve(sessionPath, as: SettingsTestSession.self) == nil)
    }

    @Test("Trio's suspend for a low ends a basal test with nobody on its screen") func suspendEndsSession() async {
        let events = FakeSettingsTestEvents()
        // Started an hour ago, on a whole second, so the suspend is in the past and the kept record reads back exactly.
        let startedAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded(.down))
        let session = SettingsTestSession(
            kind: .basal,
            startedAt: startedAt,
            expiresAt: Date().addingTimeInterval(3600),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        let suspendedAt = startedAt.addingTimeInterval(600)
        events.temps = [BasalTestTempBasal(date: suspendedAt, rate: 0, minutes: 30)]
        await service.endIfLowOrCarbsLogged()
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
        // Why and when, for the basal screen to finish the result from.
        let expected = SettingsTestEnd(sessionID: session.id, cause: .low, date: suspendedAt)
        #expect(service.lastEnd() == expected)
        // Kept on disk, so it is still there after a relaunch.
        let (relaunched, _, _) = makeService(mode: .closed, keepingFiles: true)
        #expect(relaunched.lastEnd() == expected)
    }

    @Test("Carbs logged during a basal test end it with nobody on its screen") func carbsEndSession() async {
        let events = FakeSettingsTestEvents()
        let (service, settings, storage, session) = startBasalTest(events: events)
        defer { cleanUp(storage) }

        events.carbs = [session.startedAt]
        let before = Date()
        await service.endIfLowOrCarbsLogged()
        let after = Date()
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
        let ended = service.lastEnd()
        #expect(ended?.sessionID == session.id)
        #expect(ended?.cause == .carbsLogged)
        // When it found them, within what a date keeps on disk (milliseconds).
        if let date = ended?.date {
            #expect(date >= before.addingTimeInterval(-0.01) && date <= after.addingTimeInterval(0.01))
        }
    }

    @Test("The reason is kept before the usual mode comes back, so the two are never seen apart") func endRecordBeforeRestore() async {
        let events = FakeSettingsTestEvents()
        let (service, settings, storage, session) = startBasalTest(events: events)
        defer { cleanUp(storage) }

        var recordWhenModeChanged: SettingsTestEnd?
        var modeChanges = 0
        settings.onSettingsChange = {
            modeChanges += 1
            recordWhenModeChanged = service.lastEnd()
        }
        events.temps = [BasalTestTempBasal(date: session.startedAt, rate: 0, minutes: 30)]
        await service.endIfLowOrCarbsLogged()
        #expect(modeChanges == 1)
        #expect(recordWhenModeChanged?.sessionID == session.id)
        #expect(recordWhenModeChanged?.cause == .low)
    }

    @Test("Carbs end only a basal test; another kind in Basal Testing keeps running") func carbsEndOnlyBasal() async {
        let events = FakeSettingsTestEvents()
        let (service, settings, storage) = makeService(mode: .closed, events: events)
        defer { cleanUp(storage) }

        let session = service.begin(
            kind: .isf,
            expiresIn: 3600,
            restoring: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )!
        settings.settings.dosingMode = .basalTesting
        events.carbs = [session.startedAt]
        await service.endIfLowOrCarbsLogged()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(service.lastEnd() == nil)
    }

    @Test("Without a suspend or carbs the basal test keeps running") func noSuspendLeavesSession() async {
        let events = FakeSettingsTestEvents()
        let (service, settings, storage, session) = startBasalTest(events: events)
        defer { cleanUp(storage) }

        events.temps = [
            // A cancel at the start and a suspend from before the test aren't this test's low.
            BasalTestTempBasal(date: session.startedAt, rate: 0, minutes: 0),
            BasalTestTempBasal(date: session.startedAt.addingTimeInterval(-600), rate: 0, minutes: 30)
        ]
        events.carbs = [session.startedAt.addingTimeInterval(-600)]
        await service.endIfLowOrCarbsLogged()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(events.reads > 0)
        #expect(service.lastEnd() == nil)
    }

    @Test("A test whose mode the user already changed is left alone") func userModeLeftAlone() async {
        let events = FakeSettingsTestEvents()
        let (service, settings, storage, session) = startBasalTest(events: events)
        defer { cleanUp(storage) }

        settings.settings.dosingMode = .lowGlucoseSuspend
        events.temps = [BasalTestTempBasal(date: session.startedAt, rate: 0, minutes: 30)]
        await service.endIfLowOrCarbsLogged()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .lowGlucoseSuspend)
        #expect(events.reads == 0)
    }

    @Test("A session that didn't switch to Basal Testing isn't watched") func otherSessionNotWatched() async {
        let events = FakeSettingsTestEvents()
        let (service, settings, storage) = makeService(mode: .basalTesting, events: events)
        defer { cleanUp(storage) }

        let session = service.begin(kind: .isf, expiresIn: 3600, restoring: [])
        events.temps = [BasalTestTempBasal(date: session!.startedAt, rate: 0, minutes: 30)]
        await service.endIfLowOrCarbsLogged()
        #expect(service.activeSession?.id == session?.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(events.reads == 0)
    }

    @Test("When the history can't be read, the test keeps running") func readFailureLeavesSession() async {
        let events = FakeSettingsTestEvents()
        let (service, settings, storage, session) = startBasalTest(events: events)
        defer { cleanUp(storage) }

        events.failing = true
        events.temps = [BasalTestTempBasal(date: session.startedAt, rate: 0, minutes: 30)]
        await service.endIfLowOrCarbsLogged()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(service.lastEnd() == nil)
    }

    private func cleanUp(_ storage: FileStorage) {
        storage.remove(sessionPath)
        storage.remove(historyPath)
        storage.remove(lastEndPath)
    }

    private func record(minutesAgo: Int, kind: SettingsTestKind = .basal) -> SettingsTestRecord {
        let end = Date().addingTimeInterval(-Double(minutesAgo) * 60)
        return SettingsTestRecord(
            kind: kind,
            startedAt: end.addingTimeInterval(-4 * 3600),
            completedAt: end,
            timeBlock: "Overnight",
            startGlucose: 100,
            endGlucose: 105,
            direction: .keep,
            summary: "steady"
        )
    }

    @Test("Ending a test puts the previous dosing mode back") func restoresMode() {
        let (service, settings, storage) = makeService(mode: .closed)
        defer { cleanUp(storage) }

        service.begin(kind: .basal, expiresIn: 3600, restoring: [.dosingMode(testMode: .basalTesting, previous: .closed)])
        settings.settings.dosingMode = .basalTesting
        #expect(service.activeSession != nil)

        service.end(kind: .basal)
        #expect(settings.settings.dosingMode == .closed)
        #expect(service.activeSession == nil)
        #expect(storage.retrieve(sessionPath, as: SettingsTestSession.self) == nil)
    }

    @Test("A mode the user chose themselves is left alone") func leavesUserChoice() {
        let (service, settings, storage) = makeService(mode: .lowGlucoseSuspend)
        defer { cleanUp(storage) }

        service.begin(kind: .basal, expiresIn: 3600, restoring: [.dosingMode(testMode: .basalTesting, previous: .closed)])
        service.end(kind: .basal)
        #expect(settings.settings.dosingMode == .lowGlucoseSuspend)
    }

    @Test("A second test can't start while one is running") func refusesSecondSession() {
        let (service, _, storage) = makeService(mode: .closed)
        defer { cleanUp(storage) }

        let first = service.begin(
            kind: .basal,
            expiresIn: 3600,
            restoring: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )
        let second = service.begin(
            kind: .isf,
            expiresIn: 3600,
            restoring: [.dosingMode(testMode: .basalTesting, previous: .lowGlucoseSuspend)]
        )

        #expect(first != nil)
        #expect(second == nil)
        #expect(service.activeSession?.id == first?.id)
        // Dates lose sub-second precision on disk, so compare what matters: whose way back is stored.
        let stored = storage.retrieve(sessionPath, as: SettingsTestSession.self)
        #expect(stored?.id == first?.id)
        #expect(stored?.restore == first?.restore)
    }

    @Test("A session that ran past its deadline is closed on launch") func expiredSessionRestoresOnLaunch() {
        let stale = SettingsTestSession(
            kind: .basal,
            startedAt: Date().addingTimeInterval(-6 * 3600),
            expiresAt: Date().addingTimeInterval(-60),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: stale)
        defer { cleanUp(storage) }

        #expect(settings.settings.dosingMode == .closed)
        #expect(service.activeSession == nil)
    }

    @Test("A session still inside its deadline survives a relaunch") func liveSessionSurvivesLaunch() {
        let live = SettingsTestSession(
            kind: .basal,
            expiresAt: Date().addingTimeInterval(3600),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: live)
        defer { cleanUp(storage) }

        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(service.activeSession?.id == live.id)
    }

    @Test("endIfExpired leaves a running session alone") func notExpiredNoOp() {
        let (service, settings, storage) = makeService(mode: .basalTesting)
        defer { cleanUp(storage) }

        service.begin(kind: .basal, expiresIn: 3600, restoring: [.dosingMode(testMode: .basalTesting, previous: .closed)])
        service.endIfExpired()
        #expect(service.activeSession != nil)
        #expect(settings.settings.dosingMode == .basalTesting)
    }

    @Test("Ending with no session does nothing") func endWithoutSession() {
        let (service, settings, storage) = makeService(mode: .closed)
        defer { cleanUp(storage) }

        service.end(kind: .basal)
        #expect(settings.settings.dosingMode == .closed)
    }

    @Test("History comes back newest first and can be filtered") func historyOrderAndFilter() {
        let (service, _, storage) = makeService(mode: .closed)
        defer { cleanUp(storage) }

        service.archive(record(minutesAgo: 300))
        service.archive(record(minutesAgo: 10))
        service.archive(record(minutesAgo: 100, kind: .carbRatio))

        let all = service.history(for: nil)
        #expect(all.count == 3)
        #expect(all.map(\.kind) == [.basal, .carbRatio, .basal])

        let basal = service.history(for: .basal)
        #expect(basal.count == 2)
        #expect(basal[0].completedAt > basal[1].completedAt)
    }

    @Test("History keeps only the most recent records") func historyIsCapped() {
        let (service, _, storage) = makeService(mode: .closed)
        defer { cleanUp(storage) }

        for minutes in 0 ..< 205 {
            service.archive(record(minutesAgo: minutes))
        }
        #expect(service.history(for: nil).count == 200)
    }
}

/// The old carb ratio wizard's service, keeping its saved test in memory and listing the calls made to it.
private final class FakeCalibrationModeService: CalibrationModeService {
    var saved: CalibrationTestState?
    var deactivationFails = false
    private(set) var calls: [String] = []

    struct Failure: Error {}

    var currentTest: CalibrationTestState? { nil }
    var testStatePublisher: AnyPublisher<CalibrationTestState?, Never> { Just(saved).eraseToAnyPublisher() }
    let prepTimeoutMinutes = 60

    func loadExistingTest() -> CalibrationTestState? { saved }
    func startNewTest() -> CalibrationTestState { calls.append("startNewTest")
        return CalibrationTestState() }

    func updatePhase(_: CalibrationPhase) { calls.append("updatePhase") }
    func saveTestState(_ state: CalibrationTestState) { calls.append("saveTestState")
        saved = state }

    func clearTest() { calls.append("clearTest")
        saved = nil }

    func recoverTestStateIfNeeded() async { calls.append("recoverTestStateIfNeeded") }
    func activateCalibrationOverride() async throws { calls.append("activateCalibrationOverride") }
    func deactivateCalibrationOverride() async throws {
        calls.append("deactivateCalibrationOverride")
        if deactivationFails { throw Failure() }
    }

    func scheduleReadyNotification() { calls.append("scheduleReadyNotification") }
    func scheduleResultsNotification(at _: Date) { calls.append("scheduleResultsNotification") }
    func cancelScheduledNotifications() { calls.append("cancelScheduledNotifications") }
    func postNightscoutNote(_: String) { calls.append("postNightscoutNote") }
    func archiveCompletedTest(_: CalibrationTestState, glucoseReadings _: [CalibrationGlucoseReading]) {
        calls.append("archiveCompletedTest")
    }
}

@Suite("Settings test kinds") struct SettingsTestKindTests {
    @Test("Basal is listed before sensitivity, then carb ratio") func order() {
        #expect(SettingsTestKind.allCases == [.basal, .isf, .carbRatio])
    }

    @Test("Only basal can be opened; sensitivity is coming and carb ratio is being rebuilt") func availability() {
        #expect(SettingsTestKind.basal.availability == .available)
        #expect(SettingsTestKind.isf.availability == .comingSoon)
        #expect(SettingsTestKind.carbRatio.availability == .beingRebuilt)
    }

    @Test("While one test runs, every other row is locked and the running test's own row is not") func locking() {
        let state = SettingsTest.StateModel()
        for kind in SettingsTestKind.allCases {
            #expect(!state.isLocked(kind))
        }

        state.activeSession = SettingsTestSession(
            kind: .basal,
            expiresAt: Date().addingTimeInterval(3600),
            restore: []
        )
        #expect(!state.isLocked(.basal))
        #expect(state.isLocked(.isf))
        #expect(state.isLocked(.carbRatio))
    }

    @Test("Only an available test opens, and only while no other test runs") func screens() {
        let state = SettingsTest.StateModel()
        #expect(state.screen(for: .basal) == .basalTest)
        #expect(state.screen(for: .isf) == nil)
        #expect(state.screen(for: .carbRatio) == nil)

        state.activeSession = SettingsTestSession(
            kind: .basal,
            expiresAt: Date().addingTimeInterval(3600),
            restore: []
        )
        #expect(state.screen(for: .basal) == .basalTest)
    }

    private var observingCarbRatioTest: CalibrationTestState {
        var test = CalibrationTestState()
        test.phase = .observing
        return test
    }

    @Test("A carb ratio test from before never opens the old wizard") func carbRatioInProgressNeverOpens() {
        let state = SettingsTest.StateModel()
        #expect(state.screen(for: .carbRatio) == nil)

        state.carbRatioInProgress = true
        #expect(state.screen(for: .carbRatio) == nil)

        state.activeSession = SettingsTestSession(kind: .basal, expiresAt: Date().addingTimeInterval(3600), restore: [])
        #expect(state.screen(for: .carbRatio) == nil)
        #expect(state.screen(for: .basal) == .basalTest)
    }

    @Test(
        "Ending a carb ratio test from before turns its override off, withdraws its notifications and clears it"
    ) func endCarbRatioTest() async {
        let calibration = FakeCalibrationModeService()
        calibration.saved = observingCarbRatioTest
        let state = SettingsTest.StateModel()
        state.calibrationService = calibration
        state.refreshCarbRatio()
        #expect(state.carbRatioInProgress)

        await state.endCarbRatioTest()
        #expect(
            calibration
                .calls == ["deactivateCalibrationOverride", "cancelScheduledNotifications", "postNightscoutNote", "clearTest"]
        )
        #expect(calibration.saved == nil)
        #expect(!state.carbRatioInProgress)
        #expect(state.carbRatioEndError == nil)
    }

    @Test("When the override can't be turned off, the carb ratio test is kept and the hub says so") func endCarbRatioTestFails() async {
        let calibration = FakeCalibrationModeService()
        calibration.saved = observingCarbRatioTest
        calibration.deactivationFails = true
        let state = SettingsTest.StateModel()
        state.calibrationService = calibration
        state.refreshCarbRatio()

        await state.endCarbRatioTest()
        #expect(calibration.calls == ["deactivateCalibrationOverride"])
        #expect(calibration.saved != nil)
        #expect(state.carbRatioInProgress)
        #expect(state.carbRatioEndError != nil)
    }

    @Test("A carb ratio test counts as under way from its prep until it is completed") func carbRatioPhases() {
        let underWay: [CalibrationPhase] = [
            .prepping, .readyToTest, .awaitingTabletConfirmation, .bolusDelivered, .observing, .resultsReady,
            // Its screen still has to turn the SMB-off override off and clear these.
            .cancelled, .timedOut
        ]
        for phase in CalibrationPhase.allCases {
            #expect(SettingsTestKind.carbRatioTestInProgress(phase) == underWay.contains(phase), "\(phase)")
        }
        #expect(!SettingsTestKind.carbRatioTestInProgress(nil))
    }

    @Test("Sessions and records round trip through JSON") func roundTrip() throws {
        let session = SettingsTestSession(
            kind: .basal,
            startedAt: Date(timeIntervalSince1970: 1_900_000),
            expiresAt: Date(timeIntervalSince1970: 2_000_000),
            restore: [.dosingMode(testMode: .basalTesting, previous: .lowGlucoseSuspend)]
        )
        let decoded = try JSONCoding.decoder.decode(SettingsTestSession.self, from: JSONCoding.encoder.encode(session))
        #expect(decoded == session)
    }
}

// MARK: - Shared kit

@Suite("Settings test kit") struct SettingsTestKitTests {
    private func term(_ label: String, _ value: String, _ unit: String, fromSettings: Bool = false) -> SettingsTestFormulaTerm {
        SettingsTestFormulaTerm(label: label, value: value, unit: unit, fromSettings: fromSettings)
    }

    @Test("A formula line is read as one sentence, in order, naming the values from settings") func spokenFormulaLine() {
        let spoken = SettingsTestFormulaCard.spokenLabel(
            [.term(term("Change", "+30", "mg/dL")), .op("÷"), .term(term("ISF", "50", "mg/dL/U", fromSettings: true))],
            result: term("Rate", "+0.6", "U")
        )
        let order = ["Change", "+30", "divided by", "ISF", "50", "from your settings", "equals", "Rate", "+0.6"]
        var searchFrom = spoken.startIndex
        for word in order {
            let found = spoken.range(of: word, range: searchFrom ..< spoken.endIndex)
            #expect(found != nil, "\(word) in \(spoken)")
            if let found { searchFrom = found.upperBound }
        }
        // Only the ISF is from settings.
        #expect(spoken.components(separatedBy: "from your settings").count == 2)
        // Units are spelled out, not read as letters.
        #expect(spoken.contains(UnitSpelling.spoken("mg/dL")))
    }

    @Test("A glucose and its unit stay on one line, and read the same") func keepTogether() {
        let mgdl = SettingsTestFormat.keepTogether("72", unit: "mg/dL")
        // A no-break space before the unit, and a word joiner after its slash.
        #expect(mgdl == "72\u{00A0}mg/\u{2060}dL")
        #expect(SettingsTestFormat.keepTogether("4.0", unit: "mmol/L") == "4.0\u{00A0}mmol/\u{2060}L")
        // Nothing visible changes.
        #expect(mgdl.replacingOccurrences(of: "\u{2060}", with: "").replacingOccurrences(of: "\u{00A0}", with: " ") == "72 mg/dL")
    }

    @Test("Passed checks fold into one line that counts them") func passedSummary() {
        #expect(SettingsTestFormat.passedChecksSummary(passing: 5, total: 5) == String(localized: "All 5 checks pass"))
        #expect(SettingsTestFormat.passedChecksSummary(passing: 4, total: 5) == String(localized: "4 other checks pass"))
        #expect(SettingsTestFormat.passedChecksSummary(passing: 1, total: 5) == String(localized: "1 other check passes"))
    }
}

// MARK: - Schedule snapshots and the basal gate

@Suite("Settings test schedule") struct SettingsTestScheduleTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func entry(_ start: Int, _ end: Int, _ value: Decimal) -> SettingsTestScheduleEntry {
        SettingsTestScheduleEntry(startMinutes: start, endMinutes: end, value: value)
    }

    private func basal(_ hour: Int, _ rate: Decimal) -> BasalProfileEntry {
        BasalProfileEntry(start: String(format: "%02d:00:00", hour), minutes: hour * 60, rate: rate)
    }

    private func date(hour: Int, minute: Int = 0, day: Int = 25) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private var profile: [SettingsTestScheduleEntry] {
        SettingsTestSchedule.entries([basal(0, 0.8), basal(6, 1.0), basal(22, 0.7)])
    }

    private func window(_ fromHour: Int, _ toHour: Int) -> SettingsTestTimeWindow {
        SettingsTestTimeWindow(from: date(hour: fromHour), to: date(hour: toHour), calendar: calendar)
    }

    private func record(
        _ direction: SettingsTestDirection,
        minutesAgo: Int,
        kind: SettingsTestKind = .basal,
        covered: [SettingsTestScheduleEntry]?
    ) -> SettingsTestRecord {
        let end = date(hour: 12).addingTimeInterval(-Double(minutesAgo) * 60)
        return SettingsTestRecord(
            kind: kind,
            startedAt: end.addingTimeInterval(-4 * 3600),
            completedAt: end,
            timeBlock: "Overnight",
            startGlucose: 100,
            endGlucose: 105,
            direction: direction,
            summary: "test",
            coveredEntries: covered
        )
    }

    @Test("A profile becomes entries that run to the next start, the last to midnight") func entriesFromProfile() {
        #expect(profile == [entry(0, 360, 0.8), entry(360, 1320, 1.0), entry(1320, 1440, 0.7)])
    }

    @Test("Entries are built in start order whatever order the profile arrives in") func entriesAreSorted() {
        let shuffled = SettingsTestSchedule.entries([basal(22, 0.7), basal(0, 0.8), basal(6, 1.0)])
        #expect(shuffled == profile)
    }

    @Test("An empty profile has no entries") func emptyProfile() {
        #expect(SettingsTestSchedule.entries([]).isEmpty)
    }

    @Test("A window takes its minutes of the day from the calendar") func windowMinutes() {
        let window = SettingsTestTimeWindow(
            from: date(hour: 22, minute: 15),
            to: date(hour: 4, minute: 30, day: 26),
            calendar: calendar
        )
        #expect(window.startMinutes == 22 * 60 + 15)
        #expect(window.endMinutes == 4 * 60 + 30)
    }

    @Test("A window that runs past midnight wraps") func wrapsMidnight() {
        let overnight = window(22, 4)
        #expect(overnight.contains(minuteOfDay: 30))
        #expect(overnight.contains(minuteOfDay: 22 * 60))
        #expect(!overnight.contains(minuteOfDay: 600))
        #expect(!overnight.contains(minuteOfDay: 4 * 60))

        #expect(SettingsTestSchedule.covered(by: overnight, in: profile) == [entry(0, 360, 0.8), entry(1320, 1440, 0.7)])

        // 2 hours at 0.7 and 4 hours at 0.8, over 6 hours.
        let expected = (Decimal(2) * Decimal(string: "0.7")! + Decimal(4) * Decimal(string: "0.8")!) / Decimal(6)
        let average = SettingsTestSchedule.averageRate(over: overnight, in: profile)
        #expect(abs(((average - expected) as NSDecimalNumber).doubleValue) < 0.000_001)
    }

    @Test("A window inside one day covers only the entries it overlaps") func sameDayWindow() {
        let daytime = window(8, 12)
        #expect(daytime.contains(minuteOfDay: 8 * 60))
        #expect(!daytime.contains(minuteOfDay: 12 * 60))
        #expect(SettingsTestSchedule.covered(by: daytime, in: profile) == [entry(360, 1320, 1.0)])
        #expect(SettingsTestSchedule.averageRate(over: daytime, in: profile) == 1.0)
    }

    @Test("A window that starts exactly where an entry ends does not cover it") func windowEdges() {
        #expect(SettingsTestSchedule.covered(by: window(6, 8), in: profile) == [entry(360, 1320, 1.0)])
        #expect(SettingsTestSchedule.covered(by: window(4, 6), in: profile) == [entry(0, 360, 0.8)])
    }

    @Test("A covered entry that was edited is no longer unchanged") func unchangedDetectsEdit() {
        let covered = [entry(0, 360, 0.8)]
        let edited = SettingsTestSchedule.entries([basal(0, 0.85), basal(6, 1.0), basal(22, 0.7)])
        #expect(!SettingsTestSchedule.isUnchanged(covered, in: edited))
        #expect(SettingsTestSchedule.isUnchanged(covered, in: profile))
    }

    @Test("Moving an entry's boundary counts as a change") func unchangedDetectsMovedBoundary() {
        let covered = [entry(0, 360, 0.8)]
        let moved = SettingsTestSchedule.entries([basal(0, 0.8), basal(5, 1.0), basal(22, 0.7)])
        #expect(!SettingsTestSchedule.isUnchanged(covered, in: moved))
    }

    @Test("Entries outside the window can change without touching a covered one") func unchangedIgnoresOtherEntries() {
        let covered = [entry(0, 360, 0.8)]
        let edited = SettingsTestSchedule.entries([basal(0, 0.8), basal(6, 1.2), basal(22, 0.7)])
        #expect(SettingsTestSchedule.isUnchanged(covered, in: edited))
    }

    @Test("The newest basal test decides whether the basal gate is open") func basalGateCases() {
        let covered = [entry(0, 360, 0.8)]
        let edited = SettingsTestSchedule.entries([basal(0, 0.85), basal(6, 1.0), basal(22, 0.7)])
        let steady = record(.keep, minutesAgo: 10, covered: covered)

        #expect(SettingsTestSchedule.basalGate(history: [], current: profile) == .noSteadyTest)
        #expect(SettingsTestSchedule.basalGate(history: [steady], current: profile) == .ready(lastSteady: steady.completedAt))
        #expect(SettingsTestSchedule.basalGate(history: [steady], current: edited) == .changedSince(steady.completedAt))

        let rising = record(.increase, minutesAgo: 5, covered: covered)
        #expect(
            SettingsTestSchedule.basalGate(history: [rising, steady], current: profile)
                == .lastWasNot(.increase, rising.completedAt)
        )
        let falling = record(.decrease, minutesAgo: 5, covered: covered)
        #expect(
            SettingsTestSchedule.basalGate(history: [falling, steady], current: profile)
                == .lastWasNot(.decrease, falling.completedAt)
        )
    }

    @Test("Only the newest basal test counts") func newestBasalWins() {
        let covered = [entry(0, 360, 0.8)]
        let olderRising = record(.increase, minutesAgo: 600, covered: covered)
        let newerSteady = record(.keep, minutesAgo: 10, covered: covered)
        let olderSteady = record(.keep, minutesAgo: 600, covered: covered)
        let newerFalling = record(.decrease, minutesAgo: 10, covered: covered)

        #expect(
            SettingsTestSchedule.basalGate(history: [newerSteady, olderRising], current: profile)
                == .ready(lastSteady: newerSteady.completedAt)
        )
        #expect(
            SettingsTestSchedule.basalGate(history: [newerFalling, olderSteady], current: profile)
                == .lastWasNot(.decrease, newerFalling.completedAt)
        )
    }

    @Test("Other kinds of test don't open or close the basal gate") func basalGateIgnoresOtherKinds() {
        let covered = [entry(0, 360, 0.8)]
        let steady = record(.keep, minutesAgo: 100, covered: covered)
        let newerCarbRatio = record(.increase, minutesAgo: 5, kind: .carbRatio, covered: nil)

        #expect(
            SettingsTestSchedule.basalGate(history: [newerCarbRatio, steady], current: profile)
                == .ready(lastSteady: steady.completedAt)
        )
        #expect(SettingsTestSchedule.basalGate(history: [newerCarbRatio], current: profile) == .noSteadyTest)
    }

    @Test("A steady test saved before schedules were kept can't vouch for the schedule") func gateWithoutSnapshot() {
        let legacy = record(.keep, minutesAgo: 10, covered: nil)
        #expect(SettingsTestSchedule.basalGate(history: [legacy], current: profile) == .noSteadyTest)
    }

    @Test("A raise or lower result stands whether or not a schedule was kept") func directionNeedsNoSnapshot() {
        let legacy = record(.increase, minutesAgo: 10, covered: nil)
        #expect(
            SettingsTestSchedule.basalGate(history: [legacy], current: profile)
                == .lastWasNot(.increase, legacy.completedAt)
        )
    }

    @Test("A record saved without covered entries decodes with none") func decodesOldRecord() throws {
        let json = """
        {
          "id": "6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D",
          "kind": "basal",
          "startedAt": "2026-10-25T02:00:00Z",
          "completedAt": "2026-10-25T06:00:00Z",
          "timeBlock": "Overnight",
          "startGlucose": 100,
          "endGlucose": 105,
          "direction": "keep",
          "summary": "steady",
          "applied": false
        }
        """
        let decoded = try JSONCoding.decoder.decode(SettingsTestRecord.self, from: Data(json.utf8))
        #expect(decoded.coveredEntries == nil)
        #expect(decoded.direction == .keep)
    }

    @Test("Covered entries survive a round trip through JSON") func recordRoundTrip() throws {
        let saved = record(.keep, minutesAgo: 10, covered: [entry(0, 360, 0.8), entry(1320, 1440, 0.7)])
        let decoded = try JSONCoding.decoder.decode(SettingsTestRecord.self, from: JSONCoding.encoder.encode(saved))
        #expect(decoded.coveredEntries == saved.coveredEntries)
    }

    // MARK: Basal periods

    private func untested(_ entry: SettingsTestScheduleEntry) -> SettingsTestBasalPeriod {
        SettingsTestBasalPeriod(entry: entry, lastTest: nil, lastDirection: nil, changedSince: false)
    }

    @Test("With no tests, every period is untested") func periodsUntested() {
        let periods = SettingsTestSchedule.basalPeriods(current: profile, history: [])
        #expect(periods == profile.map(untested))
    }

    @Test("A steady test marks the period it covered and leaves the others untested") func periodSteady() {
        let steady = record(.keep, minutesAgo: 10, covered: [entry(0, 360, 0.8)])
        let periods = SettingsTestSchedule.basalPeriods(current: profile, history: [steady])
        #expect(periods == [
            SettingsTestBasalPeriod(
                entry: entry(0, 360, 0.8),
                lastTest: steady.completedAt,
                lastDirection: .keep,
                changedSince: false
            ),
            untested(entry(360, 1320, 1.0)),
            untested(entry(1320, 1440, 0.7))
        ])
    }

    @Test("A rising or falling test keeps its direction") func periodDirection() {
        let rising = record(.increase, minutesAgo: 10, covered: [entry(0, 360, 0.8)])
        let falling = record(.decrease, minutesAgo: 20, covered: [entry(360, 1320, 1.0)])
        let periods = SettingsTestSchedule.basalPeriods(current: profile, history: [rising, falling])
        #expect(periods[0].lastDirection == .increase)
        #expect(periods[0].lastTest == rising.completedAt)
        #expect(periods[1].lastDirection == .decrease)
        #expect(periods[1].lastTest == falling.completedAt)
        #expect(!periods[0].changedSince)
        #expect(!periods[1].changedSince)
        #expect(periods[2] == untested(entry(1320, 1440, 0.7)))
    }

    @Test("A period edited since its test says so, and still shows what the test said") func periodEdited() {
        let steady = record(.keep, minutesAgo: 10, covered: [entry(0, 360, 0.8)])
        let edited = SettingsTestSchedule.entries([basal(0, 0.85), basal(6, 1.0), basal(22, 0.7)])
        let periods = SettingsTestSchedule.basalPeriods(current: edited, history: [steady])
        #expect(periods[0] == SettingsTestBasalPeriod(
            entry: entry(0, 360, 0.85),
            lastTest: steady.completedAt,
            lastDirection: .keep,
            changedSince: true
        ))
        #expect(periods[1] == untested(entry(360, 1320, 1.0)))
    }

    @Test("Moving a boundary or splitting an entry counts as an edit") func periodBoundaryChanged() {
        let steady = record(.keep, minutesAgo: 10, covered: [entry(0, 360, 0.8)])

        let moved = SettingsTestSchedule.entries([basal(0, 0.8), basal(5, 1.0), basal(22, 0.7)])
        #expect(SettingsTestSchedule.basalPeriods(current: moved, history: [steady])[0].changedSince)

        let split = SettingsTestSchedule.entries([basal(0, 0.8), basal(3, 0.8), basal(6, 1.0), basal(22, 0.7)])
        let splitPeriods = SettingsTestSchedule.basalPeriods(current: split, history: [steady])
        #expect(splitPeriods[0].changedSince)
        #expect(splitPeriods[1].changedSince)
        #expect(splitPeriods[0].lastTest == steady.completedAt)
        #expect(splitPeriods[1].lastTest == steady.completedAt)
    }

    @Test("An edit to another entry doesn't change a tested period") func periodOtherEntryEdited() {
        let steady = record(.keep, minutesAgo: 10, covered: [entry(0, 360, 0.8)])
        let edited = SettingsTestSchedule.entries([basal(0, 0.8), basal(6, 1.2), basal(22, 0.7)])
        let periods = SettingsTestSchedule.basalPeriods(current: edited, history: [steady])
        #expect(!periods[0].changedSince)
        #expect(periods[1] == untested(entry(360, 1320, 1.2)))
    }

    @Test("When two tests covered a period the newest decides, in whatever order they arrive") func periodNewestWins() {
        let covered = [entry(0, 360, 0.8)]
        let newer = record(.keep, minutesAgo: 10, covered: covered)
        let older = record(.increase, minutesAgo: 600, covered: covered)

        for history in [[newer, older], [older, newer]] {
            let period = SettingsTestSchedule.basalPeriods(current: profile, history: history)[0]
            #expect(period.lastTest == newer.completedAt)
            #expect(period.lastDirection == .keep)
        }
    }

    @Test("A test that covered only another entry says nothing about this one") func periodCoveredOnlyOther() {
        let other = record(.increase, minutesAgo: 10, covered: [entry(360, 1320, 1.0)])
        let steady = record(.keep, minutesAgo: 600, covered: [entry(0, 360, 0.8)])
        let periods = SettingsTestSchedule.basalPeriods(current: profile, history: [other, steady])
        // The newer test covered the daytime entry, so the overnight one still goes by the older test.
        #expect(periods[0].lastTest == steady.completedAt)
        #expect(periods[0].lastDirection == .keep)
        #expect(periods[1].lastTest == other.completedAt)
        #expect(periods[1].lastDirection == .increase)
        #expect(periods[2] == untested(entry(1320, 1440, 0.7)))
    }

    @Test("A test over midnight marks each entry it touched") func periodOvernightTest() {
        let overnight = record(.keep, minutesAgo: 10, covered: [entry(0, 360, 0.8), entry(1320, 1440, 0.7)])
        let periods = SettingsTestSchedule.basalPeriods(current: profile, history: [overnight])
        #expect(periods[0].lastTest == overnight.completedAt)
        #expect(periods[1] == untested(entry(360, 1320, 1.0)))
        #expect(periods[2].lastTest == overnight.completedAt)
    }

    @Test("Tests saved without a schedule, and tests of other settings, are ignored") func periodIgnoresUnusableRecords() {
        let legacy = record(.increase, minutesAgo: 5, covered: nil)
        let carbRatio = record(.decrease, minutesAgo: 6, kind: .carbRatio, covered: [entry(0, 360, 0.8)])
        let steady = record(.keep, minutesAgo: 600, covered: [entry(0, 360, 0.8)])

        #expect(SettingsTestSchedule.basalPeriods(current: profile, history: [legacy, carbRatio]) == profile.map(untested))

        let periods = SettingsTestSchedule.basalPeriods(current: profile, history: [legacy, carbRatio, steady])
        #expect(periods[0].lastTest == steady.completedAt)
        #expect(periods[0].lastDirection == .keep)
    }

    @Test("No schedule means no periods") func periodsWithoutSchedule() {
        let steady = record(.keep, minutesAgo: 10, covered: [entry(0, 360, 0.8)])
        #expect(SettingsTestSchedule.basalPeriods(current: [], history: [steady]).isEmpty)
    }

    // MARK: Times of day

    private let britain = SettingsTestSchedule.makeTimeFormatter(locale: Locale(identifier: "en_GB"))

    @Test("Minutes from midnight read as a time of day, and the end of the day as midnight") func timeText() {
        #expect(SettingsTestSchedule.timeText(minutes: 0, formatter: britain) == "00:00")
        #expect(SettingsTestSchedule.timeText(minutes: 390, formatter: britain) == "06:30")
        #expect(SettingsTestSchedule.timeText(minutes: 1320, formatter: britain) == "22:00")
        #expect(SettingsTestSchedule.timeText(minutes: 1440, formatter: britain) == "00:00")
    }

    @Test("The shared formatter gives the end of the day the same reading as midnight") func sharedFormatterMidnight() {
        #expect(SettingsTestSchedule.timeText(minutes: 1440) == SettingsTestSchedule.timeText(minutes: 0))
        #expect(SettingsTestSchedule.timeText(minutes: 360) != SettingsTestSchedule.timeText(minutes: 1080))
    }

    @Test("A period's span runs from its start to its end") func spanText() {
        #expect(SettingsTestSchedule.spanText(of: entry(0, 360, 0.8), formatter: britain) == "00:00–06:00")
        #expect(SettingsTestSchedule.spanText(of: entry(1320, 1440, 0.7), formatter: britain) == "22:00–00:00")
    }
}
