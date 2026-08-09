import Foundation

struct IobTotal: Codable {
    let iob: Decimal
    let activity: Decimal
    let basaliob: Decimal
    let bolusiob: Decimal
    let netbasalinsulin: Decimal
    let bolusinsulin: Decimal
    let time: Date
}

enum IobCalculation {
    struct IobCalculationResult {
        let activityContrib: Double
        let iobContrib: Double
    }

    /// logic to look up insulinPeakTime, taking into account `useCustomPeakTime`
    private static func lookupPeak(from profile: Profile) throws -> Double {
        switch (profile.curve, profile.useCustomPeakTime, profile.insulinPeakTime) {
        case (.rapidActing, true, let insulinPeakTime):
            let peakTime = Double(insulinPeakTime)
            return peakTime.clamp(lowerBound: 50, upperBound: 120)
        case (.rapidActing, false, _):
            return 75
        case (.ultraRapid, true, let insulinPeakTime):
            let peakTime = Double(insulinPeakTime)
            return peakTime.clamp(lowerBound: 35, upperBound: 100)
        case (.ultraRapid, false, _):
            return 55
        case (.bilinear, _, _):
            throw IobError.bilinearCurveNotSupported
        }
    }

    /// Runs through the IoB calculation for a treatment.
    ///
    /// **IMPORTANT** this calculation uses Doubles internally for performance
    static func iobCalc(
        treatment: ComputedPumpHistoryEvent,
        time: Date,
        dia: Decimal,
        profile: Profile
    ) throws -> IobCalculationResult? {
        guard let insulin = treatment.insulin.map({ Double($0) }) else {
            return nil
        }

        let bolusTime = treatment.timestamp
        let minsAgo = (time.timeIntervalSince(bolusTime) / 60.0).rounded()
        let peak = try lookupPeak(from: profile)
        let end = Double(dia) * 60

        guard minsAgo < end else {
            return IobCalculationResult(activityContrib: 0, iobContrib: 0)
        }

        // Calculate the constants exactly as in JavaScript
        let tau = peak * (1 - peak / end) / (1 - 2 * peak / end)
        let a = 2 * tau / end
        let S = 1 / (1 - a + (1 + a) * exp(-end / tau))

        let activityContrib = insulin * (S / pow(tau, 2)) * minsAgo * (1 - minsAgo / end) * exp(-minsAgo / tau)
        let iobContrib = insulin *
            (1 - S * (1 - a) * ((pow(minsAgo, 2) / (tau * end * (1 - a)) - minsAgo / tau - 1) * exp(-minsAgo / tau) + 1))

        guard activityContrib.isFinite, iobContrib.isFinite else {
            return IobCalculationResult(activityContrib: 0, iobContrib: 0)
        }

        return IobCalculationResult(activityContrib: activityContrib, iobContrib: iobContrib)
    }

    /// Round a Double using the same logic as Decimal.jsRounded(scale:):
    /// floor(value * 10^scale + 0.5) / 10^scale
    private static func jsRound(_ value: Double, scale: Int) -> Decimal {
        guard value.isFinite else { return 0 }
        let multiplier = pow(10.0, Double(scale))
        return Decimal((value * multiplier + 0.5).rounded(.down) / multiplier)
    }

    /// Exponential-curve constants; invariant across treatments and time points for a fixed profile.
    /// c0/c1/c2 store the identical left-associated subexpressions of `iobCalc`, so
    /// substituting them yields bit-identical IEEE-754 results.
    struct CurveConstants {
        let end: Double
        let tau: Double
        let c0: Double // S / pow(tau, 2)
        let c1: Double // S * (1 - a)
        let c2: Double // tau * end * (1 - a)
    }

    /// Only valid for exponential curves; `lookupPeak` cannot throw for them
    static func curveConstants(dia: Decimal, profile: Profile) throws -> CurveConstants {
        let peak = try lookupPeak(from: profile)
        let end = Double(dia) * 60
        let tau = peak * (1 - peak / end) / (1 - 2 * peak / end)
        let a = 2 * tau / end
        let S = 1 / (1 - a + (1 + a) * exp(-end / tau))
        return CurveConstants(end: end, tau: tau, c0: S / pow(tau, 2), c1: S * (1 - a), c2: tau * end * (1 - a))
    }

    /// Same math as `iobCalc` with the loop-invariant constants substituted
    private static func contributions(insulin: Double, minsAgo: Double, constants: CurveConstants) -> IobCalculationResult {
        guard minsAgo < constants.end else {
            return IobCalculationResult(activityContrib: 0, iobContrib: 0)
        }

        let decay = exp(-minsAgo / constants.tau)
        let activityContrib = insulin * constants.c0 * minsAgo * (1 - minsAgo / constants.end) * decay
        let iobContrib = insulin *
            (1 - constants.c1 * ((pow(minsAgo, 2) / constants.c2 - minsAgo / constants.tau - 1) * decay + 1))

        guard activityContrib.isFinite, iobContrib.isFinite else {
            return IobCalculationResult(activityContrib: 0, iobContrib: 0)
        }

        return IobCalculationResult(activityContrib: activityContrib, iobContrib: iobContrib)
    }

    /// Treatments preprocessed once for repeated `iobTotal` calls at different time points.
    /// Entries keep the original (sorted) order; nil-insulin events are dropped because
    /// they never contribute to any accumulator.
    struct PreparedIobInputs {
        fileprivate let entries: [(timestamp: Date, insulin: Double)]
        fileprivate let treatments: [ComputedPumpHistoryEvent]
        fileprivate let dia: Decimal
        fileprivate let diaSeconds: Double
        fileprivate let constants: CurveConstants?
    }

    /// `treatments` must be sorted ascending by timestamp (calcTempTreatments output is)
    static func prepare(treatments: [ComputedPumpHistoryEvent], profile: Profile) throws -> PreparedIobInputs {
        guard var dia = profile.dia else {
            throw IobError.diaNotSet
        }
        if dia < 5 {
            dia = 5
        }
        assert(
            zip(treatments, treatments.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp },
            "iobTotal treatments must be sorted ascending"
        )
        let constants = profile.curve == .bilinear ? nil : try curveConstants(dia: dia, profile: profile)
        let entries = treatments.compactMap { event in
            event.insulin.map { (timestamp: event.timestamp, insulin: Double($0)) }
        }
        return PreparedIobInputs(
            entries: entries,
            treatments: treatments,
            dia: dia,
            diaSeconds: Double(dia * 60 * 60),
            constants: constants
        )
    }

    /// First index whose timestamp makes `predicate` false — entries are sorted, so
    /// this is a binary-searched partition point
    private static func partitionPoint(
        of entries: [(timestamp: Date, insulin: Double)],
        while predicate: (Date) -> Bool
    ) -> Int {
        var low = 0
        var high = entries.count
        while low < high {
            let mid = low + (high - low) / 2
            if predicate(entries[mid].timestamp) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    static func iobTotal(treatments: [ComputedPumpHistoryEvent], profile: Profile, time now: Date) throws -> IobTotal {
        try iobTotal(prepared: prepare(treatments: treatments, profile: profile), profile: profile, time: now)
    }

    static func iobTotal(prepared: PreparedIobInputs, profile: Profile, time now: Date) throws -> IobTotal {
        // bilinear keeps the per-treatment path so its throw behavior is unchanged
        guard let constants = prepared.constants else {
            return try bilinearIobTotal(treatments: prepared.treatments, profile: profile, dia: prepared.dia, now: now)
        }

        var iob = 0.0
        var basaliob = 0.0
        var bolusiob = 0.0
        var netbasalinsulin = 0.0
        var bolusinsulin = 0.0
        var activity = 0.0

        let diaAgo = now - prepared.diaSeconds
        // window (diaAgo, now] over the sorted entries selects the same elements,
        // in the same order, as the previous full-array filter
        let start = partitionPoint(of: prepared.entries, while: { $0 <= diaAgo })
        let end = partitionPoint(of: prepared.entries, while: { $0 <= now })

        for entry in prepared.entries[start ..< end] {
            let minsAgo = (now.timeIntervalSince(entry.timestamp) / 60.0).rounded()
            let tIOB = contributions(insulin: entry.insulin, minsAgo: minsAgo, constants: constants)
            iob += tIOB.iobContrib
            activity += tIOB.activityContrib
            if tIOB.iobContrib != 0 {
                if entry.insulin < 0.1 {
                    // bolus to represent temp basal, which can only be 0.05 or -0.05
                    basaliob += tIOB.iobContrib
                    netbasalinsulin += entry.insulin
                } else {
                    bolusiob += tIOB.iobContrib
                    bolusinsulin += entry.insulin
                }
            }
        }

        return IobTotal(
            iob: jsRound(iob, scale: 3),
            activity: jsRound(activity, scale: 4),
            basaliob: jsRound(basaliob, scale: 3),
            bolusiob: jsRound(bolusiob, scale: 3),
            netbasalinsulin: jsRound(netbasalinsulin, scale: 3),
            bolusinsulin: jsRound(bolusinsulin, scale: 3),
            time: now
        )
    }

    private static func bilinearIobTotal(
        treatments: [ComputedPumpHistoryEvent],
        profile: Profile,
        dia: Decimal,
        now: Date
    ) throws -> IobTotal {
        var iob = 0.0
        var basaliob = 0.0
        var bolusiob = 0.0
        var netbasalinsulin = 0.0
        var bolusinsulin = 0.0
        var activity = 0.0

        let diaAgo = now - Double(dia * 60 * 60) // convert to seconds
        let treatments = treatments.filter({ $0.timestamp <= now && $0.timestamp > diaAgo })
        for treatment in treatments {
            guard let tIOB = try iobCalc(treatment: treatment, time: now, dia: dia, profile: profile),
                  let insulin = treatment.insulin.map({ Double($0) })
            else {
                continue
            }
            iob += tIOB.iobContrib
            activity += tIOB.activityContrib
            if tIOB.iobContrib != 0 {
                if insulin < 0.1 {
                    // bolus to represent temp basal, which can only be 0.05 or -0.05
                    basaliob += tIOB.iobContrib
                    netbasalinsulin += insulin
                } else {
                    bolusiob += tIOB.iobContrib
                    bolusinsulin += insulin
                }
            }
        }

        return IobTotal(
            iob: jsRound(iob, scale: 3),
            activity: jsRound(activity, scale: 4),
            basaliob: jsRound(basaliob, scale: 3),
            bolusiob: jsRound(bolusiob, scale: 3),
            netbasalinsulin: jsRound(netbasalinsulin, scale: 3),
            bolusinsulin: jsRound(bolusinsulin, scale: 3),
            time: now
        )
    }
}
