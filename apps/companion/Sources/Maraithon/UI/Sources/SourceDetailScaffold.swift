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
    var emptyDescription: String = "Once your first batch finishes, this view will show today's stats and your most recent sync runs."
    var clearDataDescription: String = "This will delete every record Maraithon has synced from this Mac out of the cloud. Local data on your device is not affected."

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            if let reason = needsAttentionReason {
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

    /// Minimal user-facing pane: a single status line, the total
    /// synced count, last-sync recency, and Sync now. Everything else
    /// (per-batch stats, cursor, recent activity table, raw publisher
    /// state) is debug-grade and lives in **Settings → Diagnostics**.
    private var cleanUserView: some View {
        ScrollView {
            VStack(alignment: .center, spacing: Tokens.Spacing.large) {
                SourceStatusBadge(state: liveBadgeState, variant: .prominent)
                Text(headlineCopy)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                Text(liveStatusSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    env.sources.syncNow(id: sourceID)
                } label: {
                    Label(isPaused ? "Resume sync" : "Sync now", systemImage: isPaused ? "play.fill" : "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("r", modifiers: .command)

                if isPaused {
                    Button("Pause") { env.sources.pause(id: sourceID) }
                        .buttonStyle(.bordered)
                } else {
                    Button("Pause") { env.sources.pause(id: sourceID) }
                        .buttonStyle(.bordered)
                }
            }
            .padding(Tokens.Spacing.xlarge)
            .frame(maxWidth: .infinity)
            .animation(.default, value: isPaused)
        }
        .navigationTitle(displayName)
    }

    /// Big copy line. Surfaces the total synced count when one batch
    /// has shipped; otherwise sticks to a plain status phrase.
    private var headlineCopy: String {
        let publisher = env.sources.statusPublisher(for: sourceID)
        let total = publisher?.totalAccepted ?? 0
        if isPaused {
            return "\(displayName) is paused"
        }
        if total > 0 {
            return "\(total.formatted(.number)) \(displayName) synced this session"
        }
        return "\(displayName) is up to date"
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
                // Destructive actions (clear cloud data, reset cursor)
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

                    TableColumn("Count") { row in
                        Text(String(row.count))
                            .monospacedDigit()
                    }
                    .width(min: 60, ideal: 70)

                    TableColumn("Accepted") { row in
                        Text(String(row.accepted))
                            .monospacedDigit()
                            .foregroundStyle(StatusTone.good.color)
                    }
                    .width(min: 70, ideal: 80)

                    TableColumn("Duplicates") { row in
                        Text(String(row.duplicates))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 100)
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
        if case .error(let reason) = publisher.state {
            return reason
        }
        return nil
    }

    /// Focused detail content for the `.error` state. Mirrors the
    /// unblock-view shape from `SourceUnblockView`: strip stats /
    /// controls / activity entirely, surface the action that gets the
    /// source back to green (Retry via Sync now), and show the raw
    /// error string in a copy-friendly monospaced block so the user can
    /// share it for debugging.
    private func errorView(reason: String) -> some View {
        ContentUnavailableView {
            Label("Sync error", systemImage: "xmark.octagon.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(StatusTone.error.color)
        } description: {
            VStack(alignment: .center, spacing: Tokens.Spacing.medium) {
                Text("\(displayName) ran into an error on its last sync. Most errors are transient — tap Sync now to retry. Open Logs in the sidebar for the full trace.")
                Text(reason)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Tokens.Spacing.medium)
                    .padding(.vertical, Tokens.Spacing.small)
                    .background(.secondary.opacity(0.08), in: .rect(cornerRadius: Tokens.CornerRadius.small))
                    .textSelection(.enabled)
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

    /// True when the source is configured/connected at the source layer
    /// but has never produced a successful sync. The detail pane swaps
    /// to a focused view that tells the user the one action that gets
    /// the row to green: tap Sync now. `.syncing` is excluded — the
    /// normal scaffold's animated badge already conveys "in flight."
    private var isWaitingForFirstSync: Bool {
        guard let publisher = env.sources.statusPublisher(for: sourceID) else {
            return false
        }
        if publisher.lastSyncAt != nil { return false }
        switch publisher.state {
        case .connected, .disconnected: return true
        default: return false
        }
    }

    private var waitingForFirstSyncView: some View {
        ContentUnavailableView {
            Label("Waiting for first sync", systemImage: "clock.arrow.circlepath")
                .symbolRenderingMode(.hierarchical)
        } description: {
            Text("\(displayName) is connected but hasn't completed a sync yet. Tap Sync now to fetch your first batch — otherwise Maraithon will sync on its own within a few minutes.")
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
        let displayed = publisher.state.displayed(
            lastSyncAt: publisher.lastSyncAt,
            shippedBatch: !publisher.recentBatches.isEmpty
        )
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
        // successful sync yet reads as "Waiting for first sync" — the
        // badge is muted by `displayed(...)`, the subtitle says why.
        if case .connected = publisher.state, publisher.lastSyncAt == nil {
            return "Waiting for first sync"
        }
        let prefix: String
        switch publisher.state {
        case .syncing: prefix = "Syncing now"
        case .connected: prefix = "Connected"
        case .paused: prefix = "Paused"
        case .needsAttention(let r): prefix = r
        case .disconnected: prefix = "Not yet connected"
        case .error(let r): prefix = r
        }
        if let last = publisher.lastSyncAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            let ago = formatter.localizedString(for: last, relativeTo: Date())
            return "\(prefix) — last sync \(ago)"
        }
        return prefix
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
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// Row in the recent-activity table on a detail pane.
struct SourceActivityRow: Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let count: Int
    let accepted: Int
    let duplicates: Int

    init(id: UUID = UUID(), timestamp: Date, count: Int, accepted: Int, duplicates: Int) {
        self.id = id
        self.timestamp = timestamp
        self.count = count
        self.accepted = accepted
        self.duplicates = duplicates
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
                count: event.accepted + event.duplicate,
                accepted: event.accepted,
                duplicates: event.duplicate
            )
        } ?? []
    }
}

/// Destructive confirmation sheet shared across detail panes. Mirrors
/// the iMessage Clear Cloud Data sheet, but accepts a per-source body
/// string so each pane can frame the consequence in its own language.
struct ClearCloudDataSheet: View {
    @Binding var isPresented: Bool
    let description: String
    /// Destructive action — wipes cloud data for this source.
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
                Section("Repair") {
                    Text("Drop the local sync cursor and re-pull from the source on this Mac. Cloud data is left untouched.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        onResetLocalCursor()
                        isPresented = false
                    } label: {
                        Label("Reset local cursor only", systemImage: "arrow.counterclockwise")
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
                Button("Clear cloud data") {
                    onConfirmClearCloud()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!canConfirm)
            }
        }
        .navigationTitle("Clear cloud data")
    }
}
