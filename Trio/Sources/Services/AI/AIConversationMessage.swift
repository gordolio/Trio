import Foundation

/// Role of a message in the AI conversation
enum AIMessageRole: String, Codable {
    case user
    case assistant
    case system
}

/// Content types that can appear in conversation messages
enum AIConversationMessageContent: Equatable {
    /// Plain text message
    case text(String)

    /// Carb summary component (embedded in chat like an image)
    case carbSummary(items: [AIFoodItem], canAccept: Bool)

    /// Published nutrition info card showing verified restaurant nutrition data
    case publishedNutrition(items: [AIFoodItem], restaurantName: String, sourceURL: String?)

    /// System event notification (e.g., "User updated 'Ground Beef' to 'Corned Beef Hash'")
    case systemEvent(String)
}

/// A single message in the AI conversation
struct AIConversationMessage: Identifiable, Equatable {
    let id: UUID
    let role: AIMessageRole
    let content: AIConversationMessageContent
    let timestamp: Date

    init(
        id: UUID = UUID(),
        role: AIMessageRole,
        content: AIConversationMessageContent,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }

    /// Convenience initializer for user text messages
    static func userMessage(_ text: String) -> AIConversationMessage {
        AIConversationMessage(role: .user, content: .text(text))
    }

    /// Convenience initializer for assistant text messages
    static func assistantMessage(_ text: String) -> AIConversationMessage {
        AIConversationMessage(role: .assistant, content: .text(text))
    }

    /// Convenience initializer for system events (like inline edits)
    static func systemEvent(_ text: String) -> AIConversationMessage {
        AIConversationMessage(role: .system, content: .systemEvent(text))
    }

    /// Convenience initializer for carb summary components
    static func carbSummary(items: [AIFoodItem], canAccept: Bool = true) -> AIConversationMessage {
        AIConversationMessage(role: .assistant, content: .carbSummary(items: items, canAccept: canAccept))
    }

    /// Convenience initializer for published nutrition cards
    static func publishedNutrition(
        items: [AIFoodItem],
        restaurantName: String,
        sourceURL: String?
    ) -> AIConversationMessage {
        AIConversationMessage(
            role: .assistant,
            content: .publishedNutrition(items: items, restaurantName: restaurantName, sourceURL: sourceURL)
        )
    }
}

// MARK: - Conversation History for API

/// Simplified message format for sending to OpenAI API
struct AIConversationHistoryMessage: Codable {
    let role: String
    let content: String

    init(from message: AIConversationMessage) {
        role = message.role.rawValue
        switch message.content {
        case let .text(text):
            content = text
        case let .carbSummary(items, _):
            // Convert to text representation for API
            let itemsList = items.map { "\($0.emoji ?? "") \($0.name): \(Int($0.carbs))g" }.joined(separator: ", ")
            content = "Current food items: \(itemsList)"
        case let .publishedNutrition(items, restaurantName, _):
            let itemsList = items
                .map { "\($0.name): \(Int($0.carbs))g carbs, \(Int($0.fat))g fat, \(Int($0.protein))g protein" }
                .joined(separator: "; ")
            content = "Published nutrition from \(restaurantName): \(itemsList)"
        case let .systemEvent(event):
            content = event
        }
    }
}
