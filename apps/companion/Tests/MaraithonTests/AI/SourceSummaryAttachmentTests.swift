import XCTest
@testable import Maraithon

/// Per-source integration tests for v6 on-device summaries. Each test
/// drives the source's `runCycle` (or `buildPayload`) with a stub
/// summarizer so we can assert the inclusion path without depending on
/// `NLTagger`'s output stability.
///
/// The summarizer is injected via the source's `summarizer:` init
/// parameter, so these tests stay hermetic — no Foundation model is
/// ever touched.
final class SourceSummaryAttachmentTests: XCTestCase {

    // MARK: - Notes

    @MainActor
    func testNotesSourceAttachesSummaryForLongBody() async throws {
        let body = String(repeating: "the marketing budget needs review. ", count: 60)
        XCTAssertGreaterThan(body.count, NotesSource.summaryThreshold)
        let stub = StubSummarizer(prefix: "STUBBED-NOTE")
        let result = await NotesSource_v6Helpers.attachSummaries(
            built: [makeBuiltNote(body: body)],
            summarizer: stub,
            threshold: NotesSource.summaryThreshold
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.summary, "STUBBED-NOTE:note")
    }

    @MainActor
    func testNotesSourceSkipsSummaryForShortBody() async throws {
        let body = "Brief note that doesn't need a summary."
        XCTAssertLessThan(body.count, NotesSource.summaryThreshold)
        let stub = StubSummarizer(prefix: "STUBBED-NOTE")
        let result = await NotesSource_v6Helpers.attachSummaries(
            built: [makeBuiltNote(body: body)],
            summarizer: stub,
            threshold: NotesSource.summaryThreshold
        )
        XCTAssertNil(result.first?.summary, "short note should ship without a summary")
    }

    @MainActor
    func testNotesSourceFailingSummarizerDegrades() async throws {
        let body = String(repeating: "the marketing budget needs review. ", count: 60)
        let stub = FailingSummarizer()
        let result = await NotesSource_v6Helpers.attachSummaries(
            built: [makeBuiltNote(body: body)],
            summarizer: stub,
            threshold: NotesSource.summaryThreshold
        )
        XCTAssertNil(result.first?.summary, "failed summarizer should leave summary nil")
        XCTAssertEqual(result.first?.body, body, "original body must still ship")
    }

    // MARK: - Voice memos

    @MainActor
    func testVoiceMemosBuildPayloadAttachesSummaryWhenTranscribed() async throws {
        let stub = StubSummarizer(prefix: "STUB-VM")
        let transcriber = VoiceMemosTranscriber(
            recognizerFactory: { _ in
                StubVMRecognizer(text: "transcript of the recording")
            },
            authorizationProbe: { .authorized }
        )
        let source = VoiceMemosSource(
            databaseURL: URL(fileURLWithPath: "/dev/null"),
            cursor: VoiceMemosCursor(defaults: makeDefaults()),
            eventLog: EventLog(capacity: 16),
            deviceIdProvider: { UUID() },
            pollInterval: 3600,
            transcriber: transcriber,
            audioReader: { _ in Data() },
            summarizer: stub,
            outbox: { _, _ in SyncOutcome(accepted: 0, duplicate: 0) }
        )
        let raw = RawVoiceMemo(
            rowID: 1,
            uniqueID: "VM-1",
            customLabel: "Brainstorm",
            createdAt: Date(),
            durationSeconds: 30,
            audioURL: URL(fileURLWithPath: "/dev/null"),
            fileSizeBytes: 1024
        )
        let payload = await source.buildPayload(from: raw)
        XCTAssertEqual(payload.summary, "STUB-VM:voiceMemo")
    }

    @MainActor
    func testVoiceMemosBuildPayloadSkipsSummaryWhenNoTranscript() async throws {
        let stub = StubSummarizer(prefix: "STUB-VM")
        let transcriber = VoiceMemosTranscriber(
            recognizerFactory: { _ in nil },
            authorizationProbe: { .denied }
        )
        let source = VoiceMemosSource(
            databaseURL: URL(fileURLWithPath: "/dev/null"),
            cursor: VoiceMemosCursor(defaults: makeDefaults()),
            eventLog: EventLog(capacity: 16),
            deviceIdProvider: { UUID() },
            pollInterval: 3600,
            transcriber: transcriber,
            audioReader: { _ in Data() },
            summarizer: stub,
            outbox: { _, _ in SyncOutcome(accepted: 0, duplicate: 0) }
        )
        let raw = RawVoiceMemo(
            rowID: 1,
            uniqueID: "VM-NoTX",
            customLabel: nil,
            createdAt: Date(),
            durationSeconds: 5,
            audioURL: URL(fileURLWithPath: "/dev/null"),
            fileSizeBytes: 64
        )
        let payload = await source.buildPayload(from: raw)
        XCTAssertNil(payload.transcript, "stub denies authorization")
        XCTAssertNil(payload.summary, "no transcript → no summary")
    }

    // MARK: - Files

    @MainActor
    func testFilesAttachSummariesIncludesSummaryForLongText() async throws {
        let body = String(repeating: "alpha beta product launch milestone notes. ", count: 60)
        XCTAssertGreaterThan(body.count, FilesSource.summaryThreshold)
        let raw = makeRawFile(text: body)
        let base = FilesSource.payload(from: raw)
        let stub = StubSummarizer(prefix: "STUB-FILE")
        let result = await FilesSource_v6Helpers.attachSummaries(
            raws: [raw],
            base: [base],
            summarizer: stub,
            threshold: FilesSource.summaryThreshold
        )
        XCTAssertEqual(result.first?.summary, "STUB-FILE:file")
    }

    @MainActor
    func testFilesAttachSummariesSkipsShortText() async throws {
        let body = "tiny file body"
        let raw = makeRawFile(text: body)
        let base = FilesSource.payload(from: raw)
        let stub = StubSummarizer(prefix: "STUB-FILE")
        let result = await FilesSource_v6Helpers.attachSummaries(
            raws: [raw],
            base: [base],
            summarizer: stub,
            threshold: FilesSource.summaryThreshold
        )
        XCTAssertNil(result.first?.summary, "short file should ship without a summary")
    }

    // MARK: - Fixtures

    private func makeBuiltNote(body: String) -> NotesSource.BuiltNote {
        let record = NoteRecord(
            guid: "NOTE-LONG",
            localId: "p:1",
            title: "Long note",
            snippet: nil,
            body: body,
            bodyFormat: "plain",
            folder: nil,
            isPinned: false,
            createdAt: nil,
            modifiedAt: nil,
            summary: nil
        )
        return NotesSource.BuiltNote(record: record, rowID: 1)
    }

    private func makeRawFile(text: String) -> RawFile {
        RawFile(
            guid: "FILE-LONG",
            path: "~/Documents/note.md",
            localId: "/tmp/note.md",
            filename: "note.md",
            extension: "md",
            mimeType: "text/markdown",
            byteSize: Int64(text.utf8.count),
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 1),
            textContent: text,
            textTruncated: false
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "summary-attach-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)
        defaults?.removePersistentDomain(forName: suite)
        return defaults ?? .standard
    }
}

// MARK: - Stub summarizers

/// Stub that returns a deterministic, hint-aware token. Lets us assert
/// the source called the summarizer with the right hint without
/// depending on the heuristic's exact phrasing.
private struct StubSummarizer: Summarizing {
    let prefix: String
    func summarize(text: String, hint: SummaryHint) async throws -> String {
        "\(prefix):\(hint.rawValue)"
    }
}

/// Stub that always throws so we can pin the graceful-degradation
/// path: the source should swallow the error and ship without a
/// summary rather than abort the cycle.
private struct FailingSummarizer: Summarizing {
    struct SummaryFailure: Error {}
    func summarize(text: String, hint: SummaryHint) async throws -> String {
        throw SummaryFailure()
    }
}

/// Stub speech recognizer used by the Voice Memos test. Always
/// "succeeds" with a canned transcript, never touches the live
/// `SFSpeechRecognizer`.
private struct StubVMRecognizer: SpeechRecognizing {
    let text: String
    var isAvailable: Bool { true }
    var supportsOnDeviceRecognition: Bool { true }
    func recognize(url: URL) async throws -> String { text }
}

// MARK: - Bridges into private static helpers

/// The source-side helpers are `private static`. Bridge them through
/// internal-visibility shims so the test target can drive them
/// directly without breaking the source's own encapsulation.
///
/// (These shims live in this test file and are compiled in the test
/// target only, so they don't leak into the app.)
enum NotesSource_v6Helpers {
    static func attachSummaries(
        built: [NotesSource.BuiltNote],
        summarizer: Summarizing,
        threshold: Int
    ) async -> [NoteRecord] {
        await NotesSource.testHook_attachSummaries(
            built: built, summarizer: summarizer, threshold: threshold
        )
    }
}

enum FilesSource_v6Helpers {
    static func attachSummaries(
        raws: [RawFile],
        base: [FilePayload],
        summarizer: Summarizing,
        threshold: Int
    ) async -> [FilePayload] {
        await FilesSource.testHook_attachSummaries(
            raws: raws, base: base, summarizer: summarizer, threshold: threshold
        )
    }
}
