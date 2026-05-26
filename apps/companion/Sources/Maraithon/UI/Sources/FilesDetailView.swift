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
            emptyDescription: "Once your first Files batch finishes, this view will show indexed-document rollups and recent sync runs.",
            clearDataDescription: "This deletes every file record Maraithon has synced from this Mac out of the cloud. The files on your disk are not affected."
        )
    }

    private var publisher: SourceStatusPublisher? {
        env.sources.statusPublisher(for: "files")
    }

    private var stats: [SourceStat] {
        let pub = publisher
        return [
            SourceStat(id: "today", title: "Today", value: SourceStat.format(pub?.acceptedToday), caption: "files indexed"),
            SourceStat(id: "last", title: "Last batch", value: SourceStat.format(pub?.lastBatchAccepted), caption: "accepted"),
            SourceStat(id: "dupes", title: "Duplicates", value: SourceStat.format(pub?.lastBatchDuplicate), caption: "skipped this batch"),
            SourceStat(id: "total", title: "Total synced", value: SourceStat.format(pub?.totalAccepted), caption: "since app launch")
        ]
    }
}
