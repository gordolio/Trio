import SwiftUI

extension AIAssistantsConfig {
    /// A setup screen per assistant, and the address to paste into it.
    struct ConnectSection: View {
        @ObservedObject var state: StateModel

        var body: some View {
            Section(header: Text("Connect an assistant")) {
                ForEach(Assistant.allCases) { assistant in
                    NavigationLink {
                        AssistantSetupView(assistant: assistant, state: state)
                    } label: {
                        HStack(spacing: 12) {
                            IconTile(symbol: assistant.symbol, tint: assistant.tint)
                            Text(assistant.name)
                        }
                    }
                }
                if let connectorText = state.connectorDisplayText {
                    Button {
                        state.copyConnectorURL()
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                // Colors, not hierarchical styles: those take the button's tint.
                                Text("Connector URL")
                                    .font(.footnote)
                                    .foregroundStyle(Color.secondary)
                                Text(connectorText)
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(Color.primary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "doc.on.doc")
                        }
                    }
                    .accessibilityLabel(Text("Connector URL"))
                    .accessibilityValue(Text(connectorText))
                    .accessibilityHint(Text("Copies the address"))
                }
            }
            .listRowBackground(Color.chart)
        }
    }
}
