import CoreData
import Foundation
import Swinject

/// What `storeCarbs` throws. Its text is sent to the service, and the assistant reads it out.
struct AIRequestCarbsNotSavedError: LocalizedError {
    /// `nil` when the save reported no error but the entry isn't there.
    let underlying: Error?

    var errorDescription: String? { "Couldn't save the carbs" }
}

/// Trio's treatment side of a request: the wearer's limits, Trio's bolus calculator, the carbs storage and the pump.
final class BaseAIRequestTreatments: AIRequestTreatments {
    /// The `minPredBG` the watch's bolus recommendation uses without a determination from the last 30 minutes.
    private static let defaultMinPredBG: Decimal = 54

    /// The glucose and `minPredBG`, in mg/dL, under which Trio's bolus calculator gives 0 U: `BolusCalculationManager.swift:452`.
    /// Copied here to say why a dose is 0 U. They are for display only: the dose comes from the calculator.
    static let lowGlucoseMgdl: Decimal = 54
    /// The loop run's age over which Trio's bolus calculator gives 0 U: `BolusCalculationManager.swift:452`. For display only.
    static let staleLoopAge: TimeInterval = 15 * 60

    /// The longest a loop's age is reported: a day, which is also all a loop that never ran gets.
    private static let longestLoopAge: TimeInterval = 24 * 60 * 60

    private let settingsManager: SettingsManager
    private let carbsStorage: CarbsStorage
    private let bolusCalculationManager: BolusCalculationManager
    private let apsManager: APSManager
    private let determinationStorage: DeterminationStorage
    /// Reads the latest glucose, for the reason a dose is 0 U.
    private let snapshotBuilder: AIAssistantsSnapshotBuilder

    init(resolver: Resolver) {
        let settingsManager = resolver.resolve(SettingsManager.self)!
        let apsManager = resolver.resolve(APSManager.self)!
        self.settingsManager = settingsManager
        self.apsManager = apsManager
        carbsStorage = resolver.resolve(CarbsStorage.self)!
        bolusCalculationManager = resolver.resolve(BolusCalculationManager.self)!
        determinationStorage = resolver.resolve(DeterminationStorage.self)!
        snapshotBuilder = AIAssistantsSnapshotBuilder(
            context: CoreDataStack.shared.newTaskContext(),
            loopInfo: { .init(lastLoopDate: apsManager.lastLoopDate, lastError: apsManager.lastError.value) },
            units: { settingsManager.settings.units }
        )
    }

    var limits: AIRequestLimits {
        let settings = settingsManager.settings
        return AIRequestLimits(
            maxCarbs: settings.maxCarbs,
            maxFat: settings.maxFat,
            maxProtein: settings.maxProtein,
            maxBolus: settingsManager.pumpSettings.maxBolus
        )
    }

    var logsFatAndProtein: Bool {
        settingsManager.settings.useFPUconversion
    }

    /// Trio's bolus calculator's dose for the carbs, as the watch's bolus recommendation gets it, made deliverable
    /// exactly as shown.
    func dose(forCarbs carbs: Decimal) async -> AIRequestDose {
        let determination = await latestDetermination()
        let result = await bolusCalculationManager.handleBolusCalculation(
            carbs: carbs,
            useFattyMealCorrection: false,
            useSuperBolus: false,
            lastLoopDate: apsManager.lastLoopDate,
            minPredBG: determination.minPredBG,
            simulatedCOB: nil,
            isBackdated: false
        )
        return AIRequestDose(
            units: Self.deliverableDose(result.insulinCalculated, increment: settingsManager.preferences.bolusIncrement)
        )
    }

    /// The largest dose at or below `units` that has at most two decimals, like the amounts shown, and is a whole
    /// number of the pump's increments. The pump rounds any other amount down, so this is exactly what it delivers.
    /// The increment comes from a `Double`, so it's rounded to three decimals first: a noisy 0.04999… would
    /// otherwise make no multiple of it two decimals long, and the dose 0.
    static func deliverableDose(_ units: Decimal, increment: Decimal) -> Decimal {
        let increment = rounded(increment, scale: 3, roundingMode: .plain)
        guard units > 0, increment > 0 else { return 0 }
        var steps = rounded(rounded(units, scale: 2, roundingMode: .down) / increment, scale: 0, roundingMode: .down)
        // A multiple of 0.025 can have three decimals, so step down to one that has two.
        while steps > 0 {
            let dose = steps * increment
            if rounded(dose, scale: 2, roundingMode: .down) == dose { return dose }
            steps -= 1
        }
        return 0
    }

    /// Why Trio's dose is 0 U, for the notification: `nil` for a dose over 0 U and for a 0 U dose Trio has no reason
    /// for. Only a 0 U dose needs the glucose, the forecast and the insulin on board, so only then are they read.
    func noDoseReason(units: Decimal) async -> String? {
        guard units <= 0 else { return nil }
        let now = Date()
        var glucose: StatusSnapshot.LatestGlucose?
        var displayUnits = settingsManager.settings.units.rawValue
        do {
            let snapshot = try await snapshotBuilder.build(now: now)
            glucose = snapshot.glucose.latest
            displayUnits = snapshot.units
        } catch {
            debug(.service, "AI requests: couldn't read the glucose for the 0 U reason: \(error)")
        }
        let determination = await latestDetermination()
        return Self.noDoseReason(
            glucose: glucose,
            lastLoopDate: apsManager.lastLoopDate,
            minPredBG: determination.minPredBG,
            iob: determination.iob,
            maxIOB: settingsManager.preferences.maxIOB,
            displayUnits: displayUnits,
            units: units,
            now: now
        )
    }

    /// Why Trio's dose is 0 U, but only a reason Trio knows is true, in this order: low glucose, a forecast low, a loop
    /// that hasn't run (the bolus calculator's own limits), no glucose reading, and insulin on board at its max. The
    /// calculator also gives 0 U when the dose it works out is 0 or under the pump's increment, which has no reason
    /// worth saying, so then there is `nil`.
    /// - Parameters:
    ///   - glucose: The newest glucose reading, however old.
    ///   - lastLoopDate: When the loop last ran, `.distantPast` if it never did.
    ///   - minPredBG: The forecast low the dose was worked out with, in mg/dL.
    ///   - iob: The insulin on board the dose was worked out with, from the same determination as `minPredBG`, or `nil`
    ///     when there was none.
    ///   - maxIOB: The wearer's max insulin on board.
    ///   - displayUnits: A `GlucoseUnits` raw value.
    ///   - units: Trio's dose. There's a reason only when it is 0.
    static func noDoseReason(
        glucose: StatusSnapshot.LatestGlucose?,
        lastLoopDate: Date,
        minPredBG: Decimal,
        iob: Decimal?,
        maxIOB: Decimal,
        displayUnits: String,
        units: Decimal,
        now: Date
    ) -> String? {
        guard units <= 0 else { return nil }
        if let glucose, Decimal(glucose.mgdl) < lowGlucoseMgdl {
            let reading = AIRequestDisplayText.value(mgdl: glucose.mgdl, displayUnits: displayUnits)
            return String(
                localized: "glucose is low (\(reading))",
                comment: "Why Trio's dose is 0 U: the placeholder is the glucose, for example '52 mg/dL'"
            )
        }
        if minPredBG < lowGlucoseMgdl {
            return String(
                localized: "glucose is forecast to go low",
                comment: "Why Trio's dose is 0 U: Trio's forecast goes under 54 mg/dL"
            )
        }
        let loopAge = now.timeIntervalSince(lastLoopDate)
        if loopAge > staleLoopAge {
            // A loop that never ran has no date, so its age is as long as is reported: a day.
            let minutes = String(Int(min(loopAge, longestLoopAge) / 60))
            return String(
                localized: "the loop hasn't run for \(minutes) min",
                comment: "Why Trio's dose is 0 U: the placeholder is how many minutes ago the loop last ran"
            )
        }
        // The calculator reads glucose as 0 when there is none, which is under 54 too.
        if glucose == nil {
            return String(
                localized: "there's no recent glucose reading",
                comment: "Why Trio's dose is 0 U: Trio has no glucose reading"
            )
        }
        // The calculator limits the dose to what is left under the max: the max less the insulin on board.
        if let iob, iob >= maxIOB {
            return String(
                localized: "insulin on board is at your max",
                comment: "Why Trio's dose is 0 U: the insulin Trio has already given is at the max insulin on board"
            )
        }
        return nil
    }

    /// Stores the meal as Trio's remote meal command does, eaten now, with the assistant and the description in the
    /// note, then checks the meal entry was saved: `CarbsStorage` doesn't report a failed save.
    func storeCarbs(for request: AIMealRequest, carbs: Decimal, fat: Decimal, protein: Decimal) async throws {
        let id = UUID()
        let entry = CarbsEntry(
            id: id.uuidString, createdAt: Date(), actualDate: nil,
            carbs: carbs, fat: fat, protein: protein,
            note: request.note, enteredBy: CarbsEntry.local, isFPU: false,
            fpuID: fat > 0 || protein > 0 ? UUID().uuidString : nil
        )
        do {
            try await carbsStorage.storeCarbs([entry], areFetchedFromRemote: false)
            guard try await isMealEntryStored(id: id) else {
                debug(.service, "AI requests: the carbs entry wasn't there after saving it")
                throw AIRequestCarbsNotSavedError(underlying: nil)
            }
        } catch let error as AIRequestCarbsNotSavedError {
            throw error
        } catch {
            debug(.service, "AI requests: couldn't save the carbs: \(error)")
            throw AIRequestCarbsNotSavedError(underlying: error)
        }
    }

    func enactBolus(_ units: Decimal) async -> String? {
        let outcome = BolusOutcome()
        // `enactBolus` calls back before it returns, or never, as for an amount that isn't above 0.
        await apsManager.enactBolus(amount: Double(truncating: units as NSNumber), isSMB: false) { success, message in
            outcome.record(success: success, message: message)
        }
        guard let result = outcome.result else {
            debug(.service, "AI requests: the pump didn't report on the \(units) U bolus")
            return "Trio couldn't confirm the bolus started"
        }
        return result.success ? nil : result.message
    }

    // MARK: - Helpers

    /// The newest determination from the last 30 minutes, the one Trio's bolus calculator reads: its `minPredBG`, read
    /// as the watch's bolus recommendation reads it, and its insulin on board, which is `nil` when there's none.
    private func latestDetermination() async -> (minPredBG: Decimal, iob: Decimal?) {
        do {
            let context = CoreDataStack.shared.newTaskContext()
            context.name = "AIRequestTreatments.latestDetermination"
            let ids = try await determinationStorage.fetchLastDeterminationObjectID(
                predicate: NSPredicate.predicateFor30MinAgoForDetermination
            )
            let latest = try await context.perform { [context] () -> (minPredBG: Decimal?, iob: Decimal)? in
                guard let id = ids.first, let determination = try context.existingObject(with: id) as? OrefDetermination
                else { return nil }
                // As the calculator reads it: no insulin on board is 0.
                return (determination.minPredBGFromReason, (determination.iob ?? 0) as Decimal)
            }
            return (latest?.minPredBG ?? Self.defaultMinPredBG, latest?.iob)
        } catch {
            debug(.service, "AI requests: couldn't read the last determination, using \(Self.defaultMinPredBG): \(error)")
            return (Self.defaultMinPredBG, nil)
        }
    }

    /// Whether the store has the meal entry, not one of its fat and protein equivalents. `CarbsStorage` saves the
    /// meal entry with the `CarbsEntry`'s UUID as its `id`.
    private func isMealEntryStored(id: UUID) async throws -> Bool {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "AIRequestTreatments.isMealEntryStored"
        return try await context.perform { [context] in
            let request = CarbEntryStored.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@ AND isFPU == NO", id as NSUUID)
            request.fetchLimit = 1
            return try context.count(for: request) > 0
        }
    }
}

/// What `APSManager.enactBolus` called back with, if it did.
private final class BolusOutcome {
    private let lock = NSLock()
    private var recorded: (success: Bool, message: String)?

    var result: (success: Bool, message: String)? {
        lock.withLock { recorded }
    }

    func record(success: Bool, message: String) {
        lock.withLock { recorded = (success, message) }
    }
}
