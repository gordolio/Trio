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

    @Test func decodesRelayedAnswers() throws {
        let json = """
        {"requests":[],"answers":[
          {"v":1,"requestId":"r1","decision":"approve","shown":{"carbs":"20.00","fat":"10.00","protein":"8.00","units":"1.20"},\
        "answeredAt":"2026-10-19T15:04:05Z","mac":"TYVul3-aELwwSpYoB2qLxixw1TDykYk36_qH7KYikmY"},
          {"v":1,"requestId":"r2","decision":"decline","declinedBy":"dismissed","shown":{"carbs":"1.00","fat":"0.00","protein":"0.00","units":"0.10"},\
        "answeredAt":"2026-10-19T15:04:05Z","mac":"DjDX-M29kj5YUOopDWGgB4NcqAtX1YKZ42PD_u_GKQs"}
        ]}
        """
        let answers = try AIInbox.decoder.decode(AIInbox.self, from: Data(json.utf8)).answers
        #expect(answers.map(\.requestId) == ["r1", "r2"])
        #expect(answers[0].declinedBy == nil && answers[1].declinedBy == .dismissed)
        #expect(answers[0].shown.units == "1.20")
    }

    @Test func pendingBodyHasContractKeys() throws {
        let body = AIRequestStateBody(.pending(
            askedOn: .watch,
            approvalStyle: .oneGesture,
            answerRoute: .both,
            shown: AIRequestShown(carbs: 20, fat: 0, protein: 0, units: 1.2),
            display: .init(title: "t", body: "b")
        ))
        let obj = try keys(of: body)
        #expect(Set(obj.keys) == ["state", "askedOn", "approvalStyle", "answerRoute", "shown", "display"])
        #expect(obj["state"] as? String == "pending")
        #expect(obj["askedOn"] as? String == "watch")
        #expect(obj["approvalStyle"] as? String == "oneGesture")
        #expect(obj["answerRoute"] as? String == "both")
        #expect(obj["shown"] as? [String: String] == ["carbs": "20.00", "fat": "0.00", "protein": "0.00", "units": "1.20"])
        #expect(obj["display"] as? [String: String] == ["title": "t", "body": "b"])
    }

    @Test func pendingBodyCarriesTheContextInsideTheDisplay() throws {
        let context = AIRequestContext(
            glucose: "142 mg/dL ↗",
            glucoseAgeMinutes: 3,
            recentCarbs: .init(amount: "20", minutesAgo: 6),
            recentBolus: .init(amount: "3.00", minutesAgo: 8),
            noDoseReason: nil
        )
        let body = AIRequestStateBody(.pending(
            askedOn: .watch,
            approvalStyle: .twoStep,
            answerRoute: .both,
            shown: Self.shown,
            display: .init(title: "t", body: "b", context: context)
        ))
        let display = try #require(try keys(of: body)["display"] as? [String: Any])
        #expect(Set(display.keys) == ["title", "body", "context"])
        let sent = try #require(display["context"] as? [String: Any])
        // Exactly the keys trio-rc reads: a fact Trio doesn't have is left out, not null.
        #expect(Set(sent.keys) == ["glucose", "glucoseAgeMinutes", "recentCarbs", "recentBolus"])
        #expect(sent["glucose"] as? String == "142 mg/dL ↗" && sent["glucoseAgeMinutes"] as? Int == 3)
        #expect(sent["recentCarbs"] as? [String: AnyHashable] == ["amount": "20", "minutesAgo": 6])
        #expect(sent["recentBolus"] as? [String: AnyHashable] == ["amount": "3.00", "minutesAgo": 8])
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
