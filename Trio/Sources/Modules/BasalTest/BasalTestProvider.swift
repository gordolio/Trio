import CoreData
import Foundation
import Swinject

extension BasalTest {
    final class Provider: BaseProvider, BasalTestProvider {
        @Injected() var iobService: IOBService!
        @Injected() var determinationStorage: DeterminationStorage!
        @Injected() var fetchGlucoseManager: FetchGlucoseManager!

        private let context: NSManagedObjectContext
        /// Temp basals and carbs, read the same way as `SettingsTestService` reads them to watch a running test.
        private let events: CoreDataSettingsTestEvents

        required init(resolver: Resolver) {
            let context = CoreDataStack.shared.newTaskContext()
            self.context = context
            events = CoreDataSettingsTestEvents(context: context)
            super.init(resolver: resolver)
        }

        // MARK: - Devices

        func hasCgmAndPump() -> Bool {
            fetchGlucoseManager.cgmGlucoseSourceType != .none && deviceManager.pumpManager != nil
        }

        // MARK: - Settings the test runs on

        /// The basal schedule, empty when there is none saved.
        func basalEntries() -> [SettingsTestScheduleEntry] {
            SettingsTestSchedule.basalEntries(from: storage)
        }

        /// The ISF in force at `date`, in mg/dL.
        func isf(at date: Date) -> Decimal? {
            guard let profile = storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self)
            else { return nil }
            return BasalTestEvaluator.isf(in: profile, at: date)
        }

        // MARK: - Glucose

        /// Newest first.
        func fetchRecentGlucose(minutes: Int) async throws -> [BasalTestReading] {
            let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
            return try await fetchGlucose(predicate: NSPredicate(format: "date > %@", cutoff as NSDate), ascending: false)
        }

        /// Oldest first.
        func fetchGlucose(from start: Date, to end: Date) async throws -> [BasalTestReading] {
            try await fetchGlucose(
                predicate: NSPredicate(format: "date >= %@ AND date <= %@", start as NSDate, end as NSDate),
                ascending: true
            )
        }

        private func fetchGlucose(predicate: NSPredicate, ascending: Bool) async throws -> [BasalTestReading] {
            let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: GlucoseStored.self,
                onContext: context,
                predicate: predicate,
                key: "date",
                ascending: ascending
            )
            return await context.perform {
                ((results as? [GlucoseStored]) ?? []).compactMap { stored in
                    guard let date = stored.date else { return nil }
                    return BasalTestReading(date: date, glucose: Int(stored.glucose))
                }
            }
        }

        /// The CGM's own trend arrow for the newest reading, if it gave one.
        func fetchNewestDirection() async throws -> BloodGlucose.Direction? {
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: GlucoseStored.self,
                onContext: context,
                predicate: NSPredicate(format: "date > %@", cutoff as NSDate),
                key: "date",
                ascending: false,
                fetchLimit: 1
            )
            return await context.perform { (results as? [GlucoseStored])?.first?.directionEnum }
        }

        // MARK: - IOB and COB

        func getCurrentIOB() -> Decimal {
            iobService.currentIOB ?? 0
        }

        func getCurrentCOB() async throws -> Decimal {
            let ids = try await determinationStorage.fetchLastDeterminationObjectID(
                predicate: NSPredicate.predicateFor30MinAgoForDetermination
            )
            let context = context
            return await context.perform {
                guard let id = ids.first,
                      let determination = try? context.existingObject(with: id) as? OrefDetermination
                else { return 0 }
                return Decimal(determination.cob)
            }
        }

        // MARK: - Fasting SMBs

        /// Oldest first.
        func fetchSMBs(since start: Date) async throws -> [BasalTestSMB] {
            let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: PumpEventStored.self,
                onContext: context,
                predicate: NSPredicate(
                    format: "bolus != nil AND bolus.isSMB == YES AND timestamp >= %@",
                    start as NSDate
                ),
                key: "timestamp",
                ascending: true,
                // A week of SMBs each read their bolus, so it comes in the same fetch.
                relationshipKeyPathsForPrefetching: ["bolus"]
            )
            return await context.perform {
                ((results as? [PumpEventStored]) ?? []).compactMap { event in
                    guard let date = event.timestamp else { return nil }
                    return BasalTestSMB(date: date, units: event.bolus?.amount?.decimalValue ?? 0)
                }
            }
        }

        /// Oldest first. A determination is dated by when it was due, or when it was made if that is missing.
        func fetchCOBSamples(since start: Date) async throws -> [BasalTestCOBSample] {
            let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: OrefDetermination.self,
                onContext: context,
                predicate: NSPredicate(
                    format: "deliverAt >= %@ OR (deliverAt == nil AND timestamp >= %@)",
                    start as NSDate,
                    start as NSDate
                ),
                key: "deliverAt",
                ascending: true,
                // A week of determinations, of which only these three are needed.
                propertiesToFetch: ["deliverAt", "timestamp", "cob"]
            )
            return ((results as? [[String: Any]]) ?? [])
                .compactMap { row in
                    guard let date = (row["deliverAt"] as? Date) ?? (row["timestamp"] as? Date) else { return nil }
                    return BasalTestCOBSample(date: date, cob: Decimal((row["cob"] as? NSNumber)?.intValue ?? 0))
                }
                .sorted { $0.date < $1.date }
        }

        // MARK: - Suspends

        /// Oldest first, without scheduled basal.
        func fetchTempBasals(from start: Date, to end: Date) async throws -> [BasalTestTempBasal] {
            try await events.tempBasals(from: start, to: end)
        }

        // MARK: - Things that spoil a fast

        /// When food was last logged, within the last `hours`.
        func lastCarbEntry(withinHours hours: Int) async throws -> Date? {
            let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
            let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: CarbEntryStored.self,
                onContext: context,
                predicate: NSPredicate(format: "carbs > 0 AND date >= %@", cutoff as NSDate),
                key: "date",
                ascending: false,
                fetchLimit: 1
            )
            return await context.perform { (results as? [CarbEntryStored])?.first?.date }
        }

        /// Carbs logged in a window, e.g. while a fast is running.
        func hasCarbEntries(from start: Date, to end: Date) async throws -> Bool {
            try await events.hasCarbEntries(from: start, to: end)
        }

        /// A bolus the user gave (not an SMB) in a window.
        func hasManualBolus(from start: Date, to end: Date) async throws -> Bool {
            let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: PumpEventStored.self,
                onContext: context,
                predicate: NSPredicate(
                    format: "timestamp >= %@ AND timestamp <= %@ AND bolus != nil AND bolus.isSMB == NO",
                    start as NSDate,
                    end as NSDate
                ),
                key: "timestamp",
                ascending: false,
                fetchLimit: 1
            )
            return await context.perform { !((results as? [PumpEventStored]) ?? []).isEmpty }
        }

        /// A running override or temp target changes basal and sensitivity, which muddies a basal test.
        func hasActiveAdjustment() async throws -> Bool {
            let overrides = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: OverrideStored.self,
                onContext: context,
                predicate: NSPredicate.lastActiveOverride,
                key: "date",
                ascending: false,
                fetchLimit: 1
            )
            let tempTargets = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: TempTargetStored.self,
                onContext: context,
                predicate: NSPredicate.lastActiveTempTarget,
                key: "date",
                ascending: false,
                fetchLimit: 1
            )
            return await context.perform {
                !((overrides as? [OverrideStored]) ?? []).isEmpty || !((tempTargets as? [TempTargetStored]) ?? []).isEmpty
            }
        }
    }
}
