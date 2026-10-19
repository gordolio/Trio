import CoreData
import Foundation
import Testing

@testable import Trio

@Suite("AI Assistants snapshot builder", .serialized) struct AIAssistantsSnapshotBuilderTests {
    let stack: CoreDataStack
    let context: NSManagedObjectContext
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    init() async throws {
        stack = try await CoreDataStack.createForTests()
        context = stack.newTaskContext()
    }

    func build(
        units: GlucoseUnits = .mgdL,
        loop: AIAssistantsSnapshotBuilder.LoopInfo = .init(lastLoopDate: nil, lastError: nil)
    ) async throws -> StatusSnapshot {
        try await AIAssistantsSnapshotBuilder(context: context, loopInfo: { loop }, units: { units }).build(now: now)
    }

    func minutesAgo(_ minutes: Double) -> Date {
        now.addingTimeInterval(-minutes * 60)
    }

    /// Inserts rows and saves them, as Trio's storages do.
    func insert(_ makeRows: @escaping (NSManagedObjectContext) -> Void) async throws {
        try await context.perform {
            makeRows(context)
            try context.save()
        }
    }

    func addGlucose(_ mgdl: Int16, minutesAgo minutes: Double, direction: String? = nil) async throws {
        let date = minutesAgo(minutes)
        try await insert { context in
            let row = GlucoseStored(context: context)
            row.id = UUID()
            row.date = date
            row.glucose = mgdl
            row.direction = direction
        }
    }

    func addCarbs(
        _ carbs: Double,
        minutesAgo minutes: Double,
        fat: Double = 0,
        protein: Double = 0,
        note: String? = nil,
        isFPU: Bool = false
    ) async throws {
        let date = minutesAgo(minutes)
        try await insert { context in
            let row = CarbEntryStored(context: context)
            row.id = UUID()
            row.date = date
            row.carbs = carbs
            row.fat = fat
            row.protein = protein
            row.note = note
            row.isFPU = isFPU
        }
    }

    func addBolus(_ amount: Decimal, minutesAgo minutes: Double, isSMB: Bool = false, isExternal: Bool = false) async throws {
        let date = minutesAgo(minutes)
        try await insert { context in
            let event = PumpEventStored(context: context)
            event.id = UUID().uuidString
            event.timestamp = date
            event.type = "Bolus"
            let bolus = BolusStored(context: context)
            bolus.amount = NSDecimalNumber(decimal: amount)
            bolus.isSMB = isSMB
            bolus.isExternal = isExternal
            bolus.pumpEvent = event
        }
    }

    // MARK: - Glucose

    @Test("Latest reading and delta come from the last two readings") func latestAndDeltaFromLastTwoReadings() async throws {
        try await addGlucose(110, minutesAgo: 10)
        try await addGlucose(112, minutesAgo: 5, direction: "Flat")
        let glucose = try await build().glucose
        #expect(glucose.latest == .init(date: minutesAgo(5), mgdl: 112, direction: "Flat", deltaMgdl: 2))
        #expect(glucose.recent == [.init(date: minutesAgo(10), mgdl: 110), .init(date: minutesAgo(5), mgdl: 112)])
    }

    @Test("A single reading has no delta") func singleReadingHasNoDelta() async throws {
        try await addGlucose(112, minutesAgo: 5)
        #expect(try await build().glucose.latest?.deltaMgdl == nil)
    }

    @Test("Recent readings cover the last 3 hours, oldest first") func recentKeepsOnlyLast3HoursOldestFirst() async throws {
        try await addGlucose(100, minutesAgo: 200)
        try await addGlucose(115, minutesAgo: 5)
        try await addGlucose(105, minutesAgo: 170)
        try await addGlucose(110, minutesAgo: 60)
        #expect(try await build().glucose.recent.map(\.mgdl) == [105, 110, 115])
    }

    @Test("Recent readings are the newest 60 at most") func recentKeepsAtMostTheNewest60() async throws {
        try await insert { context in
            for index in 1 ... 70 {
                let row = GlucoseStored(context: context)
                row.id = UUID()
                row.date = minutesAgo(Double(index * 2))
                row.glucose = Int16(100 + index)
            }
        }
        let recent = try await build().glucose.recent
        #expect(recent.count == 60)
        #expect(recent.first?.date == minutesAgo(120))
        #expect(recent.last?.date == minutesAgo(2))
    }

    @Test("A stale latest reading is still reported") func staleLatestReadingIsStillReported() async throws {
        try await addGlucose(140, minutesAgo: 300)
        let glucose = try await build().glucose
        #expect(glucose.latest?.mgdl == 140)
        #expect(glucose.recent.isEmpty)
    }

    @Test("A direction outside the contract's list is left out") func unknownDirectionIsLeftOut() async throws {
        try await addGlucose(112, minutesAgo: 5, direction: "↗")
        #expect(try await build().glucose.latest?.direction == nil)
    }

    @Test("An empty store gives empty or nil fields") func noDataGivesNilFields() async throws {
        let snapshot = try await build(loop: .init(lastLoopDate: .distantPast, lastError: nil))
        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.generatedAt == now)
        #expect(snapshot.glucose.latest == nil)
        #expect(snapshot.glucose.recent.isEmpty)
        #expect(snapshot.iob == nil)
        #expect(snapshot.cob == nil)
        #expect(snapshot.prediction == nil)
        #expect(snapshot.override == nil)
        #expect(snapshot.tempTarget == nil)
        #expect(snapshot.recentTreatments.isEmpty)
        #expect(snapshot.loop == .init(lastRunAt: nil, succeeded: nil, error: nil))
    }

    @Test("Someone using mmol/L still gets mg/dL values") func mmolPersonStillGetsMgdlValues() async throws {
        try await addGlucose(112, minutesAgo: 5)
        try await insert { context in
            let determination = OrefDetermination(context: context)
            determination.id = UUID()
            determination.deliverAt = minutesAgo(4)
            determination.eventualBG = NSDecimalNumber(decimal: 105)
            let target = TempTargetStored(context: context)
            target.id = UUID()
            target.name = "Activity"
            target.enabled = true
            target.date = minutesAgo(10)
            target.duration = NSDecimalNumber(decimal: 60)
            target.target = NSDecimalNumber(decimal: 140)
        }
        let snapshot = try await build(units: .mmolL)
        #expect(snapshot.units == "mmol/L")
        #expect(snapshot.glucose.latest?.mgdl == 112)
        #expect(snapshot.prediction?.eventualMgdl == 105)
        #expect(snapshot.tempTarget?.targetMgdl == 140)
    }

    // MARK: - Determination and loop

    @Test("IOB, COB and the prediction come from the latest determination") func latestDeterminationGivesIOBCOBAndPrediction(
    ) async throws {
        try await insert { context in
            let older = OrefDetermination(context: context)
            older.id = UUID()
            older.deliverAt = minutesAgo(10)
            older.iob = NSDecimalNumber(decimal: 3)
            older.cob = 40
            older.eventualBG = NSDecimalNumber(decimal: 180)
            older.insulinReq = NSDecimalNumber(decimal: 1)
            let latest = OrefDetermination(context: context)
            latest.id = UUID()
            latest.deliverAt = minutesAgo(5)
            latest.iob = NSDecimalNumber(decimal: 1.25)
            latest.cob = 20
            latest.eventualBG = NSDecimalNumber(decimal: 105)
            latest.insulinReq = NSDecimalNumber(decimal: 0.5)
        }
        let snapshot = try await build()
        #expect(snapshot.iob == 1.25)
        #expect(snapshot.cob == 20)
        #expect(snapshot.prediction == .init(eventualMgdl: 105, insulinReq: 0.5))
    }

    @Test("Decimals are sent as stored, without binary rounding noise") func decimalsSentWithoutRoundingNoise() async throws {
        try await insert { context in
            let determination = OrefDetermination(context: context)
            determination.id = UUID()
            determination.deliverAt = minutesAgo(5)
            determination.iob = NSDecimalNumber(string: "0.11")
            determination.insulinReq = NSDecimalNumber(string: "0.11")
        }
        try await addBolus(#require(Decimal(string: "0.11")), minutesAgo: 10)
        let snapshot = try await build()
        #expect(snapshot.iob == 0.11)
        #expect(snapshot.prediction?.insulinReq == 0.11)
        #expect(snapshot.recentTreatments.first?.units == 0.11)
    }

    @Test("A loop that ran without an error succeeded") func loopThatRanWithoutErrorSucceeded() async throws {
        let loop = try await build(loop: .init(lastLoopDate: minutesAgo(5), lastError: nil)).loop
        #expect(loop == .init(lastRunAt: minutesAgo(5), succeeded: true, error: nil))
    }

    @Test("The last loop error marks the loop failed") func lastErrorMarksLoopFailed() async throws {
        let error = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pump unreachable"])
        let loop = try await build(loop: .init(lastLoopDate: minutesAgo(20), lastError: error)).loop
        #expect(loop == .init(lastRunAt: minutesAgo(20), succeeded: false, error: "Pump unreachable"))
    }

    // MARK: - Overrides and temp targets

    @Test("An active indefinite override has no end") func activeOverrideIndefiniteHasNilEndsAt() async throws {
        try await insert { context in
            let older = OverrideStored(context: context)
            older.id = UUID().uuidString
            older.name = "Old"
            older.enabled = false
            older.date = minutesAgo(30)
            older.duration = NSDecimalNumber(decimal: 120)
            older.percentage = 50
            let active = OverrideStored(context: context)
            active.id = UUID().uuidString
            active.name = "Exercise"
            active.enabled = true
            active.indefinite = true
            active.date = minutesAgo(3000)
            active.duration = NSDecimalNumber(decimal: 0)
            active.percentage = 80
        }
        #expect(
            try await build()
                .override == .init(name: "Exercise", startedAt: minutesAgo(3000), endsAt: nil, percentage: 80)
        )
    }

    @Test("An active override ends after its duration") func activeOverrideEndsAfterDuration() async throws {
        try await insert { context in
            let row = OverrideStored(context: context)
            row.id = UUID().uuidString
            row.name = "Sick"
            row.enabled = true
            row.date = minutesAgo(30)
            row.duration = NSDecimalNumber(decimal: 60)
            row.percentage = 120
        }
        #expect(
            try await build()
                .override == .init(name: "Sick", startedAt: minutesAgo(30), endsAt: minutesAgo(-30), percentage: 120)
        )
    }

    @Test("An override whose time ran out isn't reported") func expiredOverrideIsNotReported() async throws {
        try await insert { context in
            let row = OverrideStored(context: context)
            row.id = UUID().uuidString
            row.name = "Sick"
            row.enabled = true
            row.date = minutesAgo(90)
            row.duration = NSDecimalNumber(decimal: 60)
            row.percentage = 120
        }
        #expect(try await build().override == nil)
    }

    @Test("An active temp target ends after its duration") func activeTempTargetEndsAt() async throws {
        try await insert { context in
            let active = TempTargetStored(context: context)
            active.id = UUID()
            active.name = "Activity"
            active.enabled = true
            active.date = minutesAgo(10)
            active.duration = NSDecimalNumber(decimal: 60)
            active.target = NSDecimalNumber(decimal: 140)
            let cancelled = TempTargetStored(context: context)
            cancelled.id = UUID()
            cancelled.name = "Eating soon"
            cancelled.enabled = false
            cancelled.date = minutesAgo(5)
            cancelled.duration = NSDecimalNumber(decimal: 30)
            cancelled.target = NSDecimalNumber(decimal: 80)
        }
        #expect(
            try await build().tempTarget == .init(
                name: "Activity",
                targetMgdl: 140,
                startedAt: minutesAgo(10),
                endsAt: minutesAgo(-50)
            )
        )
    }

    @Test("A temp target whose time ran out isn't reported") func expiredTempTargetIsNotReported() async throws {
        try await insert { context in
            let row = TempTargetStored(context: context)
            row.id = UUID()
            row.name = "Activity"
            row.enabled = true
            row.date = minutesAgo(90)
            row.duration = NSDecimalNumber(decimal: 60)
            row.target = NSDecimalNumber(decimal: 140)
        }
        #expect(try await build().tempTarget == nil)
    }

    // MARK: - Treatments

    @Test(
        "FPU entries are left out; the original meal keeps its fat and protein"
    ) func fpuEntriesExcludedOriginalMealKeepsFatProtein(
    ) async throws {
        try await addCarbs(30, minutesAgo: 60, fat: 20, protein: 25, note: "pizza")
        try await addCarbs(10, minutesAgo: 30, isFPU: true)
        try await addCarbs(10, minutesAgo: 0, isFPU: true)
        #expect(
            try await build().recentTreatments == [
                .carbs(date: minutesAgo(60), carbs: 30, fat: 20, protein: 25, note: "pizza")
            ]
        )
    }

    @Test("A carbs-only entry leaves out fat, protein and an empty note") func carbsOnlyEntryLeavesOutEmptyFields() async throws {
        try await addCarbs(45, minutesAgo: 20, note: "")
        #expect(
            try await build()
                .recentTreatments == [.carbs(date: minutesAgo(20), carbs: 45, fat: nil, protein: nil, note: nil)]
        )
    }

    @Test("SMBs and manual boluses are included with their flags") func smbAndManualBolusesIncludedWithFlags() async throws {
        try await addBolus(0.25, minutesAgo: 20, isSMB: true)
        try await addBolus(2.5, minutesAgo: 10, isExternal: true)
        try await insert { context in
            let tempBasal = PumpEventStored(context: context)
            tempBasal.id = UUID().uuidString
            tempBasal.timestamp = minutesAgo(15)
            tempBasal.type = "TempBasal"
        }
        #expect(
            try await build().recentTreatments == [
                .bolus(date: minutesAgo(10), units: 2.5, isSMB: false, isExternal: true),
                .bolus(date: minutesAgo(20), units: 0.25, isSMB: true, isExternal: false)
            ]
        )
    }

    @Test("Treatments cover the last 24 hours, carbs and boluses merged newest first") func treatmentsMergedNewestFirstWithin24h(
    ) async throws {
        try await addCarbs(50, minutesAgo: 25 * 60)
        try await addBolus(4, minutesAgo: 25 * 60)
        try await addCarbs(20, minutesAgo: 180)
        try await addBolus(1.5, minutesAgo: 120)
        try await addCarbs(15, minutesAgo: 60)
        #expect(
            try await build().recentTreatments == [
                .carbs(date: minutesAgo(60), carbs: 15, fat: nil, protein: nil, note: nil),
                .bolus(date: minutesAgo(120), units: 1.5, isSMB: false, isExternal: false),
                .carbs(date: minutesAgo(180), carbs: 20, fat: nil, protein: nil, note: nil)
            ]
        )
    }

    @Test("Treatments are the newest 400 at most") func treatmentsKeepAtMostTheNewest400() async throws {
        try await insert { context in
            for index in 1 ... 410 {
                let row = CarbEntryStored(context: context)
                row.id = UUID()
                row.date = minutesAgo(Double(index))
                row.carbs = 1
                row.isFPU = false
            }
        }
        let treatments = try await build().recentTreatments
        #expect(treatments.count == 400)
        #expect(treatments.first?.date == minutesAgo(1))
        #expect(treatments.last?.date == minutesAgo(400))
    }

    // MARK: - Freshness

    @Test("A bolus changed by another context shows up in the next build") func bolusChangesFromAnotherContextShowUp() async throws {
        // A pump event and its bolus reference each other, so once read they stay in the context.
        try await addBolus(2, minutesAgo: 10)
        #expect(try await build().recentTreatments.first?.units == 2)
        let other = stack.newTaskContext()
        try await other.perform {
            let request: NSFetchRequest<BolusStored> = BolusStored.fetchRequest()
            let bolus = try #require(try other.fetch(request).first)
            bolus.amount = NSDecimalNumber(decimal: 1.5)
            bolus.isSMB = true
            try other.save()
        }
        let treatment = try await build().recentTreatments.first
        #expect(treatment?.units == 1.5)
        #expect(treatment?.isSMB == true)
    }

    @Test("Changes saved by another context show up in the next build") func changesFromAnotherContextShowUp() async throws {
        try await addCarbs(45, minutesAgo: 20)
        #expect(try await build().recentTreatments.first?.carbs == 45)
        let other = stack.newTaskContext()
        try await other.perform {
            let request: NSFetchRequest<CarbEntryStored> = CarbEntryStored.fetchRequest()
            let row = try #require(try other.fetch(request).first)
            row.carbs = 50
            try other.save()
        }
        #expect(try await build().recentTreatments.first?.carbs == 50)
    }
}
