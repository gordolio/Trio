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
    func analyzeFoodStreaming(
        imageData: Data,
        userDescription: String?,
        sessionID: String?
    ) -> AsyncThrowingStream<PartialFoodAnalysisResult, Error>
    func refineFoodAnalysisStreaming(
        imageData: Data,
        initialResponse: AIFoodItemsResponseWithReasoning,
        userDescription: String,
        sessionID: String
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

/// Creates OpenRouter services bound to one stable model ID.
enum AIServiceRegistry {
    static var chat: AIProviderService {
        chat(for: currentModelID())
    }

    static var responses: AIResponsesProviderService {
        responses(for: currentModelID())
    }

    static func chat(for modelID: String) -> AIProviderService {
        OpenRouterService(modelID: modelID)
    }

    static func responses(for modelID: String) -> AIResponsesProviderService {
        OpenRouterResponsesService(modelID: modelID)
    }

    private static func currentModelID() -> String {
        let storage = BaseFileStorage()
        let settings = storage.retrieve(OpenAPS.Trio.settings, as: TrioSettings.self)
        return settings?.openRouterModelConfiguration.defaultModelID ?? OpenRouterModels.defaultModelID
    }
}
