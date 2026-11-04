import CoreData
import Foundation
import Swinject

extension BasalTest {
    final class Provider: BaseProvider, BasalTestProvider, BasalTestReads {
        @Injected() var iobService: IOBService!
        @Injected() var determinationStorage: DeterminationStorage!
        @Injected() var fetchGlucoseManager: FetchGlucoseManager!

        private let context: NSManagedObjectContext
        /// Temp basals and carbs, read the same way as `SettingsTestService` reads them to watch a running test, and the CGM
        /// readings.
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

        /// Whether the pump is running a temp basal set on the pump itself. Basal Testing cancels only Trio's own.
        func hasPumpSetTempBasal() -> Bool {
            deviceManager.pumpManager?.status.basalDeliveryState?.isManualTempBasal ?? false
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

        /// Newest first (`CoreDataSettingsTestEvents.recentGlucose`).
        func fetchRecentGlucose(minutes: Int) async throws -> [BasalTestReading] {
            try await events.recentGlucose(since: Date().addingTimeInterval(-Double(minutes) * 60))
        }

        /// Oldest first (`CoreDataSettingsTestEvents.glucose`).
        func fetchGlucose(from start: Date, to end: Date) async throws -> [BasalTestReading] {
            try await events.glucose(from: start, to: end)
        }

        /// The CGM's own trend arrow for the newest reading of the last day, if it gave one
        /// (`CoreDataSettingsTestEvents.newestDirection`).
        func fetchNewestDirection() async throws -> BloodGlucose.Direction? {
            try await events.newestDirection(since: Date().addingTimeInterval(-24 * 3600))
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
        func fetchSMBs(since start: Date, until end: Date = .distantFuture) async throws -> [BasalTestSMB] {
            let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: PumpEventStored.self,
                onContext: context,
                predicate: NSPredicate(
                    format: "bolus != nil AND bolus.isSMB == YES AND timestamp >= %@ AND timestamp <= %@",
                    start as NSDate,
                    end as NSDate
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

        /// Whether basal was stopped in the window, and whether Trio asked for it.
        func fetchSuspendReading(from start: Date, to end: Date) async throws -> BasalTestEvaluator.SuspendReading {
            try await events.suspendReading(from: start, to: end)
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

        /// The carb entries dated in a window, e.g. while a fast is running, read as `SettingsTestService` reads them.
        func fetchCarbEntries(from start: Date, to end: Date) async throws -> [SettingsTestCarbEntry] {
            try await events.carbEntries(from: start, to: end)
        }

        /// When the pump was suspended or resumed, gave an alarm, or had its site, reservoir or pod changed in the window,
        /// oldest first (`SettingsTestEvents.pumpInterruptions`).
        func fetchPumpInterruptions(from start: Date, to end: Date) async throws -> [Date] {
            try await events.pumpInterruptions(from: start, to: end)
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
