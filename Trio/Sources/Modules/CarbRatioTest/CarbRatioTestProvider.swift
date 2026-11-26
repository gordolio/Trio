import CoreData
import Foundation
import Swinject

extension CarbRatioTest {
    final class Provider: BaseProvider, CarbRatioTestReads {
        @Injected() private var settingsManager: SettingsManager!
        /// The ISF test's reads (settings, glucose, insulin and carbs on board, boluses, the pump, temp basals, SMBs,
        /// determinations, adjustments), shared rather than copied.
        let shared: ISFTest.Provider
        /// Its own context for the carb entries with their grams, which no other test reads.
        private let context: NSManagedObjectContext

        required init(resolver: Resolver) {
            shared = ISFTest.Provider(resolver: resolver)
            context = CoreDataStack.shared.newTaskContext()
            super.init(resolver: resolver)
        }

        // MARK: - Settings the test runs on

        /// The carb ratio schedule in grams per unit, empty when there is none saved.
        func carbRatioEntries() -> [SettingsTestScheduleEntry] {
            guard let ratios = storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self) else { return [] }
            return Self.entries(in: ratios)
        }

        /// A carb ratio schedule as entries in grams per unit that each run to the next start, the last to midnight. A
        /// ratio in exchanges becomes grams as Trio's own lookup does it, at 12 g an exchange
        /// (`ISFTest.Provider.carbRatio(in:at:)`), so both read the same ratio at any time. An entry of 0 or less is
        /// left out, as that lookup finds no ratio in it.
        static func entries(in ratios: CarbRatios) -> [SettingsTestScheduleEntry] {
            let sorted = ratios.schedule.sorted { $0.offset < $1.offset }
            return sorted.enumerated().compactMap { index, entry in
                guard entry.ratio > 0 else { return nil }
                let end = index + 1 < sorted.count ? sorted[index + 1].offset : 1440
                let value = ratios.units == .exchanges ? 12 / entry.ratio : entry.ratio
                return SettingsTestScheduleEntry(startMinutes: entry.offset, endMinutes: end, value: value)
            }
        }

        /// Max Bolus, as the Treatments screen reads it: the pump settings saved, or Trio's defaults for them. Nil
        /// without either, rather than the 10 U Treatments falls back to, which isn't a limit the user set.
        func maxBolus() -> Decimal? {
            storage.retrieve(OpenAPS.Settings.settings, as: PumpSettings.self)?.maxBolus
                ?? PumpSettings(from: OpenAPS.defaults(for: OpenAPS.Settings.settings))?.maxBolus
        }

        /// Max Carbs, as the Treatments screen reads it.
        func maxCarbs() -> Decimal? {
            settingsManager.settings.maxCarbs
        }

        // MARK: - Carbs with their grams

        /// The carb entries dated in the window, oldest first, with their grams: carbs above 0, fat and protein's carb
        /// equivalents among them, as the service's watchdog reads them (`CoreDataSettingsTestEvents.carbEntries`), with
        /// the same ID, the entry's permanent object ID, so they match the entries Begin kept and the watchdog's.
        func fetchCarbs(from start: Date, to end: Date) async throws -> [CarbRatioTestCarbs] {
            let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: CarbEntryStored.self,
                onContext: context,
                predicate: NSPredicate(format: "carbs > 0 AND date >= %@ AND date <= %@", start as NSDate, end as NSDate),
                key: "date",
                ascending: true
            )
            let context = context
            return await context.perform {
                ((results as? [CarbEntryStored]) ?? []).compactMap { entry in
                    guard let date = entry.date else { return nil }
                    return CarbRatioTestCarbs(
                        id: entry.objectID.uriRepresentation().absoluteString,
                        date: date,
                        // Stored as a double: to 2 decimals, so 37.5 g reads as 37.5, not a binary neighbour.
                        grams: rounded(Decimal(entry.carbs), scale: 2, roundingMode: .plain)
                    )
                }
            }
        }

        // MARK: - The ISF test's reads

        func isfEntries() -> [SettingsTestScheduleEntry] { shared.isfEntries() }
        func isf(at date: Date) -> Decimal? { shared.isf(at: date) }
        func target(at date: Date) -> Decimal? { shared.target(at: date) }
        func carbRatio(at date: Date) -> Decimal? { shared.carbRatio(at: date) }
        func currentIOB() -> Decimal? { shared.currentIOB() }
        func currentCOB() async throws -> Decimal? { try await shared.currentCOB() }
        func pumpDelivery() -> ISFTestPumpDelivery? { shared.pumpDelivery() }

        func fetchGlucose(from start: Date, to end: Date) async throws -> [BasalTestReading] {
            try await shared.fetchGlucose(from: start, to: end)
        }

        func fetchRecentGlucose(minutes: Int) async throws -> [BasalTestReading] {
            try await shared.fetchRecentGlucose(minutes: minutes)
        }

        func fetchDeterminations(from start: Date, to end: Date) async throws -> [ISFTestDetermination] {
            try await shared.fetchDeterminations(from: start, to: end)
        }

        func fetchBoluses(from start: Date, to end: Date) async throws -> [ISFTestBolus] {
            try await shared.fetchBoluses(from: start, to: end)
        }

        func fetchBolusRecords(from start: Date, to end: Date) async throws -> [ISFTestBolusRecord] {
            try await shared.fetchBolusRecords(from: start, to: end)
        }

        func fetchSMBs(since start: Date, until end: Date) async throws -> [BasalTestSMB] {
            try await shared.fetchSMBs(since: start, until: end)
        }

        func fetchTempBasals(from start: Date, to end: Date) async throws -> [BasalTestTempBasal] {
            try await shared.fetchTempBasals(from: start, to: end)
        }

        func zeroTempDeterminations(from start: Date, to end: Date) async throws -> [Date] {
            try await shared.zeroTempDeterminations(from: start, to: end)
        }

        func fetchArrowReading(atOrBefore date: Date) async throws -> ISFTestArrowReading? {
            try await shared.fetchArrowReading(atOrBefore: date)
        }

        func fetchSuspendReading(startedAt: Date, to end: Date) async throws -> BasalTestEvaluator.SuspendReading {
            try await shared.fetchSuspendReading(startedAt: startedAt, to: end)
        }

        func fetchPumpInterruptions(from start: Date, to end: Date) async throws -> [Date] {
            try await shared.fetchPumpInterruptions(from: start, to: end)
        }

        func hasActiveAdjustment() async throws -> Bool {
            try await shared.hasActiveAdjustment()
        }

        func fetchDoseIOB(at now: Date) async throws -> Decimal? {
            try await shared.fetchDoseIOB(at: now)
        }
    }
}
