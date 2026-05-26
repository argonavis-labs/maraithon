import Testing
@testable import MaraithonMobile

@Suite("Chat Thread Naming")
struct ChatThreadNamingTests {
    @Test
    func emptyMessageFallsBackToDefaultTitle() {
        #expect(ChatThreadNaming.title(for: "   ") == "New conversation")
    }

    @Test
    func longTitleIsWordBounded() {
        let title = ChatThreadNaming.title(
            for: "Draft a follow-up todo for the Northstar procurement review",
            maxLength: 34
        )

        #expect(title == "Draft a follow-up todo for the")
    }
}
