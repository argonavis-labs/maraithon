import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The single window that hosts the whole app. Renders either the sidebar
/// split view (signed in) or the centered Connect screen (signed out).
///
/// v4: when the user explicitly skipped Full Disk Access during
/// onboarding the main split view is overlaid with a persistent banner
/// across the top — clicking the banner short-circuits to System
/// Settings the same way the onboarding screen does. The banner clears
/// automatically once the FDA probe sees access has been granted.
struct RootWindow: View {
    @Environment(AppEnvironment.self) private var env
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
                            if env.onboarding.isFullDiskAccessSkipped {
                                FullDiskAccessRequiredBanner()
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

/// Persistent inline banner shown above the main detail pane when the
/// user opted to skip Full Disk Access during onboarding. The banner
/// stays until the FDA probe in `DiagnosticsView` (or the onboarding
/// reentry path) clears the persisted flag.
struct FullDiskAccessRequiredBanner: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(spacing: Tokens.Spacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StatusTone.attention.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("Full Disk Access required")
                    .font(.callout.weight(.medium))
                Text("Without it, Maraithon can't sync iMessage. Other sources continue to sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open System Settings") {
                openFullDiskAccess()
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, Tokens.Spacing.medium)
        .padding(.vertical, Tokens.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .combine)
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
}
