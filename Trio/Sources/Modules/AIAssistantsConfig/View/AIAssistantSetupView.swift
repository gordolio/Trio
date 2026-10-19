import SwiftUI

extension AIAssistantsConfig {
    /// How to add Trio's connector to one assistant.
    struct AssistantSetupView: View {
        let assistant: Assistant
        @ObservedObject var state: StateModel

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState
        @ScaledMetric(relativeTo: .subheadline) private var numberSize: CGFloat = 24

        var body: some View {
            Form {
                Section(header: Text("Steps")) {
                    ForEach(Array(assistant.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: numberSize, height: numberSize)
                                .background(Circle().fill(assistant.tint))
                            Text(step)
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                    }
                }
                .listRowBackground(Color.chart)

                Section(footer: Text(assistant.note)) {
                    VStack(spacing: 8) {
                        Button {
                            state.copyConnectorURL()
                        } label: {
                            Label("Copy connector URL", systemImage: "doc.on.doc")
                                .labelStyle(.titleAndIcon)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        if let connectorText = state.connectorDisplayText {
                            Text(connectorText)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.chart)
            }
            .listSectionSpacing(sectionSpacing)
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle(Text("Connect \(assistant.name)"))
            .navigationBarTitleDisplayMode(.large)
            .copiedToast(message: state.copiedMessage, trigger: state.copyCount)
        }
    }
}
