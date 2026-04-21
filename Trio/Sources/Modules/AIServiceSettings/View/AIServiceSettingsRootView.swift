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
                        "Selects which AI service powers the AI-assisted carb entry features. API keys for both providers are set in ConfigOverride.xcconfig at build time; they are not configurable in the app."
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
                        "When enabled, each food image is analyzed by every available provider in parallel. You can switch between results with the tabs above the food list to compare estimates before confirming."
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
                            label: "OpenAI",
                            configured: isKeyConfigured("OpenAIAPIKey", placeholder: "$(OPENAI_API_KEY)")
                        )
                        keyStatusRow(
                            label: "Anthropic",
                            configured: isKeyConfigured("AnthropicAPIKey", placeholder: "$(ANTHROPIC_API_KEY)")
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
