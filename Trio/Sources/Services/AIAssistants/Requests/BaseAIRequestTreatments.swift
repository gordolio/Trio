import CoreData
import Foundation
import Swinject

/// What `storeCarbs` throws. Its text is sent to the service, and the assistant reads it out.
struct AIRequestCarbsNotSavedError: LocalizedError {
    /// `nil` when the save reported no error but the entry isn't there.
    let underlying: Error?

    var errorDescription: String? { "Couldn't save the carbs" }
}

/// Trio's treatment side of a request: the wearer's limits, Trio's bolus calculator and safety checks, the carbs
/// storage and the pump.
final class BaseAIRequestTreatments: AIRequestTreatments {
    /// The `minPredBG` the watch's bolus recommendation uses without a determination from the last 30 minutes.
    private static let defaultMinPredBG: Decimal = 54

    private let settingsManager: SettingsManager
    private let carbsStorage: CarbsStorage
    private let bolusCalculationManager: BolusCalculationManager
    private let bolusSafetyValidator: BolusSafetyValidator
    private let apsManager: APSManager
    private let determinationStorage: DeterminationStorage
    /// Reads the latest glucose and the last carbs for the notification.
    private let snapshotBuilder: AIAssistantsSnapshotBuilder

    init(resolver: Resolver) {
        let settingsManager = resolver.resolve(SettingsManager.self)!
        let apsManager = resolver.resolve(APSManager.self)!
        self.settingsManager = settingsManager
        self.apsManager = apsManager
        carbsStorage = resolver.resolve(CarbsStorage.self)!
        bolusCalculationManager = resolver.resolve(BolusCalculationManager.self)!
        bolusSafetyValidator = resolver.resolve(BolusSafetyValidator.self)!
        determinationStorage = resolver.resolve(DeterminationStorage.self)!
        snapshotBuilder = AIAssistantsSnapshotBuilder(
            context: CoreDataStack.shared.newTaskContext(),
            loopInfo: { .init(lastLoopDate: apsManager.lastLoopDate, lastError: apsManager.lastError.value) },
            units: { settingsManager.settings.units }
        )
    }

    var limits: AIRequestLimits {
        let settings = settingsManager.settings
        return AIRequestLimits(maxCarbs: settings.maxCarbs, maxFat: settings.maxFat, maxProtein: settings.maxProtein)
    }

    /// Trio's bolus calculator's dose for the carbs, as the watch's bolus recommendation gets it, made deliverable
    /// exactly as shown.
    func dose(forCarbs carbs: Decimal) async -> Decimal {
        let minPredBG = await minPredBG()
        let result = await bolusCalculationManager.handleBolusCalculation(
            carbs: carbs,
            useFattyMealCorrection: false,
            useSuperBolus: false,
            lastLoopDate: apsManager.lastLoopDate,
            minPredBG: minPredBG,
            simulatedCOB: nil,
            isBackdated: false
        )
        return Self.deliverableDose(result.insulinCalculated, increment: settingsManager.preferences.bolusIncrement)
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

    func display(for request: AIMealRequest, units: Decimal) async -> AIRequestDisplay {
        let now = Date()
        var glucose: StatusSnapshot.LatestGlucose?
        var displayUnits = settingsManager.settings.units.rawValue
        var lastCarbs: (grams: Decimal, at: Date)?
        do {
            let snapshot = try await snapshotBuilder.build(now: now)
            glucose = snapshot.glucose.latest
            displayUnits = snapshot.units
            lastCarbs = Self.lastCarbs(in: snapshot.recentTreatments, now: now)
        } catch {
            debug(.service, "AI requests: couldn't read glucose and carbs for the notification: \(error)")
        }
        return AIRequestDisplay(
            title: AIRequestDisplayText.title(source: request.source, description: request.description),
            body: AIRequestDisplayText.body(
                carbs: request.carbs,
                fat: request.fat,
                protein: request.protein,
                units: units,
                glucose: glucose,
                displayUnits: displayUnits,
                lastCarbs: lastCarbs,
                now: now
            )
        )
    }

    func checkBolus(_ units: Decimal) async -> String? {
        do {
            switch try await bolusSafetyValidator.validate(bolusAmount: units) {
            case .allowed:
                return nil
            case let .rejected(rejection):
                return Self.reason(for: rejection)
            }
        } catch {
            debug(.service, "AI requests: the bolus safety check failed: \(error)")
            return error.localizedDescription
        }
    }

    /// Stores the meal as Trio's remote meal command does, eaten now, with the description in the note, then checks
    /// the meal entry was saved: `CarbsStorage` doesn't report a failed save.
    func storeCarbs(for request: AIMealRequest) async throws {
        let id = UUID()
        let entry = CarbsEntry(
            id: id.uuidString, createdAt: Date(), actualDate: nil,
            carbs: request.carbs, fat: request.fat, protein: request.protein,
            note: "AI: \(request.description)", enteredBy: CarbsEntry.local, isFPU: false,
            fpuID: request.fat > 0 || request.protein > 0 ? UUID().uuidString : nil
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

    /// The last determination's `minPredBG`, read as the watch's bolus recommendation reads it.
    private func minPredBG() async -> Decimal {
        do {
            let context = CoreDataStack.shared.newTaskContext()
            context.name = "AIRequestTreatments.minPredBG"
            let ids = try await determinationStorage.fetchLastDeterminationObjectID(
                predicate: NSPredicate.predicateFor30MinAgoForDetermination
            )
            let minPredBG = try await context.perform { [context] in
                try ids.first.flatMap { try context.existingObject(with: $0) as? OrefDetermination }?.minPredBGFromReason
            }
            return minPredBG ?? Self.defaultMinPredBG
        } catch {
            debug(.service, "AI requests: couldn't read minPredBG, using \(Self.defaultMinPredBG): \(error)")
            return Self.defaultMinPredBG
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

    /// The newest carbs entry that isn't in the future and has carbs.
    private static func lastCarbs(in treatments: [StatusSnapshot.Treatment], now: Date) -> (grams: Decimal, at: Date)? {
        for treatment in treatments where treatment.type == .carbs && treatment.date <= now {
            // Through the text, which gives 12.3 rather than 12.300000000000001.
            if let carbs = treatment.carbs, carbs > 0, let grams = Decimal(string: String(carbs)) {
                return (grams, treatment.date)
            }
        }
        return nil
    }

    private static func reason(for rejection: BolusSafetyRejection) -> String {
        switch rejection {
        case let .exceedsMaxBolus(maxBolus):
            return "Over your max bolus (\(maxBolus) U)"
        case .exceedsMaxIOB:
            return "Over your max IOB"
        case .iobUnavailable:
            return "Insulin on board isn't known yet"
        case .recentBolusWithinWindow:
            return "A bolus was given in the last few minutes"
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
