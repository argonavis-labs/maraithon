import Foundation
import Observation

/// Contract every connector implements so `SourceRegistry` can install,
/// start, pause, and surface state for it uniformly.
///
/// A source owns its own polling cadence, cursor, and payload shape. The
/// only thing it shares with the rest of the app is a `SyncEnvelope` it
/// emits via the `Outbox` closure passed in at construction time.
///
/// Implementations:
///   * are `Sendable` so they can hold non-`@MainActor` work
///   * publish state through `statusPublisher` (an `@Observable` proxy
///     readable from any actor)
///   * are idempotent on `start()` / `pause()` / `clearLocalState()`
@MainActor
protocol SourceProtocol: AnyObject {
    /// Stable identifier, e.g. `"imessage"`. Matches `SourceDescriptor.id`.
    var id: String { get }

    /// Human-readable label, e.g. `"iMessage"`.
    var displayName: String { get }

    /// SF Symbol name used by the sidebar row.
    var symbol: String { get }

    /// Observable status object the UI binds to.
    var statusPublisher: SourceStatusPublisher { get }

    /// Begin polling. Idempotent.
    func start()

    /// Stop polling but keep the cursor.
    func pause()

    /// Force an immediate sync cycle, regardless of cadence. Errors are
    /// logged and surfaced via `statusPublisher`; the call resolves once
    /// the cycle finishes.
    func syncNow() async throws

    /// Drop the local cursor + any persisted state. Does not touch cloud
    /// data — that's the cloud's responsibility via the destructive UI
    /// action.
    func clearLocalState()
}

/// Closure a source invokes to hand built envelopes off to the sync
/// engine. The engine owns batching, retry, and backoff; the source just
/// emits and trusts the engine to do the rest. Returns the aggregate
/// `SyncOutcome` from the underlying push so the source can record the
/// *server's* accepted/duplicate counts rather than a local guess.
typealias SourceOutbox = @Sendable ([SyncEnvelope]) async throws -> SyncOutcome

/// `@Observable` wrapper around `SourceState` so non-main-actor sources
/// can publish status without dragging the whole source onto the main
/// actor.
@Observable
@MainActor
final class SourceStatusPublisher {
    private(set) var state: SourceState
    private(set) var lastSyncAt: Date?
    private(set) var lastBatchAccepted: Int = 0
    private(set) var lastBatchDuplicate: Int = 0
    private(set) var lastBatchFailed: Int = 0
    /// Running totals since app launch. Detail panes surface these as
    /// "Total synced" / "Total duplicate".
    private(set) var totalAccepted: Int = 0
    private(set) var totalDuplicate: Int = 0
    private(set) var totalFailed: Int = 0
    private(set) var consecutiveFailureCount: Int = 0
    private(set) var lastFailureAt: Date?
    private(set) var lastFailureReason: String?
    /// Envelopes accepted by the server during the current calendar day.
    /// Resets the first time `recordSync` fires on a new day so the
    /// sidebar's "n today" stays accurate across midnight.
    private(set) var acceptedToday: Int = 0
    private var acceptedTodayBucket: Date? = nil
    private let calendar: Calendar
    /// Ring buffer of recent batches (newest first, capped at 20) used by
    /// the per-source detail view's "Recent checks" table.
    private(set) var recentBatches: [BatchEvent] = []
    /// The current unresolved source issue, if any. A warning means most
    /// records are syncing but some work failed; an error means nothing
    /// synced or failures outnumbered successful records.
    private(set) var activeIssue: IssueEvent?
    /// Recent warning/error events (newest first, capped at 20). These
    /// back the actionable detail panes so a green row never opens onto
    /// hidden errors.
    private(set) var recentIssues: [IssueEvent] = []

    struct BatchEvent: Identifiable, Hashable, Sendable {
        let id: UUID
        let timestamp: Date
        let accepted: Int
        let duplicate: Int
        let failed: Int
        let issueSummary: String?
        let latencyMS: Int

        init(
            timestamp: Date,
            accepted: Int,
            duplicate: Int,
            failed: Int = 0,
            issueSummary: String? = nil,
            latencyMS: Int
        ) {
            self.id = UUID()
            self.timestamp = timestamp
            self.accepted = accepted
            self.duplicate = duplicate
            self.failed = failed
            self.issueSummary = issueSummary
            self.latencyMS = latencyMS
        }
    }

    enum IssueSeverity: String, Hashable, Sendable {
        case warning
        case error
    }

    struct IssueEvent: Identifiable, Hashable, Sendable {
        let id: UUID
        let timestamp: Date
        let severity: IssueSeverity
        let reason: String
        let failedCount: Int

        init(timestamp: Date, severity: IssueSeverity, reason: String, failedCount: Int) {
            self.id = UUID()
            self.timestamp = timestamp
            self.severity = severity
            self.reason = reason
            self.failedCount = failedCount
        }
    }

    init(state: SourceState = .disconnected, calendar: Calendar = .current) {
        self.state = state
        self.calendar = calendar
    }

    func update(state: SourceState) {
        self.state = state
    }

    /// Records that a cycle completed successfully but had nothing new
    /// to ship. Sets `lastSyncAt` so the UI knows the source is alive
    /// and healthy. Resets the last-check counters to zero so the UI
    /// does not keep presenting an older batch as the latest result.
    /// Does not touch `recentBatches`, `totalAccepted`, or
    /// `acceptedToday`, since no real batch occurred.
    func recordHealthyCycle(at date: Date) {
        self.lastSyncAt = date
        self.lastBatchAccepted = 0
        self.lastBatchDuplicate = 0
        self.lastBatchFailed = 0
        self.consecutiveFailureCount = 0
        self.lastFailureAt = nil
        self.lastFailureReason = nil
        if activeIssue?.severity == .error {
            activeIssue = nil
        }
    }

    func recordSync(
        at date: Date,
        accepted: Int,
        duplicate: Int,
        failed: Int = 0,
        issueSummary: String? = nil,
        latencyMS: Int = 0
    ) {
        self.lastSyncAt = date
        self.lastBatchAccepted = accepted
        self.lastBatchDuplicate = duplicate
        self.lastBatchFailed = failed
        self.totalAccepted += accepted
        self.totalDuplicate += duplicate
        self.totalFailed += failed
        self.consecutiveFailureCount = 0
        self.lastFailureAt = nil
        self.lastFailureReason = nil
        let bucket = calendar.startOfDay(for: date)
        if bucket != acceptedTodayBucket {
            acceptedToday = 0
            acceptedTodayBucket = bucket
        }
        acceptedToday += accepted
        let summary = failed > 0
            ? (issueSummary ?? Self.defaultIssueSummary(failed: failed))
            : nil
        let event = BatchEvent(
            timestamp: date,
            accepted: accepted,
            duplicate: duplicate,
            failed: failed,
            issueSummary: summary,
            latencyMS: latencyMS
        )
        recentBatches.insert(event, at: 0)
        if recentBatches.count > 20 {
            recentBatches.removeLast(recentBatches.count - 20)
        }
        if let summary, failed > 0 {
            recordIssue(
                at: date,
                severity: Self.issueSeverity(accepted: accepted, duplicate: duplicate, failed: failed),
                reason: summary,
                failedCount: failed
            )
        } else if activeIssue?.severity == .error {
            activeIssue = nil
        }
    }

    func recordCycleFailure(at date: Date, reason: String) {
        consecutiveFailureCount += 1
        lastFailureAt = date
        lastFailureReason = reason
        recordIssue(at: date, severity: .error, reason: reason, failedCount: 1)
    }

    func clearIssues() {
        activeIssue = nil
        recentIssues.removeAll()
        consecutiveFailureCount = 0
        lastFailureAt = nil
        lastFailureReason = nil
    }

    func displayedState() -> SourceState {
        if let issue = activeIssue {
            switch issue.severity {
            case .warning:
                return .needsAttention(reason: issue.reason)
            case .error:
                return .error(reason: issue.reason)
            }
        }
        let display = state.displayed(
            lastSyncAt: lastSyncAt,
            shippedBatch: !recentBatches.isEmpty
        )
        if case .needsAttention(let reason) = display,
           lastSyncAt == nil || Self.isBlockingAttentionReason(reason) {
            return .error(reason: reason)
        }
        return display
    }

    private func recordIssue(
        at date: Date,
        severity: IssueSeverity,
        reason: String,
        failedCount: Int
    ) {
        let issue = IssueEvent(
            timestamp: date,
            severity: severity,
            reason: reason,
            failedCount: failedCount
        )
        activeIssue = issue
        recentIssues.insert(issue, at: 0)
        if recentIssues.count > 20 {
            recentIssues.removeLast(recentIssues.count - 20)
        }
    }

    private static func issueSeverity(accepted: Int, duplicate: Int, failed: Int) -> IssueSeverity {
        let synced = accepted + duplicate
        if synced == 0 || failed >= synced {
            return .error
        }
        return .warning
    }

    private static func defaultIssueSummary(failed: Int) -> String {
        if failed == 1 {
            return "1 item did not sync."
        }
        return "\(failed.formatted(.number)) items did not sync."
    }

    private static func isBlockingAttentionReason(_ reason: String) -> Bool {
        switch reason {
        case "calendar_not_authorized",
             "reminders_not_authorized":
            return true
        default:
            return SourceState.isFullDiskAccessReason(reason)
        }
    }
}
