import Foundation

/// Row in the recent checks table on a source detail pane.
struct SourceActivityRow: Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let count: Int
    let accepted: Int
    let duplicates: Int
    let failed: Int

    init(id: UUID = UUID(), timestamp: Date, count: Int, accepted: Int, duplicates: Int, failed: Int = 0) {
        self.id = id
        self.timestamp = timestamp
        self.count = count
        self.accepted = accepted
        self.duplicates = duplicates
        self.failed = failed
    }

    /// Build a recent-check list from a publisher's ring buffer, newest
    /// first, capped at `limit` rows.
    @MainActor
    static func recent(from publisher: SourceStatusPublisher?, limit: Int = 10) -> [SourceActivityRow] {
        publisher?.recentBatches.prefix(limit).map { event in
            SourceActivityRow(
                id: event.id,
                timestamp: event.timestamp,
                count: event.accepted + event.duplicate + event.failed,
                accepted: event.accepted,
                duplicates: event.duplicate,
                failed: event.failed
            )
        } ?? []
    }
}
