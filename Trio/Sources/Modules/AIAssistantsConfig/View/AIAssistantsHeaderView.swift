import SwiftUI

extension AIAssistantsConfig {
    /// The screen's title, with its icon and what it's for.
    struct HeaderView: View {
        var body: some View {
            Section {
                VStack(spacing: 10) {
                    IconTile(
                        symbol: "bubble.left.and.text.bubble.right.fill",
                        fill: AnyShapeStyle(
                            LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                        ),
                        size: 64
                    )
                    Text("AI Assistants")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text(
                        "Ask ChatGPT, Claude or Grok about your glucose and insulin, or have them log a meal for you to approve."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .listRowBackground(Color.clear)
        }
    }
}
