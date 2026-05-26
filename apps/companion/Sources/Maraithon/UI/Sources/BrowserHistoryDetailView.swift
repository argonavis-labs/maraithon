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
            emptyDescription: "Once your first Browser History batch finishes, this view will show today's visit rollups and recent sync runs.",
            clearDataDescription: "This deletes every browser visit Maraithon has synced from this Mac out of the cloud. Your browser's own history is not affected."
        )
    }

    private var publisher: SourceStatusPublisher? {
        env.sources.statusPublisher(for: "browser_history")
    }

    private var stats: [SourceStat] {
        let pub = publisher
        return [
            SourceStat(id: "today", title: "Today", value: SourceStat.format(pub?.acceptedToday), caption: "visits synced"),
            SourceStat(id: "last", title: "Last batch", value: SourceStat.format(pub?.lastBatchAccepted), caption: "accepted"),
            SourceStat(id: "dupes", title: "Duplicates", value: SourceStat.format(pub?.lastBatchDuplicate), caption: "skipped this batch"),
            SourceStat(id: "total", title: "Total synced", value: SourceStat.format(pub?.totalAccepted), caption: "since app launch")
        ]
    }
}
