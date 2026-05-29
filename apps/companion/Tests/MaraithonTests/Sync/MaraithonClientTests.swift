import XCTest
@testable import Maraithon

private func http(_ status: Int, url: URL = URL(string: "https://x")!) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

final class MaraithonClientTests: XCTestCase {

    func testWhoamiSendsBearerAndDecodesAccount() async throws {
        let captured = CapturedRequests()
        let account = DeviceAuth.Account(email: "kent@example.com", deviceName: "Mac")
        let body = try JSONEncoder().encode(account)
        let client = MaraithonClient(
            baseURL: URL(string: "https://example.com")!,
            tokenProvider: { "tok-xyz" },
            transport: { req in
                await captured.record(req)
                return (body, http(200))
            }
        )

        let got = try await client.whoami()
        XCTAssertEqual(got, account)
        let last = await captured.last
        let req = try XCTUnwrap(last)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok-xyz")
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.url?.path, "/api/v1/companion/whoami")
    }

    func testIngestGzipsBodyAndDecodesOutcome() async throws {
        let captured = CapturedRequests()
        let outcome = IngestResponse(accepted: 3, duplicate: 1, invalid: 2)
        let body = try JSONEncoder().encode(outcome)
        let client = MaraithonClient(
            baseURL: URL(string: "https://example.com")!,
            tokenProvider: { "tok" },
            transport: { req in
                await captured.record(req)
                return (body, http(200))
            }
        )
        let batch = IngestBatch(
            deviceId: UUID(),
            source: "imessage",
            messages: [
                SyncEnvelope(source: "imessage", localId: "1", guid: "g1", payload: [:])
            ]
        )

        let got = try await client.ingest(batch: batch)
        XCTAssertEqual(got.accepted, 3)
        XCTAssertEqual(got.duplicate, 1)
        XCTAssertEqual(got.invalid, 2)
        let last = await captured.last
        let req = try XCTUnwrap(last)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.httpMethod, "POST")
        let sentBody = try XCTUnwrap(req.httpBody)
        XCTAssertGreaterThan(sentBody.count, 2)
        // gzip magic bytes
        XCTAssertEqual(sentBody[0], 0x1f)
        XCTAssertEqual(sentBody[1], 0x8b)
    }

    func testIngestResponseDefaultsMissingInvalidToZero() throws {
        let data = Data(#"{"accepted":1,"duplicate":0}"#.utf8)
        let decoded = try JSONDecoder().decode(IngestResponse.self, from: data)

        XCTAssertEqual(decoded.accepted, 1)
        XCTAssertEqual(decoded.duplicate, 0)
        XCTAssertEqual(decoded.invalid, 0)
    }

    func testUnauthorizedThrowsTypedError() async {
        let client = MaraithonClient(
            baseURL: URL(string: "https://example.com")!,
            tokenProvider: { "tok" },
            transport: { _ in (Data(), http(401)) }
        )
        do {
            _ = try await client.whoami()
            XCTFail("Expected unauthorized")
        } catch MaraithonClientError.unauthorized {
            // ok
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testMissingTokenThrowsUnauthorizedBeforeRequest() async {
        let sent = SendCounter()
        let client = MaraithonClient(
            baseURL: URL(string: "https://example.com")!,
            tokenProvider: { nil },
            transport: { _ in
                await sent.mark()
                return (Data(), http(200))
            }
        )
        do {
            _ = try await client.whoami()
            XCTFail()
        } catch MaraithonClientError.unauthorized {
            let didSend = await sent.value
            XCTAssertFalse(didSend, "Should short-circuit before sending")
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testServerErrorIsRetriable() {
        XCTAssertTrue(MaraithonClientError.serverError(status: 500).isRetriable)
        XCTAssertTrue(MaraithonClientError.transport(message: "x").isRetriable)
        XCTAssertFalse(MaraithonClientError.unauthorized.isRetriable)
        XCTAssertFalse(MaraithonClientError.clientError(status: 400, body: nil).isRetriable)
    }

    func testListDevicesSendsGetAndDecodes() async throws {
        let captured = CapturedRequests()
        let payload: [String: Any] = [
            "current_device_id": "dev-1",
            "devices": [
                [
                    "id": "dev-1",
                    "device_id": "11111111-1111-1111-1111-111111111111",
                    "device_name": "Studio Mac",
                    "last_seen_at": "2026-05-10T13:14:22Z",
                    "paired_at": "2026-05-01T00:00:00Z",
                    "revoked_at": NSNull(),
                    "is_current": true,
                    "counts": [
                        "messages_count": 3,
                        "notes_count": 1,
                        "voice_memos_count": 0,
                        "calendar_events_count": 0,
                        "reminders_count": 0,
                        "files_count": 0,
                        "browser_visits_count": 0
                    ]
                ]
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [])
        let client = MaraithonClient(
            baseURL: URL(string: "https://example.com")!,
            tokenProvider: { "tok" },
            transport: { req in
                await captured.record(req)
                return (body, http(200))
            }
        )

        let response = try await client.listDevices()
        XCTAssertEqual(response.currentDeviceId, "dev-1")
        XCTAssertEqual(response.devices.count, 1)
        let device = response.devices[0]
        XCTAssertEqual(device.deviceName, "Studio Mac")
        XCTAssertTrue(device.isCurrent)
        XCTAssertEqual(device.counts.messages, 3)
        XCTAssertEqual(device.counts.notes, 1)
        XCTAssertEqual(device.counts.total, 4)
        XCTAssertNil(device.revokedAt)
        let last = await captured.last
        let req = try XCTUnwrap(last)
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.url?.path, "/api/v1/companion/devices")
    }

    func testRevokeDeviceSendsPost() async throws {
        let captured = CapturedRequests()
        let client = MaraithonClient(
            baseURL: URL(string: "https://example.com")!,
            tokenProvider: { "tok" },
            transport: { req in
                await captured.record(req)
                return (Data("{}".utf8), http(200))
            }
        )
        try await client.revokeDevice(id: "abc-123")
        let last = await captured.last
        let req = try XCTUnwrap(last)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/api/v1/companion/devices/abc-123/revoke")
    }

    func testPurgeUsesDeleteMethod() async throws {
        let captured = CapturedRequests()
        let client = MaraithonClient(
            baseURL: URL(string: "https://example.com")!,
            tokenProvider: { "tok" },
            transport: { req in
                await captured.record(req)
                return (Data("{}".utf8), http(200))
            }
        )
        let id = UUID()
        try await client.purgeDeviceMessages(deviceId: id)
        let last = await captured.last
        let req = try XCTUnwrap(last)
        XCTAssertEqual(req.httpMethod, "DELETE")
        XCTAssertEqual(req.url?.path, "/api/v1/companion/devices/\(id.uuidString)/messages")
    }
}

/// Actor wrapper so the mock transport closure can store the last request
/// from any execution context.
actor CapturedRequests {
    private(set) var last: URLRequest?

    func record(_ request: URLRequest) {
        last = request
    }
}

actor SendCounter {
    private(set) var value: Bool = false
    func mark() { value = true }
}
