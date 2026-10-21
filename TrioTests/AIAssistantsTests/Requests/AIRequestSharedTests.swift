import Foundation
import Testing

@testable import Trio

/// The amounts, the prompt and the names the phone and the watch share for a request.
@Suite("AI request shared models") struct AIRequestSharedTests {
    static let prompt = AIRequestPrompt(
        id: "3F2504E0-4F89-41D3-9A0C-0305E82C3301", source: "ChatGPT", description: "slice of pizza",
        shown: AIRequestShown(carbs: 20, fat: 10, protein: 8, units: 1.2), title: "t", body: "b",
        expiresAt: .distantFuture
    )

    @Test func shownRoundsToTwoDecimalsWithAPoint() {
        let shown = AIRequestShown(carbs: Decimal(string: "20.005")!, fat: 0, protein: 7.5, units: Decimal(string: "1.234")!)
        #expect(shown == AIRequestShown(carbs: "20.01", fat: "0.00", protein: "7.50", units: "1.23"))
    }

    @Test func promptKeepsItsContextThroughJSON() throws {
        var prompt = Self.prompt
        prompt.context = AIRequestContext(glucose: "142 mg/dL ↗", recentBolus: .init(amount: "3.00", minutesAgo: 8))
        let decoded = try JSONDecoder().decode(AIRequestPrompt.self, from: JSONEncoder().encode(prompt))
        #expect(decoded == prompt)
        // A prompt saved before the context existed still reads.
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.prompt)) as? [String: Any]
        #expect(plain?["context"] == nil)
        #expect(
            try JSONDecoder().decode(AIRequestPrompt.self, from: JSONSerialization.data(withJSONObject: plain ?? [:])) == Self
                .prompt
        )
    }

    @Test func requestIDReadsTheServicesPush() {
        let push: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "t", "body": "b"], "category": "trio.request.review"],
            "trio-rc": ["v": 1, "type": "request", "request": ["id": "r2", "source": "Grok"]]
        ]
        #expect(AIRequestIdentifiers.requestID(in: push) == "r2")
    }

    @Test func requestIDIsNilForOtherNotifications() throws {
        #expect(AIRequestIdentifiers.requestID(in: [:]) == nil)
        #expect(AIRequestIdentifiers.requestID(in: ["aiRequestId": "r1"]) == nil)
        #expect(AIRequestIdentifiers.requestID(in: ["trio-rc": ["type": "checkIn"]]) == nil)
        #expect(AIRequestIdentifiers.requestID(in: ["trio-rc": ["request": ["id": 7]]]) == nil)
        // The watch no longer makes notifications of its own for a request.
        let data = try JSONEncoder().encode(Self.prompt)
        #expect(AIRequestIdentifiers.requestID(in: ["aiRequestPrompt": data]) == nil)
    }

    @Test func watchCategoriesAreTheRequestsReviewAndTheIPhonesBackup() throws {
        let categories = AIRequestIdentifiers.watchCategories()
        #expect(Set(categories.map(\.identifier)) == ["trio.request.review", "trio.request.phone"])
        let review = try #require(categories.first { $0.identifier == AIRequestIdentifiers.categoryReview })
        // Review is the only action: nothing on the notification gives a bolus. Swiping it away reaches the app.
        #expect(review.actions.map(\.identifier) == [AIRequestIdentifiers.actionReview])
        #expect(review.options.contains(.customDismissAction))
        let phone = try #require(categories.first { $0.identifier == AIRequestIdentifiers.categoryPhone })
        #expect(phone.actions.isEmpty)
        #expect(AIRequestIdentifiers.phoneCategory().identifier == "trio.request.phone")
    }
}
