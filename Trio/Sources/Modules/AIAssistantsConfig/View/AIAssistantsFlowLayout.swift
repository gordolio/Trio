import SwiftUI

extension AIAssistantsConfig {
    /// Lays out its subviews left to right, wrapping onto new rows, like words in a paragraph.
    struct FlowLayout: Layout {
        var spacing: CGFloat = 8
        var lineSpacing: CGFloat = 8

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
            let maxWidth = proposal.width ?? .infinity
            return Self.arrange(
                sizes: sizes(of: subviews, maxWidth: maxWidth),
                maxWidth: maxWidth,
                spacing: spacing,
                lineSpacing: lineSpacing
            )
            .size
        }

        func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
            let frames = Self.arrange(
                sizes: sizes(of: subviews, maxWidth: bounds.width),
                maxWidth: bounds.width,
                spacing: spacing,
                lineSpacing: lineSpacing
            ).frames
            for (subview, frame) in zip(subviews, frames) {
                subview.place(
                    at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                    proposal: ProposedViewSize(frame.size)
                )
            }
        }

        /// Each subview's ideal size; one wider than a row is measured again at the row's width,
        /// so its text wraps.
        private func sizes(of subviews: Subviews, maxWidth: CGFloat) -> [CGSize] {
            subviews.map { subview in
                let ideal = subview.sizeThatFits(.unspecified)
                guard ideal.width > maxWidth else { return ideal }
                return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            }
        }

        /// Frames for items of `sizes`, filling rows up to `maxWidth`. An item wider than a row
        /// gets a row of its own and is clamped to `maxWidth`; a row is as tall as its tallest item.
        static func arrange(
            sizes: [CGSize],
            maxWidth: CGFloat,
            spacing: CGFloat,
            lineSpacing: CGFloat
        ) -> (frames: [CGRect], size: CGSize) {
            var frames: [CGRect] = []
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0
            var width: CGFloat = 0
            for size in sizes {
                let itemWidth = min(size.width, maxWidth)
                if x > 0, x + spacing + itemWidth > maxWidth {
                    y += rowHeight + lineSpacing
                    x = 0
                    rowHeight = 0
                }
                let originX = x > 0 ? x + spacing : 0
                frames.append(CGRect(x: originX, y: y, width: itemWidth, height: size.height))
                x = originX + itemWidth
                rowHeight = max(rowHeight, size.height)
                width = max(width, x)
            }
            return (frames, frames.isEmpty ? .zero : CGSize(width: width, height: y + rowHeight))
        }
    }
}
