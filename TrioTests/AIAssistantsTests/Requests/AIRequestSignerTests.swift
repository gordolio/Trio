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

    /// The service's push for a request, with `context` as `request.context` when it's given, and `alert` as
    /// `aps.alert`.
    private static func push(
        context: Any? = nil,
        alert: [String: Any] = ["title": "t", "body": "b"]
    ) -> [AnyHashable: Any] {
        var request: [String: Any] = [
            "id": "r1", "source": "ChatGPT", "description": "slice of pizza",
            "shown": ["carbs": "20.00", "fat": "0.00", "protein": "0.00", "units": "1.20"],
            "expiresAt": "2026-10-19T15:09:05Z"
        ]
        if let context { request["context"] = context }
        return [
            "aps": ["alert": alert, "category": "trio.request.review"],
            "trio-rc": ["v": 1, "type": "request", "request": request]
        ]
    }

    @Test func pushContextIsReadFromTheRequest() throws {
        let context: [String: Any] = [
            "glucose": "142 mg/dL ↗",
            "glucoseAgeMinutes": 3,
            "recentCarbs": ["amount": "20", "minutesAgo": 6],
            "recentBolus": ["amount": "3.00", "minutesAgo": 8],
            "noDoseReason": "glucose is low (52 mg/dL)"
        ]
        let prompt = try #require(AIRequestPrompt.fromPush(Self.push(context: context)))
        #expect(prompt.context == AIRequestContext(
            glucose: "142 mg/dL ↗",
            glucoseAgeMinutes: 3,
            recentCarbs: .init(amount: "20", minutesAgo: 6),
            recentBolus: .init(amount: "3.00", minutesAgo: 8),
            noDoseReason: "glucose is low (52 mg/dL)"
        ))
        #expect(prompt.testKind == nil)
    }

    @Test func pushContextMayHaveOnlySomeKeys() throws {
        let prompt = try #require(AIRequestPrompt.fromPush(Self.push(context: ["glucose": "142 mg/dL"])))
        #expect(prompt.context == AIRequestContext(glucose: "142 mg/dL"))
        // An empty object is a context with nothing in it.
        let empty = try #require(AIRequestPrompt.fromPush(Self.push(context: [String: Any]())))
        #expect(empty.context == AIRequestContext())
    }

    @Test func pushWithoutAContextHasNone() throws {
        #expect(try #require(AIRequestPrompt.fromPush(Self.push())).context == nil)
    }

    @Test func malformedPushContextIsIgnoredWithoutFailingThePrompt() throws {
        let malformed: [Any] = [
            "not an object",
            7,
            [1, 2, 3],
            ["glucoseAgeMinutes": "three"],
            ["glucoseAgeMinutes": 1.5],
            ["glucose": 142],
            ["recentCarbs": ["amount": "20"]],
            ["recentBolus": ["amount": 3, "minutesAgo": 8]],
            ["recentCarbs": "20 g"],
            ["noDoseReason": ["glucose is low"]],
            ["glucose": "142 mg/dL", "recentBolus": ["amount": "3.00", "minutesAgo": "8"]]
        ]
        for context in malformed {
            // The request is still asked; it just has no context.
            let prompt = try #require(AIRequestPrompt.fromPush(Self.push(context: context)), "\(context)")
            #expect(prompt.id == "r1" && prompt.shown.units == "1.20")
            #expect(prompt.context == nil, "\(context)")
        }
    }

    @Test func promptKeepsItsContextAndTestKindThroughJSON() throws {
        var prompt = Self.prompt
        prompt.context = AIRequestContext(glucose: "142 mg/dL ↗", recentBolus: .init(amount: "3.00", minutesAgo: 8))
        prompt.testKind = .real
        let decoded = try JSONDecoder().decode(AIRequestPrompt.self, from: JSONEncoder().encode(prompt))
        #expect(decoded == prompt)
        // A prompt saved before these existed still reads.
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.prompt)) as? [String: Any]
        #expect(plain?["context"] == nil && plain?["testKind"] == nil)
        #expect(
            try JSONDecoder().decode(AIRequestPrompt.self, from: JSONSerialization.data(withJSONObject: plain ?? [:])) == Self
                .prompt
        )
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

    // MARK: Display MAC

    /// The contract's "Display MAC" test vector. The spaces before `2.10`, `U` and `g` are U+00A0; the ones around
    /// `·` are ordinary.
    private enum Display {
        static let id = "8f14e45f-ea6b-4c1d-9a2f-6d1b2c3a4e5f"
        static let shown = AIRequestShown(carbs: "35.00", fat: "0.00", protein: "0.00", units: "2.10")
        static let title = "ChatGPT: slice of pizza"
        static let body = "Bolus\u{00A0}2.10\u{00A0}U · 35\u{00A0}g carbs"
        static let context = AIRequestContext(
            glucose: "142 mg/dL \u{2197}",
            glucoseAgeMinutes: 3,
            recentCarbs: .init(amount: "20", minutesAgo: 6)
        )
        static let mac = "5qt66bYnOSMr8628sulWAvWD9vEX85Tbrl7mMbo7-pE"
    }

    /// Signs the vector's inputs, with any of them changed.
    private static func signDisplay(
        id: String = Display.id,
        style: AIRequestApprovalStyle = .oneGesture,
        shown: AIRequestShown = Display.shown,
        title: String = Display.title,
        body: String = Display.body,
        context: AIRequestContext? = Display.context
    ) -> String {
        AIRequestSigner.displayMAC(
            id: id,
            approvalStyle: style,
            shown: shown,
            title: title,
            body: body,
            context: context,
            key: key
        )
    }

    /// Checks `mac` against the vector's inputs, with any of them changed.
    private static func isValidDisplay(
        _ mac: String?,
        id: String = Display.id,
        style: AIRequestApprovalStyle = .oneGesture,
        shown: AIRequestShown = Display.shown,
        title: String = Display.title,
        body: String = Display.body,
        context: AIRequestContext? = Display.context,
        key: Data = key
    ) -> Bool {
        AIRequestSigner.isValidDisplayMAC(
            mac,
            id: id,
            approvalStyle: style,
            shown: shown,
            title: title,
            body: body,
            context: context,
            key: key
        )
    }

    @Test func displayMACMatchesTheContractVector() {
        let mac = AIRequestSigner.displayMAC(
            id: Display.id,
            approvalStyle: .oneGesture,
            shown: Display.shown,
            title: Display.title,
            body: Display.body,
            context: Display.context,
            key: Self.key
        )
        #expect(mac == Display.mac)
        #expect(Self.isValidDisplay(Display.mac))
    }

    @Test func displayMACRejectsChangedBody() {
        #expect(!Self.isValidDisplay(Display.mac, body: "Bolus\u{00A0}9.10\u{00A0}U · 35\u{00A0}g carbs"))
        // A line added to the end of the body is a change too.
        #expect(!Self.isValidDisplay(Display.mac, body: Display.body + "\n"))
        #expect(!Self.isValidDisplay(Display.mac, title: "ChatGPT: two slices of pizza"))
        #expect(!Self.isValidDisplay(Display.mac, id: "8f14e45f-ea6b-4c1d-9a2f-6d1b2c3a4e50"))
    }

    @Test func displayMACRejectsChangedStyle() {
        let twoStep = Self.signDisplay(style: .twoStep)
        #expect(Self.isValidDisplay(twoStep, style: .twoStep))
        #expect(!Self.isValidDisplay(twoStep, style: .oneGesture))
    }

    @Test func displayMACRejectsChangedAmounts() {
        // The text Trio signed, over amounts it didn't: the watch would sign its answer over these.
        let changed = [
            AIRequestShown(carbs: "95.00", fat: "0.00", protein: "0.00", units: "2.10"),
            AIRequestShown(carbs: "35.00", fat: "1.00", protein: "0.00", units: "2.10"),
            AIRequestShown(carbs: "35.00", fat: "0.00", protein: "1.00", units: "2.10"),
            AIRequestShown(carbs: "35.00", fat: "0.00", protein: "0.00", units: "5.00")
        ]
        let mac = Self.signDisplay()
        #expect(Self.isValidDisplay(mac, shown: Display.shown))
        for shown in changed {
            #expect(!Self.isValidDisplay(mac, shown: shown), "\(shown)")
            #expect(!Self.isValidDisplay(Display.mac, shown: shown), "\(shown)")
        }
    }

    @Test func displayMACRejectsChangedContext() {
        var withoutCarbs = Display.context
        withoutCarbs.recentCarbs = nil
        #expect(!Self.isValidDisplay(Display.mac, context: withoutCarbs))
        // Nor can rows be added, a value changed, or the context dropped.
        var withBolus = Display.context
        withBolus.recentBolus = .init(amount: "3.00", minutesAgo: 8)
        #expect(!Self.isValidDisplay(Display.mac, context: withBolus))
        var older = Display.context
        older.glucoseAgeMinutes = 30
        #expect(!Self.isValidDisplay(Display.mac, context: older))
        #expect(!Self.isValidDisplay(Display.mac, context: nil))
    }

    @Test func displayMACRejectsAnEmptyContextString() {
        // Present but empty signs the same as missing, so it's never trusted: it would be a blank row.
        let empty = [
            AIRequestContext(glucose: ""),
            AIRequestContext(recentCarbs: .init(amount: "", minutesAgo: 6)),
            AIRequestContext(recentBolus: .init(amount: "", minutesAgo: 8)),
            AIRequestContext(noDoseReason: "")
        ]
        for context in empty {
            #expect(!Self.isValidDisplay(Self.signDisplay(context: context), context: context), "\(context)")
        }
        #expect(!AIRequestSigner.isSignableDisplay(
            id: Display.id, shown: Display.shown, title: Display.title, context: AIRequestContext(glucose: "")
        ))
        #expect(AIRequestSigner.isSignableDisplay(
            id: Display.id, shown: Display.shown, title: Display.title, context: Display.context
        ))
    }

    @Test func displayMACRejectsALineBreakInAContextField() {
        // Signed as is, but checked never: a line break there could move the text into another field.
        let multiLine: [(title: String, context: AIRequestContext)] = [
            (Display.title, AIRequestContext(glucose: "142 mg/dL\n3")),
            (Display.title, AIRequestContext(recentCarbs: .init(amount: "20\n6", minutesAgo: 6))),
            (Display.title, AIRequestContext(recentBolus: .init(amount: "3.00\r", minutesAgo: 8))),
            (Display.title, AIRequestContext(noDoseReason: "glucose is low\u{2028}(52 mg/dL)")),
            ("ChatGPT\noneGesture", Display.context)
        ]
        for (title, context) in multiLine {
            let mac = Self.signDisplay(title: title, context: context)
            #expect(!Self.isValidDisplay(mac, title: title, context: context), "\(title) \(context)")
        }
        // The request ID and the amounts too: the service sends them to the watch.
        let id = "8f14e45f\noneGesture"
        #expect(!Self.isValidDisplay(Self.signDisplay(id: id, style: .twoStep), id: id, style: .twoStep))
        let shown = AIRequestShown(carbs: "35.00\n0.00", fat: "0.00", protein: "2.10", units: "")
        #expect(!Self.isValidDisplay(Self.signDisplay(shown: shown), shown: shown))
        // The body is the one field that may have line breaks.
        let body = "Bolus\u{00A0}2.10\u{00A0}U\n142 mg/dL"
        #expect(Self.isValidDisplay(Self.signDisplay(body: body), body: body))
    }

    @Test func displayMACRejectsNil() {
        #expect(!Self.isValidDisplay(nil))
        #expect(!Self.isValidDisplay(""))
        #expect(!Self.isValidDisplay("!!"))
        #expect(!Self.isValidDisplay(Display.mac, key: Data(repeating: 7, count: 32)))
    }

    @Test func pushDisplayMACIsReadFromTheTopLevel() throws {
        var userInfo = Self.push()
        var payload = try #require(userInfo["trio-rc"] as? [String: Any])
        payload["displayMac"] = Display.mac
        userInfo["trio-rc"] = payload
        #expect(try #require(AIRequestPrompt.fromPush(userInfo)).displayMac == Display.mac)
        #expect(try #require(AIRequestPrompt.fromPush(Self.push())).displayMac == nil)
    }

    @Test func promptKeepsItsDisplayMACThroughJSON() throws {
        var prompt = Self.prompt
        prompt.displayMac = Display.mac
        let decoded = try JSONDecoder().decode(AIRequestPrompt.self, from: JSONEncoder().encode(prompt))
        #expect(decoded.displayMac == Display.mac)
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.prompt)) as? [String: Any]
        #expect(plain?["displayMac"] == nil)
    }

    // MARK: Alert text outside the title and body

    @Test func alertWithOnlyATitleAndABodyIsClean() throws {
        #expect(AIRequestPrompt.alertHasOnlyTitleAndBody(Self.push()))
        #expect(AIRequestPrompt.alertHasOnlyTitleAndBody(Self.push(alert: ["title": "t"])))
        #expect(try #require(AIRequestPrompt.fromPush(Self.push())).hasUncheckedAlertText == false)
    }

    /// The system shows these too, and a `…-loc-key` missing from the strings file is shown as it is, but the display
    /// MAC doesn't cover them.
    @Test(arguments: [
        "subtitle",
        "loc-key",
        "title-loc-key",
        "subtitle-loc-key",
        "loc-args",
        "launch-image"
    ]) func alertWithOtherTextIsNotClean(key: String) throws {
        let userInfo = Self.push(alert: ["title": "t", "body": "b", key: "Bolus 0.30 U"])
        #expect(!AIRequestPrompt.alertHasOnlyTitleAndBody(userInfo))
        // The request is still asked, but never approved from the notification.
        #expect(try #require(AIRequestPrompt.fromPush(userInfo)).hasUncheckedAlertText)
    }

    @Test func alertThatIsntADictionaryIsNotClean() {
        var userInfo = Self.push()
        userInfo["aps"] = ["alert": "Bolus 0.30 U", "category": "trio.request.approve"]
        #expect(!AIRequestPrompt.alertHasOnlyTitleAndBody(userInfo))
        #expect(!AIRequestPrompt.alertHasOnlyTitleAndBody(["aps": ["category": "trio.request.approve"]]))
    }

    @Test func uncheckedAlertTextIsntSentOrSaved() throws {
        var prompt = Self.prompt
        prompt.hasUncheckedAlertText = true
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(prompt)) as? [String: Any]
        #expect(plain?["hasUncheckedAlertText"] == nil)
        // It's the watch's own reading of the notification, never taken from JSON.
        #expect(try JSONDecoder().decode(AIRequestPrompt.self, from: JSONEncoder().encode(prompt)).hasUncheckedAlertText == false)
    }
}
