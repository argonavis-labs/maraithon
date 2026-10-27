import SwiftUI

/// Hairline-bordered container used for grouped rows on operational
/// pages. No fill, no shadow: the border and row hairlines do the work.
///
/// Invariant: content is clipped to the card radius so row backgrounds
/// (hover fills, empty states) never bleed past the border.
struct RunnerCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Palette.background)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.CornerRadius.small))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.CornerRadius.small)
                    .stroke(Tokens.Palette.border, lineWidth: Tokens.Stroke.hairline)
            }
    }
}

/// Standard inset for one row inside a `RunnerCard`: 10pt vertical,
/// 14pt horizontal, full width.
private struct RunnerCardRowInset: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, Tokens.Spacing.snug)
            .padding(.horizontal, Tokens.SourcesLayout.cardRowHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// Applies the shared card row inset.
    func runnerCardRow() -> some View {
        modifier(RunnerCardRowInset())
    }
}
