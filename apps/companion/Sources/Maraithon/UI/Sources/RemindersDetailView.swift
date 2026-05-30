import SwiftUI

/// Detail pane for the Reminders source. Activity and recent checks read
/// from the live `SourceStatusPublisher` so the user sees real numbers
/// as batches land.
struct RemindersDetailView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        SourceDetailScaffold(
            sourceID: "reminders",
            displayName: "Reminders",
            stats: stats,
            activity: SourceActivityRow.recent(from: publisher),
            syncedItemSingular: "reminder",
            syncedItemPlural: "reminders",
            emptyDescription: "After the first Reminders check, this view shows recent reminder activity and recent checks."
        )
    }

    private var publisher: SourceStatusPublisher? {
        env.sources.statusPublisher(for: "reminders")
    }

    private var stats: [SourceStat] {
        let pub = publisher
        return [
            SourceStat(id: "today", title: "Today", value: SourceStat.format(pub?.acceptedToday), caption: "reminders added"),
            SourceStat(id: "total", title: SourceDetailCopy.totalSyncedTitle, value: SourceStat.format(pub?.totalAccepted), caption: SourceDetailCopy.totalSyncedCaption),
            SourceStat(id: "last", title: SourceDetailCopy.lastCheckTitle, value: SourceStat.format(pub?.lastBatchAccepted), caption: SourceDetailCopy.lastBatchSyncedCaption),
            SourceStat(id: "already_synced", title: SourceDetailCopy.alreadySyncedTitle, value: SourceStat.format(pub?.lastBatchDuplicate), caption: SourceDetailCopy.alreadySyncedCaption),
            SourceStat(id: "last_sync", title: SourceDetailCopy.lastSyncTitle, value: SourceStat.relative(pub?.lastSyncAt), caption: SourceDetailCopy.lastSyncCaption)
        ]
    }
}
