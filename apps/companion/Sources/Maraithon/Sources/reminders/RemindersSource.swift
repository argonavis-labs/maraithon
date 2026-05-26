import AsyncAlgorithms
import Foundation
import Observation

/// `SourceProtocol` implementation for macOS Reminders, backed by
/// EventKit (iCloud + local lists). Polls every 2 minutes by default,
/// which is more aggressive than notes / voice-memos because reminders
/// change often: the assistant writes them, scheduled triggers fire
/// them, and the user toggles completion manually.
///
/// Cursor strategy differs from the iMessage / notes / voice-memos
/// sources: there is no monotonic `Z_PK` we can resume from. EventKit
/// gives us `lastModifiedDate` per reminder, so the cursor is a
/// `(guid → modified_at)` map and the source only re-pushes reminders
/// whose current `lastModifiedDate` advanced past the persisted value.
/// The server upserts on `(user, device, source, guid)` so toggling a
/// reminder from open → done rewrites the matching row.
///
/// `@MainActor` because of the `@Observable` status publisher; the
/// EventKit + HTTP work happens in detached tasks and re-enters the
/// main actor only to update status.
@MainActor
final class RemindersSource: SourceProtocol {
    let id: String = "reminders"
    let displayName: String = "Reminders"
    let symbol: String = "checklist"
    let statusPublisher: SourceStatusPublisher

    /// Outbox closure — same shape as the other sources, so tests can
    /// capture payloads without going through HTTP.
    typealias Outbox = @Sendable (UUID, [ReminderPayload]) async throws -> SyncOutcome

    private let cursor: RemindersCursor
    private let eventLog: EventLog
    private let outbox: Outbox
    private let deviceIdProvider: @MainActor @Sendable () -> UUID
    private let reader: RemindersReader
    private let pollInterval: TimeInterval
    private let lowPowerPollInterval: TimeInterval
    private let batchLimit: Int
    private let lowPowerProbe: @Sendable () -> Bool

    private var pollTask: Task<Void, Never>?
    private var isPaused: Bool = false
    private var lastLowPowerState: Bool = false
    private var lastTickAt: ContinuousClock.Instant?
    /// Tracks whether we've already triggered EventKit's prompt so a
    /// `.notDetermined` state doesn't re-fire it every cycle.
    private var didRequestAccess: Bool = false

    init(
        reader: RemindersReader = RemindersReader(),
        cursor: RemindersCursor = RemindersCursor(),
        eventLog: EventLog,
        deviceIdProvider: @escaping @MainActor @Sendable () -> UUID,
        pollInterval: TimeInterval = 120,
        lowPowerPollInterval: TimeInterval? = nil,
        batchLimit: Int = 200,
        lowPowerProbe: @escaping @Sendable () -> Bool = {
            ProcessInfo.processInfo.isLowPowerModeEnabled
        },
        outbox: @escaping Outbox
    ) {
        self.reader = reader
        self.cursor = cursor
        self.eventLog = eventLog
        self.outbox = outbox
        self.deviceIdProvider = deviceIdProvider
        self.pollInterval = pollInterval
        // Default: 4× base cadence under Low Power Mode, capped at 15
        // minutes. Reminders are inherently checkpointed so a longer
        // stretch isn't a correctness problem — the next tick still
        // catches everything modified in the interim.
        self.lowPowerPollInterval = lowPowerPollInterval ?? min(pollInterval * 4, 900)
        self.batchLimit = batchLimit
        self.lowPowerProbe = lowPowerProbe
        self.statusPublisher = SourceStatusPublisher(state: .disconnected)
    }

    /// Convenience init wiring the outbox to a `RemindersIngest`. The
    /// designated init stays available for tests that want to capture
    /// payloads directly.
    convenience init(
        reader: RemindersReader = RemindersReader(),
        cursor: RemindersCursor = RemindersCursor(),
        eventLog: EventLog,
        ingest: RemindersIngest,
        deviceIdProvider: @escaping @MainActor @Sendable () -> UUID,
        pollInterval: TimeInterval = 120,
        lowPowerPollInterval: TimeInterval? = nil,
        batchLimit: Int = 200,
        lowPowerProbe: @escaping @Sendable () -> Bool = {
            ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    ) {
        self.init(
            reader: reader,
            cursor: cursor,
            eventLog: eventLog,
            deviceIdProvider: deviceIdProvider,
            pollInterval: pollInterval,
            lowPowerPollInterval: lowPowerPollInterval,
            batchLimit: batchLimit,
            lowPowerProbe: lowPowerProbe,
            outbox: { deviceId, reminders in
                try await ingest.push(deviceId: deviceId, reminders: reminders)
            }
        )
    }

    // MARK: - SourceProtocol

    func start() {
        guard pollTask == nil else { return }
        isPaused = false
        statusPublisher.update(state: .connected)
        eventLog.info("reminders.start", source: .reminders)
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        pollTask?.cancel()
        pollTask = nil
        statusPublisher.update(state: .paused)
        eventLog.info("reminders.pause", source: .reminders)
    }

    func syncNow() async throws {
        eventLog.info("reminders.sync_now", source: .reminders)
        try await runCycle()
    }

    func clearLocalState() {
        cursor.reset()
        statusPublisher.update(state: .disconnected)
        eventLog.info("reminders.clear_local_state", source: .reminders)
    }

    // MARK: - Polling

    private func pollLoop() async {
        let timer = AsyncTimerSequence(
            interval: .seconds(pollInterval),
            clock: .continuous
        )
        await tickIfNeeded(force: true)
        for await _ in timer {
            if Task.isCancelled || isPaused { break }
            await tickIfNeeded(force: false)
        }
    }

    private func tickIfNeeded(force: Bool) async {
        let lowPower = lowPowerProbe()
        if lowPower != lastLowPowerState {
            lastLowPowerState = lowPower
            eventLog.info(
                "reminders.cadence_changed",
                source: .reminders,
                payload: [
                    "low_power": String(lowPower),
                    "interval_seconds": String(
                        Int(lowPower ? lowPowerPollInterval : pollInterval)
                    )
                ]
            )
        }
        if !force, lowPower, let last = lastTickAt {
            let elapsed = ContinuousClock().now - last
            if elapsed < .seconds(lowPowerPollInterval) { return }
        }
        lastTickAt = ContinuousClock().now
        do {
            try await runCycle()
        } catch {
            statusPublisher.update(
                state: .error(reason: String(describing: error))
            )
            eventLog.error(
                "reminders.cycle_failed",
                source: .reminders,
                payload: ["error": String(describing: error)]
            )
        }
    }

    /// Single sync cycle: enumerate every reminder, keep the ones
    /// whose `lastModifiedDate` advanced past the cursor, batch-push,
    /// advance the cursor only on POST success.
    func runCycle() async throws {
        statusPublisher.update(state: .syncing)

        // Authorization gate. EventKit's `.notDetermined` state is the
        // one we explicitly prompt for; everything else is a terminal
        // user choice we surface to the UI without retrying. Matches
        // the calendar source's flow exactly so both EventKit sources
        // behave the same way on first launch.
        let auth = reader.authorizationState()
        switch auth {
        case .authorized:
            break
        case .notDetermined:
            if !didRequestAccess {
                didRequestAccess = true
                do {
                    let granted = try await reader.requestAccess()
                    eventLog.info(
                        "reminders.access_request",
                        source: .reminders,
                        payload: ["granted": String(granted)]
                    )
                } catch {
                    eventLog.error(
                        "reminders.access_request_failed",
                        source: .reminders,
                        payload: ["error": String(describing: error)]
                    )
                }
            }
            if reader.authorizationState() != .authorized {
                statusPublisher.update(
                    state: .needsAttention(reason: "reminders_not_authorized")
                )
                return
            }
        default:
            statusPublisher.update(state: .needsAttention(reason: "reminders_not_authorized"))
            eventLog.warning(
                "reminders.not_authorized",
                source: .reminders,
                payload: ["state": String(describing: auth)]
            )
            return
        }

        let snapshots = try await reader.fetchAllReminders()

        // Diff against the cursor: only re-push rows whose
        // lastModifiedDate is strictly newer than the persisted one.
        // Reminders without a modifiedAt always push — that's a fresh
        // sighting from EventKit's perspective.
        let cursorSnapshot = cursor.snapshot
        let candidates = snapshots.filter { snap in
            guard let modified = snap.modifiedAt else { return true }
            if let last = cursorSnapshot[snap.guid] {
                return modified > last
            }
            return true
        }
        // Sort newest-first so each cycle's batch ships the user's
        // most-recently-modified reminders. Reminders without a
        // `modifiedAt` sort to the tail; tie-break by guid for stable
        // ordering across cycles.
        let sortedCandidates = candidates.sorted { lhs, rhs in
            switch (lhs.modifiedAt, rhs.modifiedAt) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.guid < rhs.guid
            }
        }
        let pushable = Array(sortedCandidates.prefix(batchLimit))

        if pushable.isEmpty {
            eventLog.debug(
                "reminders.cycle_empty",
                source: .reminders,
                payload: [
                    "scanned": String(snapshots.count),
                    "tracked": String(cursor.trackedCount)
                ]
            )
            statusPublisher.recordHealthyCycle(at: Date())
            statusPublisher.update(state: .connected)
            return
        }

        let payloads = pushable.map(Self.payload(from:))
        let deviceId = deviceIdProvider()
        let outcome = try await outbox(deviceId, payloads)

        let cursorEntries: [(guid: String, modifiedAt: Date)] = pushable.compactMap { snap in
            guard let modified = snap.modifiedAt else { return nil }
            return (guid: snap.guid, modifiedAt: modified)
        }
        cursor.advance(cursorEntries)

        statusPublisher.recordSync(
            at: Date(),
            accepted: outcome.accepted,
            duplicate: outcome.duplicate
        )
        statusPublisher.update(state: .connected)

        // Logged counters: how many rows we scanned, how many we
        // shipped, and a redacted preview of which lists they belong
        // to so the user can debug "why isn't this list syncing?"
        // without titles leaking into the log buffer.
        let lists = pushable.compactMap(\.listName).reduce(into: [String: Int]()) { acc, name in
            acc[name, default: 0] += 1
        }
        eventLog.info(
            "reminders.cycle_pushed",
            source: .reminders,
            payload: [
                "scanned": String(snapshots.count),
                "pushed": String(pushable.count),
                "accepted": String(outcome.accepted),
                "duplicate": String(outcome.duplicate),
                "tracked": String(cursor.trackedCount),
                "lists": Self.listSummary(lists)
            ]
        )
    }

    // MARK: - Mapping

    /// Static mapping from reader snapshot to wire payload. Static so
    /// tests can call it without a live `EKEventStore`.
    ///
    /// `local_id` mirrors the other sources' "p:<rowid>" shape, but
    /// reminders don't have a `Z_PK` — we use the EventKit identifier
    /// directly with an `r:` prefix so a log reader can still tell
    /// reminder local IDs apart from messages and notes.
    nonisolated static func payload(from snapshot: RemindersReader.Snapshot) -> ReminderPayload {
        ReminderPayload(
            guid: snapshot.guid,
            localId: "r:\(snapshot.guid)",
            title: snapshot.title,
            notes: snapshot.notes,
            listName: snapshot.listName,
            listColor: snapshot.listColor,
            // Pass-through of the EventKit numeric priority. `0` is
            // "no priority"; the server keeps that value verbatim
            // (default column default is 0) and the assistant tool
            // surface buckets it into "none / high / medium / low"
            // for the human-readable label.
            priority: snapshot.priority,
            dueAt: snapshot.dueAt,
            completedAt: snapshot.completedAt,
            isCompleted: snapshot.isCompleted,
            hasAlarm: snapshot.hasAlarm,
            urlAttachment: snapshot.urlAttachment,
            createdAt: snapshot.createdAt,
            modifiedAt: snapshot.modifiedAt
        )
    }

    /// Compact "list_name: count" summary for log lines. Sorted by
    /// count descending so the most-active lists surface first.
    private nonisolated static func listSummary(_ counts: [String: Int]) -> String {
        counts
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
    }
}

/// Redaction helper for reminder title / notes content. Reminders are
/// just as user-written as notes, so we never log titles verbatim —
/// only a length-tagged short prefix.
enum RemindersRedactor {
    static let prefixLength = 12

    static func redact(_ text: String?) -> String {
        guard let text else { return "<nil>" }
        if text.count <= prefixLength {
            return "[len=\(text.count)] \(text)"
        }
        let prefix = String(text.prefix(prefixLength))
        return "[len=\(text.count)] \(prefix)…"
    }
}
