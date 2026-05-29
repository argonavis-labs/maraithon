import SwiftUI

/// Detail pane for the Browser History source. Stats and recent activity
/// read from the live `SourceStatusPublisher` so the user sees real
/// numbers as batches land.
struct BrowserHistoryDetailView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        SourceDetailScaffold(
            sourceID: "browser_history",
            displayName: "Browser History",
            stats: stats,
            activity: SourceActivityRow.recent(from: publisher),
            syncedItemSingular: "visit",
            syncedItemPlural: "visits",
            emptyDescription: "After the first Browser History sync, this view shows recent visits and sync history.",
            clearDataDescription: "This deletes every browser visit synced from this Mac from Maraithon's synced copy. Your browser's own history is not affected."
        )
    }

    private var publisher: SourceStatusPublisher? {
        env.sources.statusPublisher(for: "browser_history")
    }

    private var stats: [SourceStat] {
        let pub = publisher
        return [
            SourceStat(id: "today", title: "Today", value: SourceStat.format(pub?.acceptedToday), caption: "visits synced"),
            SourceStat(id: "last", title: SourceDetailCopy.lastCheckTitle, value: SourceStat.format(pub?.lastBatchAccepted), caption: SourceDetailCopy.lastBatchSyncedCaption),
            SourceStat(id: "already_synced", title: SourceDetailCopy.alreadySyncedTitle, value: SourceStat.format(pub?.lastBatchDuplicate), caption: SourceDetailCopy.alreadySyncedCaption),
            SourceStat(id: "total", title: "Synced", value: SourceStat.format(pub?.totalAccepted), caption: SourceDetailCopy.totalSyncedCaption)
        ]
    }
}
