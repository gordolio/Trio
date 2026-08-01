import SwiftUI

/// An embedded published nutrition card for the chat view.
/// Shows verified nutrition data from a restaurant's official source with a link to verify.
struct ChatPublishedNutritionView: View {
    let items: [AIFoodItem]
    let restaurantName: String
    let sourceURL: String?
    let onVerifyItem: ((AIFoodItem) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            header

            // Item rows
            ForEach(items) { item in
                publishedItemRow(item: item)
                if item.id != items.last?.id {
                    Divider()
                        .padding(.leading, 4)
                }
            }

            // Source link
            if let urlString = sourceURL, let url = URL(string: urlString), let host = url.host {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 10))
                    Text(host)
                        .font(.caption2)
                }
                .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.darkGreen.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            PublishedBadge(style: .label, items: items)

            Text("· \(restaurantName)")
                .font(.caption.bold())
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    // MARK: - Item Row

    private func publishedItemRow(item: AIFoodItem) -> some View {
        VStack(spacing: 6) {
            // Item name
            HStack {
                if let emoji = item.emoji, !emoji.isEmpty {
                    Text(emoji)
                        .font(.callout)
                }
                Text(item.name)
                    .font(.callout.weight(.medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                // Verify button
                if item.sourceURL != nil, !(item.sourceURL?.isEmpty ?? true) {
                    Button {
                        onVerifyItem?(item)
                    } label: {
                        HStack(spacing: 3) {
                            Text("Verify", comment: "Button to verify published nutrition source")
                                .font(.caption2.weight(.medium))
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 9))
                        }
                        .foregroundColor(Color.darkGreen)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Macros row
            HStack(spacing: 0) {
                macroValue(value: item.carbs, label: "C", color: .primary)
                macroDivider
                macroValue(value: item.fat, label: "F", color: .secondary)
                macroDivider
                macroValue(value: item.protein, label: "P", color: .secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.tertiarySystemFill))
            )
        }
        .padding(.vertical, 2)
    }

    private func macroValue(value: Double, label: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Text(formatValue(value))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
    }

    private var macroDivider: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(width: 1, height: 14)
    }

    private func formatValue(_ value: Double) -> String {
        if value == floor(value) {
            return "\(Int(value))g"
        } else {
            return String(format: "%.1fg", value)
        }
    }
}

#if DEBUG
    struct ChatPublishedNutritionView_Previews: PreviewProvider {
        static var previews: some View {
            let sampleItems = [
                AIFoodItem(
                    name: "Whopper",
                    carbs: 49,
                    emoji: "🍔",
                    fat: 40,
                    protein: 29,
                    source: .published,
                    sourceURL: "https://www.bk.com/nutrition",
                    calories: 670
                ),
                AIFoodItem(
                    name: "French Fries",
                    carbs: 45,
                    emoji: "🍟",
                    fat: 17,
                    protein: 5,
                    source: .published,
                    sourceURL: "https://www.bk.com/nutrition",
                    calories: 340
                )
            ]

            ScrollView {
                VStack(spacing: 20) {
                    ChatPublishedNutritionView(
                        items: sampleItems,
                        restaurantName: "Burger King",
                        sourceURL: "https://www.bk.com/nutrition",
                        onVerifyItem: { item in print("Verify: \(item.name)") }
                    )

                    ChatPublishedNutritionView(
                        items: [sampleItems[0]],
                        restaurantName: "Burger King",
                        sourceURL: nil,
                        onVerifyItem: nil
                    )
                }
                .padding()
            }
        }
    }
#endif
