import Foundation

// MARK: - Shared Domain Types

/// Result of classifying whether a user message is requesting a nutrition lookup.
/// Domain-level type shared across all AI providers.
struct NutritionLookupIntent: Decodable {
    /// Whether the user is asking to look up/find/search for published nutrition data
    let isNutritionLookup: Bool
    /// The menu item name to look up (if applicable)
    let menuItemName: String
}

// MARK: - Provider Protocols

/// Chat-style AI operations used for food image analysis and conversational refinement.
/// Implementations must produce domain responses that are identical regardless of provider.
protocol AIProviderService {
    func estimateCarbsMultiItem(from imageData: Data) async throws -> AIFoodItemsResponse
    func estimateCarbs(from imageData: Data) async throws -> OpenAICarbEstimateResponse
    func analyzeFood(imageData: Data, userDescription: String?) async throws -> AIFoodItemsResponseWithReasoning
    func analyzeFoodStreaming(
        imageData: Data,
        userDescription: String?
    ) -> AsyncThrowingStream<PartialFoodAnalysisResult, Error>
    func updateSingleItem(
        imageData: Data,
        currentItems: [AIFoodItem],
        editedItemId: UUID,
        newDescription: String
    ) async throws -> AISingleItemUpdateResponse
    func conversationTurn(
        imageData: Data,
        currentItems: [AIFoodItem],
        conversationHistory: [AIConversationMessage],
        userMessage: String
    ) async throws -> AIConversationResponse
    func classifyNutritionLookupIntent(
        userMessage: String,
        currentItems: [AIFoodItem],
        restaurantName: String
    ) async throws -> NutritionLookupIntent
}

/// Web-search–powered operations used for published nutrition lookup.
protocol AIResponsesProviderService {
    func classifyRestaurantItem(description: String) async throws -> RestaurantClassifierResponse
    func searchPublishedNutrition(
        restaurantName: String,
        menuItemName: String
    ) async throws -> PublishedNutritionResult
}

// MARK: - Registry

/// Routes AI calls through OpenRouter.
enum AIServiceRegistry {
    static var chat: AIProviderService {
        chat(for: currentProvider())
    }

    static var responses: AIResponsesProviderService {
        responses(for: currentProvider())
    }

    static func chat(for provider: AIProviderType) -> AIProviderService {
        switch provider {
        case .openrouter: return OpenRouterService.shared
        }
    }

    static func responses(for provider: AIProviderType) -> AIResponsesProviderService {
        switch provider {
        case .openrouter: return OpenRouterResponsesService.shared
        }
    }

    /// Reads the persisted provider choice, falling back to OpenRouter.
    private static func currentProvider() -> AIProviderType {
        let storage = BaseFileStorage()
        let settings = storage.retrieve(OpenAPS.Trio.settings, as: TrioSettings.self)
        return settings?.aiProvider ?? .openrouter
    }
}
