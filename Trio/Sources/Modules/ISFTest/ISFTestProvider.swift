import CoreData
import Foundation
import LoopKit
import Swinject

extension ISFTest {
    final class Provider: BaseProvider, ISFTestProvider {
        /// The basal test's reads (glucose, trend, IOB, COB, temp basals and whether Trio asked for a zero one, a temp
        /// basal set on the pump, carbs, SMBs, adjustments, devices), shared rather than copied.
        let shared: BasalTest.Provider
        /// Manual boluses, read the same way as `SettingsTestService` reads them to watch a running test.
        private let events: CoreDataSettingsTestEvents

        required init(resolver: Resolver) {
            shared = BasalTest.Provider(resolver: resolver)
            events = CoreDataSettingsTestEvents(context: CoreDataStack.shared.newTaskContext())
            super.init(resolver: resolver)
        }

        // MARK: - Settings the test runs on

        /// The ISF schedule in mg/dL per unit, empty when there is none saved.
        func isfEntries() -> [SettingsTestScheduleEntry] {
            SettingsTestSchedule.isfEntries(from: storage)
        }

        /// The basal schedule, for the Check screen's word on the newest basal test. Empty when there is none saved.
        func basalEntries() -> [SettingsTestScheduleEntry] {
            SettingsTestSchedule.basalEntries(from: storage)
        }

        /// The ISF in force at `date`, in mg/dL per unit: from the schedule as the test keeps it (`isfEntries`), so a
        /// profile in mmol/L keeps its decimals.
        func isf(at date: Date) -> Decimal? {
            ISFTestEvaluator.scheduleValue(in: isfEntries(), at: date)
        }

        /// The glucose target in force at `date`, in mg/dL.
        func target(at date: Date) -> Decimal? {
            guard let targets = storage.retrieve(OpenAPS.Settings.bgTargets, as: BGTargets.self) else { return nil }
            return Self.target(in: targets, at: date)
        }

        /// The glucose target schedule in mg/dL, empty when there is none saved: what Begin keeps so the Dose step and the
        /// bolus read the target in force then.
        func targetEntries() -> [SettingsTestScheduleEntry] {
            guard let targets = storage.retrieve(OpenAPS.Settings.bgTargets, as: BGTargets.self) else { return [] }
            return Self.targetEntries(in: targets)
        }

        /// A target schedule as entries in mg/dL that each run to the next start, the last to midnight: the low end of each
        /// range, as Trio's own target and `target(in:at:)` take it, converted from mmol/L as that is.
        static func targetEntries(in targets: BGTargets) -> [SettingsTestScheduleEntry] {
            let sorted = targets.targets.sorted { $0.offset < $1.offset }
            return sorted.enumerated().map { index, entry in
                let end = index + 1 < sorted.count ? sorted[index + 1].offset : 1440
                let value = targets.units == .mmolL ? entry.low.asMgdL : entry.low
                return SettingsTestScheduleEntry(startMinutes: entry.offset, endMinutes: end, value: value)
            }
        }

        /// The carb ratio in force at `date`, in grams per unit.
        func carbRatio(at date: Date) -> Decimal? {
            guard let ratios = storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self) else { return nil }
            return Self.carbRatio(in: ratios, at: date)
        }

        /// The target in force at `date`, in mg/dL: the low end of its range, as Trio's own target. A profile saved in
        /// mmol/L is converted with the app's own helper.
        static func target(in targets: BGTargets, at date: Date) -> Decimal? {
            guard let low = targets.currentTarget(at: date) else { return nil }
            return targets.units == .mmolL ? low.asMgdL : low
        }

        /// The carb ratio in force at `date`, in grams per unit: the entry that started most recently at or before that
        /// time of day. Nil when none has started yet. A ratio in exchanges becomes grams as Trio's own lookup does it,
        /// at 12 g an exchange.
        static func carbRatio(in ratios: CarbRatios, at date: Date, calendar: Calendar = .current) -> Decimal? {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            guard let entry = ratios.schedule.filter({ $0.offset <= minute }).max(by: { $0.offset < $1.offset }),
                  entry.ratio > 0
            else { return nil }
            switch ratios.units {
            case .grams: return entry.ratio
            case .exchanges: return 12 / entry.ratio
            }
        }

        // MARK: - Insulin on board

        /// Insulin on board now, nil while Trio hasn't worked it out. The shared read gives 0 then, which would pass for
        /// none on board.
        func currentIOB() -> Decimal? {
            shared.iobService.currentIOB
        }

        // MARK: - Boluses

        /// The boluses in the window, oldest first, from any source, whatever their SMB flag (`allBoluses`). One recorded
        /// at 0 U is left out.
        func fetchBoluses(from start: Date, to end: Date) async throws -> [ISFTestBolus] {
            try await events.allBoluses(from: start, to: end)
        }

        /// Every bolus row in the window, manual or flagged as an SMB, with its amount, 0 U included: for reading the
        /// test bolus again.
        func fetchBolusRecords(from start: Date, to end: Date) async throws -> [ISFTestBolusRecord] {
            try await events.bolusRecords(from: start, to: end)
        }

        // MARK: - The pump

        /// What the pump is doing with basal now, from its status. Nil without a pump, or when its state can't be read.
        func pumpDelivery() -> ISFTestPumpDelivery? {
            Self.pumpDelivery(for: deviceManager.pumpManager?.status.basalDeliveryState)
        }

        /// A pump's basal delivery state as the test reads it: scheduled basal, a temp basal running or changing, or no
        /// basal going in (suspended, suspending, resuming, or not working). Nil when there is no state, and for an active
        /// state dated in the distant past, which is how a pump that isn't available reports itself.
        static func pumpDelivery(for state: PumpManagerStatus.BasalDeliveryState?) -> ISFTestPumpDelivery? {
            switch state {
            case nil:
                return nil
            case let .active(since):
                return since == .distantPast ? nil : .delivering
            case .cancelingTempBasal,
                 .initiatingTempBasal,
                 .tempBasal:
                return .tempBasal
            case .pumpInoperable,
                 .resuming,
                 .suspended,
                 .suspending:
                return .suspended
            }
        }

        /// When the pump was suspended or resumed, gave an alarm, or had its site, reservoir or pod changed in the window,
        /// oldest first (`SettingsTestEvents.pumpInterruptions`).
        func fetchPumpInterruptions(from start: Date, to end: Date) async throws -> [Date] {
            try await events.pumpInterruptions(from: start, to: end)
        }

        /// Whether basal was stopped from Begin to `end`, and whether Trio asked for it in Basal Testing: a zero temp only
        /// Closed Loop asked for as the test began is settling's (`SettingsTestEvents.isfSuspendReading`).
        func fetchSuspendReading(startedAt: Date, to end: Date) async throws -> BasalTestEvaluator.SuspendReading {
            try await events.isfSuspendReading(startedAt: startedAt, to: end)
        }

        // MARK: - Carbs on board and the bolus

        /// Carbs on board now, from Trio's newest determination of the last 12 minutes (`ISFTestEvaluator.recentCOB`),
        /// the same source and age as insulin on board for the dose. Nil when there is none that recent: unread is not
        /// none.
        func currentCOB() async throws -> Decimal? {
            let now = Date()
            let determinations = try await fetchDeterminations(
                from: now.addingTimeInterval(-BasalTest.Config.endReadingMaxAge - ISFTest.Config.savedDateTolerance),
                to: now.addingTimeInterval(ISFTest.Config.savedDateTolerance)
            )
            return ISFTestEvaluator.recentCOB(determinations, now: now)
        }

        /// The newest CGM reading at or before `date`, a history timestamp, with its arrow, from the 12 minutes before it.
        /// Nil when there is none.
        func fetchArrowReading(atOrBefore date: Date) async throws -> ISFTestArrowReading? {
            try await events.arrowReading(
                atOrBefore: date.addingTimeInterval(ISFTest.Config.savedDateTolerance),
                since: date.addingTimeInterval(-BasalTest.Config.endReadingMaxAge - ISFTest.Config.savedDateTolerance)
            )
        }

        // MARK: - Determinations

        /// Trio's determinations in the window, oldest first, with the insulin on board each held: for settling, which
        /// waits for Trio's first loop in Basal Testing, and for the insulin on board just before the bolus.
        func fetchDeterminations(from start: Date, to end: Date) async throws -> [ISFTestDetermination] {
            try await events.determinations(from: start, to: end)
        }
    }
}
