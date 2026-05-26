import XCTest
@testable import Maraithon

private func http(_ status: Int, url: URL = URL(string: "https://x")!) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

final class VoiceMemosIngestTests: XCTestCase {

    func testPushSendsExpectedHeadersAndPath() async throws {
        let captured = CapturedIngestRequest()
        let responseBody = try JSONEncoder().encode(IngestResponse(accepted: 1, duplicate: 0))
        let ingest = VoiceMemosIngest(
            baseURL: URL(string: "https://example.test")!,
            tokenProvider: { "tok-xyz" },
            transport: { req in
                await captured.record(req)
                return (responseBody, http(200))
            }
        )

        let payload = VoiceMemoPayload(
            guid: "VM-1",
            localId: "p:1",
            title: "Standup",
            durationSeconds: 12,
            fileSizeBytes: 1234,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let outcome = try await ingest.push(deviceId: UUID(), voiceMemos: [payload])
        XCTAssertEqual(outcome.accepted, 1)
        XCTAssertEqual(outcome.duplicate, 0)

        let last = await captured.last
        let req = try XCTUnwrap(last)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/api/v1/companion/voice-memos")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok-xyz")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(req.httpBody)
        XCTAssertGreaterThan(body.count, 2)
        // gzip magic bytes
        XCTAssertEqual(body[0], 0x1f)
        XCTAssertEqual(body[1], 0x8b)
    }

    func testEmptyBatchSkipsTransport() async throws {
        let counter = VoiceMemoSendCounter()
        let ingest = VoiceMemosIngest(
            baseURL: URL(string: "https://example.test")!,
            tokenProvider: { "tok" },
            transport: { _ in
                await counter.mark()
                return (Data(), http(200))
            }
        )
        let outcome = try await ingest.push(deviceId: UUID(), voiceMemos: [])
        XCTAssertEqual(outcome.accepted, 0)
        XCTAssertEqual(outcome.duplicate, 0)
        let didSend = await counter.value
        XCTAssertFalse(didSend, "Empty batches must not hit the network")
    }

    func testServerErrorIsTypedAsRetriable() async {
        let ingest = VoiceMemosIngest(
            baseURL: URL(string: "https://example.test")!,
            tokenProvider: { "tok" },
            transport: { _ in (Data(), http(500)) }
        )
        do {
            _ = try await ingest.push(
                deviceId: UUID(),
                voiceMemos: [VoiceMemoPayload(
                    guid: "g", localId: "p:1", title: nil,
                    durationSeconds: 1, fileSizeBytes: 1, createdAt: Date()
                )]
            )
            XCTFail("Expected server error")
        } catch let err as MaraithonClientError {
            XCTAssertTrue(err.isRetriable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMissingTokenShortCircuits() async {
        let counter = VoiceMemoSendCounter()
        let ingest = VoiceMemosIngest(
            baseURL: URL(string: "https://example.test")!,
            tokenProvider: { nil },
            transport: { _ in
                await counter.mark()
                return (Data(), http(200))
            }
        )
        do {
            _ = try await ingest.push(
                deviceId: UUID(),
                voiceMemos: [VoiceMemoPayload(
                    guid: "g", localId: "p:1", title: nil,
                    durationSeconds: 1, fileSizeBytes: 1, createdAt: Date()
                )]
            )
            XCTFail("Expected unauthorized")
        } catch MaraithonClientError.unauthorized {
            let didSend = await counter.value
            XCTAssertFalse(didSend, "Should short-circuit before sending")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

/// Actor wrapper so the mock transport closure can store the last request
/// from any execution context.
actor CapturedIngestRequest {
    private(set) var last: URLRequest?
    func record(_ request: URLRequest) {
        last = request
    }
}

/// Voice-Memos-scoped flag for "did the transport closure get called". The
/// iMessage suite already has a `SendCounter`; sharing it would couple two
/// otherwise-independent test files at the target level.
actor VoiceMemoSendCounter {
    private(set) var value: Bool = false
    func mark() { value = true }
}
