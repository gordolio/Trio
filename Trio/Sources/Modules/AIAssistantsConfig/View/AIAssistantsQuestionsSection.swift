import SwiftUI

extension AIAssistantsConfig {
    /// Example questions as chips; tapping one copies it.
    struct QuestionsSection: View {
        @ObservedObject var state: StateModel

        var body: some View {
            Section(
                header: Text("Things you can ask"),
                footer: Text("Assistants can only read. Nothing they do changes your treatments.")
            ) {
                ForEach(AIAssistantsConfig.questionGroups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            IconTile(symbol: group.symbol, tint: group.tint, size: 24)
                            Text(group.title)
                                .font(.subheadline.weight(.semibold))
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)

                        FlowLayout {
                            ForEach(group.questions, id: \.self) { question in
                                chip(question, tint: group.tint)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listRowBackground(Color.chart)
        }

        private func chip(_ question: String, tint: Color) -> some View {
            Button {
                state.copyQuestion(question)
            } label: {
                Text(question)
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.borderless)
            .accessibilityHint(Text("Copies the question"))
        }
    }
}
