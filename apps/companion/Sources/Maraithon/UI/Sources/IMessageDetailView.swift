import SwiftUI

/// Detail pane for the iMessage source. Composes the four sections called
/// out in the spec: Status card → Stats grid → Controls row → Recent
/// activity. The screen is read-only at this layer — interaction handlers
/// are local stubs that emit log lines; real wiring lands in M4/M5
/// integration.
///
/// Invariants:
/// - Every section is reachable from a single `ScrollView` so empty /
///   paused / error variants can swap in via `ContentUnavailableView`
///   without breaking the layout.
/// - No bordered cards, gradients, or shadows — see `AGENTS.md`.
struct IMessageDetailView: View {
    @Environment(AppEnvironment.self) private var env

    /// View-facing fallback when the real source isn't registered yet.
    /// When the registry has the source, `effectiveState` reads directly
    /// from its `SourceStatusPublisher` so the syncing animation actually
    /// reflects the source's real state.
    @State private var viewState: ViewState = .disconnected
    @State private var isPaused: Bool = false
    @State private var showBackfillSheet: Bool = false
    @State private var showClearDataSheet: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: Tokens.Spacing.large) {
                switch viewState {
                case .empty:
                    emptyContent
                case .error(let reason):
                    errorContent(reason: reason)
                case .paused, .connected, .syncing, .disconnected, .needsAttention:
                    SourceStatusBadge(state: liveBadgeState, variant: .prominent)
                    Text(headlineCopy)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                    Text(liveStatusSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button {
                        env.sources.syncNow(id: "imessage")
                    } label: {
                        Label("Sync now", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("r", modifiers: .command)

                    Button(isPaused ? "Resume" : "Pause") {
                        isPaused.toggle()
                        if isPaused {
                            env.sources.pause(id: "imessage")
                        } else {
                            env.sources.resume(id: "imessage")
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(Tokens.Spacing.xlarge)
            .frame(maxWidth: .infinity)
            .animation(.default, value: viewState)
            .animation(.default, value: isPaused)
        }
        .navigationTitle("iMessage")
        .onAppear { viewState = .connected }
    }

    /// Headline copy used by the clean detail view. Surfaces the total
    /// synced count when one batch has shipped; otherwise the steady
    /// "up to date" line. Mirrors `SourceDetailScaffold.headlineCopy`.
    private var headlineCopy: String {
        let total = env.sources.statusPublisher(for: "imessage")?.totalAccepted ?? 0
        if isPaused { return "iMessage is paused" }
        if total > 0 {
            return "\(total.formatted(.number)) iMessages synced this session"
        }
        return "iMessage is up to date"
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

    /// Maps the live `SourceStatusPublisher.state` (if registered) onto a
    /// `SourceStatusBadge.State`. Falls back to the local `viewState` when
    /// the source isn't installed.
    private var liveBadgeState: SourceStatusBadge.State {
        guard let publisher = env.sources.statusPublisher(for: "imessage") else {
            return badgeState
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
        guard let publisher = env.sources.statusPublisher(for: "imessage") else {
            return statusSubtitle
        }
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

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            SectionHeader("Stats")
            let columns = [GridItem(.adaptive(minimum: 160), spacing: Tokens.Spacing.medium)]
            LazyVGrid(columns: columns, spacing: Tokens.Spacing.medium) {
                StatCard(title: "Today", value: "47", trend: .up("+12 vs yesterday"))
                StatCard(title: "This week", value: "318", caption: "across 14 chats")
                StatCard(title: "Total", value: "12,408")
                StatCard(title: "Cursor", value: "p:218,402", caption: "rowid")
            }
        }
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            SectionHeader("Controls")
            HStack(spacing: Tokens.Spacing.small) {
                Button {
                    isPaused.toggle()
                    env.eventLog.info(
                        "imessage.toggle_pause",
                        source: .ui,
                        payload: ["paused": String(isPaused)]
                    )
                } label: {
                    Label(isPaused ? "Resume" : "Pause",
                          systemImage: isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)

                Button {
                    env.sources.syncNow()
                } label: {
                    Label("Sync now", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(isPaused)

                Button {
                    showBackfillSheet = true
                } label: {
                    Label("Backfill more…", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(role: .destructive) {
                    showClearDataSheet = true
                } label: {
                    Label("Clear cloud data…", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            SectionHeader("Recent activity")
            Table(recentBatches.sorted { $0.timestamp > $1.timestamp }) {
                TableColumn("Time") { batch in
                    Text(batch.timestamp, format: .dateTime.hour().minute().second())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 110)

                TableColumn("Count") { batch in
                    Text(String(batch.count))
                        .monospacedDigit()
                }
                .width(min: 60, ideal: 70)

                TableColumn("Accepted") { batch in
                    Text(String(batch.accepted))
                        .monospacedDigit()
                        .foregroundStyle(StatusTone.good.color)
                }
                .width(min: 70, ideal: 80)

                TableColumn("Duplicates") { batch in
                    Text(String(batch.duplicates))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 100)

                TableColumn("Latency") { batch in
                    Text(latencyText(batch.latencyMs))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 90)
            }
            .frame(minHeight: 240)
        }
    }

    // MARK: Variant content

    private var emptyContent: some View {
        ContentUnavailableView {
            Label("No messages yet", systemImage: "message")
        } description: {
            Text("Once your first batch finishes, this view will show today's stats and your most recent sync runs.")
        } actions: {
            Button("Sync now") { env.sources.syncNow() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func errorContent(reason: String) -> some View {
        ContentUnavailableView {
            Label("Sync paused", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text(reason)
        } actions: {
            Button("Try again") {
                viewState = .connected
                env.sources.syncNow()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Derived

    private var badgeState: SourceStatusBadge.State {
        if isPaused { return .paused }
        switch viewState {
        case .connected: return .connected
        case .syncing: return .syncing
        case .paused: return .paused
        case .disconnected: return .disconnected
        case .needsAttention(let reason): return .needsAttention(reason)
        case .error(let reason): return .error(reason)
        case .empty: return .connected
        }
    }

    private var statusSubtitle: String {
        if isPaused { return "Sync is paused. Resume to pick up new messages." }
        switch viewState {
        case .connected: return "Last sync 14:23 — 47 new, 0 errors."
        case .syncing: return "Pulling new messages from chat.db…"
        case .disconnected: return "Not connected. Finish onboarding to begin syncing."
        case .needsAttention(let reason): return reason
        case .error(let reason): return reason
        case .paused: return "Sync is paused. Resume to pick up new messages."
        case .empty: return "Waiting for first sync."
        }
    }

    // MARK: Mock data

    private var recentBatches: [BatchRow] {
        let now = Date()
        return (0..<8).map { offset in
            BatchRow(
                id: UUID(),
                timestamp: now.addingTimeInterval(Double(-offset) * 30),
                count: 12 + (offset * 3) % 23,
                accepted: 12 + (offset * 3) % 23 - (offset % 2),
                duplicates: offset % 3,
                latencyMs: 120 + (offset * 47) % 380
            )
        }
    }

    private func latencyText(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms) ms" }
        return String(format: "%.1f s", Double(ms) / 1000)
    }

    enum ViewState: Equatable, Hashable {
        case connected
        case syncing
        case paused
        case disconnected
        case needsAttention(String)
        case error(String)
        case empty
    }

    struct BatchRow: Identifiable, Hashable {
        let id: UUID
        let timestamp: Date
        let count: Int
        let accepted: Int
        let duplicates: Int
        let latencyMs: Int
    }
}

private struct BackfillSheet: View {
    @Binding var isPresented: Bool
    @State private var choice: BackfillSetupView.Window = .last90

    var body: some View {
        Form {
            Section("Window") {
                Picker("Backfill window", selection: $choice) {
                    ForEach(BackfillSetupView.Window.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            Section {
                Text("Maraithon will queue the missing window and pace uploads so the cloud doesn't burst.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 360, minHeight: 280)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { isPresented = false }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Start") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .navigationTitle("Backfill more")
    }
}

private struct ClearDataSheet: View {
    @Binding var isPresented: Bool
    var onConfirm: () -> Void

    @State private var typed: String = ""

    private var canConfirm: Bool {
        typed.lowercased() == "delete"
    }

    var body: some View {
        Form {
            Section {
                Label("This cannot be undone", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(StatusTone.attention.color)
                Text("This will delete every message Maraithon has synced from this Mac out of the cloud. Local Messages.app history is not affected.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Confirm") {
                TextField("Type \"delete\" to confirm", text: $typed)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 360, minHeight: 260)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { isPresented = false }
            }
            ToolbarItem(placement: .destructiveAction) {
                Button("Clear cloud data") {
                    onConfirm()
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

struct ComingSoonDetailView: View {
    var body: some View {
        ContentUnavailableView(
            "Coming soon",
            systemImage: "sparkles",
            description: Text("Additional sources land after iMessage is stable.")
        )
        .navigationTitle("Coming soon")
    }
}
