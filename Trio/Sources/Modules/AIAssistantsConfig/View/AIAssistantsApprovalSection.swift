import SwiftUI

extension AIAssistantsConfig {
    /// How an assistant's request is approved, and when the iPhone asks as well.
    struct ApprovalSection: View {
        @ObservedObject var state: StateModel

        var body: some View {
            Section(
                header: Text("Approving requests"),
                footer: Text(
                    "Two steps: open the request, then turn the crown or double tap. Double tap the notification: one gesture approves."
                )
            ) {
                Picker("Approval style", selection: $state.preferences.approvalStyle) {
                    ForEach(AIRequestApprovalStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }
            }
            .listRowBackground(Color.chart)

            Section(footer: Text("Without a watch, Trio asks on the iPhone right away.")) {
                Picker("Also ask on iPhone after", selection: $state.preferences.phoneBackupDelay) {
                    ForEach(AIAssistantsPreferences.phoneBackupDelays, id: \.self) { delay in
                        Text(Self.title(forDelay: delay)).tag(delay)
                    }
                }
            }
            .listRowBackground(Color.chart)
        }

        private static func title(forDelay delay: TimeInterval) -> LocalizedStringKey {
            delay == 0 ? "Immediately" : "\(Int(delay)) s"
        }
    }
}

private extension AIRequestApprovalStyle {
    var title: LocalizedStringKey {
        switch self {
        case .twoStep:
            return "Two steps"
        case .oneGesture:
            return "Double tap the notification"
        }
    }
}
