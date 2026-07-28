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
    let streamOptions: OpenAIStreamOptions?
    let sessionID: String?

    init(
        model: String,
        messages: [OpenAIMessage],
        maxTokens: Int,
        responseFormat: OpenAIResponseFormat?,
        stream: Bool? = nil,
        streamOptions: OpenAIStreamOptions? = nil,
        sessionID: String? = nil
    ) {
        self.model = model
        self.messages = messages
        self.maxTokens = maxTokens
        self.responseFormat = responseFormat
        self.stream = stream
        self.streamOptions = streamOptions
        self.sessionID = sessionID
    }

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
        case stream
        case streamOptions = "stream_options"
        case sessionID = "session_id"
    }
}

struct OpenAIStreamOptions: Encodable {
    let includeUsage: Bool

    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
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
    let promptTokensDetails: OpenAIPromptTokensDetails?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case promptTokensDetails = "prompt_tokens_details"
    }
}

struct OpenAIPromptTokensDetails: Decodable {
    let cachedTokens: Int?

    enum CodingKeys: String, CodingKey {
        case cachedTokens = "cached_tokens"
    }
}

// MARK: - OpenAI Streaming Response Types

/// A single chunk from the OpenAI streaming API (SSE)
struct OpenAIStreamChunk: Decodable {
    let choices: [OpenAIStreamChoice]
    let usage: OpenAIUsage?
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

/// Schema-compatible copy of a completed image analysis used as the assistant
/// turn in a cache-compatible description refinement request. App-only fields
/// such as UUIDs and source metadata are intentionally omitted.
private struct FoodAnalysisAssistantMessage: Encodable {
    struct FoodItem: Encodable {
        let name: String
        let carbs: Double
        let emoji: String
        let fat: Double
        let protein: Double
        let servingCount: Double
        let servingUnit: String
    }

    let foodItems: [FoodItem]
    let overallConfidence: Double
    let reasoning: String

    init(response: AIFoodItemsResponseWithReasoning) {
        foodItems = response.foodItems.map {
            FoodItem(
                name: $0.name,
                carbs: $0.carbs,
                emoji: $0.emoji ?? "",
                fat: $0.fat,
                protein: $0.protein,
                servingCount: $0.servingCount,
                servingUnit: $0.servingUnit
            )
        }
        overallConfidence = response.overallConfidence
        reasoning = response.reasoning
    }
}

/// Constructs the message sequence for the primary image flow. Kept separate
/// from networking so the cache-prefix contract can be regression tested.
enum FoodAnalysisRequestBuilder {
    static func initialMessages(imageData: Data) -> [OpenAIMessage] {
        [
            OpenAIMessage(
                role: "user",
                content: [
                    .text(AIPromptSettings.Prompt.streamingFoodAnalysis.value),
                    .imageUrl(OpenAIImageUrl(url: "data:image/jpeg;base64,\(imageData.base64EncodedString())"))
                ]
            )
        ]
    }

    static func refinementMessages(
        imageData: Data,
        initialResponse: AIFoodItemsResponseWithReasoning,
        userDescription: String,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> [OpenAIMessage] {
        let assistantData = try encoder.encode(FoodAnalysisAssistantMessage(response: initialResponse))
        guard let assistantJSON = String(data: assistantData, encoding: .utf8) else {
            throw OpenAIServiceError.invalidImageData
        }

        var messages = initialMessages(imageData: imageData)
        messages.append(OpenAIMessage(role: "assistant", content: [.text(assistantJSON)]))
        messages.append(OpenAIMessage(
            role: "user",
            content: [
                .text(AIPromptSettings.Prompt.foodUserContext.rendered(["description": userDescription]))
            ]
        ))
        return messages
    }
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

    /// Builds the schema used by streaming food analysis.
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

    // MARK: - Streaming Food Analysis

    /// Analyzes a food image with streaming, yielding partial results as they arrive.
    /// Food items appear progressively in the UI as each one is parsed from the stream.
    /// - Parameters:
    ///   - imageData: JPEG image data of the food to analyze
    ///   - userDescription: Optional context from user
    /// - Returns: An AsyncStream of partial results, culminating in a complete result
    func analyzeFoodStreaming(
        imageData: Data,
        userDescription: String?,
        sessionID: String?
    ) -> AsyncThrowingStream<PartialFoodAnalysisResult, Error> {
        var messages = FoodAnalysisRequestBuilder.initialMessages(imageData: imageData)

        if let description = userDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty
        {
            messages.append(OpenAIMessage(
                role: "user",
                content: [
                    .text(AIPromptSettings.Prompt.foodUserContext.rendered(["description": description]))
                ]
            ))
        }

        return streamFoodAnalysis(messages: messages, sessionID: sessionID)
    }

    /// Refines an already-completed image analysis with user context.
    ///
    /// The first message is built by the same helper as the immediate request, so
    /// its prompt text and image bytes remain an identical cacheable prefix.
    func refineFoodAnalysisStreaming(
        imageData: Data,
        initialResponse: AIFoodItemsResponseWithReasoning,
        userDescription: String,
        sessionID: String
    ) -> AsyncThrowingStream<PartialFoodAnalysisResult, Error> {
        do {
            let messages = try FoodAnalysisRequestBuilder.refinementMessages(
                imageData: imageData,
                initialResponse: initialResponse,
                userDescription: userDescription,
                encoder: encoder
            )
            return streamFoodAnalysis(messages: messages, sessionID: sessionID)
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }
    }

    private func streamFoodAnalysis(
        messages: [OpenAIMessage],
        sessionID: String?
    ) -> AsyncThrowingStream<PartialFoodAnalysisResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let apiKey = try self.getAPIKey()

                    os_log(
                        "Sending streaming food analysis with %d message(s)",
                        log: self.log,
                        type: .info,
                        messages.count
                    )

                    var request = URLRequest(url: self.endpoint)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    let chatRequest = OpenAIChatRequest(
                        model: self.modelSet.primaryModel,
                        messages: messages,
                        maxTokens: 1500,
                        responseFormat: OpenAIResponseFormat(
                            type: "json_schema",
                            jsonSchema: OpenAIJSONSchema(
                                name: "food_analysis_with_reasoning",
                                strict: true,
                                schema: self.buildFoodAnalysisWithReasoningSchema()
                            )
                        ),
                        stream: true,
                        streamOptions: OpenAIStreamOptions(includeUsage: true),
                        sessionID: sessionID
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
                        if let usage = self.streamingUsage(from: line) {
                            let cachedTokens = usage.promptTokensDetails?.cachedTokens ?? 0
                            os_log(
                                "Food analysis token usage: prompt=%d cached=%d completion=%d",
                                log: self.log,
                                type: .info,
                                usage.promptTokens,
                                cachedTokens,
                                usage.completionTokens
                            )
                        }

                        if let partialResult = parser.parseOpenAILine(line) {
                            continuation.yield(partialResult)
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

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func streamingUsage(from line: String) -> OpenAIUsage? {
        guard line.hasPrefix("data: ") else { return nil }
        let payload = String(line.dropFirst(6))
        guard payload != "[DONE]",
              let data = payload.data(using: .utf8),
              let chunk = try? decoder.decode(OpenAIStreamChunk.self, from: data)
        else {
            return nil
        }
        return chunk.usage
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

        let prompt = AIPromptSettings.Prompt.singleItemCorrection.rendered([
            "otherItems": otherItemsContext.isEmpty ? "none" : otherItemsContext,
            "itemName": editedItem.name,
            "carbs": String(Int(editedItem.carbs)),
            "fat": String(Int(editedItem.fat)),
            "protein": String(Int(editedItem.protein)),
            "newDescription": newDescription
        ])

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

        let systemPrompt = AIPromptSettings.Prompt.nutritionLookupIntent.rendered([
            "restaurantName": restaurantName,
            "currentItems": itemsList
        ])

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

        let systemPrompt = AIPromptSettings.Prompt.conversationRefinement.rendered([
            "currentItems": itemsContext,
            "conversationHistory": historyText
        ])

        // Build messages array for multi-turn conversation
        let messages: [OpenAIMessage] = [
            OpenAIMessage(
                role: "system",
                content: [.text(systemPrompt)]
            ),
            OpenAIMessage(
                role: "user",
                content: [
                    .text(AIPromptSettings.Prompt.conversationImageReference.value),
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
    static func removeObsoletePromptValues(defaults: UserDefaults = .standard) {
        for key in [
            "aiPrompt.enhancedFoodAnalysis",
            "aiPrompt.multiItemFoodAnalysis",
            "aiPrompt.legacyFoodAnalysis",
            "aiPrompt.didSplitFoodAnalysisPrompt"
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    struct Placeholder: Identifiable {
        let token: String
        let description: String

        var id: String { token }
        var displayToken: String { "{{\(token)}}" }
    }

    enum Prompt: String, CaseIterable, Identifiable {
        case streamingFoodAnalysis
        case foodUserContext
        case singleItemCorrection
        case nutritionLookupIntent
        case conversationRefinement
        case conversationImageReference
        case restaurantClassification
        case publishedNutritionSearch

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .streamingFoodAnalysis: return "Streaming Food Analysis"
            case .foodUserContext: return "Food Description Context"
            case .singleItemCorrection: return "Single-Item Correction"
            case .nutritionLookupIntent: return "Nutrition Lookup Detection"
            case .conversationRefinement: return "Conversation Refinement"
            case .conversationImageReference: return "Conversation Image Reference"
            case .restaurantClassification: return "Restaurant Classification"
            case .publishedNutritionSearch: return "Published Nutrition Search"
            }
        }

        var title: String {
            switch self {
            case .streamingFoodAnalysis: return String(localized: "Streaming Food Analysis")
            case .foodUserContext: return String(localized: "Food Description Context")
            case .singleItemCorrection: return String(localized: "Single-Item Correction")
            case .nutritionLookupIntent: return String(localized: "Nutrition Lookup Detection")
            case .conversationRefinement: return String(localized: "Conversation Refinement")
            case .conversationImageReference: return String(localized: "Conversation Image Reference")
            case .restaurantClassification: return String(localized: "Restaurant Classification")
            case .publishedNutritionSearch: return String(localized: "Published Nutrition Search")
            }
        }

        var usageDescription: String {
            switch self {
            case .streamingFoodAnalysis:
                return String(
                    localized: "Starts immediately after image capture and streams detected items and nutrient estimates into the interface."
                )
            case .foodUserContext:
                return String(
                    localized: "Sent after the initial image result as an optional description addendum, while preserving the primary prompt as the cacheable request prefix."
                )
            case .singleItemCorrection:
                return String(
                    localized: "Used when the user edits one detected food item's description and asks AI to recalculate its nutrients."
                )
            case .nutritionLookupIntent:
                return String(
                    localized: "Used during food chat to decide whether a message requests published restaurant nutrition facts."
                )
            case .conversationRefinement:
                return String(
                    localized: "Used after an initial analysis when the user chats with AI to add, remove, correct, or resize food items."
                )
            case .conversationImageReference:
                return String(localized: "Sent with the original food image on each conversational refinement request.")
            case .restaurantClassification:
                return String(
                    localized: "Used to decide whether the user's food description names a restaurant, chain, or branded menu item."
                )
            case .publishedNutritionSearch:
                return String(
                    localized: "Used to search the web for official nutrition facts after a restaurant and menu item are identified."
                )
            }
        }

        var placeholders: [Placeholder] {
            switch self {
            case .foodUserContext:
                return [.init(token: "description", description: String(localized: "The user's food description."))]
            case .singleItemCorrection:
                return [
                    .init(token: "otherItems", description: String(localized: "Other detected items and their nutrients.")),
                    .init(token: "itemName", description: String(localized: "The original item name.")),
                    .init(token: "carbs", description: String(localized: "The original carbohydrate estimate.")),
                    .init(token: "fat", description: String(localized: "The original fat estimate.")),
                    .init(token: "protein", description: String(localized: "The original protein estimate.")),
                    .init(token: "newDescription", description: String(localized: "The user's corrected description."))
                ]
            case .nutritionLookupIntent:
                return [
                    .init(token: "restaurantName", description: String(localized: "The identified restaurant name.")),
                    .init(token: "currentItems", description: String(localized: "The food items currently shown."))
                ]
            case .conversationRefinement:
                return [
                    .init(
                        token: "currentItems",
                        description: String(localized: "Current items, nutrient estimates, IDs, and sources.")
                    ),
                    .init(
                        token: "conversationHistory",
                        description: String(localized: "Previous user, assistant, and system messages.")
                    )
                ]
            case .publishedNutritionSearch:
                return [
                    .init(token: "menuItemName", description: String(localized: "The menu item to find.")),
                    .init(token: "restaurantName", description: String(localized: "The restaurant or brand name.")),
                    .init(
                        token: "restaurantDomain",
                        description: String(localized: "A lowercase restaurant name for suggesting an official domain.")
                    )
                ]
            default:
                return []
            }
        }

        var examples: [String] {
            guard self == .conversationRefinement else { return [] }
            return [
                String(localized: "That was two slices of pizza, not one."),
                String(localized: "Remove the fries; I didn't eat them."),
                String(localized: "The coffee had oat milk and no syrup."),
                String(localized: "Add a tablespoon of ranch dressing.")
            ]
        }

        var defaultValue: String {
            switch self {
            case .streamingFoodAnalysis:
                return """
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
            case .foodUserContext:
                return """
                USER CONTEXT: {{description}}
                Please factor this information into your analysis.
                """
            case .singleItemCorrection:
                return """
                I previously analyzed this food image and identified these items: {{otherItems}}

                I also identified an item as "{{itemName}}" with {{carbs}}g carbs, {{fat}}g fat, and {{protein}}g protein.

                The user has corrected this item's description to: "{{newDescription}}"

                Please re-estimate the total carbohydrates, fat, and protein for this corrected item based on the image and new description.
                Consider the visual portion size and the specific food type indicated by the user.
                """
            case .nutritionLookupIntent:
                return """
                You are classifying a user's message in a food analysis conversation.
                The user is looking at food from {{restaurantName}}. Current items: {{currentItems}}.

                Determine if the user is asking you to LOOK UP or FIND published nutrition facts for a specific menu item (e.g., "look up the fries", "find nutrition for the nuggets", "can you search for the shake?").

                This does NOT include:
                - Asking to change/update an existing item's values
                - Asking general questions about the food
                - Asking to add a new item with estimated values

                If it IS a nutrition lookup request, extract the menu item name they want to look up.
                """
            case .conversationRefinement:
                return """
                You are helping a person with diabetes refine their total carbohydrate, fat, and protein estimates for insulin dosing.

                CURRENT FOOD ITEMS:
                {{currentItems}}

                Items marked [PUBLISHED] have verified nutrition facts from the restaurant's official website.
                Items marked [AI ESTIMATE] are vision-based estimates that may be less accurate.

                CONVERSATION HISTORY:
                {{conversationHistory}}

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
            case .conversationImageReference:
                return "Here is the food image for reference:"
            case .restaurantClassification:
                return """
                You are a food classifier. Determine if the user's text describes a menu item from a restaurant, fast food chain, coffee shop, or branded food product that would have officially published nutrition information available online.

                Examples of YES: "Big Mac from McDonald's", "Starbucks caramel latte", "Chipotle burrito bowl", "Subway footlong Italian BMT", "Whopper from Burger King", "Chick-fil-A sandwich", "Domino's pepperoni pizza medium"

                Examples of NO: "homemade pasta", "rice and chicken", "some fruit", "sandwich" (generic, no brand), "salad", "my mom's lasagna"

                If yes, extract the restaurant/brand name and the specific menu item name. If the text is ambiguous but leans toward a known chain, classify as yes with lower confidence.
                """
            case .publishedNutritionSearch:
                return """
                Look up the official published nutrition facts for "{{menuItemName}}" from "{{restaurantName}}".

                STRONGLY PREFER the restaurant's own official website (e.g., {{restaurantDomain}}.com/nutrition or the restaurant's official nutrition PDF). Only use third-party nutrition databases as a fallback if the official source is unavailable.

                I need:
                - Total carbohydrates in grams
                - Total fat in grams
                - Protein in grams
                - Calories
                - The URL of the webpage where you found the nutrition facts (sourceURL)
                - servingCount: How many individual items are in one serving (e.g., 8 for an 8-count nugget, 1 for a sandwich)
                - servingCountUnit: The unit for counting (e.g., "Nuggets", "Pieces", or "Serving" if not countable)

                IMPORTANT: For menuItemName, return ONLY the menu item name as it appears on the menu, without including the restaurant or brand name. For example, return "Hash Browns" not "Hash Browns (Chick-fil-A)".

                IMPORTANT: For sourceURL, return the actual URL of the official webpage where the nutrition information was found. Prefer the restaurant's own domain (e.g., "https://www.chickfila.com/nutrition"). Do not leave this empty.

                Return the data from the official/published source. If you cannot find the exact item, return your best match with a lower confidence score.
                """
            }
        }

        var value: String {
            if let savedValue = UserDefaults.standard.string(forKey: storageKey) {
                return savedValue
            }

            return defaultValue
        }

        func rendered(_ replacements: [String: String]) -> String {
            let template = value
            let expression = try? NSRegularExpression(pattern: #"\{\{([A-Za-z][A-Za-z0-9]*)\}\}"#)
            let matches = expression?.matches(in: template, range: NSRange(template.startIndex..., in: template)) ?? []
            let templateString = template as NSString

            return matches.reversed().reduce(template) { result, match in
                let token = templateString.substring(with: match.range(at: 1))
                guard let replacement = replacements[token] else { return result }
                return (result as NSString).replacingCharacters(in: match.range, with: replacement)
            }
        }

        func save(_ value: String) {
            UserDefaults.standard.set(value, forKey: storageKey)
        }

        func reset() {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }

        private var storageKey: String {
            self == .streamingFoodAnalysis ? "aiFoodAnalysisPrompt" : "aiPrompt.\(rawValue)"
        }
    }
}
