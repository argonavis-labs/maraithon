import Foundation
import Testing
@testable import MaraithonMobile

@Suite("Mobile API Client Todos")
@MainActor
struct MobileAPIClientTodoTests {
    @Test
    func deleteTodoUsesRemoteDeleteEndpoint() async throws {
        let todoID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let recorder = HTTPRequestRecorder()
        var client = MobileAPIClient(baseURL: URL(string: "https://mobile.example.test/api/mobile")!)
        client.session = recorder.session(
            statusCode: 200,
            body:
                """
                {
                  "ok": true,
                  "deleted": true,
                  "todo": {
                    "id": "\(todoID.uuidString.lowercased())",
                    "title": "Send investor update",
                    "summary": "Send investor update",
                    "next_action": "Send investor update",
                    "due_at": null,
                    "notes": null,
                    "priority": 55,
                    "status": "dismissed",
                    "closed_at": "2026-05-29T14:00:00Z"
                  }
                }
                """
        )

        let remote = try await client.deleteTodo(sessionToken: "session-token", id: todoID)
        let request = try #require(recorder.requests.first)

        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString == "https://mobile.example.test/api/mobile/todos/\(todoID.uuidString.lowercased())?include_cards=true")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
        #expect(remote.id == todoID.uuidString.lowercased())
        #expect(remote.status == "dismissed")
    }

    @Test
    func serverErrorKeepsMachineCodeAndUsesRecoveryCopy() async throws {
        let recorder = HTTPRequestRecorder()
        var client = MobileAPIClient(baseURL: URL(string: "https://mobile.example.test/api/mobile")!)
        client.session = recorder.session(
            statusCode: 404,
            body:
                """
                {
                  "error": "not_found",
                  "message": "That item is no longer available."
                }
                """
        )

        do {
            _ = try await client.listTodos(sessionToken: "session-token")
            Issue.record("Expected a structured server error")
        } catch let error as MobileAPIError {
            #expect(error.isNotFound)
            #expect(MobileErrorCopy.message(for: error) == "That item is no longer available. Refresh to see current work.")
        }
    }

    @Test
    func listTodosRequestsDecisionCardsForMobileContext() async throws {
        let recorder = HTTPRequestRecorder()
        var client = MobileAPIClient(baseURL: URL(string: "https://mobile.example.test/api/mobile")!)
        client.session = recorder.session(
            statusCode: 200,
            body:
                """
                {
                  "todos": [
                    {
                      "id": "11111111-2222-3333-4444-555555555555",
                      "title": "Reply to Michael",
                      "summary": "Michael is waiting on the campaign update.",
                      "next_action": "Approve the short reply.",
                      "due_at": null,
                      "notes": null,
                      "priority": 80,
                      "status": "open",
                      "closed_at": null,
                      "action_card": {
                        "decision_prompt": "Decide whether to send the campaign owner and ETA.",
                        "context_items": [
                          {"label": "Person", "value": "Michael"},
                          {"label": "Project", "value": "UGC campaign"}
                        ],
                        "why_now": "Michael is waiting and no later reply was found.",
                        "source_context": "Checked Gmail",
                        "next_best_action": "Approve a short reply.",
                        "draft_preview": "Thanks Michael. I can send the timing today.",
                        "evidence_excerpt": "Can you send the next update?"
                      }
                    }
                  ]
                }
                """
        )

        let todos = try await client.listTodos(sessionToken: "session-token")
        let request = try #require(recorder.requests.first)
        let card = try #require(todos.first?.actionCard)

        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://mobile.example.test/api/mobile/todos?limit=200&status=all&sort=updated&dir=desc&include_cards=true")
        #expect(card.decisionPrompt == "Decide whether to send the campaign owner and ETA.")
        #expect(card.contextItems.compactMap(\.value) == ["Michael", "UGC campaign"])
        #expect(card.whyNow == "Michael is waiting and no later reply was found.")
        #expect(card.sourceContext == "Checked Gmail")
        #expect(card.draftPreview == "Thanks Michael. I can send the timing today.")
    }

    @Test
    func listTodoActivityRequestsDebugActivityLog() async throws {
        let recorder = HTTPRequestRecorder()
        var client = MobileAPIClient(baseURL: URL(string: "https://mobile.example.test/api/mobile")!)
        client.session = recorder.session(
            statusCode: 200,
            body:
                """
                {
                  "activity": [
                    {
                      "id": "activity-1",
                      "event_type": "marked_done",
                      "actor_type": "agent",
                      "actor_id": "completion_sweep",
                      "actor_label": "Maraithon",
                      "todo_id": "11111111-2222-3333-4444-555555555555",
                      "todo_title": "Send investor update",
                      "todo_source": "gmail",
                      "metadata": {"note": "Detected completion."},
                      "occurred_at": "2026-06-02T05:00:00Z"
                    }
                  ]
                }
                """
        )

        let activity = try await client.listTodoActivity(sessionToken: "session-token", limit: 500)
        let request = try #require(recorder.requests.first)
        let event = try #require(activity.first)

        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://mobile.example.test/api/mobile/todo-activity?limit=200")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
        #expect(event.eventType == "marked_done")
        #expect(event.actorType == "agent")
        #expect(event.actorID == "completion_sweep")
        #expect(event.todoTitle == "Send investor update")
        #expect(event.metadata["note"]?.string == "Detected completion.")
    }

    @Test
    func updateTodoRequestsFreshDecisionCardContext() async throws {
        let todoID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        let recorder = HTTPRequestRecorder()
        var client = MobileAPIClient(baseURL: URL(string: "https://mobile.example.test/api/mobile")!)
        client.session = recorder.session(
            statusCode: 200,
            body:
                """
                {
                  "todo": {
                    "id": "\(todoID.uuidString.lowercased())",
                    "title": "Reply to Michael",
                    "summary": "Michael is waiting on the campaign update.",
                    "next_action": "Approve the short reply.",
                    "due_at": null,
                    "notes": null,
                    "priority": 80,
                    "status": "open",
                    "closed_at": null,
                    "action_card": {
                      "decision_prompt": "Decide whether to send the campaign owner and ETA.",
                      "context_items": [
                        {"label": "Person", "value": "Michael"}
                      ],
                      "why_now": "Michael is waiting and no later reply was found."
                    }
                  }
                }
                """
        )

        let remote = try await client.updateTodo(
            sessionToken: "session-token",
            id: todoID,
            payload: ["title": "Reply to Michael"]
        )
        let request = try #require(recorder.requests.first)

        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.absoluteString == "https://mobile.example.test/api/mobile/todos/\(todoID.uuidString.lowercased())?include_cards=true")
        #expect(remote.actionCard?.contextItems.first?.value == "Michael")
    }

    @Test
    func listPeopleRequestsAllRelationshipStates() async throws {
        let recorder = HTTPRequestRecorder()
        var client = MobileAPIClient(baseURL: URL(string: "https://mobile.example.test/api/mobile")!)
        client.session = recorder.session(
            statusCode: 200,
            body: #"{"people":[]}"#
        )

        let people = try await client.listPeople(sessionToken: "session-token")
        let request = try #require(recorder.requests.first)

        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://mobile.example.test/api/mobile/people?limit=200&status=all")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
        #expect(people.isEmpty)
    }

    @Test
    func updatePersonPersistsRelationshipQuickActionPayload() async throws {
        let personID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let recorder = HTTPRequestRecorder()
        var client = MobileAPIClient(baseURL: URL(string: "https://mobile.example.test/api/mobile")!)
        client.session = recorder.session(
            statusCode: 200,
            body:
                """
                {
                  "person": {
                    "id": "\(personID.uuidString.lowercased())",
                    "display_name": "Ada Chen",
                    "relationship": "Northstar",
                    "contact_details": {"emails": ["ada@example.com"], "phones": []},
                    "status": "active",
                    "notes": "Board prep contact.",
                    "metadata": {"mobile_status": "active", "deal_stage": "qualified"},
                    "last_interaction_at": "2026-05-26T13:45:00Z"
                  }
                }
                """
        )

        let remote = try await client.updatePerson(
            sessionToken: "session-token",
            id: personID,
            payload: [
                "display_name": "Ada Chen",
                "relationship": "Northstar",
                "email": "ada@example.com",
                "notes": "Board prep contact.",
                "last_interaction_at": "2026-05-26T13:45:00Z",
                "metadata": [
                    "mobile_status": "active",
                    "deal_stage": "qualified"
                ]
            ]
        )
        let request = try #require(recorder.requests.first)
        let bodyData = try #require(recorder.bodies.first ?? nil)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let person = try #require(body["person"] as? [String: Any])
        let metadata = try #require(person["metadata"] as? [String: String])

        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.absoluteString == "https://mobile.example.test/api/mobile/people/\(personID.uuidString.lowercased())")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
        #expect(person["last_interaction_at"] as? String == "2026-05-26T13:45:00Z")
        #expect(metadata["mobile_status"] == "active")
        #expect(metadata["deal_stage"] == "qualified")
        #expect(remote.id == personID.uuidString.lowercased())
        #expect(remote.lastInteractionAt == ISO8601DateFormatter().date(from: "2026-05-26T13:45:00Z"))
    }
}

@MainActor
private final class HTTPRequestRecorder {
    private(set) var requests: [URLRequest] = []
    private(set) var bodies: [Data?] = []

    func session(statusCode: Int, body: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        RecordingURLProtocol.handler = { [weak self] request in
            self?.requests.append(request)
            self?.bodies.append(Self.bodyData(from: request))
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }
        return URLSession(configuration: configuration)
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
        }

        return data.isEmpty ? nil : data
    }
}

private final class RecordingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
