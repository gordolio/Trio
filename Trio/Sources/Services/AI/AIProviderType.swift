import Foundation

struct OpenRouterModelSet {
    let primaryModel: String
    let classifierModel: String

    static let openAI = OpenRouterModelSet(
        primaryModel: "openai/gpt-4o",
        classifierModel: "openai/gpt-4o-mini"
    )

    static let claude = OpenRouterModelSet(
        primaryModel: "anthropic/claude-opus-4.5",
        classifierModel: "anthropic/claude-haiku-4.5"
    )
}

/// Selects which AI backend powers the app's AI-assisted carb entry features.
enum AIProviderType: String, JSON, CaseIterable, Identifiable {
    case openai
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai:
            return String(localized: "OpenAI")
        case .claude:
            return String(localized: "Claude (Anthropic)")
        }
    }

    /// Shorter label used in compact UI like tab bars where horizontal space is tight.
    var shortDisplayName: String {
        switch self {
        case .openai:
            return String(localized: "ChatGPT")
        case .claude:
            return String(localized: "Claude")
        }
    }

    var modelSet: OpenRouterModelSet {
        switch self {
        case .openai:
            return .openAI
        case .claude:
            return .claude
        }
    }
}
