import SwiftUI

/// Page section: an uppercase caption heading with 8pt below it, then the
/// section content, then 24pt of space before the next section. Every
/// operational page composes its body from these so section rhythm is
/// identical across sources, Recall, and future pages.
struct RunnerSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, Tokens.Spacing.large)
    }
}
