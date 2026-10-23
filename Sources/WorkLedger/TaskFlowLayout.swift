import SwiftUI

struct TaskFlowLayout: Layout {
    var spacing: CGFloat = 10
    var rowSpacing: CGFloat = 4

    struct Arrangement {
        let frames: [CGRect]
        let size: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(subviews: subviews, width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(subviews: subviews, width: bounds.width)
        for (subview, frame) in zip(subviews, layout.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(subviews: Subviews, width: CGFloat?) -> Arrangement {
        let limit = Self.widthLimit(width)
        let sizes = subviews.map { subview in
            let ideal = subview.sizeThatFits(.unspecified)
            guard let limit, ideal.width > limit else { return ideal }
            return subview.sizeThatFits(ProposedViewSize(width: limit, height: nil))
        }
        return Self.arrange(sizes, width: limit, spacing: spacing, rowSpacing: rowSpacing)
    }

    static func arrange(_ sizes: [CGSize], width: CGFloat?, spacing: CGFloat = 10, rowSpacing: CGFloat = 4) -> Arrangement {
        let limit = widthLimit(width)
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        var rowIsEmpty = true
        for size in sizes {
            let itemWidth = max(0, min(size.width, limit ?? size.width))
            let itemHeight = max(0, size.height)
            var itemX = rowIsEmpty ? 0 : x + spacing
            if let limit, !rowIsEmpty, itemX + itemWidth > limit {
                y += rowHeight + rowSpacing
                itemX = 0; rowHeight = 0
            }
            frames.append(CGRect(x: itemX, y: y, width: itemWidth, height: itemHeight))
            x = itemX + itemWidth
            usedWidth = max(usedWidth, x)
            rowHeight = max(rowHeight, itemHeight)
            rowIsEmpty = false
        }
        return Arrangement(frames: frames, size: CGSize(width: usedWidth, height: sizes.isEmpty ? 0 : y + rowHeight))
    }

    private static func widthLimit(_ width: CGFloat?) -> CGFloat? {
        guard let width, width.isFinite else { return nil }
        return max(0, width)
    }
}
