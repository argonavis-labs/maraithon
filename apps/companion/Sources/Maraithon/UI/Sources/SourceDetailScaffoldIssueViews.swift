import SwiftUI

/// Focused non-healthy bodies for `SourceDetailScaffold`: each is one
/// `SourceIssueCard` under the shared page header.
extension SourceDetailScaffold {
    func errorView(reason: String) -> some View {
        SourceIssueCard(
            dotColor: Tokens.Palette.destructive,
            title: SourceDetailCopy.issueErrorTitle,
            message: SourceIssueCopy.detail(reason, sourceName: displayName)
        ) {
            checkNowButton
        }
    }

    func issueView(issue: SourceStatusPublisher.IssueEvent) -> some View {
        let isError = issue.severity == .error
        let title = isError
            ? SourceDetailCopy.issueErrorTitle
            : SourceDetailCopy.issueAttentionTitle(plural: syncedItemPlural)

        var notes = [
            SourceDetailCopy.failedItemsLine(
                issue.failedCount,
                singular: syncedItemSingular,
                plural: syncedItemPlural
            )
        ]
        if let last = publisher?.lastSyncAt {
            notes.append(SourceDetailCopy.lastSuccessfulCheckLine(last))
        }

        return SourceIssueCard(
            dotColor: isError ? Tokens.Palette.destructive : Tokens.Palette.caution,
            title: title,
            message: SourceIssueCopy.issue(issue.reason, failedCount: issue.failedCount),
            notes: notes
        ) {
            checkNowButton

            Button {
                env.sources.resetCursor(id: sourceID)
                env.sources.syncNow(id: sourceID)
            } label: {
                HStack(spacing: Tokens.Spacing.compact) {
                    Image(systemName: "arrow.counterclockwise")
                        .accessibilityHidden(true)
                    Text(SourceDetailCopy.resetSourceButtonTitle)
                }
            }
            .buttonStyle(RunnerButtonStyle(.secondary))
        }
    }

    var waitingForFirstSyncView: some View {
        SourceIssueCard(
            dotColor: Tokens.Palette.info,
            title: SourceDetailCopy.firstSyncTitle,
            message: SourceDetailCopy.firstSyncDescription(displayName: displayName)
        ) {
            checkNowButton
        }
    }

    /// Primary "Check now" button shared by the issue cards; Return
    /// triggers it because it is the only sensible next step.
    private var checkNowButton: some View {
        Button {
            env.sources.syncNow(id: sourceID)
        } label: {
            HStack(spacing: Tokens.Spacing.compact) {
                Image(systemName: "arrow.clockwise")
                    .accessibilityHidden(true)
                Text(SourceDetailCopy.checkNowButtonTitle)
            }
        }
        .buttonStyle(RunnerButtonStyle(.primary))
        .keyboardShortcut(.defaultAction)
    }
}
