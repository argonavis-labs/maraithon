import SwiftUI

struct CommandRow: View {
    let title: String
    let subtitle: String
    var value: String = ""
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Runner.Spacing.tight) {
                Image(systemName: systemImage)
                    .font(Runner.Typography.smallMedium)
                    .foregroundStyle(Runner.Palette.accent)
                    .frame(width: Runner.Layout.compactControlHeight - 4, height: Runner.Layout.compactControlHeight - 4)
                    .background(Runner.Palette.foreground5, in: RoundedRectangle(cornerRadius: Runner.Radius.control, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Runner.Spacing.xxsmall) {
                    Text(title)
                        .font(Runner.Typography.bodyMedium)
                        .foregroundStyle(Runner.Palette.foreground)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(Runner.Typography.caption)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                        .lineLimit(1)
                }

                Spacer(minLength: Runner.Spacing.small)

                if !value.isEmpty {
                    Text(value)
                        .font(Runner.Typography.smallMedium.monospacedDigit())
                        .foregroundStyle(Runner.Palette.foreground)
                }

                Image(systemName: "chevron.right")
                    .font(Runner.Typography.caption)
                    .foregroundStyle(Runner.Palette.mutedForeground)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Runner.Spacing.medium)
            .padding(.vertical, Runner.Spacing.snug)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if value.isEmpty {
            return "\(title), \(subtitle)"
        }
        return "\(title), \(value), \(subtitle)"
    }
}
