import Foundation
import Testing

@testable import Trio

@Suite("AI request signing") struct AIRequestSignerTests {
    static let key = Data(0 ..< 32)
    static let prompt = AIRequestPrompt(
        id: "3F2504E0-4F89-41D3-9A0C-0305E82C3301", source: "ChatGPT", description: "slice of pizza",
        shown: AIRequestShown(carbs: 20, fat: 10, protein: 8, units: 1.2), title: "t", body: "b",
        expiresAt: .distantFuture, approvalStyle: .twoStep, answerRoute: .both, answerToken: nil, answerURL: nil
    )
    static let at = ISO8601DateFormatter().date(from: "2026-10-19T15:04:05Z")!

    @Test func contractVectorApprove() {
        let a = AIRequestSigner.sign(prompt: Self.prompt, decision: .approve, declinedBy: nil, at: Self.at, key: Self.key)
        #expect(a.mac == "TYVul3-aELwwSpYoB2qLxixw1TDykYk36_qH7KYikmY")
        #expect(a.shown.units == "1.20" && a.answeredAt == "2026-10-19T15:04:05Z")
    }

    @Test func contractVectorDismissed() {
        let a = AIRequestSigner.sign(prompt: Self.prompt, decision: .decline, declinedBy: .dismissed, at: Self.at, key: Self.key)
        #expect(a.mac == "DjDX-M29kj5YUOopDWGgB4NcqAtX1YKZ42PD_u_GKQs")
    }

    @Test func tamperedOrWrongKeyIsInvalid() {
        let a = AIRequestSigner.sign(prompt: Self.prompt, decision: .approve, declinedBy: nil, at: Self.at, key: Self.key)
        #expect(AIRequestSigner.isValid(a, key: Self.key))
        #expect(!AIRequestSigner.isValid(a, key: Data(repeating: 7, count: 32)))
        let tampered = AIRequestAnswer(
            v: 1, requestId: a.requestId, decision: a.decision, declinedBy: nil,
            shown: AIRequestShown(carbs: 20, fat: 10, protein: 8, units: 3), answeredAt: a.answeredAt, mac: a.mac
        )
        #expect(!AIRequestSigner.isValid(tampered, key: Self.key))
    }

    @Test func promptFromContractPush() throws {
        let userInfo: [AnyHashable: Any] = [
            "aps": [
                "alert": ["title": "ChatGPT: slice of pizza", "body": "20 g carbs · 1.2 U"],
                "category": "trio.request.approve"
            ],
            "trio-rc": [
                "v": 1, "type": "request",
                "request": [
                    "id": "r1", "source": "ChatGPT", "description": "slice of pizza",
                    "shown": ["carbs": "20.00", "fat": "0.00", "protein": "0.00", "units": "1.20"],
                    "expiresAt": "2026-10-19T15:09:05Z"
                ],
                "answerRoute": "serviceOnly", "answerToken": "tok", "answerUrl": "https://trio-rc.gordol.io/api/v1/answers"
            ]
        ]
        let p = try #require(AIRequestPrompt.fromPush(userInfo))
        #expect(p.approvalStyle == .oneGesture && p.answerRoute == .serviceOnly && p.answerToken == "tok")
        #expect(AIRequestPrompt.fromPush(["trio-rc": ["v": 1, "type": "check-in"]]) == nil)
    }

    @Test func watchCategoriesPutTheGestureActionFirst() throws {
        let cats = AIRequestIdentifiers.watchCategories()
        let approve = try #require(cats.first { $0.identifier == "trio.request.approve" })
        #expect(approve.actions.map(\.identifier) == ["AIRequest.approve", "AIRequest.decline"])
        #expect(approve.actions[1].options.contains(.destructive))
        #expect(approve.options.contains(.customDismissAction))
        let review = try #require(cats.first { $0.identifier == "trio.request.review" })
        #expect(review.actions[0].options.contains(.foreground))
    }

    @Test func shownRoundsToTwoDecimalsWithAPoint() {
        let shown = AIRequestShown(carbs: Decimal(string: "20.005")!, fat: 0, protein: 7.5, units: Decimal(string: "1.234")!)
        #expect(shown == AIRequestShown(carbs: "20.01", fat: "0.00", protein: "7.50", units: "1.23"))
    }

    @Test func timestampDropsFractionalSeconds() {
        #expect(AIRequestSigner.timestamp(Self.at.addingTimeInterval(0.9)) == "2026-10-19T15:04:05Z")
    }

    @Test func messageIsTheNineContractLines() {
        let a = AIRequestSigner.sign(prompt: Self.prompt, decision: .decline, declinedBy: .button, at: Self.at, key: Self.key)
        let lines = String(decoding: AIRequestSigner.message(a), as: UTF8.self).components(separatedBy: "\n")
        #expect(lines == [
            "trio-answer/v1", Self.prompt.id, "decline", "button",
            "20.00", "10.00", "8.00", "1.20", "2026-10-19T15:04:05Z"
        ])
        let approve = AIRequestSigner.sign(
            prompt: Self.prompt,
            decision: .approve,
            declinedBy: .button,
            at: Self.at,
            key: Self.key
        )
        #expect(approve.declinedBy == nil)
        #expect(String(decoding: AIRequestSigner.message(approve), as: UTF8.self).components(separatedBy: "\n")[3] == "")
    }

    @Test func answerSurvivesJSONAndMalformedMACIsInvalid() throws {
        let a = AIRequestSigner.sign(prompt: Self.prompt, decision: .approve, declinedBy: nil, at: Self.at, key: Self.key)
        let decoded = try JSONDecoder().decode(AIRequestAnswer.self, from: JSONEncoder().encode(a))
        #expect(decoded == a)
        #expect(AIRequestSigner.isValid(decoded, key: Self.key))
        let garbage = AIRequestAnswer(
            v: 1, requestId: a.requestId, decision: a.decision, declinedBy: nil, shown: a.shown, answeredAt: a.answeredAt,
            mac: "!!"
        )
        #expect(!AIRequestSigner.isValid(garbage, key: Self.key))
    }

    @Test func pushWithFractionalExpiryAndMissingFieldsIsHandled() throws {
        func push(expiresAt: String, category: String = "trio.request.review") -> [AnyHashable: Any] {
            [
                "aps": ["alert": ["title": "t", "body": "b"], "category": category],
                "trio-rc": [
                    "v": 1, "type": "request",
                    "request": [
                        "id": "r1", "source": "Grok", "description": "toast",
                        "shown": ["carbs": "10.00", "fat": "0.00", "protein": "0.00", "units": "0.50"],
                        "expiresAt": expiresAt
                    ],
                    "answerRoute": "both"
                ]
            ]
        }
        let p = try #require(AIRequestPrompt.fromPush(push(expiresAt: "2026-10-19T15:09:05.123Z")))
        #expect(p.approvalStyle == .twoStep && p.answerToken == nil && p.answerURL == nil)
        #expect(abs(p.expiresAt.timeIntervalSince(Self.at) - 300.123) < 0.01)
        #expect(AIRequestPrompt.fromPush(push(expiresAt: "soon")) == nil)
    }

    @Test func phoneCategoryHasNoActions() {
        let phone = AIRequestIdentifiers.phoneCategory()
        #expect(phone.identifier == "trio.request.phone" && phone.actions.isEmpty)
        #expect(AIRequestIdentifiers.category(for: .twoStep) == "trio.request.review")
        #expect(AIRequestIdentifiers.category(for: .oneGesture) == "trio.request.approve")
    }
}
