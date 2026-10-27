import SwiftUI

/// A local Mac source in the sidebar with its live status as trailing text
/// (`now`, `2m`, `Checking`, `Review`). Uses `TimelineView` so recency
/// labels refresh on their own without the publisher firing.
struct SidebarSourceRow: View {
    @Environment(AppEnvironment.self) private var env
    let source: SourceDescriptor
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        let publisher = env.sources.statusPublisher(for: source.id)
        let liveState = publisher?.state ?? source.state
        let displayedState = publisher?.displayedState()
            ?? liveState.displayed(lastSyncAt: nil, shippedBatch: false)
        let lastSyncAt = publisher?.lastSyncAt

        TimelineView(.periodic(from: Date(), by: 30)) { context in
            SidebarNavRow(
                title: source.displayName,
                symbol: source.symbol,
                trailing: trailingText(rawState: liveState, displayedState: displayedState, lastSyncAt: lastSyncAt, now: context.date),
                trailingColor: trailingColor(rawState: liveState, displayedState: displayedState),
                isActive: isActive,
                action: action
            )
        }
        .accessibilityLabel(
            SourceRowCopy.accessibilityLabel(
                sourceName: source.displayName,
                comingSoon: source.comingSoon,
                rawState: liveState,
                displayedState: displayedState,
                lastSyncAt: lastSyncAt
            )
        )
        .help(
            SourceRowCopy.tooltip(
                comingSoon: source.comingSoon,
                state: liveState,
                activeIssueReason: publisher?.activeIssue?.reason,
                lastSyncAt: lastSyncAt
            )
        )
    }

    private func trailingText(rawState: SourceState, displayedState: SourceState, lastSyncAt: Date?, now: Date) -> String {
        if source.comingSoon { return SourceAvailabilityCopy.unavailableBadge }
        return SourceRowCopy.trailingStatus(
            rawState: rawState,
            displayedState: displayedState,
            lastSyncAt: lastSyncAt,
            now: now
        )
    }

    private func trailingColor(rawState: SourceState, displayedState: SourceState) -> Color {
        if source.comingSoon { return Tokens.Palette.mutedForeground }
        switch displayedState {
        case .needsAttention:
            return Tokens.Palette.cautionText
        case .error:
            return Tokens.Palette.destructiveText
        case .disconnected:
            if case .connected = rawState { return Tokens.Palette.mutedForeground }
            return Tokens.Palette.destructiveText
        default:
            return Tokens.Palette.mutedForeground
        }
    }
}
