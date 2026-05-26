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
    /// Running totals since app launch. Detail panes surface these as
    /// "Total synced" / "Total duplicate".
    private(set) var totalAccepted: Int = 0
    private(set) var totalDuplicate: Int = 0
    /// Envelopes accepted by the server during the current calendar day.
    /// Resets the first time `recordSync` fires on a new day so the
    /// sidebar's "n today" stays accurate across midnight.
    private(set) var acceptedToday: Int = 0
    private var acceptedTodayBucket: Date? = nil
    private let calendar: Calendar
    /// Ring buffer of recent batches (newest first, capped at 20) used by
    /// the per-source detail view's "Recent activity" table.
    private(set) var recentBatches: [BatchEvent] = []

    struct BatchEvent: Identifiable, Hashable, Sendable {
        let id: UUID
        let timestamp: Date
        let accepted: Int
        let duplicate: Int
        let latencyMS: Int

        init(timestamp: Date, accepted: Int, duplicate: Int, latencyMS: Int) {
            self.id = UUID()
            self.timestamp = timestamp
            self.accepted = accepted
            self.duplicate = duplicate
            self.latencyMS = latencyMS
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
    /// and healthy — but does NOT touch `recentBatches`, `totalAccepted`,
    /// `acceptedToday`, or the last-batch counters, since no real batch
    /// occurred. Use this from a source's empty-cycle path.
    func recordHealthyCycle(at date: Date) {
        self.lastSyncAt = date
    }

    func recordSync(at date: Date, accepted: Int, duplicate: Int, latencyMS: Int = 0) {
        self.lastSyncAt = date
        self.lastBatchAccepted = accepted
        self.lastBatchDuplicate = duplicate
        self.totalAccepted += accepted
        self.totalDuplicate += duplicate
        let bucket = calendar.startOfDay(for: date)
        if bucket != acceptedTodayBucket {
            acceptedToday = 0
            acceptedTodayBucket = bucket
        }
        acceptedToday += accepted
        let event = BatchEvent(
            timestamp: date,
            accepted: accepted,
            duplicate: duplicate,
            latencyMS: latencyMS
        )
        recentBatches.insert(event, at: 0)
        if recentBatches.count > 20 {
            recentBatches.removeLast(recentBatches.count - 20)
        }
    }
}
