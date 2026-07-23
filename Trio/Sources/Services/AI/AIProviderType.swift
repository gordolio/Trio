import Foundation

/// Selects which AI backend powers the app's AI-assisted carb entry features.
enum AIProviderType: String, JSON, CaseIterable, Identifiable {
    case openrouter

    var id: String { rawValue }

    var displayName: String {
        String(localized: "OpenRouter")
    }

    /// Shorter label used in compact UI like tab bars where horizontal space is tight.
    var shortDisplayName: String {
        String(localized: "OpenRouter")
    }
}
