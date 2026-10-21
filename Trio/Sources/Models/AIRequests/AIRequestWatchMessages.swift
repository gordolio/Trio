import Foundation

/// What the iPhone tells the watch about the request it opened: the request's own amounts, and Trio's dose for them
/// worked out when the watch asked.
struct AIRequestWatchDetails: Codable, Equatable {
    let id: String
    let carbs: Decimal
    let fat: Decimal
    let protein: Decimal
    /// Trio's dose, floored to the hundredths the watch shows.
    let units: Decimal
    let expiresAt: Date
}

/// What the wearer confirmed on the watch's Confirm screen.
struct AIRequestWatchConfirm: Codable, Equatable {
    let id: String
    let units: Decimal
    /// The carbs the watch logs, or `nil` for the request's exact grams: the wearer didn't change them.
    let carbs: Decimal?
}

/// The watch left the request's flow without confirming it.
struct AIRequestWatchClose: Codable, Equatable {
    let id: String
    /// The wearer swiped the request's notification away, rather than leaving its screens.
    let dismissed: Bool
}

/// The request left pending, so the device that has it open closes it with this headline.
struct AIRequestEnded: Codable, Equatable {
    let id: String
    let headline: String
    let isSuccess: Bool
}
