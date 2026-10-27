import SwiftUI

/// The terracotta "m" mark with the product name and caption. Tapping it
/// returns to Tasks, mirroring the web brand link.
struct SidebarBrand: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Spacing.snug + 1) {
                Text("m")
                    .font(Tokens.Typography.brandMark)
                    .foregroundStyle(.white)
                    .padding(.bottom, Tokens.Spacing.xsmall)
                    .frame(width: Tokens.IconSize.brandMark, height: Tokens.IconSize.brandMark)
                    .background(Tokens.Palette.accent, in: RoundedRectangle(cornerRadius: Tokens.CornerRadius.small))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Maraithon")
                        .font(Tokens.Typography.brand)
                        .tracking(Tokens.Typography.brandTracking)
                        .foregroundStyle(Tokens.Palette.foreground)
                    Text("Your chief of staff")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.mutedForeground)
                }
            }
            .padding(.horizontal, Tokens.Spacing.small + 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Maraithon, your chief of staff")
        .accessibilityHint("Shows Tasks")
    }
}
