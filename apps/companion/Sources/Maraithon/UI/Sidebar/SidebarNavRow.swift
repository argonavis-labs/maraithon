import SwiftUI

/// One sidebar destination: icon, label, optional trailing status text.
/// Active rows get the warm selected tint and a 2pt accent bar; hovered
/// rows lift with a 3% ink wash.
struct SidebarNavRow: View {
    let title: String
    let symbol: String
    var trailing: String? = nil
    var trailingColor: Color? = nil
    let isActive: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Spacing.snug) {
                Image(systemName: symbol)
                    .font(Tokens.Typography.navIcon)
                    .frame(width: Tokens.IconSize.inline)
                    .foregroundStyle(iconColor)
                    .accessibilityHidden(true)
                Text(title)
                    .font(isActive ? Tokens.Typography.bodyMedium : Tokens.Typography.body)
                    .foregroundStyle(labelColor)
                    .lineLimit(1)
                Spacer(minLength: Tokens.Spacing.xsmall)
                if let trailing {
                    Text(trailing)
                        .font(Tokens.Typography.micro)
                        .foregroundStyle(trailingColor ?? Tokens.Palette.mutedForeground)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Tokens.Spacing.snug)
            .frame(minHeight: Tokens.Layout.navRowMinHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: Tokens.CornerRadius.control))
            .overlay(alignment: .leading) {
                if isActive {
                    RoundedRectangle(cornerRadius: Tokens.CornerRadius.hairline)
                        .fill(Tokens.Palette.selectedBar)
                        .frame(width: Tokens.Stroke.activeBar)
                        .padding(.vertical, Tokens.Spacing.snug)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var background: Color {
        if isActive { return Tokens.Palette.selected }
        return hovering ? Tokens.Palette.foreground3 : .clear
    }

    private var labelColor: Color {
        isActive || hovering ? Tokens.Palette.foreground : Tokens.Palette.mutedForeground
    }

    private var iconColor: Color {
        if isActive { return Tokens.Palette.accent }
        return hovering ? Tokens.Palette.foreground : Tokens.Palette.mutedForeground
    }
}
