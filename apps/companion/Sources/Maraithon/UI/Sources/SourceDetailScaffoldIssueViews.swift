import SwiftUI

/// Focused non-healthy states for `SourceDetailScaffold`.
extension SourceDetailScaffold {
    func errorView(reason: String) -> some View {
        ContentUnavailableView {
            Label("Sync error", systemImage: "xmark.octagon.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(StatusTone.error.color)
        } description: {
            VStack(alignment: .center, spacing: Tokens.Spacing.medium) {
                Text(SourceIssueCopy.detail(reason, sourceName: displayName))
                    .font(.body)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 480)
        } actions: {
            Button {
                env.sources.syncNow(id: sourceID)
            } label: {
                Label("Check now", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .navigationTitle(displayName)
    }

    func issueView(issue: SourceStatusPublisher.IssueEvent) -> some View {
        let isError = issue.severity == .error
        let title = isError
            ? SourceDetailCopy.issueErrorTitle
            : SourceDetailCopy.issueAttentionTitle(plural: syncedItemPlural)
        let symbol = isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
        let tone = isError ? StatusTone.error : StatusTone.attention

        return ContentUnavailableView {
            Label(title, systemImage: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tone.color)
        } description: {
            VStack(alignment: .center, spacing: Tokens.Spacing.medium) {
                Text(SourceIssueCopy.issue(issue.reason, failedCount: issue.failedCount))
                Text(SourceDetailCopy.failedItemsLine(
                    issue.failedCount,
                    singular: syncedItemSingular,
                    plural: syncedItemPlural
                ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let last = publisher?.lastSyncAt {
                    Text("Last successful check: \(SourceStat.relative(last))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 480)
        } actions: {
            VStack(spacing: Tokens.Spacing.small) {
                Button {
                    env.sources.syncNow(id: sourceID)
                } label: {
                    Label("Check now", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button {
                    env.sources.resetCursor(id: sourceID)
                    env.sources.syncNow(id: sourceID)
                } label: {
                    Label(SourceDetailCopy.resetSourceButtonTitle, systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
            }
        }
        .navigationTitle(displayName)
    }

    var waitingForFirstSyncView: some View {
        ContentUnavailableView {
            Label(SourceDetailCopy.firstSyncTitle, systemImage: "clock.arrow.circlepath")
                .symbolRenderingMode(.hierarchical)
        } description: {
            Text(SourceDetailCopy.firstSyncDescription(displayName: displayName))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        } actions: {
            Button {
                env.sources.syncNow(id: sourceID)
            } label: {
                Label("Check now", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .navigationTitle(displayName)
    }
}
