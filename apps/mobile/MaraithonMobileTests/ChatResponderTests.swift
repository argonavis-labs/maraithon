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

        #expect(response.contains("4 open todos"))
    }

    @Test
    func producesPeopleAwareResponse() {
        let response = ChatResponder.response(
            to: "Summarize this CRM deal",
            openTodoCount: 2,
            contactCount: 5
        )

        #expect(response.contains("5 people") || response.contains("relationship"))
    }
}
