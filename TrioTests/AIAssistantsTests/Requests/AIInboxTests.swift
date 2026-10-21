import Foundation
import Testing

@testable import Trio

@Suite("AI inbox") struct AIInboxTests {
    static let shown = AIRequestShown(carbs: 20, fat: 0, protein: 0, units: 1.2)

    func keys(of body: AIRequestStateBody) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
    }

    @Test func decodesContractInbox() throws {
        let json =
            #"{"requests":[{"id":"r1","kind":"meal","source":"ChatGPT","createdAt":"2026-10-19T15:04:05.123Z","expiresAt":"2026-10-19T15:09:05Z","withdrawn":false,"meal":{"description":"pizza","carbs":20,"fat":10}}],"answers":[]}"#
        let inbox = try AIInbox.decoder.decode(AIInbox.self, from: Data(json.utf8))
        let meal = try #require(inbox.mealRequest(inbox.requests[0]))
        #expect(meal.carbs == 20 && meal.fat == 10 && meal.protein == 0)
    }

    @Test func readsDatesWithAndWithoutFractionalSeconds() throws {
        let json =
            #"{"requests":[{"id":"r1","kind":"meal","source":"ChatGPT","createdAt":"2026-10-19T15:04:05.123Z","expiresAt":"2026-10-19T15:09:05Z","withdrawn":false,"meal":{"description":"pizza","carbs":20,"fat":10,"protein":8}}],"answers":[]}"#
        let request = try AIInbox.decoder.decode(AIInbox.self, from: Data(json.utf8)).requests[0]
        let expiresAt = try #require(ISO8601DateFormatter().date(from: "2026-10-19T15:09:05Z"))
        #expect(request.expiresAt == expiresAt)
        #expect(abs(request.createdAt.timeIntervalSince(expiresAt) + 299.877) < 0.001)
    }

    @Test func mealRequestCopiesEveryField() throws {
        let json =
            #"{"requests":[{"id":"r1","kind":"meal","source":"ChatGPT","createdAt":"2026-10-19T15:04:05Z","expiresAt":"2026-10-19T15:09:05Z","withdrawn":false,"meal":{"description":"pizza","carbs":20.5,"fat":10,"protein":8}}],"answers":[]}"#
        let inbox = try AIInbox.decoder.decode(AIInbox.self, from: Data(json.utf8))
        let request = inbox.requests[0]
        #expect(inbox.mealRequest(request) == AIMealRequest(
            id: "r1",
            source: "ChatGPT",
            description: "pizza",
            carbs: Decimal(string: "20.5")!,
            fat: 10,
            protein: 8,
            createdAt: request.createdAt,
            expiresAt: request.expiresAt
        ))
    }

    @Test func noMealRequestForAnotherKindOrWithoutAMeal() throws {
        let json =
            #"{"requests":[{"id":"r1","kind":"snack","source":"ChatGPT","createdAt":"2026-10-19T15:04:05Z","expiresAt":"2026-10-19T15:09:05Z","withdrawn":false,"meal":{"description":"pizza","carbs":20}},{"id":"r2","kind":"meal","source":"ChatGPT","createdAt":"2026-10-19T15:04:05Z","expiresAt":"2026-10-19T15:09:05Z","withdrawn":true}],"answers":[]}"#
        let inbox = try AIInbox.decoder.decode(AIInbox.self, from: Data(json.utf8))
        #expect(inbox.requests.count == 2)
        #expect(inbox.mealRequest(inbox.requests[0]) == nil)
        #expect(inbox.mealRequest(inbox.requests[1]) == nil)
        #expect(inbox.requests[1].withdrawn)
    }

    @Test func inboxIgnoresAnswers() throws {
        // An older service still lists the answers the watch relayed. Trio takes no answers from it, so whatever
        // that key holds is left alone.
        let json = #"{"requests":[],"answers":[{"v":1,"requestId":"r1","decision":"approve","mac":"x"},{"junk":true}]}"#
        let inbox = try AIInbox.decoder.decode(AIInbox.self, from: Data(json.utf8))
        #expect(inbox.requests.isEmpty)
    }

    @Test func pendingReportHasNoStyleOrRoute() throws {
        let body = AIRequestStateBody(.pending(
            askedOn: .watch,
            shown: Self.shown,
            display: .init(title: "t", body: "b")
        ))
        let obj = try keys(of: body)
        // The keys the contract has left for a pending report: no approval style, answer route or display MAC.
        #expect(Set(obj.keys) == ["state", "askedOn", "shown", "display"])
        #expect(obj["state"] as? String == "pending")
        #expect(obj["askedOn"] as? String == "watch")
        #expect(obj["shown"] as? [String: String] == ["carbs": "20.00", "fat": "0.00", "protein": "0.00", "units": "1.20"])
        #expect(obj["display"] as? [String: String] == ["title": "t", "body": "b"])
        let text = String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
        #expect(!text.contains("approvalStyle") && !text.contains("answerRoute") && !text.contains("mac"))
    }

    @Test func pendingDisplayHasOnlyTheTitleAndBody() throws {
        let body = AIRequestStateBody(.pending(
            askedOn: .watch,
            shown: Self.shown,
            display: .init(title: "t", body: "b")
        ))
        // The service reads the title and body of the display, and nothing Trio adds to the request.
        let display = try #require(try keys(of: body)["display"] as? [String: Any])
        #expect(Set(display.keys) == ["title", "body"])
    }

    @Test func deliveringAndLoggedBodiesCarryShown() throws {
        for (report, state) in [
            (AIRequestReport.delivering(shown: Self.shown), "delivering"),
            (AIRequestReport.logged(shown: Self.shown), "logged")
        ] {
            let obj = try keys(of: AIRequestStateBody(report))
            #expect(Set(obj.keys) == ["state", "shown"])
            #expect(obj["state"] as? String == state)
        }
    }

    @Test func declinedBodyNamesWhereItWasDeclined() throws {
        let obj = try keys(of: AIRequestStateBody(.declined(on: .dismissed)))
        #expect(Set(obj.keys) == ["state", "declinedOn"])
        #expect(obj["state"] as? String == "declined")
        #expect(obj["declinedOn"] as? String == "dismissed")
    }

    @Test func endStatesWithoutDetailsAreJustTheState() throws {
        for (report, state) in [
            (AIRequestReport.expired, "expired"),
            (AIRequestReport.withdrawn, "withdrawn"),
            (AIRequestReport.replaced, "replaced")
        ] {
            let obj = try keys(of: AIRequestStateBody(report))
            #expect(Set(obj.keys) == ["state"])
            #expect(obj["state"] as? String == state)
        }
    }

    @Test func failedBody() throws {
        let obj = try keys(of: AIRequestStateBody(.failed(reason: "x", carbsLogged: true)))
        #expect(Set(obj.keys) == ["state", "reason", "carbsLogged"])
        #expect(obj["state"] as? String == "failed")
        #expect(obj["reason"] as? String == "x")
        #expect(obj["carbsLogged"] as? Bool == true)
    }

    @Test func failedBodyKeepsCarbsLoggedWhenFalse() throws {
        let obj = try keys(of: AIRequestStateBody(.failed(reason: "over the limit", carbsLogged: false)))
        #expect(obj["carbsLogged"] as? Bool == false)
    }
}
