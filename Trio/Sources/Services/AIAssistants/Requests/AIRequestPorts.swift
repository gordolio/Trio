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

extension AIMealRequest {
    /// The note its carbs entry is logged with: who asked, and the meal.
    var note: String {
        String(
            localized: "AI: \(source) \u{2013} \(description)",
            comment: "Note of a carbs entry an AI assistant asked for: the assistant's name, an en dash, and the meal"
        )
    }
}

/// Where a request came from, and so where its states are reported. The service is the only one; the pending request
/// and the carry-out marker keep their channel on disk, so it stays an enum.
enum AIRequestChannel: String, Codable {
    case service
}

enum AIRequestAskedOn: String, Codable {
    case watch
    case phone
}

/// The device a request was carried out on.
enum AIRequestAnswerSide: String, Codable {
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

/// The wearer's max carbs, fat and protein, in grams, and max bolus, in units.
struct AIRequestLimits: Equatable {
    let maxCarbs: Decimal
    let maxFat: Decimal
    let maxProtein: Decimal
    let maxBolus: Decimal
}

/// Why the pending request left pending. Each device with the request open hears it, so it can close its screen.
enum AIRequestLeft: Equatable {
    /// A device took it to carry out: the first to confirm.
    case claimed(AIRequestAnswerSide)
    case declined(AIRequestDeclinedOn)
    case expired
    /// Its assistant canceled it.
    case withdrawn
    /// A newer request took its place.
    case replaced
}

/// What became of the bolus on the Treatments sheet a request opened.
enum AIRequestPhoneBolus: Equatable {
    /// No bolus was asked for: the carbs only.
    case none
    /// The pump started the bolus.
    case started
    case failed(reason: String)
    /// A bolus was asked for, but neither started nor failed before the sheet closed, as when Face ID was canceled.
    case notStarted
    /// The units were logged as insulin given outside Trio.
    case external
}

/// What the Treatments sheet a request opened logged and gave.
struct AIRequestPhoneResult: Equatable {
    let carbs: Decimal
    let fat: Decimal
    let protein: Decimal
    let units: Decimal
    let bolus: AIRequestPhoneBolus
}

/// What Trio reports about a request: the contract's state report.
enum AIRequestReport: Codable, Equatable {
    case pending(askedOn: AIRequestAskedOn, shown: AIRequestShown, display: AIRequestDisplay)
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

/// Trio's dose for a meal.
struct AIRequestDose: Equatable {
    let units: Decimal
}

/// Sends a request's states to where the request came from.
protocol AIRequestReporter: AnyObject {
    func report(_ report: AIRequestReport, for id: String) async
}

/// Trio's treatment side of a request: the wearer's limits, the dose, and logging carbs and boluses. The checks of the
/// screens a request opens are those screens' own.
protocol AIRequestTreatments: AnyObject {
    var limits: AIRequestLimits { get }
    /// Whether the wearer's "Enable Fat and Protein Entries" setting is on. Off, which is the default, a meal's fat and
    /// protein aren't logged or shown, as on the wearer's own Treatments sheet: only its carbs are.
    var logsFatAndProtein: Bool { get }
    func dose(forCarbs carbs: Decimal) async -> AIRequestDose
    /// Why Trio's dose is 0 U, for the notification, when `units` is 0 and Trio knows the reason is true. `nil` for a
    /// dose over 0 U, and for a 0 U dose with no reason to give: the bolus calculator also gives 0 U when the dose it
    /// works out is 0 or under the pump's increment.
    func noDoseReason(units: Decimal) async -> String?
    /// Stores the request's meal, eaten now, with the note `AI: <source> – <description>`: `carbs`, `fat` and `protein`
    /// are the grams logged.
    func storeCarbs(for request: AIMealRequest, carbs: Decimal, fat: Decimal, protein: Decimal) async throws
    /// Returns `nil` if the pump accepted the bolus, otherwise the reason it didn't.
    func enactBolus(_ units: Decimal) async -> String?
}

/// The Apple Watch the service's pushes can reach.
protocol AIRequestWatchDelivery: AnyObject {
    /// Whether a watch is paired, has the app, and has sent the push token the service needs. Without one, a request is
    /// asked on the iPhone.
    var isWatchAvailable: Bool { get }
}

/// The iPhone's backup notification, which opens the request on the Treatments sheet. `askedOn` says where the request was asked
/// first, which its wording follows.
protocol AIRequestPhoneBackupScheduling: AnyObject {
    func schedule(_ prompt: AIRequestPrompt, after delay: TimeInterval, askedOn: AIRequestAskedOn)
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
    /// When Trio received the request. Optional, so a file saved before Trio recorded it still reads.
    var receivedAt: Date? = nil
    /// When the iPhone asks too, if the watch hasn't answered by then.
    var phoneAskAt: Date? = nil
}
