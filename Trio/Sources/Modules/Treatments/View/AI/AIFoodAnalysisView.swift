import Foundation
import Observation
import SwiftUI
import Swinject

struct AIFoodTreatmentResult {
    let carbs: Decimal
    let fat: Decimal
    let protein: Decimal
    let note: String
    let metadata: AIAssistedCarbEntryMetadata
}

@Observable final class AIFoodTreatmentCoordinator {
    @ObservationIgnored private let settingsManager: SettingsManager

    var carbs: Decimal = 0
    var fat: Decimal = 0
    var protein: Decimal = 0
    var note = ""
    var appliedNutrition: AIFoodTreatmentResult?
    var appliedNutritionRevision = 0

    init(resolver: Resolver) {
        settingsManager = resolver.resolve(SettingsManager.self)!
    }

    // MARK: - AI-Assisted Entry Properties

    var isAnalyzingFood = false
    var isPreparingFoodAnalysis = false
    var aiError: String?
    var foodItemSelection: FoodItemSelection?
    var conversationManager: AIConversationManager?
    var provisionalFoodItems: [AIFoodItem] = []
    var provisionalFoodAnalysisError: String?
    @ObservationIgnored private var provisionalFoodAnalysis: AIFoodItemsResponseWithReasoning?
    @ObservationIgnored private var immediateConversationManager: AIConversationManager?
    @ObservationIgnored private var immediateFoodAnalysisTask: Task<Void, Never>?
    @ObservationIgnored private var foodAnalysisTask: Task<Void, Never>?
    @ObservationIgnored private var lazyAnalysisTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var immediateAnalysisProvider: String?
    @ObservationIgnored private var immediateAnalysisSessionID: String?
    @ObservationIgnored private var immediateAnalysisImageData: Data?
    /// The captured photo data, kept visible for thumbnail display during and after analysis
    var capturedImageData: Data? {
        didSet {
            if capturedImageData == nil, oldValue != nil {
                print("🔍 capturedImageData was SET TO NIL")
                Thread.callStackSymbols.prefix(10).forEach { print("  \($0)") }
            }
        }
    }

    /// User-provided description/context for the food photo
    var foodDescription: String = ""
    var aiAssistedMetadata: AIAssistedCarbEntryMetadata?
    private var originalAICarbsQuantity: Double?
    private var pendingImageData: Data?
    private var pendingAnalysisDescription: String?
    private var pendingAnalysisSessionIDs: [String: String] = [:]

    /// Vision items saved before merge, used as fallback when user rejects published nutrition
    private var premergeVisionItems: [AIFoodItem]?
    /// Restaurant name from the published result, used for matching during reject
    private var publishedRestaurantName: String?

    // MARK: - Multi-Provider Comparison Mode

    /// Per-provider analysis slots. When multi-provider mode is off, only the single configured
    /// provider appears here. The `foodItemSelection` / `conversationManager` / `premergeVisionItems`
    /// / `publishedRestaurantName` values above mirror the slot for `displayedProvider`.
    var foodItemSelections: [String: FoodItemSelection] = [:]
    var conversationManagers: [String: AIConversationManager] = [:]
    var perProviderAnalyzing: [String: Bool] = [:]
    var perProviderErrors: [String: String] = [:]
    var perProviderPremergeVisionItems: [String: [AIFoodItem]] = [:]
    var perProviderPublishedRestaurantName: [String: String] = [:]

    /// Providers the current analysis was dispatched to, in display order.
    /// Empty when no analysis is in flight / complete.
    var activeProviders: [String] = []

    /// Which provider's results are currently shown in the UI.
    /// Only meaningful when `activeProviders.count > 1` (multi-provider mode).
    var displayedProvider: String?

    /// Whether we're in AI mode (photo captured or analysis complete)
    var isInAIMode: Bool {
        capturedImageData != nil || foodItemSelection != nil || isAnalyzingFood
    }

    var isAIAvailable: Bool {
        // SwiftUI can evaluate this before BaseView injects settingsManager.
        // Model configuration independently guarantees at least one selection.
        hasOpenRouterAPIKey
    }

    private var hasOpenRouterAPIKey: Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "OpenRouterAPIKey") as? String,
              !value.isEmpty,
              value != "$(OPENROUTER_API_KEY)" else { return false }
        return true
    }

    func isProviderAvailable(_ modelID: String) -> Bool {
        guard hasOpenRouterAPIKey else { return false }
        let catalog = OpenRouterModelCatalogService.shared.cachedModels
        guard !catalog.isEmpty else { return true }
        return catalog.first(where: { $0.id == modelID })?.isFoodAnalysisCompatible == true
    }

    var autoOpenCamera: Bool = false

    deinit {
        immediateFoodAnalysisTask?.cancel()
        foodAnalysisTask?.cancel()
        lazyAnalysisTasks.values.forEach { $0.cancel() }
    }

    // MARK: - AI-Assisted Food Analysis

    /// Stores a newly captured image and immediately starts the primary food-analysis request.
    ///
    /// Results remain provisional until the user taps Analyze. This gives the user
    /// nutrition feedback immediately without changing the treatment form or invoking
    /// Trio's insulin calculation.
    @MainActor func prepareCapturedImage(_ imageData: Data) {
        immediateFoodAnalysisTask?.cancel()
        foodAnalysisTask?.cancel()
        lazyAnalysisTasks.values.forEach { $0.cancel() }
        lazyAnalysisTasks.removeAll()

        capturedImageData = imageData
        foodDescription = ""
        aiError = nil
        provisionalFoodItems = []
        provisionalFoodAnalysis = nil
        provisionalFoodAnalysisError = nil
        immediateConversationManager = nil
        foodItemSelection = nil
        conversationManager = nil
        foodItemSelections.removeAll()
        conversationManagers.removeAll()
        perProviderAnalyzing.removeAll()
        perProviderErrors.removeAll()
        perProviderPremergeVisionItems.removeAll()
        perProviderPublishedRestaurantName.removeAll()
        activeProviders.removeAll()
        displayedProvider = nil
        pendingImageData = nil
        pendingAnalysisDescription = nil
        pendingAnalysisSessionIDs.removeAll()

        let provider = settingsManager.settings.openRouterModelConfiguration.defaultModelID
        let sessionID = UUID().uuidString
        immediateAnalysisProvider = provider
        immediateAnalysisSessionID = sessionID
        immediateAnalysisImageData = imageData
        isPreparingFoodAnalysis = true

        immediateFoodAnalysisTask = Task { [weak self] in
            await self?.performImmediateFoodAnalysis(
                imageData: imageData,
                provider: provider,
                sessionID: sessionID
            )
        }
    }

    /// Updates optional user context. It is sent once as the description addendum
    /// when the user taps Analyze.
    @MainActor func updateFoodDescription(_ description: String) {
        foodDescription = description
    }

    @MainActor func cancelCapturedImagePreparation() {
        immediateFoodAnalysisTask?.cancel()
        foodAnalysisTask?.cancel()
        foodAnalysisTask = nil
        lazyAnalysisTasks.values.forEach { $0.cancel() }
        lazyAnalysisTasks.removeAll()
        immediateFoodAnalysisTask = nil
        provisionalFoodItems = []
        provisionalFoodAnalysis = nil
        provisionalFoodAnalysisError = nil
        immediateConversationManager = nil
        immediateAnalysisProvider = nil
        immediateAnalysisSessionID = nil
        immediateAnalysisImageData = nil
        isPreparingFoodAnalysis = false
        capturedImageData = nil
        foodDescription = ""
    }

    /// Executes the actual configured-provider image prompt as soon as a photo is available.
    /// This is the same result that Analyze promotes when no description is supplied.
    @MainActor private func performImmediateFoodAnalysis(
        imageData: Data,
        provider: String,
        sessionID: String
    ) async {
        guard !Task.isCancelled,
              capturedImageData == imageData,
              immediateAnalysisSessionID == sessionID else { return }
        guard isProviderAvailable(provider) else {
            provisionalFoodAnalysisError = OpenAIServiceError.incompatibleModel(provider).localizedDescription
            isPreparingFoodAnalysis = false
            return
        }
        let manager = AIConversationManager()
        manager.modelID = provider
        let stream = AIServiceRegistry.chat(for: provider).analyzeFoodStreaming(
            imageData: imageData,
            userDescription: nil,
            sessionID: sessionID
        )

        do {
            let response = try await manager.initializeStreaming(
                stream: stream,
                imageData: imageData,
                userDescription: nil,
                onItemsUpdated: { [weak self] items in
                    guard let self,
                          self.capturedImageData == imageData,
                          self.immediateAnalysisSessionID == sessionID
                    else { return }
                    self.provisionalFoodItems = items
                }
            )

            guard !Task.isCancelled,
                  capturedImageData == imageData,
                  immediateAnalysisSessionID == sessionID
            else { return }

            provisionalFoodItems = response.foodItems
            provisionalFoodAnalysis = response
            immediateConversationManager = manager
            provisionalFoodAnalysisError = nil
        } catch is CancellationError {
            return
        } catch {
            guard capturedImageData == imageData,
                  immediateAnalysisSessionID == sessionID
            else { return }
            provisionalFoodAnalysisError = String(
                localized: "Initial analysis could not be completed. Continue will retry."
            )
            print("🍽️ [\(provider)] Immediate analysis failed: \(error.localizedDescription)")
        }

        guard capturedImageData == imageData,
              immediateAnalysisSessionID == sessionID
        else { return }
        isPreparingFoodAnalysis = false
    }

    /// Analyzes a food image using AI. In comparison mode, the selected provider
    /// runs first and the others are queried lazily when their tabs are opened.
    @MainActor func startFoodAnalysis(imageData: Data, description: String? = nil) {
        foodAnalysisTask?.cancel()
        foodAnalysisTask = Task { [weak self] in
            await self?.analyzeFood(imageData: imageData, description: description)
        }
    }

    func analyzeFood(imageData: Data, description: String? = nil) async {
        let immediateTask = await MainActor.run { immediateFoodAnalysisTask }
        await immediateTask?.value

        let normalizedDescription = description?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let finalDescription = normalizedDescription?.isEmpty == false ? normalizedDescription : nil

        let configuration = settingsManager.settings.openRouterModelConfiguration
        let configuredProvider = configuration.defaultModelID
        let tabs = configuration.selectedModelIDs
        let initialModels = Set(configuration.initialModelIDs)
        let initialProvider = tabs.contains(configuredProvider) ? configuredProvider : (tabs.first ?? configuredProvider)

        let immediateDraft = await MainActor.run {
            guard immediateAnalysisProvider == initialProvider,
                  immediateAnalysisImageData == imageData
            else {
                return (
                    response: AIFoodItemsResponseWithReasoning?.none,
                    manager: AIConversationManager?.none,
                    sessionID: String?.none
                )
            }
            return (
                response: provisionalFoodAnalysis,
                manager: immediateConversationManager,
                sessionID: immediateAnalysisSessionID
            )
        }
        let initialSessionID = immediateDraft.sessionID ?? UUID().uuidString
        let sessionIDs: [String: String] = Dictionary(uniqueKeysWithValues: tabs.map {
            ($0, $0 == initialProvider ? initialSessionID : UUID().uuidString)
        })

        await MainActor.run {
            isAnalyzingFood = true
            aiError = nil
            foodItemSelection = nil
            conversationManager = nil
            premergeVisionItems = nil
            publishedRestaurantName = nil
            foodItemSelections.removeAll()
            conversationManagers.removeAll()
            perProviderErrors.removeAll()
            perProviderPremergeVisionItems.removeAll()
            perProviderPublishedRestaurantName.removeAll()
            perProviderAnalyzing = Dictionary(
                uniqueKeysWithValues: tabs.map { ($0, initialModels.contains($0)) }
            )
            activeProviders = tabs
            displayedProvider = initialProvider
            capturedImageData = imageData
            pendingImageData = imageData
            pendingAnalysisDescription = finalDescription
            pendingAnalysisSessionIDs = sessionIDs
            isPreparingFoodAnalysis = false
        }

        await withTaskGroup(of: Void.self) { group in
            for modelID in tabs where initialModels.contains(modelID) && modelID != initialProvider {
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.runAnalysis(
                        for: modelID,
                        imageData: imageData,
                        description: finalDescription,
                        sessionID: sessionIDs[modelID] ?? UUID().uuidString
                    )
                }
            }

            await runAnalysis(
                for: initialProvider,
                imageData: imageData,
                description: finalDescription,
                sessionID: initialSessionID,
                initialResponse: immediateDraft.response,
                initialManager: immediateDraft.manager
            )
            await group.waitForAll()
        }

        await MainActor.run {
            isAnalyzingFood = perProviderAnalyzing.values.contains(true)
        }
    }

    /// Runs a single provider's analysis and writes the result into its per-provider slot.
    /// If this provider is the currently-displayed one, the top-level `foodItemSelection`
    /// / `conversationManager` mirrors are also updated so the existing UI code keeps working.
    private func runAnalysis(
        for provider: String,
        imageData: Data,
        description: String?,
        sessionID: String,
        initialResponse: AIFoodItemsResponseWithReasoning? = nil,
        initialManager: AIConversationManager? = nil
    ) async {
        let isCurrentAnalysis = await MainActor.run {
            pendingImageData == imageData && activeProviders.contains(provider)
        }
        guard isCurrentAnalysis else { return }
        guard isProviderAvailable(provider) else {
            await MainActor.run {
                guard pendingImageData == imageData, activeProviders.contains(provider) else { return }
                perProviderAnalyzing[provider] = false
                perProviderErrors[provider] = OpenAIServiceError.incompatibleModel(provider).localizedDescription
                if displayedProvider == provider {
                    aiError = perProviderErrors[provider]
                }
            }
            return
        }
        let chatService = AIServiceRegistry.chat(for: provider)
        let responsesService = AIServiceRegistry.responses(for: provider)

        do {
            print("🍽️ [\(provider)] Starting food analysis. Description: \(description ?? "<none>")")

            async let publishedNutritionResult = findPublishedNutrition(
                description: description,
                using: responsesService,
                modelID: provider
            )

            let manager: AIConversationManager
            let visionResponse: AIFoodItemsResponseWithReasoning

            if description == nil, let initialResponse {
                manager = initialManager ?? AIConversationManager()
                manager.modelID = provider
                if initialManager == nil {
                    await manager.initialize(
                        with: initialResponse,
                        imageData: imageData,
                        userDescription: nil
                    )
                }
                visionResponse = initialResponse
                print("🍽️ [\(provider)] Reusing immediate analysis; no second vision request")
            } else {
                manager = AIConversationManager()
                manager.modelID = provider
                let stream: AsyncThrowingStream<PartialFoodAnalysisResult, Error>
                if let description, let initialResponse {
                    stream = chatService.refineFoodAnalysisStreaming(
                        imageData: imageData,
                        initialResponse: initialResponse,
                        userDescription: description,
                        sessionID: sessionID
                    )
                } else {
                    stream = chatService.analyzeFoodStreaming(
                        imageData: imageData,
                        userDescription: description,
                        sessionID: sessionID
                    )
                }

                await MainActor.run {
                    guard pendingImageData == imageData, activeProviders.contains(provider) else { return }
                    conversationManagers[provider] = manager
                    if displayedProvider == provider {
                        conversationManager = manager
                    }
                }

                visionResponse = try await manager.initializeStreaming(
                    stream: stream,
                    imageData: imageData,
                    userDescription: description,
                    onItemsUpdated: { [weak self] items in
                        guard let self,
                              self.pendingImageData == imageData,
                              self.activeProviders.contains(provider) else { return }
                        let response = AIFoodItemsResponse(
                            foodItems: items,
                            overallConfidence: 0
                        )
                        let selection = FoodItemSelection(response: response)
                        self.foodItemSelections[provider] = selection
                        if self.displayedProvider == provider {
                            self.foodItemSelection = selection
                        }
                    }
                )
            }

            manager.modelID = provider
            await MainActor.run {
                guard pendingImageData == imageData, activeProviders.contains(provider) else { return }
                conversationManagers[provider] = manager
                if displayedProvider == provider {
                    conversationManager = manager
                }
            }

            let publishedResult = await publishedNutritionResult

            await MainActor.run {
                guard pendingImageData == imageData, activeProviders.contains(provider) else { return }
                perProviderPremergeVisionItems[provider] = visionResponse.foodItems
                perProviderPublishedRestaurantName[provider] = publishedResult?.restaurantName
                if displayedProvider == provider {
                    premergeVisionItems = visionResponse.foodItems
                    publishedRestaurantName = publishedResult?.restaurantName
                }
            }

            let mergedItems = NutritionFactsMerger.merge(
                publishedResult: publishedResult,
                visionItems: visionResponse.foodItems
            )

            await MainActor.run {
                guard pendingImageData == imageData, activeProviders.contains(provider) else { return }
                let mergedResponse = AIFoodItemsResponse(
                    foodItems: mergedItems,
                    overallConfidence: visionResponse.overallConfidence
                )

                if mergedItems != visionResponse.foodItems {
                    manager.replaceItems(
                        mergedItems,
                        restaurantName: publishedResult?.restaurantName,
                        sourceURL: publishedResult?.sourceURL
                    )
                }

                let selection = FoodItemSelection(response: mergedResponse)
                foodItemSelections[provider] = selection
                perProviderAnalyzing[provider] = false

                if displayedProvider == provider {
                    // No withAnimation here — an animated swap of foodItemSelection
                    // cascades a layout animation into the provider tab bar above
                    // and makes the tabs slide vertically on completion.
                    foodItemSelection = selection
                    updateFormFromSelection()
                }
                print("🍽️ [\(provider)] Analysis complete")
            }
        } catch {
            await MainActor.run {
                guard pendingImageData == imageData, activeProviders.contains(provider) else { return }
                perProviderAnalyzing[provider] = false
                foodItemSelections[provider] = nil
                conversationManagers[provider] = nil
                let message = providerFacingErrorMessage(for: error, provider: provider)
                perProviderErrors[provider] = message
                // Only surface errors for the provider the user is currently looking at —
                // a background/dormant provider failing silently shouldn't pop an alert.
                if displayedProvider == provider {
                    foodItemSelection = nil
                    conversationManager = nil
                    aiError = message
                }
            }
        }
    }

    private func findPublishedNutrition(
        description: String?,
        using service: AIResponsesProviderService,
        modelID: String
    ) async -> PublishedNutritionResult? {
        guard let description, !description.isEmpty else { return nil }
        do {
            let classification = try await service.classifyRestaurantItem(description: description)
            guard classification.isRestaurantItem,
                  !classification.restaurantName.isEmpty,
                  !classification.menuItemName.isEmpty else { return nil }
            return try await service.searchPublishedNutrition(
                restaurantName: classification.restaurantName,
                menuItemName: classification.menuItemName
            )
        } catch {
            print("🍽️ [\(modelID)] Classifier/search failed (non-fatal): \(error.localizedDescription)")
            return nil
        }
    }

    /// Maps a provider error into a user-facing string, including OpenRouter billing errors.
    /// For generic HTTP failures we prefix the provider name so the user knows which one failed.
    private func providerFacingErrorMessage(for error: Error, provider: String) -> String {
        if case OpenAIServiceError.insufficientCredits = error {
            return String(
                format: String(
                    localized: "%@ is out of credits. Please top up your account before analyzing more images.",
                    comment: "Alert shown when a provider responds with an out-of-credits signal"
                ),
                provider.openRouterShortDisplayName
            )
        }
        if case let OpenAIServiceError.invalidResponse(statusCode) = error {
            switch statusCode {
            case 401,
                 403:
                return String(
                    format: String(
                        localized: "%@ rejected the API key (status %d). Check the key configured in ConfigOverride.xcconfig.",
                        comment: "Alert shown when a provider returns HTTP 401/403"
                    ),
                    provider.openRouterShortDisplayName, statusCode
                )
            case 429:
                return String(
                    format: String(
                        localized: "%@ is currently rate-limiting requests. Please try again in a moment.",
                        comment: "Alert shown when a provider returns HTTP 429 without an insufficient_quota code"
                    ),
                    provider.openRouterShortDisplayName
                )
            default:
                return "\(provider.openRouterShortDisplayName): \(error.localizedDescription)"
            }
        }
        return "\(provider.openRouterShortDisplayName): \(error.localizedDescription)"
    }

    /// Switches which provider's results are displayed in the food item list + form.
    /// Mirrors the provider's per-provider slot into the top-level `foodItemSelection` /
    /// `conversationManager` and recomputes the bolus form from the new selection.
    /// If the target provider hasn't been queried yet (lazy multi-provider mode), this
    /// kicks off its analysis now.
    @MainActor func switchDisplayedProvider(to provider: String) {
        guard displayedProvider != provider else { return }
        // Disable animations at the source so SwiftUI/Form doesn't attach
        // an ambient transition (slide/opacity) to the resulting view-tree
        // diff. Tab switches must be visually instantaneous — including the
        // form-field updates triggered by `updateFormFromSelection`, since
        // they share the same Section as the tab bar and a List row-height
        // change there will pull the tab bar with it.
        var txn = Transaction()
        txn.disablesAnimations = true

        withTransaction(txn) {
            displayedProvider = provider
            foodItemSelection = foodItemSelections[provider]
            conversationManager = conversationManagers[provider]
            premergeVisionItems = perProviderPremergeVisionItems[provider]
            publishedRestaurantName = perProviderPublishedRestaurantName[provider]
        }

        if foodItemSelection != nil {
            withTransaction(txn) {
                updateFormFromSelection()
            }
            return
        }

        // Lazy-query: if this tab has never been analyzed, kick it off now.
        let hasBeenQueried = perProviderAnalyzing[provider] == true ||
            perProviderErrors[provider] != nil
        guard !hasBeenQueried, let imageData = pendingImageData else { return }

        withTransaction(txn) {
            perProviderAnalyzing[provider] = true
            isAnalyzingFood = true
            aiError = nil
        }

        let description = pendingAnalysisDescription
        let sessionID = pendingAnalysisSessionIDs[provider] ?? UUID().uuidString
        pendingAnalysisSessionIDs[provider] = sessionID
        lazyAnalysisTasks[provider]?.cancel()
        lazyAnalysisTasks[provider] = Task { [weak self] in
            await self?.runAnalysis(
                for: provider,
                imageData: imageData,
                description: description,
                sessionID: sessionID
            )
            await MainActor.run {
                guard let self else { return }
                var endTxn = Transaction()
                endTxn.disablesAnimations = true
                withTransaction(endTxn) {
                    self.isAnalyzingFood = self.perProviderAnalyzing.values.contains(true)
                }
                if self.pendingAnalysisSessionIDs[provider] == sessionID {
                    self.lazyAnalysisTasks[provider] = nil
                }
            }
        }
    }

    @MainActor func retryAnalysis(for provider: String) {
        guard let imageData = pendingImageData,
              activeProviders.contains(provider),
              perProviderAnalyzing[provider] != true else { return }
        perProviderErrors[provider] = nil
        if displayedProvider == provider {
            aiError = nil
        }
        perProviderAnalyzing[provider] = true
        isAnalyzingFood = true
        let description = pendingAnalysisDescription
        let sessionID = UUID().uuidString
        pendingAnalysisSessionIDs[provider] = sessionID
        lazyAnalysisTasks[provider]?.cancel()
        lazyAnalysisTasks[provider] = Task { [weak self] in
            await self?.runAnalysis(
                for: provider,
                imageData: imageData,
                description: description,
                sessionID: sessionID
            )
            await MainActor.run {
                guard let self else { return }
                self.isAnalyzingFood = self.perProviderAnalyzing.values.contains(true)
                if self.pendingAnalysisSessionIDs[provider] == sessionID {
                    self.lazyAnalysisTasks[provider] = nil
                }
            }
        }
    }

    /// Shared helper: applies a food item selection to the form fields, metadata, and triggers recalculation
    @MainActor private func applySelection(_ selection: FoodItemSelection, userModified: Bool) {
        carbs = Decimal(selection.selectedCarbs)
        note = selection.collapsedSummary

        let itemDescriptions = selection.response.foodItems.map { item in
            let emoji = item.emoji ?? ""
            return "\(emoji) \(item.name): \(Int(item.carbs))g"
        }.joined(separator: ", ")

        fat = Decimal(selection.selectedFat)
        protein = Decimal(selection.selectedProtein)

        aiAssistedMetadata = AIAssistedCarbEntryMetadata(
            detailedDescription: itemDescriptions,
            estimatedCarbs: selection.response.totalCarbs,
            emoji: selection.mainItem?.emoji ?? "",
            fat: selection.selectedFat,
            protein: selection.selectedProtein,
            carbConfidence: selection.response.overallConfidence,
            emojiConfidence: selection.response.overallConfidence,
            userModified: userModified,
            foodItems: selection.response.foodItems,
            selectedItemIds: Array(selection.selectedItemIds)
        )

        publishSelectedNutrition()
    }

    /// Updates form fields based on current food item selection
    @MainActor func updateFormFromSelection() {
        guard let selection = foodItemSelection else { return }

        if originalAICarbsQuantity == nil {
            originalAICarbsQuantity = selection.response.totalCarbs
        }

        applySelection(selection, userModified: selection.userModifiedSelection)
    }

    /// Update the user's serving count for a specific item and recalculate form values
    @MainActor func updateServingCount(for itemId: UUID, count: Double) {
        guard foodItemSelection != nil else { return }
        foodItemSelection?.userServingCounts[itemId] = count
        if let provider = displayedProvider, let updated = foodItemSelection {
            foodItemSelections[provider] = updated
        }
        updateFormFromSelection()
    }

    /// Toggle selection of a food item and update form
    @MainActor func toggleFoodItem(_ itemId: UUID) {
        guard foodItemSelection != nil else { return }
        foodItemSelection?.toggleSelection(for: itemId)
        conversationManager?.toggleSelection(for: itemId)
        if let provider = displayedProvider, let updated = foodItemSelection {
            foodItemSelections[provider] = updated
        }
        updateFormFromSelection()
    }

    /// Accepts published nutrition for an item (no-op — values are already applied)
    @MainActor func acceptPublishedNutrition(for _: UUID) {
        // Nothing to do — published values are already in use
    }

    /// Rejects published nutrition for an item and restores the original vision estimate
    @MainActor func rejectPublishedNutrition(for itemId: UUID) {
        guard var selection = foodItemSelection else { return }

        let currentItems = selection.response.foodItems

        // Find the published item being rejected
        guard let publishedItem = currentItems.first(where: { $0.id == itemId && $0.source == .published }) else {
            return
        }

        // Find matching vision item(s) from the pre-merge snapshot
        let restaurantName = publishedRestaurantName ?? ""
        let fallbackItems: [AIFoodItem]
        if let visionItems = premergeVisionItems {
            fallbackItems = visionItems.filter { visionItem in
                NutritionFactsMerger.isLikelyMatch(
                    visionItemName: visionItem.name,
                    publishedItemName: publishedItem.name,
                    restaurantName: restaurantName
                )
            }
        } else {
            fallbackItems = []
        }

        // Build the new items list: replace the published item with vision fallback(s)
        var newItems: [AIFoodItem] = []
        for item in currentItems {
            if item.id == itemId {
                if fallbackItems.isEmpty {
                    // No vision fallback found — keep the published item but mark as estimated
                    newItems.append(AIFoodItem(
                        name: publishedItem.name,
                        carbs: publishedItem.carbs,
                        emoji: publishedItem.emoji,
                        fat: publishedItem.fat,
                        protein: publishedItem.protein,
                        source: .estimated
                    ))
                } else {
                    newItems.append(contentsOf: fallbackItems)
                }
            } else {
                newItems.append(item)
            }
        }

        let newResponse = AIFoodItemsResponse(
            foodItems: newItems,
            overallConfidence: selection.response.overallConfidence
        )
        var newSelection = FoodItemSelection(response: newResponse)
        newSelection.userServingCounts = selection.userServingCounts

        withAnimation(.easeInOut(duration: 0.35)) {
            foodItemSelection = newSelection
        }
        if let provider = displayedProvider {
            foodItemSelections[provider] = newSelection
        }

        conversationManager?.replaceItems(newItems)
        updateFormFromSelection()
    }

    /// Clears the AI error state
    func clearAIError() {
        aiError = nil
    }

    /// Clears the food item selection (resets AI analysis)
    func clearFoodItemSelection() {
        immediateFoodAnalysisTask?.cancel()
        foodAnalysisTask?.cancel()
        foodAnalysisTask = nil
        lazyAnalysisTasks.values.forEach { $0.cancel() }
        lazyAnalysisTasks.removeAll()
        foodItemSelection = nil
        conversationManager = nil
        capturedImageData = nil
        foodDescription = ""
        isPreparingFoodAnalysis = false
        provisionalFoodItems = []
        provisionalFoodAnalysis = nil
        provisionalFoodAnalysisError = nil
        immediateConversationManager = nil
        immediateFoodAnalysisTask = nil
        immediateAnalysisProvider = nil
        immediateAnalysisSessionID = nil
        immediateAnalysisImageData = nil
        originalAICarbsQuantity = nil
        aiAssistedMetadata = nil
        pendingImageData = nil
        pendingAnalysisDescription = nil
        pendingAnalysisSessionIDs.removeAll()
        premergeVisionItems = nil
        publishedRestaurantName = nil
        foodItemSelections.removeAll()
        conversationManagers.removeAll()
        perProviderAnalyzing.removeAll()
        perProviderErrors.removeAll()
        perProviderPremergeVisionItems.removeAll()
        perProviderPublishedRestaurantName.removeAll()
        activeProviders.removeAll()
        displayedProvider = nil
    }

    /// Edit a food item's description and recalculate its carbs
    func editFoodItemDescription(_ itemId: UUID, newDescription: String) async {
        guard let manager = conversationManager else { return }

        // Immediately update the item name in the selection so the UI doesn't revert
        await MainActor.run {
            if var selection = foodItemSelection,
               let index = selection.response.foodItems.firstIndex(where: { $0.id == itemId })
            {
                let oldItem = selection.response.foodItems[index]
                var updatedItems = selection.response.foodItems
                updatedItems[index] = AIFoodItem(
                    id: oldItem.id,
                    name: newDescription,
                    carbs: oldItem.carbs,
                    emoji: oldItem.emoji,
                    fat: oldItem.fat,
                    protein: oldItem.protein,
                    servingCount: oldItem.servingCount,
                    servingUnit: oldItem.servingUnit
                )
                let updatedResponse = AIFoodItemsResponse(
                    foodItems: updatedItems,
                    overallConfidence: selection.response.overallConfidence
                )
                var newSelection = FoodItemSelection(response: updatedResponse)
                newSelection.selectedItemIds = selection.selectedItemIds
                newSelection.userServingCounts = selection.userServingCounts
                foodItemSelection = newSelection
                if let provider = displayedProvider {
                    foodItemSelections[provider] = newSelection
                }
            }
        }

        await manager.updateItemDescription(itemId: itemId, newDescription: newDescription)

        // Update form with the final carb values from the API
        await MainActor.run {
            updateFormFromConversation()
        }
    }

    /// Updates form fields from the conversation manager's current state
    @MainActor func updateFormFromConversation() {
        guard let manager = conversationManager else { return }

        let response = AIFoodItemsResponse(
            foodItems: manager.currentItems,
            overallConfidence: manager.overallConfidence
        )
        var selection = FoodItemSelection(response: response)
        selection.selectedItemIds = manager.selectedItemIds
        // Preserve user's per-item serving counts
        if let oldCounts = foodItemSelection?.userServingCounts {
            for (id, count) in oldCounts {
                selection.userServingCounts[id] = count
            }
        }
        foodItemSelection = selection
        if let provider = displayedProvider {
            foodItemSelections[provider] = selection
        }

        applySelection(selection, userModified: true)
    }

    /// Accept values from the conversation manager (called when user taps Accept in chat)
    @MainActor func acceptConversationValues(_ selection: FoodItemSelection) {
        foodItemSelection = selection
        if let provider = displayedProvider {
            foodItemSelections[provider] = selection
        }
        conversationManager?.selectedItemIds = selection.selectedItemIds
        applySelection(selection, userModified: true)
    }

    /// Get the IDs of items currently being recalculated (for shimmer animation)
    var pendingItemIds: Set<UUID> {
        conversationManager?.pendingItemIds ?? []
    }

    @MainActor private func publishSelectedNutrition() {
        guard let aiAssistedMetadata else { return }
        appliedNutrition = AIFoodTreatmentResult(
            carbs: carbs,
            fat: fat,
            protein: protein,
            note: note,
            metadata: aiAssistedMetadata
        )
        appliedNutritionRevision &+= 1
    }
}

/// Self-contained view for AI-assisted food analysis.
/// Manages its own state for photo capture, description input, analysis, and item selection.
/// Communicates selected nutrition back through a narrow callback.
struct AIFoodAnalysisView: View {
    @State private var state: AIFoodTreatmentCoordinator
    let onApplyNutrition: (AIFoodTreatmentResult) -> Void

    @State private var showPhotoSourcePicker = false
    @State private var showPhotoPicker = false
    @State private var showAIChat = false
    @State private var photoSourceType: PhotoSourceType = .photoLibrary
    @State private var selectedImage: UIImage?
    @State private var isFoodItemsExpanded = false

    init(
        resolver: Resolver,
        onApplyNutrition: @escaping (AIFoodTreatmentResult) -> Void
    ) {
        _state = State(initialValue: AIFoodTreatmentCoordinator(resolver: resolver))
        self.onApplyNutrition = onApplyNutrition
    }

    private var isDisplayedModelAnalyzing: Bool {
        guard let modelID = state.displayedProvider else { return state.isAnalyzingFood }
        return state.perProviderAnalyzing[modelID] == true
    }

    var body: some View {
        Group {
            if !state.isInAIMode {
                // AI button
                AnimatedRainbowButton(
                    title: NSLocalizedString("Analyze Food with AI", comment: "Button label for AI-assisted food analysis"),
                    icon: "sparkles",
                    isLoading: state.isAnalyzingFood,
                    action: { showPhotoSourcePicker = true }
                )
                .padding(.bottom, 4)
            } else if state.foodItemSelection == nil, state.foodItemSelections.isEmpty, state.activeProviders.isEmpty,
                      let imageData = state.capturedImageData
            {
                // Keep the description form visible while the real primary analysis
                // runs in the background and shows provisional nutrition below it.
                ZStack {
                    FoodDescriptionInputView(
                        description: Binding(
                            get: { state.foodDescription },
                            set: { state.updateFoodDescription($0) }
                        ),
                        imageData: imageData,
                        isPreparingAnalysis: state.isPreparingFoodAnalysis,
                        provisionalItems: state.provisionalFoodItems,
                        provisionalError: state.provisionalFoodAnalysisError,
                        onContinue: {
                            state.isAnalyzingFood = true
                            state.startFoodAnalysis(
                                imageData: imageData,
                                description: state.foodDescription.isEmpty ? nil : state.foodDescription
                            )
                        },
                        onCancel: {
                            guard !state.isAnalyzingFood else { return }
                            withAnimation(.easeInOut(duration: 0.35)) {
                                state.cancelCapturedImagePreparation()
                            }
                        }
                    )
                    .disabled(state.isAnalyzingFood)
                    .opacity(state.isAnalyzingFood ? 0.4 : 1.0)

                    if state.isAnalyzingFood {
                        analysisOverlay
                    }
                }
            } else if state.foodItemSelection != nil || !state.foodItemSelections.isEmpty || !state.activeProviders.isEmpty {
                // Food items selection tree (shown during streaming and after completion)
                VStack(spacing: 0) {
                    FoodItemsSelectionView(
                        selection: $state.foodItemSelection,
                        isExpanded: $isFoodItemsExpanded,
                        pendingItemIds: state.pendingItemIds,
                        providerTabs: state.activeProviders.map { provider in
                            FoodProviderTab(
                                provider: provider,
                                isAnalyzing: state.perProviderAnalyzing[provider] ?? false,
                                error: state.perProviderErrors[provider]
                            )
                        },
                        selectedProvider: state.displayedProvider,
                        onSelectProvider: { provider in
                            state.switchDisplayedProvider(to: provider)
                        },
                        onRetryProvider: { provider in state.retryAnalysis(for: provider) },
                        onToggleItem: { itemId in
                            state.toggleFoodItem(itemId)
                        },
                        onEditItem: isDisplayedModelAnalyzing ? nil : { itemId, newDescription in
                            Task {
                                await state.editFoodItemDescription(itemId, newDescription: newDescription)
                            }
                        },
                        onOpenChat: isDisplayedModelAnalyzing ? nil : { showAIChat = true },
                        onAcceptPublished: { itemId in
                            state.acceptPublishedNutrition(for: itemId)
                        },
                        onRejectPublished: { itemId in
                            state.rejectPublishedNutrition(for: itemId)
                        }
                    )

                    if let selection = state.foodItemSelection, !isDisplayedModelAnalyzing {
                        ForEach(selection.selectedItems) { item in
                            ServingPickerView(
                                item: item,
                                userCount: Binding(
                                    get: { state.foodItemSelection?.userServingCounts[item.id] ?? item.servingCount },
                                    set: { state.updateServingCount(for: item.id, count: $0) }
                                )
                            )
                        }
                        .padding(.top, 6)
                    }

                    if isDisplayedModelAnalyzing {
                        HStack(spacing: 6) {
                            AnimatedSparkleIcon(isAnimating: true)
                            Text("Analyzing\u{2026}")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                // Strip any ambient animation cascading into this subtree (Form's
                // implicit animations, parent .animation modifiers, etc.) so that
                // switching provider tabs doesn't slide the tab bar around.
                // Internal animations (shimmer, sparkle, expand toggle) start their
                // own transactions and are unaffected.
                .transaction { $0.animation = nil }
                .onChange(of: state.foodItemSelection?.response.foodItems.count) { _, _ in
                    // Auto-expand when first items stream in
                    if state.isAnalyzingFood, !isFoodItemsExpanded {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isFoodItemsExpanded = true
                        }
                    }
                }
            }
        }
        .actionSheet(isPresented: $showPhotoSourcePicker) {
            ActionSheet(
                title: Text("Select Photo Source"),
                buttons: [
                    .default(Text("Camera")) {
                        photoSourceType = .camera
                        showPhotoPicker = true
                    },
                    .default(Text("Photo Library")) {
                        photoSourceType = .photoLibrary
                        showPhotoPicker = true
                    },
                    .cancel()
                ]
            )
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPickerWrapper(
                selectedImage: $selectedImage,
                isPresented: $showPhotoPicker,
                sourceType: photoSourceType
            )
        }
        .onChange(of: selectedImage) { _, newImage in
            if let image = newImage,
               let imageData = image.compressedForAI()
            {
                withAnimation(.easeInOut(duration: 0.35)) {
                    state.prepareCapturedImage(imageData)
                }
                selectedImage = nil
            }
        }
        .onAppear {
            // Check if the ScanFood shortcut captured an image for us
            if let imageData = ScanFoodImageRelay.shared.pendingImageData {
                ScanFoodImageRelay.shared.pendingImageData = nil
                withAnimation(.easeInOut(duration: 0.35)) {
                    state.prepareCapturedImage(imageData)
                }
            }
        }
        .onChange(of: state.appliedNutritionRevision) {
            if let nutrition = state.appliedNutrition {
                onApplyNutrition(nutrition)
            }
        }
        .fullScreenCover(isPresented: $showAIChat) {
            if let manager = state.conversationManager {
                AIChatView(
                    conversationManager: manager,
                    isPresented: $showAIChat,
                    onAcceptValues: { selection in
                        state.acceptConversationValues(selection)
                    },
                    onAcceptPublished: { itemId in
                        state.acceptPublishedNutrition(for: itemId)
                    },
                    onRejectPublished: { itemId in
                        state.rejectPublishedNutrition(for: itemId)
                    }
                )
            }
        }
        .alert(
            Text("AI Analysis Error"),
            isPresented: Binding(
                get: { state.aiError != nil },
                set: {
                    if !$0 {
                        state.clearAIError()
                    }
                }
            ),
            actions: {
                Button("OK") {
                    state.clearAIError()
                }
            },
            message: {
                Text(state.aiError ?? "")
            }
        )
    }

    private var analysisOverlay: some View {
        VStack(spacing: 8) {
            AnimatedSparkleIcon(isAnimating: true)
                .scaleEffect(1.5)

            Text("Analyzing\u{2026}")
                .font(.caption.bold())
                .foregroundColor(Color(hue: 0.75, saturation: 0.6, brightness: 0.8))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground).opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.clear)
                .totalShimmer(isAnimating: true)
        )
    }
}
