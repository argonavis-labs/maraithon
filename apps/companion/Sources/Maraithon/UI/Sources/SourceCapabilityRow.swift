import SwiftUI

/// Card row for one source capability or privacy note: muted glyph,
/// 13pt title, 12pt muted description.
struct SourceCapabilityRow: View {
    let capability: SourceCapability

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.snug) {
            Image(systemName: capability.systemImage)
                .font(Tokens.Typography.navIcon)
                .foregroundStyle(Tokens.Palette.mutedForeground)
                .frame(width: Tokens.SourcesLayout.rowIconColumnWidth, alignment: .center)
                .padding(.top, Tokens.Spacing.xxsmall)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Tokens.Spacing.xxsmall) {
                Text(capability.title)
                    .font(Tokens.Typography.bodyMedium)
                    .foregroundStyle(Tokens.Palette.foreground)
                Text(capability.description)
                    .font(Tokens.Typography.small)
                    .foregroundStyle(Tokens.Palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .runnerCardRow()
        .accessibilityElement(children: .combine)
    }
}
