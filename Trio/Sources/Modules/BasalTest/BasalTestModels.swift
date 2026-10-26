import Foundation

struct BasalTestReading: JSON, Equatable, Identifiable {
    var id: Date { date }
    let date: Date
    /// mg/dL
    let glucose: Int
}

enum BasalTestPhase: String, JSON, Equatable {
    case running
    case finished
}

enum BasalTestEndReason: String, JSON, Equatable {
    /// The planned time was up.
    case completed
    /// The user ended it before the planned time.
    case endedEarly
    /// Glucose dropped below the stop level, so normal dosing came back.
    case low
    /// Carbs or a bolus were logged during the fast.
    case interrupted
}

enum BasalTestOutcome: String, JSON, Equatable {
    case steady
    case rising
    case falling
    /// Ended too soon to say.
    case inconclusive
    /// Something happened during the fast that makes the result unusable.
    case invalid

    /// Whether the result says anything about the basal rates.
    var isConclusive: Bool {
        switch self {
        case .falling,
             .rising,
             .steady: return true
        case .inconclusive,
             .invalid: return false
        }
    }
}

/// The wizard's persisted state. Everything about a result can be rebuilt from the window the
/// test covered, so a test that finished while the app was closed still reports properly.
struct BasalTestState: JSON, Equatable {
    var id = UUID()
    var phase: BasalTestPhase = .running
    var startedAt: Date
    /// Seconds
    var plannedDuration: TimeInterval
    /// mg/dL
    var startGlucose: Int
    var startIOB: Decimal
    var previousMode: DosingMode
    /// For example "Overnight".
    var timeBlock: String

    // Filled in when the test finishes.
    var endedAt: Date?
    var endReason: BasalTestEndReason?
    var endGlucose: Int?
    var readings: [BasalTestReading] = []
    var outcome: BasalTestOutcome?
    var interference: String?

    var plannedEnd: Date { startedAt.addingTimeInterval(plannedDuration) }
}

/// Turns what happened during a fast into a result. Pure, so it can be tested without a loop.
enum BasalTestEvaluator {
    struct Evaluation: Equatable {
        let outcome: BasalTestOutcome
        /// End minus start, in mg/dL.
        let netChange: Int
        let direction: SettingsTestDirection?
    }

    static func evaluate(
        startGlucose: Int,
        endGlucose: Int,
        elapsed: TimeInterval,
        planned: TimeInterval,
        reason: BasalTestEndReason,
        interference: String?,
        tolerance: Int = BasalTest.Config.steadyTolerance
    ) -> Evaluation {
        let net = endGlucose - startGlucose

        if interference != nil || reason == .interrupted {
            return Evaluation(outcome: .invalid, netChange: net, direction: nil)
        }

        // A low ends the test, and a fall into one points the same way as any other fall.
        if reason == .low {
            return Evaluation(outcome: .falling, netChange: net, direction: .decrease)
        }

        // Too little time to trust a small change, but a big one is already clear.
        let enoughTime = planned > 0 && elapsed >= planned * 0.75
        let clearDrift = abs(net) >= tolerance * 2
        guard enoughTime || clearDrift else {
            return Evaluation(outcome: .inconclusive, netChange: net, direction: nil)
        }

        if net > tolerance {
            return Evaluation(outcome: .rising, netChange: net, direction: .increase)
        }
        if net < -tolerance {
            return Evaluation(outcome: .falling, netChange: net, direction: .decrease)
        }
        return Evaluation(outcome: .steady, netChange: net, direction: .keep)
    }

    /// Names the part of the day a test started in.
    static func timeBlock(for date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 6 ..< 11: return String(localized: "Morning")
        case 11 ..< 17: return String(localized: "Afternoon")
        case 17 ..< 22: return String(localized: "Evening")
        default: return String(localized: "Overnight")
        }
    }

    /// The end glucose smooths over the last few readings so one noisy value doesn't decide it.
    static func endGlucose(from readings: [BasalTestReading], fallback: Int) -> Int {
        let tail = readings.sorted { $0.date < $1.date }.suffix(3)
        guard !tail.isEmpty else { return fallback }
        return tail.map(\.glucose).reduce(0, +) / tail.count
    }
}
