import CoreData
import Foundation
import Swinject

extension BasalTest {
    final class Provider: BaseProvider, BasalTestProvider {
        @Injected() var iobService: IOBService!
        @Injected() var determinationStorage: DeterminationStorage!
        @Injected() var fetchGlucoseManager: FetchGlucoseManager!

        private let context = CoreDataStack.shared.newTaskContext()

        required init(resolver: Resolver) {
            super.init(resolver: resolver)
        }

        // MARK: - Devices

        func hasCgmAndPump() -> Bool {
            fetchGlucoseManager.cgmGlucoseSourceType != .none && deviceManager.pumpManager != nil
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
            let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: CarbEntryStored.self,
                onContext: context,
                predicate: NSPredicate(format: "carbs > 0 AND date >= %@ AND date <= %@", start as NSDate, end as NSDate),
                key: "date",
                ascending: false,
                fetchLimit: 1
            )
            return await context.perform { !((results as? [CarbEntryStored]) ?? []).isEmpty }
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
