import SwiftUI

/// Detail pane for the Files source. Stats and recent activity read from
/// the live `SourceStatusPublisher` so the user sees real numbers as
/// batches land.
struct FilesDetailView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        SourceDetailScaffold(
            sourceID: "files",
            displayName: "Files",
            stats: stats,
            activity: SourceActivityRow.recent(from: publisher),
            syncedItemSingular: "file",
            syncedItemPlural: "files",
            emptyDescription: "After the first Files sync, this view shows recently indexed files and sync history.",
            clearDataDescription: "This deletes every file record synced from this Mac from Maraithon's synced copy. The files on your disk are not affected."
        )
    }

    private var publisher: SourceStatusPublisher? {
        env.sources.statusPublisher(for: "files")
    }

    private var stats: [SourceStat] {
        let pub = publisher
        return [
            SourceStat(id: "today", title: "Today", value: SourceStat.format(pub?.acceptedToday), caption: "files indexed"),
            SourceStat(id: "last", title: SourceDetailCopy.lastCheckTitle, value: SourceStat.format(pub?.lastBatchAccepted), caption: SourceDetailCopy.lastBatchSyncedCaption),
            SourceStat(id: "already_synced", title: SourceDetailCopy.alreadySyncedTitle, value: SourceStat.format(pub?.lastBatchDuplicate), caption: SourceDetailCopy.alreadySyncedCaption),
            SourceStat(id: "last_sync", title: SourceDetailCopy.lastSyncTitle, value: SourceStat.relative(pub?.lastSyncAt), caption: SourceDetailCopy.lastSyncCaption)
        ]
    }
}
