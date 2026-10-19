#if DEBUG
    import SwiftUI

    extension AIAssistantsConfig {
        /// The screen's states, for previews and the render test.
        enum PreviewState: String, CaseIterable {
            case linked
            case linkedWithoutEmail
            case waiting
            case failing
            case notLinked
            case signedOut
            case unconfigured
        }

        /// A state model seeded with `preview`'s state. It has no resolver or service, so sign-in
        /// and sign-out do nothing.
        static func previewStateModel(_ preview: PreviewState, now: Date = .now) -> StateModel {
            let state = StateModel()
            state.serviceURL = URL(string: "https://trio-rc.example.com")
            let host = "trio-rc.example.com"
            let ada = AIAssistantsAccount(email: "ada@example.com", name: "Ada Lovelace")
            switch preview {
            case .linked:
                state.linkState = .linked(host: host, lastUpload: now.addingTimeInterval(-4 * 60), lastError: nil)
                state.account = ada
            case .linkedWithoutEmail:
                state.linkState = .linked(host: host, lastUpload: now.addingTimeInterval(-20), lastError: nil)
            case .waiting:
                state.linkState = .linked(host: host, lastUpload: nil, lastError: nil)
                state.account = ada
            case .failing:
                state.linkState = .linked(
                    host: host,
                    lastUpload: now.addingTimeInterval(-12 * 60),
                    lastError: String(localized: "Upload failed (error 502)")
                )
                state.account = ada
            case .notLinked:
                state.linkState = .notLinked
            case .signedOut:
                state.linkState = .signedOut(host: host)
            case .unconfigured:
                state.serviceURL = nil
            }
            return state
        }
    }

    private struct AIAssistantsPreview: View {
        let state: AIAssistantsConfig.PreviewState

        var body: some View {
            NavigationStack {
                AIAssistantsConfig.ContentView(state: AIAssistantsConfig.previewStateModel(state))
            }
            .environment(AppState())
        }
    }

    #Preview("Linked") { AIAssistantsPreview(state: .linked) }
    #Preview("Linked, no email") { AIAssistantsPreview(state: .linkedWithoutEmail) }
    #Preview("Waiting") { AIAssistantsPreview(state: .waiting) }
    #Preview("Failing") { AIAssistantsPreview(state: .failing) }
    #Preview("Not linked") { AIAssistantsPreview(state: .notLinked) }
    #Preview("Signed out") { AIAssistantsPreview(state: .signedOut) }
    #Preview("Unconfigured") { AIAssistantsPreview(state: .unconfigured) }

    #Preview("Connect Claude") {
        NavigationStack {
            AIAssistantsConfig.AssistantSetupView(assistant: .claude, state: AIAssistantsConfig.previewStateModel(.linked))
        }
        .environment(AppState())
    }
#endif
