import SwiftUI

/// Lightweight section header modifier that matches macOS `Form` section
/// headings: uppercase, footnote weight, secondary tone, with a single
/// unit of bottom padding. Reach for this whenever a custom `VStack`
/// pretends to be a Form section.
///
/// Invariant: never introduce a parallel header style. If a screen needs
/// a different label rhythm, add a case here instead of writing
/// one-offs.
struct SectionHeaderStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
            .padding(.bottom, Tokens.Spacing.xsmall)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Applies the standard macOS-style section header treatment.
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
        VStack(alignment: .leading) {
            SectionHeader("Status")
            Text("● Syncing — 47 new, 0 errors")
                .foregroundStyle(.primary)
        }
        VStack(alignment: .leading) {
            SectionHeader("Recent activity")
            Text("14:23 — 47 messages")
                .foregroundStyle(.primary)
        }
    }
    .padding(Tokens.Spacing.large)
    .frame(width: 360, alignment: .leading)
}
