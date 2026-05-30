import SwiftUI

/// Detail pane for the iMessage source. Reads live sync health from the
/// shared publisher so green, yellow, and red sidebar states drill into
/// the same actionable status surface as Notes and Voice Memos.
struct IMessageDetailView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        SourceDetailScaffold(
            sourceID: "imessage",
            displayName: "iMessage",
            stats: stats,
            activity: SourceActivityRow.recent(from: publisher),
            syncedItemSingular: "message",
            syncedItemPlural: "messages",
            emptyDescription: "After the first iMessage check, this view shows recent message activity and recent checks.",
            clearDataDescription: "This deletes every message synced from this Mac from Maraithon's synced copy. Messages.app history on your device is not affected."
        )
    }

    private var publisher: SourceStatusPublisher? {
        env.sources.statusPublisher(for: "imessage")
    }

    private var stats: [SourceStat] {
        let pub = publisher
        return [
            SourceStat(id: "today", title: "Today", value: SourceStat.format(pub?.acceptedToday), caption: "messages synced"),
            SourceStat(id: "last", title: SourceDetailCopy.lastCheckTitle, value: SourceStat.format(pub?.lastBatchAccepted), caption: SourceDetailCopy.lastBatchSyncedCaption),
            SourceStat(id: "not_synced", title: SourceDetailCopy.notSyncedTitle, value: SourceStat.format(pub?.lastBatchFailed), caption: SourceDetailCopy.notSyncedCaption),
            SourceStat(id: "last_sync", title: SourceDetailCopy.lastSyncTitle, value: SourceStat.relative(pub?.lastSyncAt), caption: SourceDetailCopy.lastSyncCaption)
        ]
    }
}
