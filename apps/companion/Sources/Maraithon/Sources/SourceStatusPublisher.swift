import Foundation
import Observation
/// Observable source health state, including persisted user-facing sync metrics.
@Observable
@MainActor
final class SourceStatusPublisher {
    private(set) var state: SourceState
    private(set) var lastSyncAt: Date?
    private(set) var lastBatchAccepted: Int = 0
    private(set) var lastBatchDuplicate: Int = 0
    private(set) var lastBatchFailed: Int = 0
    private(set) var totalAccepted: Int = 0
    private(set) var totalDuplicate: Int = 0
    private(set) var totalFailed: Int = 0
    private(set) var consecutiveFailureCount: Int = 0
    private(set) var lastFailureAt: Date?
    private(set) var lastFailureReason: String?
    private(set) var acceptedToday: Int = 0
    private var acceptedTodayBucket: Date? = nil
    private let calendar: Calendar
    private(set) var recentBatches: [BatchEvent] = []
    private(set) var activeIssue: IssueEvent?
    private(set) var recentIssues: [IssueEvent] = []
    private let persistenceKey: String?
    private let defaults: UserDefaults?
    private static let persistencePrefix = "source_status."

    struct BatchEvent: Identifiable, Hashable, Codable, Sendable {
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

    enum IssueSeverity: String, Hashable, Codable, Sendable { case warning, error }

    struct IssueEvent: Identifiable, Hashable, Codable, Sendable {
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

    init(
        sourceID: String? = nil,
        state: SourceState = .disconnected,
        calendar: Calendar = .current,
        defaults: UserDefaults = .standard
    ) {
        self.state = state
        self.calendar = calendar
        self.persistenceKey = sourceID.map { "\(Self.persistencePrefix)\($0)" }
        self.defaults = sourceID == nil ? nil : defaults

        if let persistenceKey, let snapshot = Self.loadSnapshot(defaults: defaults, key: persistenceKey) {
            restore(snapshot)
        }
    }

    func update(state: SourceState) { self.state = state }

    /// Records a successful cycle that had nothing new to ship.
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
        persist()
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
        persist()
    }

    func recordCycleFailure(at date: Date, reason: String) {
        consecutiveFailureCount += 1
        lastFailureAt = date
        lastFailureReason = reason
        recordIssue(at: date, severity: .error, reason: reason, failedCount: 1)
        persist()
    }

    func clearIssues() {
        activeIssue = nil
        recentIssues.removeAll()
        consecutiveFailureCount = 0
        lastFailureAt = nil
        lastFailureReason = nil
        persist()
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

    var activeBlockingIssue: IssueEvent? {
        guard let issue = activeIssue, issue.severity == .error else {
            return nil
        }
        return issue
    }

    private func recordIssue(
        at date: Date,
        severity: IssueSeverity,
        reason: String,
        failedCount: Int
    ) {
        let issue = IssueEvent(timestamp: date, severity: severity, reason: reason, failedCount: failedCount)
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

    private func persist() {
        guard let defaults, let persistenceKey else { return }
        guard let data = try? JSONEncoder().encode(snapshot()) else { return }
        defaults.set(data, forKey: persistenceKey)
    }

    private func snapshot() -> Snapshot {
        Snapshot(
            lastSyncAt: lastSyncAt,
            lastBatchAccepted: lastBatchAccepted,
            lastBatchDuplicate: lastBatchDuplicate,
            lastBatchFailed: lastBatchFailed,
            totalAccepted: totalAccepted,
            totalDuplicate: totalDuplicate,
            totalFailed: totalFailed,
            acceptedToday: acceptedToday,
            acceptedTodayBucket: acceptedTodayBucket,
            recentBatches: recentBatches,
            activeIssue: activeIssue,
            recentIssues: recentIssues
        )
    }

    private func restore(_ snapshot: Snapshot) {
        lastSyncAt = snapshot.lastSyncAt
        lastBatchAccepted = snapshot.lastBatchAccepted
        lastBatchDuplicate = snapshot.lastBatchDuplicate
        lastBatchFailed = snapshot.lastBatchFailed
        totalAccepted = snapshot.totalAccepted
        totalDuplicate = snapshot.totalDuplicate
        totalFailed = snapshot.totalFailed
        acceptedToday = snapshot.acceptedToday
        acceptedTodayBucket = snapshot.acceptedTodayBucket
        recentBatches = Array(snapshot.recentBatches.prefix(20))
        activeIssue = snapshot.activeIssue
        recentIssues = Array(snapshot.recentIssues.prefix(20))
        resetAcceptedTodayIfNeeded()
    }

    private func resetAcceptedTodayIfNeeded(referenceDate: Date = Date()) {
        guard let acceptedTodayBucket else {
            acceptedToday = 0
            return
        }
        if !calendar.isDate(acceptedTodayBucket, inSameDayAs: referenceDate) {
            acceptedToday = 0
            self.acceptedTodayBucket = nil
        }
    }

    private static func loadSnapshot(defaults: UserDefaults, key: String) -> Snapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private struct Snapshot: Codable {
        let lastSyncAt: Date?
        let lastBatchAccepted, lastBatchDuplicate, lastBatchFailed: Int
        let totalAccepted, totalDuplicate, totalFailed: Int
        let acceptedToday: Int
        let acceptedTodayBucket: Date?
        let recentBatches: [BatchEvent]
        let activeIssue: IssueEvent?
        let recentIssues: [IssueEvent]
    }
}
