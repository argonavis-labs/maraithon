import SwiftUI

/// Detail pane for the Voice Memos source. Coverage and recent checks
/// read from the live `SourceStatusPublisher` so the user sees real
/// numbers as batches land.
struct VoiceMemosDetailView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        SourceDetailScaffold(
            sourceID: "voice_memos",
            displayName: "Voice Memos",
            stats: stats,
            activity: SourceActivityRow.recent(from: publisher),
            syncedItemSingular: "memo",
            syncedItemPlural: "memos",
            emptyDescription: "After the first Voice Memos check, this view shows recent memo activity and recent checks.",
            clearDataDescription: "This deletes every voice memo synced from this Mac from Maraithon's synced copy. The Voice Memos app on your device is not affected."
        )
    }

    private var publisher: SourceStatusPublisher? {
        env.sources.statusPublisher(for: "voice_memos")
    }

    private var stats: [SourceStat] {
        let pub = publisher
        return [
            SourceStat(id: "today", title: "Today", value: SourceStat.format(pub?.acceptedToday), caption: "memos synced"),
            SourceStat(id: "last", title: SourceDetailCopy.lastCheckTitle, value: SourceStat.format(pub?.lastBatchAccepted), caption: SourceDetailCopy.lastBatchSyncedCaption),
            SourceStat(id: "not_synced", title: SourceDetailCopy.notSyncedTitle, value: SourceStat.format(pub?.lastBatchFailed), caption: SourceDetailCopy.notSyncedCaption),
            SourceStat(id: "last_sync", title: SourceDetailCopy.lastSyncTitle, value: SourceStat.relative(pub?.lastSyncAt), caption: SourceDetailCopy.lastSyncCaption)
        ]
    }
}
