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
    var capabilities: [SourceCapability] = []
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
                Divider()
                capabilitiesSection
                Divider()
                privacySection
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
                Label(
                    isPaused ? SourceDetailCopy.resumeUpdatesButtonTitle : SourceDetailCopy.checkNowButtonTitle,
                    systemImage: isPaused ? "play.fill" : "arrow.clockwise"
                )
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("r", modifiers: .command)

            if !isPaused {
                Button {
                    env.sources.pause(id: sourceID)
                } label: {
                    Label(SourceDetailCopy.pauseUpdatesButtonTitle, systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
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
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            SectionHeader(SourceDetailCopy.capabilitiesSectionTitle)
            VStack(alignment: .leading, spacing: Tokens.Spacing.medium) {
                ForEach(capabilityItems) { capability in
                    SourceCapabilityRow(capability: capability)
                }
            }
        }
    }

    var privacyItems: [SourceCapability] {
        SourceDetailCopy.privacyNotes(for: sourceID, displayName: displayName)
    }

    var privacySection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            SectionHeader(SourceDetailCopy.privacySectionTitle)
            VStack(alignment: .leading, spacing: Tokens.Spacing.medium) {
                ForEach(privacyItems) { item in
                    SourceCapabilityRow(capability: item)
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
            return "\(displayName) needs attention"
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
                    SourceDetailCopy.recentChecksEmptyTitle,
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

                    TableColumn("Added") { row in
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
