import Foundation

enum OpenRouterFrontierOption: String, CaseIterable {
    case openAI = "trio/latest-openai-frontier"
    case anthropic = "trio/latest-anthropic-frontier"

    var title: String {
        switch self {
        case .openAI: String(localized: "Latest OpenAI frontier model")
        case .anthropic: String(localized: "Latest Anthropic frontier model")
        }
    }

    var providerName: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        }
    }

    var fallbackModelID: String {
        switch self {
        case .openAI: OpenRouterModels.fallbackOpenAIFrontierModelID
        case .anthropic: OpenRouterModels.fallbackAnthropicFrontierModelID
        }
    }
}

struct ResolvedOpenRouterModelConfiguration: Equatable {
    let selectedModelIDs: [String]
    let defaultModelID: String
    let initialModelIDs: [String]
}

enum OpenRouterFrontierModelResolver {
    static func model(for option: OpenRouterFrontierOption, in models: [OpenRouterModel]) -> OpenRouterModel? {
        let compatible = models.filter { model in
            model.isFoodAnalysisCompatible &&
                !model.id.contains(":") &&
                model.id.hasPrefix(option == .openAI ? "openai/" : "anthropic/")
        }

        let preferred: [OpenRouterModel]
        switch option {
        case .openAI:
            preferred = compatible.filter(isOpenAIFlagship)
        case .anthropic:
            preferred = compatible.filter { $0.id.hasPrefix("anthropic/claude-opus-") }
        }

        return newest(in: preferred) ?? newest(in: compatible.filter(isGeneralPurposeFallback))
    }

    static func modelID(for selectionID: String, in models: [OpenRouterModel]) -> String {
        guard let option = OpenRouterFrontierOption(rawValue: selectionID) else { return selectionID }
        return model(for: option, in: models)?.id ?? option.fallbackModelID
    }

    static func resolve(
        _ configuration: OpenRouterModelConfiguration,
        using models: [OpenRouterModel]
    ) -> ResolvedOpenRouterModelConfiguration {
        var seen = Set<String>()
        let selected = configuration.selectedModelIDs
            .map { modelID(for: $0, in: models) }
            .filter { seen.insert($0).inserted }
        let resolvedDefault = modelID(for: configuration.defaultModelID, in: models)
        let defaultModelID = selected.contains(resolvedDefault) ? resolvedDefault : selected[0]
        let initialModelIDs = configuration.runAllModelsSimultaneously ? selected : [defaultModelID]
        return ResolvedOpenRouterModelConfiguration(
            selectedModelIDs: selected,
            defaultModelID: defaultModelID,
            initialModelIDs: initialModelIDs
        )
    }

    static func resolveRefreshingCatalog(
        _ configuration: OpenRouterModelConfiguration
    ) async -> ResolvedOpenRouterModelConfiguration {
        let catalogService = OpenRouterModelCatalogService.shared
        let models = (try? await catalogService.loadModels()) ?? catalogService.cachedModels
        return resolve(configuration, using: models)
    }

    private static func isOpenAIFlagship(_ model: OpenRouterModel) -> Bool {
        let description = model.description?.lowercased() ?? ""
        guard !description.contains("below the flagship"),
              !description.contains("between the flagship") else { return false }
        return description.contains("openai's flagship model") ||
            description.contains("openai’s flagship model") ||
            description.contains("flagship model in openai")
    }

    private static func isGeneralPurposeFallback(_ model: OpenRouterModel) -> Bool {
        let id = model.id.lowercased()
        let excludedTerms = [
            "mini", "nano", "luna", "terra", "codex", "chat", "search", "realtime", "audio", "image"
        ]
        return !excludedTerms.contains(where: id.contains)
    }

    private static func newest(in models: [OpenRouterModel]) -> OpenRouterModel? {
        models.max {
            if $0.created == $1.created { return $0.id < $1.id }
            return ($0.created ?? 0) < ($1.created ?? 0)
        }
    }
}
