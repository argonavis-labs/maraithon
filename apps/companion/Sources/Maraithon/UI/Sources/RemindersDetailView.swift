import SwiftUI

/// Detail pane for the Reminders source. Coverage and recent checks read
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
            emptyDescription: "After the first Reminders check, this view shows recent reminder activity and recent checks.",
            clearDataDescription: "This deletes every reminder synced from this Mac from Maraithon's synced copy. The Reminders app on your device is not affected."
        )
    }

    private var publisher: SourceStatusPublisher? {
        env.sources.statusPublisher(for: "reminders")
    }

    private var stats: [SourceStat] {
        let pub = publisher
        return [
            SourceStat(id: "today", title: "Today", value: SourceStat.format(pub?.acceptedToday), caption: "reminders synced"),
            SourceStat(id: "last", title: SourceDetailCopy.lastCheckTitle, value: SourceStat.format(pub?.lastBatchAccepted), caption: SourceDetailCopy.lastBatchSyncedCaption),
            SourceStat(id: "already_synced", title: SourceDetailCopy.alreadySyncedTitle, value: SourceStat.format(pub?.lastBatchDuplicate), caption: SourceDetailCopy.alreadySyncedCaption),
            SourceStat(id: "last_sync", title: SourceDetailCopy.lastSyncTitle, value: SourceStat.relative(pub?.lastSyncAt), caption: SourceDetailCopy.lastSyncCaption)
        ]
    }
}
