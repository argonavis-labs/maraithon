import XCTest
@testable import Maraithon

private func http(_ status: Int, url: URL = URL(string: "https://x")!) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

private func samplePayload(guid: String = "REM-1") -> ReminderPayload {
    ReminderPayload(
        guid: guid,
        localId: "r:\(guid)",
        title: "Pay rent",
        notes: nil,
        listName: "Personal",
        listColor: "#FF3B30",
        priority: 0,
        dueAt: Date(timeIntervalSince1970: 1_700_000_000),
        completedAt: nil,
        isCompleted: false,
        hasAlarm: false,
        urlAttachment: nil,
        createdAt: Date(timeIntervalSince1970: 1_699_000_000),
        modifiedAt: Date(timeIntervalSince1970: 1_700_500_000)
    )
}

final class RemindersIngestTests: XCTestCase {

    func testPushSendsExpectedHeadersAndPath() async throws {
        let captured = ReminderCapturedRequest()
        let responseBody = try JSONEncoder().encode(IngestResponse(accepted: 1, duplicate: 0))
        let ingest = RemindersIngest(
            baseURL: URL(string: "https://example.test")!,
            tokenProvider: { "tok-xyz" },
            transport: { req in
                await captured.record(req)
                return (responseBody, http(200))
            }
        )

        let outcome = try await ingest.push(deviceId: UUID(), reminders: [samplePayload()])
        XCTAssertEqual(outcome.accepted, 1)
        XCTAssertEqual(outcome.duplicate, 0)

        let captured_last = await captured.last
        let req = try XCTUnwrap(captured_last)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/api/v1/companion/reminders")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok-xyz")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(req.httpBody)
        XCTAssertGreaterThan(body.count, 2)
        XCTAssertEqual(body[0], 0x1f)
        XCTAssertEqual(body[1], 0x8b)
    }

    func testWireBodyEncodesSnakeCaseFields() async throws {
        let captured = ReminderCapturedRequest()
        let responseBody = try JSONEncoder().encode(IngestResponse(accepted: 1, duplicate: 0))
        let ingest = RemindersIngest(
            baseURL: URL(string: "https://example.test")!,
            tokenProvider: { "tok" },
            transport: { req in
                await captured.record(req)
                return (responseBody, http(200))
            }
        )

        _ = try await ingest.push(deviceId: UUID(), reminders: [samplePayload(guid: "wire")])

        let captured_last = await captured.last
        let req = try XCTUnwrap(captured_last)
        let gz = try XCTUnwrap(req.httpBody)
        let plain = try Gzip.decompress(gz)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: plain) as? [String: Any])

        // Top-level snake_case fields the server expects.
        XCTAssertEqual(json["source"] as? String, "reminders")
        XCTAssertNotNil(json["device_id"])
        let reminders = try XCTUnwrap(json["reminders"] as? [[String: Any]])
        XCTAssertEqual(reminders.count, 1)
        let first = reminders[0]
        XCTAssertEqual(first["guid"] as? String, "wire")
        XCTAssertEqual(first["local_id"] as? String, "r:wire")
        XCTAssertEqual(first["list_name"] as? String, "Personal")
        XCTAssertEqual(first["list_color"] as? String, "#FF3B30")
        XCTAssertEqual(first["priority"] as? Int, 0)
        XCTAssertEqual(first["is_completed"] as? Bool, false)
        XCTAssertEqual(first["has_alarm"] as? Bool, false)
        XCTAssertNotNil(first["due_at"])
        XCTAssertNotNil(first["modified_at"])
    }

    func testEmptyBatchSkipsTransport() async throws {
        let counter = ReminderSendCounter()
        let ingest = RemindersIngest(
            baseURL: URL(string: "https://example.test")!,
            tokenProvider: { "tok" },
            transport: { _ in
                await counter.mark()
                return (Data(), http(200))
            }
        )
        let outcome = try await ingest.push(deviceId: UUID(), reminders: [])
        XCTAssertEqual(outcome.accepted, 0)
        XCTAssertEqual(outcome.duplicate, 0)
        let didSend = await counter.value
        XCTAssertFalse(didSend)
    }

    func testServerErrorIsTypedAsRetriable() async {
        let ingest = RemindersIngest(
            baseURL: URL(string: "https://example.test")!,
            tokenProvider: { "tok" },
            transport: { _ in (Data(), http(500)) }
        )
        do {
            _ = try await ingest.push(deviceId: UUID(), reminders: [samplePayload()])
            XCTFail("Expected server error")
        } catch let err as MaraithonClientError {
            XCTAssertTrue(err.isRetriable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMissingTokenShortCircuits() async {
        let counter = ReminderSendCounter()
        let ingest = RemindersIngest(
            baseURL: URL(string: "https://example.test")!,
            tokenProvider: { nil },
            transport: { _ in
                await counter.mark()
                return (Data(), http(200))
            }
        )
        do {
            _ = try await ingest.push(deviceId: UUID(), reminders: [samplePayload()])
            XCTFail("Expected unauthorized")
        } catch MaraithonClientError.unauthorized {
            let didSend = await counter.value
            XCTAssertFalse(didSend)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUnauthorizedFromServerSurfacesUnauthorized() async {
        let ingest = RemindersIngest(
            baseURL: URL(string: "https://example.test")!,
            tokenProvider: { "tok" },
            transport: { _ in (Data(), http(401)) }
        )
        do {
            _ = try await ingest.push(deviceId: UUID(), reminders: [samplePayload()])
            XCTFail("Expected unauthorized")
        } catch MaraithonClientError.unauthorized {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

actor ReminderCapturedRequest {
    private(set) var last: URLRequest?
    func record(_ request: URLRequest) { last = request }
}

actor ReminderSendCounter {
    private(set) var value: Bool = false
    func mark() { value = true }
}
