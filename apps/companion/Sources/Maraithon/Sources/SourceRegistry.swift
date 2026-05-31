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
    private static let sourceOrder = [
        "imessage": 0,
        "notes": 1,
        "voice_memos": 2,
        "reminders": 3,
        "calendar": 4,
        "files": 5,
        "browser_history": 6
    ]

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
        return sources
            .filter { descriptor in
                guard !descriptor.comingSoon,
                      let publisher = registered[descriptor.id]?.statusPublisher
                else {
                    return false
                }
                return publisher.displayedState().requiresFullDiskAccess
            }
            .sorted(by: Self.sortByProductOrder)
    }

    /// Sources with focused macOS permission screens other than Full
    /// Disk Access. Rechecked when the app returns active so Calendar
    /// and Reminders clear quickly after the user grants access in
    /// System Settings.
    func userRecoverablePermissionBlockedSources() -> [SourceDescriptor] {
        sources
            .filter { descriptor in
                guard !descriptor.comingSoon,
                      let publisher = registered[descriptor.id]?.statusPublisher
                else {
                    return false
                }

                let reason: String
                switch publisher.displayedState() {
                case .needsAttention(let stateReason), .error(let stateReason):
                    reason = stateReason
                default:
                    return false
                }

                return SourceState.isUserRecoverablePermissionReason(reason)
                    && !SourceState.isFullDiskAccessReason(reason)
            }
            .sorted(by: Self.sortByProductOrder)
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
            source.statusPublisher.clearFullDiskAccessBlock()
        }

        refreshStates()

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

    /// Re-run every source currently blocked by Full Disk Access without
    /// clearing the visible blocker first. Used when a user clicks
    /// "Check again" but the lightweight global probe still cannot prove
    /// the grant; the real source check remains the authority.
    func recheckFullDiskAccessBlockedSources() {
        let blockedIDs = Set(fullDiskAccessBlockedSources().map(\.id))

        guard !blockedIDs.isEmpty else {
            eventLog.info("source_registry.recheck_fda_blocked_none", source: .system)
            return
        }

        eventLog.info(
            "source_registry.recheck_fda_blocked",
            source: .system,
            payload: ["count": String(blockedIDs.count)]
        )

        for source in registered.values where blockedIDs.contains(source.id) {
            Task { @MainActor in
                do {
                    try await source.syncNow()
                } catch {
                    eventLog.error(
                        "source_registry.recheck_fda_blocked_failed",
                        source: .system,
                        payload: ["id": source.id, "error": String(describing: error)]
                    )
                }
            }
        }
    }

    /// Clear stale Full Disk Access blockers after a relaunch once the
    /// running app proves the grant is present. This keeps macOS reloads
    /// from showing old permission copy when TCC is already satisfied.
    @discardableResult
    func clearFullDiskAccessBlocksIfGranted(
        isGranted: () -> Bool = { FullDiskAccessProbe.isGranted() }
    ) -> Bool {
        let blockedIDs = Set(fullDiskAccessBlockedSources().map(\.id))

        guard !blockedIDs.isEmpty else { return false }
        guard isGranted() else { return false }

        eventLog.info(
            "source_registry.clear_fda_blocks_granted",
            source: .system,
            payload: ["count": String(blockedIDs.count)]
        )

        for source in registered.values where blockedIDs.contains(source.id) {
            source.statusPublisher.clearFullDiskAccessBlock()
        }

        refreshStates()
        return true
    }

    func syncUserRecoverablePermissionBlockedSources() {
        let blockedIDs = Set(userRecoverablePermissionBlockedSources().map(\.id))

        guard !blockedIDs.isEmpty else {
            eventLog.info("source_registry.sync_permission_blocked_none", source: .system)
            return
        }

        eventLog.info(
            "source_registry.sync_permission_blocked",
            source: .system,
            payload: ["count": String(blockedIDs.count)]
        )

        for source in registered.values where blockedIDs.contains(source.id) {
            Task { @MainActor in
                do {
                    try await source.syncNow()
                } catch {
                    eventLog.error(
                        "source_registry.sync_permission_blocked_failed",
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
    /// panes' "Check now" button so other sources aren't disturbed.
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

    private static func sortByProductOrder(
        _ left: SourceDescriptor,
        _ right: SourceDescriptor
    ) -> Bool {
        let leftOrder = sourceOrder[left.id] ?? Int.max
        let rightOrder = sourceOrder[right.id] ?? Int.max
        if leftOrder == rightOrder {
            return left.displayName < right.displayName
        }
        return leftOrder < rightOrder
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

    static func isUserRecoverablePermissionReason(_ reason: String) -> Bool {
        switch reason {
        case "calendar_not_authorized",
             "reminders_not_authorized",
             "imessage_full_disk_access_required",
             "notes_full_disk_access_required",
             "voice_memos_speech_disabled",
             "voice_memos_speech_not_authorized",
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
