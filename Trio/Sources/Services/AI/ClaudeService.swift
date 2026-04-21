import Foundation
import os.log

// MARK: - Anthropic API Request Types

/// Root request body for Anthropic Messages API
private struct AnthropicMessageRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String?
    let messages: [AnthropicMessage]
    let tools: [AnthropicTool]?
    let toolChoice: AnthropicToolChoice?
    let stream: Bool?

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case tools
        case toolChoice = "tool_choice"
        case stream
    }
}

private struct AnthropicMessage: Encodable {
    let role: String
    let content: [AnthropicContentBlock]
}

private enum AnthropicContentBlock: Encodable {
    case text(String)
    case image(base64: String, mediaType: String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .image(base64, mediaType):
            try container.encode("image", forKey: .type)
            try container.encode(
                AnthropicImageSource(type: "base64", mediaType: mediaType, data: base64),
                forKey: .source
            )
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case source
    }
}

private struct AnthropicImageSource: Encodable {
    let type: String
    let mediaType: String
    let data: String

    enum CodingKeys: String, CodingKey {
        case type
        case mediaType = "media_type"
        case data
    }
}

/// A tool definition for Anthropic tool-use (structured output). The `inputSchema`
/// is plain JSON Schema — we reuse the OpenAI schema types since they emit vanilla
/// JSON Schema on the wire.
private struct AnthropicTool: Encodable {
    let name: String
    let description: String
    let inputSchema: JSONSchemaDefinition

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema = "input_schema"
    }
}

private struct AnthropicToolChoice: Encodable {
    let type: String
    let name: String?
}

// MARK: - Anthropic API Response Types

private struct AnthropicMessageResponse: Decodable {
    let id: String
    let content: [AnthropicResponseContentBlock]
    let stopReason: String?
    let usage: AnthropicUsage?

    enum CodingKeys: String, CodingKey {
        case id
        case content
        case stopReason = "stop_reason"
        case usage
    }
}

/// A response content block. For structured outputs we force a `tool_use` block;
/// for plain text we use `text`.
private struct AnthropicResponseContentBlock: Decodable {
    let type: String
    let text: String?
    let name: String?
    let input: AnyDecodable?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case name
        case input
    }
}

private struct AnthropicUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

/// Lightweight JSON value wrapper so we can re-serialize Anthropic's `tool_use.input`
/// back to Data and decode into our domain types.
struct AnyDecodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = NSNull() }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else if let int = try? container.decode(Int.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let string = try? container.decode(String.self) { value = string }
        else if let array = try? container.decode([AnyDecodable].self) { value = array.map(\.value) }
        else if let dict = try? container.decode([String: AnyDecodable].self) {
            value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }
}

// MARK: - Claude Service

/// Service for interacting with Anthropic's Messages API. Exposes the same
/// interface as `OpenAIService` so they can be swapped via `AIServiceRegistry`.
final class ClaudeService: AIProviderService {
    static let shared = ClaudeService()

    private let log = OSLog(subsystem: "com.loopkit.Loop", category: "ClaudeService")
    private let session: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Primary vision/reasoning model.
    private let primaryModel = "claude-opus-4-5"
    /// Lightweight text classification model.
    private let classifierModel = "claude-haiku-4-5"

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - API Key + Request Builder

    private func getAPIKey() throws -> String {
        guard let apiKey = Bundle.main.object(forInfoDictionaryKey: "AnthropicAPIKey") as? String,
              !apiKey.isEmpty,
              apiKey != "$(ANTHROPIC_API_KEY)"
        else {
            os_log("Anthropic API key not configured in ConfigOverride.xcconfig", log: log, type: .error)
            throw OpenAIServiceError.missingAPIKey
        }
        return apiKey
    }

    private func buildRequest(apiKey: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func imageContent(_ imageData: Data) -> AnthropicContentBlock {
        .image(base64: imageData.base64EncodedString(), mediaType: "image/jpeg")
    }

    /// Forces structured output by defining a single tool and requiring its use.
    private func structuredOutputTool(name: String, description: String, schema: JSONSchemaDefinition) -> AnthropicTool {
        AnthropicTool(name: name, description: description, inputSchema: schema)
    }

    private func forceTool(named name: String) -> AnthropicToolChoice {
        AnthropicToolChoice(type: "tool", name: name)
    }

    // MARK: - Response Parsing

    /// Returns the structured `input` object from the first `tool_use` block, re-encoded
    /// as Data so callers can decode it into their domain types.
    private func extractToolInput(from response: AnthropicMessageResponse) throws -> Data {
        guard let toolBlock = response.content.first(where: { $0.type == "tool_use" }),
              let inputWrapper = toolBlock.input
        else {
            throw OpenAIServiceError.noContentInResponse
        }
        do {
            return try JSONSerialization.data(withJSONObject: inputWrapper.value, options: [])
        } catch {
            throw OpenAIServiceError.decodingError(error)
        }
    }

    /// Returns the concatenated text content (for text-only responses).
    private func extractText(from response: AnthropicMessageResponse) throws -> String {
        let text = response.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        guard !text.isEmpty else { throw OpenAIServiceError.noContentInResponse }
        return text
    }

    private func validateAndDecode(_ data: Data, _ response: URLResponse) throws -> AnthropicMessageResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIServiceError.invalidResponse(statusCode: 0)
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            os_log("Anthropic API error: status %d", log: log, type: .error, httpResponse.statusCode)
            if let errorBody = String(data: data, encoding: .utf8) {
                os_log("Error body: %{public}@", log: log, type: .error, errorBody)
            }
            throw mapAIHTTPError(statusCode: httpResponse.statusCode, body: data)
        }
        do {
            return try decoder.decode(AnthropicMessageResponse.self, from: data)
        } catch {
            throw OpenAIServiceError.decodingError(error)
        }
    }

    // MARK: - Schemas (reused from OpenAIService)

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

    private func buildConversationResponseSchema() -> JSONSchemaDefinition {
        let foodItemSchema = JSONSchemaProperty.object(
            properties: [
                "id": .string(description: "UUID of the item (same as original if updating, new UUID if adding)"),
                "name": .string(description: "Concise item description, max 30 chars"),
                "carbs": .number(description: "Estimated total carbohydrates in grams (not net carbs)"),
                "emoji": .string(description: "1-2 food emojis representing the item"),
                "fat": .number(description: "Estimated fat in grams"),
                "protein": .number(description: "Estimated protein in grams"),
                "source": .string(
                    description: "Data source: 'published' for verified restaurant data, 'estimated' for AI vision estimate"
                ),
                "servingCount": .number(
                    description: "Number of individual items in one serving. Preserve from previous turn. Use 1 if none."
                ),
                "servingUnit": .string(
                    description: "Unit for the serving count. Preserve from previous turn. Use 'Serving' if none."
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

    // MARK: - AIProviderService: Multi-Item Analysis

    func estimateCarbsMultiItem(from imageData: Data) async throws -> AIFoodItemsResponse {
        let apiKey = try getAPIKey()

        os_log("Sending food image for multi-item AI analysis (%d bytes)", log: log, type: .info, imageData.count)

        let prompt = """
        Analyze this food image for a diabetes insulin dosing app. Identify ALL individual food items visible and estimate total carbohydrate, fat, and protein content for each.

        IMPORTANT GUIDELINES:
        - List EACH distinct food item separately (e.g., for a meal with sandwich, apple, and drink - list all 3)
        - Include sides, drinks, sauces, and condiments as separate items
        - For composite items like sandwiches, list as one item but note components in the name
        - Estimate portion sizes based on visual cues
        - Choose 1-2 emojis per item that best represent it
        - Estimate fat and protein in grams for each item
        """

        let toolName = "food_analysis"
        let body = AnthropicMessageRequest(
            model: primaryModel,
            maxTokens: 1000,
            system: nil,
            messages: [
                AnthropicMessage(role: "user", content: [.text(prompt), imageContent(imageData)])
            ],
            tools: [structuredOutputTool(
                name: toolName,
                description: "Return structured food analysis results",
                schema: buildFoodAnalysisSchema()
            )],
            toolChoice: forceTool(named: toolName),
            stream: nil
        )

        var request = buildRequest(apiKey: apiKey)
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        let decoded = try validateAndDecode(data, response)
        let contentData = try extractToolInput(from: decoded)

        let analysisResponse: AIFoodAnalysisResponse
        do {
            analysisResponse = try decoder.decode(AIFoodAnalysisResponse.self, from: contentData)
        } catch {
            os_log("Failed to decode food analysis: %{public}@", log: log, type: .error, error.localizedDescription)
            throw OpenAIServiceError.decodingError(error)
        }

        let foodItems = analysisResponse.foodItems.map {
            AIFoodItem(name: $0.name, carbs: $0.carbs, emoji: $0.emoji, fat: $0.fat, protein: $0.protein)
        }
        guard !foodItems.isEmpty else {
            throw OpenAIServiceError.decodingError(NSError(
                domain: "ClaudeService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No food items found in response"]
            ))
        }

        os_log(
            "Claude detected %d food items with total %.1f grams of carbs",
            log: log, type: .info, foodItems.count,
            foodItems.reduce(0) { $0 + $1.carbs }
        )

        return AIFoodItemsResponse(
            foodItems: foodItems,
            overallConfidence: analysisResponse.overallConfidence
        )
    }

    // MARK: - AIProviderService: Legacy Single-Item Analysis

    func estimateCarbs(from imageData: Data) async throws -> OpenAICarbEstimateResponse {
        let apiKey = try getAPIKey()

        let prompt = """
        Analyze this food image for a diabetes insulin dosing app. Estimate total carbohydrate, fat, and protein content.

        Return these fields:
        - estimatedCarbs (grams)
        - foodDescription (emoji-only or emoji+text, max 25 chars)
        - emoji (1-3 food emojis)
        - detailedDescription (detailed description of food items and portions)
        - fat (grams)
        - protein (grams)
        - carbConfidence (0.0-1.0)
        - emojiConfidence (0.0-1.0)
        """

        let schema = JSONSchemaDefinition(
            type: "object",
            properties: [
                "estimatedCarbs": .number(),
                "foodDescription": .string(),
                "emoji": .string(),
                "detailedDescription": .string(),
                "fat": .number(),
                "protein": .number(),
                "carbConfidence": .number(),
                "emojiConfidence": .number()
            ],
            required: [
                "estimatedCarbs", "foodDescription", "emoji", "detailedDescription",
                "fat", "protein", "carbConfidence", "emojiConfidence"
            ],
            additionalProperties: false
        )

        let toolName = "carb_estimate"
        let body = AnthropicMessageRequest(
            model: primaryModel,
            maxTokens: 500,
            system: nil,
            messages: [AnthropicMessage(role: "user", content: [.text(prompt), imageContent(imageData)])],
            tools: [structuredOutputTool(name: toolName, description: "Return carb estimate", schema: schema)],
            toolChoice: forceTool(named: toolName),
            stream: nil
        )

        var request = buildRequest(apiKey: apiKey)
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        let decoded = try validateAndDecode(data, response)
        let contentData = try extractToolInput(from: decoded)

        struct Payload: Decodable {
            let estimatedCarbs: Double
            let foodDescription: String
            let emoji: String
            let detailedDescription: String
            let fat: Double
            let protein: Double
            let carbConfidence: Double
            let emojiConfidence: Double
        }

        let payload: Payload
        do { payload = try decoder.decode(Payload.self, from: contentData) }
        catch { throw OpenAIServiceError.decodingError(error) }

        return OpenAICarbEstimateResponse(
            estimatedCarbs: payload.estimatedCarbs,
            foodDescription: payload.foodDescription,
            emoji: payload.emoji,
            detailedDescription: payload.detailedDescription,
            fat: payload.fat,
            protein: payload.protein,
            carbConfidence: payload.carbConfidence,
            emojiConfidence: payload.emojiConfidence
        )
    }

    // MARK: - AIProviderService: Food Analysis with Reasoning

    func analyzeFood(imageData: Data, userDescription: String?) async throws -> AIFoodItemsResponseWithReasoning {
        let apiKey = try getAPIKey()

        var prompt = """
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
        if let description = userDescription, !description.isEmpty {
            prompt += "\n\nUSER CONTEXT: \(description)\nPlease factor this information into your analysis."
        }

        let toolName = "food_analysis_with_reasoning"
        let body = AnthropicMessageRequest(
            model: primaryModel,
            maxTokens: 1500,
            system: nil,
            messages: [AnthropicMessage(role: "user", content: [.text(prompt), imageContent(imageData)])],
            tools: [structuredOutputTool(
                name: toolName,
                description: "Return structured food analysis with reasoning",
                schema: buildFoodAnalysisWithReasoningSchema()
            )],
            toolChoice: forceTool(named: toolName),
            stream: nil
        )

        var request = buildRequest(apiKey: apiKey)
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        let decoded = try validateAndDecode(data, response)
        let contentData = try extractToolInput(from: decoded)

        let analysisResponse: AIFoodAnalysisWithReasoningResponse
        do {
            analysisResponse = try decoder.decode(AIFoodAnalysisWithReasoningResponse.self, from: contentData)
        } catch {
            throw OpenAIServiceError.decodingError(error)
        }

        let foodItems = analysisResponse.foodItems.map {
            AIFoodItem(
                name: $0.name, carbs: $0.carbs, emoji: $0.emoji,
                fat: $0.fat, protein: $0.protein,
                servingCount: max($0.servingCount, 1),
                servingUnit: $0.servingUnit.isEmpty ? "Serving" : $0.servingUnit
            )
        }
        guard !foodItems.isEmpty else {
            throw OpenAIServiceError.decodingError(NSError(
                domain: "ClaudeService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No food items found in response"]
            ))
        }
        return AIFoodItemsResponseWithReasoning(
            foodItems: foodItems,
            overallConfidence: analysisResponse.overallConfidence,
            reasoning: analysisResponse.reasoning
        )
    }

    // MARK: - AIProviderService: Streaming Food Analysis

    func analyzeFoodStreaming(
        imageData: Data,
        userDescription: String?
    ) -> AsyncThrowingStream<PartialFoodAnalysisResult, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let apiKey = try self.getAPIKey()

                    var prompt = """
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
                    if let description = userDescription, !description.isEmpty {
                        prompt += "\n\nUSER CONTEXT: \(description)\nPlease factor this information into your analysis."
                    }

                    let toolName = "food_analysis_with_reasoning"
                    let body = AnthropicMessageRequest(
                        model: self.primaryModel,
                        maxTokens: 1500,
                        system: nil,
                        messages: [AnthropicMessage(
                            role: "user",
                            content: [.text(prompt), self.imageContent(imageData)]
                        )],
                        tools: [self.structuredOutputTool(
                            name: toolName,
                            description: "Return structured food analysis with reasoning",
                            schema: self.buildFoodAnalysisWithReasoningSchema()
                        )],
                        toolChoice: self.forceTool(named: toolName),
                        stream: true
                    )

                    var request = self.buildRequest(apiKey: apiKey)
                    request.httpBody = try self.encoder.encode(body)

                    let (bytes, response) = try await self.session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw OpenAIServiceError.invalidResponse(statusCode: 0)
                    }
                    guard (200 ... 299).contains(httpResponse.statusCode) else {
                        os_log(
                            "Anthropic streaming API error: status %d",
                            log: self.log, type: .error, httpResponse.statusCode
                        )
                        var errorBody = Data()
                        for try await byte in bytes { errorBody.append(byte) }
                        throw mapAIHTTPError(statusCode: httpResponse.statusCode, body: errorBody)
                    }

                    let parser = StructuredJSONStreamParser()
                    var currentEvent = ""

                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.hasPrefix("event: ") {
                            currentEvent = String(trimmed.dropFirst(7))
                            continue
                        }
                        guard trimmed.hasPrefix("data: "), !currentEvent.isEmpty else { continue }

                        if let partial = parser.parseAnthropicEvent(event: currentEvent, dataLine: trimmed) {
                            continuation.yield(partial)
                            if partial.isComplete { break }
                        }
                    }

                    continuation.finish()

                } catch {
                    os_log(
                        "Claude streaming analysis failed: %{public}@",
                        log: self.log, type: .error, error.localizedDescription
                    )
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - AIProviderService: Single Item Update

    func updateSingleItem(
        imageData: Data,
        currentItems: [AIFoodItem],
        editedItemId: UUID,
        newDescription: String
    ) async throws -> AISingleItemUpdateResponse {
        let apiKey = try getAPIKey()

        guard let editedItem = currentItems.first(where: { $0.id == editedItemId }) else {
            throw OpenAIServiceError.decodingError(NSError(
                domain: "ClaudeService", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Item not found"]
            ))
        }

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

        let toolName = "single_item_update"
        let body = AnthropicMessageRequest(
            model: primaryModel,
            maxTokens: 500,
            system: nil,
            messages: [AnthropicMessage(role: "user", content: [.text(prompt), imageContent(imageData)])],
            tools: [structuredOutputTool(
                name: toolName, description: "Return updated single-item estimate",
                schema: buildSingleItemUpdateSchema()
            )],
            toolChoice: forceTool(named: toolName),
            stream: nil
        )

        var request = buildRequest(apiKey: apiKey)
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        let decoded = try validateAndDecode(data, response)
        let contentData = try extractToolInput(from: decoded)

        let apiResponse: AISingleItemUpdateAPIResponse
        do { apiResponse = try decoder.decode(AISingleItemUpdateAPIResponse.self, from: contentData) }
        catch { throw OpenAIServiceError.decodingError(error) }

        return AISingleItemUpdateResponse(
            itemId: editedItemId,
            updatedCarbs: apiResponse.updatedCarbs,
            reasoning: apiResponse.reasoning,
            updatedFat: apiResponse.updatedFat,
            updatedProtein: apiResponse.updatedProtein
        )
    }

    // MARK: - AIProviderService: Conversation Turn

    func conversationTurn(
        imageData: Data,
        currentItems: [AIFoodItem],
        conversationHistory: [AIConversationMessage],
        userMessage: String
    ) async throws -> AIConversationResponse {
        let apiKey = try getAPIKey()

        let itemsContext = currentItems.enumerated().map { index, item in
            let sourceLabel = item.source == .published ? " [PUBLISHED - verified from restaurant website]" : " [AI ESTIMATE]"
            return "[\(index + 1)] \(item.emoji ?? "") \(item.name): \(Int(item.carbs))g carbs, \(Int(item.fat))g fat, \(Int(item.protein))g protein\(sourceLabel)"
        }.joined(separator: "\n")

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

        let toolName = "conversation_response"
        let body = AnthropicMessageRequest(
            model: primaryModel,
            maxTokens: 1500,
            system: systemPrompt,
            messages: [
                AnthropicMessage(
                    role: "user",
                    content: [.text("Here is the food image for reference:"), imageContent(imageData)]
                ),
                AnthropicMessage(role: "user", content: [.text(userMessage)])
            ],
            tools: [structuredOutputTool(
                name: toolName, description: "Return updated food items and assistant response",
                schema: buildConversationResponseSchema()
            )],
            toolChoice: forceTool(named: toolName),
            stream: nil
        )

        var request = buildRequest(apiKey: apiKey)
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        let decoded = try validateAndDecode(data, response)
        let contentData = try extractToolInput(from: decoded)

        let apiResponse: AIConversationTurnAPIResponse
        do { apiResponse = try decoder.decode(AIConversationTurnAPIResponse.self, from: contentData) }
        catch { throw OpenAIServiceError.decodingError(error) }

        let originalItemsById = Dictionary(
            currentItems.map { ($0.id.uuidString.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let foodItems = apiResponse.foodItems.map { item in
            let itemId = UUID(uuidString: item.id) ?? UUID()
            let originalItem = originalItemsById[item.id.lowercased()]

            let source: AIFoodItemSource
            if let aiSource = item.source, aiSource == "published" {
                source = .published
            } else if let original = originalItem {
                source = original.source
            } else {
                source = .estimated
            }

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

        return AIConversationResponse(
            foodItems: foodItems,
            updatedItemIds: updatedItemIds,
            assistantMessage: apiResponse.assistantMessage,
            overallConfidence: apiResponse.overallConfidence
        )
    }

    // MARK: - AIProviderService: Nutrition Lookup Intent Classification

    func classifyNutritionLookupIntent(
        userMessage: String,
        currentItems: [AIFoodItem],
        restaurantName: String
    ) async throws -> NutritionLookupIntent {
        let apiKey = try getAPIKey()

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

        let schema = JSONSchemaDefinition(
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

        let toolName = "nutrition_lookup_intent"
        let body = AnthropicMessageRequest(
            model: classifierModel,
            maxTokens: 200,
            system: systemPrompt,
            messages: [AnthropicMessage(role: "user", content: [.text(userMessage)])],
            tools: [structuredOutputTool(
                name: toolName, description: "Classify whether the message is a nutrition lookup", schema: schema
            )],
            toolChoice: forceTool(named: toolName),
            stream: nil
        )

        var request = buildRequest(apiKey: apiKey)
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        let decoded = try validateAndDecode(data, response)
        let contentData = try extractToolInput(from: decoded)

        return try decoder.decode(NutritionLookupIntent.self, from: contentData)
    }
}
