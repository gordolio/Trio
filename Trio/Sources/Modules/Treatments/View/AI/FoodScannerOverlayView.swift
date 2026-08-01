import SwiftUI

/// Shared geometry for the visible scanner frame and the captured-image crop.
enum FoodScannerLayout {
    static let controlsHeight: CGFloat = 150

    static func scanRegion(
        in size: CGSize,
        safeTop: CGFloat,
        safeBottom: CGFloat
    ) -> CGRect {
        let sidePadding: CGFloat = 16
        let topTextY = safeTop + 24
        let regionTop = topTextY + 56
        let regionBottom = size.height - safeBottom - controlsHeight

        return CGRect(
            x: sidePadding,
            y: regionTop,
            width: size.width - (sidePadding * 2),
            height: max(0, regionBottom - regionTop)
        )
    }
}

/// Camera overlay view with styled scanning region corners and instructional text.
/// Uses the Trio AI purple/blue gradient theme.
///
/// Layout uses standard iOS spacing and safe area insets so it adapts
/// correctly across all iPhone models without hardcoded percentages.
struct FoodScannerOverlayView: View {
    var safeAreaInsets: EdgeInsets?

    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 1.0
    @State private var textOpacity: Double = 0.0

    private let gradientColors: [Color] = [
        Color(hue: 0.75, saturation: 0.7, brightness: 1.0), // Purple
        Color(hue: 0.60, saturation: 0.7, brightness: 1.0), // Blue
        Color(hue: 0.55, saturation: 0.6, brightness: 1.0) // Cyan
    ]

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let safeTop = safeAreaInsets?.top ?? geometry.safeAreaInsets.top
            let safeBottom = safeAreaInsets?.bottom ?? geometry.safeAreaInsets.bottom

            let cornerLength: CGFloat = 40
            let cornerLineWidth: CGFloat = 3
            let cornerRadius: CGFloat = 20

            // Text above the scan region, below the safe area
            let topTextY = safeTop + 24

            let regionRect = FoodScannerLayout.scanRegion(
                in: geometry.size,
                safeTop: safeTop,
                safeBottom: safeBottom
            )

            ZStack {
                // Dim everything outside the scan region
                Color.black.opacity(0.5)
                    .mask(
                        VignetteMask(regionRect: regionRect, cornerRadius: cornerRadius)
                            .fill(style: FillStyle(eoFill: true))
                    )

                // Corner brackets
                cornersView(
                    in: regionRect,
                    cornerLength: cornerLength,
                    cornerLineWidth: cornerLineWidth,
                    cornerRadius: cornerRadius
                )
                .scaleEffect(pulseScale, anchor: .center)
                .opacity(pulseOpacity)

                // Text above the scan region
                VStack(spacing: 4) {
                    Text(NSLocalizedString(
                        "Scan Food or Nutrition Facts",
                        comment: "Camera overlay instruction for AI food scanning"
                    ))
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.7), radius: 6, x: 0, y: 2)

                    Text(NSLocalizedString(
                        "Position food or label within the frame",
                        comment: "Camera overlay subtitle for AI food scanning"
                    ))
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundColor(.white.opacity(0.75))
                        .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 1)
                }
                .multilineTextAlignment(.center)
                .position(
                    x: w / 2,
                    y: topTextY + 12
                )
                .opacity(textOpacity)
            }
            .onAppear {
                withAnimation(.easeOut(duration: 0.6).delay(0.2)) {
                    textOpacity = 1.0
                }
                withAnimation(
                    .easeInOut(duration: 2.0)
                        .repeatForever(autoreverses: true)
                ) {
                    pulseScale = 1.01
                    pulseOpacity = 0.8
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Corner Brackets

    private func cornersView(
        in rect: CGRect,
        cornerLength: CGFloat,
        cornerLineWidth: CGFloat,
        cornerRadius: CGFloat
    ) -> some View {
        let gradient = LinearGradient(
            colors: gradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        return ZStack {
            CornerBracket(corner: .topLeft, length: cornerLength, radius: cornerRadius)
                .stroke(gradient, style: StrokeStyle(lineWidth: cornerLineWidth, lineCap: .round))
                .frame(width: cornerLength, height: cornerLength)
                .position(x: rect.minX + cornerLength / 2, y: rect.minY + cornerLength / 2)

            CornerBracket(corner: .topRight, length: cornerLength, radius: cornerRadius)
                .stroke(gradient, style: StrokeStyle(lineWidth: cornerLineWidth, lineCap: .round))
                .frame(width: cornerLength, height: cornerLength)
                .position(x: rect.maxX - cornerLength / 2, y: rect.minY + cornerLength / 2)

            CornerBracket(corner: .bottomLeft, length: cornerLength, radius: cornerRadius)
                .stroke(gradient, style: StrokeStyle(lineWidth: cornerLineWidth, lineCap: .round))
                .frame(width: cornerLength, height: cornerLength)
                .position(x: rect.minX + cornerLength / 2, y: rect.maxY - cornerLength / 2)

            CornerBracket(corner: .bottomRight, length: cornerLength, radius: cornerRadius)
                .stroke(gradient, style: StrokeStyle(lineWidth: cornerLineWidth, lineCap: .round))
                .frame(width: cornerLength, height: cornerLength)
                .position(x: rect.maxX - cornerLength / 2, y: rect.maxY - cornerLength / 2)
        }
    }
}

// MARK: - Corner Bracket Shape

private enum Corner {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

private struct CornerBracket: Shape {
    let corner: Corner
    let length: CGFloat
    let radius: CGFloat

    func path(in _: CGRect) -> Path {
        let r = min(radius, length / 2)
        var path = Path()

        switch corner {
        case .topLeft:
            path.move(to: CGPoint(x: 0, y: length))
            path.addLine(to: CGPoint(x: 0, y: r))
            path.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: length, y: 0))

        case .topRight:
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: length - r, y: 0))
            path.addQuadCurve(to: CGPoint(x: length, y: r), control: CGPoint(x: length, y: 0))
            path.addLine(to: CGPoint(x: length, y: length))

        case .bottomLeft:
            path.move(to: CGPoint(x: length, y: length))
            path.addLine(to: CGPoint(x: r, y: length))
            path.addQuadCurve(to: CGPoint(x: 0, y: length - r), control: CGPoint(x: 0, y: length))
            path.addLine(to: CGPoint(x: 0, y: 0))

        case .bottomRight:
            path.move(to: CGPoint(x: 0, y: length))
            path.addLine(to: CGPoint(x: length - r, y: length))
            path.addQuadCurve(to: CGPoint(x: length, y: length - r), control: CGPoint(x: length, y: length))
            path.addLine(to: CGPoint(x: length, y: 0))
        }

        return path
    }
}

// MARK: - Vignette Mask

/// Cuts out the scan region from a full-screen rectangle for the vignette effect.
private struct VignetteMask: Shape {
    let regionRect: CGRect
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRoundedRect(in: regionRect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        return path
    }
}

#Preview {
    ZStack {
        Color.black
        FoodScannerOverlayView()
    }
}
