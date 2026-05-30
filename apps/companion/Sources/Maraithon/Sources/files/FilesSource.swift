import AsyncAlgorithms
import Foundation
import Observation

/// `SourceProtocol` implementation for the user's macOS files under
/// `~/Documents`, `~/Desktop`, and `~/Downloads`.
///
/// Files change far less often than iMessages or notes, so this source
/// polls every 5 minutes by default. The cadence stretches when Low
/// Power Mode is on, matching the iMessage / Notes / Voice Memos
/// behaviour.
///
/// Sandbox note: the companion app runs with the App Sandbox disabled,
/// so reading these three directories does not require any additional
/// entitlement or user-granted permission. (If we ever flip the
/// sandbox back on, this source will need either a security-scoped
/// bookmark per root or a `com.apple.security.files.user-selected`
/// entitlement.) The privacy filters in `FilesScanner` enforce the
/// outbound policy regardless of sandbox state.
///
/// Logging: every transition emits through `EventLog` with
/// `source: .files`. Path and filename contents are never logged in
/// full — the source logs counts, the cursor size, and at most an
/// 8-char `guid` prefix per batch sample.
@MainActor
final class FilesSource: SourceProtocol {
    let id: String = "files"
    let displayName: String = "Files"
    let symbol: String = "folder"
    let statusPublisher: SourceStatusPublisher

    typealias Outbox = @Sendable (UUID, [FilePayload]) async throws -> SyncOutcome

    /// Extracted file text longer than this gets an on-device summary
    /// attached to the outbound payload. Matches the brief: "if
    /// extracted text > 2000 chars, summarize". Files have a higher
    /// threshold than notes because the typical file is structured
    /// (markdown, source) and benefits less from a heuristic summary.
    nonisolated static let summaryThreshold = 2000

    private let cursor: FilesCursor
    private let eventLog: EventLog
    private let outbox: Outbox
    private let deviceIdProvider: @MainActor @Sendable () -> UUID
    private let database: FilesDatabase
    private let pollInterval: TimeInterval
    private let lowPowerPollInterval: TimeInterval
    private let lowPowerProbe: @Sendable () -> Bool
    private let summarizer: Summarizing

    private var pollTask: Task<Void, Never>?
    private var isPaused: Bool = false
    private var lastLowPowerState: Bool = false
    private var lastTickAt: ContinuousClock.Instant?

    init(
        database: FilesDatabase = FilesDatabase(),
        cursor: FilesCursor = FilesCursor(),
        eventLog: EventLog,
        deviceIdProvider: @escaping @MainActor @Sendable () -> UUID,
        pollInterval: TimeInterval = 180,
        lowPowerPollInterval: TimeInterval? = nil,
        lowPowerProbe: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
        summarizer: Summarizing = OnDeviceSummarizer(),
        outbox: @escaping Outbox
    ) {
        self.database = database
        self.cursor = cursor
        self.eventLog = eventLog
        self.outbox = outbox
        self.deviceIdProvider = deviceIdProvider
        self.pollInterval = pollInterval
        // Default: 4× base cadence when on battery saver, capped at 30
        // minutes. Files are even less time-sensitive than notes.
        self.lowPowerPollInterval = lowPowerPollInterval ?? min(pollInterval * 4, 1800)
        self.lowPowerProbe = lowPowerProbe
        self.summarizer = summarizer
        self.statusPublisher = SourceStatusPublisher(sourceID: "files", state: .disconnected)
    }

    /// Production-style convenience init that binds the outbox to a
    /// `FilesIngest`. Tests should use the designated init above to
    /// inject a payload capturer instead.
    convenience init(
        database: FilesDatabase = FilesDatabase(),
        cursor: FilesCursor = FilesCursor(),
        eventLog: EventLog,
        ingest: FilesIngest,
        deviceIdProvider: @escaping @MainActor @Sendable () -> UUID,
        pollInterval: TimeInterval = 180,
        lowPowerPollInterval: TimeInterval? = nil,
        lowPowerProbe: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
        summarizer: Summarizing = OnDeviceSummarizer()
    ) {
        self.init(
            database: database,
            cursor: cursor,
            eventLog: eventLog,
            deviceIdProvider: deviceIdProvider,
            pollInterval: pollInterval,
            lowPowerPollInterval: lowPowerPollInterval,
            lowPowerProbe: lowPowerProbe,
            summarizer: summarizer,
            outbox: { deviceId, payloads in
                try await ingest.ingestFiles(
                    batch: FilesIngestBatch(
                        deviceId: deviceId,
                        source: "files",
                        files: payloads
                    )
                )
            }
        )
    }

    // MARK: - SourceProtocol

    func start() {
        guard pollTask == nil else { return }
        isPaused = false
        statusPublisher.update(state: .connected)
        eventLog.info("files.start", source: .files)
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
        eventLog.info("files.pause", source: .files)
    }

    func syncNow() async throws {
        eventLog.info("files.sync_now", source: .files)
        try await runCycle()
    }

    func clearLocalState() {
        cursor.reset()
        statusPublisher.update(state: .disconnected)
        eventLog.info("files.clear_local_state", source: .files)
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
                "files.cadence_changed",
                source: .files,
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
                "files.cycle_failed",
                source: .files,
                payload: ["error": String(describing: error)]
            )
        }
    }

    /// Single sync cycle: scan everything beyond the cursor, build
    /// payloads, POST them, advance the cursor only after the POST
    /// returns success.
    func runCycle() async throws {
        statusPublisher.update(state: .syncing)
        let startCursor = cursor.snapshot()
        let database = self.database
        let raws = try await Task.detached(priority: .utility) {
            try database.filesModifiedAfter(cursor: startCursor)
        }.value

        if raws.isEmpty {
            eventLog.debug(
                "files.cycle_empty",
                source: .files,
                payload: ["cursor_size": String(startCursor.count)]
            )
            statusPublisher.recordHealthyCycle(at: Date())
            statusPublisher.update(state: .connected)
            return
        }

        let basePayloads = raws.map(Self.payload(from:))
        let payloads = await Self.attachSummaries(
            raws: raws,
            base: basePayloads,
            summarizer: summarizer,
            threshold: Self.summaryThreshold
        )
        let deviceId = deviceIdProvider()
        let outcome = try await outbox(deviceId, payloads)

        // Advance the cursor by merging every pushed file's
        // (absolute path, modified_at) into the persisted snapshot.
        // We only mutate after the POST returns success so a 5xx
        // leaves the cursor untouched and the next cycle retries.
        var nextCursor = startCursor
        for raw in raws {
            nextCursor[raw.localId] = raw.modifiedAt
        }
        cursor.write(nextCursor)

        statusPublisher.recordSync(
            at: Date(),
            accepted: outcome.accepted,
            duplicate: outcome.duplicate
        )
        statusPublisher.update(state: .connected)

        var payload: [String: String] = [:]
        payload["count"] = String(payloads.count)
        payload["accepted"] = String(outcome.accepted)
        payload["duplicate"] = String(outcome.duplicate)
        payload["cursor_size"] = String(nextCursor.count)
        payload["first_guid_prefix"] = payloads.first.map { Self.guidPrefix($0.guid) } ?? ""
        payload["with_text"] = String(raws.filter { $0.textContent != nil }.count)
        payload["text_truncated"] = String(raws.filter { $0.textTruncated }.count)

        eventLog.info("files.cycle_pushed", source: .files, payload: payload)
    }

    // MARK: - Payload shaping

    /// Static base shape so tests and the runtime path agree. Encodes
    /// the extracted text as base64 — the server is happier with a
    /// single text field than with two parallel "plain string vs.
    /// base64" code paths.
    nonisolated static func payload(from raw: RawFile) -> FilePayload {
        let base64: String? = raw.textContent.map { text in
            Data(text.utf8).base64EncodedString()
        }
        return FilePayload(
            guid: raw.guid,
            localId: raw.localId,
            path: raw.path,
            filename: raw.filename,
            extension: raw.extension,
            mimeType: raw.mimeType,
            byteSize: raw.byteSize,
            textContentBase64: base64,
            textTruncated: raw.textTruncated,
            createdAt: raw.createdAt,
            modifiedAt: raw.modifiedAt
        )
    }

    nonisolated private static func guidPrefix(_ guid: String) -> String {
        String(guid.prefix(8))
    }

    /// Test-target entrypoint for `attachSummaries`. The function itself
    /// stays internal so production callers can't bypass `runCycle`'s
    /// thresholds — only the dedicated test bridge file invokes this
    /// path directly.
    static func testHook_attachSummaries(
        raws: [RawFile],
        base: [FilePayload],
        summarizer: Summarizing,
        threshold: Int
    ) async -> [FilePayload] {
        await attachSummaries(
            raws: raws, base: base, summarizer: summarizer, threshold: threshold
        )
    }

    /// Build a new `[FilePayload]` from `base`, attaching an on-device
    /// summary whenever the raw row's extracted text is longer than
    /// `threshold` characters. Summary failures degrade silently — we
    /// keep the original payload and ship without a summary rather
    /// than block the cycle.
    static func attachSummaries(
        raws: [RawFile],
        base: [FilePayload],
        summarizer: Summarizing,
        threshold: Int
    ) async -> [FilePayload] {
        guard raws.count == base.count else {
            // Defensive: zip below would silently drop the mismatch.
            // In practice `raws.map(Self.payload(from:))` is always a
            // 1:1 transform; if that contract ever changes we'd rather
            // ship the un-summarised batch than crash.
            return base
        }
        var out: [FilePayload] = []
        out.reserveCapacity(base.count)
        for (raw, payload) in zip(raws, base) {
            guard let body = raw.textContent, body.count > threshold else {
                out.append(payload)
                continue
            }
            let summary: String?
            do {
                let raw = try await summarizer.summarize(text: body, hint: .file)
                summary = raw.isEmpty ? nil : raw
            } catch {
                summary = nil
            }
            out.append(
                FilePayload(
                    guid: payload.guid,
                    localId: payload.localId,
                    path: payload.path,
                    filename: payload.filename,
                    extension: payload.extension,
                    mimeType: payload.mimeType,
                    byteSize: payload.byteSize,
                    textContentBase64: payload.textContentBase64,
                    textTruncated: payload.textTruncated,
                    createdAt: payload.createdAt,
                    modifiedAt: payload.modifiedAt,
                    summary: summary
                )
            )
        }
        return out
    }
}
