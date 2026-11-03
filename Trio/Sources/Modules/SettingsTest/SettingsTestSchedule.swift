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

/// One entry of the current basal schedule and what the newest test over it said.
struct SettingsTestBasalPeriod: Equatable {
    let entry: SettingsTestScheduleEntry
    /// When the newest test over this entry finished. Nil when no test has covered it.
    let lastTest: Date?
    /// What that test said about basal.
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

    /// Each current entry with what the newest basal test over it said. A test counts for an entry when the
    /// schedule it saved had an entry overlapping this one. Tests saved without a schedule can't be placed, so
    /// they are skipped. `history` can be in any order.
    static func basalPeriods(
        current: [SettingsTestScheduleEntry],
        history: [SettingsTestRecord]
    ) -> [SettingsTestBasalPeriod] {
        let basalTests = history.filter { $0.kind == .basal && $0.coveredEntries != nil }
        return current.map { entry in
            let span = SettingsTestTimeWindow(startMinutes: entry.startMinutes, endMinutes: entry.endMinutes)
            let latest = basalTests
                .filter { !covered(by: span, in: $0.coveredEntries ?? []).isEmpty }
                .max { $0.completedAt < $1.completedAt }
            guard let latest else {
                return SettingsTestBasalPeriod(entry: entry, lastTest: nil, lastDirection: nil, changedSince: false)
            }
            // What that test saw over this stretch of the day, against what is there now.
            let seen = covered(by: span, in: latest.coveredEntries ?? [])
            return SettingsTestBasalPeriod(
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

    /// An entry's stretch of the day, e.g. "00:00–06:00".
    static func spanText(of entry: SettingsTestScheduleEntry, formatter: DateFormatter = timeFormatter) -> String {
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
