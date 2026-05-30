import SwiftUI

/// Shared scaffolding used by every per-source detail pane.
///
/// The healthy state is intentionally operational: current health,
/// user-facing activity numbers, and recent checks. Permission and
/// failure states swap to focused unblock views so green sources do not
/// share space with setup copy.
struct SourceDetailScaffold: View {
    let sourceID: String
    let displayName: String
    let stats: [SourceStat]
    let activity: [SourceActivityRow]
    var syncedItemSingular: String = "item"
    var syncedItemPlural: String = "items"
    var emptyDescription: String = "After the first check, this view shows recent activity and recent checks."

    @Environment(AppEnvironment.self) var env

    var body: some View {
        Group {
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
    }

    /// Healthy detail pane. Shows the useful operational facts a user
    /// needs when a source is green.
    var cleanUserView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xlarge) {
                overviewSection
                Divider()
                statsSection
                Divider()
                activitySection
            }
            .padding(Tokens.Spacing.xlarge)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .animation(.default, value: isPaused)
        }
        .navigationTitle(displayName)
    }

    var overviewSection: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.large) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
                SourceStatusBadge(state: liveBadgeState, variant: .prominent)
                Text(headlineCopy)
                    .font(.title2.weight(.semibold))
                Text(summaryCopy)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Tokens.Spacing.large)

            actionButtons
        }
    }

    var actionButtons: some View {
        HStack(spacing: Tokens.Spacing.small) {
            Button {
                if isPaused {
                    env.sources.resume(id: sourceID)
                } else {
                    env.sources.syncNow(id: sourceID)
                }
            } label: {
                Label(isPaused ? "Resume sync" : "Sync now", systemImage: isPaused ? "play.fill" : "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("r", modifiers: .command)

            if !isPaused {
                Button {
                    env.sources.pause(id: sourceID)
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    var headlineCopy: String {
        if isPaused {
            return "\(displayName) sync is paused"
        }

        guard let publisher else {
            return "\(displayName) is not connected"
        }

        switch publisher.displayedState() {
        case .syncing:
            return "Checking \(displayName)"
        case .connected:
            return SourceDetailCopy.healthyHeadline(
                totalSynced: publisher.totalAccepted,
                singular: syncedItemSingular,
                plural: syncedItemPlural
            )
        case .paused:
            return "\(displayName) sync is paused"
        case .needsAttention:
            return "\(displayName) needs attention"
        case .error:
            return "\(displayName) could not sync"
        case .disconnected:
            return "\(displayName) is not syncing"
        }
    }

    var summaryCopy: String {
        guard let publisher else {
            return "Open Maraithon from this Mac to start syncing \(syncedItemPlural)."
        }

        if isPaused {
            return "Resume sync when you want \(displayName) to update again."
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

    var statsSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            SectionHeader(SourceDetailCopy.activitySectionTitle)
            let columns = [GridItem(.adaptive(minimum: 160), spacing: Tokens.Spacing.medium)]
            LazyVGrid(columns: columns, spacing: Tokens.Spacing.medium) {
                ForEach(stats) { stat in
                    StatCard(title: stat.title, value: stat.value, caption: stat.caption)
                }
            }
        }
    }

    var activitySection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            SectionHeader(SourceDetailCopy.recentChecksSectionTitle)
            if activity.isEmpty {
                ContentUnavailableView(
                    "No checks yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(emptyDescription)
                )
                .frame(minHeight: 200)
            } else {
                Table(activity.sorted { $0.timestamp > $1.timestamp }) {
                    TableColumn("Time") { row in
                        Text(row.timestamp, format: .dateTime.hour().minute().second())
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 90, ideal: 110)

                    TableColumn("Found") { row in
                        Text(String(row.count))
                            .monospacedDigit()
                    }
                    .width(min: 60, ideal: 70)

                    TableColumn("Synced") { row in
                        Text(String(row.accepted))
                            .monospacedDigit()
                            .foregroundStyle(StatusTone.good.color)
                    }
                    .width(min: 70, ideal: 80)

                    TableColumn(SourceDetailCopy.alreadySyncedTitle) { row in
                        Text(String(row.duplicates))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn(SourceDetailCopy.notSyncedTitle) { row in
                        Text(String(row.failed))
                            .monospacedDigit()
                            .foregroundStyle(row.failed > 0 ? StatusTone.error.color : StatusTone.muted.color)
                    }
                    .width(min: 60, ideal: 70)
                }
                .frame(minHeight: 240)
            }
        }
    }
}
