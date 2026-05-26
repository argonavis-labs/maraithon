import AsyncAlgorithms
import Foundation
import Observation

/// `SourceProtocol` implementation for `~/Library/Application Support/com.apple.voicememos/Recordings/CloudRecordings.db`.
///
/// Mirrors `IMessageSource`'s shape: a polling loop driven by
/// `AsyncTimerSequence`, a UserDefaults-backed monotonic cursor on
/// `Z_PK`, and a battery-aware cadence that stretches when Low Power
/// Mode is on. The big differences:
///
///   * The wire shape is the spec's `voice_memos` array, not the iMessage
///     envelope, so we push directly through `VoiceMemosIngest` instead
///     of the shared `SyncEngine` enqueue/drain path.
///   * Optional `ZCUSTOMLABEL`: when nil/empty we synthesize a derived
///     title (`Voice Memo · <date>`) before push. The wire `title` field
///     stays nullable too — the derived value is what callers see, never
///     a fabricated user-set label saved back to disk.
///   * Missing audio files are dropped by the database reader before they
///     ever reach the source (see `VoiceMemosDatabase.recordingsAfter`).
///
/// Logging follows the same redaction rule as iMessage: titles can contain
/// user-sensitive labels, so we only log counts and `guid` prefixes — never
/// the raw `ZCUSTOMLABEL`.
@MainActor
final class VoiceMemosSource: SourceProtocol {
    let id: String = "voice_memos"
    let displayName: String = "Voice Memos"
    let symbol: String = "waveform"
    let statusPublisher: SourceStatusPublisher

    /// Closure the source uses to push a batch. Lives at the source's
    /// boundary so tests can capture payloads without going through the
    /// HTTP transport — matches `IMessageSource.outbox`'s pattern.
    typealias Outbox = @Sendable (UUID, [VoiceMemoPayload]) async throws -> SyncOutcome

    /// Per-record audio cap. Files larger than this still ingest as
    /// metadata-only rows — the server sets `audio_truncated = true`
    /// for us — but the bytes themselves get dropped client-side so we
    /// never even base64-encode them. 2 MB is roughly a 90-second m4a
    /// at stock Voice Memos quality (~32 kbps mono AAC). The cap is
    /// deliberately tight so an aggregate batch of `batchLimit`
    /// recordings (≤ 20 MB compressed JSON) fits comfortably inside
    /// Phoenix's default frame / request-body limits — anything larger
    /// stalled the realtime push indefinitely in production.
    nonisolated static let maxAudioBytes: Int64 = 16 * 1024 * 1024

    private let cursor: VoiceMemosCursor
    private let eventLog: EventLog
    private let outbox: Outbox
    private let deviceIdProvider: @MainActor @Sendable () -> UUID
    private let databaseURL: URL
    private let pollInterval: TimeInterval
    private let lowPowerPollInterval: TimeInterval
    private let batchLimit: Int
    private let lowPowerProbe: @Sendable () -> Bool
    private let transcriber: VoiceMemosTranscriber
    private let audioReader: @Sendable (URL) throws -> Data
    private let maxAudioBytes: Int64
    private let summarizer: Summarizing

    private var pollTask: Task<Void, Never>?
    private var isPaused: Bool = false
    private var lastLowPowerState: Bool = false
    private var lastTickAt: ContinuousClock.Instant?
    /// Sticky flag set when the OS reports `kLSRErrorDomain Code=201`
    /// during transcription. Once any memo trips this we flip the
    /// source to `needsAttention("voice_memos_speech_disabled")` after
    /// the current cycle's batch ships, so the user sees the focused
    /// unblock view with a deep link to Speech Recognition settings.
    /// Reset on every `runCycle()` so a re-enable after the user fixes
    /// it is detected promptly.
    private var speechDisabledDetected: Bool = false

    init(
        databaseURL: URL = VoiceMemosDatabase.defaultDatabaseURL,
        cursor: VoiceMemosCursor = VoiceMemosCursor(),
        eventLog: EventLog,
        deviceIdProvider: @escaping @MainActor @Sendable () -> UUID,
        pollInterval: TimeInterval = 180,
        lowPowerPollInterval: TimeInterval? = nil,
        batchLimit: Int = 3,
        lowPowerProbe: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
        transcriber: VoiceMemosTranscriber = VoiceMemosTranscriber(),
        audioReader: @escaping @Sendable (URL) throws -> Data = { url in
            try Data(contentsOf: url, options: [.mappedIfSafe])
        },
        maxAudioBytes: Int64 = VoiceMemosSource.maxAudioBytes,
        summarizer: Summarizing = OnDeviceSummarizer(),
        outbox: @escaping Outbox
    ) {
        self.databaseURL = databaseURL
        self.cursor = cursor
        self.eventLog = eventLog
        self.outbox = outbox
        self.deviceIdProvider = deviceIdProvider
        self.pollInterval = pollInterval
        self.lowPowerPollInterval = lowPowerPollInterval ?? min(pollInterval * 4, 300)
        self.batchLimit = batchLimit
        self.lowPowerProbe = lowPowerProbe
        self.transcriber = transcriber
        self.audioReader = audioReader
        self.maxAudioBytes = maxAudioBytes
        self.summarizer = summarizer
        self.statusPublisher = SourceStatusPublisher(state: .disconnected)
    }

    /// Convenience init that wires the outbox to a `VoiceMemosIngest`.
    /// Production callers use this; tests use the designated init above to
    /// capture payloads directly.
    convenience init(
        databaseURL: URL = VoiceMemosDatabase.defaultDatabaseURL,
        cursor: VoiceMemosCursor = VoiceMemosCursor(),
        eventLog: EventLog,
        ingest: VoiceMemosIngest,
        deviceIdProvider: @escaping @MainActor @Sendable () -> UUID,
        pollInterval: TimeInterval = 180,
        lowPowerPollInterval: TimeInterval? = nil,
        batchLimit: Int = 3,
        lowPowerProbe: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
        transcriber: VoiceMemosTranscriber = VoiceMemosTranscriber(),
        summarizer: Summarizing = OnDeviceSummarizer()
    ) {
        self.init(
            databaseURL: databaseURL,
            cursor: cursor,
            eventLog: eventLog,
            deviceIdProvider: deviceIdProvider,
            pollInterval: pollInterval,
            lowPowerPollInterval: lowPowerPollInterval,
            batchLimit: batchLimit,
            lowPowerProbe: lowPowerProbe,
            transcriber: transcriber,
            summarizer: summarizer,
            outbox: { deviceId, payloads in
                try await ingest.push(deviceId: deviceId, voiceMemos: payloads)
            }
        )
    }

    // MARK: - SourceProtocol

    func start() {
        guard pollTask == nil else { return }
        isPaused = false
        statusPublisher.update(state: .connected)
        eventLog.info("voice_memos.start", source: .voiceMemos)
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
        eventLog.info("voice_memos.pause", source: .voiceMemos)
    }

    func syncNow() async throws {
        eventLog.info("voice_memos.sync_now", source: .voiceMemos)
        try await runCycle()
    }

    func clearLocalState() {
        cursor.reset()
        statusPublisher.update(state: .disconnected)
        eventLog.info("voice_memos.clear_local_state", source: .voiceMemos)
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
                "voice_memos.cadence_changed",
                source: .voiceMemos,
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
                "voice_memos.cycle_failed",
                source: .voiceMemos,
                payload: ["error": String(describing: error)]
            )
        }
    }

    /// Single sync cycle: read everything beyond the cursor, build payloads,
    /// push, advance the cursor only after the push returns success.
    func runCycle() async throws {
        statusPublisher.update(state: .syncing)
        // Reset the speech-disabled flag at the start of each cycle so
        // a re-enable on the user's machine flips us back to connected
        // on the next cycle without a relaunch.
        speechDisabledDetected = false
        let newestSeenBefore = cursor.newestSeen
        let backfillFromBefore = cursor.backfillFrom

        let (raws, phase, queryFloor): ([RawVoiceMemo], String, Int64) = try await Task.detached(priority: .utility) {
            [databaseURL, batchLimit] () -> ([RawVoiceMemo], String, Int64) in
            let db = try VoiceMemosDatabase(url: databaseURL)
            let newer = try db.recordingsNewerThan(rowid: newestSeenBefore, limit: batchLimit)
            if !newer.isEmpty {
                return (newer, "newer", newestSeenBefore)
            }
            let older = try db.recordingsOlderThan(rowid: backfillFromBefore, limit: batchLimit)
            return (older, "backfill", backfillFromBefore)
        }.value

        if raws.isEmpty {
            eventLog.debug(
                "voice_memos.cycle_empty",
                source: .voiceMemos,
                payload: ["phase": phase, "query_floor": String(queryFloor)]
            )
            statusPublisher.recordHealthyCycle(at: Date())
            statusPublisher.update(state: .connected)
            return
        }

        var payloads: [VoiceMemoPayload] = []
        payloads.reserveCapacity(raws.count)
        var audioTruncated = 0
        var transcribed = 0
        for raw in raws {
            let payload = await buildPayload(from: raw)
            if payload.audioBytesBase64 == nil, raw.fileSizeBytes > maxAudioBytes {
                audioTruncated += 1
            }
            if payload.transcript != nil {
                transcribed += 1
            }
            payloads.append(payload)
        }
        let deviceId = deviceIdProvider()
        let outcome = try await outbox(deviceId, payloads)

        let rowIDs = raws.map(\.rowID)
        if let maxRow = rowIDs.max() { cursor.advanceNewest(to: maxRow) }
        if let minRow = rowIDs.min() { cursor.advanceBackfill(to: minRow) }
        statusPublisher.recordSync(
            at: Date(),
            accepted: outcome.accepted,
            duplicate: outcome.duplicate
        )
        if speechDisabledDetected {
            statusPublisher.update(
                state: .needsAttention(reason: "voice_memos_speech_disabled")
            )
        } else {
            statusPublisher.update(state: .connected)
        }
        eventLog.info(
            "voice_memos.cycle_pushed",
            source: .voiceMemos,
            payload: [
                "phase": phase,
                "count": String(payloads.count),
                "accepted": String(outcome.accepted),
                "duplicate": String(outcome.duplicate),
                "newest_seen": String(cursor.newestSeen),
                "backfill_from": String(cursor.backfillFrom),
                "first_guid_prefix": payloads.first.map { Self.guidPrefix($0.guid) } ?? "",
                "audio_truncated": String(audioTruncated),
                "transcribed": String(transcribed)
            ]
        )
    }

    // MARK: - Payload shaping

    /// Static base shape — useful when callers (or tests) want just the
    /// metadata payload, without bothering with audio bytes or
    /// transcription. The full audio+transcript pipeline lives on
    /// `buildPayload(from:)`.
    nonisolated static func payload(from raw: RawVoiceMemo) -> VoiceMemoPayload {
        VoiceMemoPayload(
            guid: raw.uniqueID,
            localId: "p:\(raw.rowID)",
            title: resolvedTitle(raw: raw),
            durationSeconds: raw.durationSeconds,
            fileSizeBytes: raw.fileSizeBytes,
            createdAt: raw.createdAt
        )
    }

    /// Full payload shaping: reads the `.m4a` (if under the cap),
    /// transcribes via the on-device recognizer, and attaches both to
    /// the wire payload. Any failure along the way degrades gracefully
    /// — at worst the metadata-only payload still ships, matching the
    /// pre-v1.5 behaviour. The audio cap is enforced before we even
    /// read the file (we already know its size from `RawVoiceMemo`)
    /// so oversize captures don't waste memory.
    func buildPayload(from raw: RawVoiceMemo) async -> VoiceMemoPayload {
        var base = Self.payload(from: raw)

        let (audioB64, audioMime): (String?, String?) = readAudio(raw: raw)
        let (transcript, engine, lang): (String?, String?, String?) = await transcribeIfPossible(raw: raw)
        let summary: String? = await summarizeTranscript(transcript)

        base = VoiceMemoPayload(
            guid: base.guid,
            localId: base.localId,
            title: base.title,
            durationSeconds: base.durationSeconds,
            fileSizeBytes: base.fileSizeBytes,
            createdAt: base.createdAt,
            audioBytesBase64: audioB64,
            audioMime: audioMime,
            transcript: transcript,
            transcriptEngine: engine,
            transcriptLang: lang,
            summary: summary
        )
        return base
    }

    /// Run the summarizer over a transcript if one exists. Returns nil
    /// for missing or empty transcripts; never propagates an error
    /// from the summarizer so an off-day model doesn't block ingest.
    private func summarizeTranscript(_ transcript: String?) async -> String? {
        guard let transcript, !transcript.isEmpty else { return nil }
        do {
            let summary = try await summarizer.summarize(text: transcript, hint: .voiceMemo)
            return summary.isEmpty ? nil : summary
        } catch {
            return nil
        }
    }

    /// Returns `(audio_bytes_base64, audio_mime)` for a row, dropping
    /// the bytes (but keeping the mime) when the file is oversize or
    /// unreadable. The server treats nil-bytes-with-truncated-flag the
    /// same way regardless of why we dropped them, so logs aren't tied
    /// to any particular failure mode here.
    private func readAudio(raw: RawVoiceMemo) -> (String?, String?) {
        guard let url = raw.audioURL else { return (nil, nil) }
        if raw.fileSizeBytes > maxAudioBytes {
            eventLog.info(
                "voice_memos.audio_oversize",
                source: .voiceMemos,
                payload: [
                    "guid_prefix": Self.guidPrefix(raw.uniqueID),
                    "bytes": String(raw.fileSizeBytes),
                    "cap": String(maxAudioBytes)
                ]
            )
            return (nil, "audio/m4a")
        }
        let reader = audioReader
        let cap = maxAudioBytes
        do {
            let data = try reader(url)
            // Guard once more against the on-disk size racing past the
            // cap between the database read and the file read.
            if Int64(data.count) > cap {
                return (nil, "audio/m4a")
            }
            return (data.base64EncodedString(), "audio/m4a")
        } catch {
            eventLog.error(
                "voice_memos.audio_read_failed",
                source: .voiceMemos,
                payload: [
                    "guid_prefix": Self.guidPrefix(raw.uniqueID),
                    "error": String(describing: error)
                ]
            )
            return (nil, "audio/m4a")
        }
    }

    /// Try to transcribe; degrades to `(nil, nil, nil)` on every
    /// failure mode (no auth, no on-device model, recognizer threw)
    /// so the caller stays on the same code path either way.
    private func transcribeIfPossible(
        raw: RawVoiceMemo
    ) async -> (String?, String?, String?) {
        guard let url = raw.audioURL else { return (nil, nil, nil) }
        let outcome = await transcriber.transcribe(url: url)
        switch outcome {
        case .success(let text, let locale, let engine):
            return (text, engine, locale)
        case .empty(let locale, let engine):
            // Empty transcription still records the engine + locale so
            // the server can tell "we tried and the audio was silent"
            // apart from "we never tried".
            return (nil, engine, locale)
        case .unavailable(let reason):
            eventLog.info(
                "voice_memos.transcribe_unavailable",
                source: .voiceMemos,
                payload: [
                    "guid_prefix": Self.guidPrefix(raw.uniqueID),
                    "reason": reason
                ]
            )
            return (nil, nil, nil)
        case .failed(let reason):
            eventLog.error(
                "voice_memos.transcribe_failed",
                source: .voiceMemos,
                payload: [
                    "guid_prefix": Self.guidPrefix(raw.uniqueID),
                    "reason": reason
                ]
            )
            // macOS surfaces "Siri and Dictation are disabled" as
            // `kLSRErrorDomain Code=201` when the OS-level Speech
            // Recognition feature is off. Flip the source's status to
            // `needsAttention` so the detail pane shows the focused
            // unblock view (deep-link to Privacy → Speech Recognition).
            // Audio bytes still upload; only the transcript is gated.
            if reason.contains("Siri and Dictation are disabled")
                || reason.contains("kLSRErrorDomain Code=201") {
                speechDisabledDetected = true
            }
            return (nil, nil, nil)
        }
    }

    /// `ZCUSTOMLABEL` is nil for any recording the user never renamed (the
    /// stock Voice Memos UI labels them by location + date, but Core Data
    /// keeps the column null until the user types something). We surface a
    /// derived `Voice Memo · <localised date>` so the cloud always has a
    /// readable label without inventing a user-set value.
    nonisolated static func resolvedTitle(raw: RawVoiceMemo) -> String {
        if let label = raw.customLabel, !label.isEmpty {
            return label
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Voice Memo · \(formatter.string(from: raw.createdAt))"
    }

    /// First 8 characters of a guid, for log payloads. Keeps the line
    /// useful for debugging without persisting the full UUID.
    nonisolated private static func guidPrefix(_ guid: String) -> String {
        String(guid.prefix(8))
    }
}
