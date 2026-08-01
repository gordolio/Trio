import Combine
import CoreData
import Foundation
import Swinject

extension CarbRatioCalibration {
    final class Provider: BaseProvider, CarbRatioCalibrationProvider {
        @Injected() var iobService: IOBService!
        @Injected() var determinationStorage: DeterminationStorage!
        @Injected() var carbsStorage: CarbsStorage!
        @Injected() var apsManager: APSManager!

        private let context = CoreDataStack.shared.newTaskContext()

        required init(resolver: Resolver) {
            super.init(resolver: resolver)
        }

        // MARK: - Glucose Data

        /// Simple struct to hold glucose reading data extracted from Core Data
        /// This is Sendable-safe since it only contains value types
        struct GlucoseReading: Sendable {
            let glucose: Int
            let direction: BloodGlucose.Direction?
        }

        /// Fetch recent glucose readings for preflight checks
        /// Returns extracted values (not Core Data objects) for thread safety
        func fetchRecentGlucose(minutes: Int = 45) async throws -> [GlucoseReading] {
            let cutoffDate = Date().addingTimeInterval(-Double(minutes) * 60)
            let predicate = NSPredicate(format: "date > %@", cutoffDate as NSDate)

            let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: GlucoseStored.self,
                onContext: context,
                predicate: predicate,
                key: "date",
                ascending: false,
                fetchLimit: 15 // ~75 minutes of data at 5-min intervals
            )

            return await context.perform {
                let glucoseObjects = (results as? [GlucoseStored]) ?? []
                return glucoseObjects.map { stored in
                    GlucoseReading(glucose: Int(stored.glucose), direction: stored.directionEnum)
                }
            }
        }

        /// Fetch all glucose readings in a date range for archival
        /// Returns `CalibrationGlucoseReading` values sorted ascending by date
        func fetchGlucoseForDateRange(from startDate: Date, to endDate: Date) async throws -> [CalibrationGlucoseReading] {
            let predicate = NSPredicate(format: "date >= %@ AND date <= %@", startDate as NSDate, endDate as NSDate)

            let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: GlucoseStored.self,
                onContext: context,
                predicate: predicate,
                key: "date",
                ascending: true
            )

            return await context.perform {
                let glucoseObjects = (results as? [GlucoseStored]) ?? []
                return glucoseObjects.map { stored in
                    CalibrationGlucoseReading(date: stored.date ?? Date(), glucose: Int(stored.glucose))
                }
            }
        }

        // MARK: - IOB and COB

        /// Get current IOB value
        func getCurrentIOB() -> Decimal {
            iobService.currentIOB ?? 0
        }

        /// Get the IOB prediction array (48 entries at 5-min intervals) from the most recent OpenAPS run
        func getIOBPredictions() -> [IOBEntry] {
            storage.retrieve(OpenAPS.Monitor.iob, as: [IOBEntry].self) ?? []
        }

        /// Get current COB from latest determination
        func getCurrentCOB() async throws -> Decimal {
            let determinationIDs = try await determinationStorage.fetchLastDeterminationObjectID(
                predicate: NSPredicate.predicateFor30MinAgoForDetermination
            )

            return await context.perform {
                guard let id = determinationIDs.first,
                      let determination = try? self.context.existingObject(with: id) as? OrefDetermination
                else {
                    return 0
                }
                return Decimal(determination.cob)
            }
        }

        // MARK: - Carb Ratio

        /// Get current carb ratio for the current time of day
        func getCurrentCarbRatio() async -> Decimal {
            guard let carbRatios = await storage.retrieveAsync(
                OpenAPS.Settings.carbRatios,
                as: CarbRatios.self
            ) else {
                return 10 // Default fallback
            }

            let now = Date()
            let calendar = Calendar.current
            let midnight = calendar.startOfDay(for: now)
            let minutesSinceMidnight = Int(now.timeIntervalSince(midnight) / 60)

            // Find the applicable ratio for current time
            var applicableRatio: Decimal = carbRatios.schedule.first?.ratio ?? 10

            for entry in carbRatios.schedule {
                if entry.offset <= minutesSinceMidnight {
                    applicableRatio = entry.ratio
                } else {
                    break
                }
            }

            return applicableRatio
        }

        /// Get all carb ratio schedule entries
        func getCarbRatioSchedule() async -> [CarbRatioEntry]? {
            let carbRatios = await storage.retrieveAsync(
                OpenAPS.Settings.carbRatios,
                as: CarbRatios.self
            )
            return carbRatios?.schedule
        }

        /// Safe bounds for carb ratio (g/U)
        private let minCarbRatio: Decimal = 1
        private let maxCarbRatio: Decimal = 50

        /// Clamp a carb ratio to safe bounds
        private func clampRatio(_ ratio: Decimal) -> Decimal {
            min(max(ratio, minCarbRatio), maxCarbRatio)
        }

        /// Update carb ratio for specific time slots
        func updateCarbRatio(newRatio: Decimal, forSlots slots: [Int]? = nil) async {
            guard let carbRatios = await storage.retrieveAsync(
                OpenAPS.Settings.carbRatios,
                as: CarbRatios.self
            ) else {
                return
            }

            // Validate the new ratio is within safe bounds
            let safeNewRatio = clampRatio(newRatio)

            var newSchedule: [CarbRatioEntry]

            if let slots = slots {
                // Update specific slots - create new entries with updated ratio
                newSchedule = carbRatios.schedule.enumerated().map { index, entry in
                    if slots.contains(index) {
                        return CarbRatioEntry(start: entry.start, offset: entry.offset, ratio: safeNewRatio)
                    }
                    return entry
                }
            } else {
                // Update all slots proportionally
                guard let currentRatio = carbRatios.schedule.first?.ratio, currentRatio > 0 else { return }
                let adjustmentFactor = safeNewRatio / currentRatio

                newSchedule = carbRatios.schedule.map { entry in
                    let adjusted = entry.ratio * adjustmentFactor
                    // Round to nearest 0.1 and clamp to safe bounds
                    let roundedRatio = clampRatio(rounded(adjusted, scale: 1, roundingMode: .plain))
                    return CarbRatioEntry(start: entry.start, offset: entry.offset, ratio: roundedRatio)
                }
            }

            let updatedCarbRatios = CarbRatios(units: carbRatios.units, schedule: newSchedule)
            storage.save(updatedCarbRatios, as: OpenAPS.Settings.carbRatios)
        }

        // MARK: - Carb Entry

        /// Store carbs for calibration test
        /// - Returns: true if carbs were stored successfully
        func storeCalibrationCarbs(carbs: Decimal, note: String) async -> Bool {
            let entry = CarbsEntry(
                id: UUID().uuidString,
                createdAt: Date(),
                actualDate: nil,
                carbs: carbs,
                fat: nil,
                protein: nil,
                note: note,
                enteredBy: "CalibrationMode",
                isFPU: false,
                fpuID: nil
            )
            do {
                try await carbsStorage.storeCarbs([entry], areFetchedFromRemote: false)
                return true
            } catch {
                debug(.service, "CalibrationMode: Failed to store carbs: \(error.localizedDescription)")
                return false
            }
        }

        // MARK: - Bolus

        /// Execute calibration test bolus
        func executeCalibrationBolus(amount: Decimal) async -> Bool {
            await withCheckedContinuation { continuation in
                Task {
                    await apsManager.enactBolus(amount: Double(truncating: amount as NSNumber), isSMB: false) { success, _ in
                        continuation.resume(returning: success)
                    }
                }
            }
        }
    }
}
