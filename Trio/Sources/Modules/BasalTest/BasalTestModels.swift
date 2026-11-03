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
    /// Whether a record read to check for what spoils a fast couldn't be read when it finished, so something may have
    /// been missed. Optional so a state saved before it was kept still decodes.
    var interferenceUnread: Bool?

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
    /// (the CGM recorded nothing during the fast) there is nothing to compare, so it is inconclusive. So is a fast
    /// whose records couldn't all be read for what spoils it (`interferenceUnread`).
    static func evaluate(
        startGlucose: Int,
        endGlucose: Int?,
        elapsed: TimeInterval,
        reason: BasalTestEndReason,
        interference: String?,
        interferenceUnread: Bool = false,
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

        // Something that spoils the fast may have been missed, a bolus that brought on a low among them.
        if interferenceUnread {
            return result(.inconclusive, nil)
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

    /// How far glucose can move over the fast, in mg/dL, and still be steady: the largest whole number strictly below
    /// the change that is worth one docs step of the scheduled basal. A change of exactly one step is rising or
    /// falling (`evaluate`), so it must be outside the band, and so must any whole mg/dL past it. Never below 0.
    static func steadyBand(
        isf: Decimal,
        scheduledBasal: Decimal,
        hours: Decimal,
        step: Decimal = BasalTest.Config.docsSmallestStep
    ) -> Int {
        let limit = rounded(isf * scheduledBasal * step * hours, scale: 0, roundingMode: .up)
        return max(0, NSDecimalNumber(decimal: limit).intValue - 1)
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
            interferenceUnread: test.interferenceUnread ?? false,
            isf: test.isf,
            scheduledBasal: scheduledBasal(for: test, endingAt: end, calendar: calendar)
        )
    }

    /// When basal was first stopped while the test ran, from `start` to `end` inclusive, or nil if it wasn't: the first
    /// zero temp with time on it. A zero rate for no time is a cancel, not a suspend. The pump history doesn't say who
    /// set it; `suspendReading` asks Trio's determinations. A low's result is judged up to this moment: after it Trio
    /// wasn't giving the basal being tested, and the carbs that treat the low aren't part of the fast. After the planned
    /// end the test may still be open, but the previous mode can be back, and a zero temp then says nothing about the
    /// fast.
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

    /// What the pump history and Trio's determinations say about a suspend inside the fast.
    enum SuspendReading: Equatable {
        case none
        /// Trio suspended for a low: the first zero temp with time on it started at this time, and one of its
        /// determinations asked for it.
        case suspended(at: Date)
        /// The first zero temp with time on it started at this time, and none of Trio's determinations asked for it, so
        /// it wasn't Trio's suspend for a low. One set on the pump, for example.
        case unexplained(at: Date)
        /// The temp basals couldn't be read.
        case unreadable
    }

    /// How long before a zero temp started a determination can have asked for it: the pump starts a temp a moment after
    /// Trio decides on it, and a slow pump command can stretch that.
    static let zeroTempAskedBefore: TimeInterval = 10 * 60
    /// How long after: a pump clock a little behind the phone's dates the temp early.
    static let zeroTempAskedAfter: TimeInterval = 2 * 60

    /// Whether basal was stopped inside the fast, from `start` to `end` inclusive, and whether Trio asked for it. Only
    /// the first zero temp decides: a fast stopped by someone else is spoiled before any low of Trio's that follows,
    /// and one Trio stopped for a low is over before anything after it. In Basal Testing, Trio asks for a zero temp
    /// only when glucose or the forecast drops below its threshold.
    static func suspendReading(
        _ temps: [BasalTestTempBasal],
        zeroTempDeterminations: [Date],
        since start: Date,
        until end: Date
    ) -> SuspendReading {
        guard let stoppedAt = firstSuspend(temps, since: start, until: end) else { return .none }
        let earliest = stoppedAt.addingTimeInterval(-zeroTempAskedBefore)
        let latest = stoppedAt.addingTimeInterval(zeroTempAskedAfter)
        let asked = zeroTempDeterminations.contains { $0 >= earliest && $0 <= latest }
        return asked ? .suspended(at: stoppedAt) : .unexplained(at: stoppedAt)
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
        /// Basal was stopped inside the fast at this time, and it can't be told that was Basal Testing's suspend for a
        /// low: none of Trio's determinations asked for it, or Basal Testing was off by the time of the check and the
        /// service didn't end the test for it.
        case unexplainedSuspend(at: Date)
    }

    /// What a running fast's periodic check decides. Nil to keep going.
    ///
    /// First, the service's record of ending this test's session inside the fast, for a low, for carbs or for basal
    /// stopped without Trio asking: the service brought the usual mode back then, so the record, not the mode, says
    /// why. Without one, a mode other than Basal Testing before the planned end interrupts the fast, whatever the temps
    /// show, because a zero temp from another mode is not a low. Only while Basal Testing is still on is a zero temp in
    /// the fast that Trio asked for its suspend for a low; one it didn't ask for stops the fast in any mode. Time up
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
            case .basalStopped: return .unexplainedSuspend(at: serviceEnd.date)
            }
        }
        let timeUp = now >= plannedEnd
        if !timeUp, mode != .basalTesting { return .modeChanged }
        switch suspend {
        case let .suspended(at):
            // Only after the planned end can the mode be other than Basal Testing here.
            return mode == .basalTesting ? .low(at: at) : .unexplainedSuspend(at: at)
        case let .unexplained(at):
            return .unexplainedSuspend(at: at)
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

    /// `value` rounded toward zero to `scale` decimals, so a number shown is never more than it is and a share just
    /// under the docs' step never reads as the step. Rounded values don't always reproduce each other, so the result
    /// card marks them "≈"; the verdict uses the exact values.
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
    /// recorded nothing, so a fast with no readings can't pass as one where glucose didn't move, and nil when the
    /// newest reading is more than `BasalTest.Config.endReadingMaxAge` before `end`, so a CGM that stopped early in the
    /// fast can't have its first hours judged as the whole fast.
    static func endGlucose(from readings: [BasalTestReading], endingAt end: Date) -> Int? {
        let tail = readings.sorted { $0.date < $1.date }.suffix(3)
        guard let newest = tail.last, end.timeIntervalSince(newest.date) <= BasalTest.Config.endReadingMaxAge else {
            return nil
        }
        return tail.map(\.glucose).reduce(0, +) / tail.count
    }

    /// What the archived record says about a result. A low ends the test as a fall whatever the readings were, and
    /// Trio's suspend can come from its forecast while glucose is still above the threshold, so for a low it says what
    /// Trio did and not that glucose fell.
    static func summary(for outcome: BasalTestOutcome, reason: BasalTestEndReason) -> String {
        switch outcome {
        case .steady: return String(localized: "Glucose stayed steady")
        case .rising: return String(localized: "Glucose rose")
        case .falling:
            return reason == .low
                ? String(localized: "Trio suspended insulin for a low")
                : String(localized: "Glucose fell")
        case .inconclusive: return String(localized: "Ended too soon to tell")
        case .invalid: return String(localized: "Fast was interrupted")
        }
    }

    /// What the checks for what spoils a fast found.
    enum Interference: Equatable {
        /// Every record was read, and none spoils the fast.
        case none
        /// The message of the first check that found something.
        case found(String)
        /// Nothing was found, but a record couldn't be read, so something that spoils the fast may have been missed.
        case unreadable
    }

    /// The first check that finds something that spoils the fast. The checks run in order and stop at the first hit.
    /// One whose read throws is logged and the rest still run, so a record that can't be read never hides what a later
    /// one would have found; with nothing found, it leaves the fast unchecked.
    static func firstInterference(_ checks: [(name: String, read: () async throws -> String?)]) async -> Interference {
        var unreadable = false
        for check in checks {
            do {
                if let message = try await check.read() { return .found(message) }
            } catch {
                warning(.settings, "BasalTest: couldn't read \(check.name) to check the fast", error: error)
                unreadable = true
            }
        }
        return unreadable ? .unreadable : .none
    }

    /// What `firstInterference` reads for a fast from `start` to `end`, in order: carbs, a bolus, then Trio's own
    /// dosing, which it doesn't do in Basal Testing. Trio's SMBs and its temp basals are read apart, so one that can't
    /// be read doesn't hide what the other shows.
    static func interferenceChecks(
        hasCarbs: @escaping () async throws -> Bool,
        hasManualBolus: @escaping () async throws -> Bool,
        smbs: @escaping () async throws -> [BasalTestSMB],
        temps: @escaping () async throws -> [BasalTestTempBasal],
        since start: Date,
        until end: Date
    ) -> [(name: String, read: () async throws -> String?)] {
        let dosed = String(localized: "Trio dosed during the fast, so Basal Testing wasn't on the whole time.")
        return [
            (name: "carbs", read: {
                try await hasCarbs() ? String(localized: "Carbs were logged during the fast.") : nil
            }),
            (name: "manual boluses", read: {
                try await hasManualBolus() ? String(localized: "A bolus was given during the fast.") : nil
            }),
            (name: "Trio's SMBs", read: {
                dosedDuringFast(smbs: try await smbs(), temps: [], since: start, until: end) ? dosed : nil
            }),
            (name: "Trio's temp basals", read: {
                dosedDuringFast(smbs: [], temps: try await temps(), since: start, until: end) ? dosed : nil
            })
        ]
    }

    /// What the screen says when basal was stopped inside the fast and it can't be told that was Trio's suspend for a
    /// low.
    static var basalStoppedNote: String {
        String(localized: "Basal was stopped during the fast, and Trio can't tell whether it was for a low.")
    }

    /// How a fast the screen finishes for `reason` at `end` ends, once the history up to then is read. The periodic
    /// checks run every half minute, and the service's can lose its record to a finish that ends the session while it
    /// reads, so a low Trio suspended for may not have been seen yet: it still ends the fast as a low, judged up to the
    /// suspend. Basal stopped without Trio asking interrupts it at the stop. A fast whose history couldn't be read at
    /// its planned end, read now with nothing in it, completed. A low or an interruption already decided stays.
    static func finishing(
        reason: BasalTestEndReason,
        at end: Date,
        suspend: SuspendReading
    ) -> (reason: BasalTestEndReason, end: Date, note: String?) {
        guard reason != .low, reason != .interrupted else { return (reason, end, nil) }
        switch suspend {
        case let .suspended(at):
            return (.low, at, nil)
        case let .unexplained(at):
            return (.interrupted, at, basalStoppedNote)
        case .none:
            return (reason == .unchecked ? .completed : reason, end, nil)
        case .unreadable:
            return (reason, end, nil)
        }
    }

    /// A share of the basal as a whole percent, rounded toward zero, so a share just under the docs' step never
    /// reads as the step itself.
    static func wholePercent(_ share: Decimal) -> Int {
        NSDecimalNumber(decimal: towardZero(share * 100, scale: 0)).intValue
    }
}
