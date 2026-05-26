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
            emptyDescription: "Once your first Calendar batch finishes, this view will show event rollups and recent sync runs.",
            clearDataDescription: "This deletes every event Maraithon has synced from this Mac out of the cloud. The Calendar app on your device is not affected."
        )
    }

    private var publisher: SourceStatusPublisher? {
        env.sources.statusPublisher(for: "calendar")
    }

    private var stats: [SourceStat] {
        let pub = publisher
        return [
            SourceStat(id: "today", title: "Today", value: SourceStat.format(pub?.acceptedToday), caption: "events synced"),
            SourceStat(id: "last", title: "Last batch", value: SourceStat.format(pub?.lastBatchAccepted), caption: "accepted"),
            SourceStat(id: "dupes", title: "Duplicates", value: SourceStat.format(pub?.lastBatchDuplicate), caption: "skipped this batch"),
            SourceStat(id: "total", title: "Total synced", value: SourceStat.format(pub?.totalAccepted), caption: "since app launch")
        ]
    }
}
