import Foundation
import Testing

@testable import Trio

@Suite("Image Decision Routing", .serialized) struct ImageDecisionRoutingTests {
    @Test("Catalog excludes text-only decisions and separates calculation models") func catalogCompatibility() throws {
        let imageDecision = try JSONDecoder().decode(
            OpenRouterModel.self,
            from: Data(
                #"{"id":"vendor/vision","name":"Vision","architecture":{"input_modalities":["text","image"],"output_modalities":["decisions"]},"supported_parameters":["response_format"]}"#
                    .utf8
            )
        )
        let textDecision = try JSONDecoder().decode(
            OpenRouterModel.self,
            from: Data(
                #"{"id":"vendor/text","name":"Text","architecture":{"input_modalities":["text"],"output_modalities":["decisions"]}}"#
                    .utf8
            )
        )
        #expect(imageDecision.isImageDecisionCompatible)
        #expect(!imageDecision.isFoodAnalysisCompatible)
        #expect(!textDecision.isImageDecisionCompatible)
    }

    @Test("Only confident valid distributions route to the label model") func distributionGate() throws {
        func route(
            _ probabilities: String,
            choice: String = "nutrition_label",
            type: String = "choice"
        ) throws -> FoodImageRoute {
            let json =
                "{\"answers\":{\"route\":{\"type\":\"\(type)\",\"choice\":\"\(choice)\",\"probabilities\":\(probabilities)}}}"
            return try JSONDecoder().decode(ImageDecisionResponse.self, from: Data(json.utf8)).route
        }
        #expect(try route(#"{"nutrition_label":0.96,"food":0.02,"uncertain":0.02}"#) == .nutritionLabel)
        #expect(try route(#"{"nutrition_label":0.6,"food":0.3,"uncertain":0.1}"#) == .uncertain)
        #expect(try route(#"{"nutrition_label":1.0}"#) == .uncertain)
        #expect(try route(#"{"nutrition_label":0.95,"food":0.95,"uncertain":0.0}"#) == .uncertain)
        #expect(try route(#"{"nutrition_label":0.96,"food":0.02,"uncertain":0.02}"#, choice: "unknown") == .uncertain)
        #expect(try route(#"{"nutrition_label":0.96,"food":0.02,"uncertain":0.02}"#, type: "score") == .uncertain)
    }

    @Test("Decision settings round-trip independently from calculation settings") func settingsPersistence() throws {
        var settings = TrioSettings()
        settings.imageClassifierConfiguration.modelID = "cloudflare/clef-flash"
        settings.imageClassifierConfiguration.nutritionLabelModelID = "vendor/fast-vision"
        settings.imageClassifierConfiguration.enabled = false
        let restored = try JSONDecoder().decode(TrioSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.imageClassifierConfiguration == settings.imageClassifierConfiguration)
        #expect(restored.openRouterModelConfiguration == settings.openRouterModelConfiguration)
        let legacy = try JSONDecoder().decode(TrioSettings.self, from: Data("{}".utf8))
        #expect(legacy.imageClassifierConfiguration.modelID == "openai/gpt-6-luna-decisions")
    }

    @Test("Decision payload carries inline image, selected model and bounded choices") func imagePayload() throws {
        let data = try OpenRouterImageDecisionService.requestBody(
            imageData: Data([1, 2, 3]),
            modelID: "vendor/decision",
            sessionID: "capture"
        )
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["model"] as? String == "vendor/decision")
        #expect(json["session_id"] as? String == "capture")
        let state = try #require(json["state"] as? [[String: Any]])
        let content = try #require(state.first?["content"] as? [[String: Any]])
        #expect(content.first?["image_url"] as? String == "data:image/jpeg;base64,AQID")
        #expect(json["messages"] == nil)
    }

    @Test("Label validation retains printed per-serving values and rejects incomplete results") func labelValidation() {
        let item = AIFoodItem(name: "Crackers", carbs: 22, fat: 4, protein: 3, servingCount: 4, servingUnit: "Crackers")
        let response = AIFoodItemsResponseWithReasoning(
            foodItems: [item],
            overallConfidence: 0.95,
            reasoning: "4 crackers per serving"
        )
        #expect(AIFoodTreatmentCoordinator.isValidLabelResponse(response))
        #expect(response.foodItems[0].carbs == 22)
        #expect(
            !AIFoodTreatmentCoordinator
                .isValidLabelResponse(.init(foodItems: [], overallConfidence: 1, reasoning: "Unreadable"))
        )
        #expect(
            !AIFoodTreatmentCoordinator
                .isValidLabelResponse(.init(foodItems: [item], overallConfidence: 0.5, reasoning: "Uncertain"))
        )
        let invalid = AIFoodItem(name: "Crackers", carbs: -1, servingCount: 0)
        #expect(
            !AIFoodTreatmentCoordinator
                .isValidLabelResponse(.init(foodItems: [invalid], overallConfidence: 1, reasoning: ""))
        )
    }

    @Test("Decision transport uses separate endpoint and propagates failures for fallback") func decisionTransport() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ImageDecisionURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel()
            ImageDecisionURLProtocol.handler = nil
        }
        ImageDecisionURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://openrouter.ai/api/alpha/decisions")
            #expect(request.httpMethod == "POST")
            #expect(request.timeoutInterval == 8)
            return (
                200,
                Data(
                    #"{"answers":{"route":{"type":"choice","choice":"food","probabilities":{"food":0.98,"nutrition_label":0.01,"uncertain":0.01}}}}"#
                        .utf8
                )
            )
        }
        let service = OpenRouterImageDecisionService(session: session, apiKey: { "fixture-key" })
        #expect(try await service.classify(imageData: Data([1]), modelID: "fixture/vision", sessionID: "test") == .food)
        ImageDecisionURLProtocol.handler = { _ in (400, Data()) }
        await #expect(throws: OpenAIServiceError.self) {
            try await service.classify(imageData: Data([1]), modelID: "fixture/vision", sessionID: "test")
        }
    }

    @Test("Strict label streams reject missing nutrients and truncated JSON") func strictLabelStream() {
        for json in [
            #"{"foodItems":[{"name":"Crackers","carbs":22,"fat":4,"servingCount":4,"servingUnit":"Crackers"}],"overallConfidence":0.99,"reasoning":"label"}"#,
            #"{"foodItems":[{"name":"Crackers","carbs":22,"fat":4,"protein":true,"servingCount":4,"servingUnit":"Crackers"}],"overallConfidence":0.99,"reasoning":"label"}"#,
            #"{"foodItems":[{"name":"Crackers","carbs":22,"fat":4,"protein":3,"servingCount":4,"servingUnit":"Crackers"}],"overallConfidence":0.99,"reasoning":"label""#
        ] {
            let parser = StructuredJSONStreamParser(requireCompleteNutrition: true)
            _ = parser.feed(contentDelta: json)
            #expect(parser.finish().foodItems.isEmpty)
        }
        let parser = StructuredJSONStreamParser(requireCompleteNutrition: true)
        _ = parser
            .feed(
                contentDelta: #"{"foodItems":[{"name":"Crackers","carbs":22,"fat":4,"protein":3,"servingCount":4,"servingUnit":"Crackers"}],"overallConfidence":0.99,"reasoning":"label"}"#
            )
        #expect(parser.finish().foodItems.count == 1)
    }

    @Test("Decision catalog fetch is filtered and cached separately") func decisionCatalog() async throws {
        let defaultsName = "ImageDecisionCatalogTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ImageDecisionURLProtocol.self]
        let session = URLSession(configuration: config)
        defer {
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: defaultsName)
            ImageDecisionURLProtocol.handler = nil
        }
        var requestCount = 0
        ImageDecisionURLProtocol.handler = { request in
            requestCount += 1
            #expect(request.url?.query == "output_modalities=decisions")
            return (
                200,
                Data(
                    #"{"data":[{"id":"vendor/vision","name":"Vision","architecture":{"input_modalities":["image"],"output_modalities":["decisions"]}},{"id":"vendor/text","name":"Text","architecture":{"input_modalities":["text"],"output_modalities":["decisions"]}}]}"#
                        .utf8
                )
            )
        }
        let service = OpenRouterModelCatalogService(session: session, defaults: defaults)
        #expect(try await service.loadDecisionModels().map(\.id) == ["vendor/vision"])
        #expect(try await service.loadDecisionModels().map(\.id) == ["vendor/vision"])
        #expect(requestCount == 1)
        #expect(service.cachedModels.isEmpty)
    }

    @Test("Captured prompt remains the exact refinement prefix") func pinnedPrompt() throws {
        let image = Data([1])
        let response = AIFoodItemsResponseWithReasoning(foodItems: [], overallConfidence: 0, reasoning: "")
        let initial = FoodAnalysisRequestBuilder.initialMessages(imageData: image, prompt: "captured prompt")
        let refined = try FoodAnalysisRequestBuilder.refinementMessages(
            imageData: image,
            initialResponse: response,
            userDescription: "context",
            prompt: "captured prompt"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(initial[0]) == encoder.encode(refined[0]))
    }
}

private final class ImageDecisionURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Treatments AI Availability") struct TreatmentsAIAvailabilityTests {
    @Test("Availability is safe after coordinator initialization") func availabilityAfterInitialization() {
        let coordinator = AIFoodTreatmentCoordinator(resolver: TrioApp.resolver)
        _ = coordinator.isAIAvailable
    }
}

@Suite("OpenRouter Speed and Effort", .serialized) struct OpenRouterSpeedAndEffortTests {
    private final class CatalogURLProtocol: URLProtocol {
        static var handler: ((URLRequest) -> (Int, Data))?
        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let handler = Self.handler, let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let (status, data) = handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func model(_ reasoning: String) throws -> OpenRouterModel {
        try JSONDecoder().decode(OpenRouterModel.self, from: Data(
            "{\"id\":\"openai/frontier\",\"name\":\"Frontier\",\"description\":\"OpenAI's flagship model\",\"architecture\":{\"input_modalities\":[\"image\"]},\"supported_parameters\":[\"response_format\"]\(reasoning)}"
                .utf8
        ))
    }

    @Test("Catalog efforts distinguish missing, null, mandatory and unknown values") func capabilities() throws {
        #expect(try model("").availableReasoningEfforts.isEmpty)
        #expect(try model(#", "reasoning": {"mandatory":true}"#).availableReasoningEfforts.isEmpty)
        #expect(
            try model(#", "reasoning": {"supported_efforts":null}"#).availableReasoningEfforts == OpenRouterReasoningEffort
                .allCases
        )
        let mandatory = try model(#", "reasoning": {"supported_efforts":["none","low","high","future"],"mandatory":true}"#)
        #expect(mandatory.availableReasoningEfforts == [.low, .high])
        let roundTrip = try JSONDecoder().decode(OpenRouterModel.self, from: JSONEncoder().encode(mandatory))
        #expect(roundTrip == mandatory)
        let unrestricted = try model(#", "reasoning": {"supported_efforts":null,"mandatory":true}"#)
        #expect(!unrestricted.availableReasoningEfforts.contains(.none))
        #expect(
            try JSONDecoder().decode(OpenRouterModel.self, from: JSONEncoder().encode(unrestricted))
                .availableReasoningEfforts == unrestricted.availableReasoningEfforts
        )
    }

    @Test("Existing selections migrate to Fast mode without losing order or execution settings") func migration() throws {
        let legacy =
            Data(
                #"{"selectedModelIDs":["a/one","b/two"],"defaultModelID":"b/two","runAllModelsSimultaneously":true,"migrationVersion":1}"#
                    .utf8
            )
        let configuration = try JSONDecoder().decode(OpenRouterModelConfiguration.self, from: legacy)
        #expect(configuration.fastModeEnabled)
        #expect(configuration.reasoningEfforts.isEmpty)
        #expect(configuration.selectedModelIDs == ["a/one", "b/two"])
        #expect(configuration.defaultModelID == "b/two")
        #expect(configuration.runAllModelsSimultaneously)
    }

    @Test("Speed and per-model efforts survive persistence and model reordering") func persistence() throws {
        var configuration = OpenRouterModelConfiguration(selectedModelIDs: ["a/one", "b/two"], defaultModelID: "a/one")
        configuration.fastModeEnabled = false
        configuration.setReasoningEffort(.low, for: "a/one")
        configuration.setReasoningEffort(.high, for: "b/two")
        configuration.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        let restored = try JSONDecoder().decode(OpenRouterModelConfiguration.self, from: JSONEncoder().encode(configuration))
        #expect(restored == configuration)
        #expect(restored.reasoningEfforts == ["a/one": "low", "b/two": "high"])
        configuration.setReasoningEffort(nil, for: "a/one")
        #expect(configuration.reasoningEfforts["a/one"] == nil)
        configuration.remove("b/two")
        #expect(configuration.reasoningEfforts.isEmpty)
        configuration.setReasoningEffort(.max, for: "missing/model")
        #expect(configuration.reasoningEfforts.isEmpty)
    }

    @Test("Frontier aliases follow the resolved model and suppress newly unsupported efforts") func frontierEffort() throws {
        let selection = OpenRouterFrontierOption.openAI.rawValue
        var configuration = OpenRouterModelConfiguration(selectedModelIDs: [selection], defaultModelID: selection)
        configuration.setReasoningEffort(.low, for: selection)
        let current = try model(#", "reasoning":{"supported_efforts":["low","high"]}"#)
        #expect(
            OpenRouterRequestOptions.resolve(modelID: current.id, configuration: configuration, models: [current])
                .effort == .low
        )
        let changed = try model(#", "reasoning":{"supported_efforts":["high"]}"#)
        #expect(
            OpenRouterRequestOptions.resolve(modelID: changed.id, configuration: configuration, models: [changed])
                .effort == nil
        )
        #expect(OpenRouterRequestOptions.resolve(modelID: current.id, configuration: configuration, models: []).effort == nil)
        #expect(
            OpenRouterRequestOptions
                .resolve(modelID: OpenRouterModels.utilityModelID, configuration: configuration, models: [current]).effort == nil
        )
    }

    @Test("Chat payloads send Fast mode and nested effort; standard mode omits default effort") func payload() throws {
        func body(_ options: OpenRouterRequestOptions) throws -> [String: Any] {
            let request = OpenAIChatRequest(
                model: "openai/test",
                messages: [],
                maxTokens: 1500,
                responseFormat: nil,
                options: options
            )
            return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        }
        let fast = try body(OpenRouterRequestOptions(effort: .low))
        #expect(fast["service_tier"] as? String == "fast")
        #expect((fast["reasoning"] as? [String: String])?["effort"] == "low")
        #expect(fast["max_tokens"] as? Int == 3000)
        let standard = try body(OpenRouterRequestOptions(fastModeEnabled: false))
        #expect(standard["service_tier"] as? String == "default")
        #expect(standard["reasoning"] == nil)
        #expect(standard["max_tokens"] as? Int == 1500)
        #expect(try body(OpenRouterRequestOptions())["service_tier"] as? String == "fast")
        #expect(try body(OpenRouterRequestOptions(effort: .high))["max_tokens"] as? Int == 7500)
        #expect(try body(OpenRouterRequestOptions(effort: .max))["max_tokens"] as? Int == 30000)
    }

    @Test("Pre-effort caches remain readable offline but refresh before being treated as fresh") func cacheMigration() async throws {
        let suite = "OpenRouterSpeedAndEffortTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite)
            CatalogURLProtocol.handler = nil
        }
        let oldModels = [try model("")]
        let cache: [String: Any] = [
            "models": try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldModels)),
            "savedAt": Date().timeIntervalSinceReferenceDate
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: cache), forKey: "OpenRouterModelCatalog.v1")
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [CatalogURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let service = OpenRouterModelCatalogService(session: session, defaults: defaults)
        #expect(service.cachedModels == oldModels)
        #expect(!service.cacheIsFresh())
        let updated = try model(#", "reasoning":{"supported_efforts":["low","medium"]}"#)
        let response = try JSONEncoder().encode(OpenRouterModelCatalogResponse(data: [updated]))
        var requestCount = 0
        CatalogURLProtocol.handler = { _ in requestCount += 1
            return (200, response)
        }
        #expect(try await service.loadModels() == [updated])
        #expect(service.cacheIsFresh())
        #expect(try await service.loadModels() == [updated])
        #expect(requestCount == 1)
    }
}

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

        let removedDefault = configuration.remove("b/two")
        #expect(removedDefault)
        #expect(configuration.selectedModelIDs == ["a/one", "c/three"])
        #expect(configuration.defaultModelID == "c/three")
        let removedMissing = configuration.remove("missing/model")
        #expect(!removedMissing)
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
    @Test("Legacy provider migrates to the two automatic frontier choices") func migratesLegacyProvider() throws {
        let data = Data(#"{"aiProvider":"claude","sendToAllAIProvidersSimultaneously":false}"#.utf8)
        let settings = try JSONDecoder().decode(TrioSettings.self, from: data)

        #expect(settings.openRouterModelConfiguration.selectedModelIDs == OpenRouterModels.defaultModelIDs)
        #expect(settings.openRouterModelConfiguration.defaultModelID == OpenRouterModels.defaultModelID)
    }

    @Test("Legacy comparison migrates to two lazy frontier tabs") func migratesLegacyComparison() throws {
        let data = Data(#"{"aiProvider":"claude","sendToAllAIProvidersSimultaneously":true}"#.utf8)
        let settings = try JSONDecoder().decode(TrioSettings.self, from: data)

        #expect(settings.openRouterModelConfiguration.selectedModelIDs == OpenRouterModels.defaultModelIDs)
        #expect(settings.openRouterModelConfiguration.defaultModelID == OpenRouterModels.defaultModelID)
        #expect(!settings.openRouterModelConfiguration.runAllModelsSimultaneously)
    }

    @Test("Pre-frontier configuration migrates exactly once") func preFrontierConfigurationMigrates() throws {
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

        #expect(settings.openRouterModelConfiguration.selectedModelIDs == OpenRouterModels.defaultModelIDs)
        #expect(settings.openRouterModelConfiguration.defaultModelID == OpenRouterModels.defaultModelID)
        #expect(!settings.openRouterModelConfiguration.runAllModelsSimultaneously)
    }

    @Test("User configuration survives after the frontier migration") func migratedUserConfigurationWins() throws {
        let data = Data(#"""
        {
          "openRouterModelConfiguration":{
            "selectedModelIDs":["google/gemini-test"],
            "defaultModelID":"google/gemini-test",
            "runAllModelsSimultaneously":true,
            "migrationVersion":1
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

    @Test("Frontier choices resolve to named flagship models, not merely the newest release") func resolvesFrontierModels() throws {
        let data = Data(#"""
        {
          "data":[
            {
              "id":"openai/gpt-6.1-sol",
              "name":"OpenAI: GPT-6.1 Sol",
              "description":"A newer model positioned below the flagship.",
              "created":300,
              "architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},
              "supported_parameters":["structured_outputs"]
            },
            {
              "id":"openai/gpt-6-astra",
              "name":"OpenAI: GPT-6 Astra",
              "description":"OpenAI's flagship model for demanding end-to-end work.",
              "created":200,
              "architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},
              "supported_parameters":["response_format"]
            },
            {
              "id":"anthropic/claude-sonnet-5.5",
              "name":"Anthropic: Claude Sonnet 5.5",
              "created":400,
              "architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},
              "supported_parameters":["structured_outputs"]
            },
            {
              "id":"anthropic/claude-opus-5.5",
              "name":"Anthropic: Claude Opus 5.5",
              "created":350,
              "architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},
              "supported_parameters":["structured_outputs"]
            }
          ]
        }
        """#.utf8)
        let models = try JSONDecoder().decode(OpenRouterModelCatalogResponse.self, from: data).data

        #expect(OpenRouterFrontierModelResolver.model(for: .openAI, in: models)?.id == "openai/gpt-6-astra")
        #expect(OpenRouterFrontierModelResolver.model(for: .anthropic, in: models)?.id == "anthropic/claude-opus-5.5")

        let resolved = OpenRouterFrontierModelResolver.resolve(OpenRouterModelConfiguration(), using: models)
        #expect(resolved.selectedModelIDs == ["openai/gpt-6-astra", "anthropic/claude-opus-5.5"])
        #expect(resolved.defaultModelID == "openai/gpt-6-astra")
        #expect(resolved.initialModelIDs == ["openai/gpt-6-astra"])
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
