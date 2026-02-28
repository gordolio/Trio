import Foundation

/// The source of a food item's nutritional data
enum AIFoodItemSource: String, Codable {
    /// AI vision estimate from image analysis
    case estimated
    /// Published nutrition facts from restaurant/brand website
    case published
}

/// Represents a single food item detected by AI in a food image
struct AIFoodItem: Codable, Identifiable, Equatable {
    /// Unique identifier for this food item
    let id: UUID

    /// Name/description of the food item
    let name: String

    /// Estimated carbohydrates in grams
    let carbs: Double

    /// Emoji representation of the food (optional)
    let emoji: String?

    /// Estimated fat in grams
    let fat: Double

    /// Estimated protein in grams
    let protein: Double

    /// Source of the nutritional data (estimated by AI vision or published by restaurant)
    let source: AIFoodItemSource

    /// Citation URL for published nutrition items
    let sourceURL: String?

    /// Number of individual items in one serving (e.g., 8 for an 8-count nugget). Defaults to 1.
    let servingCount: Double

    /// Unit for the serving count (e.g., "Nuggets", "Pieces"). Defaults to "Serving".
    let servingUnit: String

    /// Calories (typically available for published items)
    let calories: Double?

    init(
        id: UUID = UUID(),
        name: String,
        carbs: Double,
        emoji: String? = nil,
        fat: Double = 0,
        protein: Double = 0,
        source: AIFoodItemSource = .estimated,
        sourceURL: String? = nil,
        servingCount: Double = 1,
        servingUnit: String = "Serving",
        calories: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.carbs = carbs
        self.emoji = emoji
        self.fat = fat
        self.protein = protein
        self.source = source
        self.sourceURL = sourceURL
        self.servingCount = servingCount
        self.servingUnit = servingUnit
        self.calories = calories
    }
}

/// Response from OpenAI containing multiple food items detected in an image
struct AIFoodItemsResponse: Codable, Equatable {
    /// Array of food items detected in the image
    let foodItems: [AIFoodItem]

    /// Overall confidence in the analysis (0.0-1.0)
    let overallConfidence: Double

    /// Total carbs across all items
    var totalCarbs: Double {
        foodItems.reduce(0) { $0 + $1.carbs }
    }

    /// Total fat across all items
    var totalFat: Double {
        foodItems.reduce(0) { $0 + $1.fat }
    }

    /// Total protein across all items
    var totalProtein: Double {
        foodItems.reduce(0) { $0 + $1.protein }
    }
}

/// Represents the selection state for food items, used by the view model
struct FoodItemSelection: Equatable {
    /// The AI response containing all food items
    let response: AIFoodItemsResponse

    /// Set of selected item IDs
    var selectedItemIds: Set<UUID>

    /// Per-item user serving counts, keyed by item ID.
    /// Only populated for items that have serving info (servingCount != nil).
    /// Initialized to the item's servingCount so multiplier starts at 1.0.
    var userServingCounts: [UUID: Double]

    init(response: AIFoodItemsResponse) {
        self.response = response
        selectedItemIds = Set(response.foodItems.map(\.id))
        // Initialize user counts to match the item's serving count (multiplier = 1.0)
        var counts: [UUID: Double] = [:]
        for item in response.foodItems {
            counts[item.id] = item.servingCount
        }
        userServingCounts = counts
    }

    /// Returns the serving multiplier for a specific item.
    func servingMultiplier(for item: AIFoodItem) -> Double {
        guard item.servingCount > 0 else { return 1.0 }
        guard let userCount = userServingCounts[item.id] else { return 1.0 }
        return userCount / item.servingCount
    }

    /// Returns only the selected food items
    var selectedItems: [AIFoodItem] {
        response.foodItems.filter { selectedItemIds.contains($0.id) }
    }

    /// Total carbs for selected items, each scaled by its own serving multiplier
    var selectedCarbs: Double {
        selectedItems.reduce(0) { $0 + $1.carbs * servingMultiplier(for: $1) }
    }

    /// Total fat for selected items, each scaled by its own serving multiplier
    var selectedFat: Double {
        selectedItems.reduce(0) { $0 + $1.fat * servingMultiplier(for: $1) }
    }

    /// Total protein for selected items, each scaled by its own serving multiplier
    var selectedProtein: Double {
        selectedItems.reduce(0) { $0 + $1.protein * servingMultiplier(for: $1) }
    }

    /// Number of selected items
    var selectedCount: Int {
        selectedItemIds.count
    }

    /// The main item to display when collapsed (highest carb item among selected)
    var mainItem: AIFoodItem? {
        selectedItems.max(by: { $0.carbs < $1.carbs })
    }

    /// Summary text for collapsed state (e.g., "Sandwich + 2 others")
    var collapsedSummary: String {
        guard let main = mainItem else {
            return NSLocalizedString("No items selected", comment: "Text shown when no food items are selected")
        }

        let emoji = main.emoji ?? ""
        let name = main.name

        if selectedCount == 1 {
            return "\(emoji) \(name)"
        } else {
            let othersCount = selectedCount - 1
            // Truncate the name if needed to fit within display limits
            let maxNameLength = 12
            let truncatedName = name.count > maxNameLength ? String(name.prefix(maxNameLength)) + "…" : name
            let format = NSLocalizedString(
                "%@%@ +%d",
                comment: "Summary showing main food item and count of others (1: emoji, 2: item name, 3: count of other items)"
            )
            return String(format: format, emoji, truncatedName, othersCount)
        }
    }

    /// Toggle selection state for an item
    mutating func toggleSelection(for itemId: UUID) {
        if selectedItemIds.contains(itemId) {
            selectedItemIds.remove(itemId)
        } else {
            selectedItemIds.insert(itemId)
        }
    }

    /// Check if a specific item is selected
    func isSelected(_ itemId: UUID) -> Bool {
        selectedItemIds.contains(itemId)
    }

    /// Returns true if any items were deselected from the original AI response
    var userModifiedSelection: Bool {
        selectedItemIds.count != response.foodItems.count
    }
}

// MARK: - Extended Response Types for Conversation

/// Response from OpenAI for initial food analysis (includes reasoning)
struct AIFoodItemsResponseWithReasoning: Codable, Equatable {
    /// Array of food items detected in the image
    let foodItems: [AIFoodItem]

    /// Overall confidence in the analysis (0.0-1.0)
    let overallConfidence: Double

    /// Reasoning explaining why these carb values were assigned
    let reasoning: String

    /// Total carbs across all items
    var totalCarbs: Double {
        foodItems.reduce(0) { $0 + $1.carbs }
    }

    /// Convert to basic response (without reasoning)
    var asBasicResponse: AIFoodItemsResponse {
        AIFoodItemsResponse(foodItems: foodItems, overallConfidence: overallConfidence)
    }
}

/// Response from OpenAI for a single item update (inline editing)
struct AISingleItemUpdateResponse: Codable, Equatable {
    /// The updated item ID
    let itemId: UUID

    /// The new carb count for this item
    let updatedCarbs: Double

    /// Brief reasoning for the update
    let reasoning: String

    /// Updated fat estimate
    let updatedFat: Double?

    /// Updated protein estimate
    let updatedProtein: Double?
}

/// Response from OpenAI for a conversation turn
struct AIConversationResponse: Codable, Equatable {
    /// All food items (full list, potentially with updates)
    let foodItems: [AIFoodItem]

    /// IDs of items that were updated in this turn
    let updatedItemIds: [UUID]

    /// Message to display in chat
    let assistantMessage: String

    /// Overall confidence in the updated analysis
    let overallConfidence: Double
}
