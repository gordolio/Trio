import Foundation
import Testing

@testable import Trio

@MainActor @Suite("Image routing coordinator", .serialized) struct ImageRoutingCoordinatorTests {
    @Test("A label is reused on Analyze and printed servings scale only when changed") func labelReuseAndServings() async throws {
        let harness = FoodRoutingHarness()
        let coordinator = harness.coordinator()
        coordinator.prepareCapturedImage(Data([1]))
        await coordinator.analyzeFood(imageData: Data([1]))

        #expect(harness.classificationCount == 1)
        #expect(harness.requests.count == 1)
        #expect(harness.requests[0].modelID == "fixture/label")
        let selection = try #require(coordinator.foodItemSelection)
        let item = try #require(selection.selectedItems.first)
        #expect(item.servingCount == 4)
        #expect(selection.selectedCarbs == 22)
        #expect(selection.selectedFat == 4)
        #expect(selection.selectedProtein == 3)
        #expect(coordinator.carbs == 22)
        #expect(coordinator.conversationManager?.modelID == "fixture/frontier")
        #expect(coordinator.perProviderAnalysisModelIDs["fixture/frontier"] == "fixture/label")

        coordinator.updateServingCount(for: item.id, count: 8)
        #expect(coordinator.foodItemSelection?.selectedCarbs == 44)
        #expect(coordinator.carbs == 44)
        #expect(coordinator.fat == 8)
        #expect(coordinator.protein == 6)
        #expect(harness.requests.count == 1)
    }

    @Test("Unsafe numeric label responses invoke one frontier fallback", arguments: [
        1E100,
        1E-100
    ]) func unsafeLabelFallback(value: Double) async {
        let item = value > 1 ? AIFoodItem(name: "Unsafe", carbs: value) :
            AIFoodItem(name: "Unsafe", carbs: 22, servingCount: value)
        let harness = FoodRoutingHarness(labelResponse: .init(foodItems: [item], overallConfidence: 0.99, reasoning: "label"))
        let coordinator = harness.coordinator()
        coordinator.prepareCapturedImage(Data([1]))
        await coordinator.analyzeFood(imageData: Data([1]))
        #expect(harness.requests.map(\.modelID) == ["fixture/label", "fixture/frontier"])
        #expect(harness.requests[1].prompt == AIPromptSettings.Prompt.streamingFoodAnalysis.value)
        #expect(harness.classificationCount == 1)
        #expect(coordinator.carbs == 40)
        #expect(coordinator.provisionalFoodItems.first?.name == "Meal")
    }

    @Test("Classifier failure uses the general prompt without reclassifying on Analyze") func classifierFailure() async {
        let harness = FoodRoutingHarness(classify: { _ in throw RoutingFixtureError.classifierFailure })
        let coordinator = harness.coordinator()
        coordinator.prepareCapturedImage(Data([1]))
        await coordinator.analyzeFood(imageData: Data([1]))
        #expect(harness.requests.count == 1)
        #expect(harness.requests[0].modelID == "fixture/frontier")
        #expect(harness.requests[0].prompt == AIPromptSettings.Prompt.streamingFoodAnalysis.value)
        #expect(harness.classificationCount == 1)
        #expect(coordinator.carbs == 40)
    }

    @Test("Label transport timeout falls back once") func labelTimeout() async {
        let harness = FoodRoutingHarness(labelError: URLError(.timedOut))
        let coordinator = harness.coordinator()
        coordinator.prepareCapturedImage(Data([1]))
        await coordinator.analyzeFood(imageData: Data([1]))
        #expect(harness.requests.map(\.modelID) == ["fixture/label", "fixture/frontier"])
        #expect(coordinator.carbs == 40)
    }

    @Test("A label with description starts fresh frontier analysis and supporting classification") func labelDescription() async {
        let harness = FoodRoutingHarness()
        let coordinator = harness.coordinator()
        coordinator.prepareCapturedImage(Data([1]))
        await coordinator.analyzeFood(imageData: Data([1]), description: "I ate two crackers")
        #expect(harness.requests.map(\.modelID) == ["fixture/label", "fixture/frontier"])
        #expect(harness.requests[1].kind == .initial)
        #expect(harness.requests[1].description == "I ate two crackers")
        #expect(harness.requests[1].prompt == AIPromptSettings.Prompt.streamingFoodAnalysis.value)
        #expect(harness.classificationCount == 1)
        #expect(harness.restaurantDescriptions == ["I ate two crackers"])
        #expect(coordinator.carbs == 40)
    }

    @Test("Food refinement retains model, prompt and capture session") func foodRefinement() async {
        let harness = FoodRoutingHarness(route: .food)
        let coordinator = harness.coordinator()
        coordinator.prepareCapturedImage(Data([1]))
        await coordinator.analyzeFood(imageData: Data([1]), description: "Half this meal")
        #expect(harness.requests.map(\.modelID) == ["fixture/frontier", "fixture/frontier"])
        #expect(harness.requests[1].kind == .refinement)
        #expect(harness.requests[0].prompt == AIPromptSettings.Prompt.foodImageAnalysis.value)
        #expect(harness.requests[1].prompt == harness.requests[0].prompt)
        #expect(harness.requests[1].sessionID == harness.requests[0].sessionID)
        #expect(harness.classificationCount == 1)
    }

    @Test(
        "Uncertain or disabled routing uses general food analysis",
        arguments: [true, false]
    ) func generalRouting(enabled: Bool) async {
        let harness = FoodRoutingHarness(route: .uncertain)
        let coordinator = harness.coordinator(routingEnabled: enabled)
        coordinator.prepareCapturedImage(Data([1]))
        await coordinator.analyzeFood(imageData: Data([1]))
        #expect(harness.requests.count == 1)
        #expect(harness.requests[0].prompt == AIPromptSettings.Prompt.streamingFoodAnalysis.value)
        #expect(harness.classificationCount == (enabled ? 1 : 0))
    }

    @Test("Label partials remain unpublished and cancellation does not start fallback") func cancelledLabelStream() async throws {
        let harness = FoodRoutingHarness(manualLabelStream: true)
        let coordinator = harness.coordinator()
        defer { coordinator.cancelCapturedImagePreparation()
            harness.finishLabel() }
        coordinator.prepareCapturedImage(Data([1]))
        try await waitUntil { harness.hasLabelStream }
        harness
            .yieldLabel(.init(
                foodItems: [AIFoodItem(name: "Unsafe", carbs: 1E100)],
                reasoning: "",
                overallConfidence: 0,
                isComplete: false
            ))
        await Task.yield()
        #expect(coordinator.provisionalFoodItems.isEmpty)
        coordinator.cancelCapturedImagePreparation()
        try await waitUntil { harness.labelTerminated }
        #expect(coordinator.capturedImageData == nil)
        #expect(coordinator.foodItemSelection == nil)
        #expect(coordinator.provisionalFoodItems.isEmpty)
        #expect(harness.requests.map(\.modelID) == ["fixture/label"])
    }

    @Test("Late classification cannot revive a cancelled capture") func cancelledClassification() async throws {
        let gate = ClassificationGate()
        let harness = FoodRoutingHarness(classify: { try await gate.classify(sessionID: $0) })
        let coordinator = harness.coordinator()
        defer { coordinator.cancelCapturedImagePreparation()
            gate.resumeAll() }
        coordinator.prepareCapturedImage(Data([1]))
        try await waitUntil { gate.pendingSessions.count == 1 }
        let session = try #require(gate.pendingSessions.first)
        coordinator.cancelCapturedImagePreparation()
        gate.resume(sessionID: session, route: .nutritionLabel)
        try await waitUntil { gate.completed == 1 }
        await Task.yield()
        #expect(harness.requests.isEmpty)
        #expect(coordinator.capturedImageData == nil)
        #expect(!coordinator.isPreparingFoodAnalysis)
    }

    @Test("An older identical-image capture cannot overwrite the current capture") func repeatedImageCapture() async throws {
        let gate = ClassificationGate()
        let harness = FoodRoutingHarness(classify: { try await gate.classify(sessionID: $0) })
        let coordinator = harness.coordinator()
        defer { coordinator.cancelCapturedImagePreparation()
            gate.resumeAll() }
        coordinator.prepareCapturedImage(Data([1]))
        try await waitUntil { gate.pendingSessions.count == 1 }
        let first = try #require(gate.pendingSessions.first)
        coordinator.prepareCapturedImage(Data([1]))
        try await waitUntil { gate.pendingSessions.count == 2 }
        let second = try #require(gate.pendingSessions.first(where: { $0 != first }))
        gate.resume(sessionID: second, route: .nutritionLabel)
        await coordinator.analyzeFood(imageData: Data([1]))
        gate.resume(sessionID: first, route: .food)
        try await waitUntil { gate.completed == 2 }
        await Task.yield()
        #expect(harness.requests.count == 1)
        #expect(harness.requests[0].sessionID == second)
        #expect(coordinator.carbs == 22)
        #expect(coordinator.perProviderAnalysisModelIDs["fixture/frontier"] == "fixture/label")
    }

    @Test("Comparison and retry use their configured model without repeating the classifier") func comparisonAndRetry() async throws {
        let harness = FoodRoutingHarness()
        let coordinator = harness.coordinator(comparison: true)
        coordinator.prepareCapturedImage(Data([1]))
        await coordinator.analyzeFood(imageData: Data([1]))
        #expect(harness.requests.map(\.modelID) == ["fixture/label"])
        coordinator.switchDisplayedProvider(to: "fixture/other")
        try await waitUntil { coordinator.foodItemSelections["fixture/other"] != nil }
        coordinator.switchDisplayedProvider(to: "fixture/frontier")
        coordinator.retryAnalysis(for: "fixture/frontier")
        try await waitUntil { coordinator.perProviderAnalyzing["fixture/frontier"] == false }
        #expect(harness.requests.map(\.modelID) == ["fixture/label", "fixture/other", "fixture/frontier"])
        #expect(harness.requests[2].sessionID != harness.requests[0].sessionID)
        #expect(harness.classificationCount == 1)
        #expect(coordinator.carbs == 40)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() {
            guard ContinuousClock.now < limit else { throw RoutingFixtureError.waitTimedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum RoutingFixtureError: Error { case classifierFailure, unexpectedOperation, waitTimedOut }

private struct RoutingRequest {
    enum Kind { case initial, refinement }
    let modelID: String
    let prompt: String
    let isLabel: Bool
    let kind: Kind
    let sessionID: String?
    let description: String?
}

private final class FoodRoutingHarness {
    private let lock = NSLock()
    private var recordedRequests: [RoutingRequest] = []
    private var classifications = 0
    private var descriptions: [String] = []
    private var labelContinuation: AsyncThrowingStream<PartialFoodAnalysisResult, Error>.Continuation?
    private var terminated = false
    private let route: FoodImageRoute
    private let labelResponse: AIFoodItemsResponseWithReasoning
    private let labelError: Error?
    private let manualLabelStream: Bool
    private let classify: ((String) async throws -> FoodImageRoute)?

    init(
        route: FoodImageRoute = .nutritionLabel,
        labelResponse: AIFoodItemsResponseWithReasoning = .init(
            foodItems: [AIFoodItem(name: "Crackers", carbs: 22, fat: 4, protein: 3, servingCount: 4, servingUnit: "Crackers")],
            overallConfidence: 0.99, reasoning: "4 crackers per serving"
        ),
        labelError: Error? = nil,
        manualLabelStream: Bool = false,
        classify: ((String) async throws -> FoodImageRoute)? = nil
    ) {
        self.route = route
        self.labelResponse = labelResponse
        self.labelError = labelError
        self.manualLabelStream = manualLabelStream
        self.classify = classify
    }

    var requests: [RoutingRequest] { lock.withLock { recordedRequests } }
    var classificationCount: Int { lock.withLock { classifications } }
    var restaurantDescriptions: [String] { lock.withLock { descriptions } }
    var hasLabelStream: Bool { lock.withLock { labelContinuation != nil } }
    var labelTerminated: Bool { lock.withLock { terminated } }

    func coordinator(routingEnabled: Bool = true, comparison: Bool = false) -> AIFoodTreatmentCoordinator {
        var settings = TrioSettings()
        settings.imageClassifierConfiguration.enabled = routingEnabled
        settings.imageClassifierConfiguration.modelID = "fixture/classifier"
        settings.imageClassifierConfiguration.nutritionLabelModelID = "fixture/label"
        settings.openRouterModelConfiguration = .init(
            selectedModelIDs: comparison ? ["fixture/frontier", "fixture/other"] : ["fixture/frontier"],
            defaultModelID: "fixture/frontier"
        )
        let savedSettings = settings
        return AIFoodTreatmentCoordinator(dependencies: .init(
            settings: { savedSettings },
            resolveModels: { configuration in
                .init(
                    selectedModelIDs: configuration.selectedModelIDs,
                    defaultModelID: configuration.defaultModelID,
                    initialModelIDs: configuration.initialModelIDs
                )
            },
            isModelAvailable: { _ in true },
            classifyImage: { _, modelID, sessionID in
                #expect(modelID == "fixture/classifier")
                self.lock.withLock { self.classifications += 1 }
                return try await self.classify?(sessionID) ?? self.route
            },
            makeChatService: { modelID, prompt, isLabel in
                RoutingChatService(harness: self, modelID: modelID, prompt: prompt, isLabel: isLabel)
            },
            makeResponsesService: { _ in RoutingResponsesService(harness: self) }
        ))
    }

    func recordDescription(_ description: String) { lock.withLock { descriptions.append(description) } }

    func stream(for request: RoutingRequest) -> AsyncThrowingStream<PartialFoodAnalysisResult, Error> {
        lock.withLock { recordedRequests.append(request) }
        return AsyncThrowingStream { continuation in
            if request.isLabel, manualLabelStream {
                continuation.onTermination = { _ in self.lock.withLock { self.terminated = true } }
                lock.withLock { labelContinuation = continuation }
                return
            }
            if request.isLabel, let labelError {
                continuation.finish(throwing: labelError)
                return
            }
            let response = request.isLabel ? labelResponse : .init(
                foodItems: [AIFoodItem(name: "Meal", carbs: 40, fat: 10, protein: 9)], overallConfidence: 0.95, reasoning: "Meal"
            )
            continuation.yield(.init(
                foodItems: response.foodItems,
                reasoning: response.reasoning,
                overallConfidence: response.overallConfidence,
                isComplete: true
            ))
            continuation.finish()
        }
    }

    func yieldLabel(_ partial: PartialFoodAnalysisResult) { lock.withLock { labelContinuation }?.yield(partial) }
    func finishLabel() { lock.withLock { labelContinuation }?.finish() }
}

private final class RoutingChatService: AIProviderService {
    let harness: FoodRoutingHarness
    let modelID: String
    let prompt: String
    let isLabel: Bool
    init(harness: FoodRoutingHarness, modelID: String, prompt: String, isLabel: Bool) {
        self.harness = harness
        self.modelID = modelID
        self.prompt = prompt
        self.isLabel = isLabel
    }

    func analyzeFoodStreaming(
        imageData _: Data,
        userDescription: String?,
        sessionID: String?
    ) -> AsyncThrowingStream<PartialFoodAnalysisResult, Error> {
        harness.stream(for: .init(
            modelID: modelID,
            prompt: prompt,
            isLabel: isLabel,
            kind: .initial,
            sessionID: sessionID,
            description: userDescription
        ))
    }

    func refineFoodAnalysisStreaming(
        imageData _: Data,
        initialResponse _: AIFoodItemsResponseWithReasoning,
        userDescription: String,
        sessionID: String
    ) -> AsyncThrowingStream<PartialFoodAnalysisResult, Error> {
        harness.stream(for: .init(
            modelID: modelID,
            prompt: prompt,
            isLabel: isLabel,
            kind: .refinement,
            sessionID: sessionID,
            description: userDescription
        ))
    }

    func updateSingleItem(
        imageData _: Data,
        currentItems _: [AIFoodItem],
        editedItemId _: UUID,
        newDescription _: String
    ) async throws -> AISingleItemUpdateResponse { throw RoutingFixtureError.unexpectedOperation }
    func conversationTurn(
        imageData _: Data,
        currentItems _: [AIFoodItem],
        conversationHistory _: [AIConversationMessage],
        userMessage _: String
    ) async throws -> AIConversationResponse { throw RoutingFixtureError.unexpectedOperation }
    func classifyNutritionLookupIntent(
        userMessage _: String,
        currentItems _: [AIFoodItem],
        restaurantName _: String
    ) async throws -> NutritionLookupIntent { throw RoutingFixtureError.unexpectedOperation }
}

private final class RoutingResponsesService: AIResponsesProviderService {
    let harness: FoodRoutingHarness
    init(harness: FoodRoutingHarness) { self.harness = harness }
    func classifyRestaurantItem(description: String) async throws -> RestaurantClassifierResponse {
        harness.recordDescription(description)
        return .init(isRestaurantItem: false, restaurantName: "", menuItemName: "", confidence: 1)
    }

    func searchPublishedNutrition(
        restaurantName _: String,
        menuItemName _: String
    ) async throws -> PublishedNutritionResult { throw RoutingFixtureError.unexpectedOperation }
}

private final class ClassificationGate {
    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<FoodImageRoute, Error>] = [:]
    private var completions = 0
    var pendingSessions: [String] { lock.withLock { Array(pending.keys) } }
    var completed: Int { lock.withLock { completions } }
    func classify(sessionID: String) async throws -> FoodImageRoute {
        let result = try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pending[sessionID] = continuation }
        }
        lock.withLock { completions += 1 }
        return result
    }

    func resume(sessionID: String, route: FoodImageRoute) {
        lock.withLock { pending.removeValue(forKey: sessionID) }?.resume(returning: route)
    }

    func resumeAll() { for session in pendingSessions { resume(sessionID: session, route: .uncertain) } }
}
