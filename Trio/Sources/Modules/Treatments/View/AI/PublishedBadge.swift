import SwiftUI

/// Display style for the published badge
enum PublishedBadgeStyle {
    /// Small green pill with white text — used inline next to food item names
    case badge
    /// Caption-sized green text with checkmark icon — used in summary headers
    case label
}

/// A reusable tappable "Published" indicator that opens `PublishedSourceVerificationView`
/// when tapped. Supports both inline badge and header label styles.
struct PublishedBadge: View {
    let style: PublishedBadgeStyle
    let items: [AIFoodItem]
    var onAccept: ((UUID) -> Void)?
    var onReject: ((UUID) -> Void)?

    @State private var verifyingItem: AIFoodItem?

    /// Items that have a valid source URL for verification
    private var verifiableItems: [AIFoodItem] {
        items.filter { $0.sourceURL != nil && !($0.sourceURL?.isEmpty ?? true) }
    }

    var body: some View {
        Group {
            switch style {
            case .badge:
                badgeContent
            case .label:
                labelContent
            }
        }
        .padding(6)
        .contentShape(Rectangle())
        .highPriorityGesture(
            TapGesture().onEnded {
                handleTap()
            }
        )
        .sheet(item: $verifyingItem) { item in
            if let urlString = item.sourceURL, let url = URL(string: urlString) {
                PublishedSourceVerificationView(
                    url: url,
                    item: item,
                    onAccept: { onAccept?(item.id) },
                    onReject: { onReject?(item.id) }
                )
            }
        }
    }

    // MARK: - Badge Style (green pill)

    private var badgeContent: some View {
        let hasURL = !verifiableItems.isEmpty

        return HStack(spacing: 2) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 8))
            Text("Published", comment: "Badge indicating nutrition data comes from official published source")
                .font(.system(size: 9, weight: .medium))
            if hasURL {
                Image(systemName: "chevron.right")
                    .font(.system(size: 6, weight: .bold))
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.darkGreen)
        .cornerRadius(4)
        .fixedSize()
    }

    // MARK: - Label Style (green text)

    private var labelContent: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 12))
                .foregroundColor(Color.darkGreen)
            Text("Published", comment: "Label for published nutrition data")
                .font(.caption.bold())
                .foregroundColor(Color.darkGreen)
            if !verifiableItems.isEmpty {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Color.darkGreen.opacity(0.7))
            }
        }
    }

    // MARK: - Tap Handling

    private func handleTap() {
        guard !verifiableItems.isEmpty else { return }

        if verifiableItems.count == 1 {
            verifyingItem = verifiableItems[0]
        } else {
            // Multiple verifiable items — pick the first one
            // (they typically share the same source URL for restaurant items)
            verifyingItem = verifiableItems[0]
        }
    }
}
