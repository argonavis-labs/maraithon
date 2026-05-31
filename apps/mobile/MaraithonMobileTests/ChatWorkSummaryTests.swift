import Foundation
import Testing
@testable import MaraithonMobile

@Suite("Chat Work Summary")
struct ChatWorkSummaryTests {
    @Test
    func visibleProgressCopyAvoidsAnthropomorphicOrGenericLabels() {
        #expect(ChatWorkSummaryViewCopy.checkedSectionTitle == "Context checked")
        #expect(ChatWorkSummaryViewCopy.progressSectionTitle == "Progress")
        #expect(ChatWorkSummaryViewCopy.completedFallbackTitle == "What Maraithon checked")
        #expect(ChatWorkSummaryViewCopy.pendingFallbackTitle == "Working on your request")
        #expect(ChatWorkSummaryViewCopy.pendingFallbackTitle != "Maraithon is thinking")
        #expect(ChatWorkSummaryViewCopy.checkedSectionTitle != "Checks")
        #expect(ChatWorkSummaryViewCopy.progressSectionTitle != "Work")
    }

    @Test
    func encodingDoesNotExposeImplementationMetadata() throws {
        let summary = ChatWorkSummary(
            headline: "Checked open work and replied",
            status: "completed",
            toolCalls: [
                .init(
                    id: "tool-1",
                    tool: "list_todos",
                    label: "Open work",
                    status: "completed",
                    summary: "Returned 2 todos"
                )
            ]
        )

        let data = try JSONEncoder().encode(summary)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let visiblePayload = String(data: data, encoding: .utf8) ?? ""

        #expect(visiblePayload.contains("list_todos") == false)
        #expect(visiblePayload.contains("Returned") == false)
        #expect(visiblePayload.contains("Checked 2 open work items.") == true)
        #expect(object["model_name"] == nil)
        #expect(object["model_tier"] == nil)
        #expect(object["model_reasoning_effort"] == nil)
        #expect(object["task_class"] == nil)
        #expect(object["route_reason"] == nil)
        #expect(object["llm_turns"] == nil)
        #expect(object["tool_steps"] == nil)
    }

    @Test
    func decodingIgnoresLegacyImplementationMetadata() throws {
        let data = Data(
            """
            {
              "headline": "Answered directly",
              "status": "completed",
              "model_name": "gpt-test",
              "model_tier": "chat",
              "model_reasoning_effort": "high",
              "task_class": "direct_answer",
              "route_reason": "test_route",
              "llm_turns": 2,
              "tool_steps": 0,
              "tool_calls": [],
              "steps": []
            }
            """.utf8
        )

        let summary = try JSONDecoder().decode(ChatWorkSummary.self, from: data)

        #expect(summary.headline == "Answered directly")
        #expect(summary.status == "completed")
        #expect(summary.hasVisibleWork)
    }

    @Test
    func decodingNormalizesLegacyImplementationVocabulary() throws {
        let data = Data(
            """
            {
              "headline": "Checked open work and replied",
              "status": "completed",
              "tool_calls": [
                {
                  "id": "tool-1",
                  "tool": "list_todos",
                  "label": "Open work",
                  "status": "completed",
                  "summary": "Returned 1 todo"
                },
                {
                  "id": "tool-2",
                  "tool": "llm_trace_debug",
                  "label": "Supporting work",
                  "status": "completed",
                  "summary": "Completed"
                }
              ],
              "steps": [
                {
                  "id": "step-1",
                  "type": "llm_request",
                  "status": "completed"
                },
                {
                  "id": "step-2",
                  "type": "implementation_run_metadata",
                  "status": "completed"
                }
              ]
            }
            """.utf8
        )

        let summary = try JSONDecoder().decode(ChatWorkSummary.self, from: data)
        let encoded = try JSONEncoder().encode(summary)
        let visiblePayload = String(data: encoded, encoding: .utf8) ?? ""

        #expect(summary.toolCalls.map(\.tool) == ["open_work", "supporting_work"])
        #expect(summary.toolCalls[0].summary == "Checked 1 open work item.")
        #expect(summary.toolCalls[1].summary == "Completed the check.")
        #expect(summary.steps.map(\.type) == ["answer_preparation", "supporting_work"])
        #expect(summary.steps.first?.displayTitle == "Prepared the answer")
        #expect(visiblePayload.contains("list_todos") == false)
        #expect(visiblePayload.contains("Returned") == false)
        #expect(visiblePayload.contains(#""summary":"Completed""#) == false)
        #expect(visiblePayload.contains("llm") == false)
        #expect(visiblePayload.contains("implementation") == false)
        #expect(visiblePayload.contains("metadata") == false)
    }

    @Test
    func decodingScopesEmptyOpenWorkToTheCurrentCheck() throws {
        let data = Data(
            """
            {
              "headline": "Checked open work and replied",
              "status": "completed",
              "tool_calls": [
                {
                  "id": "tool-1",
                  "tool": "list_todos",
                  "label": "Open work",
                  "status": "completed",
                  "summary": "Returned 0 todos"
                },
                {
                  "id": "tool-2",
                  "tool": "get_open_work_summary",
                  "label": "Open work",
                  "status": "completed",
                  "summary": "No open work found."
                }
              ],
              "steps": []
            }
            """.utf8
        )

        let summary = try JSONDecoder().decode(ChatWorkSummary.self, from: data)
        let summaries = summary.toolCalls.compactMap(\.summary)
        let visibleText = summaries.joined(separator: " ")

        #expect(summaries == [
            "This check returned no open work.",
            "This check returned no open work."
        ])
        #expect(visibleText.localizedCaseInsensitiveContains("No open work found") == false)
        #expect(visibleText.localizedCaseInsensitiveContains("all clear") == false)
    }

    @Test
    func decodingNormalizesLegacyProductVocabulary() throws {
        let data = Data(
            """
            {
              "headline": "Checking CRM context",
              "status": "running",
              "tool_calls": [
                {
                  "id": "tool-1",
                  "tool": "upsert_todos",
                  "label": "Todo update",
                  "status": "completed",
                  "summary": "Updated 2 todos."
                },
                {
                  "id": "tool-2",
                  "tool": "get_relationship_context",
                  "label": "CRM context",
                  "status": "completed",
                  "summary": "Found context in CRM."
                }
              ],
              "steps": []
            }
            """.utf8
        )

        let summary = try JSONDecoder().decode(ChatWorkSummary.self, from: data)
        let encoded = try JSONEncoder().encode(summary)
        let visiblePayload = String(data: encoded, encoding: .utf8) ?? ""

        #expect(summary.headline == "Checking relationship context")
        #expect(summary.toolCalls.map(\.tool) == ["work_update", "relationship_context"])
        #expect(summary.toolCalls.map(\.label) == ["Work update", "Relationship context"])
        #expect(summary.toolCalls.map(\.summary) == ["Updated 2 work items.", "Found context in relationship data."])
        #expect(visiblePayload.localizedCaseInsensitiveContains("todo") == false)
        #expect(visiblePayload.localizedCaseInsensitiveContains("crm") == false)
    }

    @Test
    func decodingKeepsFollowThroughLabelsUserFacing() throws {
        let data = Data(
            """
            {
              "headline": "Checked follow-through before replying",
              "status": "completed",
              "tool_calls": [
                {
                  "id": "tool-1",
                  "tool": "get_open_loops",
                  "label": "get_open_loops",
                  "status": "completed",
                  "summary": "Reviewed current follow-through."
                },
                {
                  "id": "tool-2",
                  "tool": "inspect_open_insight",
                  "label": "inspect_open_insight",
                  "status": "completed",
                  "summary": "Checked selected work."
                },
                {
                  "id": "tool-3",
                  "tool": "learn_relationship_context",
                  "label": "learn_relationship_context",
                  "status": "completed",
                  "summary": "Updated relationship notes."
                }
              ],
              "steps": []
            }
            """.utf8
        )

        let summary = try JSONDecoder().decode(ChatWorkSummary.self, from: data)
        let encoded = try JSONEncoder().encode(summary)
        let visiblePayload = String(data: encoded, encoding: .utf8) ?? ""

        #expect(summary.toolCalls.map(\.tool) == ["open_loops", "linked_item", "relationship_learning"])
        #expect(summary.toolCalls.map(\.label) == ["Follow-through", "Selected item", "Relationship notes"])
        #expect(visiblePayload.contains("Open loops") == false)
        #expect(visiblePayload.contains("Linked item") == false)
        #expect(visiblePayload.contains("Relationship learning") == false)
        #expect(visiblePayload.contains("get_open_loops") == false)
        #expect(visiblePayload.contains("inspect_open_insight") == false)
        #expect(visiblePayload.contains("learn_relationship_context") == false)
    }

    @Test
    func decodingPreservesSpecificChiefOfStaffToolLabels() throws {
        let data = Data(
            """
            {
              "headline": "Checked people, updated memory, checked Messages, and 2 more checks before replying",
              "status": "completed",
              "tool_calls": [
                {
                  "id": "tool-1",
                  "tool": "list_people",
                  "label": "list_people",
                  "status": "completed",
                  "summary": "1 person: Dana Chen"
                },
                {
                  "id": "tool-2",
                  "tool": "forget_memory",
                  "label": "forget_memory",
                  "status": "completed",
                  "summary": "Removed outdated context."
                },
                {
                  "id": "tool-3",
                  "tool": "messages_search",
                  "label": "messages_search",
                  "status": "completed",
                  "summary": "1 message: Alex: Board prep"
                },
                {
                  "id": "tool-4",
                  "tool": "slack_get_thread_context",
                  "label": "slack_get_thread_context",
                  "status": "completed",
                  "summary": "Found the launch thread."
                },
                {
                  "id": "tool-5",
                  "tool": "list_connected_accounts",
                  "label": "list_connected_accounts",
                  "status": "completed",
                  "summary": "Found 2 results."
                }
              ],
              "steps": []
            }
            """.utf8
        )

        let summary = try JSONDecoder().decode(ChatWorkSummary.self, from: data)
        let encoded = try JSONEncoder().encode(summary)
        let visiblePayload = String(data: encoded, encoding: .utf8) ?? ""

        #expect(summary.toolCalls.map(\.tool) == ["people", "memory_update", "messages", "slack", "connected_accounts"])
        #expect(summary.toolCalls.map(\.label) == ["People", "Memory update", "Messages", "Slack", "Connected accounts"])
        #expect(visiblePayload.contains("Supporting work") == false)
        #expect(visiblePayload.contains("list_people") == false)
        #expect(visiblePayload.contains("messages_search") == false)
        #expect(visiblePayload.contains("slack_get_thread_context") == false)
    }

    @Test
    func decodingTurnsGenericResultCountsIntoSourceSpecificBriefs() throws {
        let data = Data(
            """
            {
              "headline": "Checked connected context before replying",
              "status": "completed",
              "tool_calls": [
                {
                  "id": "tool-1",
                  "tool": "list_connected_accounts",
                  "label": "Connected accounts",
                  "status": "completed",
                  "summary": "Found 2 results."
                },
                {
                  "id": "tool-2",
                  "tool": "messages_search",
                  "label": "Messages",
                  "status": "completed",
                  "summary": "Returned 1 message"
                },
                {
                  "id": "tool-3",
                  "tool": "calendar_search",
                  "label": "Calendar",
                  "status": "completed",
                  "summary": "Returned 0 events"
                }
              ],
              "steps": []
            }
            """.utf8
        )

        let summary = try JSONDecoder().decode(ChatWorkSummary.self, from: data)
        let visibleText = summary.toolCalls.compactMap(\.summary).joined(separator: " ")

        #expect(summary.toolCalls.map(\.summary) == [
            "2 connected accounts available.",
            "Checked 1 message.",
            "This check returned no calendar events."
        ])
        #expect(visibleText.localizedCaseInsensitiveContains("found 2 results") == false)
        #expect(visibleText.localizedCaseInsensitiveContains("returned 1 message") == false)
        #expect(visibleText.localizedCaseInsensitiveContains("no events found") == false)
    }

    @Test
    func decodingScopesEmptyConnectedContextToTheCurrentRequest() throws {
        let data = Data(
            """
            {
              "headline": "Checked connected context before replying",
              "status": "completed",
              "tool_calls": [
                {
                  "id": "tool-1",
                  "tool": "list_connected_accounts",
                  "label": "Connected accounts",
                  "status": "completed",
                  "summary": "No connected accounts found."
                },
                {
                  "id": "tool-2",
                  "tool": "review_connected_context",
                  "label": "Connected sources",
                  "status": "completed",
                  "summary": "No results found."
                }
              ],
              "steps": []
            }
            """.utf8
        )

        let summary = try JSONDecoder().decode(ChatWorkSummary.self, from: data)
        let visibleText = summary.toolCalls.compactMap(\.summary).joined(separator: " ")

        #expect(summary.toolCalls.map(\.summary) == [
            "No connected accounts were available for this request.",
            "No connected sources were available for this request."
        ])
        #expect(visibleText.localizedCaseInsensitiveContains("available yet") == false)
        #expect(visibleText.localizedCaseInsensitiveContains("No connected accounts found") == false)
    }

    @Test
    func decodingDistinguishesMemoryAndPreferenceReadsFromUpdates() throws {
        let data = Data(
            """
            {
              "headline": "Checked preferences, checked memory, and replied",
              "status": "completed",
              "tool_calls": [
                {
                  "id": "tool-1",
                  "tool": "list_preferences",
                  "label": "list_preferences",
                  "status": "completed",
                  "summary": "2 preferences: Keep morning briefs concise; Do not interrupt weekends"
                },
                {
                  "id": "tool-2",
                  "tool": "list_memories",
                  "label": "list_memories",
                  "status": "completed",
                  "summary": "2 memories: School notices matter; Investor prefers short updates"
                }
              ],
              "steps": []
            }
            """.utf8
        )

        let summary = try JSONDecoder().decode(ChatWorkSummary.self, from: data)
        let encoded = try JSONEncoder().encode(summary)
        let visiblePayload = String(data: encoded, encoding: .utf8) ?? ""

        #expect(summary.toolCalls.map(\.tool) == ["preferences", "memory_check"])
        #expect(summary.toolCalls.map(\.label) == ["Preferences", "Memory"])
        #expect(visiblePayload.contains("list_preferences") == false)
        #expect(visiblePayload.contains("list_memories") == false)
    }

    @Test
    func decodingSanitizesVisibleLabelsAndDetails() throws {
        let data = Data(
            """
            {
              "headline": "llm_request model_name=gpt-test token=secret",
              "status": "done",
              "summary": "serverError(status: 500) token=secret",
              "tool_calls": [
                {
                  "id": "tool-1",
                  "tool": "gmail_search_messages",
                  "label": "gmail_search_messages",
                  "status": "failed",
                  "summary": "Error Domain=NSURLErrorDomain Code=-1009 token=secret"
                },
                {
                  "id": "tool-2",
                  "tool": "get_open_work_summary",
                  "label": "Reviewed open work",
                  "status": "completed",
                  "summary": "3 priorities found"
                }
              ],
              "steps": [
                {
                  "id": "step-1",
                  "type": "llm_request",
                  "status": "completed",
                  "title": "llm_request",
                  "detail": "clientError(status: 500, body: {token: secret})"
                }
              ]
            }
            """.utf8
        )

        let summary = try JSONDecoder().decode(ChatWorkSummary.self, from: data)
        let encoded = try JSONEncoder().encode(summary)
        let visiblePayload = String(data: encoded, encoding: .utf8) ?? ""

        #expect(summary.headline == nil)
        #expect(summary.status == "completed")
        #expect(summary.summary == nil)
        #expect(summary.toolCalls[0].label == "Gmail")
        #expect(summary.toolCalls[0].summary == "Gmail check could not finish.")
        #expect(summary.toolCalls[1].label == "Reviewed open work")
        #expect(summary.toolCalls[1].summary == "Found 3 priorities.")
        #expect(summary.steps[0].displayTitle == "Prepared the answer")
        #expect(summary.steps[0].detail == nil)
        #expect(visiblePayload.contains("gmail_search_messages") == false)
        #expect(visiblePayload.localizedCaseInsensitiveContains("priorities found") == false)
        #expect(visiblePayload.contains("serverError") == false)
        #expect(visiblePayload.contains("NSURLErrorDomain") == false)
        #expect(visiblePayload.contains("token") == false)
        #expect(visiblePayload.contains("llm") == false)
        #expect(visiblePayload.contains("clientError") == false)
    }
}
