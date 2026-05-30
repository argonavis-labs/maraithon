import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The single window that hosts the whole app. Renders either the sidebar
/// split view (signed in) or the centered Connect screen (signed out).
///
/// v4: when the user explicitly skipped Full Disk Access during
/// onboarding, or a live source reports that Full Disk Access is blocking
/// sync, the main split view is overlaid with a persistent banner across
/// the top. Clicking the banner short-circuits to System Settings the
/// same way the onboarding screen does.
struct RootWindow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: SidebarItem? = .source(id: "imessage")

    var body: some View {
        Group {
            switch env.deviceAuth.state {
            case .signedOut, .error:
                ConnectView()
            default:
                if env.onboarding.current != .done {
                    OnboardingView(flow: env.onboarding)
                } else {
                    NavigationSplitView {
                        SidebarView(selection: $selection)
                    } detail: {
                        VStack(spacing: 0) {
                            let blockedSourceNames = env.sources
                                .fullDiskAccessBlockedSources()
                                .map(\.displayName)
                            if env.onboarding.isFullDiskAccessSkipped || !blockedSourceNames.isEmpty {
                                FullDiskAccessRequiredBanner(blockedSourceNames: blockedSourceNames)
                            }
                            detailView(for: selection)
                        }
                    }
                }
            }
        }
        .animation(.default, value: env.deviceAuth.state)
        .animation(.default, value: env.onboarding.current)
        .onAppear {
            BatterySettings.shared.bind(sources: env.sources, eventLog: env.eventLog)
            refreshFullDiskAccessIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            refreshFullDiskAccessIfNeeded()
        }
        .onChange(of: env.deviceAuth.state) { _, newState in
            // Re-enter onboarding if the user signs out mid-flow before
            // ever completing it. Users who already finished onboarding
            // do not get re-prompted (the persisted flag wins).
            switch newState {
            case .signedOut, .error:
                env.onboarding.reset()
            default:
                break
            }
        }
    }

    private func refreshFullDiskAccessIfNeeded() {
        let needsRefresh = env.onboarding.isFullDiskAccessSkipped
            || !env.sources.fullDiskAccessBlockedSources().isEmpty

        guard needsRefresh else {
            return
        }

        if FullDiskAccessProbe.isGranted() {
            env.onboarding.recordFullDiskAccessGranted()
            env.sources.syncFullDiskAccessBlockedSources()
        } else {
            env.sources.syncNow()
        }
    }

    @ViewBuilder
    private func detailView(for selection: SidebarItem?) -> some View {
        switch selection {
        case .source(let id) where id == "imessage":
            IMessageDetailView()
        case .source(let id) where id == "notes":
            NotesDetailView()
        case .source(let id) where id == "voice_memos":
            VoiceMemosDetailView()
        case .source(let id) where id == "reminders":
            RemindersDetailView()
        case .source(let id) where id == "calendar":
            CalendarDetailView()
        case .source(let id) where id == "files":
            FilesDetailView()
        case .source(let id) where id == "browser_history":
            BrowserHistoryDetailView()
        case .source:
            ComingSoonDetailView()
        case .logs:
            LogsView()
        case .diagnostics:
            DiagnosticsView()
        case .none:
            ContentUnavailableView(
                "Pick a source",
                systemImage: "sidebar.left",
                description: Text("Choose a source from the sidebar to see its sync status.")
            )
        }
    }
}

enum SidebarItem: Hashable {
    case source(id: String)
    case logs
    case diagnostics
}

/// Persistent inline banner shown above the main detail pane when Full
/// Disk Access is blocking local-source sync.
struct FullDiskAccessRequiredBanner: View {
    let blockedSourceNames: [String]

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(spacing: Tokens.Spacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StatusTone.attention.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("Full Disk Access required")
                    .font(.callout.weight(.medium))
                Text(Self.detailText(blockedSourceNames: blockedSourceNames))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let installHint = FullDiskAccessInstallHint.current() {
                    Text(installHint.message)
                        .font(.caption)
                        .foregroundStyle(StatusTone.attention.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if let installHint = FullDiskAccessInstallHint.current(),
               installHint.stableAppInstalled {
                Button(FullDiskAccessInstallHint.switchToStableAppButtonTitle) {
                    switchToStableApp(installHint.stableAppURL)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
            Button("Check again") {
                checkAgain()
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            if FullDiskAccessInstallHint.current()?.stableAppInstalled != true {
                Button("Open System Settings") {
                    openFullDiskAccess()
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, Tokens.Spacing.medium)
        .padding(.vertical, Tokens.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }

    static func detailText(blockedSourceNames: [String]) -> String {
        let subject = readableList(blockedSourceNames, fallback: "iMessage, Notes, and Voice Memos")
        return "\(subject) need one macOS Full Disk Access grant. Enable Maraithon once; other sources continue to sync."
    }

    private static func readableList(_ values: [String], fallback: String) -> String {
        let names = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        switch names.count {
        case 0:
            return fallback
        case 1:
            return names[0]
        case 2:
            return "\(names[0]) and \(names[1])"
        default:
            let prefix = names.dropLast().joined(separator: ", ")
            return "\(prefix), and \(names[names.count - 1])"
        }
    }

    private func openFullDiskAccess() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        guard let url = URL(string: urlString) else {
            env.eventLog.warning(
                "root_window.fda_banner.url_invalid",
                source: .ui,
                payload: ["url": urlString]
            )
            return
        }
        env.eventLog.info("root_window.fda_banner.open_settings", source: .ui)
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    private func switchToStableApp(_ appURL: URL) {
        #if canImport(AppKit)
        FullDiskAccessInstallHint.switchToStableDevelopmentApp(
            appURL,
            eventLog: env.eventLog,
            eventName: "root_window.fda_banner.open_stable_app"
        )
        #endif
    }

    private func checkAgain() {
        if FullDiskAccessProbe.isGranted() {
            env.onboarding.recordFullDiskAccessGranted()
            env.sources.syncFullDiskAccessBlockedSources()
        } else {
            env.sources.syncNow()
        }
    }
}
