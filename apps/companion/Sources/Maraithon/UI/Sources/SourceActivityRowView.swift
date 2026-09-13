import SwiftUI

/// Card row for one check in the check-history section: how many items
/// were added, the found / already known / needs-another-check detail,
/// and the check time at the right.
struct SourceActivityRowView: View {
    let row: SourceActivityRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.medium) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxsmall) {
                Text(SourceDetailCopy.checkHistoryTitle(added: row.accepted))
                    .font(Tokens.Typography.body)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Palette.foreground)
                Text(SourceDetailCopy.checkHistoryDetail(
                    found: row.count,
                    alreadyKnown: row.duplicates,
                    needAnotherCheck: row.failed
                ))
                .font(Tokens.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(row.failed > 0 ? Tokens.Palette.destructiveText : Tokens.Palette.mutedForeground)
            }
            Spacer(minLength: Tokens.Spacing.medium)
            Text(row.timestamp, format: .dateTime.hour().minute().second())
                .font(Tokens.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(Tokens.Palette.mutedForeground)
                .frame(width: Tokens.SourcesLayout.activityTimeColumnWidth, alignment: .trailing)
        }
        .runnerCardRow()
        .accessibilityElement(children: .combine)
    }
}
