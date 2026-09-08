import SwiftUI

/// Wraps tags and other intrinsic-size content into rows without clipping.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for (index, placement) in result.placements.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    private func arrangement(width proposedWidth: CGFloat?, subviews: Subviews) -> (size: CGSize, placements: [CGRect]) {
        let width = proposedWidth.flatMap { $0.isFinite ? max(0, $0) : nil } ?? .greatestFiniteMagnitude
        let gap = max(0, spacing)
        var placements: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for view in subviews {
            let intrinsic = view.sizeThatFits(.unspecified)
            let size = intrinsic.width > width
                ? view.sizeThatFits(ProposedViewSize(width: width, height: nil))
                : intrinsic
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + gap
                rowHeight = 0
            }
            placements.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + gap
        }
        return (CGSize(width: usedWidth, height: placements.isEmpty ? 0 : y + rowHeight), placements)
    }
}
