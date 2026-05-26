import XCTest
@testable import Maraithon

/// Verifies the channel-prefer / HTTP-fallback contract on the
/// `*Ingest` helpers. We don't re-test every helper exhaustively —
/// they all use the same one-branch shape — but we cover the two
/// shapes that differ: `NotesIngest.ingestNotes` (simple
/// accepted/duplicate response) and
/// `BrowserHistoryIngest.ingestVisits` (four-field response).
final class IngestRealtimeFallbackTests: XCTestCase {

    private nonisolated static func http(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://x")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    func testNotesIngestFallsBackToHTTPWhenChannelNil() async throws {
        let captured = CapturedRequests()
        let bodyData = try JSONEncoder().encode(IngestResponse(accepted: 1, duplicate: 0))
        let ingest = NotesIngest(
            baseURL: URL(string: "https://example.com")!,
            tokenProvider: { "tok" },
            transport: { req in
                await captured.record(req)
                return (bodyData, Self.http(200))
            }
        )

        let batch = NotesIngestBatch(
            deviceId: UUID(),
            source: "notes",
            notes: [
                NoteRecord(
                    guid: "g",
                    localId: "l",
                    title: nil,
                    snippet: nil,
                    body: nil,
                    bodyFormat: nil,
                    folder: nil,
                    isPinned: false,
                    createdAt: nil,
                    modifiedAt: nil
                )
            ]
        )

        let outcome = try await ingest.ingestNotes(batch: batch)
        XCTAssertEqual(outcome.accepted, 1)
        let last = await captured.last
        XCTAssertNotNil(last, "HTTP transport should have been invoked")
        XCTAssertEqual(last?.url?.path, "/api/v1/companion/notes")
    }

    func testNotesIngestUsesChannelWhenConnected() async throws {
        let device = UUID()
        let mock = MockSocket()
        await mock.onSend { [weak mock] frame in
            guard let parsed = Self.parseFrame(frame) else { return }
            let response: [String: Any] = parsed.event == "ingest:notes"
                ? ["accepted": 7, "duplicate": 2, "invalid": 0]
                : [:]
            let reply = Self.replyFrame(
                joinRef: parsed.joinRef,
                ref: parsed.ref,
                topic: parsed.topic,
                status: "ok",
                response: response
            )
            await mock?.deliver(.text(reply))
        }
        let channel = RealtimeChannel(
            baseURL: URL(string: "https://example.com")!,
            deviceId: device,
            tokenProvider: { "tok" },
            socketFactory: { _ in mock },
            heartbeatInterval: .seconds(60),
            log: nil
        )
        await channel.start()
        try await Self.waitForConnected(channel)

        let httpUsed = ActorFlag()
        let ingest = NotesIngest(
            baseURL: URL(string: "https://example.com")!,
            tokenProvider: { "tok" },
            transport: { _ in
                await httpUsed.mark()
                return (Data(), Self.http(500))
            },
            realtime: channel
        )

        let batch = NotesIngestBatch(
            deviceId: device,
            source: "notes",
            notes: []
        )
        let outcome = try await ingest.ingestNotes(batch: batch)
        XCTAssertEqual(outcome.accepted, 7)
        XCTAssertEqual(outcome.duplicate, 2)

        let used = await httpUsed.value
        XCTAssertFalse(used, "HTTP transport should not have been used when channel is connected")
        await channel.stop()
    }

    func testNotesIngestFallsBackToHTTPWhenChannelRepliesServerError() async throws {
        // Reproduces the production "unmatched topic" symptom: the
        // socket is connected and the topic was joined, but the server
        // replies to a push with `{"status":"error","response":{"reason":"..."}}`.
        // Before the fix, NotesIngest only caught notConnected/closed/
        // pushTimeout, so serverError propagated and failed the cycle.
        let device = UUID()
        let mock = MockSocket()
        await mock.onSend { [weak mock] frame in
            guard let parsed = Self.parseFrame(frame) else { return }
            if parsed.event == "phx_join" {
                await mock?.deliver(.text(
                    Self.replyFrame(
                        joinRef: parsed.joinRef,
                        ref: parsed.ref,
                        topic: parsed.topic,
                        status: "ok",
                        response: [:]
                    )
                ))
                return
            }
            // Reject the ingest push with the production reason string.
            await mock?.deliver(.text(
                Self.replyFrame(
                    joinRef: parsed.joinRef,
                    ref: parsed.ref,
                    topic: parsed.topic,
                    status: "error",
                    response: ["reason": "unmatched topic"]
                )
            ))
        }
        let channel = RealtimeChannel(
            baseURL: URL(string: "https://example.com")!,
            deviceId: device,
            tokenProvider: { "tok" },
            socketFactory: { _ in mock },
            heartbeatInterval: .seconds(60),
            log: nil
        )
        await channel.start()
        try await Self.waitForConnected(channel)

        let captured = CapturedRequests()
        let bodyData = try JSONEncoder().encode(IngestResponse(accepted: 3, duplicate: 0))
        let ingest = NotesIngest(
            baseURL: URL(string: "https://example.com")!,
            tokenProvider: { "tok" },
            transport: { req in
                await captured.record(req)
                return (bodyData, Self.http(200))
            },
            realtime: channel
        )

        let batch = NotesIngestBatch(deviceId: device, source: "notes", notes: [])
        let outcome = try await ingest.ingestNotes(batch: batch)

        XCTAssertEqual(outcome.accepted, 3, "HTTP fallback should have delivered the batch")
        let last = await captured.last
        XCTAssertEqual(last?.url?.path, "/api/v1/companion/notes")
        await channel.stop()
    }

    func testBrowserHistoryUsesChannelWhenConnected() async throws {
        let device = UUID()
        let mock = MockSocket()
        await mock.onSend { [weak mock] frame in
            guard let parsed = Self.parseFrame(frame) else { return }
            let response: [String: Any] = parsed.event == "ingest:browser_history"
                ? ["accepted": 3, "duplicate": 0, "invalid": 0, "filtered": 1]
                : [:]
            await mock?.deliver(.text(
                Self.replyFrame(
                    joinRef: parsed.joinRef,
                    ref: parsed.ref,
                    topic: parsed.topic,
                    status: "ok",
                    response: response
                )
            ))
        }
        let channel = RealtimeChannel(
            baseURL: URL(string: "https://example.com")!,
            deviceId: device,
            tokenProvider: { "tok" },
            socketFactory: { _ in mock },
            heartbeatInterval: .seconds(60),
            log: nil
        )
        await channel.start()
        try await Self.waitForConnected(channel)

        let ingest = BrowserHistoryIngest(
            baseURL: URL(string: "https://example.com")!,
            tokenProvider: { "tok" },
            transport: { _ in (Data(), Self.http(500)) },
            realtime: channel
        )

        let batch = BrowserHistoryIngestBatch(deviceId: device, source: "browser_history", visits: [])
        let outcome = try await ingest.ingestVisits(batch: batch)
        XCTAssertEqual(outcome.accepted, 3)
        XCTAssertEqual(outcome.filtered, 1)

        await channel.stop()
    }

    // MARK: - Helpers (shared shape with RealtimeChannelTests)

    nonisolated private static func parseFrame(_ text: String) -> RealtimeChannelTests.Frame? {
        guard let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any?],
              arr.count >= 5
        else { return nil }
        return RealtimeChannelTests.Frame(
            joinRef: arr[0] as? String,
            ref: (arr[1] as? String) ?? "",
            topic: (arr[2] as? String) ?? "",
            event: (arr[3] as? String) ?? "",
            payload: arr[4] as? [String: Any] ?? [:]
        )
    }

    nonisolated private static func replyFrame(
        joinRef: String?,
        ref: String,
        topic: String,
        status: String,
        response: [String: Any]
    ) -> String {
        let payload: [String: Any] = ["status": status, "response": response]
        let frame: [Any?] = [joinRef, ref, topic, "phx_reply", payload]
        let data = try! JSONSerialization.data(withJSONObject: frame, options: [])
        return String(data: data, encoding: .utf8)!
    }

    private static func waitForConnected(
        _ channel: RealtimeChannel,
        timeoutMillis: Int = 1_000
    ) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMillis) / 1000)
        while Date() < deadline {
            if await channel.isConnected { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let status = await channel.currentStatus
        XCTFail("channel never reached .connected (status=\(status))")
    }
}

/// Boolean flag updated from async transport closures.
private actor ActorFlag {
    private(set) var value: Bool = false
    func mark() { value = true }
}
