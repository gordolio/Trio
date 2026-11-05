import Foundation

/// One stretch of a time-of-day schedule and the value in force over it. Minutes count from midnight,
/// `endMinutes` is exclusive, and the last entry of a schedule ends at 1440.
struct SettingsTestScheduleEntry: JSON, Equatable {
    let startMinutes: Int
    let endMinutes: Int
    let value: Decimal
}

/// The part of the day a test ran over, as minutes from midnight. A window that ends at or before
/// its start runs past midnight into the next day.
struct SettingsTestTimeWindow: Equatable {
    let startMinutes: Int
    let endMinutes: Int

    func contains(minuteOfDay: Int) -> Bool {
        if endMinutes > startMinutes {
            return minuteOfDay >= startMinutes && minuteOfDay < endMinutes
        }
        return minuteOfDay >= startMinutes || minuteOfDay < endMinutes
    }

    /// The window as ranges inside one day: one range, or two when it wraps past midnight.
    fileprivate var segments: [Range<Int>] {
        if endMinutes > startMinutes { return [startMinutes ..< endMinutes] }
        return [startMinutes ..< 1440, 0 ..< endMinutes]
    }
}

extension SettingsTestTimeWindow {
    init(from start: Date, to end: Date, calendar: Calendar) {
        func minuteOfDay(_ date: Date) -> Int {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
        self.init(startMinutes: minuteOfDay(start), endMinutes: minuteOfDay(end))
    }
}

/// One entry of a current schedule and what the newest test of the same kind over it said.
struct SettingsTestPeriod: Equatable {
    let entry: SettingsTestScheduleEntry
    /// When the newest test over this entry finished. Nil when no test has covered it.
    let lastTest: Date?
    /// What that test said about the setting.
    let lastDirection: SettingsTestDirection?
    /// The entry no longer matches what that test covered: a rate or a boundary was edited since.
    let changedSince: Bool
}

/// Helpers for checking a test against the time-of-day schedule it ran over.
enum SettingsTestSchedule {
    /// Whether a new basal test can build on the last one.
    enum BasalGate: Equatable {
        /// The last basal test was steady and the schedule it covered is unchanged.
        case ready(lastSteady: Date)
        /// There is no basal test whose schedule we know.
        case noSteadyTest
        /// The last basal test was steady, but a rate it covered has been edited since.
        case changedSince(Date)
        /// The last basal test said to raise or lower basal.
        case lastWasNot(SettingsTestDirection, Date)
    }

    /// A basal profile as entries that each run to the next start, the last to midnight.
    static func entries(_ basal: [BasalProfileEntry]) -> [SettingsTestScheduleEntry] {
        let sorted = basal.sorted { $0.minutes < $1.minutes }
        return sorted.enumerated().map { index, entry in
            let end = index + 1 < sorted.count ? sorted[index + 1].minutes : 1440
            return SettingsTestScheduleEntry(startMinutes: entry.minutes, endMinutes: end, value: entry.rate)
        }
    }

    /// The saved basal schedule as entries, empty when there is none.
    static func basalEntries(from storage: FileStorage) -> [SettingsTestScheduleEntry] {
        entries(storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? [])
    }

    /// An insulin sensitivity profile as entries in mg/dL per unit that each run to the next start, the last to
    /// midnight. A profile saved in mmol/L is converted without rounding (`isfInMgdL`).
    static func entries(_ isf: InsulinSensitivities) -> [SettingsTestScheduleEntry] {
        let sorted = isf.sensitivities.sorted { $0.offset < $1.offset }
        return sorted.enumerated().map { index, entry in
            let end = index + 1 < sorted.count ? sorted[index + 1].offset : 1440
            let value = isfInMgdL(entry.sensitivity, units: isf.units)
            return SettingsTestScheduleEntry(startMinutes: entry.offset, endMinutes: end, value: value)
        }
    }

    /// An insulin sensitivity in mg/dL per unit. One in mmol/L per unit keeps its decimals: the app's own helper rounds
    /// to whole mg/dL, which moves an ISF of 2.8 mmol/L (50.45 mg/dL) by close to 1%, a fifth of the docs' smallest step,
    /// and shown in mmol/L again it reads as the number the user entered.
    static func isfInMgdL(_ sensitivity: Decimal, units: GlucoseUnits) -> Decimal {
        units == .mmolL ? sensitivity / GlucoseUnits.exchangeRate : sensitivity
    }

    /// The saved insulin sensitivity schedule as entries in mg/dL per unit, empty when there is none.
    static func isfEntries(from storage: FileStorage) -> [SettingsTestScheduleEntry] {
        guard let profile = storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self)
        else { return [] }
        return entries(profile)
    }

    /// A carb ratio schedule as entries in grams per unit that each run to the next start, the last to midnight, with a
    /// ratio in exchanges turned into grams as Trio's own lookup does it (`CarbRatioTest.Provider.entries(in:)`).
    static func entries(_ ratios: CarbRatios) -> [SettingsTestScheduleEntry] {
        CarbRatioTest.Provider.entries(in: ratios)
    }

    /// The saved carb ratio schedule as entries in grams per unit, empty when there is none.
    static func carbRatioEntries(from storage: FileStorage) -> [SettingsTestScheduleEntry] {
        guard let ratios = storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self) else { return [] }
        return entries(ratios)
    }

    /// The entries that overlap the window at all.
    static func covered(
        by window: SettingsTestTimeWindow,
        in entries: [SettingsTestScheduleEntry]
    ) -> [SettingsTestScheduleEntry] {
        entries.filter { overlap(of: $0, with: window) > 0 }
    }

    /// The value over the window, each entry weighted by the minutes of the window it fills.
    static func averageRate(over window: SettingsTestTimeWindow, in entries: [SettingsTestScheduleEntry]) -> Decimal {
        var weighted = Decimal.zero
        var minutes = 0
        for entry in entries {
            let inWindow = overlap(of: entry, with: window)
            weighted += entry.value * Decimal(inWindow)
            minutes += inWindow
        }
        return minutes > 0 ? weighted / Decimal(minutes) : .zero
    }

    /// Whether every covered entry is still in the current schedule with the same start, end and value.
    static func isUnchanged(_ covered: [SettingsTestScheduleEntry], in current: [SettingsTestScheduleEntry]) -> Bool {
        covered.allSatisfy { current.contains($0) }
    }

    /// Whether a basal test can build on the last one. `history` is newest first, as the service returns it,
    /// and the newest basal test decides.
    static func basalGate(history: [SettingsTestRecord], current: [SettingsTestScheduleEntry]) -> BasalGate {
        guard let latest = history.first(where: { $0.kind == .basal }) else { return .noSteadyTest }
        switch latest.direction {
        case .keep:
            // Saved before schedules were kept, so there is nothing to compare the current schedule with.
            guard let covered = latest.coveredEntries else { return .noSteadyTest }
            return isUnchanged(covered, in: current)
                ? .ready(lastSteady: latest.completedAt)
                : .changedSince(latest.completedAt)
        case .decrease,
             .increase:
            return .lastWasNot(latest.direction, latest.completedAt)
        }
    }

    /// What the newest ISF test says about starting a carb ratio test, as `basalGate` says it of the newest basal test
    /// for the ISF test. A warning only (round 7 Q4), never a block.
    enum ISFGate: Equatable {
        /// The last ISF test looked accurate and the ISF schedule it covered is unchanged.
        case ready(lastAccurate: Date)
        /// There is no ISF test whose schedule we know.
        case noAccurateTest
        /// The last ISF test looked accurate, but an ISF it covered has been edited since.
        case changedSince(Date)
        /// The last ISF test said to raise or lower the ISF.
        case lastWasNot(SettingsTestDirection, Date)
    }

    /// Whether a carb ratio test can build on the last ISF test. `history` is newest first, as the service returns it,
    /// and the newest ISF test decides, as the newest basal test does for `basalGate`.
    static func isfGate(history: [SettingsTestRecord], current: [SettingsTestScheduleEntry]) -> ISFGate {
        guard let latest = history.first(where: { $0.kind == .isf }) else { return .noAccurateTest }
        switch latest.direction {
        case .keep:
            // Saved before schedules were kept, so there is nothing to compare the current schedule with.
            guard let covered = latest.coveredEntries else { return .noAccurateTest }
            return isUnchanged(covered, in: current)
                ? .ready(lastAccurate: latest.completedAt)
                : .changedSince(latest.completedAt)
        case .decrease,
             .increase:
            return .lastWasNot(latest.direction, latest.completedAt)
        }
    }

    /// Each current entry with what the newest test of `kind` over it said. A test counts for an entry when the
    /// schedule it saved had an entry overlapping this one. Tests of other kinds, and tests saved without a schedule
    /// that can't be placed, are skipped. `history` can be in any order.
    static func periods(
        for kind: SettingsTestKind,
        current: [SettingsTestScheduleEntry],
        history: [SettingsTestRecord]
    ) -> [SettingsTestPeriod] {
        let tests = history.filter { $0.kind == kind && $0.coveredEntries != nil }
        return current.map { entry in
            let span = SettingsTestTimeWindow(startMinutes: entry.startMinutes, endMinutes: entry.endMinutes)
            let latest = tests
                .filter { !covered(by: span, in: $0.coveredEntries ?? []).isEmpty }
                .max { $0.completedAt < $1.completedAt }
            guard let latest else {
                return SettingsTestPeriod(entry: entry, lastTest: nil, lastDirection: nil, changedSince: false)
            }
            // What that test saw over this stretch of the day, against what is there now.
            let seen = covered(by: span, in: latest.coveredEntries ?? [])
            return SettingsTestPeriod(
                entry: entry,
                lastTest: latest.completedAt,
                lastDirection: latest.direction,
                changedSince: !seen.allSatisfy { $0 == entry }
            )
        }
    }

    // MARK: - Times of day

    /// Shared, so each row doesn't build its own.
    static let timeFormatter = makeTimeFormatter(locale: .autoupdatingCurrent)

    /// Reads times in UTC, so minutes from midnight show as they are on any day and in any time zone.
    static func makeTimeFormatter(locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }

    /// Minutes from midnight as a time of day in the user's locale style. The end of the day, 1440, reads as midnight.
    static func timeText(minutes: Int, formatter: DateFormatter = timeFormatter) -> String {
        formatter.string(from: Date(timeIntervalSince1970: TimeInterval(minutes * 60)))
    }

    /// An entry's stretch of the day, e.g. "00:00–06:00". One that runs the whole day is "All day", not midnight to
    /// midnight, or "all day" `inSentence` ("This test covered all day.").
    static func spanText(
        of entry: SettingsTestScheduleEntry,
        inSentence: Bool = false,
        formatter: DateFormatter = timeFormatter
    ) -> String {
        if entry.startMinutes == 0, entry.endMinutes == 1440 {
            return inSentence ? String(localized: "all day") : String(localized: "All day")
        }
        let start = timeText(minutes: entry.startMinutes, formatter: formatter)
        let end = timeText(minutes: entry.endMinutes, formatter: formatter)
        return "\(start)–\(end)"
    }

    private static func overlap(of entry: SettingsTestScheduleEntry, with window: SettingsTestTimeWindow) -> Int {
        window.segments.reduce(0) { total, segment in
            total + max(0, min(entry.endMinutes, segment.upperBound) - max(entry.startMinutes, segment.lowerBound))
        }
    }
}
