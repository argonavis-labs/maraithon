import SwiftUI

/// Bottom-of-sidebar diagnostics pane. Pairs a single summary card
/// (realtime channel state, total events synced today, total queued for
/// retry, last check per source) with the existing `LogsView` below it.
///
/// Invariants:
///   - Reuses `LogsView` verbatim — this view never duplicates log
///     filtering / inspection logic.
///   - The header card is pure rollups derived from `AppEnvironment`.
///     Detail per source still lives on the per-source detail pane.
struct DiagnosticsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var realtimeStatus: DiagnosticsRealtimeStatus = .offline
    @State private var pendingRetryCount: Int = 0
    @State private var realtimeTask: Task<Void, Never>? = nil
    @State private var queueTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerCard
                .padding(Tokens.Spacing.large)
            Divider()
            LogsView()
        }
        .navigationTitle("Diagnostics")
        .onAppear {
            startObservingRealtime()
            startObservingQueue()
        }
        .onDisappear {
            realtimeTask?.cancel()
            realtimeTask = nil
            queueTask?.cancel()
            queueTask = nil
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.medium) {
            SectionHeader("Health")

            let columns = [GridItem(.adaptive(minimum: 180), spacing: Tokens.Spacing.medium)]
            LazyVGrid(columns: columns, spacing: Tokens.Spacing.medium) {
                StatCard(
                    title: "Realtime channel",
                    value: realtimeStatus.label,
                    caption: realtimeStatus.caption
                )
                StatCard(
                    title: "Events synced today",
                    value: String(eventsToday),
                    caption: "Across \(activeSourceCount) sources"
                )
                StatCard(
                    title: "Queued for retry",
                    value: String(pendingRetryCount),
                    caption: pendingRetryCount == 0 ? "No backlog" : "Will retry on next tick"
                )
                StatCard(
                    title: "Auth",
                    value: authLabel,
                    caption: authCaption
                )
            }

            VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
                SectionHeader("Last checked per source")
                if visibleSources.isEmpty {
                    ContentUnavailableView(
                        "Waiting for sources",
                        systemImage: "tray",
                        description: Text("Sources appear here after the companion registers them.")
                    )
                    .frame(minHeight: 120)
                } else {
                    ForEach(visibleSources, id: \.id) { source in
                        DiagnosticsSourceRow(
                            displayName: source.displayName,
                            symbol: source.symbol,
                            state: source.state,
                            lastSync: env.sources.statusPublisher(for: source.id)?.lastSyncAt
                        )
                    }
                }
            }
        }
    }

    // MARK: - Derived state

    private var visibleSources: [SourceDescriptor] {
        env.sources.sources.filter { !$0.comingSoon }
    }

    private var activeSourceCount: Int { visibleSources.count }

    private var eventsToday: Int {
        DiagnosticsSummaryMetrics.eventsSyncedToday(
            visibleSources.map { env.sources.statusPublisher(for: $0.id) }
        )
    }

    private var authLabel: String {
        switch env.deviceAuth.state {
        case .signedIn: return "Signed in"
        case .connecting, .awaitingApproval: return "Connecting"
        case .signedOut: return "Signed out"
        case .error: return "Error"
        }
    }

    private var authCaption: String? {
        switch env.deviceAuth.state {
        case .signedIn(let account): return account.email
        case .error(let message): return message
        default: return nil
        }
    }

    // MARK: - Live observers

    private func startObservingRealtime() {
        realtimeTask?.cancel()
        let channel = env.realtime
        realtimeTask = Task { @MainActor in
            let stream = await channel.statusStream()
            for await status in stream {
                realtimeStatus = DiagnosticsRealtimeStatus(channelStatus: status)
                if Task.isCancelled { return }
            }
        }
    }

    /// Approximation of "queued for retry" using the sync engine's
    /// observable `consecutiveFailures`. The persistent queue's actual
    /// row count would be more precise, but the engine's existing
    /// public surface only exposes the retry counter — and that's the
    /// signal the user cares about: "is sync stuck?"
    private func startObservingQueue() {
        queueTask?.cancel()
        let engine = env.syncEngine
        queueTask = Task { @MainActor in
            while !Task.isCancelled {
                pendingRetryCount = engine.consecutiveFailures
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

enum DiagnosticsSummaryMetrics {
    @MainActor
    static func eventsSyncedToday(_ publishers: [SourceStatusPublisher?]) -> Int {
        publishers.reduce(0) { total, publisher in
            total + (publisher?.acceptedToday ?? 0)
        }
    }
}

/// View-facing realtime status. Maps `RealtimeChannel.Status` into a
/// single label/caption pair so the StatCard treatment stays consistent.
enum DiagnosticsRealtimeStatus: Equatable, Sendable {
    case connected
    case reconnecting
    case offline

    init(channelStatus: RealtimeChannel.Status) {
        switch channelStatus {
        case .connected: self = .connected
        case .connecting: self = .reconnecting
        case .disconnected: self = .offline
        }
    }

    var label: String {
        switch self {
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting"
        case .offline: return "Offline"
        }
    }

    var caption: String? {
        switch self {
        case .connected: return "Push enabled"
        case .reconnecting: return "Falling back to HTTP"
        case .offline: return "Falling back to HTTP"
        }
    }
}

/// Per-source row in the diagnostics summary. Mirrors the sidebar row's
/// vocabulary but adds the most recent sync timestamp.
private struct DiagnosticsSourceRow: View {
    let displayName: String
    let symbol: String
    let state: SourceState
    let lastSync: Date?

    var body: some View {
        HStack(spacing: Tokens.Spacing.small) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: Tokens.IconSize.inline)
            Text(displayName)
                .font(.callout)
            Spacer()
            Text(lastSyncText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            SourceStatusBadge(state: badgeState)
        }
        .accessibilityElement(children: .combine)
    }

    private var badgeState: SourceStatusBadge.State {
        switch state {
        case .disconnected: return .disconnected
        case .connected: return .connected
        case .syncing: return .syncing
        case .paused: return .paused
        case .needsAttention(let reason): return .needsAttention(reason)
        case .error(let reason): return .error(reason)
        }
    }

    private var lastSyncText: String {
        guard let lastSync else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: lastSync, relativeTo: Date())
    }
}
