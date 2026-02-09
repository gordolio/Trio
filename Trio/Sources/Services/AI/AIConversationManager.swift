import Combine
import Foundation
import os.log

/// Manages the state of an AI conversation for food analysis refinement
final class AIConversationManager: ObservableObject {
    private let log = OSLog(subsystem: "com.loopkit.Loop", category: "AIConversationManager")

    // MARK: - Published State

    /// All messages in the conversation
    @Published var messages: [AIConversationMessage] = []

    /// Current food items (source of truth during conversation)
    @Published var currentItems: [AIFoodItem] = []

    /// IDs of items currently being recalculated (for shimmer animation)
    @Published var pendingItemIds: Set<UUID> = []

    /// Whether an API call is in progress
    @Published var isProcessing = false

    /// Error message if last operation failed
    @Published var errorMessage: String?

    // MARK: - Stored Data

    /// The original image data for API calls
    var imageData: Data?

    /// User's initial description (optional context)
    var userDescription: String?

    /// Reasoning from the initial analysis (shown as first chat message)
    var initialReasoning: String?

    /// Selected item IDs (which items are checked in the tree)
    var selectedItemIds: Set<UUID> = []

    /// Overall confidence from the most recent analysis
    var overallConfidence: Double = 0.0

    // MARK: - Computed Properties

    /// Total carbs for selected items
    var selectedCarbs: Double {
        currentItems.filter { selectedItemIds.contains($0.id) }
            .reduce(0) { $0 + $1.carbs }
    }

    /// Total carbs for all items
    var totalCarbs: Double {
        currentItems.reduce(0) { $0 + $1.carbs }
    }

    /// Only the selected items
    var selectedItems: [AIFoodItem] {
        currentItems.filter { selectedItemIds.contains($0.id) }
    }

    // MARK: - Initialization

    init() {}

    /// Initialize with the result of an initial food analysis
    @MainActor func initialize(
        with response: AIFoodItemsResponseWithReasoning,
        imageData: Data,
        userDescription: String?
    ) {
        self.imageData = imageData
        self.userDescription = userDescription
        currentItems = response.foodItems
        selectedItemIds = Set(response.foodItems.map(\.id))
        initialReasoning = response.reasoning
        overallConfidence = response.overallConfidence

        // Add the initial reasoning as the first assistant message (hidden until chat opens)
        messages = [
            .assistantMessage(response.reasoning),
            .carbSummary(items: response.foodItems, canAccept: true)
        ]

        os_log(
            "Initialized conversation with %d items, total %.1fg carbs",
            log: log,
            type: .info,
            currentItems.count,
            totalCarbs
        )
    }

    /// Replace current items with merged items (e.g., after published nutrition merge).
    /// Preserves conversation state while updating item data.
    @MainActor func replaceItems(_ newItems: [AIFoodItem]) {
        currentItems = newItems
        selectedItemIds = Set(newItems.map(\.id))

        // Rebuild messages with updated items
        if let reasoning = initialReasoning {
            messages = [
                .assistantMessage(reasoning),
                .carbSummary(items: newItems, canAccept: true)
            ]
        }

        os_log(
            "Replaced items with %d merged items, total %.1fg carbs",
            log: log,
            type: .info,
            currentItems.count,
            totalCarbs
        )
    }

    // MARK: - Streaming Initialization

    /// Initialize the conversation by consuming a stream of partial food analysis results.
    /// Food items appear progressively in the UI as they are parsed from the stream.
    /// - Parameters:
    ///   - stream: AsyncThrowingStream of partial results from the streaming API
    ///   - imageData: The original image data
    ///   - userDescription: Optional user context
    @MainActor func initializeStreaming(
        stream: AsyncThrowingStream<PartialFoodAnalysisResult, Error>,
        imageData: Data,
        userDescription: String?,
        onItemsUpdated: ((_ items: [AIFoodItem]) -> Void)? = nil
    ) async throws -> AIFoodItemsResponseWithReasoning {
        self.imageData = imageData
        self.userDescription = userDescription
        currentItems = []
        selectedItemIds = []
        messages = []

        var finalResult: PartialFoodAnalysisResult?

        for try await partial in stream {
            os_log(
                "Stream update: %d items (current: %d), complete: %{public}@",
                log: log,
                type: .info,
                partial.foodItems.count,
                currentItems.count,
                partial.isComplete ? "YES" : "NO"
            )

            // Update items incrementally — new items appear as they stream in
            if partial.foodItems.count > currentItems.count {
                let newItems = partial.foodItems.suffix(from: currentItems.count)
                for item in newItems {
                    currentItems.append(item)
                    selectedItemIds.insert(item.id)
                }
            }

            // Update existing items if their values changed (e.g., partial number completed)
            for (index, item) in partial.foodItems.enumerated() where index < currentItems.count {
                if currentItems[index] != item {
                    let existingId = currentItems[index].id
                    currentItems[index] = AIFoodItem(
                        id: existingId,
                        name: item.name,
                        carbs: item.carbs,
                        emoji: item.emoji,
                        fat: item.fat,
                        protein: item.protein
                    )
                }
            }

            // Notify caller so the view can update
            if !currentItems.isEmpty {
                onItemsUpdated?(currentItems)
            }

            if partial.isComplete {
                finalResult = partial
            }
        }

        guard let final_ = finalResult, !final_.foodItems.isEmpty else {
            throw OpenAIServiceError.noContentInResponse
        }

        // Build the final response using our stable IDs
        let response = AIFoodItemsResponseWithReasoning(
            foodItems: currentItems,
            overallConfidence: final_.overallConfidence,
            reasoning: final_.reasoning
        )

        // Finalize conversation state
        initialReasoning = response.reasoning
        overallConfidence = response.overallConfidence

        messages = [
            .assistantMessage(response.reasoning),
            .carbSummary(items: currentItems, canAccept: true)
        ]

        os_log(
            "Streaming initialization complete: %d items, total %.1fg carbs",
            log: log,
            type: .info,
            currentItems.count,
            currentItems.reduce(0) { $0 + $1.carbs }
        )

        return response
    }

    // MARK: - Inline Item Editing

    /// Update a single item's description and recalculate its carbs
    /// - Parameters:
    ///   - itemId: The ID of the item to update
    ///   - newDescription: The new description for the item
    @MainActor func updateItemDescription(itemId: UUID, newDescription: String) async {
        guard let imageData = imageData else {
            os_log("Cannot update item: no image data", log: log, type: .error)
            return
        }

        guard let itemIndex = currentItems.firstIndex(where: { $0.id == itemId }) else {
            os_log("Cannot update item: item not found", log: log, type: .error)
            return
        }

        let oldName = currentItems[itemIndex].name

        // Immediately update the item name so the UI doesn't revert
        let oldItem = currentItems[itemIndex]
        currentItems[itemIndex] = AIFoodItem(
            id: oldItem.id,
            name: newDescription,
            carbs: oldItem.carbs,
            emoji: oldItem.emoji,
            fat: oldItem.fat,
            protein: oldItem.protein
        )

        // Add system event to conversation history
        let editEvent = "User updated '\(oldName)' to '\(newDescription)'"
        messages.append(.systemEvent(editEvent))

        // Mark item as pending (triggers shimmer animation)
        pendingItemIds.insert(itemId)
        isProcessing = true
        errorMessage = nil

        os_log(
            "Updating item '%{public}@' to '%{public}@'",
            log: log,
            type: .info,
            oldName,
            newDescription
        )

        do {
            let response = try await OpenAIService.shared.updateSingleItem(
                imageData: imageData,
                currentItems: currentItems,
                editedItemId: itemId,
                newDescription: newDescription
            )

            // Update the item in our list
            var updatedItem = currentItems[itemIndex]
            updatedItem = AIFoodItem(
                id: updatedItem.id,
                name: newDescription,
                carbs: response.updatedCarbs,
                emoji: updatedItem.emoji,
                fat: response.updatedFat ?? updatedItem.fat,
                protein: response.updatedProtein ?? updatedItem.protein
            )
            currentItems[itemIndex] = updatedItem

            // Add brief reasoning to conversation
            if !response.reasoning.isEmpty {
                messages.append(.assistantMessage(response.reasoning))
            }

            // Add updated carb summary
            messages.append(.carbSummary(items: currentItems, canAccept: true))

            os_log("Item updated: %.1fg carbs", log: log, type: .info, response.updatedCarbs)

        } catch {
            os_log(
                "Failed to update item: %{public}@",
                log: log,
                type: .error,
                error.localizedDescription
            )
            errorMessage = error.localizedDescription
        }

        // Clear pending state
        pendingItemIds.remove(itemId)
        isProcessing = false
    }

    // MARK: - Chat Messages

    /// Send a user message and get AI response
    /// - Parameter text: The user's message
    @MainActor func sendMessage(_ text: String) async {
        guard let imageData = imageData else {
            os_log("Cannot send message: no image data", log: log, type: .error)
            return
        }

        // Add user message to history
        messages.append(.userMessage(text))

        // Mark all items as potentially pending during conversation turn
        let allItemIds = Set(currentItems.map(\.id))
        pendingItemIds = allItemIds
        isProcessing = true
        errorMessage = nil

        os_log("Sending chat message: %{public}@", log: log, type: .info, text)

        do {
            let response = try await OpenAIService.shared.conversationTurn(
                imageData: imageData,
                currentItems: currentItems,
                conversationHistory: messages,
                userMessage: text
            )

            // Build a map of old item name -> selected state before replacing
            let oldSelectionByName = Dictionary(
                currentItems.map { ($0.name.lowercased(), selectedItemIds.contains($0.id)) },
                uniquingKeysWith: { first, _ in first }
            )

            // Update items
            currentItems = response.foodItems
            overallConfidence = response.overallConfidence

            // Reconcile selection by name: preserve deselected state, default new items to selected
            selectedItemIds = Set(
                response.foodItems
                    .filter { oldSelectionByName[$0.name.lowercased()] ?? true }
                    .map(\.id)
            )

            // Add assistant response
            messages.append(.assistantMessage(response.assistantMessage))
            messages.append(.carbSummary(items: response.foodItems, canAccept: true))

            os_log(
                "Conversation turn complete: %d items updated",
                log: log,
                type: .info,
                response.updatedItemIds.count
            )

        } catch {
            os_log(
                "Conversation turn failed: %{public}@",
                log: log,
                type: .error,
                error.localizedDescription
            )
            errorMessage = error.localizedDescription

            // Add error message to chat
            messages.append(.assistantMessage(
                "I'm sorry, I encountered an error processing your request. Please try again."
            ))
        }

        // Clear pending state
        pendingItemIds.removeAll()
        isProcessing = false
    }

    // MARK: - Accept Values

    /// Create a FoodItemSelection from the current conversation state
    /// - Returns: A FoodItemSelection representing the current items and selections
    func acceptCurrentValues() -> FoodItemSelection {
        let response = AIFoodItemsResponse(
            foodItems: currentItems,
            overallConfidence: overallConfidence
        )
        var selection = FoodItemSelection(response: response)
        selection.selectedItemIds = selectedItemIds
        return selection
    }

    // MARK: - Selection Management

    /// Toggle selection of an item
    func toggleSelection(for itemId: UUID) {
        if selectedItemIds.contains(itemId) {
            selectedItemIds.remove(itemId)
        } else {
            selectedItemIds.insert(itemId)
        }
    }

    /// Check if an item is selected
    func isSelected(_ itemId: UUID) -> Bool {
        selectedItemIds.contains(itemId)
    }

    // MARK: - Utilities

    /// Clear any error message
    func clearError() {
        errorMessage = nil
    }

    /// Reset the conversation (but keep items)
    func resetConversation() {
        messages = []
        if let reasoning = initialReasoning {
            messages.append(.assistantMessage(reasoning))
        }
        messages.append(.carbSummary(items: currentItems, canAccept: true))
        errorMessage = nil
    }
}
