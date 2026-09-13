import SwiftUI
import AppKit

/// Focused card shown under the source header when a source is in
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
        SourceIssueCard(
            dotColor: Tokens.Palette.caution,
            title: hint.title,
            message: hint.body,
            notes: hint.followUpNote.map { [$0] } ?? [],
            extra: { installReminder },
            actions: { actionButtons }
        )
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            checkAgain()
        }
        .task(id: hint.requiresStableFullDiskAccessApp) {
            guard hint.requiresStableFullDiskAccessApp else { return }
            await pollFullDiskAccessGrant()
        }
    }

    @ViewBuilder
    private var installReminder: some View {
        if let installHint = fullDiskAccessInstallHint {
            reminderLine(installHint.message)
        } else if hint.requiresStableFullDiskAccessApp,
                  let reminder = FullDiskAccessInstallHint.stableGrantReminder {
            reminderLine(reminder)
        }
    }

    private func reminderLine(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Tokens.Typography.small)
                .foregroundStyle(Tokens.Palette.caution)
                .accessibilityHidden(true)
            Text(message)
                .font(Tokens.Typography.small)
                .foregroundStyle(Tokens.Palette.cautionText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if let installHint = fullDiskAccessInstallHint,
           installHint.stableAppInstalled {
            Button {
                switchToStableApp(installHint.stableAppURL)
            } label: {
                buttonLabel(FullDiskAccessInstallHint.switchToStableAppButtonTitle, symbol: "app.dashed")
            }
            .buttonStyle(RunnerButtonStyle(.primary))
            .keyboardShortcut(.defaultAction)
        } else if let installHint = fullDiskAccessInstallHint,
                  installHint.canInstallStableApp {
            Button {
                installStableApp(installHint.stableAppURL)
            } label: {
                buttonLabel(FullDiskAccessInstallHint.installStableAppButtonTitle, symbol: "square.and.arrow.down")
            }
            .buttonStyle(RunnerButtonStyle(.primary))
            .keyboardShortcut(.defaultAction)
        } else if hint.requiresStableFullDiskAccessApp,
                  FullDiskAccessInstallHint.stableGrantReminder != nil {
            Button {
                revealStableApp()
            } label: {
                buttonLabel(FullDiskAccessInstallHint.revealStableAppButtonTitle, symbol: "folder")
            }
            .buttonStyle(RunnerButtonStyle(.secondary))
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
                buttonLabel(hint.settingsButtonTitle, symbol: "gear")
            }
            .buttonStyle(RunnerButtonStyle(.primary))
            .keyboardShortcut(.defaultAction)
        }

        Button {
            checkAgain()
        } label: {
            buttonLabel("Check again", symbol: "arrow.clockwise")
        }
        .buttonStyle(RunnerButtonStyle(.secondary))
        .keyboardShortcut("r", modifiers: .command)
    }

    private func buttonLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: Tokens.Spacing.compact) {
            Image(systemName: symbol)
                .accessibilityHidden(true)
            Text(title)
        }
    }

    private func checkAgain() {
        if verifyFullDiskAccessGrant() {
            return
        }

        if hint.requiresStableFullDiskAccessApp {
            env.eventLog.info(
                "\(sourceID).full_disk_access_check_still_blocked",
                source: .ui
            )
            env.sources.syncNow(id: sourceID)
            return
        }

        env.sources.syncNow(id: sourceID)
    }

    @MainActor
    private func verifyFullDiskAccessGrant() -> Bool {
        guard env.sources.statusPublisher(for: sourceID)?.fullDiskAccessBlockReason != nil,
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
            if verifyFullDiskAccessGrant() {
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
