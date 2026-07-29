import Foundation
import Testing

@testable import Trio

@Suite("OpenRouter Model Configuration") struct OpenRouterModelConfigurationTests {
    @Test("Selection normalization enforces unique one-to-four bounds") func normalizesSelectionBounds() {
        let configuration = OpenRouterModelConfiguration(
            selectedModelIDs: ["a/one", "a/one", "b/two", "c/three", "d/four", "e/five"],
            defaultModelID: "missing/model"
        )

        #expect(configuration.selectedModelIDs == ["a/one", "b/two", "c/three", "d/four"])
        #expect(configuration.defaultModelID == "a/one")

        let empty = OpenRouterModelConfiguration(selectedModelIDs: [], defaultModelID: "")
        #expect(empty.selectedModelIDs == [OpenRouterModels.defaultModelID])
        #expect(empty.defaultModelID == OpenRouterModels.defaultModelID)
    }

    @Test("Removing the default deterministically selects its successor") func removesDefault() {
        var configuration = OpenRouterModelConfiguration(
            selectedModelIDs: ["a/one", "b/two", "c/three"],
            defaultModelID: "b/two"
        )

        #expect(configuration.remove("b/two"))
        #expect(configuration.selectedModelIDs == ["a/one", "c/three"])
        #expect(configuration.defaultModelID == "c/three")
        #expect(!configuration.remove("missing/model"))
    }

    @Test("Ordering and simultaneous execution survive persistence") func roundTrip() throws {
        var configuration = OpenRouterModelConfiguration(
            selectedModelIDs: ["a/one", "b/two", "c/three"],
            defaultModelID: "c/three",
            runAllModelsSimultaneously: true
        )
        configuration.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        let decoded = try JSONDecoder().decode(
            OpenRouterModelConfiguration.self,
            from: JSONEncoder().encode(configuration)
        )
        #expect(decoded.selectedModelIDs == ["c/three", "a/one", "b/two"])
        #expect(decoded.defaultModelID == "c/three")
        #expect(decoded.runAllModelsSimultaneously)
        #expect(decoded.initialModelIDs == decoded.selectedModelIDs)
    }

    @Test("Lazy execution initially dispatches only the default model") func lazyExecution() {
        let configuration = OpenRouterModelConfiguration(
            selectedModelIDs: ["a/one", "b/two", "c/three"],
            defaultModelID: "b/two"
        )

        #expect(configuration.selectedModelIDs == ["a/one", "b/two", "c/three"])
        #expect(configuration.initialModelIDs == ["b/two"])
    }
}

@Suite("Trio Settings AI Model Migration") struct TrioSettingsAIModelMigrationTests {
    @Test("Legacy provider migrates to its stable OpenRouter model ID") func migratesLegacyProvider() throws {
        let data = Data(#"{"aiProvider":"claude","sendToAllAIProvidersSimultaneously":false}"#.utf8)
        let settings = try JSONDecoder().decode(TrioSettings.self, from: data)

        #expect(settings.openRouterModelConfiguration.selectedModelIDs == [OpenRouterModels.legacyClaudeModelID])
        #expect(settings.openRouterModelConfiguration.defaultModelID == OpenRouterModels.legacyClaudeModelID)
    }

    @Test("Legacy comparison migrates to two lazy model tabs") func migratesLegacyComparison() throws {
        let data = Data(#"{"aiProvider":"claude","sendToAllAIProvidersSimultaneously":true}"#.utf8)
        let settings = try JSONDecoder().decode(TrioSettings.self, from: data)

        #expect(settings.openRouterModelConfiguration.selectedModelIDs == [
            OpenRouterModels.defaultModelID,
            OpenRouterModels.legacyClaudeModelID
        ])
        #expect(settings.openRouterModelConfiguration.defaultModelID == OpenRouterModels.legacyClaudeModelID)
        #expect(!settings.openRouterModelConfiguration.runAllModelsSimultaneously)
    }

    @Test("New configuration takes precedence over legacy fields") func newConfigurationWins() throws {
        let data = Data(#"""
        {
          "aiProvider":"openai",
          "sendToAllAIProvidersSimultaneously":true,
          "openRouterModelConfiguration":{
            "selectedModelIDs":["google/gemini-test"],
            "defaultModelID":"google/gemini-test",
            "runAllModelsSimultaneously":true
          }
        }
        """#.utf8)
        let settings = try JSONDecoder().decode(TrioSettings.self, from: data)

        #expect(settings.openRouterModelConfiguration.selectedModelIDs == ["google/gemini-test"])
        #expect(settings.openRouterModelConfiguration.defaultModelID == "google/gemini-test")
        #expect(settings.openRouterModelConfiguration.runAllModelsSimultaneously)
    }
}

@Suite("OpenRouter Model Catalog") struct OpenRouterModelCatalogTests {
    @Test("Catalog metadata identifies food-analysis compatibility") func decodesCapabilities() throws {
        let data = Data(#"""
        {
          "data":[
            {
              "id":"example/vision-model",
              "name":"Vision Model",
              "description":"A compatible model",
              "context_length":128000,
              "architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},
              "pricing":{"prompt":"0.000001","completion":"0.000002"},
              "supported_parameters":["response_format","tools"]
            },
            {
              "id":"example/text-model",
              "name":"Text Model",
              "architecture":{"input_modalities":["text"],"output_modalities":["text"]},
              "supported_parameters":["response_format"]
            }
          ]
        }
        """#.utf8)
        let catalog = try JSONDecoder().decode(OpenRouterModelCatalogResponse.self, from: data)

        let vision = try #require(catalog.data.first)
        #expect(vision.providerName == "Example")
        #expect(vision.contextLength == 128_000)
        #expect(vision.supportsImages)
        #expect(vision.supportsStructuredResponses)
        #expect(vision.supportsTools)
        #expect(vision.isFoodAnalysisCompatible)
        #expect(vision.pricePerMillionTokens(vision.pricing?.prompt) == "1")
        #expect(vision.pricePerMillionTokens("-1") == nil)
        #expect(!catalog.data[1].isFoodAnalysisCompatible)
        #expect(OpenRouterModelCatalogService.normalizedModels([vision, vision]) == [vision])
    }

    @Test("Favorites persist independently of catalog availability") func favoritesPersist() {
        let suiteName = "OpenRouterModelCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = OpenRouterModelCatalogService(defaults: defaults)

        service.favoriteModelIDs = ["missing/model", "example/vision-model"]

        #expect(service.favoriteModelIDs == ["missing/model", "example/vision-model"])
    }
}

// MARK: - Test data from real SSE stream

/// Each entry is the accumulated JSON content after receiving a chunk from the OpenAI SSE stream.
/// These are real values captured from a streaming food analysis response.
private let streamSnapshots: [(accumulated: String, expectedItemCount: Int, expectedItems: [ExpectedItem])] = [
    // Chunk: '{"'
    (
        accumulated: "{\"",
        expectedItemCount: 0,
        expectedItems: []
    ),
    // Chunk: 'food'
    (
        accumulated: "{\"food",
        expectedItemCount: 0,
        expectedItems: []
    ),
    // Chunk: 'Items'
    (
        accumulated: "{\"foodItems",
        expectedItemCount: 0,
        expectedItems: []
    ),
    // Chunk: '":['
    (
        accumulated: "{\"foodItems\":[",
        expectedItemCount: 0,
        expectedItems: []
    ),
    // Chunk: '{"' — empty object started in array
    (
        accumulated: "{\"foodItems\":[{\"",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem()]
    ),
    // Chunk: 'fat' — partial key "fat" is dangling, gets stripped → empty object
    (
        accumulated: "{\"foodItems\":[{\"fat",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem()]
    ),
    // Chunk: '":' — "fat": with no value, gets stripped → empty object
    (
        accumulated: "{\"foodItems\":[{\"fat\":",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem()]
    ),
    // Chunk: '10' — now we have {"fat":10}
    (
        accumulated: "{\"foodItems\":[{\"fat\":10",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(fat: 10)]
    ),
    // Chunk: ',"' — dangling key after comma, stripped → {"fat":10}
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(fat: 10)]
    ),
    // Chunk: 'name' — "name" is dangling key, stripped → {"fat":10}
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"name",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(fat: 10)]
    ),
    // Chunk: '":"' — "name":"" closes to empty string
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"name\":\"",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(name: "", fat: 10)]
    ),
    // Chunk: 'S'
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"name\":\"S",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(name: "S", fat: 10)]
    ),
    // Chunk: 'aus'
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"name\":\"Saus",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(name: "Saus", fat: 10)]
    ),
    // Chunk: 'age'
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"name\":\"Sausage",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(name: "Sausage", fat: 10)]
    ),
    // Chunk: ' links'
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"name\":\"Sausage links",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(name: "Sausage links", fat: 10)]
    ),
    // Chunk: '","' — dangling key after comma, stripped
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"name\":\"Sausage links\",\"",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(name: "Sausage links", fat: 10)]
    ),
    // Chunk: 'car' — "car" is dangling key, stripped
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"name\":\"Sausage links\",\"car",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(name: "Sausage links", fat: 10)]
    ),
    // Chunk: 'bs' — "carbs" is dangling key, stripped
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"name\":\"Sausage links\",\"carbs",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(name: "Sausage links", fat: 10)]
    ),
    // Chunk: '":' — "carbs": with no value, stripped
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"name\":\"Sausage links\",\"carbs\":",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(name: "Sausage links", fat: 10)]
    ),
    // Chunk: '1' — NOW we have name + carbs, should parse 1 item!
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"name\":\"Sausage links\",\"carbs\":1",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(name: "Sausage links", carbs: 1, fat: 10)]
    ),
    // Chunk: ',"'
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"name\":\"Sausage links\",\"carbs\":1,\"",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(name: "Sausage links", carbs: 1, fat: 10)]
    ),
    // Chunk: 'emoji' — "emoji" is dangling key, stripped
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"name\":\"Sausage links\",\"carbs\":1,\"emoji",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(name: "Sausage links", carbs: 1, fat: 10, emoji: "")]
    ),
    // Chunk: '":"' — emoji key has open quote, closes to empty string
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"name\":\"Sausage links\",\"carbs\":1,\"emoji\":\"",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(name: "Sausage links", carbs: 1, fat: 10, emoji: "")]
    ),
    // Chunk: emoji character
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"name\":\"Sausage links\",\"carbs\":1,\"emoji\":\"\u{1F32D}",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(name: "Sausage links", carbs: 1, fat: 10, emoji: "\u{1F32D}")]
    ),
    // Chunk: '","'
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"name\":\"Sausage links\",\"carbs\":1,\"emoji\":\"\u{1F32D}\",\"",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(name: "Sausage links", carbs: 1, fat: 10, emoji: "\u{1F32D}")]
    ),
    // Chunk: 'protein' — dangling key, stripped
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"name\":\"Sausage links\",\"carbs\":1,\"emoji\":\"\u{1F32D}\",\"protein",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(name: "Sausage links", carbs: 1, fat: 10, protein: 0, emoji: "\u{1F32D}")]
    ),
    // Chunk: '":' — dangling colon, no value yet, stripped
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"name\":\"Sausage links\",\"carbs\":1,\"emoji\":\"\u{1F32D}\",\"protein\":",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(name: "Sausage links", carbs: 1, fat: 10, protein: 0, emoji: "\u{1F32D}")]
    ),
    // Chunk: '10' — protein value arrives
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"name\":\"Sausage links\",\"carbs\":1,\"emoji\":\"\u{1F32D}\",\"protein\":10",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(name: "Sausage links", carbs: 1, fat: 10, protein: 10, emoji: "\u{1F32D}")]
    ),
    // Chunk: '},{"' — first item closed, second item starts
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"name\":\"Sausage links\",\"carbs\":1,\"emoji\":\"\u{1F32D}\",\"protein\":10},{\"",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(name: "Sausage links", carbs: 1, fat: 10, protein: 10, emoji: "\u{1F32D}")]
    ),
    // Chunk: 'fat'
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"name\":\"Sausage links\",\"carbs\":1,\"emoji\":\"\u{1F32D}\",\"protein\":10},{\"fat",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(name: "Sausage links", carbs: 1, fat: 10, protein: 10, emoji: "\u{1F32D}")]
    ),
    // Chunk: '":' — second item fat key with colon but no value
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"name\":\"Sausage links\",\"carbs\":1,\"emoji\":\"\u{1F32D}\",\"protein\":10},{\"fat\":",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(name: "Sausage links", carbs: 1, fat: 10, protein: 10, emoji: "\u{1F32D}")]
    ),
    // Chunk: '7' — second item has fat:7 but still no name/carbs
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"name\":\"Sausage links\",\"carbs\":1,\"emoji\":\"\u{1F32D}\",\"protein\":10},{\"fat\":7",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(name: "Sausage links", carbs: 1, fat: 10, protein: 10, emoji: "\u{1F32D}")]
    ),
    // Chunk: ',"' — continuing second item
    (
        accumulated: "{\"foodItems\":[{\"fat\":10,\"name\":\"Sausage links\",\"carbs\":1,\"emoji\":\"\u{1F32D}\",\"protein\":10},{\"fat\":7,\"",
        expectedItemCount: 1,
        expectedItems: [ExpectedItem(name: "Sausage links", carbs: 1, fat: 10, protein: 10, emoji: "\u{1F32D}")]
    )
]

/// Simple struct to define expected parse results
private struct ExpectedItem: Equatable {
    let name: String
    let carbs: Double
    let fat: Double
    let protein: Double
    let emoji: String?

    init(name: String = "", carbs: Double = 0.0, fat: Double = 0.0, protein: Double = 0.0, emoji: String? = nil) {
        self.name = name
        self.carbs = carbs
        self.fat = fat
        self.protein = protein
        self.emoji = emoji
    }
}

@Suite("Immediate Food Analysis Requests") struct ImmediateFoodAnalysisRequestTests {
    @Test("Description refinement preserves the exact base image-message prefix") func refinementPreservesBasePrefix() throws {
        let imageData = Data([0x01, 0x02, 0x03, 0x04])
        let initialResponse = AIFoodItemsResponseWithReasoning(
            foodItems: [
                AIFoodItem(
                    name: "Toast",
                    carbs: 24,
                    emoji: "🍞",
                    fat: 2,
                    protein: 4
                )
            ],
            overallConfidence: 0.9,
            reasoning: "One visible slice."
        )
        let descriptionMarker = "CACHE_ADDENDUM_MARKER"

        let baseMessages = FoodAnalysisRequestBuilder.initialMessages(imageData: imageData)
        let refinementMessages = try FoodAnalysisRequestBuilder.refinementMessages(
            imageData: imageData,
            initialResponse: initialResponse,
            userDescription: descriptionMarker
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let basePrefix = try encoder.encode(baseMessages[0])
        let refinementPrefix = try encoder.encode(refinementMessages[0])

        #expect(basePrefix == refinementPrefix)
        #expect(refinementMessages.map(\.role) == ["user", "assistant", "user"])
        #expect(!String(decoding: basePrefix, as: UTF8.self).contains(descriptionMarker))
        #expect(
            String(decoding: try encoder.encode(refinementMessages[2]), as: UTF8.self)
                .contains(descriptionMarker)
        )
    }

    @Test("Streaming requests encode usage reporting and a stable session ID") func streamingRequestMetadata() throws {
        let request = OpenAIChatRequest(
            model: "test/model",
            messages: FoodAnalysisRequestBuilder.initialMessages(imageData: Data([0x01])),
            maxTokens: 1500,
            responseFormat: nil,
            stream: true,
            streamOptions: OpenAIStreamOptions(includeUsage: true),
            sessionID: "capture-session"
        )

        let data = try JSONEncoder().encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let streamOptions = try #require(json["stream_options"] as? [String: Any])

        #expect(json["session_id"] as? String == "capture-session")
        #expect(streamOptions["include_usage"] as? Bool == true)
    }
}

@Suite("AI Prompt Settings") struct AIPromptSettingsTests {
    @Test("Obsolete prompt values are removed without affecting active prompts") func removesObsoletePromptValues() {
        let suiteName = "AIPromptSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let obsoleteKeys = [
            "aiPrompt.enhancedFoodAnalysis",
            "aiPrompt.multiItemFoodAnalysis",
            "aiPrompt.legacyFoodAnalysis",
            "aiPrompt.didSplitFoodAnalysisPrompt"
        ]
        obsoleteKeys.forEach { defaults.set("obsolete", forKey: $0) }
        defaults.set("active image prompt", forKey: "aiFoodAnalysisPrompt")
        defaults.set("active conversation prompt", forKey: "aiPrompt.conversationRefinement")

        AIPromptSettings.removeObsoletePromptValues(defaults: defaults)
        AIPromptSettings.removeObsoletePromptValues(defaults: defaults)

        #expect(obsoleteKeys.allSatisfy { defaults.object(forKey: $0) == nil })
        #expect(defaults.string(forKey: "aiFoodAnalysisPrompt") == "active image prompt")
        #expect(defaults.string(forKey: "aiPrompt.conversationRefinement") == "active conversation prompt")
    }
}

// MARK: - Tests

@Suite("OpenAI Streaming Parser Tests") struct OpenAIStreamingParserTests {
    // MARK: - closePartialJSON Tests

    @Test("closePartialJSON produces valid JSON for every stream snapshot") func testClosePartialJSONProducesValidJSON() {
        let parser = OpenAIStreamingParser()

        for (index, snapshot) in streamSnapshots.enumerated() {
            let closed = parser.closePartialJSON(snapshot.accumulated)
            let data = closed.data(using: .utf8)!
            let parsed = try? JSONSerialization.jsonObject(with: data)

            #expect(
                parsed != nil,
                """
                Snapshot \(index) failed to produce valid JSON.
                Input:  \(snapshot.accumulated)
                Closed: \(closed)
                """
            )
        }
    }

    @Test("Partial parser extracts correct item count at each snapshot") func testPartialParserItemCounts() {
        let parser = OpenAIStreamingParser()

        for (index, snapshot) in streamSnapshots.enumerated() {
            let closed = parser.closePartialJSON(snapshot.accumulated)
            guard let data = closed.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                // If it doesn't parse, we expect 0 items
                #expect(
                    snapshot.expectedItemCount == 0,
                    "Snapshot \(index): expected \(snapshot.expectedItemCount) items but JSON didn't parse"
                )
                continue
            }

            let foodItems = dict["foodItems"] as? [[String: Any]] ?? []

            #expect(
                foodItems.count == snapshot.expectedItemCount,
                """
                Snapshot \(index): expected \(snapshot.expectedItemCount) valid items, got \(foodItems.count).
                Input:  \(snapshot.accumulated)
                Closed: \(closed)
                Parsed foodItems: \(foodItems)
                """
            )
        }
    }

    @Test("Partial parser extracts correct item values at each snapshot") func testPartialParserItemValues() {
        let parser = OpenAIStreamingParser()

        for (index, snapshot) in streamSnapshots.enumerated() {
            let closed = parser.closePartialJSON(snapshot.accumulated)
            guard let data = closed.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let foodItems = dict["foodItems"] as? [[String: Any]] ?? []

            for (itemIndex, expected) in snapshot.expectedItems.enumerated() {
                guard itemIndex < foodItems.count else {
                    Issue
                        .record(
                            "Snapshot \(index): expected item at index \(itemIndex) but only \(foodItems.count) items parsed"
                        )
                    continue
                }

                let item = foodItems[itemIndex]

                let name = item["name"] as? String ?? ""
                let carbs = item["carbs"] as? Double ?? 0
                let fat = item["fat"] as? Double ?? 0
                let protein = item["protein"] as? Double ?? 0
                let emoji = item["emoji"] as? String

                #expect(
                    name == expected.name,
                    "Snapshot \(index) item \(itemIndex): name '\(name)' != '\(expected.name)'"
                )
                #expect(
                    carbs == expected.carbs,
                    "Snapshot \(index) item \(itemIndex): carbs \(carbs) != \(expected.carbs)"
                )
                #expect(
                    fat == expected.fat,
                    "Snapshot \(index) item \(itemIndex): fat \(fat) != \(expected.fat)"
                )
                #expect(
                    protein == expected.protein,
                    "Snapshot \(index) item \(itemIndex): protein \(protein) != \(expected.protein)"
                )
                #expect(
                    emoji == expected.emoji,
                    "Snapshot \(index) item \(itemIndex): emoji '\(emoji ?? "nil")' != '\(expected.emoji ?? "nil")'"
                )
            }
        }
    }

    // MARK: - closePartialJSON edge cases

    @Test("Closes mid-string correctly") func testClosesMidString() {
        let parser = OpenAIStreamingParser()
        let input = "{\"name\":\"Sausage li"
        let closed = parser.closePartialJSON(input)
        let data = closed.data(using: .utf8)!
        let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(dict != nil)
        #expect(dict?["name"] as? String == "Sausage li")
    }

    @Test("Handles dangling colon with no value") func testDanglingColon() {
        let parser = OpenAIStreamingParser()
        let input = "{\"fat\":10,\"name\":"
        let closed = parser.closePartialJSON(input)
        let data = closed.data(using: .utf8)!
        let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(dict != nil)
        #expect(dict?["fat"] as? Double == 10)
        // "name": resolves to empty string since "name" is a known string field
        #expect(dict?["name"] as? String == "")
    }

    @Test("Handles dangling partial key") func testDanglingPartialKey() {
        let parser = OpenAIStreamingParser()
        let input = "{\"fat\":10,\"car"
        let closed = parser.closePartialJSON(input)
        let data = closed.data(using: .utf8)!
        let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(dict != nil)
        #expect(dict?["fat"] as? Double == 10)
    }

    @Test("Handles nested array with incomplete second object") func testIncompleteSecondObject() {
        let parser = OpenAIStreamingParser()
        let input = "{\"items\":[{\"a\":1},{\"b\":"
        let closed = parser.closePartialJSON(input)
        let data = closed.data(using: .utf8)!
        let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(dict != nil)
        let items = dict?["items"] as? [[String: Any]]
        #expect(items != nil)
        // Trailing incomplete object after a complete one is stripped
        #expect(items?.count == 1)
        #expect(items?[0]["a"] as? Double == 1)
    }

    @Test("Handles escaped quotes in strings") func testEscapedQuotes() {
        let parser = OpenAIStreamingParser()
        let input = "{\"name\":\"Turkey \\\"special\\\" sandwich\",\"carbs\":30"
        let closed = parser.closePartialJSON(input)
        let data = closed.data(using: .utf8)!
        let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(dict != nil)
        #expect(dict?["carbs"] as? Double == 30)
    }

    @Test("Empty input produces valid JSON") func testEmptyInput() {
        let parser = OpenAIStreamingParser()
        let closed = parser.closePartialJSON("")
        #expect(closed == "")
    }

    @Test("Complete JSON passes through unchanged (modulo closing)") func testCompleteJSON() {
        let parser = OpenAIStreamingParser()
        let input = "{\"foodItems\":[{\"name\":\"Rice\",\"carbs\":45}],\"overallConfidence\":0.9}"
        let closed = parser.closePartialJSON(input)
        let data = closed.data(using: .utf8)!
        let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(dict != nil)
        let items = dict?["foodItems"] as? [[String: Any]]
        #expect(items?.count == 1)
        #expect(items?[0]["name"] as? String == "Rice")
        #expect(items?[0]["carbs"] as? Double == 45)
        #expect(dict?["overallConfidence"] as? Double == 0.9)
    }
}
