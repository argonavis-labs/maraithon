import SwiftUI

/// Sidebar listing the user's account, the available sources, and the
/// Recall, source status, and developer tools. Polished to match the
/// macOS sidebar idiom (`Section` headers, secondary metadata text,
/// compact status badge per source).
///
/// Keep `SidebarItem` and `RootWindow.detailView` in sync when adding
/// top-level destinations.
struct SidebarView: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var selection: SidebarItem?
    /// Developer-only surfaces (Logs pane, Settings → Diagnostics tab)
    /// are gated on this flag. Toggle in Settings → General →
    /// Developer mode. Defaults off so the day-to-day sidebar stays
    /// clean for non-debug use.
    @AppStorage("developer_mode") private var developerMode: Bool = false

    var body: some View {
        List(selection: $selection) {
            accountSection

            Section("Assistant") {
                Label("Recall", systemImage: "magnifyingglass")
                    .tag(SidebarItem.recall)
            }

            Section("Sources") {
                ForEach(env.sources.sources) { source in
                    SourceRow(source: source)
                        .tag(SidebarItem.source(id: source.id))
                }
            }

            if developerMode {
                Section("Developer") {
                    Label("Logs", systemImage: "list.bullet.rectangle")
                        .tag(SidebarItem.logs)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Maraithon")
        .frame(minWidth: 200, idealWidth: 240)
    }

    @ViewBuilder
    private var accountSection: some View {
        if case .signedIn(let account) = env.deviceAuth.state {
            Section("Account") {
                AccountRow(account: account)
            }
        }
    }
}

private struct AccountRow: View {
    let account: DeviceAuth.Account

    var body: some View {
        HStack(spacing: Tokens.Spacing.small) {
            Image(systemName: "person.crop.circle.fill")
                .foregroundStyle(.tint)
                .frame(width: Tokens.IconSize.regular)
            VStack(alignment: .leading, spacing: 0) {
                Text(account.email)
                    .font(.callout)
                Text(account.deviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

struct SourceRow: View {
    @Environment(AppEnvironment.self) private var env
    let source: SourceDescriptor

    var body: some View {
        let publisher = env.sources.statusPublisher(for: source.id)
        let liveState = publisher?.state ?? source.state
        let displayedState = publisher?.displayedState()
            ?? liveState.displayed(lastSyncAt: nil, shippedBatch: false)
        HStack(spacing: Tokens.Spacing.small) {
            Image(systemName: source.symbol)
                .foregroundStyle(.secondary)
                .frame(width: Tokens.IconSize.inline)
            Text(source.displayName)
            Spacer()
            if source.comingSoon {
                Text(SourceAvailabilityCopy.unavailableBadge)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Tokens.Spacing.small)
                    .padding(.vertical, Tokens.Spacing.xsmall / 2)
                    .background(.secondary.opacity(0.12), in: .capsule)
            } else {
                SourceStatusBadge(state: badgeState(for: displayedState))
                SourceRecencyChip(
                    rawState: liveState,
                    displayedState: displayedState,
                    lastSyncAt: publisher?.lastSyncAt
                )
            }
        }
        .foregroundStyle(source.comingSoon ? .secondary : .primary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            SourceRowCopy.accessibilityLabel(
                sourceName: source.displayName,
                comingSoon: source.comingSoon,
                rawState: liveState,
                displayedState: displayedState,
                lastSyncAt: publisher?.lastSyncAt
            )
        )
        .help(
            SourceRowCopy.tooltip(
                comingSoon: source.comingSoon,
                state: liveState,
                activeIssueReason: publisher?.activeIssue?.reason,
                lastSyncAt: publisher?.lastSyncAt
            )
        )
    }

    private func badgeState(for state: SourceState) -> SourceStatusBadge.State {
        switch state {
        case .disconnected: return .disconnected
        case .connected: return .connected
        case .syncing: return .syncing
        case .paused: return .paused
        case .needsAttention(let reason): return .needsAttention(reason)
        case .error(let reason): return .error(reason)
        }
    }

}

struct SourceRowCopy {
    static func accessibilityLabel(
        sourceName: String,
        comingSoon: Bool,
        rawState: SourceState,
        displayedState: SourceState,
        lastSyncAt: Date?,
        now: Date = Date()
    ) -> String {
        if comingSoon {
            return "\(sourceName), \(SourceAvailabilityCopy.unavailableAccessibilityState)"
        }

        // A source that's connected at the source layer but has no
        // successful check yet reads as waiting for the first check so
        // VoiceOver doesn't say "disconnected" when the user just hasn't
        // had a first batch land yet.
        if case .connected = rawState, lastSyncAt == nil {
            return "\(sourceName), waiting for first check"
        }

        let stateWord = statePhrase(displayedState)
        switch displayedState {
        case .needsAttention, .error:
            return "\(sourceName), \(stateWord)"
        default:
            if let last = lastSyncAt {
                let abbrev = SourceRecencyChip.format(interval: now.timeIntervalSince(last))
                let recency = abbrev == "now" ? "just now" : "\(abbrev) ago"
                return "\(sourceName), \(stateWord), last checked \(recency)"
            }
            return "\(sourceName), \(stateWord), waiting for first check"
        }
    }

    static func tooltip(
        comingSoon: Bool,
        state: SourceState,
        activeIssueReason: String?,
        lastSyncAt: Date?,
        now: Date = Date()
    ) -> String {
        if comingSoon {
            return SourceAvailabilityCopy.unavailableTitle
        }
        if let reason = activeIssueReason {
            return SourceIssueCopy.status(reason)
        }
        if case .needsAttention(let reason) = state {
            return SourceIssueCopy.status(reason)
        }
        if case .error(let reason) = state {
            return SourceIssueCopy.status(reason)
        }
        guard let last = lastSyncAt else { return SourceDetailCopy.recentChecksEmptyTitle }
        return "Last checked \(SourceDetailCopy.relativeSyncTime(last, relativeTo: now))"
    }

    static func trailingStatus(
        rawState: SourceState,
        displayedState: SourceState,
        lastSyncAt: Date?,
        now: Date = Date()
    ) -> String {
        switch displayedState {
        case .connected:
            guard let last = lastSyncAt else { return "Ready" }
            return SourceRecencyChip.format(interval: now.timeIntervalSince(last))
        case .syncing:
            return "Checking"
        case .paused:
            return "Paused"
        case .disconnected:
            if case .connected = rawState {
                return "Waiting"
            }
            return "Set up"
        case .needsAttention, .error:
            return "Review"
        }
    }

    static func trailingStatusIsRecency(_ status: String) -> Bool {
        status == "now" || status.first?.isNumber == true
    }

    private static func statePhrase(_ state: SourceState) -> String {
        switch state {
        case .connected: return "assistant ready"
        case .syncing: return "checking"
        case .paused: return "paused"
        case .disconnected: return "not updating"
        case .needsAttention(let reason):
            return "needs review, \(SourceIssueCopy.status(reason))"
        case .error(let reason):
            return "needs review, \(SourceIssueCopy.status(reason))"
        }
    }
}

/// Trailing per-row chip that shows either the abbreviated time since a
/// healthy source's last successful sync (`now`, `2m`, `3hr`, `1d`,
/// `2w`) or a short action/status label for sources that need work.
/// Uses `TimelineView` so the label refreshes on its own without
/// needing the publisher to fire.
struct SourceRecencyChip: View {
    let rawState: SourceState
    let displayedState: SourceState
    let lastSyncAt: Date?
    var now: Date = Date()

    var body: some View {
        TimelineView(.periodic(from: now, by: 30)) { context in
            let text = SourceRowCopy.trailingStatus(
                rawState: rawState,
                displayedState: displayedState,
                lastSyncAt: lastSyncAt,
                now: context.date
            )
            Text(text)
                .font(
                    SourceRowCopy.trailingStatusIsRecency(text)
                        ? .callout.monospacedDigit()
                        : .callout
                )
                .foregroundStyle(
                    tone(rawState: rawState, displayedState: displayedState).color
                )
                .contentTransition(.numericText())
                .animation(.default, value: text)
                .frame(minWidth: 52, alignment: .trailing)
        }
    }

    private func tone(rawState: SourceState, displayedState: SourceState) -> StatusTone {
        switch displayedState {
        case .needsAttention:
            return .attention
        case .error:
            return .error
        case .disconnected:
            if case .connected = rawState {
                return .muted
            }
            return .error
        default:
            return .muted
        }
    }

    /// Pure formatter exposed for tests and for the accessibility label.
    /// Returns `now` under one minute, then bucketed abbreviations:
    /// `Nm` / `Nhr` / `Nd` / `Nw`.
    nonisolated static func format(interval seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 60 { return "now" }
        let minutes = Int(s / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)hr" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        let weeks = days / 7
        return "\(weeks)w"
    }
}
