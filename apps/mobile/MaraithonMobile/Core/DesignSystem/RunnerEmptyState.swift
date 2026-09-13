import SwiftUI

/// Quiet centered empty state with an optional action.
struct RunnerEmptyState: View {
    let title: String
    let description: String
    var systemImage: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Runner.Spacing.small) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(Runner.Typography.sectionTitle)
                    .foregroundStyle(Runner.Palette.mutedForeground)
                    .padding(.bottom, Runner.Spacing.xsmall)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(Runner.Typography.bodyMedium)
                .foregroundStyle(Runner.Palette.foreground)
                .multilineTextAlignment(.center)
            Text(description)
                .font(Runner.Typography.small)
                .foregroundStyle(Runner.Palette.mutedForeground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
                    .padding(.top, Runner.Spacing.xsmall)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Runner.Spacing.xlarge)
        .padding(.horizontal, Runner.Spacing.large)
    }
}
