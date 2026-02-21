import SwiftUI

/// Reusable component that cross-fades between carbs, fat, and protein displays.
///
/// All three nutrient views are stacked in a ZStack. The active mode is fully opaque
/// while the others are hidden. This gives a clean fade-in/fade-out transition with
/// no layout movement.
///
/// Carbs mode uses the larger `valueFont` directly. Fat and protein modes use the
/// smaller `altValueFont`/`altUnitFont` with a unit label suffix.
struct AnimatedNutrientValue: View {
    let carbs: Double
    let fat: Double
    let protein: Double
    let mode: NutrientDisplayMode
    let valueFont: Font
    let altValueFont: Font
    let unitFont: Font
    let valueColor: Color
    let unitColor: Color

    var body: some View {
        ZStack {
            // Carbs layer — normal size, no label
            Text(formatNutrientValue(carbs))
                .font(valueFont.monospacedDigit())
                .foregroundColor(valueColor)
                .opacity(mode == .carbs ? 1 : 0)

            // Fat layer — smaller size with label
            HStack(spacing: 4) {
                Text(formatNutrientValue(fat))
                    .font(altValueFont.monospacedDigit())
                    .foregroundColor(valueColor)
                Text(NutrientDisplayMode.fat.label)
                    .font(unitFont)
                    .foregroundColor(unitColor)
            }
            .opacity(mode == .fat ? 1 : 0)

            // Protein layer — smaller size with label
            HStack(spacing: 4) {
                Text(formatNutrientValue(protein))
                    .font(altValueFont.monospacedDigit())
                    .foregroundColor(valueColor)
                Text(NutrientDisplayMode.protein.label)
                    .font(unitFont)
                    .foregroundColor(unitColor)
            }
            .opacity(mode == .protein ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.25), value: mode)
    }
}

/// Formats a nutrient value as a string with "g" suffix.
/// Whole numbers display without decimals (e.g. "47g"), fractional values show one decimal (e.g. "14.5g").
func formatNutrientValue(_ value: Double) -> String {
    if value == floor(value) {
        return "\(Int(value))g"
    } else {
        return String(format: "%.1fg", value)
    }
}
