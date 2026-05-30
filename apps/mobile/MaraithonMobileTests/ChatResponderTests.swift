import Testing
@testable import MaraithonMobile

@Suite("Chat Responder")
struct ChatResponderTests {
    @Test
    func producesTodoAwareResponse() {
        let response = ChatResponder.response(
            to: "Create a follow-up task",
            openTodoCount: 4,
            contactCount: 7
        )

        #expect(response.contains("4 open work items"))
        #expect(response.contains("Next move:"))
        #expect(response.localizedCaseInsensitiveContains("owner"))
        #expect(response.localizedCaseInsensitiveContains("due date"))
        #expect(!response.localizedCaseInsensitiveContains("todo"))
        #expect(!response.localizedCaseInsensitiveContains("I would"))
    }

    @Test
    func producesPeopleAwareResponse() {
        let response = ChatResponder.response(
            to: "Summarize this CRM deal",
            openTodoCount: 2,
            contactCount: 5
        )

        #expect(response.contains("5 people") || response.contains("relationship"))
        #expect(response.contains("Next move:"))
        #expect(response.localizedCaseInsensitiveContains("last-contact evidence"))
        #expect(!response.localizedCaseInsensitiveContains("I can"))
    }

    @Test
    func emptyMessageAsksForOperationalInputs() {
        let response = ChatResponder.response(
            to: "   ",
            openTodoCount: 2,
            contactCount: 3
        )

        #expect(response.localizedCaseInsensitiveContains("thread"))
        #expect(response.localizedCaseInsensitiveContains("person"))
        #expect(response.localizedCaseInsensitiveContains("desired outcome"))
        #expect(!response.localizedCaseInsensitiveContains("I can"))
    }

    @Test
    func defaultResponseKeepsTheDecisionFrame() {
        let response = ChatResponder.response(
            to: "Mark mentioned the launch delay",
            openTodoCount: 2,
            contactCount: 3
        )

        #expect(response.localizedCaseInsensitiveContains("work item"))
        #expect(response.localizedCaseInsensitiveContains("relationship note"))
        #expect(response.localizedCaseInsensitiveContains("draft"))
        #expect(response.localizedCaseInsensitiveContains("owner"))
        #expect(response.localizedCaseInsensitiveContains("timing"))
    }
}
