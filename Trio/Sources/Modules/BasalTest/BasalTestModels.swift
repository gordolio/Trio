import Foundation

struct BasalTestReading: JSON, Equatable, Identifiable {
    var id: Date { date }
    let date: Date
    /// mg/dL
    let glucose: Int
}

enum BasalTestPhase: String, JSON, Equatable {
    case running
    case finished
}

enum BasalTestEndReason: String, JSON, Equatable {
    /// The planned time was up.
    case completed
    /// The user ended it before the planned time.
    case endedEarly
    /// Trio suspended insulin for a low, so normal dosing came back.
    case low
    /// Carbs or a bolus were logged during the fast.
    case interrupted
    /// The planned time was up, but the pump history couldn't be read to check for a low.
    case unchecked
}

enum BasalTestOutcome: String, JSON, Equatable {
    case steady
    case rising
    case falling
    /// Ended too soon to say.
    case inconclusive
    /// Something happened during the fast that makes the result unusable.
    case invalid

    /// Whether the result says anything about the basal rates.
    var isConclusive: Bool {
        switch self {
        case .falling,
             .rising,
             .steady: return true
        case .inconclusive,
             .invalid: return false
        }
    }
}

/// The wizard's persisted state. Everything about a result can be rebuilt from the window the
/// test covered, so a test that finished while the app was closed still reports properly.
struct BasalTestState: JSON, Equatable {
    var id = UUID()
    var phase: BasalTestPhase = .running
    var startedAt: Date
    /// Seconds
    var plannedDuration: TimeInterval
    /// mg/dL
    var startGlucose: Int
    var startIOB: Decimal
    var previousMode: DosingMode
    /// For example "Overnight".
    var timeBlock: String
    /// The settings test session that holds the way back, so the service's record of why it ended the session can be
    /// matched to this test. Optional so a state saved before it was kept still decodes.
    var sessionID: UUID?

    // What the test runs on, saved when it starts. Optional so a state saved before they were kept still
    // decodes; without them the result is inconclusive.
    /// The ISF in force at the start, in mg/dL per unit.
    var isf: Decimal?
    /// Average scheduled basal over the planned hours, in units per hour.
    var scheduledBasal: Decimal?
    /// The basal schedule entries the planned hours cover. Nil when there were none to save.
    var coveredEntries: [SettingsTestScheduleEntry]?

    // Filled in when the test finishes.
    var endedAt: Date?
    var endReason: BasalTestEndReason?
    var endGlucose: Int?
    var readings: [BasalTestReading] = []
    var outcome: BasalTestOutcome?
    var interference: String?

    var plannedEnd: Date { startedAt.addingTimeInterval(plannedDuration) }
}

/// Which side of zero insulin on board sits on, judged at the two decimals the app shows, so anything
/// that reads 0.00 is none.
enum BasalTestIOB: Equatable {
    /// A dose is still acting.
    case positive
    /// Trio held basal back.
    case negative
    case none

    init(_ iob: Decimal) {
        let shown = rounded(iob, scale: 2, roundingMode: .bankers)
        if shown > 0 {
            self = .positive
        } else if shown < 0 {
            self = .negative
        } else {
            self = .none
        }
    }
}

/// A small bolus Trio gave on its own.
struct BasalTestSMB: Equatable {
    let date: Date
    /// Units
    let units: Decimal
}

/// What one of Trio's determinations said about carbs on board.
struct BasalTestCOBSample: Equatable {
    let date: Date
    /// Grams
    let cob: Decimal
}

/// A temp basal the pump ran.
struct BasalTestTempBasal: Equatable {
    let date: Date
    /// Units per hour
    let rate: Decimal
    let minutes: Int
}

/// Turns what happened during a fast into a result. Pure, so it can be tested without a loop.
enum BasalTestEvaluator {
    struct Evaluation: Equatable {
        let outcome: BasalTestOutcome
        /// End minus start, in mg/dL.
        let netChange: Int
        let direction: SettingsTestDirection?
        /// Net change ÷ ISF ÷ hours fasted: the units per hour that would explain the change. Negative for a
        /// fall. Nil without an ISF or any elapsed time.
        let ratePerHour: Decimal?
        /// That rate as a share of the scheduled basal, negative for a fall. Nil without a scheduled basal.
        let share: Decimal?
    }

    /// The result comes from the docs' smallest basal change: drift worth less than that much of the
    /// scheduled basal, over a fast of at least the docs' shortest length, is steady. Without an end glucose
    /// (the CGM recorded nothing during the fast) there is nothing to compare, so it is inconclusive.
    static func evaluate(
        startGlucose: Int,
        endGlucose: Int?,
        elapsed: TimeInterval,
        reason: BasalTestEndReason,
        interference: String?,
        isf: Decimal?,
        scheduledBasal: Decimal?,
        step: Decimal = BasalTest.Config.docsSmallestStep
    ) -> Evaluation {
        let net = endGlucose.map { $0 - startGlucose } ?? 0

        // Worked out whatever the outcome, because the result screen shows it.
        var ratePerHour: Decimal?
        var share: Decimal?
        if endGlucose != nil, elapsed > 0, let isf, isf > 0 {
            let rate = Decimal(net) / isf / (Decimal(elapsed) / 3600)
            ratePerHour = rate
            if let scheduledBasal, scheduledBasal > 0 {
                share = rate / scheduledBasal
            }
        }

        func result(_ outcome: BasalTestOutcome, _ direction: SettingsTestDirection?) -> Evaluation {
            Evaluation(outcome: outcome, netChange: net, direction: direction, ratePerHour: ratePerHour, share: share)
        }

        if interference != nil || reason == .interrupted {
            return result(.invalid, nil)
        }

        // A low ends the test, and a fall into one points the same way as any other fall.
        if reason == .low {
            return result(.falling, .decrease)
        }

        // A low can't be ruled out, so whatever glucose did says nothing about the basal.
        if reason == .unchecked {
            return result(.inconclusive, nil)
        }

        guard endGlucose != nil else {
            return result(.inconclusive, nil)
        }

        guard elapsed >= BasalTest.Config.docsShortestFast else {
            return result(.inconclusive, nil)
        }

        // Needs both the ISF and the scheduled basal.
        guard let shareOfBasal = share else {
            return result(.inconclusive, nil)
        }

        if abs(shareOfBasal) < step {
            return result(.steady, .keep)
        }
        return shareOfBasal > 0 ? result(.rising, .increase) : result(.falling, .decrease)
    }

    /// How far glucose can move over the fast, in mg/dL, before it is worth one docs step of the
    /// scheduled basal.
    static func steadyBand(
        isf: Decimal,
        scheduledBasal: Decimal,
        hours: Decimal,
        step: Decimal = BasalTest.Config.docsSmallestStep
    ) -> Int {
        let band = rounded(isf * scheduledBasal * step * hours, scale: 0, roundingMode: .plain)
        return NSDecimalNumber(decimal: band).intValue
    }

    /// The ISF in force at `date`, in mg/dL: the entry that started most recently at or before that time of day.
    /// Nil when none has started yet. A profile saved in mmol/L is converted with the app's own helper.
    static func isf(in sensitivities: InsulinSensitivities, at date: Date, calendar: Calendar = .current) -> Decimal? {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        guard let entry = sensitivities.sensitivities.filter({ $0.offset <= minute }).max(by: { $0.offset < $1.offset })
        else { return nil }
        return sensitivities.units == .mmolL ? entry.sensitivity.asMgdL : entry.sensitivity
    }

    /// What a test starting at `start` for `duration` runs on: the schedule entries its hours cover, and the
    /// average basal over them. Each is nil when there is nothing to keep, so an empty list can't read as
    /// "unchanged" and a basal of zero can't be a baseline.
    static func snapshot(
        of entries: [SettingsTestScheduleEntry],
        startingAt start: Date,
        for duration: TimeInterval,
        calendar: Calendar = .current
    ) -> (covered: [SettingsTestScheduleEntry]?, scheduledBasal: Decimal?) {
        let window = SettingsTestTimeWindow(from: start, to: start.addingTimeInterval(duration), calendar: calendar)
        let covered = SettingsTestSchedule.covered(by: window, in: entries)
        guard !covered.isEmpty else { return (nil, nil) }
        let average = SettingsTestSchedule.averageRate(over: window, in: covered)
        return (covered, average > 0 ? average : nil)
    }

    /// The scheduled basal a test is judged against. With the schedule it saved, that is the average over the
    /// hours it actually ran, so one ended early isn't judged on hours it never reached. Without it, the average
    /// saved at the start. Under a minute of running has no hours to average, so it keeps the saved average too.
    static func scheduledBasal(for test: BasalTestState, endingAt end: Date, calendar: Calendar = .current) -> Decimal? {
        guard let covered = test.coveredEntries else { return test.scheduledBasal }
        let window = SettingsTestTimeWindow(from: test.startedAt, to: end, calendar: calendar)
        guard window.startMinutes != window.endMinutes else { return test.scheduledBasal }
        let average = SettingsTestSchedule.averageRate(over: window, in: covered)
        return average > 0 ? average : nil
    }

    /// The result of a finished test, worked out again from what it saved, so the result screen shows the working
    /// behind the outcome. Nil while the test hasn't finished.
    static func evaluation(of test: BasalTestState, calendar: Calendar = .current) -> Evaluation? {
        guard let end = test.endedAt, let reason = test.endReason else { return nil }
        return evaluate(
            startGlucose: test.startGlucose,
            endGlucose: test.endGlucose,
            elapsed: end.timeIntervalSince(test.startedAt),
            reason: reason,
            interference: test.interference,
            isf: test.isf,
            scheduledBasal: scheduledBasal(for: test, endingAt: end, calendar: calendar)
        )
    }

    /// Whether Trio suspended insulin while the test ran, from `start` to `end` inclusive. In Basal Testing, Trio
    /// sets no temp basal except a zero one when glucose or the forecast drops below its threshold, so a zero temp
    /// with time on it is a low. A zero rate for no time is a cancel, not a suspend. After the planned end the test
    /// may still be open, but the previous mode can be back, and a zero temp then says nothing about the fast.
    static func trioSuspended(_ temps: [BasalTestTempBasal], since start: Date, until end: Date) -> Bool {
        firstSuspend(temps, since: start, until: end) != nil
    }

    /// When Trio first suspended insulin for a low while the test ran, from `start` to `end` inclusive, or nil if it
    /// didn't. A low's result is judged up to this moment: after it Trio wasn't giving the basal being tested, and
    /// the carbs that treat the low aren't part of the fast. What counts as a suspend is as for `trioSuspended`.
    static func firstSuspend(_ temps: [BasalTestTempBasal], since start: Date, until end: Date) -> Date? {
        temps.filter { $0.date >= start && $0.date <= end && $0.rate == 0 && $0.minutes > 0 }.map(\.date).min()
    }

    /// Whether Trio gave insulin of its own during the fast, from `start` to `end` inclusive: an SMB, or a temp basal
    /// that delivered for some time. Basal Testing gives neither, so either one means the fast didn't run in Basal
    /// Testing the whole time, even if the mode is back by now. Scheduled basal isn't among the temps (the fetch
    /// leaves it out), and a suspend or a cancel gives nothing.
    static func dosedDuringFast(
        smbs: [BasalTestSMB],
        temps: [BasalTestTempBasal],
        since start: Date,
        until end: Date
    ) -> Bool {
        func inside(_ date: Date) -> Bool { date >= start && date <= end }
        return smbs.contains { inside($0.date) && $0.units > 0 }
            || temps.contains { inside($0.date) && $0.rate > 0 && $0.minutes > 0 }
    }

    /// What the pump history says about a suspend inside the fast.
    enum SuspendReading: Equatable {
        case none
        /// The first zero temp with time on it started at this time.
        case suspended(at: Date)
        /// The temp basals couldn't be read.
        case unreadable
    }

    /// What a running fast's periodic check found that ends it.
    enum RunningCheck: Equatable {
        /// Trio suspended insulin for a low at this time.
        case low(at: Date)
        /// The service ended the test at this time because carbs were logged.
        case carbsLogged(at: Date)
        /// The planned time is up.
        case completed
        /// The planned time is up, but the pump history couldn't be read, so a low can't be ruled out.
        case completedUnchecked
        /// The dosing mode was changed before the planned end, so the rest of the fast didn't run in Basal Testing.
        case modeChanged
        /// Basal was stopped inside the fast, but Basal Testing was off by the time of the check and the service didn't
        /// end the test for it, so it can't be told whether that was Basal Testing's suspend for a low.
        case unexplainedSuspend
    }

    /// What a running fast's periodic check decides. Nil to keep going.
    ///
    /// First, the service's record of ending this test's session for a low or for carbs inside the fast: the service
    /// brought the usual mode back then, so the record, not the mode, says why. Without one, a mode other than Basal
    /// Testing before the planned end interrupts the fast, whatever the temps show, because a zero temp from another
    /// mode is not a low. Only while Basal Testing is still on is a zero temp in the fast its suspend for a low. Time up
    /// completes the fast, and still ends it when the pump history can't be read, so the usual mode always comes back.
    static func runningCheck(
        sessionID: UUID?,
        serviceEnd: SettingsTestEnd?,
        suspend: SuspendReading,
        now: Date,
        plannedEnd: Date,
        mode: DosingMode
    ) -> RunningCheck? {
        // A record from after the planned end says nothing about the fast, which had run its course by then.
        if let serviceEnd, let sessionID, serviceEnd.sessionID == sessionID, serviceEnd.date <= plannedEnd {
            switch serviceEnd.cause {
            case .low: return .low(at: serviceEnd.date)
            case .carbsLogged: return .carbsLogged(at: serviceEnd.date)
            }
        }
        let timeUp = now >= plannedEnd
        if !timeUp, mode != .basalTesting { return .modeChanged }
        switch suspend {
        case let .suspended(at):
            // Only after the planned end can the mode be other than Basal Testing here.
            return mode == .basalTesting ? .low(at: at) : .unexplainedSuspend
        case .unreadable:
            return timeUp ? .completedUnchecked : nil
        case .none:
            return timeUp ? .completed : nil
        }
    }

    /// The schedule entries the hours a test actually ran covered, out of those it saved at the start: what its record
    /// says it tested. Under a minute of running is the entry it started in, not the whole day. Nil without a saved
    /// schedule, or when the hours touch none of it, so an empty list can't read as "unchanged".
    static func coveredEntries(
        for test: BasalTestState,
        endingAt end: Date,
        calendar: Calendar = .current
    ) -> [SettingsTestScheduleEntry]? {
        guard let saved = test.coveredEntries else { return nil }
        let window = SettingsTestTimeWindow(from: test.startedAt, to: end, calendar: calendar)
        let covered = window.startMinutes == window.endMinutes
            ? saved.filter { $0.startMinutes <= window.startMinutes && window.startMinutes < $0.endMinutes }
            : SettingsTestSchedule.covered(by: window, in: saved)
        return covered.isEmpty ? nil : covered
    }

    /// `value` rounded toward zero to `scale` decimals, so a number shown is never more than it is. The rate and the
    /// share are both shown this way, so the working agrees with itself and with the verdict.
    static func towardZero(_ value: Decimal, scale: Int) -> Decimal {
        let magnitude = rounded(abs(value), scale: scale, roundingMode: .down)
        // Negating zero would give a Decimal that isn't a number.
        return value < 0 && magnitude != 0 ? -magnitude : magnitude
    }

    /// Names the part of the day a test started in.
    static func timeBlock(for date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 6 ..< 11: return String(localized: "Morning")
        case 11 ..< 17: return String(localized: "Afternoon")
        case 17 ..< 22: return String(localized: "Evening")
        default: return String(localized: "Overnight")
        }
    }

    /// The SMBs Trio gave inside the window while no carbs were on board. The docs read consistently positive
    /// IOB while not eating as basal that may be too low. An SMB goes by the newest COB sample at or before
    /// it, and one with no earlier sample isn't counted.
    static func fastingSMBs(
        _ smbs: [BasalTestSMB],
        cob: [BasalTestCOBSample],
        window: SettingsTestTimeWindow,
        calendar: Calendar = .current
    ) -> (count: Int, units: Decimal) {
        let samples = cob.sorted { $0.date < $1.date }
        var count = 0
        var units = Decimal.zero
        // Samples before this index are at or before the SMB being looked at. SMBs go oldest first, so it
        // only moves forward and the scan runs once over both lists.
        var after = 0
        for smb in smbs.sorted(by: { $0.date < $1.date }) {
            let parts = calendar.dateComponents([.hour, .minute], from: smb.date)
            guard window.contains(minuteOfDay: (parts.hour ?? 0) * 60 + (parts.minute ?? 0)) else { continue }
            while after < samples.count, samples[after].date <= smb.date {
                after += 1
            }
            guard after > 0, samples[after - 1].cob == 0 else { continue }
            count += 1
            units += smb.units
        }
        return (count, units)
    }

    /// The end glucose smooths over the last few readings so one noisy value doesn't decide it. Nil when the CGM
    /// recorded nothing, so a fast with no readings can't pass as one where glucose didn't move.
    static func endGlucose(from readings: [BasalTestReading]) -> Int? {
        let tail = readings.sorted { $0.date < $1.date }.suffix(3)
        guard !tail.isEmpty else { return nil }
        return tail.map(\.glucose).reduce(0, +) / tail.count
    }

    /// A share of the basal as a whole percent, rounded toward zero, so a share just under the docs' step never
    /// reads as the step itself.
    static func wholePercent(_ share: Decimal) -> Int {
        NSDecimalNumber(decimal: towardZero(share * 100, scale: 0)).intValue
    }
}
