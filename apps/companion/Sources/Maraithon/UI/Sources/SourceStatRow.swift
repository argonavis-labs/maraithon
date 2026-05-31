import SwiftUI

/// Compact native row for a source detail metric.
struct SourceStatRow: View {
    let stat: SourceStat

    var body: some View {
        LabeledContent {
            Text(stat.value)
                .font(.body.weight(.semibold))
                .monospacedDigit()
        } label: {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xsmall) {
                Text(stat.title)
                    .font(.body)
                if let caption = stat.caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, Tokens.Spacing.small)
        .accessibilityElement(children: .combine)
    }
}
