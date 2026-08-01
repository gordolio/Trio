import SwiftUI

/// Compact per-item serving size picker that lets the user adjust how many they consumed.
struct ServingPickerView: View {
    let item: AIFoodItem
    @Binding var userCount: Double

    private var isModified: Bool {
        abs(userCount - item.servingCount) > 0.01
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.servingUnit)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                Text("\(formatCount(item.servingCount)) per serving")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    let newValue = max(0.5, userCount - 1)
                    userCount = newValue
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundColor(userCount <= 0.5 ? Color.secondary.opacity(0.3) : .accentColor)
                }
                .disabled(userCount <= 0.5)
                .buttonStyle(.plain)

                Text(formatCount(userCount))
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundColor(isModified ? .accentColor : .primary)
                    .frame(minWidth: 28, alignment: .center)

                Button {
                    userCount += 1
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .animation(.easeInOut(duration: 0.15), value: userCount)
    }

    private func formatCount(_ value: Double) -> String {
        if value == floor(value) {
            return "\(Int(value))"
        } else {
            return String(format: "%.1f", value)
        }
    }
}
