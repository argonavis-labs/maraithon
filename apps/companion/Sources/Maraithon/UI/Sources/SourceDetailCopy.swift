import Foundation

/// Product copy shared by per-source detail panes.
///
/// Keeps user-facing source metrics in outcome language instead of
/// sync-engine vocabulary like "accepted" or "duplicates."
enum SourceDetailCopy {
    static let capabilitiesSectionTitle = "What your assistant can use"
    static let privacySectionTitle = "Control and privacy"
    static let activitySectionTitle = "Available context"
    static let recentChecksSectionTitle = "Check history"
    static let recentChecksEmptyTitle = "Waiting for first check"
    static let checkNowButtonTitle = "Check now"
    static let resumeUpdatesButtonTitle = "Resume updates"
    static let pauseUpdatesButtonTitle = "Pause updates"
    static let lastCheckTitle = "Last check"
    static let lastBatchSyncedCaption = "new this check"
    static let alreadySyncedTitle = "Already known"
    static let alreadySyncedCaption = "last check"
    static let notSyncedTitle = "Need another check"
    static let notSyncedCaption = "last check"
    static let totalSyncedTitle = "Assistant context"
    static let totalSyncedCaption = "available now"
    static let lastSyncTitle = "Last checked"
    static let lastSyncCaption = "successful check"
    static let firstSyncTitle = "Ready for first check"
    static let issueErrorTitle = "Last check failed"
    static let resetSourceButtonTitle = "Check from the beginning"

    static func healthyHeadline(
        displayName: String,
        totalSynced: Int,
        singular _: String,
        plural _: String
    ) -> String {
        if totalSynced > 0 {
            return "\(displayName) context is ready"
        }

        return "\(displayName) is ready for its first check"
    }

    static func pausedHeadline(displayName: String) -> String {
        "\(displayName) updates are paused"
    }

    static func pausedSummary(displayName: String, plural: String) -> String {
        "Resume updates when you want \(displayName) to check for new \(plural) again."
    }

    static func unavailablePublisherSummary(displayName: String) -> String {
        "Open Maraithon on this Mac to make \(displayName) available to your assistant."
    }

    static func errorHeadline(displayName: String) -> String {
        "\(displayName) could not be checked"
    }

    static func disconnectedHeadline(displayName: String) -> String {
        "\(displayName) is not updating"
    }

    static func itemNoun(total: Int, singular: String, plural: String) -> String {
        total == 1 ? singular : plural
    }

    static func countedItem(_ count: Int, singular: String, plural: String) -> String {
        "\(count.formatted(.number)) \(itemNoun(total: count, singular: singular, plural: plural))"
    }

    static func issueAttentionTitle(plural: String) -> String {
        "Some \(plural) need another check"
    }

    static func failedItemsLine(_ count: Int, singular: String, plural: String) -> String {
        let verb = count == 1 ? "needs" : "need"
        return "\(countedItem(count, singular: singular, plural: plural)) \(verb) another check."
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
            return "Check now to make \(displayName) context available to your assistant."
        }

        var sentences: [String] = []
        let hasUnfinishedItems = lastCheckNotSynced > 0
        if lastCheckSynced > 0 {
            let added = countedItem(lastCheckSynced, singular: singular, plural: plural)
            if totalSynced > lastCheckSynced {
                let total = countedItem(totalSynced, singular: singular, plural: plural)
                sentences.append("Added \(added) on the last check. Your assistant now has \(total) available.")
            } else {
                sentences.append("Added \(added) on the last check and made \(lastCheckSynced == 1 ? "it" : "them") available to your assistant.")
            }
        } else if hasUnfinishedItems {
            let verb = lastCheckNotSynced == 1 ? "needs" : "need"
            sentences.append("Last check found \(countedItem(lastCheckNotSynced, singular: singular, plural: plural)) that \(verb) another check.")
        } else if lastCheckAlreadySynced > 0 || totalSynced > 0 {
            if totalSynced > 0 {
                sentences.append("No new \(displayName) context on the last check. Your assistant still has \(countedItem(totalSynced, singular: singular, plural: plural)) available.")
            } else {
                sentences.append("No new \(displayName) context on the last check.")
            }
        } else {
            sentences.append("No \(displayName) context was available on the last check.")
        }

        if hasUnfinishedItems {
            if lastCheckSynced > 0 {
                sentences.append(failedItemsLine(lastCheckNotSynced, singular: singular, plural: plural))
            } else {
                sentences.append("Maraithon will retry on the next check.")
            }
        } else if totalSynced == 0 && lastCheckSynced == 0 && lastCheckAlreadySynced == 0 {
            sentences.append("Maraithon will keep checking.")
        } else {
            sentences.append("Maraithon will keep checking for new context.")
        }

        sentences.append("Checked \(relativeSyncTime(lastSyncAt, relativeTo: now)).")
        return sentences.joined(separator: " ")
    }

    static func firstSyncDescription(displayName: String) -> String {
        "Maraithon is ready to check \(displayName) for assistant context. Check now starts the first check immediately; otherwise it will begin automatically within a few minutes."
    }

    static func isWaitingForFirstSync(state: SourceState, lastSyncAt: Date?) -> Bool {
        guard lastSyncAt == nil else { return false }
        if case .connected = state {
            return true
        }
        return false
    }

    static func relativeSyncTime(_ date: Date, relativeTo now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 {
            return "just now"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
