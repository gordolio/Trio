import Foundation

/// Where the wearer answered a request. Shared, because a result says where it was answered.
enum AIRequestAnswerSide: String, Codable {
    case watch
    case phone
}

/// What the wearer is told about a request's final state: the iPhone makes it, and the watch, the iPhone sheet and
/// the notifications show the same words.
struct AIRequestResultMessage: Codable, Equatable {
    enum Tone: String, Codable {
        /// The request went as the wearer asked: the bolus started or the carbs were logged.
        case success
        /// Nothing happened, and nothing needs checking: it was declined, expired, replaced or canceled.
        case neutral
        /// The carbs were logged but the bolus wasn't, or may not have been.
        case warning
        /// Nothing was logged.
        case failure
    }

    let id: String
    /// The request's own title, for example "ChatGPT: slice of pizza".
    let title: String
    let headline: String
    let detail: String
    let tone: Tone
    /// Where the wearer answered, or `nil` when nobody did: the request was refused, expired, replaced or canceled.
    let answeredOn: AIRequestAnswerSide?
}
