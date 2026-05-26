import SwiftUI

/// Detail pane for the Reminders source. Stats and recent activity read
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
            emptyDescription: "Once your first Reminders batch finishes, this view will show today's reminder rollups and recent sync runs.",
            clearDataDescription: "This deletes every Reminder Maraithon has synced from this Mac out of the cloud. The Reminders app on your device is not affected."
        )
    }

    private var publisher: SourceStatusPublisher? {
        env.sources.statusPublisher(for: "reminders")
    }

    private var stats: [SourceStat] {
        let pub = publisher
        return [
            SourceStat(id: "today", title: "Today", value: SourceStat.format(pub?.acceptedToday), caption: "reminders synced"),
            SourceStat(id: "last", title: "Last batch", value: SourceStat.format(pub?.lastBatchAccepted), caption: "accepted"),
            SourceStat(id: "dupes", title: "Duplicates", value: SourceStat.format(pub?.lastBatchDuplicate), caption: "skipped this batch"),
            SourceStat(id: "total", title: "Total synced", value: SourceStat.format(pub?.totalAccepted), caption: "since app launch")
        ]
    }
}
