import SwiftUI

struct SyncIssueBanner: View {
    let title: String
    let message: String
    let buttonTitle: String?
    let retry: (() -> Void)?
    let dismissAccessibilityLabel: String
    let dismiss: () -> Void

    init(
        title: String = "Latest data may be out of date",
        message: String,
        buttonTitle: String? = "Retry",
        retry: (() -> Void)? = nil,
        dismissAccessibilityLabel: String = "Dismiss warning",
        dismiss: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.buttonTitle = buttonTitle
        self.retry = retry
        self.dismissAccessibilityLabel = dismissAccessibilityLabel
        self.dismiss = dismiss
    }

    var body: some View {
        HStack(alignment: .top, spacing: Runner.Spacing.snug) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Runner.Typography.caption)
                .foregroundStyle(Runner.Palette.cautionText)
                .frame(width: Runner.Spacing.roomy, height: Runner.Spacing.roomy)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Runner.Spacing.xxsmall) {
                Text(title)
                    .font(Runner.Typography.smallMedium)
                    .foregroundStyle(Runner.Palette.foreground)

                Text(message)
                    .font(Runner.Typography.caption)
                    .foregroundStyle(Runner.Palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Runner.Spacing.small)

            if let buttonTitle, let retry {
                Button(buttonTitle, action: retry)
                    .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
            }

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(Runner.Typography.caption)
                    .foregroundStyle(Runner.Palette.mutedForeground)
                    .frame(width: Runner.Layout.compactControlHeight, height: Runner.Layout.compactControlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dismissAccessibilityLabel)
        }
        .padding(.horizontal, Runner.Spacing.medium)
        .padding(.vertical, Runner.Spacing.snug)
        .background(Runner.Palette.badgeFill(Runner.Palette.hueAmber))
        .overlay(alignment: .bottom) { RunnerHairline() }
    }
}
