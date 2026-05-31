import SwiftUI
import AppKit

/// Focused detail-pane content shown when a source is in
/// `.needsAttention(...)`. Replaces stats / controls / activity entirely
/// — per AGENTS.md rule 8 and the maraithon-mac convention that blocked
/// panes should surface only the unblocking action.
///
/// The primary button deep-links into the right System Settings Privacy
/// pane via `x-apple.systempreferences:`. The secondary button re-runs
/// the source's `syncNow`, which re-evaluates authorization and flips
/// the state to `.connected` / `.syncing` if the user has granted.
struct SourceUnblockView: View {
    let sourceID: String
    let displayName: String
    let hint: SourcePermissionHint

    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ContentUnavailableView {
            Label(hint.title, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(StatusTone.attention.color)
        } description: {
            VStack(alignment: .center, spacing: Tokens.Spacing.medium) {
                Text(hint.body)
                if let note = hint.followUpNote {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let installHint = fullDiskAccessInstallHint {
                    Label {
                        Text(installHint.message)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(StatusTone.attention.color)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 480, alignment: .leading)
                    .accessibilityElement(children: .combine)
                } else if hint.requiresStableFullDiskAccessApp,
                          let reminder = FullDiskAccessInstallHint.stableGrantReminder {
                    Label {
                        Text(reminder)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(StatusTone.attention.color)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 480, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 480)
        } actions: {
            VStack(spacing: Tokens.Spacing.small) {
                if let installHint = fullDiskAccessInstallHint,
                   installHint.stableAppInstalled {
                    Button {
                        switchToStableApp(installHint.stableAppURL)
                    } label: {
                        Label(
                            FullDiskAccessInstallHint.switchToStableAppButtonTitle,
                            systemImage: "app.dashed"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else if let installHint = fullDiskAccessInstallHint,
                          installHint.canInstallStableApp {
                    Button {
                        installStableApp(installHint.stableAppURL)
                    } label: {
                        Label(
                            FullDiskAccessInstallHint.installStableAppButtonTitle,
                            systemImage: "square.and.arrow.down"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else if hint.requiresStableFullDiskAccessApp,
                          FullDiskAccessInstallHint.stableGrantReminder != nil {
                    Button {
                        revealStableApp()
                    } label: {
                        Label(
                            FullDiskAccessInstallHint.revealStableAppButtonTitle,
                            systemImage: "folder"
                        )
                    }
                    .buttonStyle(.bordered)
                }

                if fullDiskAccessInstallHint == nil ||
                    fullDiskAccessInstallHint?.canInstallStableApp == false,
                   let url = hint.settingsURL {
                    Button {
                        NSWorkspace.shared.open(url)
                        env.eventLog.info(
                            "\(sourceID).open_settings",
                            source: .ui
                        )
                    } label: {
                        Label(hint.settingsButtonTitle, systemImage: "gear")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                Button {
                    checkAgain()
                } label: {
                    Label("Check again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .navigationTitle(displayName)
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            checkAgain()
        }
        .task(id: hint.requiresStableFullDiskAccessApp) {
            guard hint.requiresStableFullDiskAccessApp else { return }
            await pollFullDiskAccessGrant()
        }
    }

    private func checkAgain() {
        if clearFullDiskAccessBlockIfGranted() {
            return
        }

        env.sources.syncNow(id: sourceID)
    }

    @MainActor
    private func clearFullDiskAccessBlockIfGranted() -> Bool {
        guard env.sources.statusPublisher(for: sourceID)?.displayedState().requiresFullDiskAccess == true,
              FullDiskAccessProbe.isGranted()
        else {
            return false
        }

        env.onboarding.recordFullDiskAccessGranted()
        env.sources.syncFullDiskAccessBlockedSources()
        return true
    }

    private func pollFullDiskAccessGrant() async {
        while !Task.isCancelled {
            if clearFullDiskAccessBlockIfGranted() {
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func switchToStableApp(_ appURL: URL) {
        FullDiskAccessInstallHint.switchToStableDevelopmentApp(
            appURL,
            eventLog: env.eventLog,
            eventName: "\(sourceID).open_stable_app"
        )
    }

    private func installStableApp(_ appURL: URL) {
        FullDiskAccessInstallHint.installStableDevelopmentApp(
            to: appURL,
            eventLog: env.eventLog,
            eventName: "\(sourceID).install_stable_app"
        )
    }

    private func revealStableApp() {
        FullDiskAccessInstallHint.revealStableDevelopmentApp(
            eventLog: env.eventLog,
            eventName: "\(sourceID).reveal_stable_app"
        )
    }

    private var fullDiskAccessInstallHint: FullDiskAccessInstallHint.Detail? {
        guard hint.requiresStableFullDiskAccessApp else { return nil }
        return FullDiskAccessInstallHint.current()
    }
}
