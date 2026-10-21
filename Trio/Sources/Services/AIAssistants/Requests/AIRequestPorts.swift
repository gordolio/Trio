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
    /// Set only on the iPhone's test requests.
    var testKind: AIRequestTestKind? = nil
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

/// How a request ended: its first final report, and what the wearer, the watch and the iPhone need to say about it.
/// `AIRequestResultText` turns it into words.
struct AIRequestOutcome: Equatable {
    let id: String
    /// The title the request was asked with. For a request that was never asked, it's made from the request.
    let title: String
    /// Who asked, for example "ChatGPT".
    let source: String
    /// The amounts the request was asked with, or `nil` when it never was.
    let shown: AIRequestShown?
    let report: AIRequestReport
    /// Where the request was asked, or `nil` when it never was: it was refused or expired on arrival.
    let askedOn: AIRequestAskedOn?
    /// Where the wearer approved it, or `nil` when nobody did.
    let approvedOn: AIRequestAnswerSide?
    /// Where the wearer declined it, or `nil` when they didn't.
    let declinedOn: AIRequestDeclinedOn?
    /// Trio stopped while starting the bolus, so it may have been given. Only a carry-out marker found at `.enacting`
    /// says so.
    var bolusUnconfirmed = false
}

extension AIRequestOutcome {
    /// A request that was never asked: refused or expired on arrival, or withdrawn before Trio saw it.
    init(_ report: AIRequestReport, request: AIMealRequest) {
        self.init(
            id: request.id,
            title: AIRequestDisplayText.title(source: request.source, description: request.description),
            source: request.source,
            shown: nil,
            report: report,
            askedOn: nil,
            approvedOn: nil,
            declinedOn: nil
        )
    }

    /// The request that was pending, with where it was approved or declined if it was.
    init(
        _ report: AIRequestReport,
        pending: PendingAIRequest,
        approvedOn: AIRequestAnswerSide? = nil,
        declinedOn: AIRequestDeclinedOn? = nil
    ) {
        self.init(
            id: pending.request.id,
            title: pending.prompt.title,
            source: pending.request.source,
            shown: pending.prompt.shown,
            report: report,
            askedOn: pending.askedOn,
            approvedOn: approvedOn,
            declinedOn: declinedOn
        )
    }

    /// The approved request Trio stopped carrying out. The bolus is unconfirmed only if Trio stopped while starting it.
    init(_ report: AIRequestReport, stopped marker: AIRequestCarryOutMarker) {
        self.init(
            id: marker.id,
            title: marker.title,
            source: marker.source,
            shown: marker.shown,
            report: report,
            askedOn: marker.askedOn,
            approvedOn: marker.approvedOn,
            declinedOn: nil,
            bolusUnconfirmed: marker.stage == .enacting
        )
    }
}

/// The notification text the wearer sees for a request.
struct AIRequestDisplay: Codable, Equatable {
    let title: String
    let body: String
    /// What Trio itself adds to the request, sent to the service so it can relay it to the watch.
    var context: AIRequestContext? = nil
    /// Trio's MAC over the title, the body, the approval style and the context, which the service relays to the watch
    /// as `displayMac`. `nil` when Trio had no key to sign with.
    var mac: String? = nil
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
    /// A dry-run test passed every check, and nothing was logged or given. Only the iPhone's test requests are dry
    /// runs, so it's reported only on `.local`.
    case dryRun(shown: AIRequestShown)

    var state: AIRequestState {
        switch self {
        case .pending:
            return .pending
        case .delivering:
            return .delivering
        case .dryRun,
             .logged:
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

/// Trio's dose for a meal, and the loop run it was worked out on.
struct AIRequestDose: Equatable {
    let units: Decimal
    /// The `deliverAt` of the determination the calculator read insulin on board from, or `nil` when there's none
    /// from the last 30 minutes. Insulin given after it isn't in the dose, so the recent-insulin check counts from it.
    let iobAsOf: Date?
}

/// Sends a request's states to where the request came from.
protocol AIRequestReporter: AnyObject {
    func report(_ report: AIRequestReport, for id: String) async
}

/// Trio's treatment side of a request: the wearer's limits, the dose, and logging carbs and boluses.
protocol AIRequestTreatments: AnyObject {
    var limits: AIRequestLimits { get }
    func dose(forCarbs carbs: Decimal) async -> AIRequestDose
    /// Trio's own facts for the request's approval: the latest glucose, recent carbs and insulin, and why the dose is
    /// 0 U when `units` is 0. Every value is inside trio-rc's limits.
    func context(for request: AIMealRequest, units: Decimal) async -> AIRequestContext
    /// Returns `nil` if the bolus is allowed, otherwise the reason it isn't. Only insulin given after `since` counts
    /// as recent.
    func checkBolus(_ units: Decimal, since: Date) async -> String?
    /// Whether a meal entry, not a fat and protein equivalent, is dated after `date` and not in the future.
    func carbsLogged(after date: Date) async -> Bool
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

/// The iPhone's backup notification, which opens Trio's approval screen. `askedOn` says where the request was asked
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
    /// When Trio received the request. This and the two below are optional, so a file saved before Trio recorded
    /// them still reads.
    var receivedAt: Date? = nil
    /// The dose's `iobAsOf`: `nil` when there was no loop run from the last 30 minutes.
    var iobAsOf: Date? = nil
    /// When the iPhone asks too, if the watch hasn't answered by then.
    var phoneAskAt: Date? = nil
}
