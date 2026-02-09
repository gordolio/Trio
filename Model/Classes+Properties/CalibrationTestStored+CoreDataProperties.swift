import CoreData
import Foundation

public extension CalibrationTestStored {
    @nonobjc class func fetchRequest() -> NSFetchRequest<CalibrationTestStored> {
        NSFetchRequest<CalibrationTestStored>(entityName: "CalibrationTestStored")
    }

    @NSManaged var id: UUID?
    @NSManaged var date: Date?
    @NSManaged var preflightStartDate: Date?
    @NSManaged var prepStartDate: Date?
    @NSManaged var testStartDate: Date?
    @NSManaged var observationEndDate: Date?
    @NSManaged var tabletBrand: String?
    @NSManaged var tabletCount: Int16
    @NSManaged var totalCarbs: NSDecimalNumber?
    @NSManaged var carbRatioAtTestTime: NSDecimalNumber?
    @NSManaged var bolusAmount: NSDecimalNumber?
    @NSManaged var startingGlucose: Int16
    @NSManaged var startingIOB: NSDecimalNumber?
    @NSManaged var endingGlucose: Int16
    @NSManaged var resultInterpretation: String?
    @NSManaged var suggestedNewRatio: NSDecimalNumber?
    @NSManaged var ratioWasApplied: Bool
    @NSManaged var glucoseReadingsJSON: Data?
}

extension CalibrationTestStored: Identifiable {}

// MARK: - Glucose Readings Convenience

extension CalibrationTestStored {
    /// Decode the stored JSON blob into an array of `CalibrationGlucoseReading`.
    var glucoseReadings: [CalibrationGlucoseReading] {
        guard let data = glucoseReadingsJSON else { return [] }
        return (try? JSONCoding.decoder.decode([CalibrationGlucoseReading].self, from: data)) ?? []
    }

    /// Encode an array of `CalibrationGlucoseReading` into the JSON blob for storage.
    func setGlucoseReadings(_ readings: [CalibrationGlucoseReading]) {
        glucoseReadingsJSON = try? JSONCoding.encoder.encode(readings)
    }
}
