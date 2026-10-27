import SwiftUI

/// Centered, muted empty state with an optional action. Used inside
/// cards and page bodies where the stock unavailable view would bring
/// system chrome.
struct RunnerEmptyState: View {
    let title: String
    var description: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Tokens.Spacing.small) {
            Text(title)
                .font(Tokens.Typography.bodyMedium)
                .foregroundStyle(Tokens.Palette.foreground)
                .multilineTextAlignment(.center)
            if let description, !description.isEmpty {
                Text(description)
                    .font(Tokens.Typography.small)
                    .foregroundStyle(Tokens.Palette.mutedForeground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
                    .padding(.top, Tokens.Spacing.xsmall)
            }
        }
        .frame(maxWidth: Tokens.SourcesLayout.issueCopyMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.SourcesLayout.emptyStateVerticalPadding)
        .padding(.horizontal, Tokens.Spacing.large)
        .accessibilityElement(children: .combine)
    }
}
