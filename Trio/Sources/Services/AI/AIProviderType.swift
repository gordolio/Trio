import Foundation

enum OpenRouterModels {
    static let defaultModelID = OpenRouterFrontierOption.openAI.rawValue
    static let defaultModelIDs = OpenRouterFrontierOption.allCases.map(\.rawValue)
    static let fallbackOpenAIFrontierModelID = "openai/gpt-6-astra"
    static let fallbackAnthropicFrontierModelID = "anthropic/claude-opus-5.5"
    static let legacyOpenAIModelID = "openai/gpt-4o"
    static let legacyClaudeModelID = "anthropic/claude-opus-4.5"
    /// Utility classifiers are text-only and intentionally independent of the selected analysis model.
    static let utilityModelID = "openai/gpt-4o-mini"
}

/// Retained only to migrate the legacy two-provider setting.
enum AIProviderType: String, JSON {
    case openai
    case claude

    var modelID: String {
        switch self {
        case .openai: OpenRouterModels.defaultModelID
        case .claude: OpenRouterFrontierOption.anthropic.rawValue
        }
    }
}

struct OpenRouterModelConfiguration: JSON, Equatable {
    static let maximumModelCount = 4
    static let currentMigrationVersion = 1

    private(set) var selectedModelIDs: [String]
    private(set) var defaultModelID: String
    var runAllModelsSimultaneously: Bool
    private let migrationVersion: Int

    var initialModelIDs: [String] {
        runAllModelsSimultaneously ? selectedModelIDs : [defaultModelID]
    }

    enum CodingKeys: String, CodingKey {
        case selectedModelIDs
        case defaultModelID
        case runAllModelsSimultaneously
        case migrationVersion
    }

    init(
        selectedModelIDs: [String] = OpenRouterModels.defaultModelIDs,
        defaultModelID: String = OpenRouterModels.defaultModelID,
        runAllModelsSimultaneously: Bool = false,
        migrationVersion: Int = Self.currentMigrationVersion
    ) {
        var seen = Set<String>()
        let normalized = selectedModelIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        self.selectedModelIDs = Array(normalized.prefix(Self.maximumModelCount))
        if self.selectedModelIDs.isEmpty {
            self.selectedModelIDs = [OpenRouterModels.defaultModelID]
        }
        self.defaultModelID = self.selectedModelIDs.contains(defaultModelID) ? defaultModelID : self.selectedModelIDs[0]
        self.runAllModelsSimultaneously = runAllModelsSimultaneously
        self.migrationVersion = migrationVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let migrationVersion = try container.decodeIfPresent(Int.self, forKey: .migrationVersion) ?? 0
        guard migrationVersion >= Self.currentMigrationVersion else {
            self.init()
            return
        }
        self.init(
            selectedModelIDs: try container.decode([String].self, forKey: .selectedModelIDs),
            defaultModelID: try container.decode(String.self, forKey: .defaultModelID),
            runAllModelsSimultaneously: try container.decodeIfPresent(
                Bool.self,
                forKey: .runAllModelsSimultaneously
            ) ?? false,
            migrationVersion: migrationVersion
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(selectedModelIDs, forKey: .selectedModelIDs)
        try container.encode(defaultModelID, forKey: .defaultModelID)
        try container.encode(runAllModelsSimultaneously, forKey: .runAllModelsSimultaneously)
        try container.encode(migrationVersion, forKey: .migrationVersion)
    }

    @discardableResult mutating func add(_ modelID: String) -> Bool {
        guard selectedModelIDs.count < Self.maximumModelCount,
              !selectedModelIDs.contains(modelID), !modelID.isEmpty else { return false }
        selectedModelIDs.append(modelID)
        return true
    }

    @discardableResult mutating func remove(_ modelID: String) -> Bool {
        guard selectedModelIDs.count > 1,
              let index = selectedModelIDs.firstIndex(of: modelID) else { return false }
        selectedModelIDs.remove(at: index)
        if defaultModelID == modelID {
            defaultModelID = selectedModelIDs[min(index, selectedModelIDs.count - 1)]
        }
        return true
    }

    mutating func move(fromOffsets: IndexSet, toOffset: Int) {
        let moving = fromOffsets.sorted().map { selectedModelIDs[$0] }
        for index in fromOffsets.sorted(by: >) { selectedModelIDs.remove(at: index) }
        let removedBeforeDestination = fromOffsets.filter { $0 < toOffset }.count
        selectedModelIDs.insert(contentsOf: moving, at: min(toOffset - removedBeforeDestination, selectedModelIDs.count))
    }

    @discardableResult mutating func setDefault(_ modelID: String) -> Bool {
        guard selectedModelIDs.contains(modelID) else { return false }
        defaultModelID = modelID
        return true
    }
}

struct OpenRouterModel: JSON, Identifiable, Equatable {
    struct Architecture: JSON, Equatable {
        let inputModalities: [String]?
        let outputModalities: [String]?

        enum CodingKeys: String, CodingKey {
            case inputModalities = "input_modalities"
            case outputModalities = "output_modalities"
        }
    }

    struct Pricing: JSON, Equatable {
        let prompt: String?
        let completion: String?
    }

    let id: String
    let name: String
    let description: String?
    let contextLength: Int?
    let architecture: Architecture?
    let pricing: Pricing?
    let supportedParameters: [String]?
    let created: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case architecture
        case pricing
        case contextLength = "context_length"
        case supportedParameters = "supported_parameters"
        case created
    }

    var providerName: String { id.openRouterProviderName }
    var shortDisplayName: String { id.openRouterShortDisplayName }

    var supportsImages: Bool {
        architecture?.inputModalities?.contains(where: { $0.lowercased() == "image" }) == true
    }

    var supportsStructuredResponses: Bool {
        let parameters = supportedParameters?.map { $0.lowercased() } ?? []
        return parameters.contains("response_format") || parameters.contains("structured_outputs")
    }

    var supportsTools: Bool {
        supportedParameters?.contains(where: { $0.lowercased() == "tools" }) == true
    }

    var isFoodAnalysisCompatible: Bool { supportsImages && supportsStructuredResponses }

    func pricePerMillionTokens(_ value: String?) -> String? {
        guard let value, let decimal = Decimal(string: value), decimal >= 0 else { return nil }
        return NSDecimalNumber(decimal: decimal * 1_000_000).stringValue
    }
}

struct OpenRouterModelCatalogResponse: JSON {
    let data: [OpenRouterModel]
}

final class OpenRouterModelCatalogService {
    private struct Cache: Codable {
        let models: [OpenRouterModel]
        let savedAt: Date
    }

    static let shared = OpenRouterModelCatalogService()
    static let refreshInterval: TimeInterval = 7 * 24 * 60 * 60

    private let endpoint = URL(string: "https://openrouter.ai/api/v1/models")!
    private let cacheKey = "OpenRouterModelCatalog.v1"
    private let favoritesKey = "OpenRouterFavoriteModelIDs.v1"
    private let session: URLSession
    private let defaults: UserDefaults

    init(session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
    }

    var cachedModels: [OpenRouterModel] {
        guard let data = defaults.data(forKey: cacheKey),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return [] }
        return Self.normalizedModels(cache.models)
    }

    func cacheIsFresh(at now: Date = Date()) -> Bool {
        guard let data = defaults.data(forKey: cacheKey),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return false }
        return now.timeIntervalSince(cache.savedAt) < Self.refreshInterval
    }

    var favoriteModelIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: favoritesKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: favoritesKey) }
    }

    func loadModels(forceRefresh: Bool = false, now: Date = Date()) async throws -> [OpenRouterModel] {
        if !forceRefresh, cacheIsFresh(at: now) { return cachedModels }

        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            throw OpenAIServiceError.invalidResponse(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let decodedModels = try JSONDecoder().decode(OpenRouterModelCatalogResponse.self, from: data).data
        let models = Self.normalizedModels(decodedModels)
        guard !models.isEmpty else { throw OpenAIServiceError.invalidResponse(statusCode: httpResponse.statusCode) }
        if let cache = try? JSONEncoder().encode(Cache(models: models, savedAt: now)) {
            defaults.set(cache, forKey: cacheKey)
        }
        return models
    }

    static func normalizedModels(_ models: [OpenRouterModel]) -> [OpenRouterModel] {
        var seen = Set<String>()
        return models.filter { model in
            let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            return !id.isEmpty && seen.insert(model.id).inserted
        }
    }
}

extension String {
    var openRouterProviderName: String {
        split(separator: "/", maxSplits: 1).first.map(String.init)?.capitalized ?? String(localized: "Unknown")
    }

    var openRouterShortDisplayName: String {
        let component = split(separator: "/", maxSplits: 1).last.map(String.init) ?? self
        return component.replacingOccurrences(of: "-", with: " ").capitalized
    }
}
