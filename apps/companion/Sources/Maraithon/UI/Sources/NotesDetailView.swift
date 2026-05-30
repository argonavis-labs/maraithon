import SwiftUI

/// Detail pane for the Apple Notes source. Activity and recent checks
/// read from the live `SourceStatusPublisher` so the user sees real
/// numbers as batches land.
struct NotesDetailView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        SourceDetailScaffold(
            sourceID: "notes",
            displayName: "Notes",
            stats: stats,
            activity: SourceActivityRow.recent(from: publisher),
            syncedItemSingular: "note",
            syncedItemPlural: "notes",
            emptyDescription: "After the first Notes check, this view shows recent note activity and recent checks."
        )
    }

    private var publisher: SourceStatusPublisher? {
        env.sources.statusPublisher(for: "notes")
    }

    private var stats: [SourceStat] {
        let pub = publisher
        return [
            SourceStat(id: "today", title: "Today", value: SourceStat.format(pub?.acceptedToday), caption: "notes added"),
            SourceStat(id: "total", title: SourceDetailCopy.totalSyncedTitle, value: SourceStat.format(pub?.totalAccepted), caption: SourceDetailCopy.totalSyncedCaption),
            SourceStat(id: "last", title: SourceDetailCopy.lastCheckTitle, value: SourceStat.format(pub?.lastBatchAccepted), caption: SourceDetailCopy.lastBatchSyncedCaption),
            SourceStat(id: "not_synced", title: SourceDetailCopy.notSyncedTitle, value: SourceStat.format(pub?.lastBatchFailed), caption: SourceDetailCopy.notSyncedCaption),
            SourceStat(id: "last_sync", title: SourceDetailCopy.lastSyncTitle, value: SourceStat.relative(pub?.lastSyncAt), caption: SourceDetailCopy.lastSyncCaption)
        ]
    }
}
