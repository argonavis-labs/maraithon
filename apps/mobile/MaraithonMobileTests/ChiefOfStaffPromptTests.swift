import Testing
@testable import MaraithonMobile

@Suite("Chief of Staff Prompts")
struct ChiefOfStaffPromptTests {
    @Test
    func promptCollectionsStayUsefulAndUnique() {
        let prompts = ChiefOfStaffPrompt.chat
        let ids = Set(prompts.map(\.id))

        #expect(ids.count == prompts.count)
        #expect(prompts.count >= ChiefOfStaffPrompt.today.count)
        #expect(prompts.allSatisfy { !$0.title.isEmpty && !$0.message.isEmpty })
        #expect(prompts.contains { $0.message.localizedCaseInsensitiveContains("work item") })
        #expect(prompts.allSatisfy { !$0.title.localizedCaseInsensitiveContains("todo") })
        #expect(prompts.allSatisfy { !$0.subtitle.localizedCaseInsensitiveContains("todo") })
        #expect(prompts.allSatisfy { !$0.message.localizedCaseInsensitiveContains("todo") })
        #expect(prompts.allSatisfy { !$0.message.localizedCaseInsensitiveContains("open loops") })
        #expect(prompts.allSatisfy { !$0.subtitle.localizedCaseInsensitiveContains("overdue") })
        #expect(prompts.allSatisfy { !$0.message.localizedCaseInsensitiveContains("overdue") })
        #expect(prompts.contains { $0.message.localizedCaseInsensitiveContains("people") })
    }
}
