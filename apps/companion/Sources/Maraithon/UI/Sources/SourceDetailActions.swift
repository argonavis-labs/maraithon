import SwiftUI

/// Header actions on a healthy source page: Check now (or Resume updates
/// while paused) and Pause updates. Both are secondary buttons; Cmd-R
/// triggers the first so the shortcut matches the unblock card.
struct SourceDetailActions: View {
    @Environment(AppEnvironment.self) private var env

    let sourceID: String
    let isPaused: Bool

    var body: some View {
        Button {
            if isPaused {
                env.sources.resume(id: sourceID)
            } else {
                env.sources.syncNow(id: sourceID)
            }
        } label: {
            HStack(spacing: Tokens.Spacing.compact) {
                Image(systemName: isPaused ? "play.fill" : "arrow.clockwise")
                    .accessibilityHidden(true)
                Text(isPaused ? SourceDetailCopy.resumeUpdatesButtonTitle : SourceDetailCopy.checkNowButtonTitle)
            }
        }
        .buttonStyle(RunnerButtonStyle(.secondary))
        .keyboardShortcut("r", modifiers: .command)

        if !isPaused {
            Button {
                env.sources.pause(id: sourceID)
            } label: {
                HStack(spacing: Tokens.Spacing.compact) {
                    Image(systemName: "pause.fill")
                        .accessibilityHidden(true)
                    Text(SourceDetailCopy.pauseUpdatesButtonTitle)
                }
            }
            .buttonStyle(RunnerButtonStyle(.secondary))
        }
    }
}
