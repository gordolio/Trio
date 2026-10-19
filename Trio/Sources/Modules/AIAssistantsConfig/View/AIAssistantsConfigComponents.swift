import SwiftUI

extension AIAssistantsConfig {
    /// An SF Symbol on a rounded square, like the icons in Settings.
    struct IconTile: View {
        let symbol: String
        let fill: AnyShapeStyle
        var size: CGFloat = 29

        init(symbol: String, tint: Color, size: CGFloat = 29) {
            self.init(symbol: symbol, fill: AnyShapeStyle(tint.gradient), size: size)
        }

        init(symbol: String, fill: AnyShapeStyle, size: CGFloat = 29) {
            self.symbol = symbol
            self.fill = fill
            self.size = size
        }

        var body: some View {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(fill)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)
        }
    }

    struct StatusDot: View {
        let color: Color

        var body: some View {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Shows `message` at the bottom for a moment each time `trigger` changes. It's hidden from
    /// VoiceOver: the state model announces copies itself.
    func copiedToast(message: String, trigger: Int) -> some View {
        overlay(alignment: .bottom) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(message)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: Capsule())
            .padding(.bottom, 24)
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { content, opacity in
                content.opacity(opacity)
            } keyframes: { _ in
                LinearKeyframe(1.0, duration: 0.15)
                LinearKeyframe(1.0, duration: 1.2)
                LinearKeyframe(0.0, duration: 0.35)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
