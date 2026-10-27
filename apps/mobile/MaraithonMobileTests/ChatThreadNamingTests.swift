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

        #expect(title == "Follow-up draft")
    }

    @Test
    func commonChiefOfStaffPromptsGetExecutiveTitles() {
        #expect(ChatThreadNaming.title(for: "Plan my day like my chief of staff. Start with the single next move.") == "Daily plan")
        #expect(ChatThreadNaming.title(for: "Review my people and tell me who needs attention today.") == "Relationship follow-ups")
        #expect(ChatThreadNaming.title(for: "What do I owe other people right now?") == "What I owe")
        #expect(ChatThreadNaming.title(for: "Help me capture a todo for the board packet.") == "Capture work")
    }

    @Test
    func credentialPromptsGetPrivacySafeTitles() {
        let title = ChatThreadNaming.title(for: "what's our OpenRouter API key?")

        #expect(title == "Credential question")
        #expect(!title.localizedCaseInsensitiveContains("openrouter"))
        #expect(!title.localizedCaseInsensitiveContains("api key"))
        #expect(!title.localizedCaseInsensitiveContains("token"))
        #expect(!title.localizedCaseInsensitiveContains("secret"))
    }

    @Test
    func credentialManualTitlesAreSanitized() {
        #expect(ChatThreadNaming.manualTitle(for: "what is OPENROUTER_API_KEY set to?") == "Credential question")
    }

    @Test
    func nonCredentialTokenLanguageKeepsNormalTitle() {
        #expect(ChatThreadNaming.title(for: "what token budget is left for this work?") == "What token budget is left for this work")
    }

    @Test
    func generatedTitlesUseWorkLanguageInsteadOfTodoVocabulary() {
        let title = ChatThreadNaming.title(
            for: "Please summarize todo risks before the board meeting",
            maxLength: 52
        )

        #expect(title == "Summarize work item risks before the board meeting")
        #expect(!title.localizedCaseInsensitiveContains("todo"))
    }

    @Test
    func generatedTitlesKeepCompleteBoundaryWords() {
        let title = ChatThreadNaming.title(
            for: "Please summarize todo risks before the board meeting"
        )

        #expect(title == "Summarize work item risks before the board")
        #expect(!title.localizedCaseInsensitiveContains("todo"))
    }

    @Test
    func manualTitleRejectsBlankInput() {
        #expect(ChatThreadNaming.manualTitle(for: " \n\t ") == nil)
    }

    @Test
    func manualTitleCollapsesWhitespace() {
        #expect(ChatThreadNaming.manualTitle(for: "  CEO    briefing \n follow-up  ") == "CEO briefing follow-up")
    }

    @Test
    func manualTitleIsWordBounded() {
        let title = ChatThreadNaming.manualTitle(
            for: "Follow-up planning for the quarterly operations review",
            maxLength: 32
        )

        #expect(title == "Follow-up planning for the")
    }
}
