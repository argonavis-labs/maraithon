import SwiftUI

/// Sidebar listing the user's account, the available sources, and the
/// Logs pane. Polished to match the macOS sidebar idiom (`Section`
/// headers, secondary metadata text, compact status badge per source).
///
/// Invariant: keep the `SidebarItem` enum signature stable — `RootWindow`
/// switches over it.
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
                    lastSyncAt: publisher?.lastSyncAt,
                    suppress: shouldSuppressRecency(displayedState)
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

    private func shouldSuppressRecency(_ state: SourceState) -> Bool {
        switch state {
        case .needsAttention, .error: return true
        default: return false
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
        // successful sync yet reads as "waiting for first sync" so
        // VoiceOver doesn't say "disconnected" when the user just hasn't
        // had a first batch land yet.
        if case .connected = rawState, lastSyncAt == nil {
            return "\(sourceName), waiting for first sync"
        }

        let stateWord = statePhrase(displayedState)
        switch displayedState {
        case .needsAttention, .error:
            return "\(sourceName), \(stateWord)"
        default:
            if let last = lastSyncAt {
                let abbrev = SourceRecencyChip.format(interval: now.timeIntervalSince(last))
                return "\(sourceName), \(stateWord), last sync \(abbrev) ago"
            }
            return "\(sourceName), \(stateWord), not yet synced"
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
        guard let last = lastSyncAt else { return "Not yet synced" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Last sync \(formatter.localizedString(for: last, relativeTo: now))"
    }

    private static func statePhrase(_ state: SourceState) -> String {
        switch state {
        case .connected: return "connected"
        case .syncing: return "syncing"
        case .paused: return "paused"
        case .disconnected: return "disconnected"
        case .needsAttention(let reason):
            return "needs attention, \(SourceIssueCopy.status(reason))"
        case .error(let reason):
            return "error, \(SourceIssueCopy.status(reason))"
        }
    }
}

/// Trailing per-row chip that shows the abbreviated time since the
/// source's last successful sync (`now`, `2m`, `3hr`, `1d`, `2w`).
/// Uses `TimelineView` so the label refreshes on its own without
/// needing the publisher to fire.
struct SourceRecencyChip: View {
    let lastSyncAt: Date?
    /// When true, recency is suppressed (e.g., needs attention / error)
    /// and the chip renders an em-dash placeholder.
    let suppress: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let text = label(now: context.date)
            Text(text)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(.default, value: text)
                .frame(minWidth: 32, alignment: .trailing)
        }
    }

    private func label(now: Date) -> String {
        if suppress { return "—" }
        guard let last = lastSyncAt else { return "—" }
        return Self.format(interval: now.timeIntervalSince(last))
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
