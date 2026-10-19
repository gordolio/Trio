import SwiftUI

extension AIAssistantsConfig {
    /// The assistants the screen explains how to connect. Steps follow each one's official docs
    /// as of October 2026.
    enum Assistant: String, CaseIterable, Identifiable {
        case claude
        case chatGPT
        case grok

        var id: String { rawValue }

        /// Product names, so they aren't localized.
        var name: String {
            switch self {
            case .claude: return "Claude"
            case .chatGPT: return "ChatGPT"
            case .grok: return "Grok"
            }
        }

        /// SF Symbols only: no brand artwork.
        var symbol: String {
            switch self {
            case .claude: return "sparkle"
            case .chatGPT: return "bubble.left.and.bubble.right.fill"
            case .grok: return "bolt.fill"
            }
        }

        var tint: Color {
            switch self {
            case .claude: return .orange
            case .chatGPT: return .green
            case .grok: return .gray
            }
        }

        var steps: [String] {
            let signIn = String(localized: "Sign in with Apple using this same Apple ID, then allow access.")
            let check = String(localized: "Ask \"What's my glucose?\" to check it works.")
            switch self {
            case .claude:
                return [
                    String(localized: "On claude.ai, open Customize, then Connectors."),
                    String(localized: "Choose Add, then Add custom connector, and paste the connector URL."),
                    signIn,
                    check
                ]
            case .chatGPT:
                return [
                    String(localized: "On chatgpt.com, open Plugins, choose +, then Add custom MCP server."),
                    String(
                        localized: "Paste the connector URL as the server URL, choose OAuth, then create the plugin and install it."
                    ),
                    signIn,
                    String(localized: "In a new chat, type @, pick the plugin, and ask \"What's my glucose?\"")
                ]
            case .grok:
                return [
                    String(localized: "On grok.com, open Connectors."),
                    String(localized: "Choose New Connector, then Custom, and paste the connector URL."),
                    signIn,
                    check
                ]
            }
        }

        var note: String {
            switch self {
            case .claude:
                return String(localized: "Claude on your phone, laptop and the web share the connector once it's added.")
            case .chatGPT:
                return String(
                    localized: "Custom MCP servers are added on chatgpt.com in a browser, and need a ChatGPT plan that allows them."
                )
            case .grok:
                return String(localized: "On Grok Business or Enterprise, an admin adds the connector for your team first.")
            }
        }
    }

    /// Example questions, grouped by the tool that answers them.
    struct QuestionGroup: Identifiable {
        let title: String
        let symbol: String
        let tint: Color
        let questions: [String]

        var id: String { title }
    }

    static let questionGroups = [
        // get_status
        QuestionGroup(
            title: String(localized: "Glucose and loop"),
            symbol: "drop.fill",
            tint: .red,
            questions: [
                String(localized: "What's my glucose?"),
                String(localized: "How much insulin is on board?"),
                String(localized: "Is Trio looping?"),
                String(localized: "Am I trending up or down?")
            ]
        ),
        // get_recent_treatments, which covers the last 1–24 hours
        QuestionGroup(
            title: String(localized: "Meals and boluses"),
            symbol: "fork.knife",
            tint: .orange,
            questions: [
                String(localized: "What did I eat today?"),
                String(localized: "When was my last bolus?"),
                String(localized: "How many carbs in the last 6 hours?")
            ]
        )
    ]
}
