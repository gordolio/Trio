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

                AIPromptSettingsView()

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
            .settingsHighlightScroll()
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

private struct AIPromptSettingsView: View {
    var body: some View {
        Section(
            header: Text("AI Prompts")
                .settingsSearchTarget(label: "AI Prompts"),
            footer: Text(
                "Custom prompts apply to both providers and remain saved across app updates."
            ),
            content: {
                ForEach(AIPromptSettings.Prompt.allCases) { prompt in
                    NavigationLink(prompt.title) {
                        AIPromptEditor(prompt: prompt)
                    }
                    .settingsSearchTarget(label: prompt.title)
                }
            }
        )
    }
}

private struct AIPromptEditor: View {
    let prompt: AIPromptSettings.Prompt

    @State private var promptText: String

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) var dismiss

    init(prompt: AIPromptSettings.Prompt) {
        self.prompt = prompt
        _promptText = State(initialValue: prompt.value)
    }

    var body: some View {
        Form {
            Section("When This Prompt Is Used") {
                Text(prompt.usageDescription)
                    .foregroundColor(.secondary)
            }
            .listRowBackground(Color.chart)

            if !prompt.placeholders.isEmpty {
                Section(
                    header: Text("Available Placeholders"),
                    footer: Text("Keep any placeholders needed to include live context in the request.")
                ) {
                    ForEach(prompt.placeholders) { placeholder in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(placeholder.displayToken)
                                .font(.system(.subheadline, design: .monospaced))
                            Text(placeholder.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .listRowBackground(Color.chart)
            }

            if !prompt.examples.isEmpty {
                Section("Example User Messages") {
                    ForEach(prompt.examples, id: \.self) { example in
                        Text("\"\(example)\"")
                            .foregroundColor(.secondary)
                    }
                }
                .listRowBackground(Color.chart)
            }

            Section("Prompt") {
                TextEditor(text: $promptText)
                    .keyboardType(.asciiCapable)
                    .font(.system(.subheadline, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .frame(minHeight: 320)
            }
            .listRowBackground(Color.chart)

            Section {
                Button("Reset to Defaults") {
                    prompt.reset()
                    promptText = prompt.defaultValue
                }
            }
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle(prompt.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarItems(
            trailing: Button("Save") {
                prompt.save(promptText)
                dismiss()
            }
            .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        )
    }
}
