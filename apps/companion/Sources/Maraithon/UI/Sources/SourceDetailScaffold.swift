import SwiftUI

/// Shared page used by every per-source detail pane, styled like the
/// Electron "Mac sources" page: eyebrow, source title, summary subtitle,
/// header actions, then hairline-card sections.
///
/// The healthy state is intentionally operational: current status,
/// what the assistant can use, available context, and check history.
/// Permission and failure states keep the same header and swap the body
/// for a single focused card so green sources never share space with
/// setup copy.
struct SourceDetailScaffold: View {
    let sourceID: String
    let displayName: String
    let stats: [SourceStat]
    let activity: [SourceActivityRow]
    var capabilities: [SourceCapability] = []
    var syncedItemSingular: String = "item"
    var syncedItemPlural: String = "items"
    var emptyDescription: String = "After the first check, this view shows recent activity and recent checks."
    /// Optional source-specific section (e.g. the Files folder picker),
    /// rendered between capabilities and stats on the healthy view. The
    /// provider wraps it in a `RunnerSection`.
    var extraSection: AnyView?

    @Environment(AppEnvironment.self) var env

    var body: some View {
        RunnerPage {
            RunnerPageHeader(
                eyebrow: SourceDetailCopy.sourcesEyebrow,
                title: displayName,
                subtitle: isHealthyView ? summaryCopy : headlineCopy
            ) {
                if isHealthyView {
                    SourceDetailActions(sourceID: sourceID, isPaused: isPaused)
                }
            }
            .padding(.bottom, Tokens.Spacing.large)

            content
        }
    }

    /// True when the page shows the operational sections rather than a
    /// single issue card.
    private var isHealthyView: Bool {
        blockingIssue == nil && needsAttentionReason == nil && errorReason == nil && !isWaitingForFirstSync
    }

    @ViewBuilder
    private var content: some View {
        if let issue = blockingIssue {
            issueView(issue: issue)
        } else if let reason = needsAttentionReason {
            SourceUnblockView(
                sourceID: sourceID,
                displayName: displayName,
                hint: SourcePermissionHint.forReason(reason)
            )
        } else if let reason = errorReason {
            errorView(reason: reason)
        } else if isWaitingForFirstSync {
            waitingForFirstSyncView
        } else {
            cleanUserView
        }
    }

    /// Healthy detail body. Shows the useful operational facts a user
    /// needs when a source is green.
    var cleanUserView: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusSection
            capabilitiesSection
            if let extraSection {
                extraSection
            }
            statsSection
            activitySection
            privacySection
        }
        .animation(.default, value: isPaused)
    }

    var statusSection: some View {
        RunnerSection(title: SourceDetailCopy.statusSectionTitle) {
            RunnerCard {
                SourceStatusBadge(state: liveBadgeState, variant: .prominent, detail: headlineCopy)
                    .runnerCardRow()
            }
        }
    }

    var capabilityItems: [SourceCapability] {
        if capabilities.isEmpty {
            return SourceDetailCopy.capabilities(for: sourceID, displayName: displayName)
        }
        return capabilities
    }

    var capabilitiesSection: some View {
        RunnerSection(title: SourceDetailCopy.capabilitiesSectionTitle) {
            RunnerCardRows(data: capabilityItems) { capability in
                SourceCapabilityRow(capability: capability)
            }
        }
    }

    var privacyItems: [SourceCapability] {
        SourceDetailCopy.privacyNotes(for: sourceID, displayName: displayName)
    }

    var privacySection: some View {
        RunnerSection(title: SourceDetailCopy.privacySectionTitle) {
            RunnerCardRows(data: privacyItems) { item in
                SourceCapabilityRow(capability: item)
            }
        }
    }

    var statsSection: some View {
        RunnerSection(title: SourceDetailCopy.activitySectionTitle) {
            RunnerCardRows(data: stats) { stat in
                SourceStatRow(stat: stat)
            }
        }
    }

    var activitySection: some View {
        RunnerSection(title: SourceDetailCopy.recentChecksSectionTitle) {
            if activity.isEmpty {
                RunnerCard {
                    RunnerEmptyState(
                        title: SourceDetailCopy.recentChecksEmptyTitle,
                        description: emptyDescription
                    )
                }
            } else {
                RunnerCardRows(data: activity.sorted { $0.timestamp > $1.timestamp }) { row in
                    SourceActivityRowView(row: row)
                }
            }
        }
    }

    var headlineCopy: String {
        if isPaused {
            return SourceDetailCopy.pausedHeadline(displayName: displayName)
        }

        guard let publisher else {
            return SourceDetailCopy.disconnectedHeadline(displayName: displayName)
        }

        switch publisher.displayedState() {
        case .syncing:
            return "Checking \(displayName)"
        case .connected:
            return SourceDetailCopy.healthyHeadline(
                displayName: displayName,
                totalSynced: publisher.totalAccepted,
                singular: syncedItemSingular,
                plural: syncedItemPlural
            )
        case .paused:
            return SourceDetailCopy.pausedHeadline(displayName: displayName)
        case .needsAttention:
            return "\(displayName) needs review"
        case .error:
            return SourceDetailCopy.errorHeadline(displayName: displayName)
        case .disconnected:
            return SourceDetailCopy.disconnectedHeadline(displayName: displayName)
        }
    }

    var summaryCopy: String {
        guard let publisher else {
            return SourceDetailCopy.unavailablePublisherSummary(displayName: displayName)
        }

        if isPaused {
            return SourceDetailCopy.pausedSummary(displayName: displayName, plural: syncedItemPlural)
        }

        return SourceDetailCopy.connectedSummary(
            displayName: displayName,
            totalSynced: publisher.totalAccepted,
            lastCheckSynced: publisher.lastBatchAccepted,
            lastCheckAlreadySynced: publisher.lastBatchDuplicate,
            lastCheckNotSynced: publisher.lastBatchFailed,
            lastSyncAt: publisher.lastSyncAt,
            singular: syncedItemSingular,
            plural: syncedItemPlural
        )
    }
}
