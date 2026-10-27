import Foundation

/// Single stat tile shown in a source detail pane's activity grid.
struct SourceStat: Identifiable, Hashable {
    let id: String
    let title: String
    let value: String
    var caption: String? = nil

    init(id: String, title: String, value: String, caption: String? = nil) {
        self.id = id
        self.title = title
        self.value = value
        self.caption = caption
    }

    /// Format an integer counter from the publisher with a user-facing
    /// placeholder when the value is not available yet.
    static func format(_ n: Int?) -> String {
        guard let n else { return "Not yet" }
        return n.formatted()
    }

    /// Short relative date string from a publisher's `lastSyncAt`.
    /// Returns a user-facing placeholder when the source has not
    /// completed a sync yet.
    static func relative(_ date: Date?) -> String {
        guard let date else { return "Not yet" }
        return SourceDetailCopy.relativeSyncTime(date)
    }
}
