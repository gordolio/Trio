import Foundation
import os.log

// MARK: - Classifier Response Model

/// Response from the restaurant classifier agent
struct RestaurantClassifierResponse: Codable {
    /// Whether the description mentions a restaurant/chain/brand food item
    let isRestaurantItem: Bool
    /// Name of the restaurant or brand (e.g., "McDonald's")
    let restaurantName: String
    /// Specific menu item name (e.g., "Big Mac")
    let menuItemName: String
    /// Confidence in the classification (0.0 - 1.0)
    let confidence: Double
}

// MARK: - Published Nutrition Result Model

/// Nutrition facts retrieved from published sources via web search
struct PublishedNutritionResult: Codable {
    /// Name of the restaurant or brand
    let restaurantName: String
    /// Name of the menu item
    let menuItemName: String
    /// Carbohydrates in grams
    let carbs: Double
    /// Fat in grams
    let fat: Double
    /// Protein in grams
    let protein: Double
    /// Calories
    let calories: Double
    /// URL of the source where nutrition facts were found
    let sourceURL: String
    /// Confidence that the result matches the query (0.0 - 1.0)
    let confidence: Double
    /// Number of individual items in one serving (e.g., 8 for an 8-count nugget). Defaults to 1.
    let servingCount: Double
    /// Unit for the serving count (e.g., "Nuggets", "Pieces"). Defaults to "Serving".
    let servingCountUnit: String
}

// MARK: - OpenRouter Web Search Types

private struct OpenRouterWebSearchRequest: Encodable {
    let model: String
    let messages: [OpenAIMessage]
    let maxTokens: Int
    let responseFormat: OpenAIResponseFormat
    let tools: [OpenRouterServerTool]

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
        case tools
    }
}

private struct OpenRouterServerTool: Encodable {
    let type: String
    let parameters: OpenRouterWebSearchParameters
}

private struct OpenRouterWebSearchParameters: Encodable {
    let engine: String
    let maxResults: Int

    enum CodingKeys: String, CodingKey {
        case engine
        case maxResults = "max_results"
    }
}

private struct OpenRouterChatResponse: Decodable {
    let choices: [OpenRouterChoice]
}

private struct OpenRouterChoice: Decodable {
    let message: OpenRouterResponseMessage
}

private struct OpenRouterResponseMessage: Decodable {
    let content: String?
    let annotations: [OpenRouterAnnotation]?
}

private struct OpenRouterAnnotation: Decodable {
    let type: String
    let urlCitation: OpenRouterURLCitation?

    enum CodingKeys: String, CodingKey {
        case type
        case urlCitation = "url_citation"
    }
}

private struct OpenRouterURLCitation: Decodable {
    let url: String
}

/// Internal response structure for parsing the nutrition search result
private struct NutritionSearchResponse: Decodable {
    let restaurantName: String
    let menuItemName: String
    let carbs: Double
    let fat: Double
    let protein: Double
    let calories: Double
    let sourceURL: String
    let confidence: Double
    let servingCount: Double
    let servingCountUnit: String
}

// MARK: - OpenRouter Responses Service

/// Service for restaurant food detection and published nutrition lookup.
final class OpenRouterResponsesService: AIResponsesProviderService {
    private let log = OSLog(subsystem: "com.loopkit.Loop", category: "OpenRouterResponsesService")
    private let session: URLSession
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let modelID: String

    init(modelID: String, session: URLSession = .shared) {
        self.modelID = modelID
        self.session = session
    }

    private func getAPIKey() throws -> String {
        guard let apiKey = Bundle.main.object(forInfoDictionaryKey: "OpenRouterAPIKey") as? String,
              !apiKey.isEmpty,
              apiKey != "$(OPENROUTER_API_KEY)"
        else {
            os_log("OpenRouter API key not configured", log: log, type: .error)
            throw OpenAIServiceError.missingAPIKey
        }
        return apiKey
    }

    // MARK: - Agent 1: Restaurant Classifier

    /// Classifies whether a user description mentions a restaurant/chain/brand food item.
    /// Uses gpt-4o-mini for speed and cost efficiency. Text-only, no image.
    func classifyRestaurantItem(description: String) async throws -> RestaurantClassifierResponse {
        let apiKey = try getAPIKey()

        os_log("Classifying description for restaurant item: %{public}@", log: log, type: .info, description)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemPrompt = AIPromptSettings.Prompt.restaurantClassification.value

        let chatRequest = OpenAIChatRequest(
            model: OpenRouterModels.utilityModelID,
            messages: [
                OpenAIMessage(role: "system", content: [.text(systemPrompt)]),
                OpenAIMessage(role: "user", content: [.text(description)])
            ],
            maxTokens: 200,
            responseFormat: OpenAIResponseFormat(
                type: "json_schema",
                jsonSchema: OpenAIJSONSchema(
                    name: "restaurant_classifier",
                    strict: true,
                    schema: buildClassifierSchema()
                )
            )
        )

        request.httpBody = try encoder.encode(chatRequest)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIServiceError.invalidResponse(statusCode: 0)
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            os_log("Classifier API error: status %d", log: log, type: .error, httpResponse.statusCode)
            throw mapAIHTTPError(statusCode: httpResponse.statusCode, body: data)
        }

        let chatResponse = try decoder.decode(OpenAIChatResponse.self, from: data)

        guard let content = chatResponse.choices.first?.message.content,
              let contentData = content.data(using: .utf8)
        else {
            throw OpenAIServiceError.noContentInResponse
        }

        let result = try decoder.decode(RestaurantClassifierResponse.self, from: contentData)

        os_log(
            "Classification result: isRestaurant=%{public}@, restaurant=%{public}@, item=%{public}@, confidence=%.2f",
            log: log, type: .info,
            result.isRestaurantItem ? "yes" : "no",
            result.restaurantName,
            result.menuItemName,
            result.confidence
        )

        return result
    }

    // MARK: - Agent 2: Published Nutrition Searcher

    /// Searches for published nutrition facts using OpenRouter's web-search server tool.
    func searchPublishedNutrition(
        restaurantName: String,
        menuItemName: String
    ) async throws -> PublishedNutritionResult {
        let catalog = OpenRouterModelCatalogService.shared.cachedModels
        if !catalog.isEmpty,
           catalog.first(where: { $0.id == modelID })?.supportsTools != true
        {
            throw OpenAIServiceError.incompatibleModel(modelID)
        }
        let apiKey = try getAPIKey()

        os_log(
            "Searching published nutrition for %{public}@ - %{public}@",
            log: log, type: .info,
            restaurantName, menuItemName
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let inputPrompt = AIPromptSettings.Prompt.publishedNutritionSearch.rendered([
            "menuItemName": menuItemName,
            "restaurantName": restaurantName,
            "restaurantDomain": restaurantName.lowercased()
        ])

        let searchRequest = OpenRouterWebSearchRequest(
            model: modelID,
            messages: [OpenAIMessage(role: "user", content: [.text(inputPrompt)])],
            maxTokens: 2000,
            responseFormat: OpenAIResponseFormat(
                type: "json_schema",
                jsonSchema: OpenAIJSONSchema(
                    name: "published_nutrition",
                    strict: true,
                    schema: buildNutritionSearchSchema()
                )
            ),
            tools: [
                OpenRouterServerTool(
                    type: "openrouter:web_search",
                    parameters: OpenRouterWebSearchParameters(engine: "auto", maxResults: 5)
                )
            ]
        )

        request.httpBody = try encoder.encode(searchRequest)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIServiceError.invalidResponse(statusCode: 0)
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            os_log("Nutrition search API error: status %d", log: log, type: .error, httpResponse.statusCode)
            if let errorBody = String(data: data, encoding: .utf8) {
                os_log("Error body: %{public}@", log: log, type: .error, errorBody)
            }
            throw mapAIHTTPError(statusCode: httpResponse.statusCode, body: data)
        }

        return try parseNutritionSearchResponse(data)
    }

    // MARK: - Schema Builders

    private func buildClassifierSchema() -> JSONSchemaDefinition {
        JSONSchemaDefinition(
            type: "object",
            properties: [
                "isRestaurantItem": .boolean(
                    description: "Whether the text describes a restaurant/chain/brand menu item with published nutrition"
                ),
                "restaurantName": .string(
                    description: "Name of the restaurant or brand, or empty string if not a restaurant item"
                ),
                "menuItemName": .string(
                    description: "Specific menu item name, or empty string if not a restaurant item"
                ),
                "confidence": .number(
                    description: "Confidence in the classification (0.0-1.0)"
                )
            ],
            required: ["isRestaurantItem", "restaurantName", "menuItemName", "confidence"],
            additionalProperties: false
        )
    }

    private func buildNutritionSearchSchema() -> JSONSchemaDefinition {
        JSONSchemaDefinition(
            type: "object",
            properties: [
                "restaurantName": .string(description: "Name of the restaurant or brand"),
                "menuItemName": .string(description: "Name of the menu item only, without the restaurant or brand name"),
                "carbs": .number(description: "Total carbohydrates in grams"),
                "fat": .number(description: "Total fat in grams"),
                "protein": .number(description: "Protein in grams"),
                "calories": .number(description: "Total calories"),
                "sourceURL": .string(
                    description: "The URL of the webpage where the nutrition facts were found (e.g., the restaurant's official nutrition page)"
                ),
                "confidence": .number(
                    description: "Confidence that the result matches the query (0.0-1.0). Use lower values if the exact item wasn't found."
                ),
                "servingCount": .number(
                    description: "Number of individual items in one serving (e.g., 8 for an 8-count nugget, 1 for a single sandwich). Use 1 if not applicable."
                ),
                "servingCountUnit": .string(
                    description: "Unit for the serving count (e.g., 'Nuggets', 'Pieces'). Use 'Serving' if not countable."
                )
            ],
            required: [
                "restaurantName", "menuItemName", "carbs", "fat", "protein", "calories", "sourceURL",
                "confidence", "servingCount", "servingCountUnit"
            ],
            additionalProperties: false
        )
    }

    // MARK: - Response Parsing

    private func parseNutritionSearchResponse(_ data: Data) throws -> PublishedNutritionResult {
        let response: OpenRouterChatResponse
        do {
            response = try decoder.decode(OpenRouterChatResponse.self, from: data)
        } catch {
            os_log("Failed to decode OpenRouter response: %{public}@", log: log, type: .error, error.localizedDescription)
            throw OpenAIServiceError.decodingError(error)
        }

        guard let message = response.choices.first?.message,
              let content = message.content,
              let contentData = content.data(using: .utf8)
        else {
            throw OpenAIServiceError.noContentInResponse
        }

        let citationURL = message.annotations?
            .first(where: { $0.type == "url_citation" })?
            .urlCitation?.url

        let nutrition: NutritionSearchResponse
        do {
            nutrition = try decoder.decode(NutritionSearchResponse.self, from: contentData)
        } catch {
            os_log("Failed to decode nutrition search content: %{public}@", log: log, type: .error, error.localizedDescription)
            throw OpenAIServiceError.decodingError(error)
        }

        os_log(
            "Found published nutrition: %{public}@ %{public}@ - carbs: %.0fg, fat: %.0fg, protein: %.0fg, cal: %.0f",
            log: log, type: .info,
            nutrition.restaurantName, nutrition.menuItemName,
            nutrition.carbs, nutrition.fat, nutrition.protein, nutrition.calories
        )

        // Prefer the LLM-provided sourceURL (from JSON schema), fall back to annotation citation
        let finalSourceURL: String
        if !nutrition.sourceURL.isEmpty {
            finalSourceURL = nutrition.sourceURL
        } else {
            finalSourceURL = citationURL ?? ""
        }
        os_log("Final sourceURL: %{public}@", log: log, type: .info, finalSourceURL)

        return PublishedNutritionResult(
            restaurantName: nutrition.restaurantName,
            menuItemName: nutrition.menuItemName,
            carbs: nutrition.carbs,
            fat: nutrition.fat,
            protein: nutrition.protein,
            calories: nutrition.calories,
            sourceURL: finalSourceURL,
            confidence: nutrition.confidence,
            servingCount: nutrition.servingCount,
            servingCountUnit: nutrition.servingCountUnit
        )
    }
}
