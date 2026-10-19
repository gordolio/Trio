import Foundation

/// The status Trio uploads with `PUT /api/v1/status`: the contract's `StatusSnapshotV1`.
/// Glucose values are always mg/dL; `units` only says how to show them. A `nil` field is left
/// out, which the service reads as `null`.
struct StatusSnapshot: Codable, Equatable {
    var schemaVersion = 1
    let generatedAt: Date
    /// A `GlucoseUnits` raw value: "mg/dL" or "mmol/L".
    let units: String
    let glucose: Glucose
    let iob: Double?
    let cob: Int?
    let loop: Loop
    let prediction: Prediction?
    let override: Override?
    let tempTarget: TempTarget?
    /// The last 24 hours, newest first.
    let recentTreatments: [Treatment]

    struct Glucose: Codable, Equatable {
        let latest: LatestGlucose?
        /// The last 3 hours, oldest first.
        let recent: [GlucoseReading]
    }

    struct GlucoseReading: Codable, Equatable {
        let date: Date
        let mgdl: Int
    }

    struct LatestGlucose: Codable, Equatable {
        let date: Date
        let mgdl: Int
        /// A `BloodGlucose.Direction` raw value.
        let direction: String?
        /// The change from the previous reading.
        let deltaMgdl: Int?
    }

    struct Loop: Codable, Equatable {
        let lastRunAt: Date?
        let succeeded: Bool?
        let error: String?
    }

    struct Prediction: Codable, Equatable {
        let eventualMgdl: Int?
        let insulinReq: Double?
    }

    struct Override: Codable, Equatable {
        let name: String
        let startedAt: Date
        /// `nil` for an indefinite override.
        let endsAt: Date?
        /// The insulin percentage; 100 is normal.
        let percentage: Double
    }

    struct TempTarget: Codable, Equatable {
        let name: String
        let targetMgdl: Double
        let startedAt: Date
        let endsAt: Date
    }

    enum TreatmentType: String, Codable {
        case carbs
        case bolus
    }

    /// A carbs entry or a bolus. Only its own kind's fields are set.
    struct Treatment: Codable, Equatable {
        let type: TreatmentType
        let date: Date
        var carbs: Double?
        var fat: Double?
        var protein: Double?
        var note: String?
        var units: Double?
        var isSMB: Bool?
        var isExternal: Bool?

        static func carbs(date: Date, carbs: Double, fat: Double?, protein: Double?, note: String?) -> Treatment {
            Treatment(type: .carbs, date: date, carbs: carbs, fat: fat, protein: protein, note: note)
        }

        static func bolus(date: Date, units: Double, isSMB: Bool, isExternal: Bool) -> Treatment {
            Treatment(type: .bolus, date: date, units: units, isSMB: isSMB, isExternal: isExternal)
        }
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}
