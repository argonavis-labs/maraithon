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
    static let lastBatchSyncedCaption = "new this check"
    static let alreadySyncedTitle = "Already known"
    static let alreadySyncedCaption = "last check"
    static let notSyncedTitle = "Needs attention"
    static let notSyncedCaption = "last check"
    static let totalSyncedTitle = "Assistant context"
    static let totalSyncedCaption = "available now"
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
            return "\(displayName) is available to your assistant"
        }

        return "Checking \(displayName) for assistant context"
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
                return "Your assistant has \(countedItem(totalSynced, singular: singular, plural: plural)) available. Check now to look for anything new."
            }
            return "Check now to make \(displayName) available to your assistant."
        }

        var sentences: [String] = []
        let hasUnfinishedItems = lastCheckNotSynced > 0
        if lastCheckSynced > 0 {
            let added = countedItem(lastCheckSynced, singular: singular, plural: plural)
            if totalSynced > lastCheckSynced {
                let total = countedItem(totalSynced, singular: singular, plural: plural)
                sentences.append("Last check added \(added), bringing \(total) into assistant context.")
            } else {
                sentences.append("Last check added \(added) to assistant context.")
            }
        } else if hasUnfinishedItems {
            let verb = lastCheckNotSynced == 1 ? "needs" : "need"
            sentences.append("Last check found \(countedItem(lastCheckNotSynced, singular: singular, plural: plural)) that \(verb) attention.")
        } else if lastCheckAlreadySynced > 0 || totalSynced > 0 {
            sentences.append("No new \(plural) since the last check.")
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
            sentences.append("Your assistant will keep this context current.")
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
