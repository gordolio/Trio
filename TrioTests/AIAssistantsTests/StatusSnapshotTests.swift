import Foundation
import Testing

@testable import Trio

extension StatusSnapshot {
    /// Fills every optional, so every contract key is present. Whole seconds, so ISO 8601 dates round-trip.
    static func fixture() -> StatusSnapshot {
        let t = Date(timeIntervalSince1970: 1_792_000_000)
        return StatusSnapshot(
            generatedAt: t,
            units: "mg/dL",
            glucose: Glucose(
                latest: LatestGlucose(date: t - 60, mgdl: 112, direction: "Flat", deltaMgdl: 1),
                recent: [GlucoseReading(date: t - 360, mgdl: 111), GlucoseReading(date: t - 60, mgdl: 112)]
            ),
            iob: 1.25,
            cob: 20,
            loop: Loop(lastRunAt: t - 30, succeeded: false, error: "Pump unreachable"),
            prediction: Prediction(eventualMgdl: 105, insulinReq: 0.5),
            override: Override(name: "Exercise", startedAt: t - 600, endsAt: t + 3000, percentage: 80),
            tempTarget: TempTarget(name: "Activity", targetMgdl: 140, startedAt: t - 600, endsAt: t + 3000),
            recentTreatments: [
                .carbs(date: t - 1800, carbs: 45, fat: 10, protein: 15, note: "pizza"),
                .bolus(date: t - 1790, units: 3.5, isSMB: false, isExternal: false)
            ]
        )
    }

    static func testDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

@Suite("AI Assistants status snapshot") struct StatusSnapshotTests {
    func json(_ snapshot: StatusSnapshot) throws -> [String: Any] {
        try #require(StatusSnapshot.makeEncoder().encode(snapshot).jsonObject)
    }

    @Test("Encodes the contract's keys and ISO 8601 dates") func encodesContractKeysAndISODates() throws {
        let json = try json(.fixture())
        #expect(json["schemaVersion"] as? Int == 1)
        #expect((json["glucose"] as? [String: Any])?["latest"] != nil)
        #expect((json["generatedAt"] as? String)?.hasSuffix("Z") == true)
        #expect(
            Set(json.keys) == [
                "schemaVersion",
                "generatedAt",
                "units",
                "glucose",
                "iob",
                "cob",
                "loop",
                "prediction",
                "override",
                "tempTarget",
                "recentTreatments"
            ]
        )
    }

    @Test("Decoding what it encodes gives the same snapshot") func roundTrips() throws {
        let data = try StatusSnapshot.makeEncoder().encode(StatusSnapshot.fixture())
        #expect(try StatusSnapshot.testDecoder().decode(StatusSnapshot.self, from: data) == .fixture())
    }

    @Test("Nil fields are left out, but the arrays are always sent") func leavesOutNilFieldsButKeepsArrays() throws {
        let snapshot = StatusSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_792_000_000),
            units: "mmol/L",
            glucose: .init(latest: nil, recent: []),
            iob: nil,
            cob: nil,
            loop: .init(lastRunAt: nil, succeeded: nil, error: nil),
            prediction: nil,
            override: nil,
            tempTarget: nil,
            recentTreatments: []
        )
        let json = try json(snapshot)
        #expect(Set(json.keys) == ["schemaVersion", "generatedAt", "units", "glucose", "loop", "recentTreatments"])
        #expect((json["glucose"] as? [String: Any]).map { Set($0.keys) } == ["recent"])
        #expect((json["loop"] as? [String: Any])?.isEmpty == true)
        #expect((json["recentTreatments"] as? [Any])?.isEmpty == true)
    }

    @Test("Each treatment sends only its own kind's fields") func treatmentsSendOnlyTheirOwnFields() throws {
        let treatments = try #require(json(.fixture())["recentTreatments"] as? [[String: Any]])
        #expect(treatments.count == 2)
        #expect(treatments[0]["type"] as? String == "carbs")
        #expect(Set(treatments[0].keys) == ["type", "date", "carbs", "fat", "protein", "note"])
        #expect(treatments[1]["type"] as? String == "bolus")
        #expect(Set(treatments[1].keys) == ["type", "date", "units", "isSMB", "isExternal"])
    }
}
