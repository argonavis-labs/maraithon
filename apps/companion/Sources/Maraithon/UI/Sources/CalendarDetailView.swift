import SwiftUI

/// Detail pane for the Calendar Events source. Stats and recent activity
/// read from the live `SourceStatusPublisher` so the user sees real
/// numbers as batches land.
struct CalendarDetailView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        SourceDetailScaffold(
            sourceID: "calendar",
            displayName: "Calendar",
            stats: stats,
            activity: SourceActivityRow.recent(from: publisher),
            syncedItemSingular: "event",
            syncedItemPlural: "events",
            emptyDescription: "After the first Calendar sync, this view shows recent event activity and sync history.",
            clearDataDescription: "This deletes every event synced from this Mac from Maraithon's synced copy. The Calendar app on your device is not affected."
        )
    }

    private var publisher: SourceStatusPublisher? {
        env.sources.statusPublisher(for: "calendar")
    }

    private var stats: [SourceStat] {
        let pub = publisher
        return [
            SourceStat(id: "today", title: "Today", value: SourceStat.format(pub?.acceptedToday), caption: "events synced"),
            SourceStat(id: "last", title: SourceDetailCopy.lastCheckTitle, value: SourceStat.format(pub?.lastBatchAccepted), caption: SourceDetailCopy.lastBatchSyncedCaption),
            SourceStat(id: "already_synced", title: SourceDetailCopy.alreadySyncedTitle, value: SourceStat.format(pub?.lastBatchDuplicate), caption: SourceDetailCopy.alreadySyncedCaption),
            SourceStat(id: "total", title: "Synced", value: SourceStat.format(pub?.totalAccepted), caption: SourceDetailCopy.totalSyncedCaption)
        ]
    }
}
