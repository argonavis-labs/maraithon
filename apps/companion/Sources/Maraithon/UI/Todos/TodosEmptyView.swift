import SwiftUI

/// Quiet in-table empty state with an optional action, matching the web
/// table's centered empty row rather than the stock unavailable view.
struct TodosEmptyView: View {
    let title: String
    let description: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Tokens.Spacing.small) {
            Text(title)
                .font(Tokens.Typography.bodyMedium)
                .foregroundStyle(Tokens.Palette.foreground)
            Text(description)
                .font(Tokens.Typography.small)
                .foregroundStyle(Tokens.Palette.mutedForeground)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
                    .padding(.top, Tokens.Spacing.xsmall)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.Spacing.page)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Tokens.Palette.border)
                .frame(height: Tokens.Stroke.hairline)
        }
    }
}
