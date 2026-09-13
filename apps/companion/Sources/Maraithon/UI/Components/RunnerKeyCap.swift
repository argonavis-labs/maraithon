import SwiftUI

/// Inline keyboard hint (`/`, `?`) used beside search fields and buttons.
struct RunnerKeyCap: View {
    let key: String
    var bordered = false

    var body: some View {
        Text(key)
            .font(Tokens.Typography.caption)
            .foregroundStyle(Tokens.Palette.mutedForeground)
            .padding(.horizontal, bordered ? Tokens.Spacing.xsmall : 0)
            .padding(.vertical, bordered ? Tokens.Spacing.xxsmall / 2 : 0)
            .overlay {
                if bordered {
                    RoundedRectangle(cornerRadius: Tokens.CornerRadius.checkbox)
                        .stroke(Tokens.Palette.border, lineWidth: Tokens.Stroke.hairline)
                }
            }
            .accessibilityHidden(true)
    }
}
