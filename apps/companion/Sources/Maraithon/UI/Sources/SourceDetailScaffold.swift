import SwiftUI

/// Shared scaffolding used by every per-source detail pane (Notes, Voice
/// Memos, Reminders, Calendar, Files, Browser History). Composes the
/// four canonical sections IMessageDetailView introduced — status card,
/// stats grid, controls row, and recent activity table — driven off the
/// real `SourceStatusPublisher` so the syncing animation tracks live
/// source state.
///
/// Invariants:
/// - All chrome-free per AGENTS.md (no bordered cards, no shadows).
/// - Per-source state lives in `stats` / `activity`; the scaffold owns
///   no source-specific knowledge.
/// - The Pause/Resume button toggles via `SourceRegistry.pause(id:)` /
///   `.resume(id:)` so the source's own polling loop honors it.
struct SourceDetailScaffold: View {
    let sourceID: String
    let displayName: String
    let stats: [SourceStat]
    let activity: [SourceActivityRow]
    var syncedItemSingular: String = "item"
    var syncedItemPlural: String = "items"
    var emptyDescription: String = "After the first sync, this view shows recent activity and sync history."
    var clearDataDescription: String = "This deletes every record synced from this Mac from Maraithon's synced copy. Local data on your device is not affected."

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            if let issue = activeIssue {
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
    /// needs when a source is green: current state, last successful sync,
    /// recent totals, last-check counts, and the recent activity rows.
    private var cleanUserView: some View {
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

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.medium) {
            HStack(alignment: .top, spacing: Tokens.Spacing.medium) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
                    Text(headlineCopy)
                        .font(.title2.weight(.semibold))
                    Text(summaryCopy)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SourceStatusBadge(state: liveBadgeState, variant: .prominent)
                }

                Spacer(minLength: Tokens.Spacing.large)

                actionButtons
            }
        }
    }

    private var actionButtons: some View {
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

    /// Primary healthy-state outcome. Counts live in the stats and
    /// summary line so the title can answer whether the source is OK.
    private var headlineCopy: String {
        if isPaused {
            return "\(displayName) sync is paused"
        }

        guard let publisher = env.sources.statusPublisher(for: sourceID) else {
            return "\(displayName) is not connected"
        }

        switch publisher.displayedState() {
        case .syncing:
            return "Checking \(displayName)"
        case .connected:
            return "\(displayName) is up to date"
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

    private var summaryCopy: String {
        guard let publisher = env.sources.statusPublisher(for: sourceID) else {
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

    // MARK: Sections

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            SectionHeader("Status")
            SourceStatusBadge(state: liveBadgeState, variant: .prominent)
            Text(liveStatusSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel(liveStatusSubtitle)
        }
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            SectionHeader("Stats")
            let columns = [GridItem(.adaptive(minimum: 160), spacing: Tokens.Spacing.medium)]
            LazyVGrid(columns: columns, spacing: Tokens.Spacing.medium) {
                ForEach(stats) { stat in
                    StatCard(title: stat.title, value: stat.value, caption: stat.caption)
                }
            }
        }
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            SectionHeader("Controls")
            HStack(spacing: Tokens.Spacing.small) {
                Button {
                    if isPaused {
                        env.sources.resume(id: sourceID)
                    } else {
                        env.sources.pause(id: sourceID)
                    }
                } label: {
                    Label(isPaused ? "Resume" : "Pause",
                          systemImage: isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(isPaused ? "Resume \(displayName) sync" : "Pause \(displayName) sync")

                Button {
                    env.sources.syncNow(id: sourceID)
                } label: {
                    Label("Sync now", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(isPaused)

                Spacer()
                // Destructive data deletion and local re-sync actions
                // live in Settings → Data, not on the per-source detail
                // pane — keeps the wipe-everything affordance in one
                // place and removes the "did I just clear the right
                // source?" footgun.
            }
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            SectionHeader("Recent activity")
            if activity.isEmpty {
                ContentUnavailableView(
                    "Nothing yet",
                    systemImage: "tray",
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

                    TableColumn("Checked") { row in
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

                    TableColumn("Already synced") { row in
                        Text(String(row.duplicates))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Not synced") { row in
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

    // MARK: Derived state

    private var isPaused: Bool {
        guard let publisher = env.sources.statusPublisher(for: sourceID) else {
            return false
        }
        if case .paused = publisher.state { return true }
        return false
    }

    /// Surfaces the publisher's `.needsAttention(reason:)` value (if
    /// any) so the body can swap to the focused unblock view. Returns
    /// `nil` when the source is in any other state.
    private var needsAttentionReason: String? {
        guard let publisher = env.sources.statusPublisher(for: sourceID) else {
            return nil
        }
        if case .needsAttention(let reason) = publisher.state {
            return reason
        }
        return nil
    }

    /// Surfaces the publisher's `.error(reason:)` value so the body can
    /// swap to a focused error view with Retry. Returns `nil` when the
    /// source is in any other state.
    private var errorReason: String? {
        guard let publisher = env.sources.statusPublisher(for: sourceID) else {
            return nil
        }
        if case .error(let reason) = publisher.displayedState() {
            return reason
        }
        return nil
    }

    private var activeIssue: SourceStatusPublisher.IssueEvent? {
        env.sources.statusPublisher(for: sourceID)?.activeIssue
    }

    /// Focused detail content for the `.error` state. Mirrors the
    /// unblock-view shape from `SourceUnblockView`: strip stats /
    /// controls / activity entirely, surface the action that gets the
    /// source back to green (Retry via Sync now) without exposing raw
    /// error dumps in the product UI.
    private func errorView(reason: String) -> some View {
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
                Label("Sync now", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .navigationTitle(displayName)
    }

    private func issueView(issue: SourceStatusPublisher.IssueEvent) -> some View {
        let isError = issue.severity == .error
        let title = isError ? "Sync is failing" : "Some items need attention"
        let symbol = isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
        let tone = isError ? StatusTone.error : StatusTone.attention
        return ContentUnavailableView {
            Label(title, systemImage: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tone.color)
        } description: {
            VStack(alignment: .center, spacing: Tokens.Spacing.medium) {
                Text(SourceIssueCopy.issue(issue.reason, failedCount: issue.failedCount))
                Text(issue.failedCount == 1 ? "1 item did not finish syncing." : "\(issue.failedCount.formatted(.number)) items did not finish syncing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let last = env.sources.statusPublisher(for: sourceID)?.lastSyncAt {
                    Text("Last successful sync: \(SourceStat.relative(last))")
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
                    Label("Sync now", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button {
                    env.sources.resetCursor(id: sourceID)
                    env.sources.syncNow(id: sourceID)
                } label: {
                    Label("Start this source over", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
            }
        }
        .navigationTitle(displayName)
    }

    /// True when the source is connected at the source layer but has
    /// never produced a successful sync. Disconnected sources must not
    /// enter this state: telling the user a source is "connected" while
    /// it is not syncing breaks trust in the setup flow.
    private var isWaitingForFirstSync: Bool {
        guard let publisher = env.sources.statusPublisher(for: sourceID) else {
            return false
        }
        return SourceDetailCopy.isWaitingForFirstSync(
            state: publisher.state,
            lastSyncAt: publisher.lastSyncAt
        )
    }

    private var waitingForFirstSyncView: some View {
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
                Label("Sync now", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .navigationTitle(displayName)
    }

    private var liveBadgeState: SourceStatusBadge.State {
        guard let publisher = env.sources.statusPublisher(for: sourceID) else {
            return .disconnected
        }
        let displayed = publisher.displayedState()
        switch displayed {
        case .connected: return .connected
        case .syncing: return .syncing
        case .paused: return .paused
        case .disconnected: return .disconnected
        case .needsAttention(let reason): return .needsAttention(reason)
        case .error(let reason): return .error(reason)
        }
    }

    private var liveStatusSubtitle: String {
        guard let publisher = env.sources.statusPublisher(for: sourceID) else {
            return "Not yet connected"
        }
        // A source that's connected at the source layer but has no
        // successful sync yet reads as ready for first sync; the badge
        // is muted by `displayed(...)`, the subtitle says why.
        if case .connected = publisher.state, publisher.lastSyncAt == nil {
            return SourceDetailCopy.firstSyncTitle
        }
        let prefix: String
        switch publisher.displayedState() {
        case .syncing: prefix = "Syncing now"
        case .connected: prefix = "Connected"
        case .paused: prefix = "Paused"
        case .needsAttention(let r): prefix = SourceIssueCopy.status(r)
        case .disconnected: prefix = "Not yet connected"
        case .error(let r): prefix = SourceIssueCopy.status(r)
        }
        if let last = publisher.lastSyncAt {
            return "\(prefix) — last sync \(SourceDetailCopy.relativeSyncTime(last))"
        }
        return prefix
    }
}

/// Product copy shared by per-source detail panes. Keeps user-facing
/// source metrics in outcome language instead of sync-engine vocabulary
/// like "accepted" or "duplicates."
enum SourceDetailCopy {
    static let lastCheckTitle = "Last check"
    static let lastBatchSyncedCaption = "synced"
    static let alreadySyncedTitle = "Already synced"
    static let alreadySyncedCaption = "last check"
    static let notSyncedTitle = "Not synced"
    static let notSyncedCaption = "last check"
    static let lastSyncTitle = "Last sync"
    static let lastSyncCaption = "successful check"
    static let firstSyncTitle = "Ready for first sync"

    static func syncedHeadline(total: Int, singular: String, plural: String) -> String {
        "\(total.formatted(.number)) \(itemNoun(total: total, singular: singular, plural: plural)) synced"
    }

    static func itemNoun(total: Int, singular: String, plural: String) -> String {
        total == 1 ? singular : plural
    }

    static func countedItem(_ count: Int, singular: String, plural: String) -> String {
        "\(count.formatted(.number)) \(itemNoun(total: count, singular: singular, plural: plural))"
    }

    static func connectedSummary(
        displayName: String,
        totalSynced: Int,
        lastCheckSynced: Int,
        lastCheckAlreadySynced: Int,
        lastCheckNotSynced: Int,
        lastSyncAt: Date?,
        singular: String,
        plural: String,
        relativeTo now: Date = Date()
    ) -> String {
        guard let lastSyncAt else {
            if totalSynced > 0 {
                return "\(syncedHeadline(total: totalSynced, singular: singular, plural: plural)) so far. Sync now to check \(displayName) again."
            }
            return "Sync now to start checking \(displayName)."
        }

        var sentences: [String] = []
        let hasUnfinishedItems = lastCheckNotSynced > 0
        if lastCheckSynced > 0 {
            sentences.append("Synced \(countedItem(lastCheckSynced, singular: singular, plural: plural)).")
            if !hasUnfinishedItems {
                sentences.append("Everything is current.")
            }
        } else if lastCheckAlreadySynced > 0 || totalSynced > 0 {
            sentences.append("No new \(plural) found.")
            if !hasUnfinishedItems {
                sentences.append("Everything is current.")
            }
        } else {
            sentences.append("No \(plural) found yet.")
        }

        if hasUnfinishedItems {
            let verb = lastCheckNotSynced == 1 ? "needs" : "need"
            sentences.append("\(countedItem(lastCheckNotSynced, singular: singular, plural: plural)) \(verb) attention.")
        } else {
            sentences.append("Automatic checks are on.")
        }

        sentences.append("Last sync \(relativeSyncTime(lastSyncAt, relativeTo: now)).")
        return sentences.joined(separator: " ")
    }

    static func firstSyncDescription(displayName: String) -> String {
        "Maraithon is ready to sync \(displayName), but the first check has not finished yet. Sync now starts it immediately; otherwise it will begin automatically within a few minutes."
    }

    static func isWaitingForFirstSync(state: SourceState, lastSyncAt: Date?) -> Bool {
        guard lastSyncAt == nil else { return false }
        if case .connected = state {
            return true
        }
        return false
    }

    static func relativeSyncTime(_ date: Date, relativeTo now: Date = Date()) -> String {
        let distance = date.timeIntervalSince(now)
        if abs(distance) < 60 {
            return "just now"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// Single stat tile shown in a detail pane's stats grid.
struct SourceStat: Identifiable, Hashable {
    let id: String
    let title: String
    let value: String
    var caption: String? = nil

    init(id: String, title: String, value: String, caption: String? = nil) {
        self.id = id
        self.title = title
        self.value = value
        self.caption = caption
    }

    /// Format an integer counter from the publisher with a "—"
    /// placeholder when the value isn't available yet.
    static func format(_ n: Int?) -> String {
        guard let n else { return "—" }
        return n.formatted()
    }

    /// Short relative date string from a publisher's `lastSyncAt`. Returns
    /// "—" when the source hasn't completed a sync yet.
    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        return SourceDetailCopy.relativeSyncTime(date)
    }
}

/// Row in the recent-activity table on a detail pane.
struct SourceActivityRow: Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let count: Int
    let accepted: Int
    let duplicates: Int
    let failed: Int

    init(id: UUID = UUID(), timestamp: Date, count: Int, accepted: Int, duplicates: Int, failed: Int = 0) {
        self.id = id
        self.timestamp = timestamp
        self.count = count
        self.accepted = accepted
        self.duplicates = duplicates
        self.failed = failed
    }

    /// Build a recent-activity list from a publisher's ring buffer,
    /// newest first, capped at `limit` rows. Returns `[]` when the
    /// publisher isn't installed.
    @MainActor
    static func recent(from publisher: SourceStatusPublisher?, limit: Int = 10) -> [SourceActivityRow] {
        publisher?.recentBatches.prefix(limit).map { event in
            SourceActivityRow(
                id: event.id,
                timestamp: event.timestamp,
                count: event.accepted + event.duplicate + event.failed,
                accepted: event.accepted,
                duplicates: event.duplicate,
                failed: event.failed
            )
        } ?? []
    }
}

/// Destructive confirmation sheet shared across data-management panes.
/// Accepts a per-source body string so each pane can frame the
/// consequence in its own language.
struct ClearCloudDataSheet: View {
    @Binding var isPresented: Bool
    let description: String
    /// Destructive action — deletes synced data for this source.
    var onConfirmClearCloud: () -> Void
    /// Non-destructive action — drops the local cursor and lets the next
    /// polling tick repopulate. `nil` hides the section (e.g., used by
    /// previews or tests that only want to assert the destructive flow).
    var onResetLocalCursor: (() -> Void)? = nil

    @State private var typed: String = ""

    private var canConfirm: Bool {
        typed.lowercased() == "delete"
    }

    var body: some View {
        Form {
            Section {
                Label("This cannot be undone", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(StatusTone.attention.color)
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Confirm") {
                TextField("Type \"delete\" to confirm", text: $typed)
                    .textFieldStyle(.roundedBorder)
            }
            if let onResetLocalCursor {
                Section("Re-sync Source") {
                    Text("Re-sync this source from this Mac. Maraithon's synced copy is left untouched.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        onResetLocalCursor()
                        isPresented = false
                    } label: {
                        Label("Re-sync this source", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 360, minHeight: 320)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { isPresented = false }
            }
            ToolbarItem(placement: .destructiveAction) {
                Button("Delete synced data") {
                    onConfirmClearCloud()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!canConfirm)
            }
        }
        .navigationTitle("Delete synced data")
    }
}
