import CoreData
import Foundation

/// Builds the status snapshot from Core Data, following the field rules in the API contract.
final class AIAssistantsSnapshotBuilder {
    struct LoopInfo {
        /// `nil` or `.distantPast` if the loop never ran.
        let lastLoopDate: Date?
        let lastError: Error?
    }

    private static let recentGlucoseWindow: TimeInterval = 3 * 60 * 60
    private static let recentGlucoseLimit = 60
    private static let treatmentsWindow: TimeInterval = 24 * 60 * 60
    private static let treatmentsLimit = 400

    private let context: NSManagedObjectContext
    private let loopInfo: () -> LoopInfo
    private let units: () -> GlucoseUnits

    init(context: NSManagedObjectContext, loopInfo: @escaping () -> LoopInfo, units: @escaping () -> GlucoseUnits) {
        self.context = context
        self.loopInfo = loopInfo
        self.units = units
    }

    /// Resets the context first. It doesn't merge other contexts' saves, and a pump event and its
    /// bolus reference each other, so once read they would stay in it with their old values.
    func build(now: Date) async throws -> StatusSnapshot {
        let loop = Self.loop(loopInfo())
        let unitsName = units().rawValue
        return try await context.perform { [context] in
            context.reset()
            let determination = try Self.fetch(
                OrefDetermination.self,
                NSPredicate(format: "deliverAt != nil"),
                newestFirstBy: "deliverAt",
                limit: 1,
                in: context
            ).first
            return try StatusSnapshot(
                generatedAt: now,
                units: unitsName,
                glucose: Self.glucose(now: now, in: context),
                iob: determination.flatMap { Self.finite($0.iob) },
                cob: determination.map { Int($0.cob) },
                loop: loop,
                prediction: determination.map {
                    StatusSnapshot.Prediction(
                        eventualMgdl: Self.finite($0.eventualBG).map { Int($0.rounded()) },
                        insulinReq: Self.finite($0.insulinReq)
                    )
                },
                override: Self.activeOverride(now: now, in: context),
                tempTarget: Self.activeTempTarget(now: now, in: context),
                recentTreatments: Self.recentTreatments(now: now, in: context)
            )
        }
    }

    // MARK: - Fields

    private static func loop(_ info: LoopInfo) -> StatusSnapshot.Loop {
        let lastRunAt = info.lastLoopDate.flatMap { $0 == .distantPast ? nil : $0 }
        if let error = info.lastError {
            return .init(lastRunAt: lastRunAt, succeeded: false, error: error.localizedDescription)
        }
        // A loop that never ran hasn't succeeded either: unknown.
        return .init(lastRunAt: lastRunAt, succeeded: lastRunAt == nil ? nil : true, error: nil)
    }

    /// `latest` is the newest reading, however old, so a stale sensor shows as stale.
    private static func glucose(now: Date, in context: NSManagedObjectContext) throws -> StatusSnapshot.Glucose {
        let lastTwo = try fetch(
            GlucoseStored.self,
            NSPredicate(format: "date != nil"),
            newestFirstBy: "date",
            limit: 2,
            in: context
        )
        let latest = lastTwo.first.flatMap { reading -> StatusSnapshot.LatestGlucose? in
            guard let date = reading.date else { return nil }
            return .init(
                date: date,
                mgdl: Int(reading.glucose),
                direction: reading.direction.flatMap { BloodGlucose.Direction(rawValue: $0)?.rawValue },
                deltaMgdl: lastTwo.dropFirst().first.map { Int(reading.glucose) - Int($0.glucose) }
            )
        }
        let recent = try fetch(
            GlucoseStored.self,
            NSPredicate(format: "date >= %@", now.addingTimeInterval(-recentGlucoseWindow) as NSDate),
            newestFirstBy: "date",
            limit: recentGlucoseLimit,
            in: context
        )
        return .init(
            latest: latest,
            recent: recent.reversed().compactMap { reading in
                reading.date.map { StatusSnapshot.GlucoseReading(date: $0, mgdl: Int(reading.glucose)) }
            }
        )
    }

    /// The newest enabled override. Trio leaves an override enabled after its time runs out,
    /// so one that has ended isn't reported.
    private static func activeOverride(now: Date, in context: NSManagedObjectContext) throws -> StatusSnapshot.Override? {
        guard let row = try fetch(
            OverrideStored.self,
            NSPredicate(format: "enabled == YES AND date != nil"),
            newestFirstBy: "date",
            limit: 1,
            in: context
        ).first, let startedAt = row.date else { return nil }
        let endsAt = row.indefinite ? nil : endDate(start: startedAt, minutes: row.duration)
        if let endsAt, endsAt <= now { return nil }
        return .init(name: row.name ?? "Override", startedAt: startedAt, endsAt: endsAt, percentage: row.percentage)
    }

    /// The newest enabled temp target, while its time hasn't run out.
    private static func activeTempTarget(now: Date, in context: NSManagedObjectContext) throws -> StatusSnapshot.TempTarget? {
        guard let row = try fetch(
            TempTargetStored.self,
            NSPredicate(format: "enabled == YES AND date != nil"),
            newestFirstBy: "date",
            limit: 1,
            in: context
        ).first,
            let startedAt = row.date,
            let target = finite(row.target),
            let endsAt = endDate(start: startedAt, minutes: row.duration),
            endsAt > now
        else { return nil }
        return .init(name: row.name ?? "Temp Target", targetMgdl: target, startedAt: startedAt, endsAt: endsAt)
    }

    /// Carbs entries without their FPU equivalents (the meal entry carries the fat and protein),
    /// plus boluses, newest first.
    private static func recentTreatments(now: Date, in context: NSManagedObjectContext) throws -> [StatusSnapshot.Treatment] {
        let since = now.addingTimeInterval(-treatmentsWindow) as NSDate
        let carbs = try fetch(
            CarbEntryStored.self,
            NSPredicate(format: "date >= %@ AND isFPU == NO", since),
            newestFirstBy: "date",
            limit: treatmentsLimit,
            in: context
        ).compactMap { entry -> StatusSnapshot.Treatment? in
            guard let date = entry.date else { return nil }
            let note = entry.note?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .carbs(
                date: date,
                carbs: entry.carbs,
                fat: entry.fat > 0 ? entry.fat : nil,
                protein: entry.protein > 0 ? entry.protein : nil,
                note: note?.isEmpty == false ? note : nil
            )
        }
        let boluses = try fetch(
            PumpEventStored.self,
            NSPredicate(format: "timestamp >= %@ AND bolus != nil", since),
            newestFirstBy: "timestamp",
            limit: treatmentsLimit,
            prefetching: ["bolus"],
            in: context
        ).compactMap { event -> StatusSnapshot.Treatment? in
            guard let date = event.timestamp, let bolus = event.bolus, let units = finite(bolus.amount) else { return nil }
            return .bolus(date: date, units: units, isSMB: bolus.isSMB, isExternal: bolus.isExternal)
        }
        return Array((carbs + boluses).sorted { $0.date > $1.date }.prefix(treatmentsLimit))
    }

    // MARK: - Helpers

    private static func fetch<Entity: NSManagedObject>(
        _: Entity.Type,
        _ predicate: NSPredicate,
        newestFirstBy key: String,
        limit: Int,
        prefetching relationships: [String] = [],
        in context: NSManagedObjectContext
    ) throws -> [Entity] {
        let request = NSFetchRequest<Entity>(entityName: String(describing: Entity.self))
        request.predicate = predicate
        request.sortDescriptors = [NSSortDescriptor(key: key, ascending: false)]
        request.fetchLimit = limit
        request.relationshipKeyPathsForPrefetching = relationships
        return try context.fetch(request)
    }

    /// `nil` without a positive duration.
    private static func endDate(start: Date, minutes: NSDecimalNumber?) -> Date? {
        guard let minutes = finite(minutes), minutes > 0 else { return nil }
        return start.addingTimeInterval(minutes * 60)
    }

    /// Goes through the decimal's text: `doubleValue` turns 0.11 into 0.11000000000000001.
    /// The service rejects NaN and infinity.
    private static func finite(_ number: NSDecimalNumber?) -> Double? {
        guard let value = number.flatMap({ Double($0.stringValue) }), value.isFinite else { return nil }
        return value
    }
}
