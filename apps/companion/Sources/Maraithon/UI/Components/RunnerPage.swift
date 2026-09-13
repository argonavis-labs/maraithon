import SwiftUI

/// Scrollable page container matching the Tasks page: a leading-aligned
/// column capped at `Tokens.Layout.pageMaxWidth`, 40pt side gutters, the
/// standard top inset, and the workspace background. The window hides its
/// title bar, so pages draw their own header with `RunnerPageHeader`.
struct RunnerPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: Tokens.Layout.pageMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Tokens.Spacing.page)
            .padding(.top, Tokens.Layout.pageTopInset)
            .padding(.bottom, Tokens.Spacing.page)
        }
        .background(Tokens.Palette.background)
    }
}
