import CryptoKit
import Foundation

/// The amounts an AI assistant's request shows the wearer. They are strings with exactly two decimals and a
/// `.` separator, so the phone and the watch sign and compare the same bytes.
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

enum AIRequestDecision: String, Codable {
    case approve
    case decline
}

enum AIRequestDeclinedBy: String, Codable {
    /// The wearer pressed Decline.
    case button
    /// The wearer swiped the notification away.
    case dismissed
}

enum AIRequestApprovalStyle: String, Codable, CaseIterable {
    /// Review the request first, then approve.
    case twoStep
    /// Approve straight from the notification.
    case oneGesture
}

enum AIRequestAnswerRoute: String, Codable, CaseIterable {
    case both
    case watchOnly
    case serviceOnly
}

/// What the watch shows for a request, and what it signs the answer against.
struct AIRequestPrompt: Codable, Equatable {
    let id: String
    let source: String
    let description: String
    let shown: AIRequestShown
    let title: String
    let body: String
    let expiresAt: Date
    let approvalStyle: AIRequestApprovalStyle
    let answerRoute: AIRequestAnswerRoute
    /// The bearer token for relaying the answer to the service. Single use.
    let answerToken: String?
    let answerURL: URL?

    /// Reads the service's watch push. Returns `nil` unless it is a well-formed request.
    static func fromPush(_ userInfo: [AnyHashable: Any]) -> AIRequestPrompt? {
        guard let payload = userInfo[AIRequestIdentifiers.pushPayloadKey] as? [String: Any],
              payload["type"] as? String == "request",
              let request = payload["request"] as? [String: Any],
              let id = request["id"] as? String,
              let source = request["source"] as? String,
              let description = request["description"] as? String,
              let shown = request["shown"] as? [String: Any],
              let carbs = shown["carbs"] as? String,
              let fat = shown["fat"] as? String,
              let protein = shown["protein"] as? String,
              let units = shown["units"] as? String,
              let expiresAtString = request["expiresAt"] as? String,
              let expiresAt = date(fromTimestamp: expiresAtString),
              let aps = userInfo["aps"] as? [String: Any],
              let alert = aps["alert"] as? [String: Any],
              let title = alert["title"] as? String,
              let body = alert["body"] as? String
        else { return nil }

        let category = aps["category"] as? String
        return AIRequestPrompt(
            id: id,
            source: source,
            description: description,
            shown: AIRequestShown(carbs: carbs, fat: fat, protein: protein, units: units),
            title: title,
            body: body,
            expiresAt: expiresAt,
            approvalStyle: category == AIRequestIdentifiers.categoryApprove ? .oneGesture : .twoStep,
            answerRoute: (payload["answerRoute"] as? String).flatMap(AIRequestAnswerRoute.init(rawValue:)) ?? .both,
            answerToken: payload["answerToken"] as? String,
            answerURL: (payload["answerUrl"] as? String).flatMap(URL.init(string:))
        )
    }

    /// ISO 8601, with or without fractional seconds.
    private static func date(fromTimestamp string: String) -> Date? {
        (try? Date(string, strategy: Date.ISO8601FormatStyle()))
            ?? (try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
}

/// The wearer's signed answer: the contract's `SignedAnswerV1`. The watch sends the same value to the
/// phone and to the service.
struct AIRequestAnswer: Codable, Equatable {
    let v: Int
    let requestId: String
    let decision: AIRequestDecision
    let declinedBy: AIRequestDeclinedBy?
    let shown: AIRequestShown
    let answeredAt: String
    let mac: String
}

/// Signs and checks answers with the 32-byte key that only the phone and the watch hold.
enum AIRequestSigner {
    /// ISO 8601 in UTC, with a `Z` and whole seconds.
    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle())
    }

    /// The bytes the MAC covers: the contract's nine lines joined with `\n`.
    static func message(_ answer: AIRequestAnswer) -> Data {
        let lines = [
            "trio-answer/v1",
            answer.requestId,
            answer.decision.rawValue,
            answer.declinedBy?.rawValue ?? "",
            answer.shown.carbs,
            answer.shown.fat,
            answer.shown.protein,
            answer.shown.units,
            answer.answeredAt
        ]
        return Data(lines.joined(separator: "\n").utf8)
    }

    static func sign(
        prompt: AIRequestPrompt,
        decision: AIRequestDecision,
        declinedBy: AIRequestDeclinedBy?,
        at date: Date,
        key: Data
    ) -> AIRequestAnswer {
        let unsigned = AIRequestAnswer(
            v: 1,
            requestId: prompt.id,
            decision: decision,
            declinedBy: decision == .decline ? declinedBy : nil,
            shown: prompt.shown,
            answeredAt: timestamp(date),
            mac: ""
        )
        let code = HMAC<SHA256>.authenticationCode(for: message(unsigned), using: SymmetricKey(data: key))
        return AIRequestAnswer(
            v: unsigned.v,
            requestId: unsigned.requestId,
            decision: unsigned.decision,
            declinedBy: unsigned.declinedBy,
            shown: unsigned.shown,
            answeredAt: unsigned.answeredAt,
            mac: base64URL(Data(code))
        )
    }

    /// Recomputes the MAC and compares it in constant time.
    static func isValid(_ answer: AIRequestAnswer, key: Data) -> Bool {
        guard let mac = data(fromBase64URL: answer.mac) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: message(answer), using: SymmetricKey(data: key))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func data(fromBase64URL string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
