import SwiftUI

/// Wraps children onto new lines when they exceed the available width, with
/// each line vertically centered. Used for a task title followed by its
/// badges so short titles keep badges inline and long titles push them down.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = Tokens.Spacing.small
    var verticalSpacing: CGFloat = Tokens.Spacing.compact

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arranged = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in arranged.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var lineStart = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0

        func closeLine(upTo end: Int) {
            for index in lineStart..<end {
                frames[index].origin.y += (lineHeight - frames[index].height) / 2
            }
        }

        for (index, subview) in subviews.enumerated() {
            let remaining = width - x
            var size = subview.sizeThatFits(ProposedViewSize(width: remaining, height: nil))
            if size.width > remaining, x > 0 {
                closeLine(upTo: index)
                lineStart = index
                x = 0
                y += lineHeight + verticalSpacing
                lineHeight = 0
                size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            if width.isFinite { size.width = min(size.width, width) }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            lineHeight = max(lineHeight, size.height)
            x += size.width + horizontalSpacing
            widest = max(widest, x - horizontalSpacing)
        }
        closeLine(upTo: subviews.count)

        let totalWidth = width.isFinite ? width : widest
        return (CGSize(width: totalWidth, height: y + lineHeight), frames)
    }
}
