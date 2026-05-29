import Foundation
import Observation

/// Owns the set of installed sources and exposes their statuses to UI.
///
/// Real sources are registered through `register(_:)`. Sources still in
/// development are surfaced as `coming-soon` rows so the sidebar shape is
/// stable.
@Observable
@MainActor
final class SourceRegistry {
    private(set) var sources: [SourceDescriptor] = []

    private var registered: [String: any SourceProtocol] = [:]
    private let eventLog: EventLog

    init(eventLog: EventLog) {
        self.eventLog = eventLog
    }

    /// Register a real source. Preserves the product order chosen by
    /// `AppEnvironment` so core sources like iMessage and Notes do not
    /// get buried under later registrations.
    func register(_ source: any SourceProtocol) {
        registered[source.id] = source
        let descriptor = SourceDescriptor(
            id: source.id,
            displayName: source.displayName,
            symbol: source.symbol,
            state: source.statusPublisher.state,
            comingSoon: false
        )
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = descriptor
        } else {
            sources.append(descriptor)
        }
        eventLog.info(
            "source_registry.registered",
            source: .system,
            payload: ["id": source.id]
        )
    }

    /// Live status publisher for a registered source, or `nil` if not
    /// installed. UI binds to this directly so the syncing animation
    /// reflects the source's actual state without polling the cached
    /// `SourceDescriptor`.
    func statusPublisher(for id: String) -> SourceStatusPublisher? {
        registered[id]?.statusPublisher
    }

    /// Live sources currently blocked by macOS Full Disk Access. Used by
    /// the main window banner so a permissions regression after
    /// onboarding is visible without making the user inspect each source.
    func fullDiskAccessBlockedSources() -> [SourceDescriptor] {
        let sourceOrder = ["imessage": 0, "notes": 1, "voice_memos": 2]

        return sources
            .filter { descriptor in
                guard !descriptor.comingSoon,
                      let publisher = registered[descriptor.id]?.statusPublisher
                else {
                    return false
                }
                return publisher.displayedState().requiresFullDiskAccess
            }
            .sorted {
                let left = sourceOrder[$0.id] ?? Int.max
                let right = sourceOrder[$1.id] ?? Int.max
                if left == right {
                    return $0.displayName < $1.displayName
                }
                return left < right
            }
    }

    /// Pull the latest state from every registered source's status
    /// publisher into the visible descriptors. UI calls this on a timer or
    /// when it observes a status change.
    func refreshStates() {
        for (index, descriptor) in sources.enumerated() {
            guard let source = registered[descriptor.id] else { continue }
            sources[index].state = source.statusPublisher.displayedState()
        }
    }

    /// Triggered by ⌘R and the toolbar's Sync Now button. Fires every
    /// registered source's `syncNow` in parallel.
    func syncNow() {
        eventLog.info("source_registry.sync_now", source: .system)
        for source in registered.values {
            Task { @MainActor in
                do {
                    try await source.syncNow()
                } catch {
                    eventLog.error(
                        "source_registry.sync_now_failed",
                        source: .system,
                        payload: ["id": source.id, "error": String(describing: error)]
                    )
                }
            }
        }
    }

    /// Recheck every source currently blocked by macOS Full Disk
    /// Access. The grant is app-wide, so checking one blocked local
    /// source should immediately unblock the others instead of making the
    /// user wait for each source's next polling tick.
    func syncFullDiskAccessBlockedSources() {
        let blockedIDs = Set(fullDiskAccessBlockedSources().map(\.id))

        guard !blockedIDs.isEmpty else {
            eventLog.info("source_registry.sync_fda_blocked_none", source: .system)
            return
        }

        eventLog.info(
            "source_registry.sync_fda_blocked",
            source: .system,
            payload: ["count": String(blockedIDs.count)]
        )

        for source in registered.values where blockedIDs.contains(source.id) {
            Task { @MainActor in
                do {
                    try await source.syncNow()
                } catch {
                    eventLog.error(
                        "source_registry.sync_fda_blocked_failed",
                        source: .system,
                        payload: ["id": source.id, "error": String(describing: error)]
                    )
                }
            }
        }
    }

    func pauseAll() {
        for source in registered.values {
            source.pause()
        }
    }

    func startAll() {
        for source in registered.values {
            source.start()
        }
    }

    /// Pause polling for a single registered source. No-op if the source
    /// is unknown. Used by the per-source detail panes' Pause button.
    func pause(id: String) {
        guard let source = registered[id] else {
            eventLog.warning(
                "source_registry.pause_unknown",
                source: .system,
                payload: ["id": id]
            )
            return
        }
        eventLog.info(
            "source_registry.pause",
            source: .system,
            payload: ["id": id]
        )
        source.pause()
    }

    /// Resume polling for a single registered source. No-op if the source
    /// is unknown. Used by the per-source detail panes' Resume button.
    func resume(id: String) {
        guard let source = registered[id] else {
            eventLog.warning(
                "source_registry.resume_unknown",
                source: .system,
                payload: ["id": id]
            )
            return
        }
        eventLog.info(
            "source_registry.resume",
            source: .system,
            payload: ["id": id]
        )
        source.start()
    }

    /// Drop the local cursor (and any in-memory caches the source owns)
    /// without touching cloud data. The next polling tick re-pulls
    /// everything from the local source from scratch — useful for
    /// repairing a sync that got stuck on a stale cursor. Delegates to
    /// the source's `clearLocalState()`.
    func resetCursor(id: String) {
        guard let source = registered[id] else {
            eventLog.warning(
                "source_registry.reset_cursor_unknown",
                source: .system,
                payload: ["id": id]
            )
            return
        }
        eventLog.info(
            "source_registry.reset_cursor",
            source: .system,
            payload: ["id": id]
        )
        source.clearLocalState()
    }

    /// Force an immediate sync cycle for a single registered source.
    /// No-op if the source is unknown. Used by the per-source detail
    /// panes' "Sync now" button so other sources aren't disturbed.
    func syncNow(id: String) {
        guard let source = registered[id] else {
            eventLog.warning(
                "source_registry.sync_now_unknown",
                source: .system,
                payload: ["id": id]
            )
            return
        }
        eventLog.info(
            "source_registry.sync_now_one",
            source: .system,
            payload: ["id": id]
        )
        Task { @MainActor in
            do {
                try await source.syncNow()
            } catch {
                eventLog.error(
                    "source_registry.sync_now_failed",
                    source: .system,
                    payload: ["id": source.id, "error": String(describing: error)]
                )
            }
        }
    }
}

/// Lightweight view-facing description of a source. UI binds to this; the
/// actual source object lives on the registry and is hidden from views.
struct SourceDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let symbol: String
    var state: SourceState
    let comingSoon: Bool
}

enum SourceState: Hashable, Sendable {
    case disconnected
    case connected
    case syncing
    case paused
    case needsAttention(reason: String)
    case error(reason: String)

    var requiresFullDiskAccess: Bool {
        switch self {
        case .needsAttention(let reason), .error(let reason):
            return Self.isFullDiskAccessReason(reason)
        default:
            return false
        }
    }

    static func isFullDiskAccessReason(_ reason: String) -> Bool {
        switch reason {
        case "imessage_full_disk_access_required",
             "notes_full_disk_access_required",
             "voice_memos_full_disk_access_required":
            return true
        default:
            return false
        }
    }

    /// The state as it should be displayed to the user. Three rules:
    ///
    /// 1. `.connected` requires a `lastSyncAt` — a source that has
    ///    never completed a single cycle (no batch, no heartbeat) is
    ///    demoted to `.disconnected` so the green dot means "the
    ///    source is healthy." Sources that are fully caught up
    ///    (cycle hits the empty path on every poll) still light green
    ///    because `recordHealthyCycle` sets `lastSyncAt` — that's the
    ///    point. Working ≠ "moving net-new data right now."
    /// 2. `.syncing` is held as steady green once a batch has shipped
    ///    this session, so the rotating-arrow badge doesn't flash on
    ///    every 3-min cycle. The animated arrow still appears on the
    ///    very first sync (when `shippedBatch == false`) as helpful
    ///    "we're working on it" feedback.
    /// 3. Other states pass through unchanged.
    func displayed(lastSyncAt: Date?, shippedBatch: Bool) -> SourceState {
        switch self {
        case .connected:
            return lastSyncAt == nil ? .disconnected : .connected
        case .syncing:
            return shippedBatch ? .connected : .syncing
        default:
            return self
        }
    }
}
