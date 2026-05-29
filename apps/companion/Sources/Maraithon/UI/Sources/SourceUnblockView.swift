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
                        Text(installHint)
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
                if let url = hint.settingsURL {
                    Button {
                        NSWorkspace.shared.open(url)
                        env.eventLog.info(
                            "\(sourceID).open_settings",
                            source: .ui
                        )
                    } label: {
                        Label("Open System Settings", systemImage: "gear")
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
    }

    private func checkAgain() {
        if env.sources.statusPublisher(for: sourceID)?.displayedState().requiresFullDiskAccess == true,
           FullDiskAccessProbe.isGranted() {
            env.onboarding.recordFullDiskAccessGranted()
            env.sources.syncFullDiskAccessBlockedSources()
        } else {
            env.sources.syncNow(id: sourceID)
        }
    }

    private var fullDiskAccessInstallHint: String? {
        guard hint.requiresStableFullDiskAccessApp else { return nil }
        return FullDiskAccessInstallHint.currentMessage()
    }
}
