import Foundation

/// Merges published nutrition facts with vision-estimated food items.
/// Published facts take priority for matching items; vision fills in extras.
enum NutritionFactsMerger {
    /// Minimum confidence threshold for published results to be used
    private static let minimumConfidence: Double = 0.3

    /// Merges published nutrition data with vision-detected items.
    ///
    /// Strategy:
    /// 1. If published data found and meets confidence threshold, create an AIFoodItem with source = .published
    /// 2. Remove any vision items that are likely duplicates of the published item
    /// 3. Keep all non-matching vision items (sides, drinks, extras) with source = .estimated
    ///
    /// - Parameters:
    ///   - publishedResult: Nutrition from web search (nil if classifier said no or search failed)
    ///   - visionItems: Items from the streaming vision analysis
    /// - Returns: Merged array of AIFoodItem with published item first (if present)
    static func merge(
        publishedResult: PublishedNutritionResult?,
        visionItems: [AIFoodItem]
    ) -> [AIFoodItem] {
        guard let published = publishedResult, published.confidence >= minimumConfidence else {
            return visionItems
        }

        // Clean the menu item name by stripping any parenthesized restaurant name the LLM may have included
        let cleanedMenuItemName = cleanMenuItemName(published.menuItemName, restaurantName: published.restaurantName)

        // Create the published food item
        let publishedItem = AIFoodItem(
            name: cleanedMenuItemName,
            carbs: published.carbs,
            emoji: findBestEmoji(from: visionItems, matching: published),
            fat: published.fat,
            protein: published.protein,
            source: .published,
            sourceURL: published.sourceURL,
            servingCount: published.servingCount,
            servingUnit: published.servingCountUnit,
            calories: published.calories
        )

        // Filter out vision items that are likely duplicates of the published item
        let nonDuplicateVisionItems = visionItems.filter { visionItem in
            !isLikelyMatch(
                visionItemName: visionItem.name,
                publishedItemName: cleanedMenuItemName,
                restaurantName: published.restaurantName
            )
        }

        // Published item first, then remaining vision items (sides, drinks, extras)
        return [publishedItem] + nonDuplicateVisionItems
    }

    /// Determines if a vision item name matches the published item (fuzzy comparison).
    /// Uses lowercased containment checks in both directions.
    static func isLikelyMatch(
        visionItemName: String,
        publishedItemName: String,
        restaurantName: String
    ) -> Bool {
        let visionLower = visionItemName.lowercased()
        let publishedLower = publishedItemName.lowercased()
        let restaurantLower = restaurantName.lowercased()

        // Direct containment in either direction
        if visionLower.contains(publishedLower) || publishedLower.contains(visionLower) {
            return true
        }

        // Check if vision item contains the restaurant name (e.g., "Burger King Whopper")
        if visionLower.contains(restaurantLower) {
            // Strip the restaurant name and check what's left
            let stripped = visionLower.replacingOccurrences(of: restaurantLower, with: "").trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty || publishedLower.contains(stripped) || stripped.contains(publishedLower) {
                return true
            }
        }

        // Check word overlap: if most significant words match
        let visionWords = Set(visionLower.split(separator: " ").map(String.init))
        let publishedWords = Set(publishedLower.split(separator: " ").map(String.init))
        let commonWords = visionWords.intersection(publishedWords)

        // If more than half of the shorter set's words match, consider it a match
        let shorterCount = min(visionWords.count, publishedWords.count)
        if shorterCount > 0, Double(commonWords.count) / Double(shorterCount) >= 0.5 {
            return true
        }

        return false
    }

    /// Strips any parenthesized restaurant name from the menu item name.
    /// e.g., "Hash Browns (Chick-fil-A)" → "Hash Browns"
    static func cleanMenuItemName(_ menuItemName: String, restaurantName: String) -> String {
        let restaurantLower = restaurantName.lowercased()
        // Remove parenthesized text containing the restaurant name
        var cleaned = menuItemName
        if let openParen = cleaned.range(of: "("),
           let closeParen = cleaned.range(of: ")", range: openParen.upperBound ..< cleaned.endIndex)
        {
            let parenContent = cleaned[openParen.upperBound ..< closeParen.lowerBound].lowercased()
            if parenContent.trimmingCharacters(in: .whitespaces).contains(restaurantLower) ||
                restaurantLower.contains(parenContent.trimmingCharacters(in: .whitespaces))
            {
                cleaned.removeSubrange(openParen.lowerBound ... closeParen.lowerBound)
                cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            }
        }
        return cleaned.isEmpty ? menuItemName : cleaned
    }

    /// Find the best emoji from vision items that match the published item
    private static func findBestEmoji(
        from visionItems: [AIFoodItem],
        matching published: PublishedNutritionResult
    ) -> String? {
        // Try to find a matching vision item and use its emoji
        for item in visionItems {
            if isLikelyMatch(
                visionItemName: item.name,
                publishedItemName: published.menuItemName,
                restaurantName: published.restaurantName
            ) {
                return item.emoji
            }
        }
        return nil
    }
}
