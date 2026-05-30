import AsyncAlgorithms
import Foundation
import Observation
import OSLog

/// `SourceProtocol` implementation for Apple Notes
/// (`~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite`).
///
/// Mirrors `IMessageSource`:
///   * Opens the Notes Core Data store read-only and resumes from
///     `NotesCursor`.
///   * Polls on a configurable cadence (default 60s — slower than
///     iMessage because users edit notes far less frequently than they
///     send messages).
///   * Builds `NoteRecord`s and posts them directly via `NotesIngest`,
///     bypassing `SyncEngine`'s iMessage-shaped queue (see the
///     `NotesIngest` doc-comment for the trade-off).
///   * Logs every transition through `EventLog`. We use `source: .system`
///     for `LogSource` because the enum doesn't have a `.notes` case yet;
///     adding one would mean touching `EventLog.swift` which lives
///     outside this team's scope — the brief explicitly tells us to fall
///     back to `.system`.
///   * Honors Low Power Mode the same way `IMessageSource` does, by
///     stretching cadence and re-reading the power state per tick.
///
/// `@MainActor` because of the `@Observable` status publisher; the
/// actual SQLite + HTTP work happens in detached tasks and re-enters
/// the main actor only to update status.
@MainActor
final class NotesSource: SourceProtocol {
    let id: String = "notes"
    let displayName: String = "Notes"
    let symbol: String = "note.text"
    let statusPublisher: SourceStatusPublisher

    /// Bodies longer than this get an on-device summary attached to the
    /// outbound payload. Matches the brief: "if body is > 1000 chars,
    /// also compute summary". Shorter notes ship without a summary
    /// because the body itself is already compact enough.
    nonisolated static let summaryThreshold = 1000

    private let cursor: NotesCursor
    private let eventLog: EventLog
    private let ingest: NotesIngest
    private let deviceIdProvider: @MainActor () -> UUID
    private let databaseURL: URL
    private let pollInterval: TimeInterval
    private let lowPowerPollInterval: TimeInterval
    private let batchLimit: Int
    private let lowPowerProbe: @Sendable () -> Bool
    private let summarizer: Summarizing

    private var pollTask: Task<Void, Never>?
    private var isPaused: Bool = false
    private var lastLowPowerState: Bool = false
    private var lastTickAt: ContinuousClock.Instant?

    init(
        databaseURL: URL = NotesDatabase.defaultDatabaseURL,
        cursor: NotesCursor = NotesCursor(),
        eventLog: EventLog,
        ingest: NotesIngest,
        deviceIdProvider: @escaping @MainActor () -> UUID,
        pollInterval: TimeInterval = 180,
        lowPowerPollInterval: TimeInterval? = nil,
        batchLimit: Int = 200,
        lowPowerProbe: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
        summarizer: Summarizing = OnDeviceSummarizer()
    ) {
        self.databaseURL = databaseURL
        self.cursor = cursor
        self.eventLog = eventLog
        self.ingest = ingest
        self.deviceIdProvider = deviceIdProvider
        self.pollInterval = pollInterval
        // Default: 4× base cadence when on battery saver, capped at 10
        // minutes (a notch longer than iMessage's 5-minute cap since
        // notes are inherently less time-sensitive).
        self.lowPowerPollInterval = lowPowerPollInterval ?? min(pollInterval * 4, 600)
        self.batchLimit = batchLimit
        self.lowPowerProbe = lowPowerProbe
        self.summarizer = summarizer
        self.statusPublisher = SourceStatusPublisher(sourceID: "notes", state: .disconnected)
    }

    // MARK: - SourceProtocol

    func start() {
        guard pollTask == nil else { return }
        isPaused = false
        statusPublisher.update(state: .connected)
        eventLog.info("notes.start", source: .system)
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
        eventLog.info("notes.pause", source: .system)
    }

    func syncNow() async throws {
        eventLog.info("notes.sync_now", source: .system)
        do {
            try await runCycle()
        } catch {
            markCycleFailed(error, event: "notes.sync_now_failed")
            throw error
        }
    }

    func clearLocalState() {
        cursor.reset()
        statusPublisher.clearIssues()
        statusPublisher.update(state: .disconnected)
        eventLog.info("notes.clear_local_state", source: .system)
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
                "notes.cadence_changed",
                source: .system,
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
            markCycleFailed(error, event: "notes.cycle_failed")
        }
    }

    /// Two-phase newest-first cycle: pull `Z_PK > newestSeen` first,
    /// then fall back to `Z_PK < backfillFrom`. So today's notes ship
    /// on the first cycle, then history walks backward.
    func runCycle() async throws {
        statusPublisher.update(state: .syncing)
        let newestSeenBefore = cursor.newestSeen
        let backfillFromBefore = cursor.backfillFrom

        let (built, phase, queryFloor) = try await Task.detached(priority: .utility) {
            [databaseURL, batchLimit] () -> ([BuiltNote], String, Int64) in
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

        if built.isEmpty {
            eventLog.debug(
                "notes.cycle_empty",
                source: .system,
                payload: ["phase": phase, "query_floor": String(queryFloor)]
            )
            statusPublisher.recordHealthyCycle(at: Date())
            statusPublisher.update(state: .connected)
            return
        }

        // Attach on-device summaries for any note whose body is longer
        // than `summaryThreshold`. Done after the detached read so the
        // summarizer (which may be `@MainActor`-bound or `Sendable`)
        // can run sequentially in the source's actor context. Failures
        // degrade silently via the summarizer's own contract.
        let recordsForWire = await Self.attachSummaries(
            built: built,
            summarizer: summarizer,
            threshold: Self.summaryThreshold
        )

        let deviceId = deviceIdProvider()
        let batch = NotesIngestBatch(
            deviceId: deviceId,
            source: "notes",
            notes: recordsForWire
        )
        let outcome = try await ingest.ingestNotes(batch: batch)

        let rowIDs = built.map(\.rowID)
        if let maxRow = rowIDs.max() { cursor.advanceNewest(to: maxRow) }
        if let minRow = rowIDs.min() { cursor.advanceBackfill(to: minRow) }
        statusPublisher.recordSync(
            at: Date(),
            accepted: outcome.accepted,
            duplicate: outcome.duplicate,
            failed: outcome.invalid,
            issueSummary: outcome.invalid > 0
                ? Self.syncIssueSummary(count: outcome.invalid, singular: "note", plural: "notes")
                : nil
        )
        statusPublisher.update(state: .connected)
        eventLog.info(
            "notes.cycle_pushed",
            source: .system,
            payload: [
                "phase": phase,
                "count": String(built.count),
                "accepted": String(outcome.accepted),
                "duplicate": String(outcome.duplicate),
                "invalid": String(outcome.invalid),
                "newest_seen": String(cursor.newestSeen),
                "backfill_from": String(cursor.backfillFrom)
            ]
        )
    }

    private static func syncIssueSummary(count: Int, singular: String, plural: String) -> String {
        count == 1
            ? "1 \(singular) did not sync."
            : "\(count.formatted(.number)) \(plural) did not sync."
    }

    private func markCycleFailed(_ error: Error, event: String) {
        if let reason = Self.accessIssueReason(for: error) {
            statusPublisher.clearIssues()
            statusPublisher.update(state: .needsAttention(reason: reason))
            eventLog.warning(
                event,
                source: .system,
                payload: ["reason": reason, "error": String(describing: error)]
            )
            return
        }
        let reason = String(describing: error)
        statusPublisher.recordCycleFailure(at: Date(), reason: reason)
        statusPublisher.update(state: .error(reason: reason))
        eventLog.error(
            event,
            source: .system,
            payload: ["error": reason]
        )
    }

    static func accessIssueReason(for error: Error) -> String? {
        guard let databaseError = error as? NotesDatabase.DatabaseError else {
            return nil
        }
        switch databaseError {
        case .openFailed(let code, let message):
            return isAuthorizationDenied(code: code, message: message)
                ? "notes_full_disk_access_required"
                : nil
        case .prepareFailed(let message), .stepFailed(let message):
            return isAuthorizationDenied(code: nil, message: message)
                ? "notes_full_disk_access_required"
                : nil
        case .entityMissing:
            return nil
        }
    }

    private static func isAuthorizationDenied(code: Int32?, message: String) -> Bool {
        if code == 23 { return true }
        let normalized = message.lowercased()
        return normalized.contains("authorization denied")
            || normalized.contains("autheloirzation denied")
    }

    // MARK: - Record construction

    /// Pairs a built `NoteRecord` with its original `Z_PK` so the source
    /// can advance the cursor after a successful POST. `Z_PK` is local-
    /// only and never ships over the wire.
    struct BuiltNote: Sendable {
        let record: NoteRecord
        let rowID: Int64
    }

    /// Test-target entrypoint for `attachSummaries`. The function itself
    /// stays internal (`static`) so production callers can't bypass
    /// `runCycle`'s thresholds — only the dedicated test bridge file
    /// invokes this path directly.
    static func testHook_attachSummaries(
        built: [BuiltNote],
        summarizer: Summarizing,
        threshold: Int
    ) async -> [NoteRecord] {
        await attachSummaries(built: built, summarizer: summarizer, threshold: threshold)
    }

    /// Walk every built note and attach a summary when the body exceeds
    /// `threshold` characters. Summary failures degrade silently — we
    /// keep the original record and ship it without a summary rather
    /// than block the cycle. Runs sequentially because each summary is
    /// fast (heuristic path is ~tens of microseconds per KB) and the
    /// batch size is bounded by `batchLimit`.
    static func attachSummaries(
        built: [BuiltNote],
        summarizer: Summarizing,
        threshold: Int
    ) async -> [NoteRecord] {
        var out: [NoteRecord] = []
        out.reserveCapacity(built.count)
        for entry in built {
            let record = entry.record
            guard let body = record.body, body.count > threshold else {
                out.append(record)
                continue
            }
            let summary: String?
            do {
                let raw = try await summarizer.summarize(text: body, hint: .note)
                summary = raw.isEmpty ? nil : raw
            } catch {
                // Never block ingest on a summarizer failure.
                summary = nil
            }
            out.append(
                NoteRecord(
                    guid: record.guid,
                    localId: record.localId,
                    title: record.title,
                    snippet: record.snippet,
                    body: record.body,
                    bodyFormat: record.bodyFormat,
                    folder: record.folder,
                    isPinned: record.isPinned,
                    createdAt: record.createdAt,
                    modifiedAt: record.modifiedAt,
                    summary: summary
                )
            )
        }
        return out
    }

    /// Direction the Notes cursor walk is going on a given cycle.
    nonisolated enum QueryKind: Sendable {
        case newerThan(Int64)
        case olderThan(Int64)
    }

    nonisolated private static func buildRecords(
        databaseURL: URL,
        kind: QueryKind,
        limit: Int
    ) throws -> [BuiltNote] {
        let db = try NotesDatabase(url: databaseURL)
        let raws: [RawNote]
        switch kind {
        case .newerThan(let rowid):
            raws = try db.notesNewerThan(rowid: rowid, limit: limit)
        case .olderThan(let rowid):
            raws = try db.notesOlderThan(rowid: rowid, limit: limit)
        }
        var built: [BuiltNote] = []
        built.reserveCapacity(raws.count)
        var blobsPresent = 0
        var decodedOK = 0
        // Cache folder names so a batch full of notes from the same
        // folder doesn't repeat the lookup query.
        var folderCache: [Int64: String?] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        for raw in raws {
            let folderName: String?
            if let folderRow = raw.folderRowID {
                if let cached = folderCache[folderRow] {
                    folderName = cached
                } else {
                    let resolved = try db.folder(rowid: folderRow)
                    folderCache[folderRow] = resolved
                    folderName = resolved
                }
            } else {
                folderName = nil
            }
            // Body decode happens inline (still inside the detached
            // utility task) because the gzipped protobuf is small —
            // typical notes are a few KB after inflate. Decode failure
            // is non-fatal: the rest of the note still ships and the
            // server keeps a `nil` body, exactly as a body-less legacy
            // row would.
            let body: String?
            let bodyFormat: String?
            if let blob = raw.bodyBlob {
                blobsPresent += 1
                if let decoded = NotesBodyDecoder.decode(blob) {
                    decodedOK += 1
                    body = decoded
                    bodyFormat = "plain"
                } else {
                    body = nil
                    bodyFormat = nil
                }
            } else {
                body = nil
                bodyFormat = nil
            }
            let record = NoteRecord(
                guid: raw.guid,
                localId: "p:\(raw.rowID)",
                title: raw.title,
                snippet: raw.snippet,
                body: body,
                bodyFormat: bodyFormat,
                folder: folderName,
                isPinned: raw.isPinned,
                createdAt: raw.createdAt.map(iso.string(from:)),
                modifiedAt: raw.modifiedAt.map(iso.string(from:))
            )
            built.append(BuiltNote(record: record, rowID: raw.rowID))
        }
        Self.diagnosticsLog(
            "notes.body_decode rows=\(raws.count) blobs_present=\(blobsPresent) decoded_ok=\(decodedOK)"
        )
        return built
    }

    nonisolated private static func diagnosticsLog(_ message: String) {
        os.Logger(subsystem: "com.maraithon.companion", category: "notes")
            .info("\(message, privacy: .public)")
    }
}

/// Redaction helper for note title/snippet content. Notes don't carry
/// phone numbers, but title/snippet bodies are user-written prose and
/// must never appear verbatim in the log buffer or the on-disk log
/// file. We truncate to a short prefix and append the original length
/// so log readers can still reason about row sizes.
///
/// Kept as a free enum (not a method on the source) so detached
/// `Task`s can call it without touching `@MainActor` state.
enum NotesRedactor {
    /// Maximum prefix length in characters before redaction kicks in.
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
