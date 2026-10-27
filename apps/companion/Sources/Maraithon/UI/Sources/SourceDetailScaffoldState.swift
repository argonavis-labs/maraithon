import SwiftUI

/// Derived state for `SourceDetailScaffold`.
extension SourceDetailScaffold {
    var publisher: SourceStatusPublisher? {
        env.sources.statusPublisher(for: sourceID)
    }

    var isPaused: Bool {
        guard let publisher else {
            return false
        }
        if case .paused = publisher.state { return true }
        return false
    }

    var needsAttentionReason: String? {
        guard let publisher else {
            return nil
        }
        if case .needsAttention(let reason) = publisher.state {
            return reason
        }
        if case .error(let reason) = publisher.displayedState(),
           SourcePermissionHint.hasFocusedUnblock(for: reason) {
            return reason
        }
        return nil
    }

    var errorReason: String? {
        guard let publisher else {
            return nil
        }
        if case .error(let reason) = publisher.displayedState() {
            return reason
        }
        return nil
    }

    var activeIssue: SourceStatusPublisher.IssueEvent? {
        publisher?.activeIssue
    }

    var blockingIssue: SourceStatusPublisher.IssueEvent? {
        publisher?.activeBlockingIssue
    }

    var isWaitingForFirstSync: Bool {
        guard let publisher else {
            return false
        }
        return SourceDetailCopy.isWaitingForFirstSync(
            state: publisher.state,
            lastSyncAt: publisher.lastSyncAt
        )
    }

    var liveBadgeState: SourceStatusBadge.State {
        guard let publisher else {
            return .disconnected
        }
        switch publisher.displayedState() {
        case .connected: return .connected
        case .syncing: return .syncing
        case .paused: return .paused
        case .disconnected: return .disconnected
        case .needsAttention(let reason): return .needsAttention(reason)
        case .error(let reason): return .error(reason)
        }
    }
}
