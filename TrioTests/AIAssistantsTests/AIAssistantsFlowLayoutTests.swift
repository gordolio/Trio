import CoreGraphics
import Testing

@testable import Trio

@Suite("AI Assistants chip flow layout") struct AIAssistantsFlowLayoutTests {
    /// Lays out chips of the given (width, height) sizes with 8 pt spacing between chips and rows.
    func arrange(_ sizes: [(CGFloat, CGFloat)], maxWidth: CGFloat) -> (frames: [CGRect], size: CGSize) {
        AIAssistantsConfig.FlowLayout.arrange(
            sizes: sizes.map { CGSize(width: $0.0, height: $0.1) },
            maxWidth: maxWidth,
            spacing: 8,
            lineSpacing: 8
        )
    }

    @Test("Chips that fit share a row") func fitsOnOneRow() {
        let result = arrange([(50, 20), (60, 20)], maxWidth: 200)
        #expect(result.frames == [CGRect(x: 0, y: 0, width: 50, height: 20), CGRect(x: 58, y: 0, width: 60, height: 20)])
        #expect(result.size == CGSize(width: 118, height: 20))
    }

    @Test("A chip that doesn't fit starts a new row under the tallest one") func wrapsBelowTallest() {
        let result = arrange([(50, 20), (50, 40), (150, 20)], maxWidth: 200)
        #expect(result.frames == [
            CGRect(x: 0, y: 0, width: 50, height: 20),
            CGRect(x: 58, y: 0, width: 50, height: 40),
            CGRect(x: 0, y: 48, width: 150, height: 20)
        ])
        #expect(result.size == CGSize(width: 150, height: 68))
    }

    @Test("A chip that fits exactly stays on the row") func exactFitStays() {
        let result = arrange([(100, 20), (92, 20)], maxWidth: 200)
        #expect(result.frames[1] == CGRect(x: 108, y: 0, width: 92, height: 20))
        #expect(result.size == CGSize(width: 200, height: 20))
    }

    @Test("A chip wider than the row gets its own row, clamped to the row width") func wideChipClamped() {
        let result = arrange([(50, 20), (300, 40), (40, 20)], maxWidth: 200)
        #expect(result.frames == [
            CGRect(x: 0, y: 0, width: 50, height: 20),
            CGRect(x: 0, y: 28, width: 200, height: 40),
            CGRect(x: 0, y: 76, width: 40, height: 20)
        ])
        #expect(result.size == CGSize(width: 200, height: 96))
    }

    @Test("No chips take no space") func empty() {
        let result = arrange([], maxWidth: 200)
        #expect(result.frames.isEmpty)
        #expect(result.size == .zero)
    }

    @Test("Without a width limit every chip shares one row") func unlimitedWidth() {
        let result = arrange([(50, 20), (300, 20)], maxWidth: .infinity)
        #expect(result.frames[1] == CGRect(x: 58, y: 0, width: 300, height: 20))
        #expect(result.size == CGSize(width: 358, height: 20))
    }
}
