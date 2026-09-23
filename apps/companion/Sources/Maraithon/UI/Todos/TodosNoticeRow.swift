/// Inline warning when a refresh fails but the previous list remains usable.
import SwiftUI

struct TodosNoticeRow: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: Tokens.Spacing.small) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Tokens.Palette.cautionText)
                .accessibilityHidden(true)
            Text(message)
                .font(Tokens.Typography.small)
                .foregroundStyle(Tokens.Palette.cautionText)
                .lineLimit(2)
            Spacer()
            Button("Retry", action: retry)
                .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
        }
        .padding(.horizontal, Tokens.Spacing.tight)
        .padding(.vertical, Tokens.Spacing.small)
        .padding(.bottom, Tokens.Spacing.small)
        .accessibilityElement(children: .combine)
    }
}
