import Foundation

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
}
