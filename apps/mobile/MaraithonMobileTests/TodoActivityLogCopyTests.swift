import Foundation
import Testing
@testable import MaraithonMobile

@Suite("Todo Activity Log Copy")
@MainActor
struct TodoActivityLogCopyTests {
    @Test
    func eventTitlesNameDebugLifecycleEvents() {
        #expect(TodoActivityLogCopy.eventTitle(for: event(eventType: "created")) == "Todo Created")
        #expect(TodoActivityLogCopy.eventTitle(for: event(eventType: "marked_done")) == "Todo Marked Done")
        #expect(TodoActivityLogCopy.eventTitle(for: event(eventType: "deleted")) == "Todo Deleted")
        #expect(TodoActivityLogCopy.eventTitle(for: event(eventType: "something_else")) == "Todo Updated")
    }

    @Test
    func actorTextKeepsAgentAndUserDistinct() {
        #expect(TodoActivityLogCopy.actorText(for: event(actorType: "user")) == "User")
        #expect(TodoActivityLogCopy.actorText(for: event(actorType: "agent")) == "Agent")
        #expect(TodoActivityLogCopy.actorText(for: event(actorType: "system", actorLabel: "Maintenance")) == "Maintenance")
    }

    @Test
    func missingTodoTitleHasDebugFallback() {
        #expect(TodoActivityLogCopy.todoTitle(for: event(todoTitle: "  ")) == "Untitled Todo")
        #expect(TodoActivityLogCopy.todoTitle(for: event(todoTitle: "Reply to Alex")) == "Reply to Alex")
    }

    private func event(
        eventType: String = "created",
        actorType: String = "user",
        actorLabel: String? = nil,
        todoTitle: String? = "Reply to Alex"
    ) -> MobileAPIClient.RemoteTodoActivity {
        MobileAPIClient.RemoteTodoActivity(
            id: "activity-id",
            eventType: eventType,
            actorType: actorType,
            actorLabel: actorLabel,
            todoTitle: todoTitle,
            occurredAt: Date(timeIntervalSince1970: 0)
        )
    }
}
