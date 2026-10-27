import SwiftUI

/// Detail pane for the Contacts source.
struct ContactsDetailView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        SourceDetailScaffold(
            sourceID: "contacts",
            displayName: "Contacts",
            stats: stats,
            activity: SourceActivityRow.recent(from: publisher),
            syncedItemSingular: "contact",
            syncedItemPlural: "contacts",
            emptyDescription: "After the first Contacts check, this view shows recent contact sync activity and recent checks."
        )
    }

    private var publisher: SourceStatusPublisher? {
        env.sources.statusPublisher(for: "contacts")
    }

    private var stats: [SourceStat] {
        let pub = publisher
        return [
            SourceStat(id: "today", title: "Today", value: SourceStat.format(pub?.acceptedToday), caption: "contacts merged"),
            SourceStat(id: "total", title: SourceDetailCopy.totalSyncedTitle, value: SourceStat.format(pub?.totalAccepted), caption: SourceDetailCopy.totalSyncedCaption),
            SourceStat(id: "last", title: SourceDetailCopy.lastCheckTitle, value: SourceStat.format(pub?.lastBatchAccepted), caption: SourceDetailCopy.lastBatchSyncedCaption),
            SourceStat(id: "already_synced", title: SourceDetailCopy.alreadySyncedTitle, value: SourceStat.format(pub?.lastBatchDuplicate), caption: SourceDetailCopy.alreadySyncedCaption),
            SourceStat(id: "last_sync", title: SourceDetailCopy.lastSyncTitle, value: SourceStat.relative(pub?.lastSyncAt), caption: SourceDetailCopy.lastSyncCaption)
        ]
    }
}
