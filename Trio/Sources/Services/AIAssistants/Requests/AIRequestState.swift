import Foundation

/// Where a request from an AI assistant stands. A request ends in one of the final states and never
/// leaves it.
enum AIRequestState: String, Codable, CaseIterable {
    case created
    case pending
    case withdrawing
    /// The pump accepted the bolus command. Nothing waits for the delivery to finish.
    case delivering
    case logged
    case declined
    case expired
    case withdrawn
    case replaced
    case failed

    var isFinal: Bool {
        switch self {
        case .created,
             .pending,
             .withdrawing:
            return false
        case .declined,
             .delivering,
             .expired,
             .failed,
             .logged,
             .replaced,
             .withdrawn:
            return true
        }
    }
}
