import Foundation
import os.log

// MARK: - Error Types

/// Errors that can occur during AI API operations.
enum OpenAIServiceError: LocalizedError {
    case missingAPIKey
    case invalidImageData
    case networkError(Error)
    case invalidResponse(statusCode: Int)
    case decodingError(Error)
    case noContentInResponse
    /// The OpenRouter account is out of credit.
    case insufficientCredits

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return NSLocalizedString("OpenRouter API key is not configured", comment: "Error when OpenRouter API key is missing")
        case .invalidImageData:
            return NSLocalizedString("Unable to process the selected image", comment: "Error when image data is invalid")
        case let .networkError(error):
            return String(
                format: NSLocalizedString("Network error: %@", comment: "Network error with description"),
                error.localizedDescription
            )
        case let .invalidResponse(statusCode):
            return String(
                format: NSLocalizedString("Server returned error (status %d)", comment: "Server error with status code"),
                statusCode
            )
        case .decodingError:
            return NSLocalizedString("Unable to parse the AI response", comment: "Error when response parsing fails")
        case .noContentInResponse:
            return NSLocalizedString("No content returned from AI", comment: "Error when AI returns empty response")
        case .insufficientCredits:
            return NSLocalizedString(
                "The AI provider is out of credits.",
                comment: "Error shown when an AI provider responds with an out-of-credits signal"
            )
        }
    }
}

/// Inspects an HTTP error for an "out of credits" signal.
/// Falls back to `.invalidResponse(statusCode:)` for every other non-2xx response.
func mapAIHTTPError(statusCode: Int, body: Data) -> OpenAIServiceError {
    if statusCode == 402 {
        return .insufficientCredits
    }

    if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
       let error = json["error"] as? [String: Any]
    {
        let code = (error["code"] as? String) ?? ""
        let message = ((error["message"] as? String) ?? "").lowercased()

        if code == "insufficient_quota" || message.contains("credit balance") ||
            message.contains("payment required")
        {
            return .insufficientCredits
        }
    }
    return .invalidResponse(statusCode: statusCode)
}

// MARK: - OpenAI API Request Types (Codable)

/// Root request body for OpenAI Chat Completions API
struct OpenAIChatRequest: Encodable {
    let model: String
    let messages: [OpenAIMessage]
    let maxTokens: Int
    let responseFormat: OpenAIResponseFormat?
    let stream: Bool?

    init(
        model: String,
        messages: [OpenAIMessage],
        maxTokens: Int,
        responseFormat: OpenAIResponseFormat?,
        stream: Bool? = nil
    ) {
        self.model = model
        self.messages = messages
        self.maxTokens = maxTokens
        self.responseFormat = responseFormat
        self.stream = stream
    }

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
        case stream
    }
}

/// A message in the OpenAI chat conversation
struct OpenAIMessage: Encodable {
    let role: String
    let content: [OpenAIMessageContent]
}

/// Content item within a message (text or image)
enum OpenAIMessageContent: Encodable {
    case text(String)
    case imageUrl(OpenAIImageUrl)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .imageUrl(imageUrl):
            try container.encode("image_url", forKey: .type)
            try container.encode(imageUrl, forKey: .imageUrl)
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageUrl = "image_url"
    }
}

/// Image URL content for vision API
struct OpenAIImageUrl: Encodable {
    let url: String
}

/// Response format specification for structured outputs
struct OpenAIResponseFormat: Encodable {
    let type: String
    let jsonSchema: OpenAIJSONSchema

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }
}

/// JSON Schema specification for structured outputs
struct OpenAIJSONSchema: Encodable {
    let name: String
    let strict: Bool
    let schema: JSONSchemaDefinition
}

/// JSON Schema definition (supports nested object definitions)
struct JSONSchemaDefinition: Encodable {
    let type: String
    let properties: [String: JSONSchemaProperty]?
    let required: [String]?
    let items: JSONSchemaProperty?
    let additionalProperties: Bool?
    let `enum`: [String]?
    let description: String?

    init(
        type: String,
        properties: [String: JSONSchemaProperty]? = nil,
        required: [String]? = nil,
        items: JSONSchemaProperty? = nil,
        additionalProperties: Bool? = nil,
        enum enumValues: [String]? = nil,
        description: String? = nil
    ) {
        self.type = type
        self.properties = properties
        self.required = required
        self.items = items
        self.additionalProperties = additionalProperties
        self.enum = enumValues
        self.description = description
    }

    enum CodingKeys: String, CodingKey {
        case type
        case properties
        case required
        case items
        case additionalProperties
        case `enum`
        case description
    }
}

/// Property definition within a JSON schema
indirect enum JSONSchemaProperty: Encodable {
    case string(description: String? = nil)
    case number(description: String? = nil)
    case boolean(description: String? = nil)
    case `enum`(values: [String], description: String? = nil)
    case array(items: JSONSchemaProperty, description: String? = nil)
    case object(properties: [String: JSONSchemaProperty], required: [String], description: String? = nil)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .string(description):
            try container.encode("string", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)

        case let .number(description):
            try container.encode("number", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)

        case let .boolean(description):
            try container.encode("boolean", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)

        case let .enum(values, description):
            try container.encode("string", forKey: .type)
            try container.encode(values, forKey: .enumValues)
            try container.encodeIfPresent(description, forKey: .description)

        case let .array(items, description):
            try container.encode("array", forKey: .type)
            try container.encode(items, forKey: .items)
            try container.encodeIfPresent(description, forKey: .description)

        case let .object(properties, required, description):
            try container.encode("object", forKey: .type)
            try container.encode(properties, forKey: .properties)
            try container.encode(required, forKey: .required)
            try container.encode(false, forKey: .additionalProperties)
            try container.encodeIfPresent(description, forKey: .description)
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case description
        case enumValues = "enum"
        case items
        case properties
        case required
        case additionalProperties
    }
}

// MARK: - OpenAI API Response Types (Codable)

/// Root response from OpenAI Chat Completions API
struct OpenAIChatResponse: Decodable {
    let id: String
    let choices: [OpenAIChoice]
    let usage: OpenAIUsage?
}

/// A choice in the API response
struct OpenAIChoice: Decodable {
    let index: Int
    let message: OpenAIResponseMessage
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index
        case message
        case finishReason = "finish_reason"
    }
}

/// Message content in the response
struct OpenAIResponseMessage: Decodable {
    let role: String
    let content: String?
}

/// Token usage information
struct OpenAIUsage: Decodable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

// MARK: - OpenAI Streaming Response Types

/// A single chunk from the OpenAI streaming API (SSE)
struct OpenAIStreamChunk: Decodable {
    let choices: [OpenAIStreamChoice]
}

/// A choice within a streaming chunk
struct OpenAIStreamChoice: Decodable {
    let delta: OpenAIStreamDelta
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
    }
}

/// Delta content in a streaming chunk
struct OpenAIStreamDelta: Decodable {
    let content: String?
}

// MARK: - AI Response Content Types (what we parse from the content field)

/// Response structure for multi-item food analysis (matches our JSON schema)
struct AIFoodAnalysisResponse: Decodable {
    let foodItems: [AIFoodItemResponse]
    let overallConfidence: Double
    let reasoning: String?
}

/// Response structure for multi-item food analysis with reasoning
struct AIFoodAnalysisWithReasoningResponse: Decodable {
    let foodItems: [AIFoodItemResponse]
    let overallConfidence: Double
    let reasoning: String
}

/// Response structure for single item update
struct AISingleItemUpdateAPIResponse: Decodable {
    let updatedCarbs: Double
    let reasoning: String
    let updatedFat: Double?
    let updatedProtein: Double?
}

/// Response structure for conversation turn
struct AIConversationTurnAPIResponse: Decodable {
    let foodItems: [AIFoodItemWithIdResponse]
    let updatedItemIds: [String]
    let assistantMessage: String
    let overallConfidence: Double
}

/// Individual food item in the AI response
struct AIFoodItemResponse: Decodable {
    let name: String
    let carbs: Double
    let emoji: String
    let fat: Double
    let protein: Double
    let servingCount: Double
    let servingUnit: String
}

/// Individual food item in conversation response (includes ID and source)
struct AIFoodItemWithIdResponse: Decodable {
    let id: String
    let name: String
    let carbs: Double
    let emoji: String
    let fat: Double
    let protein: Double
    let source: String?
    let servingCount: Double
    let servingUnit: String
}

/// Response from OpenAI Vision API containing carb estimate and food description (legacy single-item)
struct OpenAICarbEstimateResponse {
    let estimatedCarbs: Double
    let foodDescription: String
    let emoji: String
    let detailedDescription: String
    let fat: Double
    let protein: Double
    let carbConfidence: Double
    let emojiConfidence: Double
}

// MARK: - OpenRouter Service

/// Service for interacting with OpenRouter's OpenAI-compatible API.
final class OpenRouterService: AIProviderService {
    static let openAI = OpenRouterService(modelSet: AIProviderType.openai.modelSet)
    static let claude = OpenRouterService(modelSet: AIProviderType.claude.modelSet)

    private let log = OSLog(subsystem: "com.loopkit.Loop", category: "OpenRouterService")
    private let session: URLSession
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let modelSet: OpenRouterModelSet

    init(modelSet: OpenRouterModelSet, session: URLSession = .shared) {
        self.modelSet = modelSet
        self.session = session
    }

    /// Retrieves the OpenRouter API key from the app's Info.plist.
    private func getAPIKey() throws -> String {
        guard let apiKey = Bundle.main.object(forInfoDictionaryKey: "OpenRouterAPIKey") as? String,
              !apiKey.isEmpty,
              apiKey != "$(OPENROUTER_API_KEY)"
        else {
            os_log("OpenRouter API key not configured in ConfigOverride.xcconfig", log: log, type: .error)
            throw OpenAIServiceError.missingAPIKey
        }
        return apiKey
    }

    // MARK: - Multi-Item Food Analysis (Structured Outputs)

    /// Analyzes a food image and returns an array of individual food items detected
    /// Uses OpenAI Structured Outputs to guarantee response format
    /// - Parameter imageData: JPEG image data of the food to analyze
    /// - Returns: AIFoodItemsResponse containing all detected food items
    func estimateCarbsMultiItem(from imageData: Data) async throws -> AIFoodItemsResponse {
        let apiKey = try getAPIKey()
        let base64Image = imageData.base64EncodedString()

        os_log("Sending food image for multi-item AI analysis (%d bytes)", log: log, type: .info, imageData.count)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let defaultPrompt = """
        Analyze this food image for a diabetes insulin dosing app. Identify ALL individual food items visible and estimate total carbohydrate, fat, and protein content for each.

        IMPORTANT GUIDELINES:
        - List EACH distinct food item separately (e.g., for a meal with sandwich, apple, and drink - list all 3)
        - Include sides, drinks, sauces, and condiments as separate items
        - For composite items like sandwiches, list as one item but note components in the name
        - Estimate portion sizes based on visual cues
        - Choose 1-2 emojis per item that best represent it
        - Estimate fat and protein in grams for each item
        """
        let prompt = AIPromptSettings.foodAnalysisPrompt(fallback: defaultPrompt)

        // Build the request with structured output schema
        let chatRequest = OpenAIChatRequest(
            model: modelSet.primaryModel,
            messages: [
                OpenAIMessage(
                    role: "user",
                    content: [
                        .text(prompt),
                        .imageUrl(OpenAIImageUrl(url: "data:image/jpeg;base64,\(base64Image)"))
                    ]
                )
            ],
            maxTokens: 1000,
            responseFormat: OpenAIResponseFormat(
                type: "json_schema",
                jsonSchema: OpenAIJSONSchema(
                    name: "food_analysis",
                    strict: true,
                    schema: buildFoodAnalysisSchema()
                )
            )
        )

        request.httpBody = try encoder.encode(chatRequest)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIServiceError.invalidResponse(statusCode: 0)
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            os_log("OpenAI API error: status %d", log: log, type: .error, httpResponse.statusCode)
            if let errorBody = String(data: data, encoding: .utf8) {
                os_log("Error body: %{public}@", log: log, type: .error, errorBody)
            }
            throw mapAIHTTPError(statusCode: httpResponse.statusCode, body: data)
        }

        return try parseMultiItemResponse(data)
    }

    /// Builds the JSON schema for food analysis structured output
    private func buildFoodAnalysisSchema() -> JSONSchemaDefinition {
        let foodItemSchema = JSONSchemaProperty.object(
            properties: [
                "name": .string(description: "Concise item description, max 30 chars"),
                "carbs": .number(description: "Estimated total carbohydrates in grams (not net carbs)"),
                "emoji": .string(description: "1-2 food emojis representing the item"),
                "fat": .number(description: "Estimated fat in grams"),
                "protein": .number(description: "Estimated protein in grams")
            ],
            required: ["name", "carbs", "emoji", "fat", "protein"],
            description: "A single food item detected in the image"
        )

        return JSONSchemaDefinition(
            type: "object",
            properties: [
                "foodItems": .array(items: foodItemSchema, description: "Array of all food items detected"),
                "overallConfidence": .number(description: "Overall confidence in the analysis (0.0-1.0)")
            ],
            required: ["foodItems", "overallConfidence"],
            additionalProperties: false
        )
    }

    /// Parses the OpenAI API response for multi-item food analysis
    private func parseMultiItemResponse(_ data: Data) throws -> AIFoodItemsResponse {
        // First decode the outer OpenAI response structure
        let chatResponse: OpenAIChatResponse
        do {
            chatResponse = try decoder.decode(OpenAIChatResponse.self, from: data)
        } catch {
            os_log("Failed to decode OpenAI response: %{public}@", log: log, type: .error, error.localizedDescription)
            throw OpenAIServiceError.decodingError(error)
        }

        guard let content = chatResponse.choices.first?.message.content else {
            throw OpenAIServiceError.noContentInResponse
        }

        os_log("Received multi-item AI response content: %{public}@", log: log, type: .debug, content)

        // Decode the content JSON (guaranteed to match schema due to structured outputs)
        guard let contentData = content.data(using: .utf8) else {
            throw OpenAIServiceError
                .decodingError(NSError(
                    domain: "OpenAIService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid content encoding"]
                ))
        }

        let analysisResponse: AIFoodAnalysisResponse
        do {
            analysisResponse = try decoder.decode(AIFoodAnalysisResponse.self, from: contentData)
        } catch {
            os_log("Failed to decode food analysis: %{public}@", log: log, type: .error, error.localizedDescription)
            throw OpenAIServiceError.decodingError(error)
        }

        // Convert to our domain model
        let foodItems = analysisResponse.foodItems.map { item in
            AIFoodItem(
                name: item.name,
                carbs: item.carbs,
                emoji: item.emoji,
                fat: item.fat,
                protein: item.protein
            )
        }

        guard !foodItems.isEmpty else {
            throw OpenAIServiceError
                .decodingError(NSError(
                    domain: "OpenAIService",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "No food items found in response"]
                ))
        }

        os_log(
            "AI detected %d food items with total %.1f grams of carbs",
            log: log,
            type: .info,
            foodItems.count,
            foodItems.reduce(0) { $0 + $1.carbs }
        )

        return AIFoodItemsResponse(
            foodItems: foodItems,
            overallConfidence: analysisResponse.overallConfidence
        )
    }

    // MARK: - Legacy Single-Item Analysis (kept for backwards compatibility)

    /// Analyzes a food image and returns estimated carbohydrate content
    /// - Parameter imageData: JPEG image data of the food to analyze
    /// - Returns: OpenAICarbEstimateResponse containing carb estimate and description
    func estimateCarbs(from imageData: Data) async throws -> OpenAICarbEstimateResponse {
        let apiKey = try getAPIKey()
        let base64Image = imageData.base64EncodedString()

        os_log("Sending food image for AI analysis (%d bytes)", log: log, type: .info, imageData.count)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompt = """
        Analyze this food image for a diabetes insulin dosing app. Estimate total carbohydrate, fat, and protein content.

        EMOJI SELECTION:
        Choose 1-3 food emojis that best represent the meal. Use only standard food/drink emojis.

        FOOD DESCRIPTION RULES:
        - If emojis completely represent the food (e.g., 🍕 for pizza), use ONLY the emoji(s) as the description
        - If emojis partially represent it, combine emoji + brief text (e.g., "🍝 Carbonara")
        - If no good emoji match exists, use brief text description (max 25 chars)

        Respond ONLY with valid JSON in this exact format (no other text):
        {
            "estimatedCarbs": <number in grams>,
            "foodDescription": "<emoji-only OR emoji+text OR text, max 25 chars>",
            "emoji": "<1-3 food emojis>",
            "detailedDescription": "<detailed description of food items and portions observed>",
            "fat": <number in grams>,
            "protein": <number in grams>,
            "carbConfidence": <0.0-1.0>,
            "emojiConfidence": <0.0-1.0>
        }
        """

        let chatRequest = OpenAIChatRequest(
            model: modelSet.primaryModel,
            messages: [
                OpenAIMessage(
                    role: "user",
                    content: [
                        .text(prompt),
                        .imageUrl(OpenAIImageUrl(url: "data:image/jpeg;base64,\(base64Image)"))
                    ]
                )
            ],
            maxTokens: 500,
            responseFormat: nil // Legacy mode without structured outputs
        )

        request.httpBody = try encoder.encode(chatRequest)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIServiceError.invalidResponse(statusCode: 0)
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            os_log("OpenAI API error: status %d", log: log, type: .error, httpResponse.statusCode)
            if let errorBody = String(data: data, encoding: .utf8) {
                os_log("Error body: %{public}@", log: log, type: .error, errorBody)
            }
            throw mapAIHTTPError(statusCode: httpResponse.statusCode, body: data)
        }

        return try parseLegacyResponse(data)
    }

    /// Parses the legacy single-item response
    private func parseLegacyResponse(_ data: Data) throws -> OpenAICarbEstimateResponse {
        let chatResponse: OpenAIChatResponse
        do {
            chatResponse = try decoder.decode(OpenAIChatResponse.self, from: data)
        } catch {
            throw OpenAIServiceError.decodingError(error)
        }

        guard let content = chatResponse.choices.first?.message.content else {
            throw OpenAIServiceError.noContentInResponse
        }

        os_log("Received AI response content: %{public}@", log: log, type: .debug, content)

        // Extract JSON from content (may be wrapped in markdown code blocks)
        let jsonString = extractJSON(from: content)

        guard let jsonData = jsonString.data(using: .utf8) else {
            throw OpenAIServiceError
                .decodingError(NSError(
                    domain: "OpenAIService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid content encoding"]
                ))
        }

        // Decode the legacy response structure
        let result: LegacySingleItemResponse
        do {
            result = try decoder.decode(LegacySingleItemResponse.self, from: jsonData)
        } catch {
            throw OpenAIServiceError.decodingError(error)
        }

        os_log(
            "AI estimated %{public}.1f grams of carbs (confidence: %.2f) for: %{public}@",
            log: log,
            type: .info,
            result.estimatedCarbs,
            result.carbConfidence,
            result.foodDescription
        )

        return OpenAICarbEstimateResponse(
            estimatedCarbs: result.estimatedCarbs,
            foodDescription: result.foodDescription,
            emoji: result.emoji,
            detailedDescription: result.detailedDescription,
            fat: result.fat,
            protein: result.protein,
            carbConfidence: result.carbConfidence,
            emojiConfidence: result.emojiConfidence
        )
    }

    /// Extracts JSON from a string that might contain markdown code blocks
    private func extractJSON(from content: String) -> String {
        // Try to find JSON in code block first
        if let codeBlockRange = content.range(of: "```json"),
           let endRange = content.range(of: "```", range: codeBlockRange.upperBound ..< content.endIndex)
        {
            return String(content[codeBlockRange.upperBound ..< endRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Try plain code block
        if let codeBlockRange = content.range(of: "```"),
           let endRange = content.range(of: "```", range: codeBlockRange.upperBound ..< content.endIndex)
        {
            return String(content[codeBlockRange.upperBound ..< endRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Try to find JSON object directly
        if let startBrace = content.firstIndex(of: "{"),
           let endBrace = content.lastIndex(of: "}")
        {
            return String(content[startBrace ... endBrace])
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Enhanced Food Analysis with Reasoning

    /// Analyzes a food image with optional user description and returns items with reasoning
    /// - Parameters:
    ///   - imageData: JPEG image data of the food to analyze
    ///   - userDescription: Optional context from user (e.g., "No sugar added dessert")
    /// - Returns: AIFoodItemsResponseWithReasoning containing items and explanation
    func analyzeFood(imageData: Data, userDescription: String?) async throws -> AIFoodItemsResponseWithReasoning {
        let apiKey = try getAPIKey()
        let base64Image = imageData.base64EncodedString()

        os_log("Sending food image for AI analysis with reasoning (%d bytes)", log: log, type: .info, imageData.count)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let defaultPrompt = """
        Analyze this food image for a diabetes insulin dosing app. Identify ALL individual food items visible and estimate total carbohydrate, fat, and protein content for each.

        IMPORTANT GUIDELINES:
        - List EACH distinct food item separately (e.g., for a meal with sandwich, apple, and drink - list all 3)
        - Include sides, drinks, sauces, and condiments as separate items
        - For composite items like sandwiches, list as one item but note components in the name
        - Estimate portion sizes based on visual cues
        - Choose 1-2 emojis per item that best represent it
        - Estimate fat and protein in grams for each item
        - Provide a brief reasoning explaining your carb estimates
        """
        var prompt = AIPromptSettings.foodAnalysisPrompt(fallback: defaultPrompt)

        // Add user description if provided
        if let description = userDescription, !description.isEmpty {
            prompt += "\n\nUSER CONTEXT: \(description)\nPlease factor this information into your analysis."
        }

        let chatRequest = OpenAIChatRequest(
            model: modelSet.primaryModel,
            messages: [
                OpenAIMessage(
                    role: "user",
                    content: [
                        .text(prompt),
                        .imageUrl(OpenAIImageUrl(url: "data:image/jpeg;base64,\(base64Image)"))
                    ]
                )
            ],
            maxTokens: 1500,
            responseFormat: OpenAIResponseFormat(
                type: "json_schema",
                jsonSchema: OpenAIJSONSchema(
                    name: "food_analysis_with_reasoning",
                    strict: true,
                    schema: buildFoodAnalysisWithReasoningSchema()
                )
            )
        )

        request.httpBody = try encoder.encode(chatRequest)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIServiceError.invalidResponse(statusCode: 0)
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            os_log("OpenAI API error: status %d", log: log, type: .error, httpResponse.statusCode)
            if let errorBody = String(data: data, encoding: .utf8) {
                os_log("Error body: %{public}@", log: log, type: .error, errorBody)
            }
            throw mapAIHTTPError(statusCode: httpResponse.statusCode, body: data)
        }

        return try parseMultiItemResponseWithReasoning(data)
    }

    /// Builds schema for food analysis with reasoning
    private func buildFoodAnalysisWithReasoningSchema() -> JSONSchemaDefinition {
        let foodItemSchema = JSONSchemaProperty.object(
            properties: [
                "name": .string(description: "Concise item description, max 30 chars"),
                "carbs": .number(description: "Estimated total carbohydrates in grams (not net carbs)"),
                "emoji": .string(description: "1-2 food emojis representing the item"),
                "fat": .number(description: "Estimated fat in grams"),
                "protein": .number(description: "Estimated protein in grams"),
                "servingCount": .number(
                    description: "Number of individual items in one serving for this item. For nutrition labels, use the count per serving (e.g., 4 for '4 crackers'). For actual food, use 1."
                ),
                "servingUnit": .string(
                    description: "Unit for the serving count (e.g., 'Crackers', 'Nuggets', 'Pieces'). Use 'Serving' for actual food."
                )
            ],
            required: ["name", "carbs", "emoji", "fat", "protein", "servingCount", "servingUnit"],
            description: "A single food item detected in the image"
        )

        return JSONSchemaDefinition(
            type: "object",
            properties: [
                "foodItems": .array(items: foodItemSchema, description: "Array of all food items detected"),
                "overallConfidence": .number(description: "Overall confidence in the analysis (0.0-1.0)"),
                "reasoning": .string(
                    description: "Brief explanation of how total carb values were estimated, mentioning portion sizes and assumptions made"
                )
            ],
            required: ["foodItems", "overallConfidence", "reasoning"],
            additionalProperties: false
        )
    }

    /// Parses the response with reasoning
    private func parseMultiItemResponseWithReasoning(_ data: Data) throws -> AIFoodItemsResponseWithReasoning {
        let chatResponse: OpenAIChatResponse
        do {
            chatResponse = try decoder.decode(OpenAIChatResponse.self, from: data)
        } catch {
            os_log("Failed to decode OpenAI response: %{public}@", log: log, type: .error, error.localizedDescription)
            throw OpenAIServiceError.decodingError(error)
        }

        guard let content = chatResponse.choices.first?.message.content else {
            throw OpenAIServiceError.noContentInResponse
        }

        os_log("Received AI response with reasoning: %{public}@", log: log, type: .debug, content)

        guard let contentData = content.data(using: .utf8) else {
            throw OpenAIServiceError
                .decodingError(NSError(
                    domain: "OpenAIService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid content encoding"]
                ))
        }

        let analysisResponse: AIFoodAnalysisWithReasoningResponse
        do {
            analysisResponse = try decoder.decode(AIFoodAnalysisWithReasoningResponse.self, from: contentData)
        } catch {
            os_log(
                "Failed to decode food analysis with reasoning: %{public}@",
                log: log,
                type: .error,
                error.localizedDescription
            )
            throw OpenAIServiceError.decodingError(error)
        }

        let foodItems = analysisResponse.foodItems.map { item in
            AIFoodItem(
                name: item.name,
                carbs: item.carbs,
                emoji: item.emoji,
                fat: item.fat,
                protein: item.protein,
                servingCount: max(item.servingCount, 1),
                servingUnit: item.servingUnit.isEmpty ? "Serving" : item.servingUnit
            )
        }

        guard !foodItems.isEmpty else {
            throw OpenAIServiceError
                .decodingError(NSError(
                    domain: "OpenAIService",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "No food items found in response"]
                ))
        }

        os_log("AI detected %d food items with reasoning", log: log, type: .info, foodItems.count)

        return AIFoodItemsResponseWithReasoning(
            foodItems: foodItems,
            overallConfidence: analysisResponse.overallConfidence,
            reasoning: analysisResponse.reasoning
        )
    }

    // MARK: - Streaming Food Analysis

    /// Analyzes a food image with streaming, yielding partial results as they arrive.
    /// Food items appear progressively in the UI as each one is parsed from the stream.
    /// - Parameters:
    ///   - imageData: JPEG image data of the food to analyze
    ///   - userDescription: Optional context from user
    /// - Returns: An AsyncStream of partial results, culminating in a complete result
    func analyzeFoodStreaming(
        imageData: Data,
        userDescription: String?
    ) -> AsyncThrowingStream<PartialFoodAnalysisResult, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let apiKey = try self.getAPIKey()
                    let base64Image = imageData.base64EncodedString()

                    os_log(
                        "Sending food image for streaming AI analysis (%d bytes)",
                        log: self.log,
                        type: .info,
                        imageData.count
                    )

                    var request = URLRequest(url: self.endpoint)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    let defaultPrompt = """
                    Analyze this food image for a diabetes insulin dosing app. Identify ALL individual food items visible and estimate total carbohydrate, fat, and protein content for each.

                    IMPORTANT GUIDELINES:
                    - List EACH distinct food item separately (e.g., for a meal with sandwich, apple, and drink - list all 3)
                    - Include sides, drinks, sauces, and condiments as separate items
                    - For composite items like sandwiches, list as one item but note components in the name
                    - Estimate portion sizes based on visual cues
                    - Choose 1-2 emojis per item that best represent it
                    - Estimate fat and protein in grams for each item
                    - Provide a brief reasoning explaining your carb estimates

                    SERVING SIZE RULES (per item):
                    - If the image shows a NUTRITION FACTS LABEL, report carbs/fat/protein PER SERVING as printed on the label. Set the item's servingCount to the number per serving (e.g., 4) and servingUnit to the unit (e.g., "Crackers").
                    - If the image shows ACTUAL FOOD (not a label), estimate total nutrients for the visible portion. Set servingCount to 1 and servingUnit to "Serving".
                    """
                    var prompt = AIPromptSettings.foodAnalysisPrompt(fallback: defaultPrompt)

                    if let description = userDescription, !description.isEmpty {
                        prompt += "\n\nUSER CONTEXT: \(description)\nPlease factor this information into your analysis."
                    }

                    let chatRequest = OpenAIChatRequest(
                        model: self.modelSet.primaryModel,
                        messages: [
                            OpenAIMessage(
                                role: "user",
                                content: [
                                    .text(prompt),
                                    .imageUrl(OpenAIImageUrl(url: "data:image/jpeg;base64,\(base64Image)"))
                                ]
                            )
                        ],
                        maxTokens: 1500,
                        responseFormat: OpenAIResponseFormat(
                            type: "json_schema",
                            jsonSchema: OpenAIJSONSchema(
                                name: "food_analysis_with_reasoning",
                                strict: true,
                                schema: self.buildFoodAnalysisWithReasoningSchema()
                            )
                        ),
                        stream: true
                    )

                    request.httpBody = try self.encoder.encode(chatRequest)

                    let (bytes, response) = try await self.session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw OpenAIServiceError.invalidResponse(statusCode: 0)
                    }

                    guard (200 ... 299).contains(httpResponse.statusCode) else {
                        os_log(
                            "OpenAI streaming API error: status %d",
                            log: self.log,
                            type: .error,
                            httpResponse.statusCode
                        )
                        var errorBody = Data()
                        for try await byte in bytes { errorBody.append(byte) }
                        throw mapAIHTTPError(statusCode: httpResponse.statusCode, body: errorBody)
                    }

                    let parser = StructuredJSONStreamParser()

                    for try await line in bytes.lines {
                        if let partialResult = parser.parseOpenAILine(line) {
                            continuation.yield(partialResult)

                            if partialResult.isComplete {
                                break
                            }
                        }
                    }

                    continuation.finish()

                } catch {
                    os_log(
                        "Streaming analysis failed: %{public}@",
                        log: self.log,
                        type: .error,
                        error.localizedDescription
                    )
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Single Item Update (Inline Editing)

    /// Updates a single item's carb estimate based on new description
    /// - Parameters:
    ///   - imageData: Original image data
    ///   - currentItems: All current food items
    ///   - editedItemId: ID of the item being edited
    ///   - newDescription: New description for the item
    /// - Returns: Updated carb count and reasoning
    func updateSingleItem(
        imageData: Data,
        currentItems: [AIFoodItem],
        editedItemId: UUID,
        newDescription: String
    ) async throws -> AISingleItemUpdateResponse {
        let apiKey = try getAPIKey()
        let base64Image = imageData.base64EncodedString()

        guard let editedItem = currentItems.first(where: { $0.id == editedItemId }) else {
            throw OpenAIServiceError
                .decodingError(NSError(domain: "OpenAIService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Item not found"]))
        }

        os_log("Updating item '%{public}@' to '%{public}@'", log: log, type: .info, editedItem.name, newDescription)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build context of other items
        let otherItemsContext = currentItems
            .filter { $0.id != editedItemId }
            .map { "\($0.emoji ?? "") \($0.name): \(Int($0.carbs))g carbs, \(Int($0.fat))g fat, \(Int($0.protein))g protein" }
            .joined(separator: ", ")

        let prompt = """
        I previously analyzed this food image and identified these items: \(otherItemsContext
            .isEmpty ? "none" : otherItemsContext)

        I also identified an item as "\(editedItem
            .name)" with \(Int(editedItem.carbs))g carbs, \(Int(editedItem.fat))g fat, \(Int(editedItem.protein))g protein.

        The user has corrected this item's description to: "\(newDescription)"

        Please re-estimate the total carbohydrates, fat, and protein for this corrected item based on the image and new description.
        Consider the visual portion size and the specific food type indicated by the user.
        """

        let chatRequest = OpenAIChatRequest(
            model: modelSet.primaryModel,
            messages: [
                OpenAIMessage(
                    role: "user",
                    content: [
                        .text(prompt),
                        .imageUrl(OpenAIImageUrl(url: "data:image/jpeg;base64,\(base64Image)"))
                    ]
                )
            ],
            maxTokens: 500,
            responseFormat: OpenAIResponseFormat(
                type: "json_schema",
                jsonSchema: OpenAIJSONSchema(
                    name: "single_item_update",
                    strict: true,
                    schema: buildSingleItemUpdateSchema()
                )
            )
        )

        request.httpBody = try encoder.encode(chatRequest)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIServiceError.invalidResponse(statusCode: 0)
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            os_log("OpenAI API error: status %d", log: log, type: .error, httpResponse.statusCode)
            throw mapAIHTTPError(statusCode: httpResponse.statusCode, body: data)
        }

        return try parseSingleItemUpdateResponse(data, itemId: editedItemId)
    }

    /// Builds schema for single item update
    private func buildSingleItemUpdateSchema() -> JSONSchemaDefinition {
        JSONSchemaDefinition(
            type: "object",
            properties: [
                "updatedCarbs": .number(description: "Updated total carbohydrate estimate in grams (not net carbs)"),
                "reasoning": .string(description: "Brief explanation of the updated estimate"),
                "updatedFat": .number(description: "Updated fat estimate in grams"),
                "updatedProtein": .number(description: "Updated protein estimate in grams")
            ],
            required: ["updatedCarbs", "reasoning", "updatedFat", "updatedProtein"],
            additionalProperties: false
        )
    }

    /// Parses single item update response
    private func parseSingleItemUpdateResponse(_ data: Data, itemId: UUID) throws -> AISingleItemUpdateResponse {
        let chatResponse: OpenAIChatResponse
        do {
            chatResponse = try decoder.decode(OpenAIChatResponse.self, from: data)
        } catch {
            throw OpenAIServiceError.decodingError(error)
        }

        guard let content = chatResponse.choices.first?.message.content else {
            throw OpenAIServiceError.noContentInResponse
        }

        guard let contentData = content.data(using: .utf8) else {
            throw OpenAIServiceError
                .decodingError(NSError(
                    domain: "OpenAIService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid content encoding"]
                ))
        }

        let apiResponse: AISingleItemUpdateAPIResponse
        do {
            apiResponse = try decoder.decode(AISingleItemUpdateAPIResponse.self, from: contentData)
        } catch {
            throw OpenAIServiceError.decodingError(error)
        }

        os_log("Item updated to %.1fg carbs", log: log, type: .info, apiResponse.updatedCarbs)

        return AISingleItemUpdateResponse(
            itemId: itemId,
            updatedCarbs: apiResponse.updatedCarbs,
            reasoning: apiResponse.reasoning,
            updatedFat: apiResponse.updatedFat,
            updatedProtein: apiResponse.updatedProtein
        )
    }

    // MARK: - Nutrition Lookup Intent Classification

    /// Classifies whether a user's chat message is requesting a published nutrition lookup.
    /// Uses a lightweight GPT call to determine intent and extract the item name.
    func classifyNutritionLookupIntent(
        userMessage: String,
        currentItems: [AIFoodItem],
        restaurantName: String
    ) async throws -> NutritionLookupIntent {
        let apiKey = try getAPIKey()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let itemsList = currentItems.map { "\($0.emoji ?? "") \($0.name)" }.joined(separator: ", ")

        let systemPrompt = """
        You are classifying a user's message in a food analysis conversation.
        The user is looking at food from \(restaurantName). Current items: \(itemsList).

        Determine if the user is asking you to LOOK UP or FIND published nutrition facts for a specific menu item \
        (e.g., "look up the fries", "find nutrition for the nuggets", "can you search for the shake?").

        This does NOT include:
        - Asking to change/update an existing item's values
        - Asking general questions about the food
        - Asking to add a new item with estimated values

        If it IS a nutrition lookup request, extract the menu item name they want to look up.
        """

        let messages = [
            OpenAIMessage(role: "system", content: [.text(systemPrompt)]),
            OpenAIMessage(role: "user", content: [.text(userMessage)])
        ]

        let intentSchema = JSONSchemaDefinition(
            type: "object",
            properties: [
                "isNutritionLookup": .boolean(
                    description: "Whether the user is requesting a published nutrition lookup/search"
                ),
                "menuItemName": .string(
                    description: "The menu item name to look up, or empty string if not a lookup request"
                )
            ],
            required: ["isNutritionLookup", "menuItemName"],
            additionalProperties: false
        )

        let chatRequest = OpenAIChatRequest(
            model: modelSet.classifierModel,
            messages: messages,
            maxTokens: 200,
            responseFormat: OpenAIResponseFormat(
                type: "json_schema",
                jsonSchema: OpenAIJSONSchema(
                    name: "nutrition_lookup_intent",
                    strict: true,
                    schema: intentSchema
                )
            )
        )

        request.httpBody = try encoder.encode(chatRequest)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            throw OpenAIServiceError.invalidResponse(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let chatResponse = try decoder.decode(OpenAIChatResponse.self, from: data)

        guard let content = chatResponse.choices.first?.message.content,
              let contentData = content.data(using: .utf8)
        else {
            throw OpenAIServiceError.noContentInResponse
        }

        return try decoder.decode(NutritionLookupIntent.self, from: contentData)
    }

    // MARK: - Conversation Turn

    /// Processes a conversation turn with the AI
    /// - Parameters:
    ///   - imageData: Original image data
    ///   - currentItems: Current food items
    ///   - conversationHistory: Previous messages in the conversation
    ///   - userMessage: The user's new message
    /// - Returns: Updated items and assistant response
    func conversationTurn(
        imageData: Data,
        currentItems: [AIFoodItem],
        conversationHistory: [AIConversationMessage],
        userMessage: String
    ) async throws -> AIConversationResponse {
        let apiKey = try getAPIKey()
        let base64Image = imageData.base64EncodedString()

        os_log("Processing conversation turn: %{public}@", log: log, type: .info, userMessage)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build current items context (include source info so AI knows which items are published)
        let itemsContext = currentItems.enumerated().map { index, item in
            let sourceLabel = item.source == .published ? " [PUBLISHED - verified from restaurant website]" : " [AI ESTIMATE]"
            return "[\(index + 1)] \(item.emoji ?? "") \(item.name): \(Int(item.carbs))g carbs, \(Int(item.fat))g fat, \(Int(item.protein))g protein\(sourceLabel)"
        }.joined(separator: "\n")

        // Build conversation history (text + system events + published nutrition context)
        let historyText = conversationHistory.compactMap { msg -> String? in
            switch msg.content {
            case let .text(text):
                return "\(msg.role.rawValue.capitalized): \(text)"
            case let .systemEvent(event):
                return "System: \(event)"
            case .carbSummary:
                return nil
            case let .publishedNutrition(items, restaurantName, _):
                let itemsList = items.map { "\($0.emoji ?? "") \($0.name): \(Int($0.carbs))g carbs" }.joined(separator: ", ")
                return "System: Published nutrition facts from \(restaurantName) were found and verified: \(itemsList)"
            }
        }.joined(separator: "\n")

        let systemPrompt = """
        You are helping a person with diabetes refine their total carbohydrate, fat, and protein estimates for insulin dosing.

        CURRENT FOOD ITEMS:
        \(itemsContext)

        Items marked [PUBLISHED] have verified nutrition facts from the restaurant's official website.
        Items marked [AI ESTIMATE] are vision-based estimates that may be less accurate.

        CONVERSATION HISTORY:
        \(historyText)

        The user's new message is below. Based on their feedback:
        1. Update any food items that need to change
        2. Keep item IDs consistent (return the same IDs for unchanged items)
        3. Provide a helpful response acknowledging their input
        4. If they mention specific items, update those
        5. If they provide new information about the whole meal, adjust accordingly
        6. For items marked [PUBLISHED], preserve their values unless the user explicitly asks to change them
        7. If the user asks you to look up or find nutrition facts for an item, let them know that you can only provide AI estimates in the conversation — published nutrition lookups happen automatically when a restaurant is identified
        8. For each item, include a "source" field: "published" for items with verified data, "estimated" for AI estimates

        For each item, return:
        - id: The original UUID if updating, or generate a new one for new items
        - name: Food description (max 30 chars)
        - carbs: Estimated total carbohydrate grams (not net carbs)
        - emoji: 1-2 relevant emojis
        - fat: Estimated fat grams
        - protein: Estimated protein grams
        - source: "published" if the item has verified published nutrition data, "estimated" if AI estimate

        For each item, also preserve its servingCount and servingUnit from the previous analysis unless the user explicitly changes it.
        """

        // Build messages array for multi-turn conversation
        let messages: [OpenAIMessage] = [
            OpenAIMessage(
                role: "system",
                content: [.text(systemPrompt)]
            ),
            OpenAIMessage(
                role: "user",
                content: [
                    .text("Here is the food image for reference:"),
                    .imageUrl(OpenAIImageUrl(url: "data:image/jpeg;base64,\(base64Image)"))
                ]
            ),
            OpenAIMessage(
                role: "user",
                content: [.text(userMessage)]
            )
        ]

        let chatRequest = OpenAIChatRequest(
            model: modelSet.primaryModel,
            messages: messages,
            maxTokens: 1500,
            responseFormat: OpenAIResponseFormat(
                type: "json_schema",
                jsonSchema: OpenAIJSONSchema(
                    name: "conversation_response",
                    strict: true,
                    schema: buildConversationResponseSchema()
                )
            )
        )

        request.httpBody = try encoder.encode(chatRequest)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIServiceError.invalidResponse(statusCode: 0)
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            os_log("OpenAI API error: status %d", log: log, type: .error, httpResponse.statusCode)
            throw mapAIHTTPError(statusCode: httpResponse.statusCode, body: data)
        }

        return try parseConversationResponse(data, originalItems: currentItems)
    }

    /// Builds schema for conversation response
    private func buildConversationResponseSchema() -> JSONSchemaDefinition {
        let foodItemSchema = JSONSchemaProperty.object(
            properties: [
                "id": .string(description: "UUID of the item (same as original if updating, new UUID if adding)"),
                "name": .string(description: "Concise item description, max 30 chars"),
                "carbs": .number(description: "Estimated total carbohydrates in grams (not net carbs)"),
                "emoji": .string(description: "1-2 food emojis representing the item"),
                "fat": .number(description: "Estimated fat in grams"),
                "protein": .number(description: "Estimated protein in grams"),
                "source": .string(description: "Data source: 'published' for verified restaurant data, 'estimated' for AI vision estimate"),
                "servingCount": .number(
                    description: "Number of individual items in one serving for this item. Preserve from previous turn. Use 1 if no specific serving info."
                ),
                "servingUnit": .string(
                    description: "Unit for the serving count (e.g., 'Nuggets', 'Pieces'). Preserve from previous turn. Use 'Serving' if no specific serving info."
                )
            ],
            required: ["id", "name", "carbs", "emoji", "fat", "protein", "source", "servingCount", "servingUnit"],
            description: "A food item"
        )

        return JSONSchemaDefinition(
            type: "object",
            properties: [
                "foodItems": .array(items: foodItemSchema, description: "All food items (updated list)"),
                "updatedItemIds": .array(items: .string(), description: "IDs of items that were changed in this turn"),
                "assistantMessage": .string(description: "Helpful response to the user acknowledging their input"),
                "overallConfidence": .number(description: "Overall confidence in the updated analysis (0.0-1.0)")
            ],
            required: ["foodItems", "updatedItemIds", "assistantMessage", "overallConfidence"],
            additionalProperties: false
        )
    }

    /// Parses conversation response
    private func parseConversationResponse(_ data: Data, originalItems: [AIFoodItem]) throws -> AIConversationResponse {
        let chatResponse: OpenAIChatResponse
        do {
            chatResponse = try decoder.decode(OpenAIChatResponse.self, from: data)
        } catch {
            throw OpenAIServiceError.decodingError(error)
        }

        guard let content = chatResponse.choices.first?.message.content else {
            throw OpenAIServiceError.noContentInResponse
        }

        guard let contentData = content.data(using: .utf8) else {
            throw OpenAIServiceError
                .decodingError(NSError(
                    domain: "OpenAIService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid content encoding"]
                ))
        }

        let apiResponse: AIConversationTurnAPIResponse
        do {
            apiResponse = try decoder.decode(AIConversationTurnAPIResponse.self, from: contentData)
        } catch {
            throw OpenAIServiceError.decodingError(error)
        }

        // Build a lookup of original items by ID to preserve sourceURL and other metadata
        let originalItemsById = Dictionary(
            originalItems.map { ($0.id.uuidString.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Convert API response items to domain model, preserving source metadata
        let foodItems = apiResponse.foodItems.map { item in
            let itemId = UUID(uuidString: item.id) ?? UUID()
            let originalItem = originalItemsById[item.id.lowercased()]

            // Determine source: prefer AI's response, fall back to original item's source
            let source: AIFoodItemSource
            if let aiSource = item.source, aiSource == "published" {
                source = .published
            } else if let original = originalItem {
                source = original.source
            } else {
                source = .estimated
            }

            // Prefer AI response serving info, fall back to original item's values.
            let servingCount: Double = {
                if item.servingCount > 0 { return item.servingCount }
                return originalItem?.servingCount ?? 1
            }()
            let servingUnit: String = {
                if !item.servingUnit.isEmpty { return item.servingUnit }
                return originalItem?.servingUnit ?? "Serving"
            }()

            return AIFoodItem(
                id: itemId,
                name: item.name,
                carbs: item.carbs,
                emoji: item.emoji,
                fat: item.fat,
                protein: item.protein,
                source: source,
                sourceURL: originalItem?.sourceURL,
                servingCount: servingCount,
                servingUnit: servingUnit,
                calories: originalItem?.calories
            )
        }

        let updatedItemIds = apiResponse.updatedItemIds.compactMap { UUID(uuidString: $0) }

        os_log("Conversation turn: %d items, %d updated", log: log, type: .info, foodItems.count, updatedItemIds.count)

        return AIConversationResponse(
            foodItems: foodItems,
            updatedItemIds: updatedItemIds,
            assistantMessage: apiResponse.assistantMessage,
            overallConfidence: apiResponse.overallConfidence
        )
    }
}

enum AIPromptSettings {
    static let defaultFoodAnalysisPrompt = """
    Analyze this food image for a diabetes insulin dosing app. Identify ALL individual food items visible and estimate total carbohydrate, fat, and protein content for each.

    IMPORTANT GUIDELINES:
    - List EACH distinct food item separately (e.g., for a meal with sandwich, apple, and drink - list all 3)
    - Include sides, drinks, sauces, and condiments as separate items
    - For composite items like sandwiches, list as one item but note components in the name
    - Estimate portion sizes based on visual cues
    - Choose 1-2 emojis per item that best represent it
    - Estimate fat and protein in grams for each item
    - Provide a brief reasoning explaining your carb estimates

    SERVING SIZE RULES (per item):
    - If the image shows a NUTRITION FACTS LABEL, report carbs/fat/protein PER SERVING as printed on the label. Set the item's servingCount to the number per serving (e.g., 4) and servingUnit to the unit (e.g., "Crackers").
    - If the image shows ACTUAL FOOD (not a label), estimate total nutrients for the visible portion. Set servingCount to 1 and servingUnit to "Serving".
    """

    private static let foodAnalysisPromptKey = "aiFoodAnalysisPrompt"

    static var foodAnalysisPrompt: String {
        get { foodAnalysisPrompt(fallback: defaultFoodAnalysisPrompt) }
        set { UserDefaults.standard.set(newValue, forKey: foodAnalysisPromptKey) }
    }

    static func foodAnalysisPrompt(fallback defaultPrompt: String) -> String {
        UserDefaults.standard.string(forKey: foodAnalysisPromptKey) ?? defaultPrompt
    }

    static func resetFoodAnalysisPrompt() {
        UserDefaults.standard.removeObject(forKey: foodAnalysisPromptKey)
    }
}

// MARK: - Legacy Response Type

/// Response structure for legacy single-item analysis
private struct LegacySingleItemResponse: Decodable {
    let estimatedCarbs: Double
    let foodDescription: String
    let emoji: String
    let detailedDescription: String
    let fat: Double
    let protein: Double
    let carbConfidence: Double
    let emojiConfidence: Double
}
