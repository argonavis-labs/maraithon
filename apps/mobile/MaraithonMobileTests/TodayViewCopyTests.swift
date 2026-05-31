import Testing
@testable import MaraithonMobile

@Suite("Today View Copy")
struct TodayViewCopyTests {
    @Test
    func nextActionsUsesConcreteOperationalLabels() {
        #expect(TodayViewCopy.actionSectionTitle == "Next actions")
        #expect(TodayViewCopy.focusSectionTitle == "Today's focus")
        #expect(TodayViewCopy.recentChatsSectionTitle == "Recent chats")
        #expect(TodayViewCopy.completeFocusActionLabel == "Done")
        #expect(TodayViewCopy.dismissFocusActionLabel == "Dismiss")
        #expect(TodayViewCopy.editFocusActionLabel == "Edit")
        #expect(TodayViewCopy.askMaraithonTitle == "Ask Maraithon")
        #expect(TodayViewCopy.askMaraithonSubtitle == "Plan, draft, or prioritize")
        #expect(TodayViewCopy.openWorkTitle == "Open work")
        #expect(TodayViewCopy.overdueTitle == "Past due")
        #expect(TodayViewCopy.overdueSubtitle == "Needs action")
        #expect(TodayViewCopy.followUpTitle == "Needs follow-up")
        #expect(TodayViewCopy.followUpSubtitle == "Relationships need attention")
    }

    @Test
    func emptyStatesReadLikeExecutiveBriefs() {
        #expect(TodayViewCopy.emptyFocusTitle == "Nothing urgent for today")
        #expect(TodayViewCopy.emptyFocusDescription == "Today shows past-due, due-today, high-priority work, and relationship follow-ups. Use Open work for everything else.")
        #expect(TodayViewCopy.emptyRecentChatsTitle == "No recent chats")
        #expect(TodayViewCopy.emptyRecentChatsDescription == "Start a chat when you need a draft, summary, or prioritization pass.")
    }

    @Test
    func nextActionsAvoidsGenericOrMisleadingLanguage() {
        let exactCopy = TodayViewCopy.actionLabels.joined(separator: " ")
        let copy = exactCopy.lowercased()

        #expect(!copy.contains("priority snapshot"))
        #expect(!copy.contains("dashboard"))
        #expect(!copy.contains("command center"))
        #expect(!copy.contains("needs a decision"))
        #expect(!copy.contains("outstanding work"))
        #expect(!copy.contains("stale active relationships"))
        #expect(!copy.contains("relationships tracked"))
        #expect(!copy.contains("queue"))
        #expect(!copy.contains("delete"))
        #expect(!exactCopy.contains("No Recent Chats"))
    }
}
