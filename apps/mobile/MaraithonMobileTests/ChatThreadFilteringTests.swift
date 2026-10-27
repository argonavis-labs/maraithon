import Foundation
import Testing
@testable import MaraithonMobile

@Suite("Chat Thread Filtering")
struct ChatThreadFilteringTests {
    @Test
    func emptySearchReturnsAllThreads() {
        let first = ChatThread(title: "Planning")
        let second = ChatThread(title: "Follow-ups")

        #expect(ChatThreadFiltering.filter([first, second], searchText: " ").map(\.title) == ["Planning", "Follow-ups"])
    }

    @Test
    func searchMatchesTitleAndMessageBody() {
        let planning = ChatThread(title: "Planning")
        let relationships = ChatThread(title: "Relationships")
        let message = ChatMessage(body: "Draft a note for Alex", role: .assistant, thread: relationships)
        relationships.messages.append(message)

        #expect(ChatThreadFiltering.filter([planning, relationships], searchText: "relation").map(\.title) == ["Relationships"])
        #expect(ChatThreadFiltering.filter([planning, relationships], searchText: "alex").map(\.title) == ["Relationships"])
        #expect(ChatThreadFiltering.filter([planning, relationships], searchText: "missing").isEmpty)
    }
}
