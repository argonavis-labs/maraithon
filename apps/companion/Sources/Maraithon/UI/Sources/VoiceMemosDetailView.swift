import SwiftUI

/// Detail pane for the Voice Memos source. Stats and recent activity
/// read from the live `SourceStatusPublisher` so the user sees real
/// numbers as batches land.
struct VoiceMemosDetailView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        SourceDetailScaffold(
            sourceID: "voice_memos",
            displayName: "Voice Memos",
            stats: stats,
            activity: SourceActivityRow.recent(from: publisher),
            emptyDescription: "Once your first Voice Memos batch finishes, this view will show today's memo rollups and recent sync runs.",
            clearDataDescription: "This deletes every Voice Memo Maraithon has synced from this Mac out of the cloud. The Voice Memos app on your device is not affected."
        )
    }

    private var publisher: SourceStatusPublisher? {
        env.sources.statusPublisher(for: "voice_memos")
    }

    private var stats: [SourceStat] {
        let pub = publisher
        return [
            SourceStat(id: "today", title: "Today", value: SourceStat.format(pub?.acceptedToday), caption: "memos synced"),
            SourceStat(id: "last", title: "Last batch", value: SourceStat.format(pub?.lastBatchAccepted), caption: "accepted"),
            SourceStat(id: "dupes", title: "Duplicates", value: SourceStat.format(pub?.lastBatchDuplicate), caption: "skipped this batch"),
            SourceStat(id: "total", title: "Total synced", value: SourceStat.format(pub?.totalAccepted), caption: "since app launch")
        ]
    }
}
