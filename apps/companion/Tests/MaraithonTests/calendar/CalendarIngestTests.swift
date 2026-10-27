import XCTest
@testable import Maraithon

private func http(_ status: Int, url: URL = URL(string: "https://x")!) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

final class CalendarIngestTests: XCTestCase {

    func testPushSendsExpectedHeadersAndPath() async throws {
        let captured = CapturedCalendarRequest()
        let responseBody = try JSONEncoder().encode(IngestResponse(accepted: 1, duplicate: 0))
        let ingest = CalendarIngest(
            baseURL: URL(string: "https://example.test")!,
            tokenProvider: { "tok-xyz" },
            transport: { req in
                await captured.record(req)
                return (responseBody, http(200))
            }
        )

        let payload = CalendarEventPayload(
            guid: "EVT-1",
            localId: "cal:MASTER-1",
            calendarName: "Home",
            calendarColor: "#ff8800",
            title: "Standup",
            notes: nil,
            location: nil,
            startAt: Date(timeIntervalSince1970: 0),
            endAt: Date(timeIntervalSince1970: 1800),
            isAllDay: false,
            isRecurring: false,
            organizerEmail: nil,
            attendeesCount: 0,
            attendeeEmails: [],
            createdAt: nil,
            modifiedAt: nil
        )
        let outcome = try await ingest.push(deviceId: UUID(), events: [payload])
        XCTAssertEqual(outcome.accepted, 1)
        XCTAssertEqual(outcome.duplicate, 0)

        let last = await captured.last
        let req = try XCTUnwrap(last)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/api/v1/companion/calendar-events")
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
        let counter = CalendarSendCounter()
        let ingest = CalendarIngest(
            baseURL: URL(string: "https://example.test")!,
            tokenProvider: { "tok" },
            transport: { _ in
                await counter.mark()
                return (Data(), http(200))
            }
        )
        let outcome = try await ingest.push(deviceId: UUID(), events: [])
        XCTAssertEqual(outcome.accepted, 0)
        XCTAssertEqual(outcome.duplicate, 0)
        let didSend = await counter.value
        XCTAssertFalse(didSend, "Empty batches must not hit the network")
    }

    func testServerErrorIsTypedAsRetriable() async {
        let ingest = CalendarIngest(
            baseURL: URL(string: "https://example.test")!,
            tokenProvider: { "tok" },
            transport: { _ in (Data(), http(500)) }
        )
        do {
            _ = try await ingest.push(deviceId: UUID(), events: [samplePayload()])
            XCTFail("Expected server error")
        } catch let err as MaraithonClientError {
            XCTAssertTrue(err.isRetriable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMissingTokenShortCircuits() async {
        let counter = CalendarSendCounter()
        let ingest = CalendarIngest(
            baseURL: URL(string: "https://example.test")!,
            tokenProvider: { nil },
            transport: { _ in
                await counter.mark()
                return (Data(), http(200))
            }
        )
        do {
            _ = try await ingest.push(deviceId: UUID(), events: [samplePayload()])
            XCTFail("Expected unauthorized")
        } catch MaraithonClientError.unauthorized {
            let didSend = await counter.value
            XCTAssertFalse(didSend, "Should short-circuit before sending")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func samplePayload() -> CalendarEventPayload {
        CalendarEventPayload(
            guid: "g",
            localId: "cal:m",
            calendarName: nil,
            calendarColor: nil,
            title: nil,
            notes: nil,
            location: nil,
            startAt: Date(),
            endAt: Date(),
            isAllDay: false,
            isRecurring: false,
            organizerEmail: nil,
            attendeesCount: 0,
            attendeeEmails: [],
            createdAt: nil,
            modifiedAt: nil
        )
    }
}

actor CapturedCalendarRequest {
    private(set) var last: URLRequest?
    func record(_ request: URLRequest) {
        last = request
    }
}

actor CalendarSendCounter {
    private(set) var value: Bool = false
    func mark() { value = true }
}
