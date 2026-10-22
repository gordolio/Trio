import Foundation

/// What `GET /api/v1/inbox` returns: the requests that aren't final. The service may still list the answers a watch
/// relayed through it, under `answers`. Trio takes no answers from it, so that key is left unread.
struct AIInbox: Decodable {
    let requests: [Request]

    struct Request: Decodable {
        let id: String
        let kind: String
        /// Who asked, for example "ChatGPT".
        let source: String
        let createdAt: Date
        let expiresAt: Date
        /// The assistant canceled it and Trio hasn't confirmed yet.
        let withdrawn: Bool
        let meal: Meal?
    }

    struct Meal: Decodable {
        let description: String
        let carbs: Decimal
        let fat: Decimal?
        let protein: Decimal?
    }

    /// `nil` unless the request is a meal with its details. A missing fat or protein is 0.
    func mealRequest(_ r: Request) -> AIMealRequest? {
        guard r.kind == "meal", let meal = r.meal else { return nil }
        return AIMealRequest(
            id: r.id,
            source: r.source,
            description: meal.description,
            carbs: meal.carbs,
            fat: meal.fat ?? 0,
            protein: meal.protein ?? 0,
            createdAt: r.createdAt,
            expiresAt: r.expiresAt
        )
    }

    /// Reads the service's dates, which are ISO 8601 with milliseconds (`Date.toISOString()`), and also
    /// without them.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = (try? Date(string, strategy: Date.ISO8601FormatStyle()))
                ?? (try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(string)")
            }
            return date
        }
        return decoder
    }()
}

/// The body of `PUT /api/v1/requests/{id}/state`: the contract's state report. A field that doesn't go with
/// the state is left out.
struct AIRequestStateBody: Encodable, Equatable {
    let state: AIRequestState
    private(set) var askedOn: AIRequestAskedOn?
    private(set) var shown: AIRequestShown?
    private(set) var display: AIRequestDisplay?
    private(set) var declinedOn: AIRequestDeclinedOn?
    private(set) var reason: String?
    private(set) var carbsLogged: Bool?

    init(_ report: AIRequestReport) {
        state = report.state
        switch report {
        case let .pending(askedOn, shown, display):
            self.askedOn = askedOn
            self.shown = shown
            self.display = display
        case let .delivering(shown),
             let .logged(shown):
            self.shown = shown
        case let .declined(on):
            declinedOn = on
        case .expired,
             .replaced,
             .withdrawn:
            break
        case let .failed(reason, carbsLogged):
            self.reason = reason
            self.carbsLogged = carbsLogged
        }
    }
}
