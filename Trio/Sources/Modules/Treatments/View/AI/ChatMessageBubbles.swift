import SwiftUI

// MARK: - Chat Bubble Tail Shape

/// A chat bubble tail that sits at the bottom corner of a message bubble.
/// Draws a small curved appendage like iMessage bubbles.
private struct BubbleTail: Shape {
    /// Whether the tail points to the right (user) or left (assistant)
    var isFromUser: Bool = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w: CGFloat = 10
        let h: CGFloat = 16

        if isFromUser {
            // Right-side tail
            path.move(to: CGPoint(x: rect.maxX - w, y: rect.maxY - h))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.maxY - h * 0.15)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - w, y: rect.maxY),
                control: CGPoint(x: rect.maxX - w * 0.5, y: rect.maxY)
            )
        } else {
            // Left-side tail
            path.move(to: CGPoint(x: rect.minX + w, y: rect.maxY - h))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY),
                control: CGPoint(x: rect.minX, y: rect.maxY - h * 0.15)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + w, y: rect.maxY),
                control: CGPoint(x: rect.minX + w * 0.5, y: rect.maxY)
            )
        }

        path.closeSubpath()
        return path
    }
}

// MARK: - Message Bubbles

/// A user message bubble (right-aligned, blue background, tail on right)
struct UserMessageBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer(minLength: 60)

            ZStack(alignment: .bottomTrailing) {
                Text(text)
                    .font(.body)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                BubbleTail(isFromUser: true)
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 16)
                    .offset(x: 3, y: 2)
            }
        }
    }
}

/// An assistant text message bubble (left-aligned, grey background, tail on left).
/// Light mode: light grey bubble. Dark mode: dark grey bubble.
struct AssistantMessageBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Text(text)
                    .font(.body)
                    .foregroundColor(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                BubbleTail(isFromUser: false)
                    .fill(Color(.systemGray5))
                    .frame(width: 10, height: 16)
                    .offset(x: -3, y: 2)
            }

            Spacer(minLength: 60)
        }
    }
}

/// A system event message (centered, subtle styling)
struct SystemEventMessageView: View {
    let text: String

    var body: some View {
        HStack {
            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "pencil.circle")
                    .font(.caption)
                Text(text)
                    .font(.caption)
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.tertiarySystemFill))
            .cornerRadius(12)

            Spacer()
        }
    }
}

/// A typing indicator for when the AI is processing
struct TypingIndicator: View {
    @State private var dotOpacities: [Double] = [0.3, 0.3, 0.3]

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    ForEach(0 ..< 3, id: \.self) { index in
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 8, height: 8)
                            .opacity(dotOpacities[index])
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(.systemGray5))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                BubbleTail(isFromUser: false)
                    .fill(Color(.systemGray5))
                    .frame(width: 10, height: 16)
                    .offset(x: -3, y: 2)
            }

            Spacer(minLength: 60)
        }
        .onAppear {
            animateDots()
        }
    }

    private func animateDots() {
        for index in 0 ..< 3 {
            withAnimation(
                .easeInOut(duration: 0.4)
                    .repeatForever(autoreverses: true)
                    .delay(Double(index) * 0.15)
            ) {
                dotOpacities[index] = 1.0
            }
        }
    }
}

// MARK: - Carb Summary Header

/// Header view for the carb summary showing AI sparkle icon
struct AICarbSummaryHeader: View {
    let totalCarbs: Double
    let totalFat: Double
    let totalProtein: Double
    let items: [AIFoodItem]
    let isUpdating: Bool
    var hasPublishedItems: Bool = false
    var allPublished: Bool = false
    var publishedItems: [AIFoodItem] = []
    var onAcceptPublished: ((UUID) -> Void)?
    var onRejectPublished: ((UUID) -> Void)?
    var nutrientDisplay: NutrientDisplayMode = .carbs
    var onCycleNutrient: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            // Source indicator
            HStack(spacing: 4) {
                if allPublished {
                    PublishedBadge(
                        style: .label,
                        items: publishedItems,
                        onAccept: onAcceptPublished,
                        onReject: onRejectPublished
                    )
                } else if hasPublishedItems {
                    AnimatedSparkleIcon(isAnimating: isUpdating)
                    Text("AI Estimate", comment: "Label for AI-generated carb estimate")
                        .font(.caption.bold())
                    Text("·")
                        .font(.caption.bold())
                    PublishedBadge(
                        style: .label,
                        items: publishedItems,
                        onAccept: onAcceptPublished,
                        onReject: onRejectPublished
                    )
                } else {
                    AnimatedSparkleIcon(isAnimating: isUpdating)
                    Text("AI Estimate", comment: "Label for AI-generated carb estimate")
                        .font(.caption.bold())
                }
            }
            .foregroundColor(.secondary)

            Spacer()

            // Total nutrient value
            VStack(alignment: .trailing, spacing: 2) {
                AnimatedNutrientValue(
                    carbs: totalCarbs,
                    fat: totalFat,
                    protein: totalProtein,
                    mode: nutrientDisplay,
                    valueFont: .title2.bold(),
                    altValueFont: .title3.bold(),
                    unitFont: .caption,
                    valueColor: .primary,
                    unitColor: .secondary
                )
                Text(itemCountLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .totalShimmer(isAnimating: isUpdating)
            .contentShape(Rectangle())
            .onTapGesture {
                onCycleNutrient?()
            }
        }
    }

    private var itemCountLabel: String {
        // For a single item with specific serving info, show serving details (e.g., "4 Crackers")
        if items.count == 1, let item = items.first, item.servingUnit != "Serving" {
            let count = Int(item.servingCount)
            return "\(count) \(item.servingUnit)"
        }
        if items.count == 1 {
            return String(localized: "1 item", comment: "Single item count")
        } else {
            return String(localized: "\(items.count) items", comment: "Multiple item count")
        }
    }
}

#if DEBUG
    struct ChatMessageBubbles_Previews: PreviewProvider {
        static var previews: some View {
            VStack(spacing: 16) {
                UserMessageBubble(text: "Actually the rice is brown rice")

                AssistantMessageBubble(
                    text: "I've updated the rice to brown rice. The carb count is now slightly lower at 35g instead of 40g since brown rice has more fiber."
                )

                SystemEventMessageView(text: "User updated 'Ground Beef' to 'Corned Beef Hash'")

                TypingIndicator()

                AICarbSummaryHeader(totalCarbs: 47, totalFat: 14, totalProtein: 22, items: [
                    AIFoodItem(name: "Sandwich", carbs: 32, emoji: "🥪", fat: 14, protein: 22),
                    AIFoodItem(name: "Apple", carbs: 15, emoji: "🍎"),
                    AIFoodItem(name: "Diet Soda", carbs: 0, emoji: "🥤")
                ], isUpdating: false)
                    .padding()
                    .background(Color(.systemGroupedBackground))
                    .cornerRadius(12)

                AICarbSummaryHeader(totalCarbs: 47, totalFat: 14, totalProtein: 22, items: [
                    AIFoodItem(name: "Sandwich", carbs: 32, emoji: "🥪", fat: 14, protein: 22),
                    AIFoodItem(name: "Apple", carbs: 15, emoji: "🍎"),
                    AIFoodItem(name: "Diet Soda", carbs: 0, emoji: "🥤")
                ], isUpdating: true)
                    .padding()
                    .background(Color(.systemGroupedBackground))
                    .cornerRadius(12)
            }
            .padding()
        }
    }
#endif
