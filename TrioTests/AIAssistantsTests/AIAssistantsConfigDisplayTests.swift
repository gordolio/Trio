import Foundation
import Testing

@testable import Trio

@Suite("AI Assistants settings display", .serialized) @MainActor struct AIAssistantsConfigDisplayTests {
    let service = FakeAIAssistantsService()
    /// What the state model put on the pasteboard, in order.
    let copied = TestBox<[String]>([])
    /// What the state model announced to VoiceOver, in order.
    let announced = TestBox<[String]>([])

    func makeState() -> AIAssistantsConfig.StateModel {
        let state = AIAssistantsConfig.StateModel()
        state.service = service
        state.serviceURL = URL(string: "https://trio-rc.example.com")
        let copied = self.copied, announced = self.announced
        state.pasteboard = { copied.value.append($0) }
        state.announce = { announced.value.append($0) }
        return state
    }

    // MARK: - Connector URL

    @Test("The connector URL is the service plus /mcp") func connectorURL() {
        let state = makeState()
        #expect(state.connectorURL == URL(string: "https://trio-rc.example.com/mcp"))
        #expect(state.connectorDisplayText == "trio-rc.example.com/mcp")
        state.serviceURL = URL(string: "https://trio-rc.example.com:8443")
        #expect(state.connectorURL == URL(string: "https://trio-rc.example.com:8443/mcp"))
        #expect(state.connectorDisplayText == "trio-rc.example.com:8443/mcp")
        state.serviceURL = nil
        #expect(state.connectorURL == nil)
        #expect(state.connectorDisplayText == nil)
    }

    // MARK: - Copying

    @Test("Copying the connector URL copies the full URL and confirms it") func copyConnectorURL() {
        let state = makeState()
        state.copyConnectorURL()
        #expect(copied.value == ["https://trio-rc.example.com/mcp"])
        #expect(announced.value == ["Connector URL copied"])
        #expect(state.copyCount == 1)
        #expect(state.copiedMessage == "Connector URL copied")
    }

    @Test("Without a service there's nothing to copy") func copyConnectorURLWithoutService() {
        let state = makeState()
        state.serviceURL = nil
        state.copyConnectorURL()
        #expect(copied.value.isEmpty)
        #expect(announced.value.isEmpty)
        #expect(state.copyCount == 0)
    }

    @Test("Copying a question copies its text") func copyQuestion() {
        let state = makeState()
        state.copyQuestion("What's my glucose?")
        state.copyQuestion("Is Trio looping?")
        #expect(copied.value == ["What's my glucose?", "Is Trio looping?"])
        #expect(announced.value == ["Question copied", "Question copied"])
        #expect(state.copyCount == 2)
        #expect(state.copiedMessage == "Question copied")
    }

    // MARK: - Status

    @Test("The sharing status follows the link state") func sharingStatus() {
        let state = makeState()
        let at = Date(timeIntervalSince1970: 1_000_000)
        let cases: [(AIAssistantsLinkState, AIAssistantsConfig.SharingStatus?, Bool)] = [
            (.linked(host: "h", lastUpload: at, lastError: nil), .sharing(lastUpload: at), true),
            (.linked(host: "h", lastUpload: nil, lastError: nil), .waitingForFirstUpdate, true),
            (.linked(host: "h", lastUpload: at, lastError: "Offline"), .failed(message: "Offline", lastUpload: at), true),
            (.linked(host: "h", lastUpload: nil, lastError: "Offline"), .failed(message: "Offline", lastUpload: nil), true),
            (.notLinked, nil, false),
            (.signedOut(host: "h"), nil, false)
        ]
        for (link, status, linked) in cases {
            state.linkState = link
            #expect(state.sharingStatus == status, "\(link)")
            #expect(state.isLinked == linked, "\(link)")
        }
    }

    @Test("Updated text is relative, and never in the future") func updatedText() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let text = AIAssistantsConfig.StateModel.updatedText
        #expect(text(now.addingTimeInterval(-30), now) == "Updated just now")
        #expect(text(now.addingTimeInterval(120), now) == "Updated just now")
        #expect(text(now.addingTimeInterval(-5 * 60), now) == "Updated 5 minutes ago")
        #expect(text(now.addingTimeInterval(-2 * 3600), now) == "Updated 2 hours ago")
    }

    // MARK: - Sections

    @Test("The settings have no Testing section, so no test request can be sent") func settingsHaveNoTestingSection() {
        // The screen's content, as the types of the sections it is made of.
        let content = String(reflecting: AIAssistantsConfig.ContentView.Body.self)
        // The same reading finds the sections that are there, so an empty reading can't pass.
        #expect(content.contains("AIAssistantsConfig.ApprovalSection"))
        #expect(content.contains("AIAssistantsConfig.QuestionsSection"))
        // Not just "Testing": SwiftUI's own `allowsHitTesting` modifier has it in its name.
        #expect(!content.contains("AIAssistantsConfig.Testing"))
    }

    // MARK: - Account

    @Test("Initials come from the name, else the email") func initials() {
        let state = makeState()
        let cases: [(AIAssistantsAccount?, String?)] = [
            (AIAssistantsAccount(email: "gordon.child@gmail.com", name: "Gordon Child"), "GC"),
            (AIAssistantsAccount(email: "x@example.com", name: "Mary Ann Lee"), "ML"),
            (AIAssistantsAccount(email: "x@example.com", name: "Cher"), "C"),
            (AIAssistantsAccount(email: "gordon.child@gmail.com", name: nil), "GC"),
            (AIAssistantsAccount(email: "ann_b-c@example.com", name: nil), "AB"),
            (AIAssistantsAccount(email: "x7k2q@privaterelay.appleid.com", name: nil), "X"),
            (AIAssistantsAccount(email: nil, name: nil), nil),
            (nil, nil)
        ]
        for (account, expected) in cases {
            state.account = account
            #expect(state.initials == expected, "\(String(describing: account))")
        }
    }

    @Test("The account title is the email, else 'Signed in with Apple'") func accountTitle() {
        let state = makeState()
        state.account = AIAssistantsAccount(email: "ann@example.com", name: "Ann Lee")
        #expect(state.accountTitle == "ann@example.com")
        state.account = AIAssistantsAccount(email: nil, name: "Ann Lee")
        #expect(state.accountTitle == "Signed in with Apple")
        state.account = nil
        #expect(state.accountTitle == "Signed in with Apple")
    }

    @Test("The account shown is the service's") func accountFollowsService() async {
        let state = makeState()
        state.subscribe()
        let ann = AIAssistantsAccount(email: "ann@example.com", name: "Ann Lee")
        service.account.send(ann)
        #expect(await eventuallyTrue { state.account == ann })
        service.account.send(nil)
        #expect(await eventuallyTrue { state.account == nil })
    }
}
