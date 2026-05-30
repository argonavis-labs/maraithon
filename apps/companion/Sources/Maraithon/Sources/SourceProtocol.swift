import Foundation

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
