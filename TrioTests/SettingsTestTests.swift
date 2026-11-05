import Combine
import CoreData
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
        interferenceUnread: Bool = false,
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
            interferenceUnread: interferenceUnread,
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

    @Test(
        "A fast whose records couldn't all be read for interruptions says nothing, a low included"
    ) func unreadInterferenceIsInconclusive() {
        for end in [60, 100, 140] {
            let result = evaluate(end: end, interferenceUnread: true)
            #expect(result.outcome == .inconclusive, "\(end)")
            #expect(result.direction == nil, "\(end)")
        }
        // A bolus that couldn't be read may be what brought the low.
        #expect(evaluate(start: 95, end: 68, elapsedHours: 2, reason: .low, interferenceUnread: true).outcome == .inconclusive)
        // Something that spoiled it still says so.
        #expect(evaluate(end: 140, interference: "Carbs", interferenceUnread: true).outcome == .invalid)
        #expect(evaluate(end: 140, reason: .interrupted, interferenceUnread: true).outcome == .invalid)
    }

    @Test("The steady band stays a whole mg/dL under the change one docs step is worth") func bandForFast() {
        // 50 × 0.8 × 0.1 × 4 = 16 exactly, which is a step, so the band is 15.
        #expect(BasalTestEvaluator.steadyBand(isf: 50, scheduledBasal: 0.8, hours: 4) == 15)
        // 45 × 0.75 × 0.1 × 6 = 20.25
        #expect(BasalTestEvaluator.steadyBand(isf: 45, scheduledBasal: 0.75, hours: 6) == 20)
        // 52 × 0.75 × 0.1 × 4 = 15.6
        #expect(BasalTestEvaluator.steadyBand(isf: 52, scheduledBasal: 0.75, hours: 4) == 15)
        // 50 × 0.8 × 0.2 × 4 = 32 exactly
        #expect(BasalTestEvaluator.steadyBand(isf: 50, scheduledBasal: 0.8, hours: 4, step: 0.2) == 31)
        // 50 × 0.8 × 0.1 × 4.25 = 17 exactly
        #expect(BasalTestEvaluator.steadyBand(isf: 50, scheduledBasal: 0.8, hours: 4.25) == 16)
    }

    @Test("A change at the edge of the band agrees with the verdict") func bandMatchesVerdict() {
        let band = BasalTestEvaluator.steadyBand(isf: 50, scheduledBasal: 0.8, hours: 4)
        #expect(band == 15)
        // 16 mg/dL is exactly one docs step, so it is rising; 15 is inside the band and steady.
        #expect(evaluate(end: 100 + 16).outcome == .rising)
        #expect(evaluate(end: 100 + 15).outcome == .steady)
        #expect(evaluate(end: 100 + band).outcome == .steady)
        #expect(evaluate(end: 100 + band + 1).outcome == .rising)
        #expect(evaluate(end: 100 - 16).outcome == .falling)
        #expect(evaluate(end: 100 - band).outcome == .steady)
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
        #expect(BasalTestEvaluator.endGlucose(from: readings, endingAt: now.addingTimeInterval(5 * 300)) == 140)
    }

    @Test("There is no end glucose when the CGM recorded nothing") func noEndGlucoseWithoutReadings() {
        #expect(BasalTestEvaluator.endGlucose(from: [], endingAt: Date()) == nil)
    }

    @Test("A CGM that stopped early in the fast gives no end glucose") func endGlucoseNeedsARecentReading() {
        let end = Date()
        // The CGM stopped an hour before the end of the fast.
        let readings = (0 ..< 6).map {
            BasalTestReading(date: end.addingTimeInterval(-3600 - Double($0) * 300), glucose: 100 + $0 * 10)
        }
        #expect(BasalTestEvaluator.endGlucose(from: readings, endingAt: end) == nil)
    }

    @Test("The newest reading may be as old as Trio's loop accepts, and no older") func endGlucoseReadingAgeLimit() {
        #expect(BasalTest.Config.endReadingMaxAge == 12 * 60)
        let end = Date()
        func endGlucose(newestAge: TimeInterval) -> Int? {
            // Readings 5 minutes apart, the newest `newestAge` before the end: 130, 140, 150 at the tail.
            let readings = (0 ..< 6).map {
                BasalTestReading(date: end.addingTimeInterval(-newestAge - Double(5 - $0) * 300), glucose: 100 + $0 * 10)
            }
            return BasalTestEvaluator.endGlucose(from: readings, endingAt: end)
        }
        #expect(endGlucose(newestAge: 0) == 140)
        #expect(endGlucose(newestAge: 10 * 60) == 140)
        #expect(endGlucose(newestAge: 12 * 60) == 140)
        #expect(endGlucose(newestAge: 12 * 60 + 1) == nil)
    }

    @Test("A low end is described as Trio's suspend; a fall from the readings as a fall") func summaryForLowEnd() {
        // A low's result is "falling" whatever the readings were, and Trio's suspend can come from its forecast while
        // glucose is still above the threshold, so it is not described as a measured fall.
        #expect(BasalTestEvaluator.summary(for: .falling, reason: .low) == "Trio suspended insulin for a low")
        #expect(BasalTestEvaluator.summary(for: .falling, reason: .completed) == "Glucose fell")
        #expect(BasalTestEvaluator.summary(for: .falling, reason: .endedEarly) == "Glucose fell")
        // Other outcomes keep their text.
        #expect(BasalTestEvaluator.summary(for: .steady, reason: .completed) == "Glucose stayed steady")
        #expect(BasalTestEvaluator.summary(for: .rising, reason: .completed) == "Glucose rose")
        #expect(BasalTestEvaluator.summary(for: .inconclusive, reason: .endedEarly) == "Ended too soon to tell")
        #expect(BasalTestEvaluator.summary(for: .invalid, reason: .interrupted) == "Fast was interrupted")
        // A low that something else spoiled is still an interrupted fast.
        #expect(BasalTestEvaluator.summary(for: .invalid, reason: .low) == "Fast was interrupted")
    }

    private struct ReadFailure: Error {}

    /// Counts how many times a check was read.
    private final class Reads {
        var calls = 0
    }

    @Test("A read that fails doesn't hide a later one") func failedReadDoesntHideALaterOne() async {
        let found = await BasalTestEvaluator.firstInterference([
            (name: "carbs", read: { throw ReadFailure() }),
            (name: "boluses", read: { "A bolus was given during the fast." })
        ])
        #expect(found == .found("A bolus was given during the fast."))
    }

    @Test("Nothing found is no interference") func noInterference() async {
        #expect(await BasalTestEvaluator.firstInterference([]) == BasalTestEvaluator.Interference.none)
        #expect(await BasalTestEvaluator.firstInterference([
            (name: "carbs", read: { nil }),
            (name: "boluses", read: { nil }),
            (name: "dosing", read: { nil })
        ]) == BasalTestEvaluator.Interference.none)
    }

    @Test("Nothing found with a read that failed means something may have been missed") func unreadInterference() async {
        #expect(await BasalTestEvaluator.firstInterference([
            (name: "carbs", read: { throw ReadFailure() }),
            (name: "boluses", read: { nil }),
            (name: "dosing", read: { throw ReadFailure() })
        ]) == .unreadable)
    }

    @Test("The first interference found wins, and the checks after it aren't read") func firstInterferenceWins() async {
        let later = Reads()
        let found = await BasalTestEvaluator.firstInterference([
            (name: "carbs", read: { nil }),
            (name: "boluses", read: { "A bolus was given during the fast." }),
            (name: "dosing", read: {
                later.calls += 1
                return "Trio dosed during the fast."
            })
        ])
        #expect(found == .found("A bolus was given during the fast."))
        #expect(later.calls == 0)

        let first = await BasalTestEvaluator.firstInterference([
            (name: "carbs", read: { "Carbs were logged during the fast." }),
            (name: "boluses", read: { "A bolus was given during the fast." })
        ])
        #expect(first == .found("Carbs were logged during the fast."))
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

    // MARK: Basal stopped

    private let testStart = Date(timeIntervalSince1970: 1_000_000)
    /// The planned end of a 4 hour fast.
    private var testEnd: Date { testStart.addingTimeInterval(4 * hour) }

    private func temp(_ rate: Decimal, minutes: Int, after seconds: TimeInterval) -> BasalTestTempBasal {
        BasalTestTempBasal(date: testStart.addingTimeInterval(seconds), rate: rate, minutes: minutes)
    }

    /// Whether basal was stopped inside the fast, whoever stopped it.
    private func suspended(_ temps: [BasalTestTempBasal]) -> Bool {
        firstSuspend(temps) != nil
    }

    @Test("A zero temp basal after the start means basal was stopped") func zeroTempMeansSuspend() {
        let suspend = temp(0, minutes: 30, after: 600)
        #expect(suspended([suspend]))
    }

    @Test("A zero temp at the very start counts, a moment before it doesn't") func suspendAtStartEdge() {
        #expect(suspended([temp(0, minutes: 30, after: 0)]))
        #expect(!suspended([temp(0, minutes: 30, after: -1)]))
    }

    @Test("A zero rate for no time is a cancelled temp, not a suspend") func ignoresCancelAtStart() {
        #expect(!suspended([temp(0, minutes: 0, after: 600)]))
    }

    @Test("A temp that still delivers is not a suspend") func ignoresNonZero() {
        #expect(!suspended([temp(0.4, minutes: 30, after: 600)]))
    }

    @Test("A suspend from before the test began is not this test's low") func ignoresBeforeStart() {
        #expect(!suspended([temp(0, minutes: 30, after: -3600)]))
    }

    @Test("A suspend after the planned end is not this test's low; one at it is") func ignoresSuspendAfterPlannedEnd() {
        let atEnd = temp(0, minutes: 30, after: 4 * hour)
        let afterEnd = temp(0, minutes: 30, after: 4 * hour + 60)
        #expect(suspended([atEnd]))
        #expect(!suspended([afterEnd]))
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

    // MARK: Whose suspend

    private func reading(
        _ temps: [BasalTestTempBasal],
        askedAt determinations: [TimeInterval]
    ) -> BasalTestEvaluator.SuspendReading {
        BasalTestEvaluator.suspendReading(
            temps,
            zeroTempDeterminations: determinations.map { testStart.addingTimeInterval($0) },
            since: testStart,
            until: testEnd
        )
    }

    @Test("A zero temp one of Trio's determinations asked for is its suspend for a low") func askedForZeroTempIsLow() {
        let suspend = temp(0, minutes: 30, after: 1800)
        // The determination is made, then the pump starts the temp a little later.
        #expect(reading([suspend], askedAt: [1770]) == .suspended(at: testStart.addingTimeInterval(1800)))
    }

    @Test("A zero temp no determination of Trio's asked for is unexplained, not a low") func unaskedZeroTempIsUnexplained() {
        let suspend = temp(0, minutes: 30, after: 1800)
        #expect(reading([suspend], askedAt: []) == .unexplained(at: testStart.addingTimeInterval(1800)))
        // Trio asking for one an hour earlier doesn't make this one its.
        #expect(reading([suspend], askedAt: [-1800, 5400]) == .unexplained(at: testStart.addingTimeInterval(1800)))
    }

    @Test("A determination up to 10 minutes before the zero temp or 2 after it asked for it") func askedForWindowEdges() {
        let suspend = temp(0, minutes: 30, after: 1800)
        let low = BasalTestEvaluator.SuspendReading.suspended(at: testStart.addingTimeInterval(1800))
        let unexplained = BasalTestEvaluator.SuspendReading.unexplained(at: testStart.addingTimeInterval(1800))
        #expect(reading([suspend], askedAt: [1800 - 600]) == low)
        #expect(reading([suspend], askedAt: [1800 + 120]) == low)
        #expect(reading([suspend], askedAt: [1800 - 601]) == unexplained)
        #expect(reading([suspend], askedAt: [1800 + 121]) == unexplained)
    }

    @Test("Only the first zero temp in the fast decides whose it was") func firstZeroTempDecides() {
        let unasked = temp(0, minutes: 30, after: 1800)
        let asked = temp(0, minutes: 30, after: 3600)
        // Basal stopped by someone else spoils the fast before Trio's low came.
        #expect(reading([asked, unasked], askedAt: [3570]) == .unexplained(at: testStart.addingTimeInterval(1800)))
        // Trio's low ended the fast before anything else happened.
        #expect(reading([unasked, asked], askedAt: [1770]) == .suspended(at: testStart.addingTimeInterval(1800)))
    }

    @Test(
        "A zero temp only a determination from before the fast's first minute asked for is Closed Loop's, not the fast's low"
    ) func closedLoopZeroTempAtStart() {
        // Closed Loop decided on it 20 seconds before Start; the pump set it 3 seconds after.
        let early = temp(0, minutes: 30, after: 3)
        #expect(reading([early], askedAt: [-20]) == .unexplained(at: testStart.addingTimeInterval(3)))
        // The ISF test's settle margin: a determination from a minute after Start on was made in Basal Testing.
        #expect(ISFTest.Config.settleLoopMargin == 60)
        let edge = temp(0, minutes: 30, after: 90)
        #expect(reading([edge], askedAt: [60]) == .suspended(at: testStart.addingTimeInterval(90)))
        #expect(reading([edge], askedAt: [59]) == .unexplained(at: testStart.addingTimeInterval(90)))
        // Either one asking is enough, as long as one is from Basal Testing.
        #expect(reading([edge], askedAt: [30, 80]) == .suspended(at: testStart.addingTimeInterval(90)))
    }

    @Test("Without a zero temp in the fast there is no suspend, whatever Trio asked for") func noZeroTempNoReading() {
        #expect(reading([], askedAt: [1800]) == BasalTestEvaluator.SuspendReading.none)
        let others = [temp(0, minutes: 0, after: 1800), temp(0.4, minutes: 30, after: 1800), temp(0, minutes: 30, after: -60)]
        #expect(reading(others, askedAt: [1800, -60]) == BasalTestEvaluator.SuspendReading.none)
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

    @Test("A saved result whose records couldn't all be read stays inconclusive") func savedUnreadInterference() {
        var test = runningTest(covered: [scheduleEntry(0, 1440, 0.8)], scheduledBasal: 0.8)
        test.isf = 50
        test.phase = .finished
        test.endedAt = test.plannedEnd
        test.endReason = .completed
        test.endGlucose = 140
        #expect(BasalTestEvaluator.evaluation(of: test, calendar: utc)?.outcome == .rising)
        test.interferenceUnread = true
        #expect(BasalTestEvaluator.evaluation(of: test, calendar: utc)?.outcome == .inconclusive)
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

    private func interferenceChecks(
        smbs: @escaping () async throws -> [BasalTestSMB],
        temps: @escaping () async throws -> [BasalTestTempBasal]
    ) -> [(name: String, read: () async throws -> String?)] {
        BasalTestEvaluator.interferenceChecks(
            hasCarbs: { false },
            pumpInterruptions: { [] },
            hasManualBolus: { false },
            smbs: smbs,
            temps: temps,
            since: testStart,
            until: testEnd
        )
    }

    private func isFound(_ interference: BasalTestEvaluator.Interference) -> Bool {
        if case .found = interference { return true }
        return false
    }

    @Test("Trio's SMBs and temp basals are read apart, so one that fails doesn't hide the other") func dosingReadApart() async {
        let delivering = temp(0.4, minutes: 30, after: 600)
        let failedSMBs = await BasalTestEvaluator.firstInterference(
            interferenceChecks(smbs: { throw ReadFailure() }, temps: { [delivering] })
        )
        #expect(isFound(failedSMBs))
        let failedTemps = await BasalTestEvaluator.firstInterference(
            interferenceChecks(smbs: { [self.smbAfter(600)] }, temps: { throw ReadFailure() })
        )
        #expect(isFound(failedTemps))
        // With nothing found in the other, the failed one leaves the fast unchecked.
        let nothingElse = await BasalTestEvaluator.firstInterference(
            interferenceChecks(smbs: { throw ReadFailure() }, temps: { [] })
        )
        #expect(nothingElse == .unreadable)
    }

    // MARK: Finishing on the screen

    private func finishing(
        _ reason: BasalTestEndReason,
        _ suspend: BasalTestEvaluator.SuspendReading
    ) -> (reason: BasalTestEndReason, end: Date, note: String?) {
        // Ended two hours in.
        BasalTestEvaluator.finishing(reason: reason, at: at(seconds: 2 * hour), suspend: suspend)
    }

    @Test("A low the checks hadn't seen yet still ends the fast as a low, at the suspend") func finishingFindsLow() {
        for reason in [BasalTestEndReason.endedEarly, .completed, .unchecked] {
            let finished = finishing(reason, .suspended(at: at(seconds: hour)))
            #expect(finished.reason == .low, "\(reason)")
            #expect(finished.end == at(seconds: hour), "\(reason)")
            #expect(finished.note == nil, "\(reason)")
        }
    }

    @Test("Basal stopped without Trio asking interrupts the fast, at the stop") func finishingFindsUnexplained() {
        for reason in [BasalTestEndReason.endedEarly, .completed, .unchecked] {
            let finished = finishing(reason, .unexplained(at: at(seconds: hour)))
            #expect(finished.reason == .interrupted, "\(reason)")
            #expect(finished.end == at(seconds: hour), "\(reason)")
            #expect(finished.note != nil, "\(reason)")
        }
    }

    @Test("Nothing found keeps the reason, except that an unchecked fast is now checked") func finishingFindsNothing() {
        let end = at(seconds: 2 * hour)
        #expect(finishing(.endedEarly, .none).reason == .endedEarly)
        #expect(finishing(.completed, .none).reason == .completed)
        #expect(finishing(.unchecked, .none).reason == .completed)
        #expect(finishing(.endedEarly, .none).end == end)
        #expect(finishing(.endedEarly, .none).note == nil)
        // A read that fails again changes nothing.
        #expect(finishing(.endedEarly, .unreadable).reason == .endedEarly)
        #expect(finishing(.unchecked, .unreadable).reason == .unchecked)
    }

    @Test("A low or an interruption already decided stays as it was") func finishingKeepsDecided() {
        let end = at(seconds: 2 * hour)
        let low = finishing(.low, .unexplained(at: at(seconds: hour)))
        #expect(low.reason == .low)
        #expect(low.end == end)
        let interrupted = finishing(.interrupted, .suspended(at: at(seconds: hour)))
        #expect(interrupted.reason == .interrupted)
        #expect(interrupted.end == end)
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
        unexplained: TimeInterval? = nil,
        unreadable: Bool = false,
        now: TimeInterval,
        mode: DosingMode = .basalTesting
    ) -> BasalTestEvaluator.RunningCheck? {
        let reading: BasalTestEvaluator.SuspendReading = unreadable
            ? .unreadable
            : suspend.map { .suspended(at: testStart.addingTimeInterval($0)) }
            ?? unexplained.map { .unexplained(at: testStart.addingTimeInterval($0)) }
            ?? .none
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

    @Test("A bolus the service found ends the fast at the time it recorded") func runningServiceEndExtraBolus() {
        #expect(
            check(ended: serviceEnd(.extraBolus, after: 2400), now: 3600, mode: .closed)
                == .bolusGiven(at: at(seconds: 2400))
        )
        // After the planned end the fast had run its course.
        #expect(check(ended: serviceEnd(.extraBolus, after: 4 * hour + 60), now: 5 * hour, mode: .closed) == .completed)
    }

    @Test("A record of no bolus, which a basal session never gets, reads as an interrupted fast") func runningServiceEndNoBolus() {
        // The service brought the usual mode back, so the fast didn't run to its end.
        #expect(check(ended: serviceEnd(.noBolus, after: 2400), now: 3600, mode: .closed) == .modeChanged(at: nil))
    }

    @Test(
        "A record of another session, from after the planned end, or with no session to match isn't this fast's"
    ) func runningServiceEndOtherSession() {
        let other = serviceEnd(.low, after: 1800, session: UUID())
        #expect(check(ended: other, now: 3600, mode: .closed) == .modeChanged(at: nil))
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
        #expect(unmatched == .modeChanged(at: nil))

        // Ended after the fast was over: the fast itself ran its course.
        #expect(check(ended: serviceEnd(.low, after: 4 * hour + 60), now: 5 * hour, mode: .closed) == .completed)
        #expect(check(ended: serviceEnd(.carbsLogged, after: 4 * hour + 60), now: 5 * hour, mode: .closed) == .completed)
    }

    @Test("A mode changed before the planned end interrupts the fast, even with a zero temp in it") func runningModeChanged() {
        #expect(check(now: 3600, mode: .closed) == .modeChanged(at: nil))
        #expect(check(now: 3600, mode: .open) == .modeChanged(at: nil))
        #expect(check(now: 3600, mode: .lowGlucoseSuspend) == .modeChanged(at: nil))
        // A zero temp the new mode set is not a low.
        #expect(check(suspend: 1800, now: 3600, mode: .closed) == .modeChanged(at: nil))
        #expect(check(suspend: 1800, now: 3600, mode: .lowGlucoseSuspend) == .modeChanged(at: nil))
    }

    @Test("Only while Basal Testing is still on is a zero temp in the fast a low") func runningLowInBasalTesting() {
        #expect(check(suspend: 1800, now: 3600) == .low(at: at(seconds: 1800)))
        // Inside the grace after the planned end, Basal Testing is still on.
        #expect(check(suspend: 1800, now: 5 * hour) == .low(at: at(seconds: 1800)))
        // Off by now, with no record from the service: it can't be told whose zero temp it was.
        #expect(check(suspend: 1800, now: 5 * hour, mode: .closed) == .unexplainedSuspend(at: at(seconds: 1800)))
    }

    @Test("A zero temp Trio didn't ask for stops the fast at it, in any mode") func runningUnexplainedZeroTemp() {
        #expect(check(unexplained: 1800, now: 3600) == .unexplainedSuspend(at: at(seconds: 1800)))
        #expect(check(unexplained: 1800, now: 5 * hour) == .unexplainedSuspend(at: at(seconds: 1800)))
        #expect(check(unexplained: 1800, now: 5 * hour, mode: .closed) == .unexplainedSuspend(at: at(seconds: 1800)))
        // A mode changed before the planned end still reads as that.
        #expect(check(unexplained: 1800, now: 3600, mode: .closed) == .modeChanged(at: nil))
    }

    @Test("The service's record of carbs it couldn't read interrupts the fast at it") func runningServiceEndCarbsUnreadable() {
        #expect(
            check(ended: serviceEnd(.carbsUnreadable, after: 1800), now: 3600, mode: .closed)
                == .carbsUnreadable(at: at(seconds: 1800))
        )
    }

    @Test("The service's record of basal stopped without Trio asking stops the fast at it") func runningServiceEndBasalStopped() {
        #expect(
            check(ended: serviceEnd(.basalStopped, after: 1800), now: 3600, mode: .closed)
                == .unexplainedSuspend(at: at(seconds: 1800))
        )
        #expect(
            check(ended: serviceEnd(.basalStopped, after: 4 * hour + 60), now: 5 * hour, mode: .closed) == .completed
        )
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
        #expect(check(unreadable: true, now: 3600, mode: .closed) == .modeChanged(at: nil))
    }

    // MARK: How a running check ends the fast

    @Test("Each running check ends the fast with the reason, time and note the screen gave it") func endingForEachRunningCheck() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        typealias Expected = (check: BasalTestEvaluator.RunningCheck, reason: BasalTestEndReason, at: Date?, note: String?)
        let expected: [Expected] = [
            (.low(at: date), .low, date, nil),
            (.carbsLogged(at: date), .interrupted, date, "Carbs were logged during the fast."),
            (.bolusGiven(at: date), .interrupted, date, "A bolus was given during the fast."),
            (.completed, .completed, nil, nil),
            (.completedUnchecked, .unchecked, nil, nil),
            (.modeChanged(at: nil), .interrupted, nil, "The dosing mode changed during the fast."),
            (
                .modeChangedRestored(at: nil),
                .interrupted,
                nil,
                "The dosing mode changed during the fast, so it has no result. Your usual dosing mode is back."
            ),
            // With the service's record of the change: when another mode was first picked.
            (.modeChanged(at: date), .interrupted, date, "The dosing mode changed during the fast."),
            (
                .modeChangedRestored(at: date),
                .interrupted,
                date,
                "The dosing mode changed during the fast, so it has no result. Your usual dosing mode is back."
            ),
            (
                .unexplainedSuspend(at: date),
                .interrupted,
                date,
                "Basal was stopped during the fast, and Trio can't tell whether it was for a low."
            ),
            (
                .carbsUnreadable(at: date),
                .interrupted,
                date,
                "Trio couldn't read your carbs to check the fast, so it brought your usual dosing back."
            )
        ]
        for item in expected {
            let ending = BasalTestEvaluator.ending(for: item.check)
            #expect(ending.reason == item.reason, "\(item.check)")
            #expect(ending.at == item.at, "\(item.check)")
            #expect(ending.note == item.note, "\(item.check)")
        }
    }

    // MARK: The Result's paragraphs

    /// A finished fast started at 04:00 that planned four hours, with the fields a finish fills in.
    private func finished(
        outcome: BasalTestOutcome,
        reason: BasalTestEndReason,
        ranFor: TimeInterval = 4 * 3600,
        endGlucose: Int? = 110,
        interference: String? = nil,
        interferenceUnread: Bool? = nil
    ) -> BasalTestState {
        var state = runningTest(covered: [scheduleEntry(0, 1440, 1)], scheduledBasal: 1)
        state.isf = 50
        state.phase = .finished
        state.endedAt = state.startedAt.addingTimeInterval(ranFor)
        state.endReason = reason
        state.endGlucose = endGlucose
        state.outcome = outcome
        state.interference = interference
        state.interferenceUnread = interferenceUnread
        return state
    }

    private func paragraphs(of test: BasalTestState) -> [String] {
        guard let outcome = test.outcome else { return [] }
        return BasalTestEvaluator.resultParagraphs(for: outcome, test: test, evaluation: BasalTestEvaluator.evaluation(of: test))
    }

    @Test("The Result's paragraphs are the words the screen showed for each outcome") func resultParagraphsPerOutcome() {
        #expect(
            paragraphs(of: finished(outcome: .steady, reason: .completed))
                == ["Glucose moved less than the smallest basal change in Trio docs would explain."]
        )
        #expect(
            paragraphs(of: finished(outcome: .rising, reason: .completed, endGlucose: 150))
                == ["A higher basal number gives more insulin."]
        )
        #expect(
            paragraphs(of: finished(outcome: .falling, reason: .completed, endGlucose: 70))
                == ["A lower basal number gives less insulin."]
        )
        // A fall with no readings at all says so under its line.
        #expect(
            paragraphs(of: finished(outcome: .falling, reason: .low, endGlucose: nil))
                == [
                    "A lower basal number gives less insulin.",
                    "No CGM readings were recorded during the fast, so there is no end glucose to compare."
                ]
        )
        #expect(
            paragraphs(of: finished(outcome: .invalid, reason: .interrupted, interference: "A bolus was given during the fast."))
                == ["A bolus was given during the fast."]
        )
        // With no note to say what happened, the Result's own sentence.
        #expect(
            paragraphs(of: finished(outcome: .invalid, reason: .interrupted))
                == ["Something changed during the fast, so the result can't be trusted. Try again."]
        )
    }

    @Test("A fast that couldn't be judged says why, and the readings it lacked") func resultParagraphsInconclusive() {
        let unread =
            "Trio couldn't read all its records of carbs, boluses and its own dosing, so it can't tell whether something interrupted this fast."
        let noReadings = "No CGM readings were recorded during the fast, so there is no end glucose to compare."
        #expect(
            paragraphs(of: finished(outcome: .inconclusive, reason: .completed, interferenceUnread: true)) == [unread]
        )
        #expect(
            paragraphs(of: finished(outcome: .inconclusive, reason: .completed, endGlucose: nil, interferenceUnread: true))
                == [unread, noReadings]
        )
        #expect(
            paragraphs(of: finished(outcome: .inconclusive, reason: .unchecked, endGlucose: nil))
                == ["Trio couldn't read the pump history to check for a low, so it can't judge this fast.", noReadings]
        )
        #expect(paragraphs(of: finished(outcome: .inconclusive, reason: .completed, endGlucose: nil)) == [noReadings])
        #expect(
            paragraphs(of: finished(outcome: .inconclusive, reason: .endedEarly, ranFor: 2 * 3600))
                == ["The docs say to fast 4–6 hours, and this one ended after 2 h 00 m. That's too soon to trust."]
        )
        // Ran its hours, but without an ISF there is no working to show.
        var noISF = finished(outcome: .inconclusive, reason: .completed)
        noISF.isf = nil
        #expect(
            paragraphs(of: noISF)
                == ["Trio couldn't read your ISF or basal schedule for these hours, so it can't tell what your basal did."]
        )
    }

    @Test("A fast without an ISF says there is no working to show: rising, falling and too soon") func resultParagraphsNoWorking() {
        let noWorking = "Trio couldn't read your ISF or basal schedule for these hours, so there is no working to show."
        var rising = finished(outcome: .rising, reason: .completed, endGlucose: 150)
        rising.isf = nil
        #expect(paragraphs(of: rising) == ["A higher basal number gives more insulin.", noWorking])

        var falling = finished(outcome: .falling, reason: .completed, endGlucose: 70)
        falling.isf = nil
        #expect(paragraphs(of: falling) == ["A lower basal number gives less insulin.", noWorking])

        // Ended after 2 hours: too soon, and with no ISF there is no working either.
        var tooSoon = finished(outcome: .inconclusive, reason: .endedEarly, ranFor: 2 * 3600)
        tooSoon.isf = nil
        #expect(
            paragraphs(of: tooSoon)
                == ["The docs say to fast 4–6 hours, and this one ended after 2 h 00 m. That's too soon to trust.", noWorking]
        )
    }

    @Test("A fast with an ending decided keeps it through JSON, and one saved without decodes with none") func pendingEndRoundTrip() throws {
        var state = runningTest(covered: nil, scheduledBasal: nil)
        #expect(state.pendingEnd == nil)
        state.pendingEnd = BasalTestPendingEnd(
            reason: .interrupted,
            at: Date(timeIntervalSince1970: 1_000_000),
            note: "Carbs were logged during the fast.",
            byUser: false
        )
        let decoded = try JSONCoding.decoder.decode(BasalTestState.self, from: JSONCoding.encoder.encode(state))
        #expect(decoded == state)
        #expect(decoded.pendingEnd?.reason == .interrupted)

        // Written without the key, as the screen saved it.
        let plain = try JSONCoding.encoder.encode(runningTest(covered: nil, scheduledBasal: nil))
        let text = try #require(String(data: plain, encoding: .utf8))
        #expect(!text.contains("pendingEnd"))
        #expect(try JSONCoding.decoder.decode(BasalTestState.self, from: plain).pendingEnd == nil)
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

@Suite("Settings test service", .serialized, .settingsTestFiles) struct SettingsTestServiceTests {
    private let sessionPath = "trio/settings_test_session.json"
    private let historyPath = "trio/settings_test_history.json"
    private let lastEndPath = "trio/settings_test_last_end.json"

    private func makeService(
        mode: DosingMode,
        existing: SettingsTestSession? = nil,
        events: FakeSettingsTestData = FakeSettingsTestData(),
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
        // The app's broadcaster is shared, so another suite's settings change would reach this service.
        container.register(Broadcaster.self) { _ in SilentBroadcaster() }
        return (BaseSettingsTestService(resolver: container, events: events, runtime: .inert), settings, storage)
    }

    /// A test of `kind` (a basal test unless said) running in Basal Testing, from Closed Loop, begun just now.
    private func startBasalTest(
        events: FakeSettingsTestData,
        kind: SettingsTestKind = .basal
    ) -> (BaseSettingsTestService, FakeSettingsManager, FileStorage, SettingsTestSession) {
        let (service, settings, storage) = makeService(mode: .closed, events: events)
        let session = service.begin(
            kind: kind,
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
        let events = FakeSettingsTestData()
        // Started an hour ago, on a whole second, so the suspend is in the past and the kept record reads back exactly.
        let startedAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded(.down))
        let session = SettingsTestSession(
            kind: .basal,
            startedAt: startedAt,
            expiresAt: Date().addingTimeInterval(3600),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )
        // Set before the service exists, because a recovered session is checked as soon as it is made.
        let suspendedAt = startedAt.addingTimeInterval(600)
        events.trioSuspends(at: suspendedAt)
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
        // Why and when, for the basal screen to finish the result from.
        let expected = SettingsTestEnd(sessionID: session.id, cause: .low, date: suspendedAt)
        #expect(service.lastEnd() == expected)
        // Kept on disk, so it is still there after a relaunch.
        let (relaunched, _, _) = makeService(mode: .closed, keepingFiles: true)
        #expect(relaunched.lastEnd() == expected)
    }

    @Test(
        "Basal stopped without Trio asking ends a basal test, and isn't kept as a low"
    ) func unaskedZeroTempEndsSession() async {
        let events = FakeSettingsTestData()
        // On a whole second, so the kept record reads back exactly.
        let startedAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded(.down))
        let session = SettingsTestSession(
            kind: .basal,
            startedAt: startedAt,
            expiresAt: Date().addingTimeInterval(3600),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )
        // A zero temp set on the pump, with Trio's last zero temp determination long before it.
        let stoppedAt = startedAt.addingTimeInterval(1200)
        events.temps = [BasalTestTempBasal(date: stoppedAt, rate: 0, minutes: 60)]
        events.zeroTempDeterminations = [startedAt.addingTimeInterval(-3600)]
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
        #expect(service.lastEnd() == SettingsTestEnd(sessionID: session.id, cause: .basalStopped, date: stoppedAt))
    }

    @Test("Carbs logged during a basal test end it with nobody on its screen") func carbsEndSession() async {
        let events = FakeSettingsTestData()
        let (service, settings, storage, session) = startBasalTest(events: events)
        defer { cleanUp(storage) }

        events.carbs = [session.startedAt]
        let before = Date()
        await service.endIfLowOrInterrupted()
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
        let events = FakeSettingsTestData()
        let (service, settings, storage, session) = startBasalTest(events: events)
        defer { cleanUp(storage) }

        var recordWhenModeChanged: SettingsTestEnd?
        var modeChanges = 0
        settings.onSettingsChange = {
            modeChanges += 1
            recordWhenModeChanged = service.lastEnd()
        }
        events.basalTestingSuspends(at: session.startedAt, startedAt: session.startedAt)
        await service.endIfLowOrInterrupted()
        #expect(modeChanges == 1)
        #expect(recordWhenModeChanged?.sessionID == session.id)
        #expect(recordWhenModeChanged?.cause == .low)
    }

    @Test("Carbs end a basal test even when the temp basals can't be read") func carbsEndWhenTempsUnreadable() async {
        let events = FakeSettingsTestData()
        let (service, settings, storage, session) = startBasalTest(events: events)
        defer { cleanUp(storage) }

        events.failingTemps = true
        events.carbs = [session.startedAt]
        await service.endIfLowOrInterrupted()
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
        #expect(service.lastEnd()?.cause == .carbsLogged)
    }

    @Test("Carbs end a basal or ISF test; another kind in Basal Testing keeps running") func carbsEndOnlyBasalAndISF() async {
        let events = FakeSettingsTestData()
        let (service, settings, storage) = makeService(mode: .closed, events: events)
        defer { cleanUp(storage) }

        let session = service.begin(
            kind: .carbRatio,
            expiresIn: 3600,
            restoring: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )!
        settings.settings.dosingMode = .basalTesting
        events.carbs = [session.startedAt]
        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(service.lastEnd() == nil)
    }

    /// A test of `kind` (an ISF test unless said) that began `age` ago (an hour unless said), on a whole second so that
    /// what the service keeps reads back exactly, and is in Basal Testing. An ISF test settled `settledAfter` its start,
    /// at once unless said, so its bolus window runs from Start as before settling was kept; nil for one still settling.
    /// Set the events from its start before making the service with it: a session found at launch is checked at once,
    /// so they can't change after that.
    private func runningSession(
        kind: SettingsTestKind = .isf,
        age: TimeInterval = 3600,
        settledAfter: TimeInterval? = 0
    ) -> SettingsTestSession {
        let startedAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - age).rounded(.down))
        return SettingsTestSession(
            kind: kind,
            startedAt: startedAt,
            expiresAt: Date().addingTimeInterval(3600),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)],
            bolusWindowStart: kind == .isf ? settledAfter.map { startedAt.addingTimeInterval($0) } : nil,
            // Begun with settling, as an ISF test now is.
            settles: kind == .isf ? true : nil
        )
    }

    @Test(
        "An ISF session saved before settling was kept has its bolus window from Start, as it had then"
    ) func oldISFSessionWindowFromStart() async throws {
        let startedAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 7200).rounded(.down))
        let iso = ISO8601DateFormatter()
        // A session file as the build before settling wrote it: no bolus window start, no mark that it settles.
        let json = """
        {
          "id": "8B1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D",
          "kind": "isf",
          "startedAt": "\(iso.string(from: startedAt))",
          "expiresAt": "\(iso.string(from: startedAt.addingTimeInterval(6 * 3600)))",
          "restore": [{"dosingMode": {"testMode": "basalTesting", "previous": "closed"}}]
        }
        """
        let old = try JSONCoding.decoder.decode(SettingsTestSession.self, from: Data(json.utf8))
        #expect(old.settles == nil)
        #expect(old.bolusWindowStart == nil)
        #expect(old.bolusWindowStartInEffect == startedAt)

        // Two hours in with no bolus: ended for no bolus at its 90 minutes, as it was then, not left settling to 150.
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: old, events: FakeSettingsTestData())
        defer { cleanUp(storage) }
        await service.endIfLowOrInterrupted()
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
        #expect(
            service.lastEnd() == SettingsTestEnd(
                sessionID: old.id,
                cause: .noBolus,
                date: startedAt.addingTimeInterval(ISFTest.Config.doseAllowance)
            )
        )
    }

    @Test("A session marked as one that settles has no bolus window until settling ends") func settlingSessionWindow() {
        var session = runningSession(settledAfter: nil)
        #expect(session.settles == true)
        #expect(session.bolusWindowStartInEffect == nil)
        session.bolusWindowStart = session.startedAt.addingTimeInterval(600)
        #expect(session.bolusWindowStartInEffect == session.startedAt.addingTimeInterval(600))
        // Begin marks an ISF session that settles; a basal one isn't marked.
        let (service, _, storage) = makeService(mode: .closed)
        defer { cleanUp(storage) }
        let begun = service.begin(
            kind: .isf,
            expiresIn: 3600,
            restoring: [.dosingMode(testMode: .basalTesting, previous: .closed)],
            settles: true
        )
        #expect(begun?.settles == true)
        #expect(storage.retrieve(sessionPath, as: SettingsTestSession.self)?.settles == true)
        service.end(kind: .isf)
        #expect(service.begin(kind: .basal, expiresIn: 3600, restoring: [])?.settles == nil)
    }

    @Test(
        "A check acts on what it found only if its session is still running with the same bolus window start"
    ) func checkActsOnlyOnAnUnchangedSession() {
        let copy = runningSession(settledAfter: nil)
        #expect(BaseSettingsTestService.isUnchanged(copy, live: copy))
        // Ended while the check read the history.
        #expect(!BaseSettingsTestService.isUnchanged(copy, live: nil))
        // Another session began.
        #expect(!BaseSettingsTestService.isUnchanged(copy, live: runningSession(settledAfter: nil)))
        // Settling ended while it read, so no bolus while settling no longer holds.
        var settled = copy
        settled.bolusWindowStart = copy.startedAt.addingTimeInterval(600)
        #expect(!BaseSettingsTestService.isUnchanged(copy, live: settled))
        // A later expiry alone changes nothing the check decided on.
        var extended = copy
        extended.expiresAt = copy.expiresAt.addingTimeInterval(3600)
        #expect(BaseSettingsTestService.isUnchanged(copy, live: extended))
    }

    // MARK: ISF settling

    @Test(
        "While an ISF test settles, a second bolus doesn't end it, and no bolus doesn't before the time for settling and the dose"
    ) func settlingKeepsISF() async {
        let events = FakeSettingsTestData()
        // Two hours in, past the 90 minutes a settled test would have for its bolus, with an SMB at Begin and a bolus.
        let session = runningSession(age: 7200, settledAfter: nil)
        events.smbFlaggedBoluses = [ISFTestBolus(date: session.startedAt.addingTimeInterval(5), units: dec("0.3"))]
        events.boluses = [ISFTestBolus(date: session.startedAt.addingTimeInterval(1800), units: 2)]
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(service.lastEnd() == nil)
    }

    @Test("A minute short of the time for settling and the dose, an ISF test still settling keeps running") func settlingNotOver() async {
        let events = FakeSettingsTestData()
        let session = runningSession(
            age: ISFTest.Config.settleAllowance + ISFTest.Config.doseAllowance - 60,
            settledAfter: nil
        )
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(service.lastEnd() == nil)
    }

    @Test(
        "An ISF test still settling once the time for settling and the dose is up ends for no bolus, dated then"
    ) func settlingOverEndsISF() async {
        let events = FakeSettingsTestData()
        let wait = ISFTest.Config.settleAllowance + ISFTest.Config.doseAllowance
        let session = runningSession(age: wait + 60, settledAfter: nil)
        // A bolus given while it settled isn't the test's.
        events.boluses = [ISFTestBolus(date: session.startedAt.addingTimeInterval(600), units: 2)]
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
        #expect(
            service.lastEnd() == SettingsTestEnd(
                sessionID: session.id,
                cause: .noBolus,
                date: session.startedAt.addingTimeInterval(wait)
            )
        )
    }

    @Test(
        "Once an ISF test has settled, an SMB from before its bolus window and the user's bolus aren't two boluses"
    ) func straySMBBeforeWindowKeepsISF() async {
        let events = FakeSettingsTestData()
        let session = runningSession(age: 3600, settledAfter: 600)
        events.smbFlaggedBoluses = [ISFTestBolus(date: session.startedAt.addingTimeInterval(5), units: dec("0.3"))]
        events.boluses = [ISFTestBolus(date: session.startedAt.addingTimeInterval(1200), units: 2)]
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(service.lastEnd() == nil)
    }

    @Test(
        "Once an ISF test has settled, a second bolus in its window ends it, dated at that bolus"
    ) func secondBolusAfterWindowEndsISF() async {
        let events = FakeSettingsTestData()
        let session = runningSession(age: 3600, settledAfter: 600)
        let second = session.startedAt.addingTimeInterval(2400)
        events.smbFlaggedBoluses = [ISFTestBolus(date: session.startedAt.addingTimeInterval(5), units: dec("0.3"))]
        events.boluses = [
            ISFTestBolus(date: session.startedAt.addingTimeInterval(1200), units: 2),
            ISFTestBolus(date: second, units: 1)
        ]
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
        #expect(service.lastEnd() == SettingsTestEnd(sessionID: session.id, cause: .extraBolus, date: second))
    }

    @Test(
        "Once an ISF test has settled, its 90 minutes for the bolus run from the end of settling"
    ) func doseDeadlineFromWindowStart() async {
        let settled: TimeInterval = 1800
        // A minute short of the deadline from the end of settling, which is well past 90 minutes from Start.
        let early = runningSession(age: settled + ISFTest.Config.doseAllowance - 60, settledAfter: settled)
        var (service, settings, storage) = makeService(mode: .basalTesting, existing: early, events: FakeSettingsTestData())
        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == early.id)
        #expect(service.lastEnd() == nil)
        cleanUp(storage)

        let late = runningSession(age: settled + ISFTest.Config.doseAllowance + 60, settledAfter: settled)
        (service, settings, storage) = makeService(mode: .basalTesting, existing: late, events: FakeSettingsTestData())
        defer { cleanUp(storage) }
        await service.endIfLowOrInterrupted()
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
        let deadline = late.startedAt.addingTimeInterval(settled + ISFTest.Config.doseAllowance)
        #expect(service.lastEnd() == SettingsTestEnd(sessionID: late.id, cause: .noBolus, date: deadline))
    }

    @Test(
        "The bolus window start is kept only for the running session of that kind, and survives a relaunch"
    ) func setBolusWindowStart() {
        let (service, settings, storage) = makeService(mode: .closed)
        defer { cleanUp(storage) }
        let at = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 60).rounded(.down))

        // No session: nothing to keep it on.
        service.setBolusWindowStart(kind: .isf, at: at)
        #expect(service.activeSession == nil)

        let session = service.begin(
            kind: .isf,
            expiresIn: 3600,
            restoring: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )!
        settings.settings.dosingMode = .basalTesting
        #expect(session.bolusWindowStart == nil)

        // Another kind's is not this one's.
        service.setBolusWindowStart(kind: .basal, at: at)
        #expect(service.activeSession?.bolusWindowStart == nil)

        service.setBolusWindowStart(kind: .isf, at: at)
        #expect(service.activeSession?.bolusWindowStart == at)
        #expect(storage.retrieve(sessionPath, as: SettingsTestSession.self)?.bolusWindowStart == at)

        let (relaunched, _, _) = makeService(mode: .basalTesting, keepingFiles: true)
        #expect(relaunched.activeSession?.id == session.id)
        #expect(relaunched.activeSession?.bolusWindowStart == at)
    }

    @Test(
        "The bolus window start makes an ISF session last until its test's latest end from there, and never shortens it"
    ) func bolusWindowStartExtendsExpiry() {
        let (service, settings, storage) = makeService(mode: .closed)
        defer { cleanUp(storage) }
        let session = service.begin(
            kind: .isf,
            expiresIn: 3600,
            restoring: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )!
        settings.settings.dosingMode = .basalTesting
        let fromWindow = ISFTest.Config.doseAllowance + ISFTest.Config.docsWait + ISFTest.Config.expiryGrace

        // Settled two hours after Begin, with the expiry an hour from Begin: the session now lasts the bolus window, the
        // 4 hours and the grace after them.
        let late = session.startedAt.addingTimeInterval(2 * 3600)
        service.setBolusWindowStart(kind: .isf, at: late)
        #expect(service.activeSession?.expiresAt == late.addingTimeInterval(fromWindow))
        // Saved with it, to the millisecond a date keeps on disk.
        let saved = storage.retrieve(sessionPath, as: SettingsTestSession.self)?.expiresAt
        #expect(saved.map { abs($0.timeIntervalSince(late.addingTimeInterval(fromWindow))) < 0.001 } == true)

        // An earlier window start doesn't bring the expiry back.
        let early = session.startedAt.addingTimeInterval(60)
        service.setBolusWindowStart(kind: .isf, at: early)
        #expect(service.activeSession?.bolusWindowStart == early)
        #expect(service.activeSession?.expiresAt == late.addingTimeInterval(fromWindow))
    }

    @Test("A session already lasting past its test's latest end keeps its expiry") func bolusWindowStartKeepsLongerExpiry() {
        let (service, settings, storage) = makeService(mode: .closed)
        defer { cleanUp(storage) }
        let session = service.begin(
            kind: .isf,
            expiresIn: 10 * 3600,
            restoring: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )!
        settings.settings.dosingMode = .basalTesting
        service.setBolusWindowStart(kind: .isf, at: session.startedAt.addingTimeInterval(600))
        #expect(service.activeSession?.expiresAt == session.expiresAt)
    }

    @Test("Carbs logged during an ISF test end it with nobody on its screen") func carbsEndISF() async {
        let events = FakeSettingsTestData()
        let (service, settings, storage, session) = startBasalTest(events: events, kind: .isf)
        defer { cleanUp(storage) }

        events.carbs = [session.startedAt]
        let before = Date()
        await service.endIfLowOrInterrupted()
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

    @Test("A second manual bolus ends an ISF test, dated at that bolus, and the usual mode comes back") func secondBolusEndsISF() async {
        let events = FakeSettingsTestData()
        let session = runningSession()
        let second = session.startedAt.addingTimeInterval(1800)
        events.boluses = [
            ISFTestBolus(date: session.startedAt.addingTimeInterval(600), units: 2),
            ISFTestBolus(date: second, units: 1)
        ]
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
        // Dated at the second bolus, not at the time found, so the screen can tell it from one after the planned end.
        #expect(service.lastEnd() == SettingsTestEnd(sessionID: session.id, cause: .extraBolus, date: second))
        #expect(storage.retrieve(sessionPath, as: SettingsTestSession.self) == nil)
    }

    @Test("The second of three manual boluses is the one the end is dated at") func extraBolusDatedAtTheSecond() async {
        let events = FakeSettingsTestData()
        let session = runningSession()
        let second = session.startedAt.addingTimeInterval(1200)
        events.boluses = [
            ISFTestBolus(date: session.startedAt.addingTimeInterval(2400), units: 1),
            ISFTestBolus(date: session.startedAt.addingTimeInterval(600), units: 2),
            ISFTestBolus(date: second, units: 1)
        ]
        let (service, _, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.lastEnd() == SettingsTestEnd(sessionID: session.id, cause: .extraBolus, date: second))
    }

    @Test("One manual bolus is the test's own, so the ISF test keeps running") func firstBolusKeepsISF() async {
        let events = FakeSettingsTestData()
        let session = runningSession()
        events.boluses = [ISFTestBolus(date: session.startedAt.addingTimeInterval(600), units: 2)]
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(events.reads > 0)
        #expect(service.lastEnd() == nil)
    }

    @Test("Boluses from before the test began don't count towards a second one") func earlierBolusesDontCount() async {
        let events = FakeSettingsTestData()
        let session = runningSession()
        events.boluses = [
            ISFTestBolus(date: session.startedAt.addingTimeInterval(-1200), units: 3),
            ISFTestBolus(date: session.startedAt.addingTimeInterval(-600), units: 1),
            ISFTestBolus(date: session.startedAt.addingTimeInterval(600), units: 2)
        ]
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(service.lastEnd() == nil)
    }

    @Test("A basal test ignores how many boluses there were") func basalIgnoresBolusCount() async {
        let events = FakeSettingsTestData()
        let session = runningSession(kind: .basal)
        events.boluses = [
            ISFTestBolus(date: session.startedAt.addingTimeInterval(600), units: 2),
            ISFTestBolus(date: session.startedAt.addingTimeInterval(1200), units: 1),
            ISFTestBolus(date: session.startedAt.addingTimeInterval(1800), units: 1)
        ]
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(service.lastEnd() == nil)
    }

    @Test("A suspend comes before logged carbs and a second bolus in an ISF test") func suspendBeatsCarbsAndBolus() async {
        let events = FakeSettingsTestData()
        let session = runningSession()
        let suspendedAt = session.startedAt.addingTimeInterval(900)
        events.trioSuspends(at: suspendedAt)
        events.carbs = [session.startedAt.addingTimeInterval(600)]
        events.boluses = [
            ISFTestBolus(date: session.startedAt.addingTimeInterval(300), units: 2),
            ISFTestBolus(date: session.startedAt.addingTimeInterval(600), units: 1)
        ]
        let (service, _, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.lastEnd() == SettingsTestEnd(sessionID: session.id, cause: .low, date: suspendedAt))
    }

    @Test("Logged carbs come before a second bolus in an ISF test") func carbsBeatSecondBolus() async {
        let events = FakeSettingsTestData()
        let session = runningSession()
        events.carbs = [session.startedAt.addingTimeInterval(600)]
        events.boluses = [
            ISFTestBolus(date: session.startedAt.addingTimeInterval(300), units: 2),
            ISFTestBolus(date: session.startedAt.addingTimeInterval(600), units: 1)
        ]
        let (service, _, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.lastEnd()?.sessionID == session.id)
        #expect(service.lastEnd()?.cause == .carbsLogged)
    }

    @Test("When the bolus history can't be read, the ISF test keeps running") func bolusReadFailureLeavesISF() async {
        let events = FakeSettingsTestData()
        let session = runningSession()
        events.failingBoluses = true
        events.boluses = [
            ISFTestBolus(date: session.startedAt.addingTimeInterval(600), units: 2),
            ISFTestBolus(date: session.startedAt.addingTimeInterval(1200), units: 1)
        ]
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(service.lastEnd() == nil)
    }

    @Test(
        "A bolus cancelled before anything was given isn't one, so the right bolus after it keeps the ISF test running"
    ) func cancelledBolusDoesntCount() async {
        let events = FakeSettingsTestData()
        let session = runningSession()
        events.boluses = [
            ISFTestBolus(date: session.startedAt.addingTimeInterval(300), units: 0),
            ISFTestBolus(date: session.startedAt.addingTimeInterval(600), units: 2)
        ]
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(service.lastEnd() == nil)
    }

    @Test("A cancelled bolus doesn't count towards a second one either") func cancelledBolusDoesntShiftTheSecond() async {
        let events = FakeSettingsTestData()
        let session = runningSession()
        let second = session.startedAt.addingTimeInterval(900)
        events.boluses = [
            ISFTestBolus(date: session.startedAt.addingTimeInterval(300), units: 0),
            ISFTestBolus(date: session.startedAt.addingTimeInterval(600), units: 2),
            ISFTestBolus(date: second, units: 1)
        ]
        let (service, _, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.lastEnd() == SettingsTestEnd(sessionID: session.id, cause: .extraBolus, date: second))
    }

    @Test(
        "With no bolus by the dose deadline an ISF test ends, dated at the deadline, and the usual mode comes back"
    ) func noBolusEndsISF() async {
        let events = FakeSettingsTestData()
        // Two hours in, with nothing given.
        let session = runningSession(age: 7200)
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
        let deadline = session.startedAt.addingTimeInterval(ISFTest.Config.doseAllowance)
        #expect(service.lastEnd() == SettingsTestEnd(sessionID: session.id, cause: .noBolus, date: deadline))
        #expect(storage.retrieve(sessionPath, as: SettingsTestSession.self) == nil)
    }

    @Test(
        "A bolus that came after the dose deadline isn't the test's, so the test still ends for no bolus"
    ) func lateBolusIsNoBolus() async {
        let events = FakeSettingsTestData()
        let session = runningSession(age: 7200)
        events.boluses = [ISFTestBolus(date: session.startedAt.addingTimeInterval(6000), units: 2)]
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
        let deadline = session.startedAt.addingTimeInterval(ISFTest.Config.doseAllowance)
        #expect(service.lastEnd() == SettingsTestEnd(sessionID: session.id, cause: .noBolus, date: deadline))
    }

    @Test("A bolus cancelled before anything was given doesn't stop the test ending for no bolus") func cancelledBolusIsNoBolus() async {
        let events = FakeSettingsTestData()
        let session = runningSession(age: 7200)
        events.boluses = [ISFTestBolus(date: session.startedAt.addingTimeInterval(300), units: 0)]
        let (service, _, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.lastEnd()?.cause == .noBolus)
    }

    @Test("A bolus before the dose deadline keeps an ISF test running long after it") func bolusBeforeDeadlineKeepsISF() async {
        let events = FakeSettingsTestData()
        let session = runningSession(age: 7200)
        events.boluses = [ISFTestBolus(date: session.startedAt.addingTimeInterval(1200), units: 2)]
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(service.lastEnd() == nil)
    }

    @Test(
        "Half an hour after an ISF test's 4 hours the usual mode comes back, with no reason kept, as on expiry"
    ) func waitOverEndsISF() async {
        let events = FakeSettingsTestData()
        // The bolus went in 20 minutes after Start, 4 h 30 min ago.
        let wait = ISFTest.Config.docsWait + ISFTest.Config.expiryGrace
        let session = runningSession(age: wait + 1200)
        events.boluses = [ISFTestBolus(date: session.startedAt.addingTimeInterval(1200), units: 2)]
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
        #expect(storage.retrieve(sessionPath, as: SettingsTestSession.self) == nil)
        // Nothing went wrong, so the screen finishes the test as completed when it is opened.
        #expect(service.lastEnd() == nil)
    }

    @Test("A minute short of half an hour after the 4 hours an ISF test keeps running") func waitNotOverKeepsISF() async {
        let events = FakeSettingsTestData()
        let wait = ISFTest.Config.docsWait + ISFTest.Config.expiryGrace - 60
        let session = runningSession(age: wait + 1200)
        events.boluses = [ISFTestBolus(date: session.startedAt.addingTimeInterval(1200), units: 2)]
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(service.lastEnd() == nil)
    }

    @Test("A basal test isn't ended for an ISF test's wait") func basalIgnoresISFWait() async {
        let events = FakeSettingsTestData()
        let session = runningSession(kind: .basal, age: ISFTest.Config.docsWait + ISFTest.Config.expiryGrace + 1200)
        events.boluses = [ISFTestBolus(date: session.startedAt.addingTimeInterval(1200), units: 2)]
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)
    }

    @Test(
        "A test bolus the pump history flagged as an SMB is still the test bolus, so the test isn't ended for no bolus"
    ) func smbFlaggedTestBolusKeepsISF() async {
        let events = FakeSettingsTestData()
        let session = runningSession(age: 7200)
        events.smbFlaggedBoluses = [ISFTestBolus(date: session.startedAt.addingTimeInterval(1200), units: 2)]
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(service.lastEnd() == nil)
    }

    @Test("A second bolus flagged as an SMB still ends an ISF test, dated at that bolus") func smbFlaggedSecondBolusEndsISF() async {
        let events = FakeSettingsTestData()
        let session = runningSession(age: 3600)
        let second = session.startedAt.addingTimeInterval(2400)
        events.boluses = [ISFTestBolus(date: session.startedAt.addingTimeInterval(1200), units: 2)]
        events.smbFlaggedBoluses = [ISFTestBolus(date: second, units: dec("0.5"))]
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
        #expect(service.lastEnd() == SettingsTestEnd(sessionID: session.id, cause: .extraBolus, date: second))
    }

    @Test("A basal test isn't ended for boluses flagged as SMBs, as for any bolus") func basalIgnoresSMBFlaggedBoluses() async {
        let events = FakeSettingsTestData()
        let session = runningSession(kind: .basal, age: 7200)
        events.smbFlaggedBoluses = [
            ISFTestBolus(date: session.startedAt.addingTimeInterval(1200), units: 2),
            ISFTestBolus(date: session.startedAt.addingTimeInterval(2400), units: 1)
        ]
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(service.lastEnd() == nil)
    }

    private func dec(_ string: String) -> Decimal { Decimal(string: string)! }

    @Test("Before the dose deadline no bolus yet doesn't end an ISF test") func noBolusYetKeepsISF() async {
        let events = FakeSettingsTestData()
        // An hour in, 30 minutes short of the deadline.
        let session = runningSession(age: 3600)
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(service.lastEnd() == nil)
    }

    @Test("A basal test is never ended for having no bolus") func basalNeverEndsForNoBolus() async {
        let events = FakeSettingsTestData()
        let session = runningSession(kind: .basal, age: 7200)
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(service.lastEnd() == nil)
    }

    @Test("Logged carbs come before no bolus when an ISF test is ended") func carbsBeatNoBolus() async {
        let events = FakeSettingsTestData()
        let session = runningSession(age: 7200)
        events.carbs = [session.startedAt.addingTimeInterval(600)]
        let (service, _, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.lastEnd()?.cause == .carbsLogged)
    }

    @Test("When the bolus history can't be read, an ISF test with no bolus keeps running") func noBolusNeedsReadableHistory() async {
        let events = FakeSettingsTestData()
        events.failingBoluses = true
        let session = runningSession(age: 7200)
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(service.lastEnd() == nil)
    }

    @Test("The watchdog's check ends an ISF test on a second bolus") func checkSessionEndsISFOnSecondBolus() async {
        let events = FakeSettingsTestData()
        let session = runningSession()
        events.boluses = [
            ISFTestBolus(date: session.startedAt.addingTimeInterval(600), units: 2),
            ISFTestBolus(date: session.startedAt.addingTimeInterval(1200), units: 1)
        ]
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.checkSession()
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
        #expect(service.lastEnd()?.cause == .extraBolus)
    }

    @Test(
        "Basal stopped without Trio asking ends an ISF test, before carbs and boluses, and isn't kept as a low"
    ) func unaskedZeroTempEndsISF() async {
        let events = FakeSettingsTestData()
        let session = runningSession()
        // A zero temp set on the pump, with Trio's last zero temp determination long before it.
        let stoppedAt = session.startedAt.addingTimeInterval(900)
        events.temps = [BasalTestTempBasal(date: stoppedAt, rate: 0, minutes: 60)]
        events.zeroTempDeterminations = [session.startedAt.addingTimeInterval(-3600)]
        events.carbs = [session.startedAt.addingTimeInterval(600)]
        events.boluses = [
            ISFTestBolus(date: session.startedAt.addingTimeInterval(300), units: 2),
            ISFTestBolus(date: session.startedAt.addingTimeInterval(600), units: 1)
        ]
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
        #expect(service.lastEnd() == SettingsTestEnd(sessionID: session.id, cause: .basalStopped, date: stoppedAt))
    }

    @Test("Carbs that can't be read end an ISF test, so the usual dosing comes back") func carbsUnreadableEndsISF() async {
        let events = FakeSettingsTestData()
        let (service, settings, storage, session) = startBasalTest(events: events, kind: .isf)
        defer { cleanUp(storage) }

        events.failingCarbs = true
        await service.endIfLowOrInterrupted()
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
        #expect(service.lastEnd()?.sessionID == session.id)
        #expect(service.lastEnd()?.cause == .carbsUnreadable)
    }

    @Test("Carbs that can't be read come before a second bolus in an ISF test") func carbsUnreadableBeatsSecondBolus() async {
        let events = FakeSettingsTestData()
        let session = runningSession()
        events.failingCarbs = true
        events.boluses = [
            ISFTestBolus(date: session.startedAt.addingTimeInterval(300), units: 2),
            ISFTestBolus(date: session.startedAt.addingTimeInterval(600), units: 1)
        ]
        let (service, _, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.lastEnd()?.cause == .carbsUnreadable)
    }

    @Test(
        "When the temp basals can't be read, an ISF test still ends for a second bolus"
    ) func secondBolusEndsISFWhenTempsUnreadable() async {
        let events = FakeSettingsTestData()
        let session = runningSession()
        let second = session.startedAt.addingTimeInterval(1800)
        events.failingTemps = true
        events.boluses = [
            ISFTestBolus(date: session.startedAt.addingTimeInterval(600), units: 2),
            ISFTestBolus(date: second, units: 1)
        ]
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
        #expect(service.lastEnd() == SettingsTestEnd(sessionID: session.id, cause: .extraBolus, date: second))
    }

    @Test("A low from before the mode was changed still ends an ISF test as a low") func lowBeforeModeChangeISF() async {
        let events = FakeSettingsTestData()
        let (service, settings, storage, session) = startBasalTest(events: events, kind: .isf)
        defer { cleanUp(storage) }

        // Started as the test began, and asked for by Basal Testing's first loop, a minute after Begin, within the time a
        // determination can trail the zero temp it asked for.
        events.temps = [BasalTestTempBasal(date: session.startedAt, rate: 0, minutes: 30)]
        events.zeroTempDeterminations = [session.startedAt.addingTimeInterval(ISFTest.Config.settleLoopMargin)]
        settings.settings.dosingMode = .closed
        #expect(service.noteTestModeLeft())
        await service.endIfLowOrInterrupted()
        #expect(service.activeSession == nil)
        #expect(service.lastEnd()?.sessionID == session.id)
        #expect(service.lastEnd()?.cause == .low)
        // The mode the user picked stays.
        #expect(settings.settings.dosingMode == .closed)
    }

    @Test(
        "After the mode was changed, an ISF test ends as a mode change, not for a second bolus, no bolus or carbs"
    ) func afterModeChangeISF() async {
        let events = FakeSettingsTestData()
        // Past the dose deadline with two boluses and carbs, all of which would end it in Basal Testing.
        var session = runningSession(age: 7200)
        session.leftTestModeAt = session.startedAt.addingTimeInterval(60)
        events.carbs = [session.startedAt.addingTimeInterval(600)]
        events.boluses = [
            ISFTestBolus(date: session.startedAt.addingTimeInterval(300), units: 2),
            ISFTestBolus(date: session.startedAt.addingTimeInterval(600), units: 1)
        ]
        // The new mode's zero temp, after the change.
        events.trioSuspends(at: session.startedAt.addingTimeInterval(120))
        let (service, settings, storage) = makeService(mode: .closed, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession == nil)
        // The user's Closed Loop is left as it is, and the record says nothing was put back.
        #expect(service.lastEnd() == SettingsTestEnd(
            sessionID: session.id,
            cause: .modeChanged,
            date: session.leftTestModeAt!,
            modeRestored: false
        ))
        #expect(settings.settings.dosingMode == .closed)
    }

    /// How a session ends after the user picked another mode, for each way it can happen.
    private enum ModeChangeCase: CaseIterable {
        /// Away from Basal Testing, and still away when the session ends.
        case awayAndStay
        /// Away and back to Basal Testing before the check that ends the session ran.
        case awayAndBack
        /// The session ran past its deadline after the change, back in Basal Testing.
        case expiryAfterChange
        /// Trio suspended for a low before the change, and the user came back to Basal Testing.
        case lowBeforeChange
    }

    @Test(
        "After a mode change, a session's end puts the usual mode back only if Basal Testing is on, basal and ISF alike"
    ) func modeAfterTheSessionEnds() async {
        for kind in [SettingsTestKind.basal, .isf] {
            for item in ModeChangeCase.allCases {
                let events = FakeSettingsTestData()
                var session = runningSession(kind: kind, age: 3600)
                let leftAt = session.startedAt.addingTimeInterval(1800)
                session.leftTestModeAt = leftAt
                if item == .expiryAfterChange { session.expiresAt = Date().addingTimeInterval(-60) }
                if item == .lowBeforeChange { events.trioSuspends(at: session.startedAt.addingTimeInterval(900)) }
                // The mode in force when the session ends.
                let mode: DosingMode = item == .awayAndStay ? .lowGlucoseSuspend : .basalTesting
                let (service, settings, storage) = makeService(mode: mode, existing: session, events: events)
                defer { cleanUp(storage) }

                await service.checkSession()
                let label = "\(kind), \(item)"
                #expect(service.activeSession == nil, "\(label)")
                // Basal Testing on: the usual mode is back. Another mode: the user's, left alone.
                #expect(settings.settings.dosingMode == (item == .awayAndStay ? .lowGlucoseSuspend : .closed), "\(label)")
                let ended = service.lastEnd()
                #expect(ended?.sessionID == session.id, "\(label)")
                if item == .lowBeforeChange {
                    // The low before the change keeps its cause.
                    #expect(ended?.cause == .low, "\(label)")
                } else {
                    #expect(ended?.cause == .modeChanged, "\(label)")
                    #expect(ended?.modeRestored == (item != .awayAndStay), "\(label)")
                    #expect(abs((ended?.date ?? .distantPast).timeIntervalSince(leftAt)) < 0.01, "\(label)")
                }
            }
        }
    }

    @Test(
        "Switched away from Basal Testing and back between checks, the test's end puts the usual mode back and says so"
    ) func modeSwitchedAwayAndBack() async {
        for kind in [SettingsTestKind.isf, .basal] {
            let events = FakeSettingsTestData()
            let (service, settings, storage, session) = startBasalTest(events: events, kind: kind)
            defer { cleanUp(storage) }

            settings.settings.dosingMode = .closed
            let leftAt = session.startedAt.addingTimeInterval(1)
            #expect(service.noteTestModeLeft(at: leftAt))
            // The user picks Basal Testing again before the check runs.
            settings.settings.dosingMode = .basalTesting
            await service.endIfLowOrInterrupted()
            #expect(service.activeSession == nil)
            let ended = service.lastEnd()
            #expect(ended?.sessionID == session.id)
            #expect(ended?.cause == .modeChanged)
            #expect(ended?.modeRestored == true)
            #expect(settings.settings.dosingMode == .closed)
            // So neither screen says Basal Testing is still on.
            #expect(!SettingsTestModeRule.basalTestingLeftOn(mode: settings.settings.dosingMode, activeSessionID: nil))
        }
        // Back in Basal Testing after the session ended, with no test running it: the Results say so.
        #expect(SettingsTestModeRule.basalTestingLeftOn(mode: .basalTesting, activeSessionID: nil))
        #expect(!SettingsTestModeRule.basalTestingLeftOn(mode: .basalTesting, activeSessionID: UUID()))
        #expect(!SettingsTestModeRule.basalTestingLeftOn(mode: .closed, activeSessionID: nil))
    }

    @Test("A history that can't be read to rule out a low before the mode change waits for the next check") func modeChangeUnread() async {
        let events = FakeSettingsTestData()
        let (service, settings, storage, session) = startBasalTest(events: events, kind: .isf)
        defer { cleanUp(storage) }

        settings.settings.dosingMode = .closed
        #expect(service.noteTestModeLeft(at: session.startedAt.addingTimeInterval(1)))
        events.failingTemps = true
        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == session.id)
        #expect(service.lastEnd() == nil)
    }

    @Test(
        "A session that expires after the mode was left keeps why, and its end leaves no lost session for a screen to restore"
    ) func expiryAfterModeLeft() async {
        var session = runningSession(age: 7200)
        session.expiresAt = Date().addingTimeInterval(-60)
        session.leftTestModeAt = session.startedAt.addingTimeInterval(60)
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: FakeSettingsTestData())
        defer { cleanUp(storage) }

        service.endIfExpired()
        #expect(service.activeSession == nil)
        // Back in Basal Testing at the end: the usual mode comes back.
        #expect(settings.settings.dosingMode == .closed)
        #expect(service.lastEnd()?.sessionID == session.id)
        #expect(service.lastEnd()?.cause == .modeChanged)
        #expect(service.lastEnd()?.modeRestored == true)
        // The screen that finishes the test has nothing left to put back.
        #expect(SettingsTestModeRule.modeToRestore(
            mode: settings.settings.dosingMode,
            testSessionID: session.id,
            activeSessionID: service.activeSession?.id,
            lastEndSessionID: service.lastEnd()?.sessionID,
            previousMode: .closed
        ) == nil)
    }

    @Test(
        "The pump suspended, alarmed or changed ends an ISF test from Begin, after a low and before carbs"
    ) func pumpInterruptionEndsISF() async {
        let events = FakeSettingsTestData()
        let session = runningSession()
        let suspendedAt = session.startedAt.addingTimeInterval(900)
        events.pumpEvents = [suspendedAt, session.startedAt.addingTimeInterval(1500), session.startedAt.addingTimeInterval(-60)]
        events.carbs = [session.startedAt.addingTimeInterval(600)]
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.endIfLowOrInterrupted()
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
        #expect(service.lastEnd() == SettingsTestEnd(sessionID: session.id, cause: .pumpInterrupted, date: suspendedAt))

        // Trio's own suspend for a low still comes first.
        let lowEvents = FakeSettingsTestData()
        let lowSession = runningSession()
        lowEvents.trioSuspends(at: lowSession.startedAt.addingTimeInterval(600))
        lowEvents.pumpEvents = [lowSession.startedAt.addingTimeInterval(300)]
        let (lowService, _, lowStorage) = makeService(mode: .basalTesting, existing: lowSession, events: lowEvents)
        defer { cleanUp(lowStorage) }
        await lowService.endIfLowOrInterrupted()
        #expect(lowService.lastEnd()?.cause == .low)
    }

    @Test(
        "A pump history that can't be read keeps an ISF test running; the pump suspended, alarmed or changed ends a basal test too"
    ) func pumpHistoryUnread() async {
        let events = FakeSettingsTestData()
        events.failingPumpEvents = true
        let session = runningSession()
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }
        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)

        let basalEvents = FakeSettingsTestData()
        let basal = runningSession(kind: .basal)
        let suspendedAt = basal.startedAt.addingTimeInterval(600)
        basalEvents.pumpEvents = [suspendedAt]
        let (basalService, basalSettings, basalStorage) = makeService(mode: .basalTesting, existing: basal, events: basalEvents)
        defer { cleanUp(basalStorage) }
        await basalService.endIfLowOrInterrupted()
        #expect(basalService.activeSession == nil)
        #expect(basalSettings.settings.dosingMode == .closed)
        #expect(basalService.lastEnd() == SettingsTestEnd(sessionID: basal.id, cause: .pumpInterrupted, date: suspendedAt))
    }

    @Test(
        "A zero temp only Closed Loop asked for as an ISF test began isn't its low; one Basal Testing asked for is"
    ) func closedLoopZeroTempAtBegin() async {
        let events = FakeSettingsTestData()
        let session = runningSession()
        // Decided before Begin, enacted 10 seconds after it.
        events.temps = [BasalTestTempBasal(date: session.startedAt.addingTimeInterval(10), rate: 0, minutes: 30)]
        events.zeroTempDeterminations = [session.startedAt.addingTimeInterval(-20)]
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }
        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(service.lastEnd() == nil)

        // A basal test reads the same zero temp with the same margin (part 2, Q6): Closed Loop's, so not the fast's low.
        // It wasn't Basal Testing's, so it stops the fast as basal stopped.
        let basalEvents = FakeSettingsTestData()
        let basal = runningSession(kind: .basal)
        basalEvents.temps = [BasalTestTempBasal(date: basal.startedAt.addingTimeInterval(10), rate: 0, minutes: 30)]
        basalEvents.zeroTempDeterminations = [basal.startedAt.addingTimeInterval(-20)]
        let (basalService, _, basalStorage) = makeService(mode: .basalTesting, existing: basal, events: basalEvents)
        defer { cleanUp(basalStorage) }
        await basalService.endIfLowOrInterrupted()
        #expect(basalService.lastEnd()?.cause == .basalStopped)
    }

    @Test("Without a suspend or carbs the basal test keeps running") func noSuspendLeavesSession() async {
        let events = FakeSettingsTestData()
        let (service, settings, storage, session) = startBasalTest(events: events)
        defer { cleanUp(storage) }

        events.temps = [
            // A cancel at the start and a suspend from before the test aren't this test's low.
            BasalTestTempBasal(date: session.startedAt, rate: 0, minutes: 0),
            BasalTestTempBasal(date: session.startedAt.addingTimeInterval(-600), rate: 0, minutes: 30)
        ]
        events.carbs = [session.startedAt.addingTimeInterval(-600)]
        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(events.reads > 0)
        #expect(service.lastEnd() == nil)
    }

    @Test("A test whose mode the user already changed is left alone") func userModeLeftAlone() async {
        let events = FakeSettingsTestData()
        let (service, settings, storage, session) = startBasalTest(events: events)
        defer { cleanUp(storage) }

        settings.settings.dosingMode = .lowGlucoseSuspend
        events.temps = [BasalTestTempBasal(date: session.startedAt, rate: 0, minutes: 30)]
        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .lowGlucoseSuspend)
        #expect(events.reads == 0)
    }

    @Test("A session that didn't switch to Basal Testing isn't watched") func otherSessionNotWatched() async {
        let events = FakeSettingsTestData()
        let (service, settings, storage) = makeService(mode: .basalTesting, events: events)
        defer { cleanUp(storage) }

        let session = service.begin(kind: .isf, expiresIn: 3600, restoring: [])
        events.temps = [BasalTestTempBasal(date: session!.startedAt, rate: 0, minutes: 30)]
        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == session?.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(events.reads == 0)
    }

    @Test(
        "When the temp basals can't be read and no carbs were logged, the test keeps running"
    ) func readFailureLeavesSession() async {
        let events = FakeSettingsTestData()
        let (service, settings, storage, session) = startBasalTest(events: events)
        defer { cleanUp(storage) }

        events.failingTemps = true
        events.temps = [BasalTestTempBasal(date: session.startedAt, rate: 0, minutes: 30)]
        await service.endIfLowOrInterrupted()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(service.lastEnd() == nil)
    }

    @Test("Carbs that can't be read end a basal test, so the usual dosing comes back") func carbsUnreadableEndsSession() async {
        let events = FakeSettingsTestData()
        let (service, settings, storage, session) = startBasalTest(events: events)
        defer { cleanUp(storage) }

        events.failingCarbs = true
        await service.endIfLowOrInterrupted()
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
        #expect(service.lastEnd()?.sessionID == session.id)
        #expect(service.lastEnd()?.cause == .carbsUnreadable)
    }

    @Test("A low still comes first when carbs can't be read") func lowBeforeCarbsUnreadable() async {
        let events = FakeSettingsTestData()
        let (service, _, storage, session) = startBasalTest(events: events)
        defer { cleanUp(storage) }

        events.failingCarbs = true
        events.basalTestingSuspends(at: session.startedAt, startedAt: session.startedAt)
        await service.endIfLowOrInterrupted()
        #expect(service.lastEnd()?.cause == .low)
    }

    // MARK: Leaving Basal Testing

    @Test("A low from before the mode was changed is still kept") func lowBeforeModeChange() async {
        let events = FakeSettingsTestData()
        let (service, settings, storage, session) = startBasalTest(events: events)
        defer { cleanUp(storage) }

        events.basalTestingSuspends(at: session.startedAt, startedAt: session.startedAt)
        settings.settings.dosingMode = .closed
        #expect(service.noteTestModeLeft())
        await service.endIfLowOrInterrupted()
        #expect(service.activeSession == nil)
        let ended = service.lastEnd()
        #expect(ended?.sessionID == session.id)
        #expect(ended?.cause == .low)
        // When Trio suspended, within what a date keeps on disk (milliseconds).
        #expect(abs((ended?.date ?? .distantPast).timeIntervalSince(session.startedAt)) < 0.01)
        // The mode the user picked stays.
        #expect(settings.settings.dosingMode == .closed)
    }

    @Test(
        "After the mode was changed, a zero temp or carbs aren't Basal Testing's to act on: the test ends as a mode change"
    ) func afterModeChange() async {
        let events = FakeSettingsTestData()
        let (service, settings, storage, session) = startBasalTest(events: events)
        defer { cleanUp(storage) }

        settings.settings.dosingMode = .closed
        #expect(service.noteTestModeLeft(at: session.startedAt.addingTimeInterval(1)))
        // The new mode's zero temp, after the change.
        events.trioSuspends(at: session.startedAt.addingTimeInterval(2))
        events.temps.append(BasalTestTempBasal(date: session.startedAt.addingTimeInterval(3), rate: 0, minutes: 30))
        events.carbs = [session.startedAt]
        await service.endIfLowOrInterrupted()
        #expect(service.activeSession == nil)
        #expect(service.lastEnd()?.cause == .modeChanged)
        #expect(settings.settings.dosingMode == .closed)
        // The basal screen reads it as a mode change.
        #expect(BasalTestEvaluator.runningCheck(
            sessionID: session.id,
            serviceEnd: service.lastEnd(),
            suspend: .none,
            now: Date(),
            plannedEnd: Date().addingTimeInterval(3600),
            mode: .closed
        ) == .modeChanged(at: service.lastEnd()?.date))
    }

    @Test("Only the first change away from Basal Testing is noted") func modeLeftOnce() async {
        let events = FakeSettingsTestData()
        let (service, settings, storage, session) = startBasalTest(events: events)
        defer { cleanUp(storage) }

        // Still in Basal Testing: nothing to note.
        #expect(!service.noteTestModeLeft())
        settings.settings.dosingMode = .lowGlucoseSuspend
        let left = session.startedAt.addingTimeInterval(60)
        #expect(service.noteTestModeLeft(at: left))
        settings.settings.dosingMode = .closed
        #expect(!service.noteTestModeLeft(at: left.addingTimeInterval(60)))
        #expect(service.activeSession?.leftTestModeAt == left)
        // Kept on disk with the session, to what a date keeps there (milliseconds).
        let saved = storage.retrieve(sessionPath, as: SettingsTestSession.self)?.leftTestModeAt
        #expect(abs((saved ?? .distantPast).timeIntervalSince(left)) < 0.01)
    }

    @Test("The service's own restore isn't a change away from Basal Testing") func restoreIsNotLeaving() async {
        let events = FakeSettingsTestData()
        let (service, settings, storage, _) = startBasalTest(events: events)
        defer { cleanUp(storage) }

        var noted: Bool?
        settings.onSettingsChange = { noted = service.noteTestModeLeft() }
        service.end(kind: .basal)
        #expect(noted == false)
    }

    @Test("Without a zero temp, Trio's determinations aren't read") func noZeroTempSkipsDeterminations() async throws {
        let events = FakeSettingsTestData()
        let start = Date(timeIntervalSince1970: 1_000_000)
        events.failingDeterminations = true
        events.temps = [BasalTestTempBasal(date: start.addingTimeInterval(60), rate: 0.4, minutes: 30)]
        // A failed read of them can't leave a fast with no suspend unchecked.
        #expect(try await events.suspendReading(from: start, to: start.addingTimeInterval(3600)) == .none)
        events.temps.append(BasalTestTempBasal(date: start.addingTimeInterval(120), rate: 0, minutes: 30))
        await #expect(throws: FakeSettingsTestData.Failure.self) {
            try await events.suspendReading(from: start, to: start.addingTimeInterval(3600))
        }
    }

    @Test("A low is kept when the session had already run past its deadline") func lowIsKeptWhenSessionExpired() async {
        let events = FakeSettingsTestData()
        // On a whole second, so the suspend reads back exactly.
        let startedAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 7200).rounded(.down))
        let session = SettingsTestSession(
            kind: .basal,
            startedAt: startedAt,
            expiresAt: Date().addingTimeInterval(-60),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )
        let suspendedAt = startedAt.addingTimeInterval(600)
        events.trioSuspends(at: suspendedAt)
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.checkSession()
        // The low is on record, then the usual mode is back, so the screen reports the low and not "interrupted".
        #expect(service.lastEnd() == SettingsTestEnd(sessionID: session.id, cause: .low, date: suspendedAt))
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
        #expect(storage.retrieve(sessionPath, as: SettingsTestSession.self) == nil)
    }

    @Test("A session recovered at launch past its deadline is checked for a low first") func lowIsKeptWhenExpiredAtLaunch() async {
        let events = FakeSettingsTestData()
        let startedAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 7200).rounded(.down))
        let session = SettingsTestSession(
            kind: .basal,
            startedAt: startedAt,
            expiresAt: Date().addingTimeInterval(-60),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )
        let suspendedAt = startedAt.addingTimeInterval(600)
        events.trioSuspends(at: suspendedAt)
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        // Nothing calls the check here: the service runs it itself once it is made, and the session ends within it.
        var waits = 0
        while service.activeSession != nil, waits < 100 {
            try? await Task.sleep(for: .milliseconds(50))
            waits += 1
        }
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
        #expect(service.lastEnd() == SettingsTestEnd(sessionID: session.id, cause: .low, date: suspendedAt))
    }

    @Test("An expired session with no low ends without a record") func expiredSessionWithoutALow() async {
        let events = FakeSettingsTestData()
        let startedAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 7200).rounded(.down))
        let session = SettingsTestSession(
            kind: .basal,
            startedAt: startedAt,
            expiresAt: Date().addingTimeInterval(-60),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )
        // What the service kept for an earlier test, which this one mustn't touch.
        let earlier = SettingsTestEnd(
            sessionID: UUID(),
            cause: .carbsLogged,
            date: Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 86400).rounded(.down))
        )
        BaseFileStorage().save(earlier, as: lastEndPath)
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events, keepingFiles: true)
        defer { cleanUp(storage) }

        await service.checkSession()
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
        #expect(storage.retrieve(sessionPath, as: SettingsTestSession.self) == nil)
        #expect(service.lastEnd() == earlier)
    }

    @Test("A running session isn't ended by the check") func checkSessionLeavesALiveSession() async {
        let events = FakeSettingsTestData()
        let (service, settings, storage, session) = startBasalTest(events: events)
        defer { cleanUp(storage) }

        await service.checkSession()
        #expect(service.activeSession?.id == session.id)
        #expect(settings.settings.dosingMode == .basalTesting)
        #expect(events.reads > 0)
        #expect(service.lastEnd() == nil)
    }

    @Test("A session whose history can't be read still ends at its deadline") func expiredSessionEndsWhenHistoryUnreadable() async {
        let events = FakeSettingsTestData()
        events.failing = true
        // One whose carbs aren't read, so only the deadline ends it. An ISF test reads them, as a basal test does.
        let session = SettingsTestSession(
            kind: .carbRatio,
            startedAt: Date().addingTimeInterval(-7200),
            expiresAt: Date().addingTimeInterval(-60),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: session, events: events)
        defer { cleanUp(storage) }

        await service.checkSession()
        #expect(service.activeSession == nil)
        #expect(settings.settings.dosingMode == .closed)
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

    @Test("A session that ran past its deadline is closed on launch") func expiredSessionRestoresOnLaunch() async {
        let stale = SettingsTestSession(
            kind: .basal,
            startedAt: Date().addingTimeInterval(-6 * 3600),
            expiresAt: Date().addingTimeInterval(-60),
            restore: [.dosingMode(testMode: .basalTesting, previous: .closed)]
        )
        let (service, settings, storage) = makeService(mode: .basalTesting, existing: stale)
        defer { cleanUp(storage) }

        // The launch check reads the history for a low first, so it finishes a moment after the service is made.
        await service.checkSession()
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

@Suite("Settings test events") struct SettingsTestEventsTests {
    @Test(
        "Carb entries are read in the window with their object IDs, the same from any context; none of 0 g"
    ) func carbEntriesWithIDs() async throws {
        let stack = try await CoreDataStack.createForTests()
        let writer = stack.newTaskContext()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let expected: [String] = try await writer.perform {
            func entry(after seconds: TimeInterval, carbs: Double, fpu: Bool = false) -> CarbEntryStored {
                let entry = CarbEntryStored(context: writer)
                entry.id = UUID()
                entry.date = start.addingTimeInterval(seconds)
                entry.carbs = carbs
                entry.isFPU = fpu
                return entry
            }
            let meal = entry(after: 600, carbs: 20)
            // Fat and protein's carb equivalents are carb entries too.
            let equivalents = entry(after: 1200, carbs: 5, fpu: true)
            _ = entry(after: 900, carbs: 0)
            // Outside the window.
            _ = entry(after: -60, carbs: 20)
            _ = entry(after: 7200, carbs: 20)
            try writer.save()
            return [meal, equivalents].map { $0.objectID.uriRepresentation().absoluteString }
        }

        let end = start.addingTimeInterval(3600)
        let entries = try await CoreDataSettingsTestEvents(context: stack.newTaskContext()).carbEntries(from: start, to: end)
        #expect(entries.map(\.date) == [start.addingTimeInterval(600), start.addingTimeInterval(1200)])
        #expect(entries.map(\.id) == expected)
        // Read from another context, each is the same entry.
        let again = try await CoreDataSettingsTestEvents(context: stack.newTaskContext()).carbEntries(from: start, to: end)
        #expect(again == entries)
    }

    @Test(
        "Carbs spoil a test from Begin on, and before it, back a day, only when they weren't there at Begin"
    ) func carbRule() {
        let begin = Date(timeIntervalSince1970: 1_000_000)
        func entry(_ id: String, _ seconds: TimeInterval) -> SettingsTestCarbEntry {
            SettingsTestCarbEntry(id: id, date: begin.addingTimeInterval(seconds))
        }
        let dinner = entry("dinner", -3 * 3600)
        let kept = SettingsTestCarbRule.keptAtBegin([entry("lunch", -6 * 3600), dinner])
        #expect(kept == ["dinner", "lunch"])
        #expect(SettingsTestCarbRule.readFrom(startedAt: begin, kept: kept) == begin.addingTimeInterval(-24 * 3600))
        func spoil(_ entries: [SettingsTestCarbEntry]) -> Bool {
            SettingsTestCarbRule.spoil(entries, startedAt: begin, kept: kept)
        }
        #expect(!spoil([dinner]))
        // Logged since Begin with the time it was eaten, before Begin.
        #expect(spoil([dinner, entry("snack", -30 * 60)]))
        // Dated from Begin on, as before.
        #expect(spoil([entry("tea", 600)]))
        #expect(spoil([entry("tea", 0)]))
        // Dated from Begin on, it spoils the test even if it was there at Begin (fat and protein's, say).
        #expect(SettingsTestCarbRule.spoil([entry("equivalents", 0)], startedAt: begin, kept: ["equivalents"]))
        // More than a day before Begin.
        #expect(!spoil([entry("yesterday", -25 * 3600)]))

        // A test that kept none reads from Begin, as before.
        #expect(SettingsTestCarbRule.readFrom(startedAt: begin, kept: nil) == begin)
        #expect(!SettingsTestCarbRule.spoil([entry("snack", -30 * 60)], startedAt: begin, kept: nil))
        #expect(SettingsTestCarbRule.spoil([entry("tea", 0)], startedAt: begin, kept: nil))
    }

    @Test(
        "Trio's determinations that asked for a zero temp with time on it, dated by when they were due"
    ) func zeroTempDeterminations() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        let start = Date(timeIntervalSince1970: 1_000_000)
        await context.perform {
            func determination(after seconds: TimeInterval, rate: Decimal?, minutes: Decimal?, due: Bool = true) {
                let determination = OrefDetermination(context: context)
                determination.id = UUID()
                determination.deliverAt = due ? start.addingTimeInterval(seconds) : nil
                // Made a moment after it was due, as the loop marks it once the pump has it.
                determination.timestamp = start.addingTimeInterval(seconds + 20)
                determination.rate = rate.map { NSDecimalNumber(decimal: $0) }
                determination.duration = minutes.map { NSDecimalNumber(decimal: $0) }
            }
            determination(after: 600, rate: 0, minutes: 30)
            // No change, a cancel, and a temp that delivers didn't ask for a zero temp.
            determination(after: 900, rate: nil, minutes: nil)
            determination(after: 1200, rate: 0, minutes: 0)
            determination(after: 1500, rate: 0.4, minutes: 30)
            // Without a time it was due, it goes by when it was made.
            determination(after: 1800, rate: 0, minutes: 30, due: false)
            // Outside the window.
            determination(after: -60, rate: 0, minutes: 30)
            determination(after: 7200, rate: 0, minutes: 30)
            try? context.save()
        }

        let dates = try await CoreDataSettingsTestEvents(context: context)
            .zeroTempDeterminations(from: start, to: start.addingTimeInterval(3600))
        #expect(dates == [start.addingTimeInterval(600), start.addingTimeInterval(1820)])
    }

    @Test(
        "Boluses are read with the amount the pump history holds now, whatever their SMB flag; one at 0 U is left out"
    ) func bolusesReadTheCurrentAmount() async throws {
        let stack = try await CoreDataStack.createForTests()
        // The reader keeps its own context, as the ISF screen's provider does; the pump history writes in another.
        let reader = stack.newTaskContext()
        let writer = stack.newTaskContext()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let bolusAt = start.addingTimeInterval(1200.000_3)
        func insert(at date: Date, amount: Decimal?, isSMB: Bool = false) async throws -> NSManagedObjectID {
            try await writer.perform {
                let event = PumpEventStored(context: writer)
                event.id = UUID().uuidString
                event.timestamp = date
                event.type = PumpEventStored.EventType.bolus.rawValue
                event.isMutable = true
                let bolus = BolusStored(context: writer)
                bolus.amount = amount.map { NSDecimalNumber(decimal: $0) }
                bolus.isSMB = isSMB
                bolus.pumpEvent = event
                try writer.save()
                return event.objectID
            }
        }
        // While delivering, the row holds the programmed amount.
        let id = try await insert(at: bolusAt, amount: 2)
        _ = try await insert(at: start.addingTimeInterval(1800), amount: 0)
        _ = try await insert(at: start.addingTimeInterval(2400), amount: dec("0.5"), isSMB: true)
        let unnamed = start.addingTimeInterval(3000)
        _ = try await insert(at: unnamed, amount: nil)
        let events = CoreDataSettingsTestEvents(context: reader)
        let window = (start, start.addingTimeInterval(3600))
        // The reader holds on to the row it read, as a context can, so a stale copy would show if one were kept.
        let held = try await reader.perform { try reader.existingObject(with: id) as? PumpEventStored }
        _ = await reader.perform { held?.bolus?.amount }

        // The one flagged as an SMB is read too: Basal Testing gives none, so it is a bolus like the others.
        let smbFlagged = ISFTestBolus(date: start.addingTimeInterval(2400), units: dec("0.5"))
        let first = try await events.allBoluses(from: window.0, to: window.1)
        #expect(first == [ISFTestBolus(date: bolusAt, units: 2), smbFlagged, ISFTestBolus(date: unnamed, units: 0)])

        // Cut short: the pump reports what it delivered, and the row is updated in place.
        try await writer.perform {
            let event = try writer.existingObject(with: id) as? PumpEventStored
            event?.bolus?.amount = NSDecimalNumber(decimal: 1)
            event?.isMutable = false
            try writer.save()
        }
        let reread = try await events.allBoluses(from: window.0, to: window.1)
        #expect(reread == [ISFTestBolus(date: bolusAt, units: 1), smbFlagged, ISFTestBolus(date: unnamed, units: 0)])

        // The test's re-read takes every bolus row with its amount, 0 U and no amount included.
        let rows = try await events.bolusRecords(from: window.0, to: window.1)
        #expect(rows == [
            ISFTestBolusRecord(date: bolusAt, amount: 1),
            ISFTestBolusRecord(date: start.addingTimeInterval(1800), amount: 0),
            ISFTestBolusRecord(date: start.addingTimeInterval(2400), amount: dec("0.5")),
            ISFTestBolusRecord(date: unnamed, amount: nil)
        ])
        // Finalized with `automatic` unset, the pump history flags the row as an SMB: both reads still find it, with the
        // amount delivered.
        try await writer.perform {
            let event = try writer.existingObject(with: id) as? PumpEventStored
            event?.bolus?.isSMB = true
            try writer.save()
        }
        #expect(try await events.allBoluses(from: window.0, to: window.1) == reread)
        let flipped = try await events.bolusRecords(from: bolusAt, to: bolusAt)
        #expect(flipped == [ISFTestBolusRecord(date: bolusAt, amount: 1)])
        #expect(ISFTestEvaluator.bolusAmount(saved: 2, reread: flipped, bolusAt: bolusAt, finishing: true) == .units(1))
        // A row at 0 U reads as cancelled.
        let zeroAt = start.addingTimeInterval(1800)
        let zero = try await events.bolusRecords(from: zeroAt, to: zeroAt)
        #expect(ISFTestEvaluator.bolusAmount(saved: 2, reread: zero, bolusAt: zeroAt, finishing: true) == .cancelled)
        withExtendedLifetime(held) {}
    }

    @Test(
        "The pump's suspends and resumes, alarms, and site, reservoir or pod changes are read in the window, nothing else"
    ) func pumpInterruptions() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        let start = Date(timeIntervalSince1970: 1_000_000)
        await context.perform {
            func event(_ type: PumpEventStored.EventType, after seconds: TimeInterval) {
                let event = PumpEventStored(context: context)
                event.id = UUID().uuidString
                event.timestamp = start.addingTimeInterval(seconds)
                event.type = type.rawValue
            }
            event(.pumpSuspend, after: 600)
            event(.pumpResume, after: 900)
            event(.pumpAlarm, after: 1200)
            event(.rewind, after: 1500)
            event(.prime, after: 1800)
            event(.siteChange, after: 2100)
            // Not one: dosing, a battery event.
            event(.bolus, after: 300)
            event(.tempBasal, after: 400)
            event(.pumpBattery, after: 500)
            // Outside the window.
            event(.pumpSuspend, after: -60)
            event(.pumpAlarm, after: 7200)
            try? context.save()
        }
        let dates = try await CoreDataSettingsTestEvents(context: context)
            .pumpInterruptions(from: start, to: start.addingTimeInterval(3600))
        #expect(dates == [600, 900, 1200, 1500, 1800, 2100].map { start.addingTimeInterval($0) })
    }

    @Test(
        "Manual BG entries and CGM calibrations are left out of every glucose, arrow and newest-direction read"
    ) func manualReadingsLeftOut() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        let start = Date().addingTimeInterval(-3600)
        await context.perform {
            func glucose(after seconds: TimeInterval, _ value: Int16, manual: Bool, direction: String? = "Flat") {
                let stored = GlucoseStored(context: context)
                stored.id = UUID()
                stored.date = start.addingTimeInterval(seconds)
                stored.glucose = value
                stored.isManual = manual
                stored.direction = manual ? nil : direction
            }
            glucose(after: 600, 112, manual: false)
            glucose(after: 900, 113, manual: false)
            glucose(after: 1200, 114, manual: false, direction: "SingleUp")
            // A fingerstick entered with Home's "+", and a calibration, both stored as manual, with no arrow.
            glucose(after: 1300, 128, manual: true)
            glucose(after: 1320, 140, manual: true)
            try? context.save()
        }
        let events = CoreDataSettingsTestEvents(context: stack.newTaskContext())
        let cgm = [600, 900, 1200].map { start.addingTimeInterval($0) }
        #expect(try await events.glucose(from: start, to: start.addingTimeInterval(3600)).map(\.date) == cgm)
        #expect(try await events.recentGlucose(since: start).map(\.date) == cgm.reversed())
        // The newest reading's arrow is the CGM's, not none from the fingerstick after it.
        #expect(try await events.newestDirection(since: start) == .singleUp)
        let arrow = try await events.arrowReading(atOrBefore: start.addingTimeInterval(1400), since: start)
        #expect(arrow == ISFTestArrowReading(date: start.addingTimeInterval(1200), direction: .singleUp))
    }

    @Test(
        "Alarms, site and pod changes, suspends and resumes the pump driver reports are stored as the rows the interruption read finds"
    ) func pumpInterruptionsFromThePumpDriver() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        let resolver = Assembler([
            StorageAssembly(),
            ServiceAssembly(),
            APSAssembly(),
            NetworkAssembly(),
            UIAssembly(),
            SecurityAssembly(),
            TestAssembly(testContext: context)
        ]).resolver
        let storage = try #require(resolver.resolve(PumpHistoryStorage.self))
        let start = Date().addingTimeInterval(-3600)
        func event(_ type: PumpEventType, after seconds: TimeInterval) -> NewPumpEvent {
            NewPumpEvent(
                date: start.addingTimeInterval(seconds),
                dose: nil,
                raw: Data("interruption-\(seconds)".utf8),
                title: "\(type)",
                type: type
            )
        }
        // Stored through upstream's own mapping (`PumpEventType.storedEventType`), not as raw rows.
        try await storage.storePumpEvents([
            event(.alarm, after: 600),
            event(.replaceComponent(componentType: .infusionSet), after: 1200),
            event(.replaceComponent(componentType: .pump), after: 1800),
            event(.suspend, after: 2400),
            event(.resume, after: 2700),
            event(.rewind, after: 3000),
            event(.prime, after: 3060),
            // Not one: an alarm cleared, which upstream doesn't store.
            event(.alarmClear, after: 900)
        ], replacePendingEvents: false)
        let dates = try await CoreDataSettingsTestEvents(context: context).pumpInterruptions(from: start, to: Date())
        #expect(dates == [600, 1200, 1800, 2400, 2700, 3000, 3060].map { start.addingTimeInterval($0) })
    }

    private func dec(_ string: String) -> Decimal { Decimal(string: string)! }
}

@Suite("Settings test kinds") struct SettingsTestKindTests {
    @Test("Basal is listed before sensitivity, then carb ratio") func order() {
        #expect(SettingsTestKind.allCases == [.basal, .isf, .carbRatio])
    }

    @Test("Basal and sensitivity can be opened; carb ratio is being rebuilt") func availability() {
        #expect(SettingsTestKind.basal.availability == .available)
        #expect(SettingsTestKind.isf.availability == .available)
        #expect(SettingsTestKind.carbRatio.availability == .beingRebuilt)
    }

    @Test("While one test runs, every other test can't start and the running test's own can be followed") func locking() {
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

    @Test(
        "An available test opens even while another runs, so its steps can be read; its own Check blocks the start"
    ) func screens() {
        let state = SettingsTest.StateModel()
        #expect(state.screen(for: .basal) == .basalTest)
        #expect(state.screen(for: .isf) == .isfTest)
        #expect(state.screen(for: .carbRatio) == nil)

        state.activeSession = SettingsTestSession(
            kind: .basal,
            expiresAt: Date().addingTimeInterval(3600),
            restore: []
        )
        #expect(state.screen(for: .basal) == .basalTest)
        #expect(state.screen(for: .isf) == .isfTest)
        #expect(state.screen(for: .carbRatio) == nil)

        state.activeSession = SettingsTestSession(kind: .isf, expiresAt: Date().addingTimeInterval(3600), restore: [])
        #expect(state.screen(for: .isf) == .isfTest)
        #expect(state.screen(for: .basal) == .basalTest)
    }

    // MARK: Sensitivity row warning

    private let gateNow = Date(timeIntervalSince1970: 1_700_000_000)
    private let english = Locale(identifier: "en_US")

    @Test("A steady basal test with its schedule unchanged shows no warning") func gateReadyHasNoNote() {
        let gate = SettingsTestSchedule.BasalGate.ready(lastSteady: gateNow.addingTimeInterval(-3 * 86400))
        #expect(SettingsTestKind.isfGateNote(for: gate, now: gateNow, locale: english) == nil)
    }

    @Test("Any other basal gate warns in the Check screen's words, and says the test can still start") func gateNotes() {
        let past = gateNow.addingTimeInterval(-3 * 86400)
        let gates: [SettingsTestSchedule.BasalGate] = [
            .noSteadyTest,
            .changedSince(past),
            .lastWasNot(.increase, past),
            .lastWasNot(.decrease, past)
        ]
        for gate in gates {
            let note = SettingsTestKind.isfGateNote(for: gate, now: gateNow, locale: english)
            let check = ISFTestEvaluator.basalGateText(gate, now: gateNow, locale: english)
            #expect(note == "\(check). You can still start.")
        }
        #expect(
            SettingsTestKind.isfGateNote(for: .noSteadyTest, now: gateNow, locale: english)
                == "No steady basal test yet. You can still start."
        )
        #expect(
            SettingsTestKind.isfGateNote(for: .lastWasNot(.decrease, past), now: gateNow, locale: english)
                == "The last basal test said basal looks too high. You can still start."
        )
    }

    @Test("The warning never locks the row, and goes while a test runs or before the gate is read") func gateNoteState() {
        let state = SettingsTest.StateModel()
        #expect(state.isfGateNote == nil)

        state.basalGate = .noSteadyTest
        #expect(state.isfGateNote == "No steady basal test yet. You can still start.")
        #expect(!state.isLocked(.isf))
        #expect(state.screen(for: .isf) == .isfTest)

        state.activeSession = SettingsTestSession(kind: .isf, expiresAt: gateNow, restore: [])
        #expect(state.isfGateNote == nil)
    }

    // MARK: Time period rows

    private func period(
        _ direction: SettingsTestDirection?,
        changedSince: Bool = false
    ) -> SettingsTestPeriod {
        SettingsTestPeriod(
            entry: SettingsTestScheduleEntry(startMinutes: 0, endMinutes: 360, value: 50),
            lastTest: direction == nil ? nil : gateNow,
            lastDirection: direction,
            changedSince: changedSince
        )
    }

    private func status(_ kind: SettingsTestKind, _ period: SettingsTestPeriod) -> String {
        kind.periodStatusText(for: period) { _ in "3 days ago" }
    }

    @Test("A sensitivity period says whether its last test looked accurate, too high or too low") func isfStatus() {
        #expect(status(.isf, period(.keep)) == "Looked accurate 3 days ago")
        // The drop fell short of the ISF: the number is too high, and the docs say decrease it.
        #expect(status(.isf, period(.decrease)) == "ISF looked too high 3 days ago")
        // The drop overshot: the number is too low, and the docs say increase it.
        #expect(status(.isf, period(.increase)) == "ISF looked too low 3 days ago")
    }

    @Test("A basal period reads as it always has") func basalStatus() {
        #expect(status(.basal, period(.keep)) == "Steady 3 days ago")
        #expect(status(.basal, period(.increase)) == "Basal looked too low 3 days ago")
        #expect(status(.basal, period(.decrease)) == "Basal looked too high 3 days ago")
    }

    @Test("An untested or edited period says so, whatever the kind") func untestedAndChangedStatus() {
        for kind in [SettingsTestKind.basal, .isf] {
            #expect(status(kind, period(nil)) == "Not tested yet")
            #expect(status(kind, period(.keep, changedSince: true)) == "Changed since the last test")
            #expect(status(kind, period(.decrease, changedSince: true)) == "Changed since the last test")
        }
    }

    @Test("A sensitivity shows in the user's units, with the unit kept together") func isfText() {
        // The unit never breaks across lines, so compare as it reads.
        func read(_ text: String) -> String {
            text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{2060}", with: "")
        }
        #expect(read(SettingsTestKind.isfText(50, units: .mgdL, locale: english)) == "50 mg/dL/U")
        #expect(read(SettingsTestKind.isfText(45.5, units: .mgdL, locale: english)) == "45.5 mg/dL/U")
        // 50 mg/dL per unit is 2.8 mmol/L per unit.
        #expect(read(SettingsTestKind.isfText(50, units: .mmolL, locale: english)) == "2.8 mmol/L/U")
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

        var isf = session
        isf.kind = .isf
        isf.bolusWindowStart = Date(timeIntervalSince1970: 1_900_600)
        let decodedISF = try JSONCoding.decoder.decode(SettingsTestSession.self, from: JSONCoding.encoder.encode(isf))
        #expect(decodedISF == isf)
        #expect(decodedISF.bolusWindowStart == Date(timeIntervalSince1970: 1_900_600))
    }

    @Test("A session saved before the bolus window start was kept decodes with none") func decodesOldSession() throws {
        let json = """
        {
          "id": "6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D",
          "kind": "isf",
          "startedAt": "2026-11-03T12:00:00Z",
          "expiresAt": "2026-11-03T18:00:00Z",
          "restore": [{"dosingMode": {"testMode": "basalTesting", "previous": "closed"}}]
        }
        """
        let decoded = try JSONCoding.decoder.decode(SettingsTestSession.self, from: Data(json.utf8))
        #expect(decoded.kind == .isf)
        #expect(decoded.bolusWindowStart == nil)
        #expect(decoded.leftTestModeAt == nil)
        #expect(decoded.restore == [.dosingMode(testMode: .basalTesting, previous: .closed)])
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

    @Test("A rounded result follows ≈, is read as about, and the card says so") func approximateResult() {
        let share = SettingsTestFormulaTerm(
            label: "Share",
            value: "+31%",
            unit: "of basal",
            fromSettings: false,
            approximate: true
        )
        let line: [SettingsTestFormulaPart] = [.term(term("Rate", "+0.15", "U/h")), .op("÷"), .term(term("Basal", "0.50", "U/h"))]
        #expect(SettingsTestFormulaCard.relation(for: share) == "≈")
        #expect(SettingsTestFormulaCard.relation(for: term("Rate", "+0.6", "U")) == "=")

        let spoken = SettingsTestFormulaCard.spokenLabel(line, result: share)
        #expect(spoken.contains(String(localized: "is about")))
        #expect(!spoken.contains(String(localized: "equals")))
        #expect(!spoken.contains("≈"))
        #expect(SettingsTestFormulaCard.spokenLabel(line, result: term("Share", "30%", "")).contains(String(localized: "equals")))

        let exact = term("Rate", "+0.6", "U")
        #expect(SettingsTestFormulaCard.showsApproximate(result: [exact, share], lineCount: 2))
        #expect(!SettingsTestFormulaCard.showsApproximate(result: [exact], lineCount: 1))
        // A result with no line isn't shown, so its ≈ doesn't count.
        #expect(!SettingsTestFormulaCard.showsApproximate(result: [exact, share], lineCount: 1))
    }

    @Test("At accessibility sizes a formula stacks one term to a line, its operators leading") func stackedFormula() {
        let current = term("Current", "212", "mg/dL")
        let target = term("Target", "100", "mg/dL", fromSettings: true)
        let isf = term("ISF", "50", "mg/dL/U", fromSettings: true)
        func shape(_ parts: [SettingsTestFormulaPart]) -> [String] {
            SettingsTestFormulaCard.stackedLines(parts).map { "\($0.leading)|\($0.term.label)|\($0.trailing)" }
        }

        // The docs' dose: ( Current − Target ) ÷ ISF.
        let dose: [SettingsTestFormulaPart] = [
            .op("("), .term(current), .op("−"), .term(target), .op(")"), .op("÷"), .term(isf)
        ]
        #expect(shape(dose) == ["(|Current|", "−|Target|)", "÷|ISF|"])
        // Each term keeps whether it is from the settings, so it stays blue.
        #expect(SettingsTestFormulaCard.stackedLines(dose).map(\.term.fromSettings) == [false, true, true])

        // The basal rate: no brackets, so the first term has nothing before it.
        let rate: [SettingsTestFormulaPart] = [
            .term(term("Change", "+37", "mg/dL")), .op("÷"), .term(isf), .op("÷"), .term(term("Hours", "6", "h"))
        ]
        #expect(shape(rate) == ["|Change|", "÷|ISF|", "÷|Hours|"])

        // A bracket that opens after an operator leads with both; brackets that close together close one line.
        let nested: [SettingsTestFormulaPart] = [
            .term(current), .op("÷"), .op("("), .term(target), .op("−"), .term(isf), .op(")")
        ]
        #expect(shape(nested) == ["|Current|", "÷ (|Target|", "−|ISF|)"])
        let closedTwice: [SettingsTestFormulaPart] = [
            .op("("), .op("("), .term(current), .op("−"), .term(target), .op(")"), .op(")")
        ]
        #expect(shape(closedTwice) == ["( (|Current|", "−|Target|) )"])

        // Every term is on a line, once, in order.
        for parts in [dose, rate, nested, closedTwice] {
            let terms = parts.compactMap { part -> String? in
                if case let .term(term) = part { return term.label }
                return nil
            }
            #expect(SettingsTestFormulaCard.stackedLines(parts).map(\.term.label) == terms)
        }
        #expect(SettingsTestFormulaCard.stackedLines([]).isEmpty)
    }

    @Test("The step bar checks the steps before the current one, unless they were skipped") func stepBarStatus() {
        typealias Bar = SettingsTestStepBar<BasalTest.Step>
        // Basal passes no skipped steps, so its bar is as it was.
        #expect(BasalTest.Step.allCases.map { Bar.status(of: $0, current: .check, skipped: []) } == [
            .current, .upcoming, .upcoming
        ])
        #expect(BasalTest.Step.allCases.map { Bar.status(of: $0, current: .result, skipped: []) } == [
            .done, .done, .current
        ])
        // A skipped step before the current one is skipped; the current step and those to come never are.
        #expect(BasalTest.Step.allCases.map { Bar.status(of: $0, current: .result, skipped: [.fast]) } == [
            .done, .skipped, .current
        ])
        #expect(BasalTest.Step.allCases.map { Bar.status(of: $0, current: .fast, skipped: [.fast, .result]) } == [
            .done, .current, .upcoming
        ])
    }

    @Test("A warning is an orange triangle, apart from the info look") func warningState() {
        #expect(SettingsTestCheckState.warning.icon == "exclamationmark.triangle.fill")
        #expect(SettingsTestCheckState.warning.color == .orange)
        #expect(SettingsTestCheckState.info.icon == "info.circle")
        #expect(SettingsTestCheckState.info.color == .secondary)
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

    @Test("The chart's range pads the readings, and leaves room above a target line for its label") func chartRange() {
        // Without a target, the readings with 10 mg/dL either side, as the basal screens draw it.
        #expect(SettingsTestGlucoseChart.yRange(values: [100, 140], target: nil) == 90 ... 150)
        #expect(SettingsTestGlucoseChart.yRange(values: [], target: nil) == 60 ... 190)
        #expect(SettingsTestGlucoseChart.yRange(values: [35, 410], target: nil) == 40 ... 400)
        // A target under the readings changes nothing above them.
        #expect(SettingsTestGlucoseChart.yRange(values: [150, 220], target: 100) == 90 ... 230)
        // A target at the top gets a fifth of the range below it above it, so its label isn't cut off.
        #expect(SettingsTestGlucoseChart.yRange(values: [60, 100], target: 110) == 50 ... 122)
        // And at least 10 mg/dL.
        #expect(SettingsTestGlucoseChart.yRange(values: [105], target: 110) == 95 ... 120)
        // A reading just over the target still leaves the label its room.
        #expect(SettingsTestGlucoseChart.yRange(values: [60, 112], target: 110) == 50 ... 122)
    }

    @Test("The chart's range is always a valid range, however far the values are past its limits") func chartRangeClamped() {
        // Every reading above 400, with no target: the top 10 mg/dL of the chart.
        #expect(SettingsTestGlucoseChart.yRange(values: [420, 450], target: nil) == 390 ... 400)
        #expect(SettingsTestGlucoseChart.yRange(values: [], target: 450) == 390 ... 400)
        // Every reading below 40: the bottom 10 mg/dL.
        #expect(SettingsTestGlucoseChart.yRange(values: [20, 25], target: nil) == 40 ... 50)
        // In between, nothing changes.
        #expect(SettingsTestGlucoseChart.yRange(values: [35, 410], target: nil) == 40 ... 400)
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

    private func isf(_ units: GlucoseUnits, _ points: [(hour: Int, value: Decimal)]) -> InsulinSensitivities {
        InsulinSensitivities(
            units: units,
            userPreferredUnits: units,
            sensitivities: points.map {
                InsulinSensitivityEntry(sensitivity: $0.value, offset: $0.hour * 60, start: String(format: "%02d:00:00", $0.hour))
            }
        )
    }

    @Test("An ISF profile becomes entries that run to the next start, the last to midnight") func isfEntriesSpanTheDay() {
        let entries = SettingsTestSchedule.entries(isf(.mgdL, [(0, 50), (6, 40), (18, 45)]))
        #expect(entries == [entry(0, 360, 50), entry(360, 1080, 40), entry(1080, 1440, 45)])
    }

    @Test("ISF entries are built in start order whatever order the profile arrives in") func isfEntriesAreSorted() {
        let shuffled = SettingsTestSchedule.entries(isf(.mgdL, [(18, 45), (0, 50), (6, 40)]))
        #expect(shuffled == [entry(0, 360, 50), entry(360, 1080, 40), entry(1080, 1440, 45)])
    }

    @Test("An ISF saved in mmol/L is read in mg/dL, keeping its decimals") func isfEntriesFromMmol() {
        let entries = SettingsTestSchedule.entries(isf(.mmolL, [(0, 2.8), (12, 2.2)]))
        #expect(entries == [
            entry(0, 720, Decimal(2.8) / GlucoseUnits.exchangeRate),
            entry(720, 1440, Decimal(2.2) / GlucoseUnits.exchangeRate)
        ])
        // 2.8 mmol/L is 50.45 mg/dL, not the app's whole 50, which is close to 1% off, and it reads back as 2.8.
        #expect(Trio.rounded(entries[0].value, scale: 2, roundingMode: .plain) == Decimal(string: "50.45"))
        #expect(entries[0].value.formattedISF(for: .mmolL, locale: Locale(identifier: "en_US")) == "2.8")
        #expect(SettingsTestSchedule.isfInMgdL(50, units: .mgdL) == 50)
    }

    @Test("An ISF profile with no entries has none") func isfEntriesEmpty() {
        #expect(SettingsTestSchedule.entries(isf(.mgdL, [])).isEmpty)
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

    @Test("A record saved before boluses were kept decodes with no bolus or tablets") func decodesRecordWithoutBolus() throws {
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
          "applied": false,
          "coveredEntries": [{"startMinutes": 0, "endMinutes": 360, "value": 0.8}]
        }
        """
        let decoded = try JSONCoding.decoder.decode(SettingsTestRecord.self, from: Data(json.utf8))
        #expect(decoded.bolusUnits == nil)
        #expect(decoded.tabletCarbs == nil)
        #expect(decoded.iobHandling == nil)
        #expect(decoded.iobCounted == nil)
        #expect(decoded.coveredEntries == [entry(0, 360, 0.8)])
    }

    @Test("How an ISF test handled insulin on board, and what it counted, survive a round trip through JSON") func iobRoundTrip() throws {
        var saved = record(.decrease, minutesAgo: 10, kind: .isf, covered: [entry(0, 360, 50)])
        saved.bolusUnits = 2
        saved.iobHandling = ISFTestIOBHandling.count.rawValue
        saved.iobCounted = Decimal(string: "-0.3")!
        let decoded = try JSONCoding.decoder.decode(SettingsTestRecord.self, from: JSONCoding.encoder.encode(saved))
        #expect(decoded.iobHandling == "count")
        #expect(decoded.iobCounted == Decimal(string: "-0.3")!)
        #expect(decoded == saved)
    }

    @Test("The bolus and tablets of a test survive a round trip through JSON") func bolusRoundTrip() throws {
        var saved = record(.decrease, minutesAgo: 10, kind: .isf, covered: [entry(0, 360, 50)])
        saved.bolusUnits = 1.8
        saved.tabletCarbs = 12
        let decoded = try JSONCoding.decoder.decode(SettingsTestRecord.self, from: JSONCoding.encoder.encode(saved))
        #expect(decoded.bolusUnits == 1.8)
        #expect(decoded.tabletCarbs == 12)
        #expect(decoded == saved)
    }

    @Test("Covered entries survive a round trip through JSON") func recordRoundTrip() throws {
        let saved = record(.keep, minutesAgo: 10, covered: [entry(0, 360, 0.8), entry(1320, 1440, 0.7)])
        let decoded = try JSONCoding.decoder.decode(SettingsTestRecord.self, from: JSONCoding.encoder.encode(saved))
        #expect(decoded.coveredEntries == saved.coveredEntries)
    }

    // MARK: Basal periods

    private func untested(_ entry: SettingsTestScheduleEntry) -> SettingsTestPeriod {
        SettingsTestPeriod(entry: entry, lastTest: nil, lastDirection: nil, changedSince: false)
    }

    @Test("With no tests, every period is untested") func periodsUntested() {
        let periods = SettingsTestSchedule.periods(for: .basal, current: profile, history: [])
        #expect(periods == profile.map(untested))
    }

    @Test("A steady test marks the period it covered and leaves the others untested") func periodSteady() {
        let steady = record(.keep, minutesAgo: 10, covered: [entry(0, 360, 0.8)])
        let periods = SettingsTestSchedule.periods(for: .basal, current: profile, history: [steady])
        #expect(periods == [
            SettingsTestPeriod(
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
        let periods = SettingsTestSchedule.periods(for: .basal, current: profile, history: [rising, falling])
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
        let periods = SettingsTestSchedule.periods(for: .basal, current: edited, history: [steady])
        #expect(periods[0] == SettingsTestPeriod(
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
        #expect(SettingsTestSchedule.periods(for: .basal, current: moved, history: [steady])[0].changedSince)

        let split = SettingsTestSchedule.entries([basal(0, 0.8), basal(3, 0.8), basal(6, 1.0), basal(22, 0.7)])
        let splitPeriods = SettingsTestSchedule.periods(for: .basal, current: split, history: [steady])
        #expect(splitPeriods[0].changedSince)
        #expect(splitPeriods[1].changedSince)
        #expect(splitPeriods[0].lastTest == steady.completedAt)
        #expect(splitPeriods[1].lastTest == steady.completedAt)
    }

    @Test("An edit to another entry doesn't change a tested period") func periodOtherEntryEdited() {
        let steady = record(.keep, minutesAgo: 10, covered: [entry(0, 360, 0.8)])
        let edited = SettingsTestSchedule.entries([basal(0, 0.8), basal(6, 1.2), basal(22, 0.7)])
        let periods = SettingsTestSchedule.periods(for: .basal, current: edited, history: [steady])
        #expect(!periods[0].changedSince)
        #expect(periods[1] == untested(entry(360, 1320, 1.2)))
    }

    @Test("When two tests covered a period the newest decides, in whatever order they arrive") func periodNewestWins() {
        let covered = [entry(0, 360, 0.8)]
        let newer = record(.keep, minutesAgo: 10, covered: covered)
        let older = record(.increase, minutesAgo: 600, covered: covered)

        for history in [[newer, older], [older, newer]] {
            let period = SettingsTestSchedule.periods(for: .basal, current: profile, history: history)[0]
            #expect(period.lastTest == newer.completedAt)
            #expect(period.lastDirection == .keep)
        }
    }

    @Test("A test that covered only another entry says nothing about this one") func periodCoveredOnlyOther() {
        let other = record(.increase, minutesAgo: 10, covered: [entry(360, 1320, 1.0)])
        let steady = record(.keep, minutesAgo: 600, covered: [entry(0, 360, 0.8)])
        let periods = SettingsTestSchedule.periods(for: .basal, current: profile, history: [other, steady])
        // The newer test covered the daytime entry, so the overnight one still goes by the older test.
        #expect(periods[0].lastTest == steady.completedAt)
        #expect(periods[0].lastDirection == .keep)
        #expect(periods[1].lastTest == other.completedAt)
        #expect(periods[1].lastDirection == .increase)
        #expect(periods[2] == untested(entry(1320, 1440, 0.7)))
    }

    @Test("A test over midnight marks each entry it touched") func periodOvernightTest() {
        let overnight = record(.keep, minutesAgo: 10, covered: [entry(0, 360, 0.8), entry(1320, 1440, 0.7)])
        let periods = SettingsTestSchedule.periods(for: .basal, current: profile, history: [overnight])
        #expect(periods[0].lastTest == overnight.completedAt)
        #expect(periods[1] == untested(entry(360, 1320, 1.0)))
        #expect(periods[2].lastTest == overnight.completedAt)
    }

    @Test("Tests saved without a schedule, and tests of other settings, are ignored") func periodIgnoresUnusableRecords() {
        let legacy = record(.increase, minutesAgo: 5, covered: nil)
        let carbRatio = record(.decrease, minutesAgo: 6, kind: .carbRatio, covered: [entry(0, 360, 0.8)])
        let steady = record(.keep, minutesAgo: 600, covered: [entry(0, 360, 0.8)])

        #expect(
            SettingsTestSchedule.periods(for: .basal, current: profile, history: [legacy, carbRatio]) == profile
                .map(untested)
        )

        let periods = SettingsTestSchedule.periods(for: .basal, current: profile, history: [legacy, carbRatio, steady])
        #expect(periods[0].lastTest == steady.completedAt)
        #expect(periods[0].lastDirection == .keep)
    }

    @Test("A test marks only the periods of its own kind") func periodsByKind() {
        let isfProfile = [entry(0, 720, 50), entry(720, 1440, 40)]
        let basalTest = record(.keep, minutesAgo: 600, covered: [entry(0, 360, 0.8)])
        let isfTest = record(.decrease, minutesAgo: 10, kind: .isf, covered: [entry(0, 720, 50)])

        // An ISF test doesn't mark a basal period, whatever its entries cover.
        let basalPeriods = SettingsTestSchedule.periods(for: .basal, current: profile, history: [isfTest, basalTest])
        #expect(basalPeriods[0].lastTest == basalTest.completedAt)
        #expect(basalPeriods[0].lastDirection == .keep)
        #expect(SettingsTestSchedule.periods(for: .basal, current: profile, history: [isfTest]) == profile.map(untested))

        // And a basal test doesn't mark an ISF period.
        let isfPeriods = SettingsTestSchedule.periods(for: .isf, current: isfProfile, history: [basalTest, isfTest])
        #expect(isfPeriods[0] == SettingsTestPeriod(
            entry: isfProfile[0],
            lastTest: isfTest.completedAt,
            lastDirection: .decrease,
            changedSince: false
        ))
        #expect(isfPeriods[1] == untested(isfProfile[1]))
        #expect(SettingsTestSchedule.periods(for: .isf, current: isfProfile, history: [basalTest]) == isfProfile.map(untested))
    }

    @Test("No schedule means no periods") func periodsWithoutSchedule() {
        let steady = record(.keep, minutesAgo: 10, covered: [entry(0, 360, 0.8)])
        #expect(SettingsTestSchedule.periods(for: .basal, current: [], history: [steady]).isEmpty)
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

    @Test("An entry that runs the whole day reads as all day, not midnight to midnight") func spanTextAllDay() {
        #expect(SettingsTestSchedule.spanText(of: entry(0, 1440, 0.8), formatter: britain) == "All day")
        #expect(SettingsTestSchedule.spanText(of: entry(0, 1440, 0.8)) == String(localized: "All day"))
        // Only the whole day: one ending at midnight from later in the day is still a span.
        #expect(SettingsTestSchedule.spanText(of: entry(60, 1440, 0.8), formatter: britain) == "01:00–00:00")
        // Inside a sentence it is lowercase ("This test covered all day."); other spans read the same either way.
        #expect(SettingsTestSchedule.spanText(of: entry(0, 1440, 0.8), inSentence: true, formatter: britain) == "all day")
        #expect(SettingsTestSchedule.spanText(of: entry(0, 1440, 0.8), inSentence: true) == String(localized: "all day"))
        #expect(
            SettingsTestSchedule.spanText(of: entry(0, 360, 0.8), inSentence: true, formatter: britain) == "00:00–06:00"
        )
    }
}
