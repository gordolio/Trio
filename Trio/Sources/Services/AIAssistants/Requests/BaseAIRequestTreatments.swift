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

    /// The glucose and `minPredBG`, in mg/dL, under which Trio's bolus calculator gives 0 U: `BolusCalculationManager.swift:452`.
    /// Copied here to say why a dose is 0 U. They are for display only: the dose comes from the calculator.
    static let lowGlucoseMgdl: Decimal = 54
    /// The loop run's age over which Trio's bolus calculator gives 0 U: `BolusCalculationManager.swift:452`. For display only.
    static let staleLoopAge: TimeInterval = 15 * 60

    /// Carbs entered more recently than this are shown, so a meal that's already logged stands out.
    private static let recentCarbsWindow: TimeInterval = 15 * 60
    /// A bolus given more recently than this is shown, so the wearer sees insulin that's already on its way.
    private static let recentBolusWindow: TimeInterval = 30 * 60

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
        return AIRequestLimits(
            maxCarbs: settings.maxCarbs,
            maxFat: settings.maxFat,
            maxProtein: settings.maxProtein,
            maxBolus: settingsManager.pumpSettings.maxBolus
        )
    }

    /// Trio's bolus calculator's dose for the carbs, as the watch's bolus recommendation gets it, made deliverable
    /// exactly as shown, and the loop run the calculator read insulin on board from.
    func dose(forCarbs carbs: Decimal) async -> AIRequestDose {
        // Read before the calculator reads its own: if a loop run lands in between, `iobAsOf` is the earlier one, so
        // the recent-insulin check counts more insulin, never less.
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
            units: Self.deliverableDose(result.insulinCalculated, increment: settingsManager.preferences.bolusIncrement),
            iobAsOf: determination.deliverAt
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

    /// Trio's own facts for the approval: the latest glucose, recent carbs and insulin, and, for a 0 U dose, why. A fact
    /// that can't be read is left out.
    func context(for _: AIMealRequest, units: Decimal) async -> AIRequestContext {
        let now = Date()
        var glucose: StatusSnapshot.LatestGlucose?
        var treatments: [StatusSnapshot.Treatment] = []
        var displayUnits = settingsManager.settings.units.rawValue
        do {
            let snapshot = try await snapshotBuilder.build(now: now)
            glucose = snapshot.glucose.latest
            treatments = snapshot.recentTreatments
            displayUnits = snapshot.units
        } catch {
            debug(.service, "AI requests: couldn't read glucose and treatments for the approval: \(error)")
        }
        // Only a 0 U dose needs the forecast and the insulin on board.
        let determination = units > 0 ? nil : await latestDetermination()
        return Self.context(
            glucose: glucose,
            recentTreatments: treatments,
            lastLoopDate: apsManager.lastLoopDate,
            minPredBG: determination?.minPredBG ?? Self.defaultMinPredBG,
            iob: determination?.iob,
            maxIOB: settingsManager.preferences.maxIOB,
            displayUnits: displayUnits,
            units: units,
            now: now
        )
    }

    /// The context from what Trio read. Every value is inside trio-rc's limits (see `AIRequestContext.Limit`): a fact
    /// dated in the future or more than a day ago is left out, and so is one whose text won't fit, because trio-rc
    /// refuses the whole pending report over one such value.
    /// - Parameters:
    ///   - glucose: The newest glucose reading, however old.
    ///   - recentTreatments: Carbs entries and boluses, in any order.
    ///   - lastLoopDate: When the loop last ran, `.distantPast` if it never did.
    ///   - minPredBG: The forecast low the dose was worked out with, in mg/dL.
    ///   - iob: The insulin on board the dose was worked out with, from the same determination as `minPredBG`, or `nil`
    ///     when there was none.
    ///   - maxIOB: The wearer's max insulin on board.
    ///   - displayUnits: A `GlucoseUnits` raw value.
    ///   - units: Trio's dose. The 0 U reason is set only when it is 0, and only when Trio knows it is true.
    static func context(
        glucose: StatusSnapshot.LatestGlucose?,
        recentTreatments: [StatusSnapshot.Treatment],
        lastLoopDate: Date,
        minPredBG: Decimal,
        iob: Decimal?,
        maxIOB: Decimal,
        displayUnits: String,
        units: Decimal,
        now: Date
    ) -> AIRequestContext {
        var result = AIRequestContext()

        // A reading from the future is still the latest one, so it is shown, without an age. One over a day old is
        // too old to show as current.
        if let glucose, now.timeIntervalSince(glucose.date) <= TimeInterval(AIRequestContext.Limit.minutes * 60) {
            result.glucose = AIRequestContext.fitted(
                AIRequestDisplayText.reading(glucose, displayUnits: displayUnits),
                toUTF16Units: AIRequestContext.Limit.glucose
            )
            result.glucoseAgeMinutes = AIRequestContext.minutes(from: glucose.date, to: now)
        }

        result.recentCarbs = recent(
            recentTreatments.filter { $0.type == .carbs },
            within: recentCarbsWindow,
            now: now
        ) { treatment in
            // Through the text, which gives 12.3 rather than 12.300000000000001.
            guard let carbs = treatment.carbs, carbs > 0, let grams = Decimal(string: String(carbs)) else { return nil }
            let wholeHundredths = rounded(grams, scale: 2, roundingMode: .down)
            return wholeHundredths > 0 ? AIRequestDisplayText.amount(wholeHundredths) : nil
        }
        // An automatic microbolus isn't one the wearer asked for, and there can be many.
        result.recentBolus = recent(
            recentTreatments.filter { $0.type == .bolus && $0.isSMB != true },
            within: recentBolusWindow,
            now: now
        ) { treatment in
            guard let given = treatment.units, given > 0, let units = Decimal(string: String(given)),
                  rounded(units, scale: 2, roundingMode: .plain) > 0
            else { return nil }
            return twoDecimals(units)
        }

        if units <= 0 {
            result.noDoseReason = noDoseReason(
                glucose: glucose,
                minPredBG: minPredBG,
                lastLoopDate: lastLoopDate,
                iob: iob,
                maxIOB: maxIOB,
                displayUnits: displayUnits,
                now: now
            ).flatMap { AIRequestContext.fitted($0, toUTF16Units: AIRequestContext.Limit.noDoseReason) }
        }
        return result
    }

    /// The newest of `treatments` that isn't dated in the future, is under `window` old and has an amount from
    /// `amount`. Left out when the amount won't fit trio-rc's limit: a cut number would read as a different one.
    private static func recent(
        _ treatments: [StatusSnapshot.Treatment],
        within window: TimeInterval,
        now: Date,
        amount: (StatusSnapshot.Treatment) -> String?
    ) -> AIRequestContext.Recent? {
        let candidates = treatments.compactMap { treatment -> (date: Date, amount: String)? in
            guard treatment.date <= now, now.timeIntervalSince(treatment.date) < window, let amount = amount(treatment)
            else { return nil }
            return (treatment.date, amount)
        }
        guard let newest = candidates.max(by: { $0.date < $1.date }),
              newest.amount.utf16.count <= AIRequestContext.Limit.amount,
              let minutes = AIRequestContext.minutes(from: newest.date, to: now)
        else { return nil }
        return AIRequestContext.Recent(amount: newest.amount, minutesAgo: minutes)
    }

    /// Why Trio's dose is 0 U, but only a reason Trio knows is true, in this order: low glucose, a forecast low, a loop
    /// that hasn't run (the bolus calculator's own limits), no glucose reading, and insulin on board at its max. The
    /// calculator also gives 0 U when the dose it works out is 0 or under the pump's increment, which has no reason
    /// worth saying, so then there is `nil`.
    private static func noDoseReason(
        glucose: StatusSnapshot.LatestGlucose?,
        minPredBG: Decimal,
        lastLoopDate: Date,
        iob: Decimal?,
        maxIOB: Decimal,
        displayUnits: String,
        now: Date
    ) -> String? {
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
            // A loop that never ran has no date, so its age is as long as the service takes: a day.
            let minutes = String(Int(min(loopAge, TimeInterval(AIRequestContext.Limit.minutes * 60)) / 60))
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

    /// Trio's bolus safety checks, with the recent-insulin window starting at `since`, as Trio Remote Control starts
    /// it at its command's time.
    func checkBolus(_ units: Decimal, since: Date) async -> String? {
        do {
            switch try await bolusSafetyValidator.validate(bolusAmount: units, lookbackStart: since) {
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

    /// Whether a meal entry is dated after `date` and not in the future, as Trio Remote Control checks for carbs logged
    /// since its command. Fat and protein equivalents are dated ahead, so they're left out. If the store can't be
    /// read, it answers `true`, so the approval is refused rather than given unchecked.
    func carbsLogged(after date: Date) async -> Bool {
        let now = Date()
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "AIRequestTreatments.carbsLogged"
        do {
            return try await context.perform { [context] in
                let request = CarbEntryStored.fetchRequest()
                request.predicate = NSPredicate(
                    format: "date > %@ AND date <= %@ AND isFPU == NO",
                    date as NSDate,
                    now as NSDate
                )
                request.fetchLimit = 1
                return try context.count(for: request) > 0
            }
        } catch {
            debug(.service, "AI requests: couldn't check for carbs logged since the request arrived: \(error)")
            return true
        }
    }

    /// Stores the meal as Trio's remote meal command does, eaten now, with the assistant and the description in the
    /// note, then checks the meal entry was saved: `CarbsStorage` doesn't report a failed save. `carbs` replaces the
    /// request's own carbs when set.
    func storeCarbs(for request: AIMealRequest, carbs: Decimal?) async throws {
        let id = UUID()
        let entry = CarbsEntry(
            id: id.uuidString, createdAt: Date(), actualDate: nil,
            carbs: carbs ?? request.carbs, fat: request.fat, protein: request.protein,
            note: request.note, enteredBy: CarbsEntry.local, isFPU: false,
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

    /// The newest determination from the last 30 minutes, the one Trio's bolus calculator reads: its `minPredBG`, read
    /// as the watch's bolus recommendation reads it, its `deliverAt`, which is `nil` when there's none, and its insulin
    /// on board, which is `nil` when there's none.
    private func latestDetermination() async -> (minPredBG: Decimal, deliverAt: Date?, iob: Decimal?) {
        do {
            let context = CoreDataStack.shared.newTaskContext()
            context.name = "AIRequestTreatments.latestDetermination"
            let ids = try await determinationStorage.fetchLastDeterminationObjectID(
                predicate: NSPredicate.predicateFor30MinAgoForDetermination
            )
            let latest = try await context.perform { [context] () -> (minPredBG: Decimal?, deliverAt: Date?, iob: Decimal)? in
                guard let id = ids.first, let determination = try context.existingObject(with: id) as? OrefDetermination
                else { return nil }
                // As the calculator reads it: no insulin on board is 0.
                return (determination.minPredBGFromReason, determination.deliverAt, (determination.iob ?? 0) as Decimal)
            }
            return (latest?.minPredBG ?? Self.defaultMinPredBG, latest?.deliverAt, latest?.iob)
        } catch {
            debug(.service, "AI requests: couldn't read the last determination, using \(Self.defaultMinPredBG): \(error)")
            return (Self.defaultMinPredBG, nil, nil)
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

    /// What the service is told when Trio's bolus safety checks reject the dose.
    static func reason(for rejection: BolusSafetyRejection) -> String {
        switch rejection {
        case let .exceedsMaxBolus(maxBolus):
            return "Over your max bolus (\(maxBolus) U)"
        case .exceedsMaxIOB:
            return "Over your max IOB"
        case .iobUnavailable:
            return "Insulin on board isn't known yet"
        case let .recentBolusWithinWindow(totalRecent):
            return "Trio gave \(twoDecimals(totalRecent)) U after working out this dose. Ask again in a few minutes"
        }
    }

    /// The units rounded to two decimals, with a `.`, like the doses shown.
    private static func twoDecimals(_ units: Decimal) -> String {
        var units = units
        var rounded = Decimal()
        NSDecimalRound(&rounded, &units, 2, .plain)
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), NSDecimalNumber(decimal: rounded).doubleValue)
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
