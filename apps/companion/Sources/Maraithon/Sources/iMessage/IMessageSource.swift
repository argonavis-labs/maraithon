import AsyncAlgorithms
import Foundation
import Observation

/// `SourceProtocol` implementation for `~/Library/Messages/chat.db`.
///
/// Responsibilities:
///   * Open the database read-only and resume from `IMessageCursor`.
///   * Poll on a configurable cadence (default 30s) using
///     `AsyncTimerSequence`, so we cooperate with structured concurrency
///     and can be driven deterministically in tests via a short interval
///     on `.continuous`.
///   * Build `SyncEnvelope`s shaped per the companion spec's "Push
///     payload" and hand them to an outbox closure.
///   * Filter blocked handles before push so the cloud never sees them.
///   * Log every transition through `EventLog` with handles redacted via
///     `Redactor`.
///   * Honor Low Power Mode by stretching cadence to
///     `lowPowerPollInterval` (4× the base interval by default). We
///     re-read `ProcessInfo.processInfo.isLowPowerModeEnabled` on every
///     tick instead of tearing down / rebuilding the timer on each
///     `NSProcessInfo.powerStateDidChangeNotification` — re-reading is
///     simpler, Sendable-clean, and at worst delays the cadence change
///     by one base tick (≤30s in production), which is fine.
///
/// The source is `@MainActor` because it owns an `@Observable` status
/// publisher; the actual SQLite + push work happens in detached tasks
/// and re-enters the main actor only to update status.
@MainActor
final class IMessageSource: SourceProtocol {
    let id: String = "imessage"
    let displayName: String = "iMessage"
    let symbol: String = "message"
    let statusPublisher: SourceStatusPublisher

    private let cursor: IMessageCursor
    private let blocklist: Blocklist
    private let eventLog: EventLog
    private let ingest: IMessageIngest
    private let deviceIdProvider: @MainActor () -> UUID
    private let databaseURL: URL
    private let pollInterval: TimeInterval
    private let lowPowerPollInterval: TimeInterval
    private let batchLimit: Int
    private let lowPowerProbe: @Sendable () -> Bool

    private var pollTask: Task<Void, Never>?
    private var isPaused: Bool = false
    private var lastLowPowerState: Bool = false

    init(
        databaseURL: URL = IMessageDatabase.defaultDatabaseURL,
        cursor: IMessageCursor = IMessageCursor(),
        blocklist: Blocklist,
        eventLog: EventLog,
        ingest: IMessageIngest,
        deviceIdProvider: @escaping @MainActor () -> UUID,
        pollInterval: TimeInterval = 180,
        lowPowerPollInterval: TimeInterval? = nil,
        batchLimit: Int = 200,
        lowPowerProbe: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    ) {
        self.databaseURL = databaseURL
        self.cursor = cursor
        self.blocklist = blocklist
        self.eventLog = eventLog
        self.ingest = ingest
        self.deviceIdProvider = deviceIdProvider
        self.pollInterval = pollInterval
        // Default: 4× base cadence when on battery saver. Capped at 5 min
        // so we still catch up reasonably quickly when the user comes back
        // to a plugged-in state.
        self.lowPowerPollInterval = lowPowerPollInterval ?? min(pollInterval * 4, 300)
        self.batchLimit = batchLimit
        self.lowPowerProbe = lowPowerProbe
        self.statusPublisher = SourceStatusPublisher(sourceID: "imessage", state: .disconnected)
    }

    // MARK: - SourceProtocol

    func start() {
        guard pollTask == nil else { return }
        isPaused = false
        statusPublisher.update(state: .connected)
        eventLog.info("imessage.start", source: .imessage)
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
        eventLog.info("imessage.pause", source: .imessage)
    }

    func syncNow() async throws {
        eventLog.info("imessage.sync_now", source: .imessage)
        do {
            try await runCycle()
        } catch {
            markCycleFailed(error, event: "imessage.sync_now_failed")
            throw error
        }
    }

    func clearLocalState() {
        cursor.reset()
        statusPublisher.clearIssues()
        statusPublisher.update(state: .disconnected)
        eventLog.info("imessage.clear_local_state", source: .imessage)
    }

    // MARK: - Polling

    /// `AsyncTimerSequence`-driven poll loop. The base ticker runs at
    /// `pollInterval` on the continuous clock; when Low Power Mode is on
    /// we skip ticks until `lowPowerPollInterval` has elapsed since the
    /// last cycle. Re-reading the power state per tick (rather than
    /// observing `NSProcessInfo.powerStateDidChangeNotification` and
    /// rebuilding the timer) keeps the loop Sendable-clean and avoids
    /// notification-token lifecycle wrangling — the worst-case lag for a
    /// cadence change is one base tick.
    private func pollLoop() async {
        let timer = AsyncTimerSequence(
            interval: .seconds(pollInterval),
            clock: .continuous
        )
        // Run immediately on start; `AsyncTimerSequence` only fires after
        // its first interval, so without this priming cycle the first
        // sync would be delayed by `pollInterval`.
        await tickIfNeeded(force: true)
        for await _ in timer {
            if Task.isCancelled || isPaused { break }
            await tickIfNeeded(force: false)
        }
    }

    /// Continuous clock instant of the most recent cycle attempt. Used to
    /// honor the longer low-power cadence while sharing a single timer.
    private var lastTickAt: ContinuousClock.Instant?

    private func tickIfNeeded(force: Bool) async {
        if waitForFullDiskAccessGrantIfNeeded() {
            return
        }

        let lowPower = lowPowerProbe()
        if lowPower != lastLowPowerState {
            lastLowPowerState = lowPower
            eventLog.info(
                "imessage.cadence_changed",
                source: .imessage,
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
            try await runCycle(suppressIfPaused: true)
        } catch {
            markCycleFailed(error, event: "imessage.cycle_failed")
        }
    }

    private func waitForFullDiskAccessGrantIfNeeded() -> Bool {
        guard let reason = statusPublisher.fullDiskAccessBlockReason else {
            return false
        }

        if FullDiskAccessProbe.isGranted() {
            statusPublisher.clearFullDiskAccessBlock()
            eventLog.info(
                "imessage.full_disk_access_granted",
                source: .imessage,
                payload: ["previous_reason": reason]
            )
            return false
        }

        eventLog.debug(
            "imessage.waiting_for_full_disk_access",
            source: .imessage,
            payload: ["reason": reason]
        )
        return true
    }

    /// Two-phase newest-first cycle:
    ///   1. Pull rows with `rowid > newestSeen` (DESC) — today's
    ///      messages first.
    ///   2. If none, pull rows with `rowid < backfillFrom` (DESC) —
    ///      walk history backward.
    /// Cursor pointers advance only after the ingest succeeds.
    func runCycle(suppressIfPaused: Bool = false) async throws {
        statusPublisher.update(state: .syncing)
        let newestSeenBefore = cursor.newestSeen
        let backfillFromBefore = cursor.backfillFrom

        // Phase 1: newest unseen
        let (built, phase, queryFloor) = try await Task.detached(priority: .utility) {
            [databaseURL, batchLimit] () -> ([BuiltRecord], String, Int64) in
            let newer = try Self.buildRecords(
                databaseURL: databaseURL,
                kind: .newerThan(newestSeenBefore),
                limit: batchLimit
            )
            if !newer.isEmpty {
                return (newer, "newer", newestSeenBefore)
            }
            let older = try Self.buildRecords(
                databaseURL: databaseURL,
                kind: .olderThan(backfillFromBefore),
                limit: batchLimit
            )
            return (older, "backfill", backfillFromBefore)
        }.value

        let filtered = filterBlocked(built)
        if filtered.isEmpty {
            if shouldSuppressPollOutcome(suppressIfPaused) { return }

            eventLog.debug(
                "imessage.cycle_empty",
                source: .imessage,
                payload: [
                    "phase": phase,
                    "query_floor": String(queryFloor)
                ]
            )
            statusPublisher.recordHealthyCycle(at: Date())
            statusPublisher.update(state: .connected)
            return
        }

        let batch = IMessageIngestBatch(
            deviceId: deviceIdProvider(),
            source: "imessage",
            messages: filtered.map(\.record)
        )
        let outcome = try await ingest.ingestMessages(batch: batch)

        let rowIDs = filtered.map(\.envelopeRowID)
        if let maxRow = rowIDs.max() { cursor.advanceNewest(to: maxRow) }
        if let minRow = rowIDs.min() { cursor.advanceBackfill(to: minRow) }

        if shouldSuppressPollOutcome(suppressIfPaused) { return }

        statusPublisher.recordSync(
            at: Date(),
            accepted: outcome.accepted,
            duplicate: outcome.duplicate,
            failed: outcome.invalid,
            issueSummary: outcome.invalid > 0
                ? Self.syncIssueSummary(count: outcome.invalid, singular: "message", plural: "messages")
                : nil
        )
        statusPublisher.update(state: .connected)
        eventLog.info(
            "imessage.cycle_pushed",
            source: .imessage,
            payload: [
                "phase": phase,
                "count": String(filtered.count),
                "accepted": String(outcome.accepted),
                "duplicate": String(outcome.duplicate),
                "invalid": String(outcome.invalid),
                "blocklist_filtered": String(built.count - filtered.count),
                "newest_seen": String(cursor.newestSeen),
                "backfill_from": String(cursor.backfillFrom)
            ]
        )
    }

    private func shouldSuppressPollOutcome(_ suppressIfPaused: Bool) -> Bool {
        suppressIfPaused && (isPaused || Task.isCancelled)
    }

    private static func syncIssueSummary(count: Int, singular: String, plural: String) -> String {
        count == 1
            ? "1 \(singular) did not sync."
            : "\(count.formatted(.number)) \(plural) did not sync."
    }

    private func filterBlocked(_ built: [BuiltRecord]) -> [BuiltRecord] {
        built.filter { b in
            let handles = b.allHandles
            for handle in handles {
                if blocklist.contains(handle) {
                    eventLog.debug(
                        "imessage.filtered_blocked",
                        source: .imessage,
                        payload: ["handle": Redactor.redact(handle)]
                    )
                    return false
                }
            }
            return true
        }
    }

    private func markCycleFailed(_ error: Error, event: String) {
        if let reason = Self.accessIssueReason(for: error) {
            statusPublisher.clearIssues()
            statusPublisher.update(state: .needsAttention(reason: reason))
            eventLog.warning(
                event,
                source: .imessage,
                payload: ["reason": reason, "error": String(describing: error)]
            )
            return
        }
        let reason = String(describing: error)
        statusPublisher.recordCycleFailure(at: Date(), reason: reason)
        statusPublisher.update(state: .error(reason: reason))
        eventLog.error(
            event,
            source: .imessage,
            payload: ["error": reason]
        )
    }

    static func accessIssueReason(for error: Error) -> String? {
        guard let databaseError = error as? IMessageDatabase.DatabaseError else {
            return nil
        }
        switch databaseError {
        case .openFailed(let code, let message):
            return isAuthorizationDenied(code: code, message: message)
                ? "imessage_full_disk_access_required"
                : nil
        case .prepareFailed(let message), .stepFailed(let message):
            return isAuthorizationDenied(code: nil, message: message)
                ? "imessage_full_disk_access_required"
                : nil
        }
    }

    private static func isAuthorizationDenied(code: Int32?, message: String) -> Bool {
        if code == 23 { return true }
        let normalized = message.lowercased()
        return normalized.contains("authorization denied")
            || normalized.contains("autheloirzation denied")
    }

    // MARK: - Record construction

    /// Wraps `MessageRecord` with the local-only metadata the source
    /// uses during a cycle: the original `ROWID` (for cursor advance)
    /// and the raw handles (for blocklist filtering). Neither field is
    /// included in the wire payload that ships to the cloud.
    struct BuiltRecord: Sendable {
        let record: MessageRecord
        let envelopeRowID: Int64
        let allHandles: [String]
    }

    /// Direction the cursor walk is going on a given cycle. `newerThan`
    /// pulls everything strictly greater than the bound (sorted DESC);
    /// `olderThan` pulls everything strictly less (also DESC). Both
    /// queries are bounded by `limit`.
    nonisolated enum QueryKind: Sendable {
        case newerThan(Int64)
        case olderThan(Int64)
    }

    nonisolated private static func buildRecords(
        databaseURL: URL,
        kind: QueryKind,
        limit: Int
    ) throws -> [BuiltRecord] {
        let db = try IMessageDatabase(url: databaseURL)
        let raws: [RawMessage]
        switch kind {
        case .newerThan(let rowid):
            raws = try db.messagesNewerThan(rowid: rowid, limit: limit)
        case .olderThan(let rowid):
            raws = try db.messagesOlderThan(rowid: rowid, limit: limit)
        }
        var built: [BuiltRecord] = []
        built.reserveCapacity(raws.count)
        for raw in raws {
            let senderHandle: String? = try raw.handleRowID.flatMap {
                try db.handle(rowid: $0)
            }
            let chat: ChatInfo? = try raw.chatRowID.flatMap {
                try db.chat(rowid: $0)
            }
            let text = Self.bodyText(raw: raw)
            let record = Self.record(
                raw: raw,
                senderHandle: senderHandle,
                chat: chat,
                text: text
            )
            var handles: [String] = []
            if let s = senderHandle { handles.append(s) }
            if let chat { handles.append(contentsOf: chat.participantHandles) }
            built.append(
                BuiltRecord(
                    record: record,
                    envelopeRowID: raw.rowID,
                    allHandles: handles
                )
            )
        }
        return built
    }

    nonisolated private static func bodyText(raw: RawMessage) -> String? {
        // Apple sometimes stores raw binary (a bplist00 archive or its
        // header byte fragments) inside `m.text`. SQLite returns those
        // bytes as a UTF-8 string, which yields garbage like
        // "X$versionY$archiverT$topX$objects" (the bplist's top-level
        // keys concatenated). Reject any such payload at both layers
        // so we never store the bplist artifact masquerading as text.
        if let text = raw.text, !text.isEmpty, !looksLikeBinaryArtifact(text) {
            return text
        }
        if let blob = raw.attributedBody,
           let decoded = AttributedBodyDecoder.decode(blob),
           !looksLikeBinaryArtifact(decoded) {
            return decoded
        }
        return nil
    }

    /// True when a `m.text` string is actually the byte representation
    /// of a binary plist (or its leading keys). Hits exact-prefix
    /// patterns rather than heuristics so we don't false-positive on
    /// legitimate message bodies that happen to mention "bplist".
    nonisolated private static func looksLikeBinaryArtifact(_ s: String) -> Bool {
        if s.hasPrefix("bplist") { return true }
        // Any presence of these bplist top-level keys is conclusive —
        // they don't occur in normal message text in this exact form,
        // and they're the dead-give-away when SQLite returns the
        // text column's raw bplist bytes as a "string".
        let markers = ["$version", "$archiver", "$objects", "$top", "NSKeyedArchiver"]
        for marker in markers {
            if s.contains(marker) { return true }
        }
        // Leading non-printable / non-whitespace byte means we're
        // looking at binary data, not a body string.
        if let first = s.unicodeScalars.first,
           first.value < 0x20,
           first != "\n", first != "\r", first != "\t" {
            return true
        }
        return false
    }

    nonisolated private static func record(
        raw: RawMessage,
        senderHandle: String?,
        chat: ChatInfo?,
        text: String?
    ) -> MessageRecord {
        let chatHandles = chat?.participantHandles ?? senderHandle.map { [$0] } ?? []
        let chatStyle = chat?.style ?? .im
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let sentAt = isoFormatter.string(from: raw.sentAt)

        let chatHandlesJSON = (try? JSONEncoder().encode(chatHandles))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        return MessageRecord(
            guid: raw.guid,
            localId: "p:\(raw.rowID)",
            isFromMe: raw.isFromMe,
            senderHandle: senderHandle,
            chatKey: chat?.guid,
            chatDisplayName: chat?.displayName,
            chatStyle: chatStyle.rawValue,
            text: text,
            sentAt: sentAt,
            hasAttachments: raw.hasAttachments,
            chatHandlesJSON: chatHandlesJSON,
            attachmentsJSON: "[]"
        )
    }
}
