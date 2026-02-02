import SwiftUI
import UIKit

/// An animated button with a rotating purple/blue AI-themed gradient border.
struct AnimatedRainbowButton: View {
    let title: String
    let icon: String
    let isLoading: Bool
    let action: () -> Void

    @State private var effectsOpacity: Double = 1.0

    // Purple/blue AI-themed gradient colors
    private let glowColors: [Color] = [
        Color(hue: 0.75, saturation: 0.7, brightness: 1.0), // Purple
        Color(hue: 0.60, saturation: 0.7, brightness: 1.0), // Blue
        Color(hue: 0.55, saturation: 0.6, brightness: 1.0), // Cyan
        Color(hue: 0.65, saturation: 0.8, brightness: 1.0), // Blue
        Color(hue: 0.80, saturation: 0.6, brightness: 1.0), // Violet
        Color(hue: 0.75, saturation: 0.7, brightness: 1.0) // Purple (loop)
    ]

    init(
        title: String,
        icon: String = "sparkles",
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                // Background fill
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(UIColor.systemBackground))

                // Static border that appears as glow fades
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(1.0 - effectsOpacity), lineWidth: 1.0)

                // Button content
                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .medium))
                    }

                    Text(title)
                        .bold()
                }
                .foregroundColor(.primary)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .overlay(
                RotatingGradientBorder(colors: glowColors)
                    .padding(-12) // expand canvas so blur extends outside button
                    .opacity(effectsOpacity)
                    .allowsHitTesting(false)
            )
        }
        .disabled(isLoading)
        .opacity(isLoading ? 0.7 : 1.0)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                withAnimation(.easeOut(duration: 1.5)) {
                    effectsOpacity = 0
                }
            }
        }
    }
}

/// Draws a rotating conic gradient masked to a rounded rect stroke,
/// with a soft glow rendered via a second blurred pass.
private struct RotatingGradientBorder: View {
    let colors: [Color]
    private let cornerRadius: CGFloat = 12
    private let borderWidth: CGFloat = 1.5
    private let glowRadius: CGFloat = 6
    private let padding: CGFloat = 12
    private let rotationDuration: Double = 3.0

    var body: some View {
        TimelineView(.animation) { timeline in
            let angle = Angle.degrees(
                timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: rotationDuration) / rotationDuration * 360
            )
            Canvas { context, size in
                // Inset the stroke path so it lines up with the button edge
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: padding, dy: padding)
                let path = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .path(in: rect)

                let gradient = Gradient(colors: colors)
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let shading = GraphicsContext.Shading.conicGradient(
                    gradient,
                    center: center,
                    angle: angle
                )

                // Glow pass — clip interior so glow only extends outward
                context.drawLayer { glowCtx in
                    glowCtx.addFilter(.blur(radius: glowRadius))
                    glowCtx.stroke(
                        path,
                        with: shading,
                        style: StrokeStyle(lineWidth: borderWidth + 4)
                    )
                    // Punch out the interior
                    glowCtx.blendMode = .destinationOut
                    glowCtx.fill(path, with: .color(.white))
                }

                // Crisp border pass
                context.stroke(
                    path,
                    with: shading,
                    style: StrokeStyle(lineWidth: borderWidth)
                )
            }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        AnimatedRainbowButton(
            title: "Analyze Food with AI",
            icon: "sparkles",
            isLoading: false,
            action: {}
        )
        .padding(.horizontal)

        AnimatedRainbowButton(
            title: "Analyzing...",
            icon: "sparkles",
            isLoading: true,
            action: {}
        )
        .padding(.horizontal)
    }
    .padding(.vertical)
    .background(Color(UIColor.systemGroupedBackground))
}
