import Foundation

/// A meal an AI assistant asks Trio to log, with Trio's dose for it.
struct AIMealRequest: Codable, Equatable {
    let id: String
    /// Who asked, for example "ChatGPT".
    let source: String
    let description: String
    let carbs: Decimal
    let fat: Decimal
    let protein: Decimal
    let createdAt: Date
    let expiresAt: Date
}

/// Where a request came from, and so where its states are reported.
enum AIRequestChannel: String, Codable {
    case service
    /// The debug request, made on the phone.
    case local
}

enum AIRequestAskedOn: String, Codable {
    case watch
    case phone
}

enum AIRequestDeclinedOn: String, Codable {
    case watch
    case phone
    /// The wearer swiped the watch notification away.
    case dismissed
}

/// The notification text the wearer sees for a request.
struct AIRequestDisplay: Codable, Equatable {
    let title: String
    let body: String
}

/// The wearer's max carbs, fat and protein, in grams.
struct AIRequestLimits: Equatable {
    let maxCarbs: Decimal
    let maxFat: Decimal
    let maxProtein: Decimal
}

/// What Trio reports about a request: the contract's state report.
enum AIRequestReport: Codable, Equatable {
    case pending(
        askedOn: AIRequestAskedOn,
        approvalStyle: AIRequestApprovalStyle,
        answerRoute: AIRequestAnswerRoute,
        shown: AIRequestShown,
        display: AIRequestDisplay
    )
    /// The pump accepted the bolus command.
    case delivering(shown: AIRequestShown)
    /// The carbs were logged, and Trio's dose was 0 U.
    case logged(shown: AIRequestShown)
    case declined(on: AIRequestDeclinedOn)
    case expired
    case withdrawn
    case replaced
    /// A check failed and nothing was stored, or the pump failed after the carbs were logged.
    case failed(reason: String, carbsLogged: Bool)

    var state: AIRequestState {
        switch self {
        case .pending:
            return .pending
        case .delivering:
            return .delivering
        case .logged:
            return .logged
        case .declined:
            return .declined
        case .expired:
            return .expired
        case .withdrawn:
            return .withdrawn
        case .replaced:
            return .replaced
        case .failed:
            return .failed
        }
    }
}

/// Sends a request's states to where the request came from.
protocol AIRequestReporter: AnyObject {
    func report(_ report: AIRequestReport, for id: String) async
}

/// Trio's treatment side of a request: the wearer's limits, the dose, and logging carbs and boluses.
protocol AIRequestTreatments: AnyObject {
    var limits: AIRequestLimits { get }
    func dose(forCarbs carbs: Decimal) async -> Decimal
    func display(for request: AIMealRequest, units: Decimal) async -> AIRequestDisplay
    /// Returns `nil` if the bolus is allowed, otherwise the reason it isn't.
    func checkBolus(_ units: Decimal) async -> String?
    func storeCarbs(for request: AIMealRequest) async throws
    /// Returns `nil` if the pump accepted the bolus, otherwise the reason it didn't.
    func enactBolus(_ units: Decimal) async -> String?
}

/// Shows requests on the Apple Watch over WatchConnectivity.
protocol AIRequestWatchDelivery: AnyObject {
    var isWatchAvailable: Bool { get }
    func deliver(_ prompt: AIRequestPrompt)
    func withdraw(id: String)
}

/// The iPhone's backup notification, which asks for Face ID before approving.
protocol AIRequestPhoneBackupScheduling: AnyObject {
    func schedule(_ prompt: AIRequestPrompt, after delay: TimeInterval)
    func cancel(id: String)
}

/// The request waiting for the wearer's answer.
struct PendingAIRequest: Codable, Equatable {
    let request: AIMealRequest
    let channel: AIRequestChannel
    let prompt: AIRequestPrompt
    let askedOn: AIRequestAskedOn
    /// Trio's dose, as computed when the request arrived.
    let units: Decimal
}
