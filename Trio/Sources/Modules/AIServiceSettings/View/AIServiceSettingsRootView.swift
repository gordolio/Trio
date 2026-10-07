import SwiftUI
import Swinject

extension AIServiceSettings {
    struct RootView: BaseView {
        let resolver: Resolver

        @StateObject var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState
        @State private var showingModelPicker = false
        @State private var labelModelSearch = ""

        var body: some View {
            Form {
                Section(
                    header: Text("Image Classifier"),
                    footer: Text(
                        "Classifies each photo once. Clear nutrition labels use the fast label model; food uses your default food analysis model. Uncertain results or classifier errors use the default model."
                    )
                ) {
                    Toggle("Experimental image routing", isOn: $state.imageClassifierConfiguration.enabled)
                    NavigationLink {
                        Form {
                            if let error = state.decisionCatalogError {
                                Text(error).foregroundStyle(.secondary)
                            }
                            if state.isLoadingCatalog { ProgressView("Loading Models…") }
                            Button("Refresh Models") {
                                Task { await state.refreshCatalog(forceRefresh: true) }
                            }
                            .disabled(state.isLoadingCatalog)
                            if !state.decisionModels.contains(where: { $0.id == state.imageClassifierConfiguration.modelID }) {
                                Text("Selected: \(state.imageClassifierConfiguration.modelID)")
                                Text("Selected model is unavailable in the image decision catalog.").foregroundStyle(.secondary)
                            }
                            ForEach(state.decisionModels) { model in
                                Button {
                                    state.imageClassifierConfiguration.modelID = model.id
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(model.name)
                                            Text(model.id).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if model.id == state.imageClassifierConfiguration.modelID {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                        .navigationTitle("Image Decision Model")
                    } label: {
                        LabeledContent(
                            "Decision Model",
                            value: state.decisionModels.first(where: { $0.id == state.imageClassifierConfiguration.modelID })?
                                .name ?? state.imageClassifierConfiguration.modelID
                        )
                    }
                    NavigationLink {
                        Form {
                            ForEach(state.catalogModels.filter {
                                $0.isFoodAnalysisCompatible && (
                                    labelModelSearch.isEmpty ||
                                        $0.name.localizedCaseInsensitiveContains(labelModelSearch) ||
                                        $0.id.localizedCaseInsensitiveContains(labelModelSearch)
                                )
                            }) { model in
                                Button {
                                    state.imageClassifierConfiguration.nutritionLabelModelID = model.id
                                } label: {
                                    HStack {
                                        Text(model.name)
                                        Spacer()
                                        if model.id == state.imageClassifierConfiguration.nutritionLabelModelID {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                        .navigationTitle("Nutrition Label Model")
                        .searchable(text: $labelModelSearch, prompt: "Search Models")
                    } label: {
                        LabeledContent(
                            "Nutrition Label Model",
                            value: state.imageClassifierConfiguration.nutritionLabelModelID.openRouterShortDisplayName
                        )
                    }
                }
                .listRowBackground(Color.chart)

                Section(
                    header: Text("Food Analysis Models"),
                    footer: Text(
                        "Choose 1 to 4 OpenRouter models. Frontier choices resolve to the current model from the weekly catalog refresh. Drag to set tab order and tap the checkmark to choose the default model."
                    )
                ) {
                    ForEach(state.modelConfiguration.selectedModelIDs, id: \.self) { modelID in
                        configuredModelRow(modelID)
                    }
                    .onDelete(perform: state.removeModels)
                    .onMove(perform: state.moveModels)

                    Button {
                        showingModelPicker = true
                    } label: {
                        if state.isLoadingCatalog {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Loading Models…")
                            }
                        } else {
                            Label("Add Model", systemImage: "plus.circle")
                        }
                    }
                    .disabled(
                        state.isLoadingCatalog ||
                            state.modelConfiguration.selectedModelIDs.count >= OpenRouterModelConfiguration.maximumModelCount
                    )
                }
                .listRowBackground(Color.chart)

                Section("About Model Choices") {
                    Text(
                        "Models differ in capabilities, price, latency, retention policies, and downstream providers. OpenRouter catalog metadata can change; verify a model's provider terms before sending health-related images."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.chart)

                AIPromptSettingsView()

                Section(
                    header: Text("Model Execution"),
                    footer: Text(
                        "Off loads the default model first and other model tabs only when opened. On starts every configured model immediately and may increase cost."
                    ),
                    content: {
                        Toggle(
                            "Run all models immediately",
                            isOn: $state.modelConfiguration.runAllModelsSimultaneously
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
            .toolbar { EditButton() }
            .onAppear(perform: configureView)
            .task { await state.refreshCatalog() }
            .refreshable { await state.refreshCatalog(forceRefresh: true) }
            .sheet(isPresented: $showingModelPicker) {
                ModelPickerView(state: state)
            }
        }

        @ViewBuilder private func configuredModelRow(_ modelID: String) -> some View {
            let model = state.model(for: modelID)
            let frontierOption = OpenRouterFrontierOption(rawValue: modelID)
            HStack(spacing: 12) {
                Button { state.setDefault(modelID) } label: {
                    Image(systemName: state.modelConfiguration.defaultModelID == modelID ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(state.modelConfiguration.defaultModelID == modelID ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(state.modelConfiguration.defaultModelID == modelID ? "Default model" : "Make default model")

                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        model?.name ??
                            frontierOption?.fallbackModelID.openRouterShortDisplayName ??
                            modelID.openRouterShortDisplayName
                    )
                    Text(modelSubtitle(modelID: modelID, model: model, frontierOption: frontierOption))
                        .font(.caption)
                        .foregroundStyle(model == nil ? Color.orange : Color.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
        }

        private func modelSubtitle(
            modelID: String,
            model: OpenRouterModel?,
            frontierOption: OpenRouterFrontierOption?
        ) -> String {
            if let frontierOption {
                let resolvedID = model?.id ?? frontierOption.fallbackModelID
                return String(
                    format: String(localized: "Tracks %@ weekly · %@"),
                    frontierOption.providerName,
                    resolvedID
                )
            }
            return model.map { "\($0.providerName) · \($0.id)" } ??
                String(localized: "Unavailable in current catalog · \(modelID)")
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

private struct ModelPickerView: View {
    @ObservedObject var state: AIServiceSettings.StateModel
    @Environment(\.dismiss) private var dismiss
    @State private var models: [OpenRouterModel]
    @State private var searchText = ""
    @State private var selectedProvider = "All"
    @State private var favoritesOnly = false

    init(state: AIServiceSettings.StateModel) {
        _state = ObservedObject(wrappedValue: state)
        _models = State(initialValue: OpenRouterModelCatalogService.normalizedModels(state.catalogModels))
    }

    private var providers: [String] {
        ["All"] + Array(Set(models.map(\.providerName))).sorted()
    }

    private var filteredModels: [OpenRouterModel] {
        models
            .filter(\.isFoodAnalysisCompatible)
            .filter { selectedProvider == "All" || $0.providerName == selectedProvider }
            .filter { !favoritesOnly || state.favoriteModelIDs.contains($0.id) }
            .filter {
                searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) ||
                    $0.id.localizedCaseInsensitiveContains(searchText)
            }
            .sorted {
                let lhsFavorite = state.favoriteModelIDs.contains($0.id)
                let rhsFavorite = state.favoriteModelIDs.contains($1.id)
                guard lhsFavorite == rhsFavorite else { return lhsFavorite }
                let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                return nameOrder == .orderedSame ? $0.id < $1.id : nameOrder == .orderedAscending
            }
    }

    private var filteredFrontierOptions: [OpenRouterFrontierOption] {
        guard !favoritesOnly else { return [] }
        return OpenRouterFrontierOption.allCases.filter { option in
            let resolvedModel = state.model(for: option.rawValue)
            guard selectedProvider == "All" ||
                option.providerName.caseInsensitiveCompare(selectedProvider) == .orderedSame else { return false }
            return searchText.isEmpty ||
                option.title.localizedCaseInsensitiveContains(searchText) ||
                option.providerName.localizedCaseInsensitiveContains(searchText) ||
                option.fallbackModelID.openRouterShortDisplayName.localizedCaseInsensitiveContains(searchText) ||
                option.fallbackModelID.localizedCaseInsensitiveContains(searchText) ||
                resolvedModel?.name.localizedCaseInsensitiveContains(searchText) == true ||
                resolvedModel?.id.localizedCaseInsensitiveContains(searchText) == true
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let catalogError = state.catalogError {
                        Text(catalogError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }

                    ForEach(filteredFrontierOptions, id: \.rawValue) { option in
                        FrontierModelOptionRow(
                            option: option,
                            resolvedModel: state.model(for: option.rawValue),
                            isSelected: state.modelConfiguration.selectedModelIDs.contains(option.rawValue),
                            onSelect: {
                                state.addModel(option.rawValue)
                                dismiss()
                            }
                        )
                        .padding(.horizontal, 16)

                        Divider().padding(.leading, 70)
                    }

                    ForEach(filteredModels, id: \.id) { model in
                        ModelCatalogRow(
                            model: model,
                            isFavorite: state.favoriteModelIDs.contains(model.id),
                            isSelected: state.modelConfiguration.selectedModelIDs.contains(model.id),
                            onFavorite: { state.toggleFavorite(model.id) },
                            onSelect: {
                                state.addModel(model.id)
                                dismiss()
                            }
                        )
                        .padding(.horizontal, 16)

                        Divider().padding(.leading, 70)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .searchable(text: $searchText, prompt: "Search models")
            .navigationTitle("OpenRouter Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { favoritesOnly.toggle() } label: {
                        Image(systemName: favoritesOnly ? "star.fill" : "star")
                    }
                    Menu {
                        Picker("Provider", selection: $selectedProvider) {
                            ForEach(providers, id: \.self) { Text($0).tag($0) }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .overlay {
                if state.isLoadingCatalog, models.isEmpty {
                    ProgressView("Loading OpenRouter models…")
                } else if filteredFrontierOptions.isEmpty, filteredModels.isEmpty {
                    Text("No compatible models match these filters.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .task {
                guard models.isEmpty else { return }
                await state.refreshCatalog()
                models = OpenRouterModelCatalogService.normalizedModels(state.catalogModels)
            }
        }
    }
}

private struct FrontierModelOptionRow: View {
    let option: OpenRouterFrontierOption
    let resolvedModel: OpenRouterModel?
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(option.title).font(.headline)
                        Spacer()
                        if isSelected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }
                    Text(resolvedModel?.name ?? option.fallbackModelID.openRouterShortDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Updates from the cached OpenRouter catalog at most once a week.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSelected)
    }
}

private struct ModelCatalogRow: View {
    let model: OpenRouterModel
    let isFavorite: Bool
    let isSelected: Bool
    let onFavorite: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFavorite ? "Remove favorite" : "Add favorite")

            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(model.name).font(.headline)
                        Spacer()
                        if isSelected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }
                    Text(model.providerName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Label("Vision", systemImage: "eye")
                        Label("Structured", systemImage: "curlybraces")
                        if let context = model.contextLength {
                            Label("\(context / 1000)K", systemImage: "text.word.spacing")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    if let input = model.pricePerMillionTokens(model.pricing?.prompt),
                       let output = model.pricePerMillionTokens(model.pricing?.completion)
                    {
                        Text("$\(input) input / $\(output) output per 1M tokens")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let description = model.description, !description.isEmpty {
                        Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSelected)
        }
        .padding(.vertical, 3)
    }
}

private struct AIPromptSettingsView: View {
    private let supportingPrompts: [AIPromptSettings.Prompt] = [
        .foodImageAnalysis,
        .nutritionLabelExtraction,
        .singleItemCorrection,
        .nutritionLookupIntent,
        .conversationRefinement,
        .conversationImageReference,
        .restaurantClassification,
        .publishedNutritionSearch
    ]

    var body: some View {
        Section(
            header: Text("AI Prompts")
                .settingsSearchTarget(label: "AI Prompts"),
            footer: Text(
                "Streaming Food Analysis is the main image prompt. Food Description Context is its optional addendum when the user supplies more information."
            ),
            content: {
                NavigationLink {
                    AIPromptEditor(prompt: .streamingFoodAnalysis)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AIPromptSettings.Prompt.streamingFoodAnalysis.title)
                        Text("Primary prompt")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .settingsSearchTarget(label: AIPromptSettings.Prompt.streamingFoodAnalysis.title)

                NavigationLink {
                    AIPromptEditor(prompt: .foodUserContext)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AIPromptSettings.Prompt.foodUserContext.title)
                        Text("Optional description addendum")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .settingsSearchTarget(label: AIPromptSettings.Prompt.foodUserContext.title)
            }
        )
        .listRowBackground(Color.chart)

        Section(
            header: Text("Supporting Prompts"),
            footer: Text(
                "Used for corrections, conversation, intent detection, and restaurant or published-nutrition workflows."
            ),
            content: {
                ForEach(supportingPrompts) { prompt in
                    NavigationLink(prompt.title) {
                        AIPromptEditor(prompt: prompt)
                    }
                    .settingsSearchTarget(label: prompt.title)
                }
            }
        )
        .listRowBackground(Color.chart)
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
