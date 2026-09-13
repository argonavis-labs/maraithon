import SwiftUI

/// Key/value card row: muted 13pt label (with an optional 11pt caption
/// beneath it) on the left, a tabular-digit 13pt value on the right.
struct RunnerKeyValueRow: View {
    let label: String
    var caption: String? = nil
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.medium) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxsmall) {
                Text(label)
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.mutedForeground)
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.mutedForeground)
                }
            }
            Spacer(minLength: Tokens.Spacing.medium)
            Text(value)
                .font(Tokens.Typography.body)
                .monospacedDigit()
                .foregroundStyle(Tokens.Palette.foreground)
                .multilineTextAlignment(.trailing)
        }
        .runnerCardRow()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)\(caption.map { ". \($0)" } ?? "")")
    }
}
