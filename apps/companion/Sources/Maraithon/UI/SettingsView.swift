import SwiftUI
import ServiceManagement

/// Standard macOS Settings scene with General / Sync / Devices / Privacy tabs.
struct SettingsView: View {
    @AppStorage("developer_mode") private var developerMode: Bool = false

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            SyncSettingsView()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            DevicesSettingsView()
                .tabItem { Label("Devices", systemImage: "laptopcomputer") }
            DataSettingsView()
                .tabItem { Label("Data", systemImage: "externaldrive") }
            if developerMode {
                DiagnosticsSettingsView()
                    .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            }
            PrivacySettingsView()
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .frame(width: 520, height: 500)
    }
}

/// Centralized data-deletion controls. Per-source rows expose a
/// non-destructive local re-sync and a destructive synced-data delete.
/// Per the team convention, the detail panes no longer show these
/// buttons — data deletion lives in Settings only.
private struct DataSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var pendingClear: PendingClear? = nil

    var body: some View {
        Form {
            Section {
                Text(DataSettingsCopy.intro)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Per source") {
                ForEach(env.sources.sources.filter { !$0.comingSoon }) { source in
                    DataRow(
                        title: source.displayName,
                        symbol: source.symbol,
                        onReset: { env.sources.resetCursor(id: source.id) },
                        onClear: { pendingClear = .source(id: source.id, name: source.displayName) }
                    )
                }
            }
            Section("All sources") {
                Button(role: .destructive) {
                    pendingClear = .all
                } label: {
                    Label(DataSettingsCopy.deleteAllTitle, systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                Text(DataSettingsCopy.deleteAllDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $pendingClear) { pending in
            ClearCloudDataSheet(
                isPresented: Binding(
                    get: { pendingClear != nil },
                    set: { if !$0 { pendingClear = nil } }
                ),
                description: pending.description,
                onConfirmClearCloud: {
                    switch pending {
                    case .source(let id, _):
                        env.eventLog.warning(
                            "\(id).clear_cloud_data.confirmed",
                            source: .ui
                        )
                    case .all:
                        env.eventLog.warning(
                            "settings.clear_all_cloud_data.confirmed",
                            source: .ui
                        )
                    }
                },
                onResetLocalCursor: nil
            )
        }
    }

    private enum PendingClear: Identifiable, Hashable {
        case source(id: String, name: String)
        case all

        var id: String {
            switch self {
            case .source(let id, _): return "source:\(id)"
            case .all: return "all"
            }
        }

        var description: String {
            switch self {
            case .source(_, let name):
                return DataSettingsCopy.sourceDeleteConfirmation(sourceName: name)
            case .all:
                return DataSettingsCopy.deleteAllConfirmation
            }
        }
    }

    private struct DataRow: View {
        let title: String
        let symbol: String
        let onReset: () -> Void
        let onClear: () -> Void

        var body: some View {
            HStack(spacing: Tokens.Spacing.small) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: Tokens.IconSize.inline)
                Text(title)
                Spacer()
                Button(DataSettingsCopy.resyncTitle, action: onReset)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(role: .destructive) { onClear() } label: {
                    Text(DataSettingsCopy.deleteTitle)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }
        }
    }
}

enum DataSettingsCopy {
    static let intro = "Manage data Maraithon has synced from this Mac. Re-sync starts a source over locally; Delete removes Maraithon's synced copy and cannot be undone."
    static let resyncTitle = "Re-sync"
    static let deleteTitle = "Delete…"
    static let deleteAllTitle = "Delete all synced data…"
    static let deleteAllDescription = "Deletes Maraithon's synced copy for every source from this Mac. Local data is not affected; sources can sync again afterward."
    static let deleteAllConfirmation = "This deletes every record Maraithon has synced from this Mac across all sources. Local data on your device is not affected; sources can sync again afterward."

    static func sourceDeleteConfirmation(sourceName: String) -> String {
        "This deletes every \(sourceName) record Maraithon has synced from this Mac. Local data on your device is not affected."
    }
}

/// Developer-grade diagnostics: per-source publisher metrics, the live
/// cursor state, and the recent-activity ring buffer. The end-user
/// detail panes no longer
/// show any of this — it lives only here so debugging surfaces don't
/// crowd the day-to-day "is this working?" view.
private struct DiagnosticsSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var expanded: Set<String> = []

    var body: some View {
        Form {
            Section {
                Text(DiagnosticsSettingsCopy.intro)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(env.sources.sources.filter { !$0.comingSoon }) { source in
                Section(source.displayName) {
                    DiagnosticsSourceRow(sourceID: source.id, expanded: $expanded)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DiagnosticsSourceRow: View {
    @Environment(AppEnvironment.self) private var env
    let sourceID: String
    @Binding var expanded: Set<String>

    var body: some View {
        let pub = env.sources.statusPublisher(for: sourceID)
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            HStack {
                MetricCell(title: "Today", value: format(pub?.acceptedToday))
                MetricCell(title: "Last check", value: format(pub?.lastBatchAccepted))
                MetricCell(title: "Already known", value: format(pub?.lastBatchDuplicate))
                MetricCell(title: "Needs attention", value: format(pub?.lastBatchFailed))
                MetricCell(title: "Synced", value: format(pub?.totalAccepted))
            }
            Text(DiagnosticsSettingsCopy.stateLine(publisher: pub))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            Button {
                if expanded.contains(sourceID) {
                    expanded.remove(sourceID)
                } else {
                    expanded.insert(sourceID)
                }
            } label: {
                Label(
                    expanded.contains(sourceID) ? "Hide recent activity" : "Show recent activity",
                    systemImage: expanded.contains(sourceID) ? "chevron.up" : "chevron.down"
                )
                .font(.caption)
            }
            .buttonStyle(.borderless)

            if expanded.contains(sourceID), let pub, !pub.recentBatches.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(pub.recentBatches.prefix(10)) { event in
                        HStack {
                            Text(event.timestamp, format: .dateTime.hour().minute().second())
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Text(DiagnosticsSettingsCopy.batchLine(event))
                                .monospacedDigit()
                        }
                        .font(.caption.monospaced())
                    }
                }
                .padding(.top, Tokens.Spacing.xsmall)
            }
        }
        .padding(.vertical, Tokens.Spacing.xsmall)
    }

    private func format(_ n: Int?) -> String {
        guard let n else { return "—" }
        return n.formatted(.number)
    }
}

enum DiagnosticsSettingsCopy {
    static let intro = "Review sync health for each source. Expand a source to see recent batches and the last successful check."
    static let developerModeDescription = "Shows Logs and Diagnostics for sync health, recent batches, and support troubleshooting. Off by default."

    @MainActor
    static func stateLine(publisher: SourceStatusPublisher?) -> String {
        guard let publisher else { return "Status: Not registered. Last checked: Never" }
        let stateString: String
        switch publisher.displayedState() {
        case .connected: stateString = "Connected"
        case .syncing: stateString = "Syncing"
        case .paused: stateString = "Paused"
        case .disconnected: stateString = "Disconnected"
        case .needsAttention(let reason):
            stateString = "Needs attention - \(SourceIssueCopy.status(reason))"
        case .error(let reason):
            stateString = "Error - \(SourceIssueCopy.status(reason))"
        }
        let last = publisher.lastSyncAt.map { date in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f.string(from: date)
        } ?? "Never"
        return "Status: \(stateString). Last checked: \(last)"
    }

    static func batchLine(_ event: SourceStatusPublisher.BatchEvent) -> String {
        "Synced \(event.accepted) | Already known \(event.duplicate) | Needs attention \(event.failed) | \(event.latencyMS) ms"
    }
}

private struct MetricCell: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var requiresApproval = SMAppService.mainApp.status == .requiresApproval

    var body: some View {
        @Bindable var updates = env.updates
        @Bindable var batterySettings = BatterySettings.shared
        Form {
            Section {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, newValue in
                        updateLoginItem(enabled: newValue)
                    }
                if requiresApproval {
                    Label(
                        "Approve Maraithon in System Settings → General → Login Items to enable.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            Section("Power") {
                Toggle(
                    "Pause syncing when on battery",
                    isOn: $batterySettings.pauseOnBattery
                )
                Text("When enabled, Maraithon pauses every source while macOS is in Low Power Mode. Sources resume automatically once you plug in.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Software Update") {
                Toggle(
                    "Automatically check for updates",
                    isOn: $updates.automaticallyChecksForUpdates
                )
                .disabled(!env.updates.isSparkleEnabled)
                LabeledContent("Last checked") {
                    Text(lastCheckText)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("") {
                    Button("Check Now") {
                        env.updates.checkForUpdates()
                    }
                    .disabled(!env.updates.canCheckForUpdates)
                }
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.shortVersion)
            }
            Section("Developer") {
                Toggle("Developer mode", isOn: $developerMode)
                Text(DiagnosticsSettingsCopy.developerModeDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @AppStorage("developer_mode") private var developerMode: Bool = false

    private var lastCheckText: String {
        guard let date = env.updates.lastUpdateCheckDate else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func updateLoginItem(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
        requiresApproval = SMAppService.mainApp.status == .requiresApproval
    }
}

private struct SyncSettingsView: View {
    @AppStorage("pollIntervalSeconds") private var pollInterval = 30.0

    var body: some View {
        Form {
            Section("Cadence") {
                LabeledContent("Poll every") {
                    Slider(value: $pollInterval, in: 15...300, step: 5) {
                        Text("Poll interval")
                    } minimumValueLabel: {
                        Text("15s").font(.caption).foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text("5m").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(width: 240)
                }
                LabeledContent("Currently", value: "\(Int(pollInterval))s")
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacySettingsView: View {
    var body: some View {
        Form {
            PrivacyBlocklistEditor()
            SpotlightSurfaceSection()
            EndToEndEncryptionSection()
            Section("Telemetry") {
                Toggle("Send anonymous usage stats", isOn: .constant(false))
                Toggle("Send crash reports", isOn: .constant(true))
            }
        }
        .formStyle(.grouped)
    }
}

enum PrivacySettingsCopy {
    static let encryptionIntro =
        "When enabled, content is encrypted on this Mac with a key only this device holds. " +
        "Maraithon can still use details like time, sender, and source name, but not the message, " +
        "note, or transcript text. Search quality may drop for sources you encrypt."
    static let browserHistoryEncryptionFooter =
        "Browser History is handled separately because search ranking needs site and visit details. " +
        "You can control whether browser results appear in Spotlight above."
}

/// "End-to-end encryption (per source)" section. One checkbox per
/// source listed in `EncryptableSource`. State is persisted to
/// `UserDefaults` via `@AppStorage` so the ingest helpers see the
/// same value without an `AppEnvironment` round-trip.
///
/// Browser history is intentionally absent from the list — see the
/// `EncryptableSource` enum docs for the rationale. The footnote
/// below the checkboxes spells that out for the user.
private struct EndToEndEncryptionSection: View {
    var body: some View {
        Section {
            Text(PrivacySettingsCopy.encryptionIntro)
            .font(.footnote)
            .foregroundStyle(.secondary)

            ForEach(EncryptableSource.allCases) { source in
                EncryptionToggleRow(source: source)
            }
        } header: {
            Text("End-to-end encryption (per source)")
        } footer: {
            Text(PrivacySettingsCopy.browserHistoryEncryptionFooter)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

private struct EncryptionToggleRow: View {
    let source: EncryptableSource

    @AppStorage private var enabled: Bool

    init(source: EncryptableSource) {
        self.source = source
        self._enabled = AppStorage(
            wrappedValue: false,
            EncryptionSettings.defaultsKey(for: source)
        )
    }

    var body: some View {
        Toggle(source.displayName, isOn: $enabled)
    }
}

/// "Surface in Mac Spotlight" toggles, one per source we ship index
/// support for. Lives in Settings → Privacy because the decision is
/// inherently a privacy call — turning a source on means its titles +
/// snippets (already redaction-filtered) will appear in the system-wide
/// Spotlight search alongside other Mac results.
///
/// State is persisted to `UserDefaults` via `SpotlightTogglesStore` so
/// flips survive app relaunches. Defaults follow the privacy table in
/// the v6 brief: Notes / Voice Memos / Reminders / Calendar / Files
/// are on; iMessage and Browser History are off.
private struct SpotlightSurfaceSection: View {
    @State private var store = SpotlightTogglesStore()

    /// Sources surfaced in this section. Encrypted-with-device-key
    /// rows are excluded from the indexer entirely and don't appear
    /// here either — there's nothing for the user to flip.
    private let rows: [Row] = [
        Row(id: "notes", label: "Notes"),
        Row(id: "voice_memos", label: "Voice Memos"),
        Row(id: "reminders", label: "Reminders"),
        Row(id: "calendar", label: "Calendar"),
        Row(id: "files", label: "Files"),
        Row(id: "imessage", label: "iMessage"),
        Row(id: "browser_history", label: "Browser History")
    ]

    var body: some View {
        Section {
            ForEach(rows) { row in
                Toggle(
                    row.label,
                    isOn: Binding(
                        get: { store.isEnabled(source: row.id) },
                        set: { store.setEnabled($0, source: row.id) }
                    )
                )
            }
        } header: {
            Text("Surface in Mac Spotlight")
        } footer: {
            Text(
                "When on, synced records appear in macOS Spotlight search " +
                "alongside your other Mac results. Tapping a result opens " +
                "the matching detail view in Maraithon."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private struct Row: Identifiable, Hashable {
        let id: String
        let label: String
    }
}

private extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
