import Foundation

/// Product copy shared by per-source detail panes.
///
/// Keeps user-facing source metrics in outcome language instead of
/// sync-engine vocabulary like "accepted" or "duplicates."
enum SourceDetailCopy {
    static let capabilitiesSectionTitle = "Assistant coverage"
    static let privacySectionTitle = "Privacy guardrails"
    static let activitySectionTitle = "Activity"
    static let recentChecksSectionTitle = "Recent checks"
    static let lastCheckTitle = "Last check"
    static let lastBatchSyncedCaption = "synced"
    static let alreadySyncedTitle = "Already known"
    static let alreadySyncedCaption = "last check"
    static let notSyncedTitle = "Needs attention"
    static let notSyncedCaption = "last check"
    static let totalSyncedTitle = "Total synced"
    static let totalSyncedCaption = "all time"
    static let lastSyncTitle = "Last checked"
    static let lastSyncCaption = "successful check"
    static let firstSyncTitle = "Ready for first sync"

    static func healthyHeadline(
        displayName: String,
        totalSynced: Int,
        singular _: String,
        plural _: String
    ) -> String {
        if totalSynced > 0 {
            return "Maraithon can use \(displayName)"
        }

        return "Maraithon is checking \(displayName)"
    }

    static func itemNoun(total: Int, singular: String, plural: String) -> String {
        total == 1 ? singular : plural
    }

    static func countedItem(_ count: Int, singular: String, plural: String) -> String {
        "\(count.formatted(.number)) \(itemNoun(total: count, singular: singular, plural: plural))"
    }

    static func connectedSummary(
        displayName: String,
        totalSynced: Int,
        lastCheckSynced: Int,
        lastCheckAlreadySynced: Int,
        lastCheckNotSynced: Int,
        lastSyncAt: Date?,
        singular: String,
        plural: String,
        relativeTo now: Date = Date()
    ) -> String {
        guard let lastSyncAt else {
            if totalSynced > 0 {
                return "Maraithon has synced \(countedItem(totalSynced, singular: singular, plural: plural)) so far. Check now to look for new \(plural)."
            }
            return "Check now to start syncing \(displayName)."
        }

        var sentences: [String] = []
        let hasUnfinishedItems = lastCheckNotSynced > 0
        if lastCheckSynced > 0 {
            sentences.append("Last check found and synced \(countedItem(lastCheckSynced, singular: singular, plural: plural)).")
        } else if hasUnfinishedItems {
            let verb = lastCheckNotSynced == 1 ? "needs" : "need"
            sentences.append("Last check found \(countedItem(lastCheckNotSynced, singular: singular, plural: plural)) that \(verb) attention.")
        } else if lastCheckAlreadySynced > 0 || totalSynced > 0 {
            sentences.append("No new \(plural) found.")
        } else {
            sentences.append("No \(plural) found yet.")
        }

        if hasUnfinishedItems {
            if lastCheckSynced > 0 {
                let verb = lastCheckNotSynced == 1 ? "needs" : "need"
                sentences.append("\(countedItem(lastCheckNotSynced, singular: singular, plural: plural)) \(verb) attention.")
            } else {
                sentences.append("Maraithon will retry on the next check.")
            }
        } else {
            sentences.append("Maraithon will keep checking in the background.")
        }

        sentences.append("Checked \(relativeSyncTime(lastSyncAt, relativeTo: now)).")
        return sentences.joined(separator: " ")
    }

    static func firstSyncDescription(displayName: String) -> String {
        "Maraithon is ready to sync \(displayName), but the first check has not finished yet. Sync now starts it immediately; otherwise it will begin automatically within a few minutes."
    }

    static func isWaitingForFirstSync(state: SourceState, lastSyncAt: Date?) -> Bool {
        guard lastSyncAt == nil else { return false }
        if case .connected = state {
            return true
        }
        return false
    }

    static func relativeSyncTime(_ date: Date, relativeTo now: Date = Date()) -> String {
        let distance = date.timeIntervalSince(now)
        if abs(distance) < 60 {
            return "just now"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
