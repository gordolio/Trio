import SwiftUI
import Swinject

extension AIServiceSettings {
    struct RootView: BaseView {
        let resolver: Resolver

        @StateObject var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            Form {
                Section(
                    header: Text("AI Provider"),
                    footer: Text(
                        "Selects which model runs first for AI-assisted carb entry. Both models are accessed through OpenRouter."
                    ),
                    content: {
                        Picker("Provider", selection: $state.aiProvider) {
                            ForEach(AIProviderType.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                )
                .listRowBackground(Color.chart)

                Section(
                    header: Text("Compare Providers"),
                    footer: Text(
                        "When enabled, both models appear as tabs. The selected model runs first; the other loads when you open its tab."
                    ),
                    content: {
                        Toggle(
                            "Send to all providers simultaneously",
                            isOn: $state.sendToAllAIProvidersSimultaneously
                        )
                    }
                )
                .listRowBackground(Color.chart)

                Section(
                    header: Text("API Key Status"),
                    content: {
                        keyStatusRow(
                            label: "OpenRouter",
                            configured: isKeyConfigured("OpenRouterAPIKey", placeholder: "$(OPENROUTER_API_KEY)")
                        )
                    }
                )
                .listRowBackground(Color.chart)
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("AI")
            .navigationBarTitleDisplayMode(.automatic)
            .onAppear(perform: configureView)
        }

        private func keyStatusRow(label: String, configured: Bool) -> some View {
            HStack {
                Text(label)
                Spacer()
                Text(configured ? "Configured" : "Not configured")
                    .foregroundColor(configured ? .green : .secondary)
            }
        }

        private func isKeyConfigured(_ infoPlistKey: String, placeholder: String) -> Bool {
            guard let value = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String else { return false }
            return !value.isEmpty && value != placeholder
        }
    }
}
