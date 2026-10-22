import SwiftUI

extension AIAssistantsConfig {
    /// Whether Trio asks about an assistant's meal requests, and when the iPhone asks as well.
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
                Picker("Ask on iPhone if no answer", selection: $state.preferences.phoneBackupDelay) {
                    ForEach(AIAssistantsPreferences.phoneBackupDelays, id: \.self) { delay in
                        Text(Self.title(forDelay: delay)).tag(delay)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("If your watch hasn't answered by then, your iPhone asks too. Without a watch, it asks right away.")
                    Text(
                        "Swiping a request away on your watch declines it, unless it's open on your iPhone. Requests expire after 5 minutes."
                    )
                }
            }
            .listRowBackground(Color.chart)
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
