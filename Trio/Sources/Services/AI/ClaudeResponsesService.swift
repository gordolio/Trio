import Foundation
import os.log

/// Service for restaurant food detection and published nutrition lookup using
/// Anthropic's Messages API. Mirrors `OpenAIResponsesService` so the two can be
/// swapped via `AIServiceRegistry`.
final class ClaudeResponsesService: AIResponsesProviderService {
    static let shared = ClaudeResponsesService()

    private let log = OSLog(subsystem: "com.loopkit.Loop", category: "ClaudeResponsesService")
    private let session: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private let primaryModel = "claude-opus-4-5"
    private let classifierModel = "claude-haiku-4-5"

    init(session: URLSession = .shared) {
        self.session = session
    }

    private func getAPIKey() throws -> String {
        guard let apiKey = Bundle.main.object(forInfoDictionaryKey: "AnthropicAPIKey") as? String,
              !apiKey.isEmpty,
              apiKey != "$(ANTHROPIC_API_KEY)"
        else {
            os_log("Anthropic API key not configured", log: log, type: .error)
            throw OpenAIServiceError.missingAPIKey
        }
        return apiKey
    }

    private func buildRequest(apiKey: String, extraBetas: [String] = []) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !extraBetas.isEmpty {
            request.setValue(extraBetas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        return request
    }

    // MARK: - Request Body

    private struct RequestBody: Encodable {
        let model: String
        let maxTokens: Int
        let system: String?
        let messages: [Message]
        let tools: [Tool]?
        let toolChoice: ToolChoice?

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case system
            case messages
            case tools
            case toolChoice = "tool_choice"
        }
    }

    private struct Message: Encodable {
        let role: String
        let content: [Content]
    }

    private enum Content: Encodable {
        case text(String)

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .text(text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            }
        }

        enum CodingKeys: String, CodingKey {
            case type
            case text
        }
    }

    private enum Tool: Encodable {
        case custom(name: String, description: String, inputSchema: JSONSchemaDefinition)
        case webSearch(name: String, maxUses: Int)

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .custom(name, description, schema):
                try container.encode(name, forKey: .name)
                try container.encode(description, forKey: .description)
                try container.encode(schema, forKey: .inputSchema)
            case let .webSearch(name, maxUses):
                try container.encode("web_search_20250305", forKey: .type)
                try container.encode(name, forKey: .name)
                try container.encode(maxUses, forKey: .maxUses)
            }
        }

        enum CodingKeys: String, CodingKey {
            case type
            case name
            case description
            case inputSchema = "input_schema"
            case maxUses = "max_uses"
        }
    }

    private struct ToolChoice: Encodable {
        let type: String
        let name: String?
    }

    // MARK: - Response Parsing

    private struct Response: Decodable {
        let content: [ResponseBlock]
    }

    /// A content block in Anthropic's response. We care about:
    /// - `tool_use` — the forced structured-output tool, with `input` as our result
    /// - `server_tool_use` — Anthropic's internal web-search invocation
    /// - `web_search_tool_result` — citations from the search
    private struct ResponseBlock: Decodable {
        let type: String
        let name: String?
        let input: AnyDecodable?
        let content: [WebSearchResultItem]?

        enum CodingKeys: String, CodingKey {
            case type
            case name
            case input
            case content
        }
    }

    private struct WebSearchResultItem: Decodable {
        let type: String
        let url: String?
        let title: String?
    }

    private func validateAndDecode(_ data: Data, _ response: URLResponse) throws -> Response {
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
        do { return try decoder.decode(Response.self, from: data) }
        catch { throw OpenAIServiceError.decodingError(error) }
    }

    private func toolInput(from response: Response, toolName: String) throws -> Data {
        guard let block = response.content.first(where: { $0.type == "tool_use" && $0.name == toolName }),
              let wrapper = block.input
        else { throw OpenAIServiceError.noContentInResponse }
        do { return try JSONSerialization.data(withJSONObject: wrapper.value, options: []) }
        catch { throw OpenAIServiceError.decodingError(error) }
    }

    private func firstWebSearchURL(from response: Response) -> String? {
        for block in response.content where block.type == "web_search_tool_result" {
            if let first = block.content?.first(where: { $0.type == "web_search_result" })?.url {
                return first
            }
        }
        return nil
    }

    // MARK: - Agent 1: Restaurant Classifier

    func classifyRestaurantItem(description: String) async throws -> RestaurantClassifierResponse {
        let apiKey = try getAPIKey()

        os_log(
            "Classifying description for restaurant item: %{public}@",
            log: log, type: .info, description
        )

        let systemPrompt = """
        You are a food classifier. Determine if the user's text describes a menu item \
        from a restaurant, fast food chain, coffee shop, or branded food product that \
        would have officially published nutrition information available online.

        Examples of YES: "Big Mac from McDonald's", "Starbucks caramel latte", \
        "Chipotle burrito bowl", "Subway footlong Italian BMT", "Whopper from Burger King", \
        "Chick-fil-A sandwich", "Domino's pepperoni pizza medium"

        Examples of NO: "homemade pasta", "rice and chicken", "some fruit", \
        "sandwich" (generic, no brand), "salad", "my mom's lasagna"

        If yes, extract the restaurant/brand name and the specific menu item name. \
        If the text is ambiguous but leans toward a known chain, classify as yes with lower confidence.
        """

        let schema = JSONSchemaDefinition(
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
                "confidence": .number(description: "Confidence in the classification (0.0-1.0)")
            ],
            required: ["isRestaurantItem", "restaurantName", "menuItemName", "confidence"],
            additionalProperties: false
        )

        let toolName = "restaurant_classifier"
        let body = RequestBody(
            model: classifierModel,
            maxTokens: 200,
            system: systemPrompt,
            messages: [Message(role: "user", content: [.text(description)])],
            tools: [.custom(name: toolName, description: "Classify whether input is a restaurant item", inputSchema: schema)],
            toolChoice: ToolChoice(type: "tool", name: toolName)
        )

        var request = buildRequest(apiKey: apiKey)
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        let decoded = try validateAndDecode(data, response)
        let contentData = try toolInput(from: decoded, toolName: toolName)

        let result: RestaurantClassifierResponse
        do { result = try decoder.decode(RestaurantClassifierResponse.self, from: contentData) }
        catch { throw OpenAIServiceError.decodingError(error) }

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

    func searchPublishedNutrition(
        restaurantName: String,
        menuItemName: String
    ) async throws -> PublishedNutritionResult {
        let apiKey = try getAPIKey()

        os_log(
            "Searching published nutrition for %{public}@ - %{public}@",
            log: log, type: .info, restaurantName, menuItemName
        )

        let userPrompt = """
        Look up the official published nutrition facts for "\(menuItemName)" from "\(restaurantName)".

        STRONGLY PREFER the restaurant's own official website (e.g., \(restaurantName.lowercased()).com/nutrition \
        or the restaurant's official nutrition PDF). Only use third-party nutrition databases as a fallback \
        if the official source is unavailable.

        After you have found the nutrition facts via web search, call the `published_nutrition` tool \
        with the result. Return these fields:
        - restaurantName (just the brand)
        - menuItemName (ONLY the menu item name, without the restaurant or brand)
        - carbs (grams)
        - fat (grams)
        - protein (grams)
        - calories
        - sourceURL (the actual URL of the webpage where the info was found; prefer the restaurant's own domain)
        - confidence (0.0-1.0; lower if the exact item wasn't found)
        - servingCount (e.g., 8 for "8-count nugget"; 1 for a single sandwich)
        - servingCountUnit (e.g., "Nuggets", "Pieces"; use "Serving" if not countable)
        """

        let schema = JSONSchemaDefinition(
            type: "object",
            properties: [
                "restaurantName": .string(description: "Name of the restaurant or brand"),
                "menuItemName": .string(description: "Name of the menu item only, without the restaurant or brand name"),
                "carbs": .number(description: "Total carbohydrates in grams"),
                "fat": .number(description: "Total fat in grams"),
                "protein": .number(description: "Protein in grams"),
                "calories": .number(description: "Total calories"),
                "sourceURL": .string(description: "URL of the webpage where nutrition facts were found"),
                "confidence": .number(description: "Confidence (0.0-1.0)"),
                "servingCount": .number(description: "Number of individual items in one serving"),
                "servingCountUnit": .string(description: "Unit for the serving count")
            ],
            required: [
                "restaurantName", "menuItemName", "carbs", "fat", "protein", "calories",
                "sourceURL", "confidence", "servingCount", "servingCountUnit"
            ],
            additionalProperties: false
        )

        let toolName = "published_nutrition"
        let body = RequestBody(
            model: primaryModel,
            maxTokens: 2000,
            system: nil,
            messages: [Message(role: "user", content: [.text(userPrompt)])],
            tools: [
                .webSearch(name: "web_search", maxUses: 3),
                .custom(name: toolName, description: "Return the looked-up nutrition facts", inputSchema: schema)
            ],
            toolChoice: nil
        )

        var request = buildRequest(apiKey: apiKey)
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        let decoded = try validateAndDecode(data, response)
        let contentData = try toolInput(from: decoded, toolName: toolName)

        struct Payload: Decodable {
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

        let payload: Payload
        do { payload = try decoder.decode(Payload.self, from: contentData) }
        catch { throw OpenAIServiceError.decodingError(error) }

        let finalSourceURL = payload.sourceURL.isEmpty ? (firstWebSearchURL(from: decoded) ?? "") : payload.sourceURL

        os_log(
            "Claude found published nutrition: %{public}@ %{public}@ - carbs: %.0fg, fat: %.0fg, protein: %.0fg, cal: %.0f",
            log: log, type: .info,
            payload.restaurantName, payload.menuItemName,
            payload.carbs, payload.fat, payload.protein, payload.calories
        )

        return PublishedNutritionResult(
            restaurantName: payload.restaurantName,
            menuItemName: payload.menuItemName,
            carbs: payload.carbs,
            fat: payload.fat,
            protein: payload.protein,
            calories: payload.calories,
            sourceURL: finalSourceURL,
            confidence: payload.confidence,
            servingCount: payload.servingCount,
            servingCountUnit: payload.servingCountUnit
        )
    }
}
