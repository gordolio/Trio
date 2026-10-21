import SwiftUI

extension AIAssistantsConfig {
    /// Whether Trio asks about an assistant's meal requests, how they're approved, and when the iPhone asks as well.
    struct ApprovalSection: View {
        @ObservedObject var state: StateModel

        var body: some View {
            Section {
                Toggle("Allow meal requests", isOn: $state.preferences.allowsMealRequests)
            } header: {
                Text("Approving requests")
            } footer: {
                if !state.preferences.allowsMealRequests {
                    Text("Assistants can still read your status. Any meal they ask for is declined.")
                }
            }
            .listRowBackground(Color.chart)

            Section {
                Picker("Approval style", selection: approvalStyle) {
                    ForEach(AIRequestApprovalStyle.allCases, id: \.self) { style in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(style.title)
                            Text(style.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .tag(style)
                    }
                }
                .pickerStyle(.inline)
                .alert("Approve from the notification?", isPresented: $state.isConfirmingOneGesture) {
                    Button("Turn On") { state.confirmOneGesture() }
                    Button("Cancel", role: .cancel) { state.cancelOneGesture() }
                } message: {
                    Text(
                        "One tap or double tap on the notification gives the bolus, without opening the request. Use this only if you check the dose on the notification every time."
                    )
                }
            } footer: {
                Text("Swiping a request away declines it. Requests expire after 5 minutes.")
            }
            .listRowBackground(Color.chart)

            Section {
                Picker("Ask on iPhone if no answer", selection: $state.preferences.phoneBackupDelay) {
                    ForEach(AIAssistantsPreferences.phoneBackupDelays, id: \.self) { delay in
                        Text(Self.title(forDelay: delay)).tag(delay)
                    }
                }
            } footer: {
                Text("If your watch hasn't answered by then, your iPhone asks too. Without a watch, it asks right away.")
            }
            .listRowBackground(Color.chart)
        }

        /// The picker shows the style in use. Choosing approval from the notification doesn't change it until the
        /// alert is confirmed, so the check mark stays where it was until then.
        private var approvalStyle: Binding<AIRequestApprovalStyle> {
            Binding(
                get: { state.preferences.approvalStyle },
                set: { state.requestApprovalStyle($0) }
            )
        }

        private static func title(forDelay delay: TimeInterval) -> LocalizedStringKey {
            switch delay {
            case 0:
                return "Right away"
            case 15:
                return "After 15 s"
            case 30:
                return "After 30 s"
            case 60:
                return "After 1 min"
            default:
                return "After \(Int(delay)) s"
            }
        }
    }
}

private extension AIRequestApprovalStyle {
    var title: LocalizedStringKey {
        switch self {
        case .twoStep:
            return "Review on watch first"
        case .oneGesture:
            return "Approve from the notification"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .twoStep:
            return "Tap Review, check the amounts, then turn the crown or double tap."
        case .oneGesture:
            return "Approve on the notification gives the bolus at once."
        }
    }
}
