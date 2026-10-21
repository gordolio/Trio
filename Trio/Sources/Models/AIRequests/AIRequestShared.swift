import Foundation

/// The amounts an AI assistant's request shows the wearer. They are strings with exactly two decimals and a `.`
/// separator, so every device and the service read the same text.
struct AIRequestShown: Codable, Equatable {
    let carbs: String
    let fat: String
    let protein: String
    let units: String
}

extension AIRequestShown {
    init(carbs: Decimal, fat: Decimal, protein: Decimal, units: Decimal) {
        self.init(
            carbs: Self.format(carbs),
            fat: Self.format(fat),
            protein: Self.format(protein),
            units: Self.format(units)
        )
    }

    private static func format(_ value: Decimal) -> String {
        var value = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        return String(
            format: "%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            NSDecimalNumber(decimal: rounded).doubleValue
        )
    }
}

/// What Trio asks about a request: who asked and for what, the amounts, and the text of the notifications. It's kept
/// with the pending request.
struct AIRequestPrompt: Codable, Equatable {
    let id: String
    let source: String
    let description: String
    let shown: AIRequestShown
    let title: String
    let body: String
    let expiresAt: Date
    /// What Trio itself adds to the request: the latest glucose, recent carbs and insulin, and why the dose is 0 U.
    /// `nil` for a request made before Trio recorded them.
    var context: AIRequestContext? = nil
}
