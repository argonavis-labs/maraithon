import SwiftUI

/// Section heading modifier for operational pages: 11pt medium,
/// uppercase, 0.5 tracking, muted, with 8pt below before the section
/// body. Reach for this whenever a `VStack` acts as a page section.
///
/// Invariant: never introduce a parallel header style. If a screen needs
/// a different label rhythm, add a case here instead of writing
/// one-offs.
struct SectionHeaderStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Tokens.Typography.captionMedium)
            .foregroundStyle(Tokens.Palette.mutedForeground)
            .textCase(.uppercase)
            .tracking(Tokens.SourcesLayout.sectionHeadingTracking)
            .padding(.bottom, Tokens.Spacing.small)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Applies the standard workspace section header treatment.
    func sectionHeaderStyle() -> some View {
        modifier(SectionHeaderStyle())
    }
}

/// Convenience wrapper for the common `Text` + modifier case.
struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .sectionHeaderStyle()
    }
}

#Preview {
    VStack(alignment: .leading, spacing: Tokens.Spacing.large) {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Status")
            Text("Checking. 47 new, 0 errors")
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Palette.foreground)
        }
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Recent activity")
            Text("14:23. 47 messages")
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Palette.foreground)
        }
    }
    .padding(Tokens.Spacing.large)
    .frame(width: 360, alignment: .leading)
    .background(Tokens.Palette.background)
}
